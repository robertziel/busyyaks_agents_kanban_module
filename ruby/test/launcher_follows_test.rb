# frozen_string_literal: true

require "test_helper"

# THE FOLLOW RULE (agent_types[].launcher_follows): a session spawned or launched for a board runs the launcher of the
# board's running session of the followed type: a lead started on localclaude makes its workers and sub teams run
# localclaude too; no lead running → the type's spawn_launcher (configured), or the card waits — never a launcher the
# code picks.
# And a per-launcher model: a --model under localclaude would override the gateway's model.
class LauncherFollowsTest < Minitest::Test
  include KanbanTest::Setup

  class FakeLauncher
    attr_reader :started
    def initialize = (@started = []; @n = 0)
    def name(project:, base:) = "#{base}_#{@n += 1}"
    def start(**kw) = (@started << kw; { "ok" => true })
  end

  def raw_config
    raw = JSON.parse(File.read(File.join(KanbanTest::ROOT, "fixtures/boards/coding.json")))
    raw["table_prefix"] = KanbanTest::PREFIX
    raw["agent_types"].find { |t| t["key"] == "lead" }["takes"] -= ["queued"]
    raw["agent_types"] << {
      "key" => "worker", "label" => "Worker", "launchers" => %w[fullclaude localclaude],
      "model" => { "fullclaude" => "opus", "localclaude" => nil }, "launcher_follows" => "lead",
      "spawn_launcher" => "fullclaude", # the operator's choice when no lead runs to follow (no code default)
      "prompt" => "Worker {session} for {slug}: you own {cards}.",
      "agent_name" => "worker-{session}", "session_name" => "{slug}_worker",
      "takes" => [], "spawns_for" => ["queued"], "max" => nil, "max_per_project" => nil,
    }
    raw
  end

  def config = (@follow_config ||= AgentsKanban::HostConfig.new(raw_config))

  def setup
    super
    @root = Dir.mktmpdir("follow")
    @projects = {
      "g/r" => { slug: "g/r", path: @root, remote: nil },
      "o/other" => { slug: "o/other", path: @root, remote: nil },
    }
    @live = []
    @l = FakeLauncher.new
    @api = AgentsKanban::Api.new(store: kb, attachments: nil, markdown: md, projects: ->(s) { @projects[s] },
                                 sessions: -> { @live }, launcher: @l, grace: 0)
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def lead!(launcher, slug: "g/r")
    s, j = @api.launch(slug, { "type" => "lead", "launcher" => launcher }, by: "op")
    assert_equal 201, s, j.inspect
    @live << j[:session]
    j[:session]
  end

  def words(argv) = argv.first == "bash" ? Shellwords.split(argv.last) : argv

  def rebuild!(raw)
    @follow_config = AgentsKanban::HostConfig.new(raw)
    @kb = nil
    @api = AgentsKanban::Api.new(store: kb, attachments: nil, markdown: md, projects: ->(s) { @projects[s] },
                                 sessions: -> { @live }, launcher: @l, grace: 0)
  end

  def test_config_validates_launcher_follows_and_the_model_map
    bad = lambda do |mut|
      r = raw_config
      mut.(r["agent_types"].find { |t| t["key"] == "worker" }, r)
      assert_raises(AgentsKanban::ConfigError) { AgentsKanban::HostConfig.new(r) }.message
    end
    assert_match(/agent_types\[worker\].launcher_follows: no agent type "boss" \(lead, team, plain, worker\)/,
                 bad.(->(w, _) { w["launcher_follows"] = "boss" }))
    assert_match(/launcher_follows must name another type/, bad.(->(w, _) { w["launcher_follows"] = "worker" }))
    assert_match(/launcher_follows must be an agent type key or null/, bad.(->(w, _) { w["launcher_follows"] = 3 }))
    assert_match(/lead runs localclaude, which worker.launchers lacks — it could never follow it/,
                 bad.(->(w, _) { w["launchers"] = ["fullclaude"]; w["model"] = "opus" }))
    assert_match(/worker\].launcher_follows: team itself follows lead \(one level only\)/,
                 bad.(->(w, _) { w["launcher_follows"] = "team" }))
    launchers = 'agent_types\[worker\].launchers \(fullclaude, localclaude\), got fullclaude'
    assert_match(/agent_types\[worker\].model: a map must name exactly #{launchers}/,
                 bad.(->(w, _) { w["model"] = { "fullclaude" => "opus" } }))
    assert_match(/agent_types\[worker\].model\[localclaude\] must be null or match/,
                 bad.(->(w, _) { w["model"]["localclaude"] = "a b" }))
    w = config.agent_type("worker")
    assert_equal ["lead", "opus", nil], [w.launcher_follows, w.model_for(nil), w.model_for("localclaude")]
    assert_nil config.agent_type("lead").launcher_follows, "optional: a type without it follows nobody"
  end

  def test_the_model_map_decides_the_model_per_launcher
    l = AgentsKanban::Launch
    assert_equal ["claude", "--permission-mode", "bypassPermissions", "--model", "opus", "--remote-control", "s1"],
                 l.argv(config, type: "worker", session: "s1")
    assert_equal ["localclaude", "--remote-control", "s1"],
                 words(l.argv(config, type: "worker", launcher: "localclaude", session: "s1")),
                 "no --model under the gateway launcher: it would override the gateway's model"
    assert_nil l.plan(config, type: "worker", launcher: "localclaude", session: "s1", slug: "g/r")[:model]
    assert_equal "opus", l.plan(config, type: "worker", session: "s1", slug: "g/r")[:model]
  end

  def test_a_worker_spawned_for_a_card_runs_the_running_leads_launcher
    lead!("localclaude")
    c = kb.create(slug: "g/r", title: "do it", by: "op", column: "todo")
    assert_equal [c], @api.spawn_pass
    st = @l.started.last
    assert_equal %w[worker localclaude], [st[:type], st[:launcher]]
    assert_equal ["localclaude", "--remote-control", st[:session]], words(st[:argv])
    assert_equal "localclaude", kb.sessions_t.where(session: st[:session]).get(:launcher_key),
                 "registered with the launcher it runs"
  end

  def test_a_lead_on_fullclaude_spawns_fullclaude_workers_and_no_lead_means_the_types_spawn_launcher
    c = kb.create(slug: "o/other", title: "no lead", by: "op", column: "todo")
    assert_equal [c], @api.spawn_pass
    started = @l.started.last
    assert_equal %w[fullclaude opus], [started[:launcher], words(started[:argv]).then { |w| w[w.index("--model") + 1] }]
    lead!("fullclaude")
    d = kb.create(slug: "g/r", title: "lead on fullclaude", by: "op", column: "todo")
    assert_equal [d], @api.spawn_pass
    assert_equal "fullclaude", @l.started.last[:launcher]
  end

  # no lead to follow, several launchers and no spawn_launcher: the spawn is refused with the keys, the card waits with
  # that note (once, not per pass) and nothing starts; a lead starting gives it one to follow
  def test_without_spawn_launcher_and_no_lead_the_card_waits_and_says_why
    raw = raw_config
    raw["agent_types"].find { |t| t["key"] == "worker" }.delete("spawn_launcher")
    rebuild!(raw)
    c = kb.create(slug: "g/r", title: "no lead", by: "op", column: "todo")
    2.times { assert_equal [], @api.spawn_pass }
    assert_empty @l.started
    note = "spawn refused: agent type worker runs fullclaude, localclaude and none was named — name the launcher, " \
           "or set agent_types[worker].spawn_launcher"
    assert_equal [note], kb.activity_t.where(card_id: c, kind: "owner").select_map(:body)
    assert_nil kb.card(c)[:owner_session]
    assert_equal 0, kb.sessions_t.count, "nothing registered"
    lead!("localclaude")
    assert_equal [c], @api.spawn_pass
    assert_equal "localclaude", @l.started.last[:launcher]
  end

  # one refused spawn does not stop the pass: the card of the board with a lead to follow still gets its worker
  def test_a_refused_spawn_does_not_stop_the_pass
    raw = raw_config
    raw["agent_types"].find { |t| t["key"] == "worker" }.delete("spawn_launcher")
    rebuild!(raw)
    lead!("localclaude", slug: "o/other")
    c = kb.create(slug: "g/r", title: "no lead here", by: "op", column: "todo")
    d = kb.create(slug: "o/other", title: "lead here", by: "op", column: "todo")
    assert_equal [d], @api.spawn_pass
    assert_equal [%w[worker localclaude o/other]], @l.started.drop(1).map { |s| [s[:type], s[:launcher], s[:project][:slug]] }
    assert_match(/\Aspawn refused: agent type worker runs fullclaude, localclaude/,
                 kb.activity_t.where(card_id: c, kind: "owner").get(:body))
    assert_nil kb.card(c)[:owner_session]
  end

  # Api#launch (a start the engine performs) with no launcher named: the type's spawn_launcher — or, while the lead
  # runs, the lead's; kanban_register (a session started elsewhere) never takes spawn_launcher
  def test_launch_without_a_launcher_runs_spawn_launcher_and_register_never_does
    s, j = @api.launch("g/r", { "type" => "worker" }, by: "op")
    assert_equal [201, "fullclaude"], [s, j[:launcher]]
    assert_equal "fullclaude", kb.sessions_t.where(session: j[:session]).get(:launcher_key)
    @live << j[:session]
    lead!("localclaude")
    s, j = @api.launch("g/r", { "type" => "worker" }, by: "op")
    assert_equal [201, "localclaude"], [s, j[:launcher]], "the running lead's launcher beats spawn_launcher"
    e = assert_raises(AgentsKanban::Invalid) do
      kb.register_session(session: "w_by_hand", project: "g/r", type: "worker", by: "op")
    end
    assert_equal "agent type worker runs fullclaude, localclaude — name the launcher this session was started with",
                 e.message
    assert_equal "localclaude",
                 kb.register_session(session: "w_by_hand", project: "g/r", type: "worker", launcher: "localclaude",
                                     by: "op")[:launcher]
  end

  def test_another_boards_lead_is_not_followed
    lead!("localclaude", slug: "o/other")
    c = kb.create(slug: "g/r", title: "x", by: "op", column: "todo")
    assert_equal [c], @api.spawn_pass
    assert_equal "fullclaude", @l.started.last[:launcher]
  end

  def test_an_ended_lead_is_not_followed
    s = lead!("localclaude")
    @live.delete(s) # gone from the host (grace 0): not running
    c = kb.create(slug: "g/r", title: "x", by: "op", column: "todo")
    assert_equal [c], @api.spawn_pass
    assert_equal "fullclaude", @l.started.last[:launcher]
  end

  def test_a_sub_team_launch_follows_the_lead_and_a_different_launcher_is_refused
    s = lead!("localclaude")
    _, j = @api.launches("g/r")
    team = j[:types].find { |t| t[:key] == "team" }
    assert_equal ["lead", { type: "lead", session: s, launcher: "localclaude" }], team.values_at(:launcher_follows, :follows)
    assert_equal [%w[fullclaude opus], ["localclaude", nil]], team[:launchers].map { |x| [x[:key], x[:model]] }
    assert_nil j[:types].find { |t| t[:key] == "lead" }[:follows]
    st, r = @api.launch("g/r", { "type" => "team" }, by: "op")
    assert_equal [201, "localclaude"], [st, r[:launcher]]
    assert_equal ["localclaude", "--remote-control", r[:session]], words(@l.started.last[:argv])
    st, r = @api.launch("g/r", { "type" => "team", "launcher" => "localclaude" }, by: "op")
    assert_equal [201, "localclaude"], [st, r[:launcher]], "asking for the followed launcher is fine"
    n = @l.started.size
    st, r = @api.launch("g/r", { "type" => "team", "launcher" => "fullclaude" }, by: "op")
    assert_equal 422, st
    assert_match(/team sessions of g\/r run localclaude while the lead session #{s} does .* — fullclaude refused/, r[:error])
    assert_equal n, @l.started.size, "nothing started"
  end
end
