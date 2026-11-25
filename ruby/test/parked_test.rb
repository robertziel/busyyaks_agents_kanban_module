# frozen_string_literal: true

require "test_helper"

# PARKED COLUMNS ARE THE OPERATOR'S TO LEAVE. With "Prioritise" open to agents (by: any), a lead could move Backlog
# cards to To do and spawn a worker on each: work nobody asked for. The rule
# is now the column TYPE's (ColumnTypes operator_exit), so no workflow can open it: an agent never moves a card out of a
# parked column, never claims or spawns for one there, no agent type takes its cards, a workflow with an agent way out
# is refused on save and on load, and Schema v19 rewrote the stored boards that had one.
class ParkedTest < Minitest::Test
  include KanbanTest::Setup

  B = AgentsKanban::Board
  Denied = AgentsKanban::Denied
  Invalid = AgentsKanban::Invalid

  # The host's LAUNCH port: keeps the key of each lead it started; `named` counts the host asked for a session name.
  class FakeLauncher
    attr_reader :keys, :named

    def initialize = (@n = 0; @keys = {}; @named = 0)

    def name(project:, base:)
      @named += 1
      "#{base}_#{@n += 1}"
    end

    def start(**kw)
      @keys[kw[:session]] = kw[:lead_key] if kw[:lead_key]
      { "ok" => true }
    end

    def lead_key(session:) = @keys.fetch(session) { raise AgentsKanban::Delivery::Refused, "#{session}: not mine" }
  end

  def raw_config
    raw = JSON.parse(File.read(File.join(KanbanTest::ROOT, "fixtures/boards/coding.json")))
    raw["table_prefix"] = KanbanTest::PREFIX
    raw["agent_types"] << {
      "key" => "worker", "label" => "Worker", "launchers" => %w[fullclaude localclaude],
      "model" => { "fullclaude" => "opus", "localclaude" => nil }, "under" => "lead",
      "prompt" => "Worker {session} for {slug}: you own {cards}.",
      "agent_name" => "worker-{session}", "session_name" => "{slug}_worker",
      "takes" => [], "max" => nil, "max_per_project" => nil,
    }
    raw
  end

  def config = (@parked_config ||= AgentsKanban::HostConfig.new(raw_config))

  def setup
    super
    @root = Dir.mktmpdir("parked")
    @projects = { "g/r" => { slug: "g/r", path: @root, remote: nil } }
    @live = %w[tl_g_r]
    @l = FakeLauncher.new
    @api = AgentsKanban::Api.new(store: kb, attachments: nil, markdown: md, projects: ->(s) { @projects[s] },
                                 sessions: -> { @live }, launcher: @l, grace: 0)
    @tools = AgentsKanban::Tools.new(store: kb, attachments: nil, projects: ->(s) { @projects[s] },
                                     sessions: -> { @live }, card_url: CARD_URL, grace: 0, launcher: @l)
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def call(tool, args) = @tools.call(tool, args.transform_keys(&:to_s))
  def ok(tool, **args) = JSON.parse(call(tool, args))
  def err(tool, **args) = assert_raises(AgentsKanban::Denied, AgentsKanban::Invalid) { call(tool, args) }.message

  def col(key, type) = { "key" => key, "label" => key.capitalize, "type" => type }
  def edge(name, from, to, by) = { "name" => name, "from" => from, "to" => to, "by" => by }
  def board(transitions) = B.new({ "columns" => [col("ideas", "parked"), col("todo", "queued"), col("doing", "working"),
                                                  col("done", "done"),], "transitions" => transitions, }, host: config)

  def lead!
    s, j = @api.launch("g/r", { "type" => "lead", "launcher" => "localclaude" }, by: "op")
    assert_equal 201, s, j.inspect
    @live << j[:session]
    j[:session]
  end

  # ── 1. the type's rule, on the board ─────────────────────────────────────────────────────────────

  def test_the_parked_type_is_the_operators_to_leave_and_says_so
    t = AgentsKanban::ColumnTypes.fetch("parked")
    assert t.operator_exit
    assert_match(/only the operator moves a card out/, t.summary)
    assert_equal ["parked"], AgentsKanban::ColumnTypes::ALL.select(&:operator_exit).map(&:key)
    assert_equal ["backlog"], kb.board_of("g/r").rules[:operator_exit]
    j = ok("kanban_workflow", project: "g/r")
    assert_match(/only the operator moves a card out/, j["types"].find { |x| x["key"] == "parked" }["summary"])
    assert(j["types"].find { |x| x["key"] == "parked" }["operator_exit"])
  end

  def test_a_workflow_with_an_agent_way_out_of_a_parked_column_is_refused_naming_it
    { "agent" => "ideas", "any" => %w[ideas todo] }.each do |by, from|
      e = assert_raises(Invalid) { board([edge("Prioritise", from, "todo", by)]) }
      assert_match(/transitions\[0\] "Prioritise" \(by: #{by}\) leaves Ideas: only the operator moves a card out of a parked/,
                   e.message)
    end
    e = assert_raises(Invalid) { board([edge("Start", "todo", "doing", "any"), edge("Move", "*", "*", "any")]) }
    assert_match(/transitions\[1\] "Move" \(by: any\) leaves Ideas: .*make it by: operator \(its other sources in a /,
                 e.message)
    # the operator's way out, an agent's way IN (Deprioritise, a "*" into the parked column: no edge out of it)
    b = board([edge("Prioritise", "ideas", "todo", "operator"), edge("Shelve", %w[todo doing], "ideas", "any"),
               edge("Park", "*", "ideas", "agent"), edge("Move", %w[todo doing], "*", "any"),
               edge("Move", "ideas", "*", "operator"),])
    assert_empty b.workflow.from("ideas", actor: :agent)
    assert_equal %w[todo doing done], b.workflow.from("ideas", actor: :operator).map(&:to).uniq
  end

  def test_a_stored_board_with_an_agent_way_out_no_longer_loads
    db[:"#{KanbanTest::PREFIX}board_transitions"].where(project_slug: "", name: "Prioritise").update(by: "any")
    e = assert_raises(Invalid) { kb.board_of("g/r") }
    assert_match(/the board template no longer fits this host .*"Prioritise" \(by: any\) leaves Backlog/, e.message)
  end

  def test_an_operator_save_with_an_agent_way_out_is_refused
    shape = KanbanTest.board_hash
    shape["transitions"].find { |t| t["name"] == "Prioritise" }["by"] = "any"
    s, j = @api.board_shape_save("g/r", shape, by: "op")
    assert_equal 422, s
    assert_match(/"Prioritise" \(by: any\) leaves Backlog/, j[:error])
  end

  # ── 1. Store#move: an agent never moves a card out of a parked column ────────────────────────────

  def test_an_agent_never_moves_a_card_out_of_backlog_whatever_way_it_asks
    id = ok("kanban_create", project: "g/r", title: "idea", author: "agent-a", tmux_session: "tl_g_r")["id"]
    assert_equal "backlog", kb.card(id)[:column], "agents may still create in Backlog"
    %w[todo doing qa].each do |to|
      assert_match(/card ##{id} sits in Backlog: only the operator moves a card out of it — agents never prioritise/,
                   err("kanban_move", id: id, column: to, author: "agent-a"))
    end
    assert_match(/sits in Backlog: only the operator moves a card out/,
                 err("kanban_move", id: id, transition: "Prioritise", author: "agent-a"))
    assert_raises(Denied) { kb.move(id, column: "todo", by: "agent-a", agent: true) }
    assert_equal "backlog", kb.card(id)[:column]
    refute(kb.activity(id).any? { |a| a[:kind] == "move" }, "nothing moved")
    # a reorder inside Backlog stays; the operator moves it out; an agent may shelve a card back into Backlog
    assert_equal "backlog", ok("kanban_move", id: id, column: "backlog", position: 0, author: "agent-a")["column"]
    assert_equal "todo", kb.move(id, transition: "Prioritise", by: "op")[:column]
    assert_equal "backlog", ok("kanban_move", id: id, column: "backlog", author: "agent-a")["column"]
  end

  def test_an_agent_creates_cards_in_backlog_only
    %w[todo doing qa].each do |col|
      assert_match(/agents create cards only in Backlog: the operator moves a card into the work flow/,
                   err("kanban_create", project: "g/r", title: "x", author: "agent-a", tmux_session: "tl_g_r", column: col))
    end
    assert_equal "backlog", ok("kanban_create", project: "g/r", title: "x", author: "agent-a", tmux_session: "tl_g_r")["column"]
    assert_equal "todo", kb.create(slug: "g/r", title: "op's", by: "op", column: "todo").then { |i| kb.card(i)[:column] }
  end

  # dependencies: only the operator's finish of a parent promotes its parked children (content board: Waiting → Queued)
  def test_only_the_operators_finish_promotes_parked_children
    s = store(KanbanTest.config("content"))
    by_agent = s.create(slug: "p", title: "parent 1", by: "op", column: "queued")
    kid1 = s.create(slug: "p", title: "child 1", by: "lead", parent: by_agent)
    s.move(by_agent, column: "done", by: "worker", agent: true)
    assert_equal "waiting", s.card(kid1)[:column], "an agent's finish leaves the child parked"
    by_op = s.create(slug: "p", title: "parent 2", by: "op", column: "queued")
    kid2 = s.create(slug: "p", title: "child 2", by: "lead", parent: by_op)
    s.move(by_op, column: "done", by: "op")
    assert_equal "queued", s.card(kid2)[:column], "the operator's finish promotes it"
  end

  # ── 2. claim, spawn, adoption ─────────────────────────────────────────────────────────────────

  def test_no_agent_claims_a_parked_card
    id = kb.create(slug: "g/r", title: "idea", by: "op")
    assert_match(/card ##{id} sits in Backlog: no agent claims a parked card/,
                 err("kanban_claim", id: id, assignee: "agent-a", tmux_session: "tl_g_r"))
    assert_equal [nil, nil], kb.card(id).values_at(:assignee, :owner_session)
  end

  def test_the_lead_never_spawns_for_nor_adopts_a_parked_card
    parked = kb.create(slug: "g/r", title: "idea", by: "op")
    queued = kb.create(slug: "g/r", title: "work", by: "op", column: "todo")
    lead = lead!
    assert_equal [nil, lead], [parked, queued].map { |i| kb.card(i)[:owner_session] }, "the lead adopted To do only"
    named = @l.named
    e = assert_raises(Denied) do
      call("kanban_spawn", id: parked, type: "worker", tmux_session: lead, author: "claude-#{lead}")
    end
    assert_match(/card ##{parked} sits in Backlog: no agent spawns for a parked card/, e.message)
    assert_equal named, @l.named, "refused before the host was asked for a session"
    assert_equal 1, kb.sessions_t.where(project_slug: "g/r", ended_at: nil).count, "nothing registered"
    # the Store refuses it too (any spawn path): a registration for a parked card writes nothing
    e = assert_raises(Denied) do
      kb.register_session(session: "x_1", project: "g/r", type: "worker", by: "op", launcher: "localclaude",
                          for_cards: [parked], lead_id: kb.open_session(lead)[:id])
    end
    assert_match(/no agent spawns for a parked card/, e.message)
    assert_nil kb.card(parked)[:owner_session]
    # the operator moves it out: from then on it is the lead's, like any queued card
    kb.move(parked, column: "todo", by: "op")
    assert_equal lead, kb.card(parked)[:owner_session]
  end

  def test_no_agent_type_takes_parked_cards
    raw = raw_config
    raw["agent_types"].find { |t| t["key"] == "lead" }["takes"] = %w[parked queued]
    e = assert_raises(AgentsKanban::ConfigError) { AgentsKanban::HostConfig.new(raw) }
    assert_match(/agent_types\[lead\]\.takes: parked — only the operator moves a card out of a parked column; no agent/,
                 e.message)
  end

  # ── 3. the agents' instructions ───────────────────────────────────────────────────────────────

  def test_the_mcp_instructions_and_kanban_move_say_it
    assert_match(/Only the operator moves a card out of Backlog: never prioritise, claim, spawn for or start a card there/,
                 @tools.instructions)
    assert_match(/your new cards start there and only there/, @tools.instructions)
    assert_match(/"Push" or "update tickets" means the cards already past Backlog/, @tools.instructions)
    move = @tools.definitions.find { |d| d[:name] == "kanban_move" }
    assert_match(/Only the operator moves a card out of Backlog, whatever the workflow says/, move[:description])
  end

  # ── 5. Schema v19: the stored boards ──────────────────────────────────────────────────────────

  def test_v19_makes_every_stored_way_out_of_a_parked_column_the_operators
    kb.board_of("g/r") # the project's own rows
    t = :"#{KanbanTest::PREFIX}board_transitions"
    db[t].where(name: "Prioritise").update(by: "any")
    db[t].where(name: "Move", by: "operator").delete # back to the old catch-all, free for agents
    db[t].where(name: "Move").update(by: "any", from_keys: JSON.generate("*"))
    @now = 5_000
    changed = AgentsKanban::Schema.parked_exits!(db, prefix: KanbanTest::PREFIX, now: @now)
    assert_equal ["", "g/r"], changed.sort, "the template and the project"
    %w[g/r].each do |slug|
      b = kb.board_of(slug)
      assert_empty b.workflow.from("backlog", actor: :agent)
      tr = b.to_h["transitions"]
      assert_equal "operator", tr.find { |x| x["name"] == "Prioritise" }["by"]
      moves = tr.select { |x| x["name"] == "Move" }.map { |x| x.values_at("from", "by") }
      assert_equal [[b.keys - ["backlog"], "any"], %w[backlog operator]], moves
      assert_equal (b.keys - ["todo"]).sort, b.workflow.from("todo", actor: :agent).map(&:to).uniq.sort,
                   "agents keep the catch-all everywhere else (into Backlog too)"
    end
    row = db[:"#{KanbanTest::PREFIX}boards"].where(project_slug: "g/r").first
    assert_equal ["migration", 5_000], row.values_at(:updated_by, :updated_at)
    assert_empty AgentsKanban::Schema.parked_exits!(db, prefix: KanbanTest::PREFIX), "idempotent"
  end

  def test_v19_never_doubles_an_operator_edge_that_already_leaves
    kb.board_of("g/r")
    t = :"#{KanbanTest::PREFIX}board_transitions"
    db[t].where(project_slug: "g/r", name: "Prioritise").update(by: "agent")
    db[t].insert(project_slug: "g/r", position: 99, name: "prioritise", from_keys: JSON.generate("*"), to_key: "todo",
                 by: "operator")
    AgentsKanban::Schema.parked_exits!(db, prefix: KanbanTest::PREFIX)
    names = kb.board_of("g/r").to_h["transitions"].map { |x| x["name"] }
    assert_equal [0, 1], [names.count("Prioritise"), names.count("prioritise")],
                 "the agent's Prioritise is dropped: the operator's covers backlog → todo already"
    assert_empty kb.board_of("g/r").workflow.from("backlog", actor: :agent)
  end
end
