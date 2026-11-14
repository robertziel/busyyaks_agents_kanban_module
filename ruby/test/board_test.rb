# frozen_string_literal: true

require "test_helper"

# The BOARD (SPEC § 2): a project's columns with their TYPES and its workflow, kept in the database per project
# (BoardRepo: boards / board_columns / board_transitions + the template row), every rule derived from the types in one
# place (Board#rules). The coding board fixture derives exactly the rules busyyaks's board runs on (workflow v3: a
# question is a FLAG, Human Check and Ready to merge are gates); the content board the same for content_app's; the
# local v4 board (fixtures/boards/local_v4.board.json) is the private local-repo flow with its two agent review loops.
class BoardTest < Minitest::Test
  include KanbanTest::Setup
  Invalid = AgentsKanban::Invalid
  B = AgentsKanban::Board
  T = AgentsKanban::ColumnTypes

  def coding = B.new(KanbanTest.board_hash("coding"), host: config)
  def content = B.new(KanbanTest.board_hash("content"), host: KanbanTest.config("content"))
  def local = B.new(KanbanTest.board_hash("local_v4"), host: config)
  def raw = KanbanTest.board_hash("coding")
  def host_raw = JSON.parse(JSON.generate(config.to_h))
  def col(key, type, label: key.capitalize) = { "key" => key, "label" => label, "type" => type }
  def move = { "name" => "Move", "from" => "*", "to" => "*", "by" => "any" }
  def steps(board) = board.approvals.map { |a| [a.from, a.to, a.then, a.name, a.final] }

  # ── approval steps: a gate's ONE forward operator exit ────────────────────────────────────────

  # The local v4 board asks the operator three times: Local: Human review → Local: Merged (the agent then deploys
  # and hands the card to Local: Deploy check), Local: Deploy check → Public: Create PR (Open public PR: the agent
  # builds, audits and opens it, then moves the card on to Public: Agent review — card #271), and
  # Public: Human review → Awaiting merge (final: the agent merges and moves the card to Done). Backward exits
  # (Changes requested, Deploy failed, Rework) and Cancel approve nothing.
  def test_local_v4_derives_three_approval_steps
    assert_equal [%w[local_human_review local_merged_pr deploy_check Approve] + [false],
                  %w[deploy_check public_create_pr public_agent_review] + ["Open public PR", false],
                  %w[public_human_review awaiting_merge done Approve] + [true],],
                 steps(local)
    assert_equal %w[local_human_review deploy_check public_human_review awaiting_merge], local.gate_columns
    assert_equal local.gate_columns, local.waiting
    assert_equal "local_merged_pr", local.approval_for("local_human_review", "local_merged_pr").to
    assert_nil local.approval_for("local_human_review", "local_author"), "Changes requested is no approval"
    assert_nil local.approval_for("deploy_check", "doing"), "Deploy failed is no approval"
    assert_nil local.approval_from("awaiting_merge"), "Merge is the agent's move, not an approval"
    assert_equal %w[doing local_author public_create_pr public_author], local.working_columns
    assert_equal %w[local_agent_review local_merged_pr public_agent_review], local.review_columns
    assert_equal %w[doing todo], [local.watchdog.from, local.watchdog.to], "the FIRST working column"
    assert_equal "doing", local.idle_column
    assert_equal %w[done cancelled], local.terminal
    assert_equal local.keys - %w[done cancelled], local.owner_watched_columns
    assert_equal %w[local_human_review], local.handoff_targets("local_agent_review")
    assert_equal [], local.handoff_targets("doing")
    assert local.gate?("deploy_check")
    refute local.done?("cancelled")
    assert local.terminal?("cancelled")
    assert local.agent_closed?("cancelled")
  end

  # no board fixture stores a position: the editor lays the graph out every time (SPEC § 2)
  def test_no_board_fixture_stores_a_position
    names = Dir[File.join(KanbanTest::ROOT, "fixtures/boards/*.board.json")].map { |f| File.basename(f, ".board.json") }
    assert_includes names, "legacy_v2_prereview"
    names.each do |n|
      assert(KanbanTest.board_hash(n)["columns"].none? { |c| c.key?("x") || c.key?("y") }, "#{n} stores no position")
    end
  end

  # The coding board's check IS its gate: Human Check → Ready to merge (then Merge → Merged, by any). The content
  # board has no gate: no step.
  def test_coding_board_has_one_final_step_and_content_none
    assert_equal [%w[human_check ready merged Approve] + [true]], steps(coding)
    assert_nil coding.approval_for("human_check", "merged"), "a catch-all drag past the step is no approval"
    assert_empty content.approvals
    assert_equal [{ from: "human_check", to: "ready", then: "merged", name: "Approve", final: true }],
                 coding.rules[:gates][:approvals]
  end

  def test_an_approval_step_is_one_forward_operator_exit_of_a_gate
    cols = [col("w", "working"), col("g", "gate"), col("r", "review"), col("s", "review"), col("p", "parked"),
            col("d", "done"), col("c", "cancelled"),]
    b = ->(ts) { B.new({ "columns" => cols, "transitions" => [move] + ts }, host: config) }
    go = ->(to, by: "operator", from: "g") { { "name" => "Go #{to}", "from" => from, "to" => to, "by" => by } }
    assert_equal [%w[g r]], b.([go.("r")]).approvals.map { |a| [a.from, a.to] }
    assert_nil b.([go.("r")]).approvals.first.then
    assert_equal "s", b.([go.("r"), go.("s", by: "agent", from: "r")]).approvals.first.then
    assert_equal [%w[g p]], b.([go.("p")]).approvals.map { |a|
 [a.from, a.to] }, "forward into parked still waits for the operator"
    assert_empty b.([go.("r"), go.("s")]).approvals, "two forward exits: a choice of route"
    assert_empty b.([go.("r", by: "any")]).approvals, "an exit agents may take too approves nothing"
    assert_empty b.([go.("w")]).approvals, "a backward exit (rework) approves nothing"
    assert_empty b.([go.("c")]).approvals, "cancel approves nothing"
    assert_empty b.([go.("d")]).approvals, "a terminal target is no step"
    final = b.([go.("r"), go.("d", by: "agent", from: "r")]).approvals.first
    assert_equal ["d", true], [final.then, final.final]
  end

  def test_two_gates_leading_into_one_column_are_refused
    cols = [col("g", "gate"), col("h", "gate"), col("r", "review"), col("d", "done")]
    ts = [{ "name" => "A", "from" => "g", "to" => "r", "by" => "operator" },
          { "name" => "B", "from" => "h", "to" => "r", "by" => "operator" },]
    e = assert_raises(Invalid) { B.new({ "columns" => cols, "transitions" => ts }, host: config) }
    assert_match(/two approval steps lead into column r/, e.message)
  end

  # ── the types ─────────────────────────────────────────────────────────────────────────────────

  def test_the_type_set_and_its_flags
    assert_equal %w[parked queued working review gate done cancelled], T.keys
    assert_equal %w[gate], T::ALL.select(&:waiting).map(&:key)
    assert_equal %w[queued working review gate], T::ALL.select(&:listened).map(&:key)
    assert_equal %w[gate done cancelled], T::ALL.select(&:operator_only).map(&:key)
    assert_equal %w[done cancelled], T::ALL.select(&:agent_no_create).map(&:key)
    assert_equal %w[done], T::ALL.select(&:finishes).map(&:key)
    assert_equal %w[done cancelled], T::ALL.select(&:terminal).map(&:key)
    assert_equal %w[queued done cancelled], T::ALL.select(&:singleton).map(&:key)
    assert_match(/unknown column type "x"/, assert_raises(Invalid) { T.fetch("x") }.message)
    assert_equal T.keys, T.json.map { |t| t[:key] }
    assert_equal({ "asks_operator" => nil, "handoff" => "gate", "approved" => "gate" }, T::LEGACY)
  end

  # ── the coding board derives busyyaks's rules exactly ─────────────────────────────────────────

  def test_coding_board_is_busyyaks_board
    b = coding
    assert_equal %w[backlog todo doing qa human_check ready merged], b.keys
    assert_equal ["Backlog", "To do", "In progress", "QA", "Human Check", "Ready to merge", "Merged"], b.labels.values
    assert_equal "backlog", b.default_column
    assert_equal %w[human_check ready], b.waiting
    assert_equal %w[todo doing qa human_check ready], b.listened
    assert_equal %w[human_check ready merged], b.operator_only
    assert_equal %w[merged], b.no_create_for_agents
    assert_equal %w[merged], b.terminal
    h = b.handoff
    assert_equal [%w[human_check ready], true, true, 20, true],
                 [h.columns, h.requires_pr_url, h.requires_ci_url, h.qa_min_chars, h.ui_change_needs_screenshots]
    assert_equal %w[doing todo], [b.watchdog.from, b.watchdog.to]
    assert_nil b.dependencies
    assert_equal %w[todo doing qa human_check ready], b.watched_columns
    assert_equal %w[backlog todo doing qa human_check ready], b.owner_watched_columns
    assert_equal "doing", b.idle_column
    assert_equal %w[qa], b.review_columns
    assert b.done?("merged")
    refute b.done?("ready")
    assert b.agent_closed?("merged")
    assert b.agent_closed?("ready")
    assert_equal "Human Check", b.label("human_check")
    assert_equal "gate", b.type_of("human_check").key
    assert_equal %w[human_check], b.handoff_targets("doing")
    assert_match(/no column "nope"/, assert_raises(Invalid) { b.label("nope") }.message)
    assert_equal %w[todo doing qa human_check ready], b.takes_columns(config.agent_type("lead")) # board order
    assert_equal [], b.spawn_columns
    assert b.frozen?
  end

  def test_content_board_derives_its_rules
    b = content
    assert_equal %w[waiting queued running done], b.keys
    assert_equal [], b.waiting
    assert_equal %w[queued running], b.listened
    assert_equal %w[done], b.operator_only
    assert_nil b.handoff
    assert_empty b.approvals
    refute b.agent_closed?("done"), "no gate: anyone finishes a card"
    assert_equal %w[running queued], [b.watchdog.from, b.watchdog.to]
    assert_equal ["done"], b.dependencies.done
    assert_equal %w[queued running], b.dependencies.blocked
    assert_equal [["waiting"], "queued"], [b.dependencies.promote.from, b.dependencies.promote.to]
    assert b.done?("done")
  end

  def test_rules_json_is_the_same_derivation
    r = coding.rules
    assert_equal %w[human_check ready], r[:waiting]
    assert_equal %w[merged], r[:terminal]
    assert_equal %i[handoff approvals watchdog], r[:gates].keys
    assert_equal %w[human_check ready], r[:gates][:handoff][:columns]
    assert_equal [{ from: "human_check", to: "ready", then: "merged", name: "Approve", final: true }], r[:gates][:approvals]
    assert_nil r[:dependencies]
    assert_equal "doing", r[:idle_column]
    assert_equal %w[qa], r[:review_columns]
    assert_equal raw, coding.to_h # declared: what the editor shows and the rows store
  end

  # ── validation: loud, with the reason ─────────────────────────────────────────────────────────

  def test_refusals_name_the_problem
    bad = ->(h, re) { assert_match(re, assert_raises(Invalid) { B.new(h, host: config) }.message) }
    bad.({ "columns" => [], "transitions" => [] }, /columns must be a non-empty list/)
    bad.({ "columns" => [col("a", "parked")], "transitions" => [], "x" => 1 }, /unknown keys x/)
    bad.({ "columns" => [col("A", "parked")], "transitions" => [] }, /columns\[0\].key "A" must match/)
    bad.({ "columns" => [col("a", "parked", label: " ")], "transitions" => [] }, /column a: label must be/)
    bad.({ "columns" => [col("a", "nope")], "transitions" => [] }, /column a: type "nope" is not one of parked, queued/)
    # the graph is laid out by the editor every time: a stored position is an unknown key (SPEC § 2)
    bad.({ "columns" => [col("a", "parked").merge("x" => 1, "y" => 2)], "transitions" => [] },
         /columns\[0\] must be an object with key, label, type \(and optionally hide_after_hours\)/)
    bad.({ "columns" => [col("a", "parked"), col("a", "parked")], "transitions" => [] }, /duplicate column key a/)
    bad.({ "columns" => [col("a", "queued"), col("b", "queued")], "transitions" => [] },
         /columns a and b are both queued: a board has at most one queued column/)
    bad.({ "columns" => [col("a", "cancelled"), col("b", "cancelled"), col("d", "done")], "transitions" => [] },
         /columns a and b are both cancelled/)
    bad.({ "columns" => [col("a", "asks_operator")], "transitions" => [] },
         /column a: type "asks_operator" is not one of .* \(a workflow v2 type: BoardRepo#migrate_v3! retypes/)
    # several working columns are allowed (In progress + Author response)
    two = B.new({ "columns" => [col("a", "working"), col("b", "working"), col("d", "done")], "transitions" => [] },
host: config)
    assert_equal %w[a b], two.working_columns
    assert_equal "a", two.idle_column
    to_nowhere = { "name" => "Go", "from" => "a", "to" => "zz", "by" => "any" }
    bad.({ "columns" => [col("a", "parked")], "transitions" => [to_nowhere] }, /transitions\[0\]\.to must be a column key/)
    bad.({ "columns" => [col("a", "parked"), col("b", "working")], "transitions" => [move, move] }, /duplicate transition/)
    bad.({ "columns" => [col("a", "parked")], "transitions" => nil }, /transitions must be a list/)
    # every board ends in a done column: what "finished" means on it
    bad.({ "columns" => [col("a", "parked"), col("b", "working")], "transitions" => [] },
         /the board has no done column \(type done\): every board needs one/)
    # the host decides the handoff gate's requirements: a gate column on a host with handoff: null is refused
    nohand = AgentsKanban::HostConfig.new(host_raw.merge("handoff" => nil))
    e = assert_raises(Invalid) { B.new(raw, host: nohand) }
    assert_match(/column human_check is a gate but the host config has handoff: null/, e.message)
    # dependencies enforced need a done column
    deps = AgentsKanban::HostConfig.new(host_raw.merge("dependencies" => true))
    e = assert_raises(Invalid) { B.new({ "columns" => [col("a", "parked")], "transitions" => [] }, host: deps) }
    assert_match(/no done column/, e.message)
    assert_equal %w[todo doing qa], B.new(raw, host: deps).dependencies.blocked
  end

  def test_a_board_without_gates_derives_none_and_the_first_column_is_the_default
    cols = [col("inbox", "parked"), col("work", "working"), col("out", "done")]
    b = B.new({ "columns" => cols, "transitions" => [move] }, host: config)
    assert_equal "inbox", b.default_column
    assert_nil b.handoff
    assert_empty b.approvals
    assert_equal [], b.gate_columns
    assert_nil b.watchdog # no queued column to return a released card to
    assert_equal %w[work], b.watched_columns
  end

  # ── the host config: settings only ────────────────────────────────────────────────────────────

  def test_host_config_has_no_board_keys_and_takes_and_spawns_for_name_types
    assert_equal %w[priorities label_colors system_author attachment_url_prefix launchers agent_types concurrency
                    owner_sessions table_prefix theme idle_watch handoff approval dependencies session_dialogs flags
                    review_loop session_boards],
                 AgentsKanban::HostConfig::KEYS
    e = assert_raises(AgentsKanban::ConfigError) { AgentsKanban::HostConfig.new(host_raw.merge("columns" => [])) }
    assert_match(/unknown keys columns \(columns, gates and workflow live in the database now/, e.message)
    assert config.to_h.frozen? && config.to_h["agent_types"].frozen?
    refused = ->(h) { assert_raises(AgentsKanban::ConfigError) { AgentsKanban::HostConfig.new(h) }.message }
    assert_match(/agent_types\[lead\].takes must be a list of column types/,
                 refused.(host_raw.tap { |h| h["agent_types"][0]["takes"] = ["todo"] }))
    assert_equal({ ci_ping_after_minutes: 10, ci_comment_after_minutes: 20, owner_idle_hours: 4 }, config.idle_watch.to_h)
    assert_match(/idle_watch must be an object with exactly ci_ping/,
                 refused.(host_raw.merge("idle_watch" => { "column" => "doing" })))
    assert_match(/dependencies must be true or false/, refused.(host_raw.merge("dependencies" => nil)))
    assert_match(/handoff must be an object with exactly requires_pr_url/,
                 refused.(host_raw.merge("handoff" => { "column" => "x" })))
    assert_nil KanbanTest.config("content").handoff
    assert KanbanTest.config("content").dependencies
    # workflow v3: the flags' reminder and the review loop
    assert_equal 24, config.flags.reminder_hours
    assert_equal [3, "unresolved", "red", %w[local_agent_review public_agent_review]], config.review_loop.to_h.values
    assert_nil KanbanTest.config("content").review_loop
    assert_match(/flags must be an object with exactly reminder_hours/, refused.(host_raw.merge("flags" => nil)))
    assert_match(/flags.reminder_hours must be an integer >= 1/, refused.(host_raw.merge("flags" => { "reminder_hours" => 0 })))
    assert_match(/review_loop must be an object with exactly max_rounds/, refused.(host_raw.merge("review_loop" => {})))
    loop_raw = host_raw["review_loop"]
    assert_match(/review_loop.max_rounds must be an integer >= 1/,
                 refused.(host_raw.merge("review_loop" => loop_raw.merge("max_rounds" => 0))))
    assert_match(/review_loop.unresolved_label must be a non-empty string/,
                 refused.(host_raw.merge("review_loop" => loop_raw.merge("unresolved_label" => " "))))
    assert_match(/review_loop.unresolved_label cannot contain a comma/,
                 refused.(host_raw.merge("review_loop" => loop_raw.merge("unresolved_label" => "a,b"))))
    assert_match(/review_loop.unresolved_color must be one of label_colors/,
                 refused.(host_raw.merge("review_loop" => loop_raw.merge("unresolved_color" => "mauve"))))
    assert_match(/review_loop.columns must be a non-empty list of review column keys/,
                 refused.(host_raw.merge("review_loop" => loop_raw.merge("columns" => []))))
  end

  # ── hide_after_hours: how long a card may sit without an update before its list folds it ────────────

  def test_hide_after_hours_defaults_by_type_and_a_column_may_override_it
    assert_equal({ "parked" => 168, "done" => 24, "cancelled" => 24 },
                 T::ALL.to_h { |t| [t.key, t.hide_after_hours] }.select { |_, h| h != 72 })
    b = coding
    assert_equal({ "backlog" => 168, "todo" => 72, "doing" => 72, "qa" => 72, "human_check" => 72, "ready" => 72,
                   "merged" => 24, },
                 b.hide_after_hours)
    assert_equal b.hide_after_hours, b.rules[:hide_after_hours]
    bare = raw.merge("columns" => raw["columns"].map { |c| c.except("hide_after_hours") }) # absent = the type's default
    assert_equal b.hide_after_hours, B.new(bare, host: config).hide_after_hours
    assert_equal 24, B.new(bare, host: config).to_h["columns"].last["hide_after_hours"] # the declared shape always carries it
    overrides = { "merged" => 6, "qa" => 0 }
    columns = raw["columns"].map { |c| overrides.key?(c["key"]) ? c.merge("hide_after_hours" => overrides[c["key"]]) : c }
    tuned = raw.merge("columns" => columns)
    b2 = B.new(tuned, host: config)
    assert_equal [6, 0, 168], %w[merged qa backlog].map { |k| b2.column(k).hide_after_hours }
    [-1, 1.5, "24", B::MAX_HIDE_HOURS + 1].each do |bad|
      columns = raw["columns"].map { |c| c["key"] == "qa" ? c.merge("hide_after_hours" => bad) : c }
      e = assert_raises(Invalid) { B.new(raw.merge("columns" => columns), host: config) }
      assert_match(/column qa: hide_after_hours must be an integer 0\.\.#{B::MAX_HIDE_HOURS}/, e.message)
    end
    columns = raw["columns"].map { |c| c.merge("hidden" => 1) }
    e = assert_raises(Invalid) { B.new(raw.merge("columns" => columns), host: config) }
    assert_match(/must be an object with key, label, type \(and optionally hide_after_hours\)/, e.message)
  end

  def test_a_saved_hide_after_hours_round_trips_through_the_rows
    r = repo
    r.fetch("g/r", by: "sys")
    tuned = raw.merge("columns" => raw["columns"].map { |c| c["key"] == "merged" ? c.merge("hide_after_hours" => 48) : c })
    r.save("g/r", tuned, by: "op", cards_in: ->(*) { {} })
    assert_equal 48, r.fetch("g/r", by: "sys").column("merged").hide_after_hours
    assert_equal 48, db[:"#{KanbanTest::PREFIX}board_columns"].where(project_slug: "g/r", key: "merged").get(:hide_after_hours)
    assert_equal 24, r.fetch("p", by: "sys").column("merged").hide_after_hours # the template: the type's default
  end

  # ── the repository: per project in the database, the template, instantiation ─────────────────

  def repo
    AgentsKanban::BoardRepo.new(db, tables: kb.tables, host: config, clock: -> { @now }, known: ->(s) { @boards.include?(s) })
  end

  def test_a_project_gets_the_template_as_its_own_rows_and_edits_it_apart
    r = repo
    assert r.template?
    assert_equal [], r.slugs
    b = r.fetch("g/r", by: "sys")
    assert_equal coding, b
    assert_equal ["g/r"], r.slugs # instantiated: its own rows now
    assert_equal ["sys", AgentsKanban::Store.iso(1000)],
                 [r.json("g/r", by: "sys")[:updated_by], r.json("g/r", by: "sys")[:updated]]
    edited = raw.merge("columns" => raw["columns"] + [col("staging", "review", label: "In staging")])
    r.save("g/r", edited, by: "op", cards_in: ->(*) { {} })
    assert_equal %w[backlog todo doing qa human_check ready merged staging], r.fetch("g/r", by: "sys").keys
    assert_equal coding, r.fetch("p", by: "sys") # another project: still the template
    assert_equal coding, r.template
    j = r.json("g/r", by: "sys")
    assert_equal ["op", 8, T.keys], [j[:updated_by], j[:columns].size, j[:types].map { |t| t[:key] }]
    assert_equal %w[human_check ready], j[:rules][:waiting]
    assert_equal coding, r.reset("g/r", by: "op", cards_in: ->(*) { {} })
  end

  # retyping a column with cards into a waiting type (a gate) would put them before the operator unasked.
  def test_making_a_column_with_cards_wait_for_the_operator_is_refused
    id = kb.create(slug: "g/r", title: "a", by: "op", column: "qa")
    qa_waits = raw.merge("columns" => raw["columns"].map { |c| c["key"] == "qa" ? c.merge("type" => "gate") : c })
    e = assert_raises(Invalid) { kb.board_save("g/r", qa_waits, by: "op") }
    assert_match(/cannot make a column with cards wait for the operator: QA \(qa\) holds card ##{id} — move them first/,
                 e.message)
    kb.move(id, column: "doing", by: "op")
    kb.board_save("g/r", qa_waits, by: "op")
    assert_includes kb.board_of("g/r").waiting, "qa"
  end

  def test_removing_a_column_with_cards_is_refused_naming_them
    id = kb.create(slug: "g/r", title: "a", by: "op", column: "qa")
    b = kb.create(slug: "g/r", title: "b", by: "op", column: "qa")
    transitions = raw["transitions"]
      .map { |t| t.merge("from" => t["from"].is_a?(Array) ? t["from"] - ["qa"] : t["from"]) }
      .reject { |t| t["from"] == "qa" || t["to"] == "qa" }
    without_qa = raw.merge("columns" => raw["columns"].reject { |c| c["key"] == "qa" },
                           "transitions" => transitions)
    e = assert_raises(Invalid) { kb.board_save("g/r", without_qa, by: "op") }
    assert_match(/cannot remove a column with cards: QA \(qa\) holds cards ##{id}, ##{b} — move them first/, e.message)
    assert_equal coding, kb.board_of("g/r") # nothing changed
    kb.move(id, column: "doing", by: "op")
    kb.archive(b, by: "op") # an archived card still references its column: still refused
    assert_raises(Invalid) { kb.board_save("g/r", without_qa, by: "op") }
  end

  # the template is instantiated only for a slug the host KNOWS (never a ghost row for a typo or a vanished project),
  # and a first read that loses the race against another process re-reads the winner's rows instead of failing
  def test_only_a_known_project_is_instantiated_and_a_lost_race_re_reads
    e = assert_raises(Invalid) { kb.board_of("no/such") }
    assert_match(/no board no\/such/, e.message)
    assert_equal 0, db[:"#{KanbanTest::PREFIX}boards"].where(project_slug: "no/such").count
    assert_equal 0, db[:"#{KanbanTest::PREFIX}board_columns"].where(project_slug: "no/such").count
    r1 = repo
    r2 = AgentsKanban::BoardRepo.new(db, tables: kb.tables, host: config, clock: -> { @now }, known: ->(_) { true })
    # r1 loses: between its "no rows" read and its insert, r2 writes the project's rows
    orig = r1.method(:write)
    r1.define_singleton_method(:write) do |slug, board, **kw|
      r2.fetch(slug, by: "other") if slug == "g/r"
      orig.call(slug, board, **kw)
    end
    assert_equal coding, r1.fetch("g/r", by: "sys")
    assert_equal 1, db[:"#{KanbanTest::PREFIX}boards"].where(project_slug: "g/r").count
    assert_equal 7, db[:"#{KanbanTest::PREFIX}board_columns"].where(project_slug: "g/r").count
    assert_equal "other", r1.json("g/r", by: "sys")[:updated_by] # the winner's copy, not overwritten
  end

  def test_no_template_and_a_stored_board_the_host_no_longer_fits_are_loud
    r = repo
    db[:"#{KanbanTest::PREFIX}boards"].delete
    e = assert_raises(Invalid) { r.fetch("g/r", by: "sys") }
    assert_match(/no board template/, e.message)
    seed_template(config, KanbanTest.board_hash("coding"))
    repo.fetch("g/r", by: "sys")
    nohand = AgentsKanban::HostConfig.new(host_raw.merge("handoff" => nil))
    r2 = AgentsKanban::BoardRepo.new(db, tables: kb.tables, host: nohand, clock: -> { @now }, known: ->(_) { true })
    e = assert_raises(Invalid) { r2.fetch("g/r", by: "sys") }
    assert_match(/the stored board of g\/r no longer fits this host \(column human_check is a gate/, e.message)
    assert_match(/the board template no longer fits/, assert_raises(Invalid) { r2.fetch("new", by: "sys") }.message)
  end

  # THE MIGRATION: the template + every project's board from the legacy `workflows` rows (the first version) or the template
  def test_seed_carries_the_legacy_workflows_rows_over_and_drops_the_table
    r = repo # (the store's own seeding ran: a fresh host DB is simulated below by clearing the rows)
    legacy = :"#{KanbanTest::PREFIX}workflows"
    db.create_table(legacy) do
      primary_key :id
      String :project_slug, null: false, unique: true
      String :body, text: true, null: false
      String :updated_by, null: false
      Integer :updated_at, null: false
    end
    own = {
      "name" => "strict",
      "transitions" => [
        { "name" => "Start work", "from" => "todo", "to" => "doing", "by" => "any" },
        { "name" => "Approve", "from" => "human_check", "to" => "ready", "by" => "operator" },
      ],
    }
    db[legacy].insert(project_slug: "g/r", body: JSON.generate(own), updated_by: "op", updated_at: 500)
    db[:"#{KanbanTest::PREFIX}boards"].delete
    db[:"#{KanbanTest::PREFIX}board_columns"].delete
    db[:"#{KanbanTest::PREFIX}board_transitions"].delete
    rep = r.seed!(template: KanbanTest.board_hash("coding"), projects: %w[p g/r], by: "migration")
    assert_equal({ template: "created", created: %w[p g/r], from_workflows: ["g/r"], dropped_workflows: true }, rep)
    refute db.table_exists?(legacy)
    assert_equal coding, r.template
    assert_equal coding, r.fetch("p", by: "x")
    g = r.fetch("g/r", by: "x")
    assert_equal coding.keys, g.keys
    assert_equal own["transitions"], g.to_h["transitions"]
    assert_equal ["op", AgentsKanban::Store.iso(500)], r.json("g/r", by: "x").values_at(:updated_by, :updated)
    assert_equal({ template: "kept", created: [], from_workflows: [], dropped_workflows: false },
                 r.seed!(template: KanbanTest.board_hash("coding"), projects: %w[p], by: "again"))
  end
end
