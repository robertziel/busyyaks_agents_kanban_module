# frozen_string_literal: true

require "test_helper"

# A LEAD IS NEVER A CARD'S ASSIGNEE (card 612): the lead owns what it adopts (its pings reach it, it routes them) but
# only workers are assignees. A card in a column a lead takes, open and unflagged, with no assignee WAITS FOR A WORKER:
# its face and the board header say so, the waiting list lists it apart (`workerless`, never needs-you), and the lead
# gives it to an idle worker (kanban_assign_worker) or starts one (kanban_spawn). Waiting worker_watch.wait_minutes →
# the lead is pinged once and the card counts as waiting for the operator. Schema v17 clears every lead assignee.
class LeadUnassignableTest < Minitest::Test
  include KanbanTest::Setup

  class FakeLauncher
    attr_reader :keys

    def initialize = (@n = 0; @keys = {})
    def name(project:, base:) = "#{base}_#{@n += 1}"

    def start(**kw)
      @keys[kw[:session]] = kw[:lead_key] if kw[:lead_key]
      { "ok" => true }
    end

    def lead_key(session:)
      @keys.fetch(session) { raise AgentsKanban::Delivery::Refused, "#{session}: no lead this launcher started" }
    end
  end

  def raw_config(wait = 15)
    raw = JSON.parse(File.read(File.join(KanbanTest::ROOT, "fixtures/boards/coding.json")))
    raw["table_prefix"] = KanbanTest::PREFIX
    raw["worker_watch"] = { "wait_minutes" => wait }
    raw["agent_types"] << {
      "key" => "worker", "label" => "Worker", "launchers" => %w[fullclaude localclaude],
      "model" => { "fullclaude" => "opus", "localclaude" => nil }, "under" => "lead",
      "prompt" => "Worker {session} for {slug}: you own {cards}.",
      "agent_name" => "worker-{session}", "session_name" => "{slug}_worker",
      "takes" => [], "max" => 4, "max_per_project" => nil,
    }
    raw
  end

  def config = (@cfg ||= AgentsKanban::HostConfig.new(raw_config))

  def setup
    super
    @projects = { "g/r" => { slug: "g/r", path: "/tmp", remote: nil },
"o/other" => { slug: "o/other", path: "/tmp", remote: nil }, }
    @live = []
    @l = FakeLauncher.new
    @api = AgentsKanban::Api.new(store: kb, attachments: nil, markdown: md, projects: ->(s) { @projects[s] },
                                 sessions: -> { @live }, launcher: @l, grace: 0)
    @tools = AgentsKanban::Tools.new(store: kb, attachments: nil, projects: ->(s) { @projects[s] },
                                     sessions: -> { @live }, card_url: CARD_URL, grace: 0, launcher: @l)
  end

  def lead!(slug = "g/r")
    s, j = @api.launch(slug, { "type" => "lead", "launcher" => "localclaude" }, by: "op")
    assert_equal 201, s, j.inspect
    @live << j[:session]
    j[:session]
  end

  # a worker registered by hand under the running lead (kanban_register), alive
  def worker!(name, slug = "g/r")
    @live << name
    JSON.parse(@tools.call("kanban_register", { "project" => slug, "type" => "worker", "tmux_session" => name,
                                                "author" => "worker-#{name}", "launcher" => "localclaude", }))
  end

  def face(id) = kb.card_json(kb.card(id))
  def call(name, args) = JSON.parse(@tools.call(name, args.transform_keys(&:to_s)))
  def refused(name, args) = assert_raises(AgentsKanban::Denied) { @tools.call(name, args.transform_keys(&:to_s)) }.message
  def assign(id, worker, lead)
    call("kanban_assign_worker", id: id, worker_session: worker, tmux_session: lead, author: "claude-#{lead}")
  end

  # ── 1. no lead assignee ─────────────────────────────────────────────────────────────────────────

  def test_no_write_makes_a_lead_a_cards_assignee
    todo = kb.create(slug: "g/r", title: "station", by: "op", column: "todo")
    lead = lead!
    assert_equal [lead, nil], kb.card(todo).values_at(:owner_session, :assignee), "adoption owns, never assigns"
    assert_match(/adopted by claude-#{lead} .* · waiting for a worker/, kb.activity(todo).last[:body])
    # kanban_claim by the lead's session, or naming the lead as assignee from another session
    m = refused("kanban_claim", id: todo, assignee: "claude-#{lead}", tmux_session: lead)
    assert_match(/session #{lead} is a lead and cannot claim card ##{todo}: a lead is never a card's assignee \(card 612\)/, m)
    worker!("w_1")
    m = refused("kanban_claim", id: todo, assignee: "claude-#{lead}", tmux_session: "w_1")
    assert_match(/claude-#{lead} is a lead and cannot claim/, m)
    # the operator's assignee edit, and an operator-made card naming the lead
    e = assert_raises(AgentsKanban::Denied) { kb.update(todo, { "assignee" => "claude-#{lead}" }, by: "op") }
    assert_match(/claude-#{lead} is a lead: a lead is never a card's assignee/, e.message)
    e = assert_raises(AgentsKanban::Denied) { kb.create(slug: "g/r", title: "x", by: "op", assignee: lead) }
    assert_match(/#{lead} is a lead/, e.message)
    # review round 1: an owner given (an agent's card) never lets a lead assignee through — refused, never dropped
    e = assert_raises(AgentsKanban::Denied) do
      kb.create(slug: "g/r", title: "x", by: "claude-#{lead}", owner_session: lead, assignee: "claude-#{lead}")
    end
    assert_match(/claude-#{lead} is a lead/, e.message)
    # kanban_create by the lead: owned by it, no assignee (in Backlog: agents create there only)
    c = call("kanban_create", project: "g/r", title: "made by the lead", author: "claude-#{lead}")
    assert_equal [lead, nil], c.values_at("owner_session", "assignee")
    # a lead registration started for a card is refused, naming the rule
    e = assert_raises(AgentsKanban::Denied) do
      kb.register_session(session: "lead_x", project: "o/other", type: "lead", launcher: "localclaude", by: "op",
                          for_cards: [todo])
    end
    assert_match(/a lead session is not started for a card: a lead is never a card's assignee/, e.message)
    assert_nil kb.open_session("lead_x"), "nothing registered"
    # the assignee pass never fills a lead owner's empty assignee
    assert_empty kb.adopt_ownerless(live: @live.to_set)
    assert_nil kb.card(todo)[:assignee]
    # a lead asking on an ownerless card owns it, unassigned
    q = kb.create(slug: "g/r", title: "q", by: "op", column: "doing")
    asked = call("kanban_ask", id: q, question: "which?", author: "claude-#{lead}", tmux_session: lead)
    assert_equal [lead, nil, true], asked.values_at("owner_session", "assignee", "needs_operator")
  end

  # ── 2. waiting for a worker: card face, board header, waiting list ─────────────────────────────

  def test_a_card_with_no_worker_waits_for_one_and_is_not_needs_you
    todo = kb.create(slug: "g/r", title: "station", by: "op", column: "todo")
    parked = kb.create(slug: "g/r", title: "parked", by: "op", column: "backlog")
    lead = lead!
    face = face(todo)
    assert_equal({ since: nil, stale: nil }, face[:waiting_for_worker])
    assert_equal false, face[:waiting]
    assert_nil face(parked)[:waiting_for_worker], "Backlog is no column a lead takes"
    kb.worker_watch_pass(live: @live.to_set, grace: 0)
    assert_equal Time.at(@now).iso8601, face(todo)[:waiting_for_worker][:since]
    board = @api.board("g/r")[1]
    assert_equal [1, 0], board.values_at(:workerless, :waiting)
    boards = @api.boards(@projects.values)[1]
    assert_equal 1, boards[:workerless]
    w = @api.waiting(@projects.values)[1]
    assert_equal [0, []], w.values_at(:total, :projects), "never needs-you"
    assert_equal [["g/r", [todo]]], w[:workerless].map { |g| [g[:slug], g[:cards].map { |c| c[:id] }] }
    assert_equal({ since: Time.at(@now).iso8601, stale: nil }, w[:workerless].first[:cards].first[:waiting_for_worker])
    # a flagged card waits for the operator, not for a worker
    call("kanban_ask", id: todo, question: "?", author: "claude-#{lead}", tmux_session: lead)
    assert_nil face(todo)[:waiting_for_worker]
    assert_equal 0, @api.board("g/r")[1][:workerless]
  end

  # ── 3. dispatch: an idle worker or a new one ───────────────────────────────────────────────────

  def test_the_lead_gives_a_waiting_card_to_an_idle_worker
    a = kb.create(slug: "g/r", title: "A", by: "op", column: "todo")
    b = kb.create(slug: "g/r", title: "B", by: "op", column: "doing")
    kb.comment(a, body: "start with the docs", author: "operator@example.com", operator: true)
    lead = lead!
    worker!("w_1")
    worker!("w_2")
    view = call("kanban_board", project: "g/r")["dispatch"]
    assert_equal [[a, b], lead, %w[w_1 w_2]], [view["waiting_for_worker"].sort, view["lead"],
                                                 view["idle_workers"].map { |r| r["session"] },]
    # only the lead (a worker calling is refused: no lead key for it)
    m = refused("kanban_assign_worker", id: a, worker_session: "w_1", tmux_session: "w_1", author: "worker-w_1")
    assert_match(/w_1 is not a lead this host started/, m)
    got = assign(a, "w_1", lead)
    assert_equal %w[w_1 worker-w_1], got.values_at("owner_session", "assignee")
    assert_nil got["waiting_for_worker"]
    assert_match(/assigned to worker-w_1 — session w_1 \(worker\), an idle worker, by the lead claude-#{lead}/,
                 kb.activity(a).map { |x| x[:body] }.join("\n"))
    ping = kb.pings(a).find { |p| p[:session] == "w_1" }
    assert_match(/is yours: the lead claude-#{lead} gave it to you/, ping[:text])
    assert_match(/start with the docs/, kb.pings(a).map { |p| p[:text] }.join("\n"), "the unheard comment relayed")
    # w_1 is busy now: not idle; the refusal names the idle ones
    m = refused("kanban_assign_worker", id: b, worker_session: "w_1", tmux_session: lead, author: "claude-#{lead}")
    assert_match(/w_1 is not an idle worker of g\/r .* idle now: w_2 \(worker\)/, m)
    # a card that has a worker is not waiting
    m = refused("kanban_assign_worker", id: a, worker_session: "w_2", tmux_session: lead, author: "claude-#{lead}")
    assert_match(/card ##{a} is not waiting for a worker: its assignee is worker-w_1/, m)
    # a worker that is not alive is not idle
    @live.delete("w_2")
    m = refused("kanban_assign_worker", id: b, worker_session: "w_2", tmux_session: lead, author: "claude-#{lead}")
    assert_match(/idle now: none: start one with kanban_spawn/, m)
    @live << "w_2"
    assert_equal "worker-w_2", assign(b, "w_2", lead)["assignee"]
    # a worker whose card is done is idle again
    kb.move(a, column: "merged", by: "op")
    assert_equal %w[w_1], call("kanban_board", project: "g/r")["dispatch"]["idle_workers"].map { |r| r["session"] }
    # another board's card is refused
    o = kb.create(slug: "o/other", title: "O", by: "op", column: "todo")
    m = refused("kanban_assign_worker", id: o, worker_session: "w_1", tmux_session: lead, author: "claude-#{lead}")
    assert_match(%r{card ##{o} is on o/other, not on g/r}, m)
  end

  def test_no_idle_worker_means_a_new_one_with_kanban_spawn
    id = kb.create(slug: "g/r", title: "A", by: "op", column: "doing")
    lead = lead!
    assert_empty call("kanban_board", project: "g/r")["dispatch"]["idle_workers"]
    r = call("kanban_spawn", id: id, type: "worker", tmux_session: lead, author: "claude-#{lead}")
    assert_equal [r["session"], "worker-#{r['session']}"], kb.card(id).values_at(:owner_session, :assignee)
    assert_empty call("kanban_board", project: "g/r")["dispatch"]["waiting_for_worker"]
  end

  def test_the_dispatch_view_says_when_the_live_sessions_cannot_be_read
    kb.create(slug: "g/r", title: "A", by: "op", column: "todo")
    down = AgentsKanban::Tools.new(store: kb, attachments: nil, projects: ->(s) { @projects[s] },
                                   sessions: -> { raise AgentsKanban::Delivery::Unavailable, "launcher down" },
                                   card_url: CARD_URL, grace: 0, launcher: @l)
    v = JSON.parse(down.call("kanban_board", { "project" => "g/r" }))["dispatch"]
    assert_nil v["idle_workers"]
    assert_match(/cannot read the live sessions: launcher down/, v["idle_error"])
    assert_equal 1, v["waiting_for_worker"].size
  end

  # ── 4. the watch ───────────────────────────────────────────────────────────────────────────────

  def test_a_card_waiting_too_long_pings_the_lead_once_and_then_waits_for_the_operator
    id = kb.create(slug: "g/r", title: "A", by: "op", column: "doing")
    lead = lead!
    live = @live.to_set
    assert_equal [[id, :waiting]], kb.worker_watch_pass(live: live, grace: 0)
    @now += (15 * 60) - 1
    assert_empty kb.worker_watch_pass(live: live, grace: 0)
    @now += 1
    before = kb.pings(id).size
    assert_equal [[id, :told]], kb.worker_watch_pass(live: live, grace: 0)
    told = kb.pings(id).first
    assert_equal [lead, "lead_dispatch"], told.values_at(:session, :reason)
    assert_match(/has waited 15 min for a worker and now counts as waiting for the operator/, told[:text])
    assert_equal before + 1, kb.pings(id).size
    assert_match(/no worker for 15 min — pinged the lead #{lead}; counts as waiting for the operator/,
kb.activity(id).last[:body])
    face = face(id)
    assert_equal [true, "no worker for 15 min (since #{Time.at(1_000).strftime('%H:%M')})"],
                 [face[:waiting], face[:waiting_for_worker][:stale]]
    w = @api.waiting(@projects.values)[1]
    assert_equal [1, []], [w[:total], w[:workerless]]
    assert_equal 1_000, kb.waiting_cards(["g/r"]).by_slug["g/r"].first[:since]
    @now += 3600
    assert_empty kb.worker_watch_pass(live: live, grace: 0), "once per wait"
    # a worker takes it: the wait is over and forgotten
    worker!("w_1")
    assign(id, "w_1", lead)
    assert_empty kb.worker_watch_pass(live: @live.to_set, grace: 0)
    assert_equal [nil, nil], kb.cards.where(id: id).get(%i[worker_wait_at worker_wait_told_at])
    assert_equal 0, @api.waiting(@projects.values)[1][:total]
    # its worker gone and released: it waits again from scratch
    kb.release_session_cards("w_1", reason: "gone", by: "op")
    kb.adopt_ownerless(live: @live.to_set)
    assert_equal [[id, :waiting]], kb.worker_watch_pass(live: @live.to_set, grace: 0)
  end

  def test_with_no_lead_running_the_watch_says_so_and_with_the_watch_off_nothing_escalates
    id = kb.create(slug: "g/r", title: "A", by: "op", column: "doing")
    kb.worker_watch_pass(live: Set[], grace: 0)
    @now += 15 * 60
    assert_equal [[id, :told_nobody]], kb.worker_watch_pass(live: Set[], grace: 0)
    assert_empty kb.pings(id)
    assert_match(/no lead runs to ping — press Launch/, kb.activity(id).last[:body])
    off = store(AgentsKanban::HostConfig.new(raw_config(nil)))
    other = off.create(slug: "g/r", title: "B", by: "op", column: "doing")
    off.worker_watch_pass(live: Set[], grace: 0)
    @now += 10 * 3600
    assert_empty off.worker_watch_pass(live: Set[], grace: 0)
    assert_nil off.card(other)[:waiting_for_worker][:stale]
    assert_equal false, off.card(other)[:waiting]
  end

  def test_the_notifier_runs_the_worker_watch
    id = kb.create(slug: "g/r", title: "A", by: "op", column: "doing")
    lead!
    client = Struct.new(:names) do
      def sessions = names.map { |n| { "name" => n } }
      def dialog(**) = nil
      def agents = raise(AgentsKanban::Delivery::Refused, "no collector")
    end.new(@live)
    log = StringIO.new
    n = AgentsKanban::Notifier.new(kb, client: client, ci: NoCi.new, clock: -> { @now }, grace: 0, log: log)
    n.watch
    @now += 15 * 60
    n.watch
    assert_match(/worker watch: card #{id} no worker yet, the lead pinged/, log.string)
  end

  def test_config_requires_worker_watch_and_checks_it
    raw = raw_config
    { raw.except("worker_watch") => /missing keys worker_watch/,
      raw.merge("worker_watch" => {}) => /worker_watch must be an object with exactly wait_minutes/,
      raw.merge("worker_watch" => { "wait_minutes" => 0 }) => /wait_minutes must be null \(off\) or an integer >= 1/,
      raw.merge("worker_watch" => { "wait_minutes" => "5" }) => /got "5"/, }.each do |bad, msg|
      assert_match msg, assert_raises(AgentsKanban::ConfigError) { AgentsKanban::HostConfig.new(bad) }.message
    end
    assert_equal 15, config.worker_watch.wait_minutes
    refute AgentsKanban::HostConfig.new(raw_config(nil)).worker_watch.on?
  end

  # ── 5. schema v17: every lead assignee cleared, the rollback refused ──────────────────────────────

  def test_schema_17_clears_every_lead_assignee_on_open_cards
    t = AgentsKanban::Schema.tables(KanbanTest::PREFIX)
    lead = lead!
    worker!("w_1")
    open = kb.create(slug: "g/r", title: "open", by: "op", column: "doing")
    done = kb.create(slug: "g/r", title: "done", by: "op", column: "merged")
    mine = kb.create(slug: "g/r", title: "worker's", by: "op", column: "doing")
    gone = kb.create(slug: "g/r", title: "archived", by: "op", column: "doing")
    db[t[:cards]].where(id: [open, done, gone]).update(assignee: "claude-#{lead}", owner_session: lead)
    db[t[:cards]].where(id: mine).update(assignee: "worker-w_1", owner_session: "w_1")
    db[t[:cards]].where(id: gone).update(archived_at: 5)
    e = assert_raises(ArgumentError) { AgentsKanban::Schema.lead_assignees!(db, prefix: KanbanTest::PREFIX) }
    assert_match(/lead_types: is required \(step 17\)/, e.message)
    AgentsKanban::Schema.lead_assignees_down!(db, prefix: KanbanTest::PREFIX) # nothing cleared yet: allowed
    assert_equal [open], AgentsKanban::Schema.lead_assignees!(db, prefix: KanbanTest::PREFIX, lead_types: ["lead"], now: 2_000)
    assert_equal [nil, lead], db[t[:cards]].where(id: open).get(%i[assignee owner_session])
    assert_equal "claude-#{lead}", db[t[:cards]].where(id: done).get(:assignee), "a finished card keeps its history"
    assert_equal "worker-w_1", db[t[:cards]].where(id: mine).get(:assignee)
    line = kb.activity(open).last
    assert_equal ["migration", "owner", 2_000], line.values_at(:author, :kind, :created_at)
    assert_match(/assignee cleared by the v17 migration: claude-#{lead} is a lead, and a lead is never a card's assignee/,
                 line[:body])
    assert_empty AgentsKanban::Schema.lead_assignees!(db, prefix: KanbanTest::PREFIX, lead_types: ["lead"]), "idempotent"
    e = assert_raises(ArgumentError) { AgentsKanban::Schema.lead_assignees_down!(db, prefix: KanbanTest::PREFIX) }
    assert_match(/step 17 cleared a lead assignee on cards #{open}: rolling back would restore a lead/, e.message)
    assert_includes db.schema(t[:cards]).map(&:first), :worker_wait_told_at
  end
end
