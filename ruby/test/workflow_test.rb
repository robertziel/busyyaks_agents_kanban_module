# frozen_string_literal: true

require "test_helper"

# Workflows (SPEC § 2): the named transitions of a project's BOARD, kept in the database with its columns
# (board_transitions; the template's copy until the operator saves the project's own). Validated as part of the Board;
# a move off the graph is refused with the edges there are. Agents read it (Tools kanban_workflow), never write it.
class WorkflowTest < Minitest::Test
  include KanbanTest::Setup
  Invalid = AgentsKanban::Invalid
  Denied = AgentsKanban::Denied

  STRICT = [
      { "name" => "Prioritise", "from" => "backlog", "to" => "todo", "by" => "any" },
      { "name" => "Shelve", "from" => "todo", "to" => "backlog", "by" => "any" },
      { "name" => "Start work", "from" => "todo", "to" => "doing", "by" => "any" },
      { "name" => "Send for review", "from" => "doing", "to" => "qa", "by" => "agent" },
      { "name" => "Fixes needed", "from" => "qa", "to" => "doing", "by" => "any" },
      { "name" => "Hand over", "from" => %w[doing qa], "to" => "human_check", "by" => "agent" },
      { "name" => "Approve", "from" => "human_check", "to" => "ready", "by" => "operator" },
      { "name" => "Merge", "from" => "ready", "to" => "merged", "by" => "any" },
  ].freeze

  def handoff_args
    {
      qa: "Open the page at 375 and 1280 px and check the row",
      pr_url: "https://github.com/o/r/pull/1",
      ci_url: "https://ci.example.com/job/r/1/",
      ui_change: false,
    }
  end

  def shape = KanbanTest.board_hash("coding")
  def strict! = kb.board_save("g/r", shape.merge("transitions" => STRICT), by: "op")
  def workflow(h) = AgentsKanban::Workflow.new(h, keys: kb.board_of("g/r").keys)

  # ── the value object ──────────────────────────────────────────────────────────────────────────

  def test_a_workflow_keeps_what_was_declared_and_expands_the_edges
    w = workflow(STRICT)
    assert_equal STRICT, w.to_a # declared, not expanded: what the editor shows and the rows store
    assert_equal %w[human_check qa], w.from("doing").map(&:to).sort
    assert_equal ["Send for review"], w.from("doing", actor: :agent).select { |e| e.to == "qa" }.map(&:name)
    assert_empty w.from("doing", actor: :operator).select { |e| e.to == "qa" }
  end

  def test_a_bad_workflow_is_refused_with_the_reason
    bad = lambda do |h, msg|
      e = assert_raises(AgentsKanban::Invalid) { workflow(h) }
      assert_match msg, e.message
    end
    go = { "name" => "Go", "from" => "todo", "to" => "doing", "by" => "any" }
    bad.call(nil, /transitions must be a list/)
    bad.call([go.merge("extra" => 1)], /transitions\[0\] must be an object with exactly/)
    bad.call([go.merge("to" => "nope")], /transitions\[0\]\.to/)
    bad.call([go.merge("by" => "bot")], /by must be one of operator, agent, any/)
    bad.call([go.merge("to" => %w[doing qa])], /one column/)
    bad.call([go, go.merge("to" => "qa")], /one name, one target/)
    bad.call([go, go], /duplicate transition/)
    bad.call([go.merge("name" => "")], /name must match/)
    assert_equal [], workflow([]).edges # an empty list is a board nobody can move on — allowed, the editor's starting point
  end

  # ── kept in the database, per project (with the columns: board_test.rb has the repository) ──────

  def test_save_validates_and_stores_the_projects_own_transitions
    j = strict!
    assert_equal [STRICT, "op"], [j[:transitions], j[:updated_by]]
    assert_equal STRICT, store.board_of("g/r").to_h["transitions"] # a fresh store reads it back: the database, not memory
    assert_equal shape["transitions"], kb.board_of("p").to_h["transitions"] # other projects: the template's
    bad = [{ "name" => "X", "from" => "nope", "to" => "todo", "by" => "any" }]
    assert_raises(Invalid) { kb.board_save("g/r", shape.merge("transitions" => bad), by: "op") }
    assert_equal STRICT, kb.board_of("g/r").to_h["transitions"] # a refused save changes nothing
    assert_equal shape["transitions"], kb.board_reset("g/r", by: "op")[:transitions]
    assert_raises(Invalid) { kb.board_save("nope", shape, by: "op") } # no such board
  end

  # ── the moves it governs ──────────────────────────────────────────────────────────────────────

  def test_a_strict_workflow_refuses_a_move_with_no_edge_and_lists_the_edges
    strict!
    id = kb.create(slug: "g/r", title: "a", by: "op")
    e = assert_raises(Denied) { kb.move(id, column: "doing", by: "op") }
    assert_match(
      /workflow: no transition Backlog → In progress for the operator\. Allowed from Backlog: Prioritise → To do/,
      e.message,
    )
    kb.move(id, column: "todo", by: "op")
    assert_equal "doing", kb.move(id, column: "doing", by: "op")[:column]
  end

  def test_a_transition_name_picks_the_target_and_a_disagreeing_column_is_refused
    strict!
    id = kb.create(slug: "g/r", title: "a", by: "op", column: "todo")
    assert_raises(Denied) { kb.move(id, column: "qa", transition: "Start work", by: "op") }
    assert_equal "doing", kb.move(id, transition: "start work", by: "op")[:column]
    e = assert_raises(Denied) { kb.move(id, transition: "Merge", by: "op") }
    assert_match(/no transition "Merge" from In progress for the operator \(none\)/, e.message)
    assert_raises(Invalid) { kb.move(id, by: "op") }
  end

  def test_who_may_take_an_edge
    strict!
    id = kb.create(slug: "g/r", title: "a", by: "op", column: "doing")
    assert_equal "qa", kb.move(id, transition: "Send for review", by: "tl_a", agent: true)[:column]
    other = kb.create(slug: "g/r", title: "b", by: "op", column: "doing")
    assert_match(/for the operator/, assert_raises(Denied) { kb.move(other, transition: "Send for review", by: "op") }.message)
  end

  def test_gated_moves_need_their_edge_and_the_gate_still_applies_first
    strict!
    id = kb.create(slug: "g/r", title: "a", by: "op", column: "doing")
    assert_raises(Denied) { kb.move(id, column: "human_check", by: "tl_a", agent: true) } # gate: kanban_handoff only
    assert_equal "human_check", kb.handoff(id, by: "tl_a", **handoff_args)[:column]
    assert_equal "ready", kb.approve(id, by: "op")[:column]
    assert_equal "merged", kb.move(id, transition: "Merge", by: "tl_a", agent: true)[:column]
  end

  def test_the_default_keeps_the_board_free
    id = kb.create(slug: "g/r", title: "a", by: "op")
    assert_equal "merged", kb.move(id, column: "merged", by: "op")[:column]
  end

  def test_card_json_lists_the_transitions_out_of_its_column_and_the_board_reads_the_workflow_once
    strict!
    ids = Array.new(3) { |i| kb.create(slug: "g/r", title: "c#{i}", by: "op", column: "todo") }
    assert_equal ["Shelve", "Start work"], kb.card_json(kb.card(ids[0]))[:transitions].map { |t| t[:name] }.sort
    reads = 0
    l = Object.new.tap do |o|
      o.define_singleton_method(:method_missing) { |_m, *a| reads += 1 if a.first.to_s.include?("board_transitions") }
      o.define_singleton_method(:respond_to_missing?) { |*| true }
    end
    db.loggers << l
    kb.board("g/r")["todo"].each { |c| kb.card_json(c) }
    db.loggers.delete(l)
    assert_operator reads, :<=, 1
    plain = store(KanbanTest.config("content"))
    other = plain.create(slug: "p", title: "x", by: "op")
    # the content board's catch-all
    assert_equal ["Move"], plain.card_json(plain.card(other))[:transitions].map { |t| t[:name] }.uniq
  end

  # a handoff the workflow refuses leaves NOTHING behind (no handoff fields, no log); a question is a FLAG and needs no
  # edge — the card stays where it is
  def test_a_handoff_the_workflow_refuses_writes_nothing_and_an_ask_needs_no_edge
    transitions = [
      { "name" => "Start work", "from" => "todo", "to" => "doing", "by" => "any" },
      { "name" => "Approve", "from" => "human_check", "to" => "ready", "by" => "operator" },
    ]
    kb.board_save("g/r", shape.merge("transitions" => transitions), by: "op")
    id = kb.create(slug: "g/r", title: "a", by: "op", column: "doing")
    kb.claim(id, assignee: "tl_a", session: "tl_a")
    before = db[:"#{KanbanTest::PREFIX}card_activity"].where(card_id: id).count
    e = assert_raises(Denied) { kb.handoff(id, by: "tl_a", **handoff_args) }
    assert_match(/no transition from In progress into a gate for an agent — the board's gates: Human Check \(human_check\)/,
                 e.message)
    e = assert_raises(Denied) { kb.handoff(id, by: "tl_a", column: "human_check", **handoff_args) }
    assert_match(/workflow: no transition In progress → Human Check for an agent/, e.message)
    c = kb.card(id)
    assert_equal ["doing", nil, nil, nil, nil], [c[:column], c[:question], c[:asked_by], c[:handoff_at], c[:pr_url]]
    assert_equal before, db[:"#{KanbanTest::PREFIX}card_activity"].where(card_id: id).count
    asked = kb.ask(id, question: "Which one?", by: "tl_a")
    assert_equal ["doing", "Which one?", true], [asked[:column], asked[:question], kb.card_json(asked)[:needs_operator]]
  end

  # "one name, one target" is case-insensitive, like the lookup
  def test_names_differing_only_in_case_are_one_name
    go = { "name" => "Go", "from" => "todo", "to" => "doing", "by" => "any" }
    e = assert_raises(Invalid) { workflow([go, go.merge("name" => "go")]) }
    assert_match(/duplicate transition/, e.message) # same target too: one name
    e = assert_raises(Invalid) { workflow([go, go.merge("name" => "go", "to" => "qa")]) }
    assert_match(/one name, one target/, e.message)
  end

  # a fan-out "*" edge is named together with its column
  def test_a_fan_out_name_needs_the_column
    id = kb.create(slug: "g/r", title: "a", by: "op", column: "todo")
    assert_match(/give the column too/, assert_raises(Invalid) { kb.move(id, transition: "Move", by: "op") }.message)
    assert_equal "qa", kb.move(id, transition: "Move", column: "qa", by: "op")[:column]
  end
end
