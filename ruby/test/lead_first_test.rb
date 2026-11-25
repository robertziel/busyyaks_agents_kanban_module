# frozen_string_literal: true

require "test_helper"
require "shellwords"

# LEAD-FIRST BOARDS: a board starts with its lead — the operator's Launch — and only the lead starts its
# team. A session of a type `under` the lead type exists only under the board's RUNNING lead: the operator's launch
# while it runs, or the lead's own kanban_spawn (with its lead key); it runs the lead's launcher and carries the lead's
# registration id (the DB refuses the row without one). The engine starts nobody on its own: an ownerless card is the
# lead's (its `takes`), and with no lead it waits — the board and the waiting list say "no lead".
class LeadFirstTest < Minitest::Test
  include KanbanTest::Setup

  # The host's LAUNCH port: it keeps the key of each lead it started (like bin/launcher's state) and gives it back by
  # session only — a test sets keys[s] to play a stale / wrong key.
  class FakeLauncher
    attr_reader :started, :keys
    attr_accessor :fail, :fixed_name

    def initialize = (@started = []; @n = 0; @keys = {})
    # fixed_name: the name a host gave a session before the host's session_name changed (an old registration)
    def name(project:, base:) = fixed_name || "#{base}_#{@n += 1}"

    def start(**kw)
      raise AgentsKanban::Delivery::Refused, "tmux failed: no server" if @fail

      @started << kw
      @keys[kw[:session]] = kw[:lead_key] if kw[:lead_key]
      { "ok" => true }
    end

    def lead_key(session:)
      @keys.fetch(session) { raise AgentsKanban::Delivery::Refused, "#{session}: no lead this launcher started" }
    end
  end

  def raw_config
    raw = JSON.parse(File.read(File.join(KanbanTest::ROOT, "fixtures/boards/coding.json")))
    raw["table_prefix"] = KanbanTest::PREFIX
    raw["agent_types"] << {
      "key" => "worker", "label" => "Worker", "launchers" => %w[fullclaude localclaude],
      "model" => { "fullclaude" => "opus", "localclaude" => nil }, "under" => "lead",
      "prompt" => "Worker {session} for {slug}: you own {cards}.",
      "agent_name" => "worker-{session}", "session_name" => "{slug}_worker",
      "takes" => [], "max" => 2, "max_per_project" => nil,
    }
    raw
  end

  def config = (@lead_config ||= AgentsKanban::HostConfig.new(raw_config))

  def setup
    super
    @root = Dir.mktmpdir("lead-first")
    @projects = {
      "g/r" => { slug: "g/r", path: @root, remote: nil },
      "o/other" => { slug: "o/other", path: @root, remote: nil },
    }
    @live = []
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

  def words(argv) = argv.first == "bash" ? Shellwords.split(argv.last) : argv

  # The operator's Launch of the board's lead → [session, the key the host's launcher keeps for it]
  def lead!(launcher = "localclaude", slug: "g/r")
    s, j = @api.launch(slug, { "type" => "lead", "launcher" => launcher }, by: "op")
    assert_equal 201, s, j.inspect
    @live << j[:session]
    [j[:session], @l.keys.fetch(j[:session])]
  end

  def spawn(id, session, type: "worker")
    JSON.parse(@tools.call("kanban_spawn", { "id" => id, "type" => type, "tmux_session" => session,
                                             "author" => "claude-#{session}", }))
  end

  # ── config ────────────────────────────────────────────────────────────────────────────────────

  def test_config_refuses_the_removed_spawn_keys_and_validates_under_and_standalone
    bad = lambda do |mut|
      r = raw_config
      mut.(r["agent_types"].find { |t| t["key"] == "worker" }, r)
      assert_raises(AgentsKanban::ConfigError) { AgentsKanban::HostConfig.new(r) }.message
    end
    { "spawns_for" => ["queued"], "spawn_launcher" => "fullclaude", "launcher_follows" => "lead" }.each do |k, v|
      assert_match(/agent_types\[worker\].#{k} is removed: .*lead-first boards/, bad.(->(w, _) { w[k] = v }))
    end
    assert_match(/agent_types\[worker\].under: no agent type "boss" \(lead, team, plain, worker\)/,
                 bad.(->(w, _) { w["under"] = "boss" }))
    assert_match(/under must name another type/, bad.(->(w, _) { w["under"] = "worker" }))
    assert_match(/under must be an agent type key or null/, bad.(->(w, _) { w["under"] = 3 }))
    assert_match(/worker\].under: team is itself under lead \(one lead level only\)/,
                 bad.(->(w, _) { w["under"] = "team" }))
    assert_match(/lead runs localclaude, which worker.launchers lacks/,
                 bad.(->(w, _) { w["launchers"] = ["fullclaude"]; w["model"] = "opus" }))
    assert_match(/the lead type lead must have max_per_project: 1/,
                 bad.(->(_, r) { r["agent_types"][0]["max_per_project"] = 2 }))
    # review round 1 (blocker): no type runs leaderless by omission — under a lead, or a declared standalone PLAIN one
    assert_match(/agent_types\[worker\] runs without a lead: give it `under: <lead type>` \(lead\), or `standalone: true`/,
                 bad.(->(w, _) { w.delete("under") }))
    assert_match(/agent_types\[worker\]: a standalone type is a plain session — prompt null and takes \[\]/,
                 bad.(->(w, _) { w.delete("under"); w["standalone"] = true }))
    assert_match(/agent_types\[worker\]: a standalone type is a plain session/,
                 bad.(->(w, _) { w.delete("under"); w.merge!("standalone" => true, "prompt" => nil, "takes" => ["queued"]) }))
    assert_match(/standalone and under exclude each other/, bad.(->(w, _) { w["standalone"] = true }))
    assert_match(/standalone must be true or false/, bad.(->(w, _) { w["standalone"] = "yes" }))
    assert_match(/agent_types\[plain\] runs without a lead/,
                 bad.(->(_, r) { r["agent_types"].find { |t| t["key"] == "plain" }.delete("standalone") }))
    assert_match(/team\].under: lead is standalone/,
                 bad.(->(_, r) { r["agent_types"][0].merge!("standalone" => true, "prompt" => nil, "takes" => []) }))
    assert config.agent_type("plain").standalone
    refute config.agent_type("worker").standalone
    assert_equal %w[lead], config.lead_types.map(&:key)
    assert config.lead_type?(config.agent_type("lead"))
    refute config.lead_type?(config.agent_type("plain"))
    w = config.agent_type("worker")
    assert_equal ["lead", "opus", nil], [w.under, w.model_for("fullclaude"), w.model_for("localclaude")]
  end

  def test_a_type_with_several_launchers_and_none_named_is_refused
    e = assert_raises(AgentsKanban::Invalid) { config.agent_type("plain").launcher!(nil) }
    assert_equal "agent type plain runs fullclaude, localclaude — name the launcher this session was started with",
                 e.message
    assert_equal "localclaude", config.agent_type("plain").launcher!("localclaude")
  end

  # ── the operator's launches ───────────────────────────────────────────────────────────────────

  def test_no_lead_means_no_worker_and_no_sub_team_from_the_operator_either
    %w[worker team].each do |type|
      s, j = @api.launch("g/r", { "type" => type, "launcher" => "fullclaude" }, by: "op")
      assert_equal 422, s
      assert_match(/no lead session runs for g\/r: a #{type} session runs only under the board's lead — launch the lead first/,
                   j[:error])
    end
    assert_empty @l.started
    assert_equal 0, kb.sessions_t.count, "nothing registered"
    s, j = @api.launch("g/r", { "type" => "plain", "launcher" => "fullclaude" }, by: "op")
    assert_equal [201, nil], [s, j[:lead]], "plain runs on its own"
  end

  def test_the_lead_key_goes_to_the_hosts_start_only_and_never_into_json
    s, j = @api.launch("g/r", { "type" => "lead", "launcher" => "localclaude" }, by: "op")
    assert_equal 201, s
    key = @l.started.last[:lead_key]
    assert_match(/\A\h{64}\z/, key)
    assert_nil @l.started.last[:lead], "a lead runs under nobody"
    refute_includes JSON.generate(j), key
    row = kb.open_session(j[:session])
    assert_equal Digest::SHA256.hexdigest(key), row[:lead_key_digest], "only the digest is stored"
    assert_equal [0, nil], row.values_at(:needs_lead, :lead_id)
    @live << j[:session]
    _, sessions = @api.sessions
    refute_includes JSON.generate(sessions), key
    refute_includes JSON.generate(sessions), row[:lead_key_digest]
    s, p = @api.launch("g/r", { "type" => "plain", "launcher" => "fullclaude" }, by: "op")
    assert_equal [201, nil], [s, @l.started.last[:lead_key]], "no other session gets a key (#{p[:session]})"
  end

  def test_the_operators_worker_runs_under_the_running_lead_on_its_launcher
    lead, = lead!("localclaude")
    s, j = @api.launch("g/r", { "type" => "worker" }, by: "op")
    assert_equal [201, "localclaude", lead], [s, j[:launcher], j[:lead]]
    st = @l.started.last
    assert_equal [lead, nil], [st[:lead], st[:lead_key]]
    assert_equal ["localclaude", "--remote-control", j[:session]], words(st[:argv])
    assert_equal [1, kb.open_session(lead)[:id]], kb.open_session(j[:session]).values_at(:needs_lead, :lead_id)
    s, j = @api.launch("g/r", { "type" => "team", "launcher" => "fullclaude" }, by: "op")
    assert_equal 422, s
    assert_match(/team sessions of g\/r run localclaude, the launcher of their lead session #{lead} .* fullclaude refused/,
                 j[:error])
    # another board's lead is not this board's
    s, = @api.launch("o/other", { "type" => "worker", "launcher" => "localclaude" }, by: "op")
    assert_equal 422, s
  end

  def test_launches_say_which_types_need_a_lead_and_who_leads
    _, j = @api.launches("g/r")
    team = j[:types].find { |t| t[:key] == "team" }
    assert_equal ["lead", nil], team.values_at(:under, :follows), "no lead: the bar greys it"
    lead, = lead!("localclaude")
    _, j = @api.launches("g/r")
    team = j[:types].find { |t| t[:key] == "team" }
    assert_equal({ type: "lead", session: lead, launcher: "localclaude" }, team[:follows])
    assert_nil j[:types].find { |t| t[:key] == "lead" }[:under]
  end

  def test_the_db_refuses_a_session_that_needs_a_lead_and_has_none
    assert_raises(Sequel::CheckConstraintViolation, Sequel::ConstraintViolation) do
      kb.sessions_t.insert(session: "w", socket: "default", project_slug: "g/r", type_key: "worker",
                           launcher_key: "fullclaude", agent_name: "worker-w", launched_by: "op", launched_at: @now,
                           needs_lead: 1, lead_id: nil)
    end
    e = assert_raises(AgentsKanban::Denied) do
      kb.register_session(session: "w", project: "g/r", type: "worker", launcher: "fullclaude", by: "op")
    end
    assert_match(/no lead session runs for g\/r/, e.message)
    e = assert_raises(AgentsKanban::Invalid) do
      kb.register_session(session: "p", project: "g/r", type: "plain", launcher: "fullclaude", by: "op", lead_id: 1)
    end
    assert_match(/runs under no lead/, e.message)
  end

  def test_a_new_lead_adopts_the_sessions_an_ended_lead_left_behind
    lead, = lead!
    _, w = @api.launch("g/r", { "type" => "worker" }, by: "op")
    @live << w[:session]
    @live.delete(lead)
    kb.sessions_sync(@live.to_set, grace: 0)
    assert_equal AgentsKanban::Store::GONE, kb.sessions_t.where(session: lead).get(:end_reason)
    lead2, = lead!
    assert_equal kb.open_session(lead2)[:id], kb.open_session(w[:session])[:lead_id]
  end

  def test_a_failed_start_ends_the_registration_and_is_a_launch_failure
    lead, = lead!
    @l.fail = true
    s, j = @api.launch("g/r", { "type" => "worker" }, by: "op")
    assert_equal [422, "tmux failed: no server"], [s, j[:error]]
    assert_equal [["g_r_worker_2", "worker", "tmux failed: no server"]],
                 kb.launch_failures(["g/r"]).map { |f| f.values_at(:session, :type, :reason) }
    refute kb.open_session("g_r_worker_2")
    assert kb.open_session(lead)
  end

  # ── kanban_spawn: the lead starts its team ────────────────────────────────────────────────────

  def test_the_lead_takes_ownerless_work_and_spawns_a_worker_that_owns_the_card
    id = kb.create(slug: "g/r", title: "station", by: "op", column: "todo")
    lead, key = lead!("localclaude")
    assert_equal lead, kb.card(id)[:owner_session], "the lead adopted the ownerless To do card"
    assert_equal [[lead, "##{id}"]], [[@l.started.last[:session], @l.started.last[:vars][:cards]]]
    r = spawn(id, lead)
    w = r["session"]
    assert_equal ["worker-#{w}", "localclaude", lead], r.values_at("agent", "launcher", "lead")
    assert_equal [w, "worker-#{w}", "todo"], kb.card(id).values_at(:owner_session, :assignee, :column)
    st = @l.started.last
    assert_equal ["worker", lead, "##{id}", nil], [st[:type], st[:lead], st[:vars][:cards], st[:lead_key]]
    assert_equal kb.open_session(lead)[:id], kb.open_session(w)[:lead_id]
    assert_match(/spawned for this card by the lead claude-#{lead}: worker-#{w}/, kb.activity(id).last[:body])
    @live << w
    assert_empty kb.adopt_ownerless(live: @live.to_set), "the worker's card stays the worker's"
  end

  def test_kanban_spawn_is_refused_to_anybody_but_a_lead_the_host_started
    id = kb.create(slug: "g/r", title: "x", by: "op", column: "todo")
    lead, key = lead!
    @live << "intruder"
    @l.keys[lead] = "0" * 64 # the host's key for it does not match the registration's (a stale / swapped session)
    e = assert_raises(AgentsKanban::Denied) { spawn(id, lead) }
    assert_match(/#{lead} is not a lead this host started/, e.message)
    @l.keys[lead] = key
    e = assert_raises(AgentsKanban::Denied) { spawn(id, "intruder") }
    assert_match(/intruder is not a lead this host started: intruder: no lead this launcher started/, e.message)
    @l.keys["intruder"] = key # another session handed the lead's key: its registration (none) does not match
    assert_raises(AgentsKanban::Denied) { spawn(id, "intruder") }
    _, w = @api.launch("g/r", { "type" => "worker" }, by: "op")
    @live << w[:session]
    assert_raises(AgentsKanban::Denied) { spawn(id, w[:session]) }
    e = assert_raises(AgentsKanban::Invalid) { spawn(id, lead, type: "plain") }
    assert_match(/agent type plain is not under lead/, e.message)
    other = kb.create(slug: "o/other", title: "elsewhere", by: "op", column: "backlog")
    e = assert_raises(AgentsKanban::Denied) { spawn(other, lead) }
    assert_match(/is on o\/other, not on g\/r/, e.message)
    kb.set_owner(id, session: w[:session], by: "op")
    e = assert_raises(AgentsKanban::Denied) { spawn(id, lead) }
    assert_match(/owned by #{w[:session]} — a lead spawns only for its own or ownerless cards/, e.message)
    assert_equal 2, @l.started.size, "nothing started by the refused calls"
  end

  def test_a_stale_key_dies_with_its_lead
    id = kb.create(slug: "g/r", title: "x", by: "op", column: "backlog")
    lead, key = lead!
    @live.delete(lead)
    kb.sessions_sync(@live.to_set, grace: 0)
    @live << lead
    assert_raises(AgentsKanban::Denied) { spawn(id, lead) }
  end

  def test_kanban_spawn_respects_the_caps_and_a_failed_start_releases_the_card
    lead, key = lead!
    ids = Array.new(3) { |i| kb.create(slug: "g/r", title: "c#{i}", by: "op", column: "backlog") }
    ids.first(2).each { |i| @live << spawn(i, lead)["session"] }
    e = assert_raises(AgentsKanban::Denied) { spawn(ids[2], lead) }
    assert_match(%r{2/2 worker sessions are running}, e.message)
    @l.fail = true
    kb.end_session(@live.pop, reason: "done", by: "op")
    e = assert_raises(AgentsKanban::Invalid) { spawn(ids[2], lead) }
    assert_match(/the host could not start the session: tmux failed/, e.message)
    assert_nil kb.card(ids[2])[:owner_session]
  end

  def test_kanban_spawn_needs_the_launcher_port_and_is_listed_only_with_a_lead_type
    t = AgentsKanban::Tools.new(store: kb, attachments: nil, projects: ->(s) { @projects[s] }, sessions: -> { @live },
                                card_url: CARD_URL)
    assert_includes t.definitions.map { |d| d[:name] }, "kanban_spawn"
    assert_raises(ArgumentError) { t.call("kanban_spawn", { "id" => 1 }) }
    content = AgentsKanban::Tools.new(store: store(KanbanTest.config("content")), attachments: nil,
                                      projects: ->(s) { @projects[s] }, sessions: -> { @live }, card_url: CARD_URL)
    refute_includes content.definitions.map { |d| d[:name] }, "kanban_spawn"
  end

  # ── kanban_register: a session started by hand ────────────────────────────────────────────────

  def test_kanban_register_under_a_lead_needs_a_running_lead_the_host_started
    @live << "by_hand"
    args = { "project" => "g/r", "type" => "worker", "tmux_session" => "by_hand", "author" => "me",
             "launcher" => "localclaude", }
    e = assert_raises(AgentsKanban::Denied) { @tools.call("kanban_register", args) }
    assert_match(/no lead session runs for g\/r/, e.message)
    lead, key = lead!("localclaude")
    @l.keys[lead] = "0" * 64
    assert_raises(AgentsKanban::Denied) { @tools.call("kanban_register", args) }
    @l.keys[lead] = key
    r = JSON.parse(@tools.call("kanban_register", args))
    assert_equal [lead, "localclaude"], r.values_at("lead", "launcher")
    assert_equal kb.open_session(lead)[:id], kb.open_session("by_hand")[:lead_id]
    @live << "lead_by_hand"
    e = assert_raises(AgentsKanban::Denied) do
      @tools.call("kanban_register", { "project" => "o/other", "type" => "lead", "tmux_session" => "lead_by_hand",
                                       "author" => "me", "launcher" => "fullclaude", })
    end
    assert_match(/a lead is started only by the operator's Launch/, e.message)
    assert_nil kb.open_session("lead_by_hand"), "a lead is never registered by hand"
  end

  # QA round 1: the key reaches the host's start (env) and nothing else — no registration Hash, no JSON answer of the
  # Api or the MCP tools, no notifier log line carries `lead_key` or the key's value
  def test_the_lead_key_is_in_no_answer_and_no_log
    key = nil
    reg = kb.register_session(session: "direct", project: "o/other", type: "lead", launcher: "fullclaude", by: "op",
                              key_to: ->(k) { key = k })
    assert_match(/\A\h{64}\z/, key)
    refute reg.key?(:lead_key)
    @live << "direct"
    lead, lk = lead!("localclaude")
    id = kb.create(slug: "g/r", title: "w", by: "op", column: "todo")
    spawned = @tools.call("kanban_spawn", { "id" => id, "type" => "worker", "tmux_session" => lead,
                                            "author" => "claude-#{lead}", })
    @live << JSON.parse(spawned)["session"]
    log = StringIO.new
    client = Struct.new(:live) do
      def sessions = live.map { |s| { "name" => s } }
      def dialog(**) = nil
      def notify(**) = { "ok" => true }
      def agents = raise(AgentsKanban::Delivery::Refused, "no collector")
    end.new(@live)
    AgentsKanban::Notifier.new(kb, client: client, clock: -> { @now }, grace: 0, ci: NoCi.new, log: log).tap do |n|
      n.watch
      n.deliver
    end
    outputs = [
      spawned, log.string, JSON.generate(reg),
      JSON.generate(@api.launch("o/other", { "type" => "plain", "launcher" => "fullclaude" }, by: "op")),
      JSON.generate(@api.sessions), JSON.generate(@api.launches("g/r")), JSON.generate(@api.board("g/r")),
      JSON.generate(@api.waiting(@projects.values)), JSON.generate(kb.card_body(kb.card(id))),
      JSON.generate(kb.concurrency(@live.to_set, grace: 0)), JSON.generate(kb.card_sessions(id)),
      @tools.call("kanban_board", { "project" => "g/r" }), @tools.call("kanban_workflow", { "project" => "g/r" }),
    ]
    # a refusal names no key either (the session registered already)
    outputs << assert_raises(AgentsKanban::Denied) do
      @tools.call("kanban_register", { "project" => "g/r", "type" => "plain", "tmux_session" => "direct", "author" => "x",
                                       "launcher" => "fullclaude", })
    end.message
    outputs.each do |o|
      refute_includes o, "lead_key\"", o[0, 200]
      [key, lk].each { |k| refute_includes o, k, "the raw key leaked: #{o[0, 200]}" }
    end
  end

  # ── nothing starts on its own; the board and the waiting list say "no lead" ───────────────────

  def test_the_notifier_starts_nobody_and_an_ownerless_card_waits_for_the_lead
    id = kb.create(slug: "g/r", title: "x", by: "op", column: "todo")
    client = Struct.new(:live) do
      def sessions = live.map { |s| { "name" => s } }
      def dialog(**) = nil
      def notify(**) = { "ok" => true }
      def agents = raise(AgentsKanban::Delivery::Refused, "no collector")
    end.new(@live)
    n = AgentsKanban::Notifier.new(kb, client: client, clock: -> { @now }, grace: 0, ci: NoCi.new, log: StringIO.new)
    n.watch
    assert_empty @l.started, "the notifier starts nobody"
    assert_nil kb.card(id)[:owner_session]
    _, b = @api.board("g/r")
    assert_equal({ type: "lead", label: "Launch", launch_label: nil, session: nil, ended: nil }, b[:lead])
    lead, = lead!
    _, b = @api.board("g/r")
    assert_equal lead, b[:lead][:session]
    @live.delete(lead)
    n.watch
    assert_empty @l.started.drop(1), "a dead lead is not relaunched"
    _, b = @api.board("g/r")
    gone = [b[:lead][:session], b[:lead][:ended][:session], b[:lead][:ended][:reason]]
    assert_equal [nil, lead, AgentsKanban::Store::GONE], gone
    # the card the dead lead held goes back to nobody once the watchdog's grace passed, and waits
    @now += 3600
    n.watch
    assert_nil kb.card(id)[:owner_session]
  end

  def test_the_waiting_list_shows_a_lead_that_ended_on_its_own_until_a_lead_runs_again
    lead, = lead!
    stopped, = lead!("fullclaude", slug: "o/other")
    kb.end_session(stopped, reason: "stopped by the operator", by: "op")
    @live.delete(lead)
    kb.sessions_sync(@live.to_set, grace: 0)
    _, w = @api.waiting(@projects.values)
    assert_equal [["g/r", lead, "lead", AgentsKanban::Store::GONE]],
                 w[:lead_ends].map { |r| r.values_at(:project, :session, :type, :reason) },
                 "the operator's stop is not an alert"
    lead!
    _, w = @api.waiting(@projects.values)
    assert_empty w[:lead_ends], "a lead runs again"
    @now += AgentsKanban::Store::LAUNCH_FAILURE_WINDOW_S + 1
    assert_empty kb.lead_ends(["g/r"])
    assert_empty AgentsKanban::Store.new(db, config: KanbanTest.config("content"), markdown: md,
                                         boards: ->(_) { true }, clock: -> { @now }, prs: PrRoles.new).lead_ends(["g/r"])
  end

  # review round 1: EVERY lead end alerts but the operator's stop — the watchdog's, an agent's, a host's, gone; a failed
  # start is a launch failure, not listed twice
  def test_every_lead_end_but_the_operators_stop_is_a_lead_end
    reasons = { "g/r" => "gone (watchdog)", "o/other" => "ended by its agent" }
    @projects["p"] = { slug: "p", path: @root, remote: nil }
    reasons.each_key { |slug| lead!("fullclaude", slug: slug) }
    stopped, = lead!("fullclaude", slug: "p")
    reasons.each do |slug, why|
      kb.end_session(kb.sessions_t.where(project_slug: slug, ended_at: nil).get(:session), reason: why, by: "x")
    end
    kb.end_session(stopped, reason: AgentsKanban::Store::OPERATOR_STOP, by: "op")
    @l.fail = true
    @projects["q"] = { slug: "q", path: @root, remote: nil }
    @boards << "q"
    @api.launch("q", { "type" => "lead", "launcher" => "fullclaude" }, by: "op")
    got = kb.lead_ends(%w[g/r o/other p q]).to_h { |r| [r[:project], r[:reason]] }
    assert_equal reasons, got
    refute_empty kb.launch_failures(["q"]), "the failed start is a launch failure"
  end

  def test_an_api_with_no_sessions_port_shows_no_lead_and_a_port_down_says_unknown
    api = AgentsKanban::Api.new(store: kb, attachments: nil, markdown: md, projects: ->(s) { @projects[s] })
    assert_nil api.board("g/r")[1][:lead]
    down = AgentsKanban::Api.new(store: kb, attachments: nil, markdown: md, projects: ->(s) { @projects[s] },
                                 sessions: -> { raise AgentsKanban::Delivery::Unavailable, "launcher down" })
    assert_equal({ type: "lead", label: "Launch", launch_label: nil, session: nil, error: "launcher down" },
                 down.board("g/r")[1][:lead])
  end

  # A registered alive owner fills a missing assignee with no taker running (moved from the spawn tests).
  def test_a_registered_owner_fills_a_missing_assignee
    lead!
    kb.register_session(session: "w_1", project: "g/r", type: "worker", launcher: "localclaude", by: "op",
                        lead_id: kb.open_session(@live.first)[:id])
    id = kb.create(slug: "g/r", title: "x", by: "op", column: "backlog")
    kb.set_owner(id, session: "w_1", by: "op")
    kb.move(id, column: "doing", by: "op")
    db[:"#{KanbanTest::PREFIX}cards"].where(id: id).update(assignee: nil)
    assert_equal [id], kb.adopt_ownerless(live: Set["w_1", *@live])
    assert_equal %w[worker-w_1 w_1], kb.card(id).values_at(:assignee, :owner_session)
  end

  # ── the Launch bar: a type only its lead starts, and the lead's button text ─────────────────────

  def bar_config
    raw = raw_config
    raw["agent_types"].find { |t| t["key"] == "worker" }["launchable"] = false
    raw["agent_types"].find { |t| t["key"] == "lead" }["launch_label"] = "Launch team lead"
    AgentsKanban::HostConfig.new(raw)
  end

  def bar_api(cfg)
    st = store(cfg)
    [st, AgentsKanban::Api.new(store: st, attachments: nil, markdown: md, projects: ->(s) { @projects[s] },
                                  sessions: -> { @live }, launcher: @l, grace: 0),
     AgentsKanban::Tools.new(store: st, attachments: nil, projects: ->(s) { @projects[s] },
                             sessions: -> { @live }, card_url: CARD_URL, grace: 0, launcher: @l),]
  end

  def test_the_launch_bar_never_offers_worker
    st, api, tools = bar_api(bar_config)
    _, l = api.launches("g/r")
    bar = l[:types].to_h { |t| [t[:key], t.slice(:label, :launchable, :launch_label)] }
    assert_equal({ label: "Worker", launchable: false, launch_label: nil }, bar["worker"])
    assert_equal({ label: "Launch", launchable: true, launch_label: "Launch team lead" }, bar["lead"])
    assert_equal [true, nil], bar["team"].values_at(:launchable, :launch_label), "a type that says nothing is offered"
    # the operator's launch of it is refused — with no lead, and with one running
    s, j = api.launch("g/r", { "type" => "worker", "launcher" => "localclaude" }, by: "op")
    want = "Worker (worker) is not launched from the Launch bar: the board's lead starts one for a card (kanban_spawn)"
    assert_equal [422, want], [s, j[:error]]
    s, j = api.launch("g/r", { "type" => "lead", "launcher" => "localclaude" }, by: "op")
    assert_equal 201, s, j.inspect
    lead = j[:session]
    @live << lead
    s, = api.launch("g/r", { "type" => "worker", "launcher" => "localclaude" }, by: "op")
    assert_equal 422, s
    assert_equal %w[lead], @l.started.map { |x| x[:type] }, "nothing was started for the refused launches"
    # its lead's kanban_spawn still starts one for a card
    id = st.create(slug: "g/r", title: "work", by: "op", column: "todo")
    r = JSON.parse(tools.call("kanban_spawn", { "id" => id, "type" => "worker", "tmux_session" => lead,
                                                "author" => "claude-#{lead}", }))
    assert_equal "worker", @l.started.last[:type]
    assert_equal r["session"], st.card(id)[:owner_session]
    _, b = api.board("g/r")
    assert_equal "Launch team lead", b[:lead][:launch_label]
  end

  def test_launchable_and_launch_label_are_checked
    bad = lambda do |key, mut|
      r = raw_config
      mut.(r["agent_types"].find { |t| t["key"] == key })
      assert_raises(AgentsKanban::ConfigError) { AgentsKanban::HostConfig.new(r) }.message
    end
    assert_match(/worker\].launchable must be true or false/, bad.("worker", ->(t) { t["launchable"] = "no" }))
    assert_match(/plain\]: launchable: false needs `under: <lead type>`/, bad.("plain", ->(t) { t["launchable"] = false }))
    assert_match(/lead\]: launchable: false needs `under/, bad.("lead", ->(t) { t["launchable"] = false }))
    assert_match(/worker\].launch_label must be null/, bad.("worker", ->(t) { t["launch_label"] = " " }))
    assert_match(/worker\]: launch_label names a Launch bar button, and launchable is false/,
                 bad.("worker", ->(t) { t.merge!("launchable" => false, "launch_label" => "Start") }))
    w = bar_config.agent_type("worker")
    assert_equal [false, nil], [w.launchable, w.launch_label]
    assert_equal [true, nil], [config.agent_type("worker").launchable, config.agent_type("worker").launch_label]
  end

  def test_the_board_banner_marks_an_ended_lead_of_an_old_session_name
    @l.fixed_name = "tl_g_r"
    old, = lead!
    @l.fixed_name = nil
    kb.end_session(old, reason: "done", by: "op")
    _, b = @api.board("g/r")
    assert_equal({ session: "tl_g_r", reason: "done", old_name: "g_r_teamlead" }, b[:lead][:ended].except(:at),
                 "a name a launch no longer gives is old: the banner says so and names today's")
    now, = lead!
    kb.end_session(now, reason: "done", by: "op")
    _, b = @api.board("g/r")
    assert_equal [now, nil], b[:lead][:ended].values_at(:session, :old_name), "today's name (the host's suffix too)"
  end
end
