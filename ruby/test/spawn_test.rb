# frozen_string_literal: true

require "test_helper"

# THE SPAWN RULE: a card in a `spawns_for` column gets ONE NEW session of that type, started for it alone — not
# by the running lead, which keeps its own work.
class SpawnTest < Minitest::Test
  include KanbanTest::Setup

  class FakeLauncher
    attr_reader :started
    attr_accessor :fail
    def initialize = (@started = []; @n = 0)
    def name(project:, base:) = "#{base}_#{@n += 1}"
    def start(**kw)
      raise AgentsKanban::Delivery::Refused, "tmux failed: no server" if @fail

      @started << kw
      { "ok" => true }
    end
  end

  def spawn_types = ["queued"]

  def config
    @spawn_config ||= begin
      raw = JSON.parse(File.read(File.join(KanbanTest::ROOT, "fixtures/boards/coding.json")))
      raw["table_prefix"] = KanbanTest::PREFIX
      raw["agent_types"].find { |t| t["key"] == "lead" }["takes"] -= ["queued"]
      raw["agent_types"] << {
        "key" => "worker", "label" => "Worker", "launchers" => ["fullclaude"], "model" => nil,
        "prompt" => "Worker {session} for {slug}: you own {cards}.",
        "agent_name" => "worker-{session}", "session_name" => "{slug}_worker",
        "takes" => [], "spawns_for" => spawn_types, "max" => 2, "max_per_project" => 2,
      }
      AgentsKanban::HostConfig.new(raw)
    end
  end

  def setup
    super
    @root = Dir.mktmpdir("spawn")
    @projects = { "g/r" => { slug: "g/r", path: @root, remote: nil } }
    @live = []
    @l = FakeLauncher.new
    @api = AgentsKanban::Api.new(store: kb, attachments: nil, markdown: md, projects: ->(s) { @projects[s] },
                                 sessions: -> { @live }, launcher: @l, grace: 60)
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def test_config_spawns_for_is_optional_validated_and_one_spawner_per_column_type
    b = kb.board_of("g/r")
    assert_equal "worker", b.spawner_for("todo").key # the queued column of this board
    assert_nil b.spawner_for("doing")
    assert_equal ["todo"], b.spawn_columns
    assert_equal [], KanbanTest.config.spawn_types, "a host without spawns_for spawns nothing"
    raw = JSON.parse(File.read(File.join(KanbanTest::ROOT, "fixtures/boards/coding.json")))
    raw["agent_types"][1]["spawns_for"] = ["queued"]
    raw["agent_types"][2]["spawns_for"] = ["queued"]
    e = assert_raises(AgentsKanban::ConfigError) { AgentsKanban::HostConfig.new(raw) }
    assert_match(/column type queued is in more than one type's spawns_for/, e.message)
    raw["agent_types"][2]["spawns_for"] = ["todo"]
    assert_raises(AgentsKanban::ConfigError) { AgentsKanban::HostConfig.new(raw) }
  end

  def test_moving_a_card_to_a_spawn_column_launches_a_dedicated_session_that_owns_it
    @live << "lead_1"
    kb.register_session(session: "lead_1", project: "g/r", type: "lead", launcher: "fullclaude", by: "op")
    id = kb.create(slug: "g/r", title: "station", by: "op", column: "backlog")
    s, j = @api.move(id, { "column" => "todo" }, by: "operator@example.com")
    assert_equal 200, s
    c = kb.card(id)
    assert_equal %w[worker-g_r_worker_1 g_r_worker_1 todo], c.values_at(:assignee, :owner_session, :column),
                 "a NEW session, not the running lead"
    st = @l.started.last
    assert_equal ["g_r_worker_1", "worker", "##{id}"], [st[:session], st[:type], st[:vars][:cards]]
    assert_equal ["--remote-control", "g_r_worker_1"], st[:argv].last(2)
    assert_equal "worker", kb.open_session("g_r_worker_1")[:type_key]
    assert_match(/spawned for this card: worker-g_r_worker_1/, kb.activity(id).map { |a| a[:body] }.join("\n"))
    assert_equal 1, @l.started.size
    assert_equal "spawned: g_r_worker_1", j[:delivered]
  end

  def test_spawn_is_idempotent_across_passes_and_the_intake_never_gives_a_spawn_column_card_to_the_lead
    @live << "lead_1"
    kb.register_session(session: "lead_1", project: "g/r", type: "lead", launcher: "fullclaude", by: "op")
    id = kb.create(slug: "g/r", title: "x", by: "op", column: "todo") # created there: the pass picks it up
    assert_empty kb.adopt_ownerless(live: Set["lead_1"]), "the lead does not take a spawn column"
    assert_equal [id], @api.spawn_pass
    @live << "g_r_worker_1"
    assert_empty @api.spawn_pass
    assert_empty @api.spawn_pass(only: id)
    assert_equal 1, @l.started.size
  end

  def test_spawn_respects_caps_and_waits_with_the_reason_then_spawns_when_a_slot_frees
    ids = Array.new(3) { |i| kb.create(slug: "g/r", title: "c#{i}", by: "op", column: "todo") }
    @now += 1
    assert_equal ids.first(2), @api.spawn_pass, "FIFO, up to the worker cap (2)"
    third = kb.card(ids[2])
    assert_nil third[:owner_session]
    assert_match(%r{waiting for a free worker session — 2/2 worker sessions are running}, kb.activity(ids[2]).last[:body])
    n = kb.activity(ids[2]).size
    @api.spawn_pass
    assert_equal n, kb.activity(ids[2]).size, "the waiting note is logged once, not per pass"
    # one worker's session ends: the slot frees, the waiting card gets its own session
    kb.end_session("g_r_worker_1", reason: "done", by: "op")
    @live << "g_r_worker_2"
    assert_equal [ids[2]], @api.spawn_pass
    assert_equal "g_r_worker_3", kb.card(ids[2])[:owner_session]
  end

  def test_a_failed_spawn_releases_the_card_notes_why_ends_the_registration_and_retries_after_the_backoff
    id = kb.create(slug: "g/r", title: "x", by: "op", column: "todo")
    @l.fail = true
    assert_empty @api.spawn_pass
    assert_equal [nil, nil], kb.card(id).values_at(:owner_session, :assignee)
    assert_match(/spawn failed: tmux failed: no server/, kb.activity(id).last[:body])
    assert_equal "start failed: tmux failed: no server", kb.sessions_t.where(session: "g_r_worker_1").first[:end_reason]
    @l.fail = false
    assert_empty @api.spawn_pass, "inside the backoff: no new session every pass"
    @now += AgentsKanban::Store::SPAWN_RETRY_S
    assert_equal [id], @api.spawn_pass
    assert_equal "g_r_worker_2", kb.card(id)[:owner_session]
  end

  def test_a_dead_workers_card_gets_a_new_worker
    id = kb.create(slug: "g/r", title: "x", by: "op", column: "todo")
    @api.spawn_pass
    assert_equal "g_r_worker_1", kb.card(id)[:owner_session]
    # the worker's tmux session vanished: the watchdog releases the card after the grace, the next pass spawns again
    kb.watch_owners(Set[], grace: 60)
    @now += 61
    kb.sessions_sync(Set[], grace: 60)
    assert_equal [id], kb.watch_owners(Set[], grace: 60)
    assert_equal [id], @api.spawn_pass
    assert_equal "g_r_worker_2", kb.card(id)[:owner_session]
  end

  # a worker created a card in Backlog and ended; the card kept that dead session as owner (the
  # watchdog skipped parked columns), so the operator's move to To do spawned nobody and pinged a dead session.
  def test_a_parked_card_of_a_dead_session_is_released_and_spawned_for_once_moved_to_todo
    id = kb.create(slug: "g/r", title: "x", by: "op", column: "backlog")
    kb.set_owner(id, session: "old_worker", by: "op")
    done = kb.create(slug: "g/r", title: "shipped", by: "op", column: "merged")
    kb.set_owner(done, session: "old_worker", by: "op")
    kb.watch_owners(Set[], grace: 60)
    @now += 61
    assert_equal [id], kb.watch_owners(Set[], grace: 60), "parked is watched; done keeps its owner as history"
    assert_equal ["backlog", nil, nil], kb.card(id).values_at(:column, :owner_session, :assignee), "released in place"
    assert_equal "old_worker", kb.card(done)[:owner_session]
    _, j = @api.move(id, { "column" => "todo" }, by: "op")
    assert_match(/\Aspawned: g_r_worker_1/, j[:delivered])
  end

  def test_ports_down_raise_and_a_move_says_the_spawn_is_deferred
    id = kb.create(slug: "g/r", title: "x", by: "op", column: "backlog")
    down = AgentsKanban::Api.new(store: kb, attachments: nil, markdown: md, projects: ->(s) { @projects[s] },
                                 sessions: -> { raise AgentsKanban::Delivery::Unavailable, "launcher down" },
                                 launcher: @l, grace: 60)
    s, j = down.move(id, { "column" => "todo" }, by: "op")
    assert_equal 200, s
    assert_match(/spawn deferred to the notifier pass: launcher down/, j[:delivered])
    assert_nil kb.card(id)[:owner_session], "never handed to another session instead"
    assert_raises(AgentsKanban::Delivery::Unavailable) { down.spawn_pass }
  end

  # The operator sets a worker session as a card's owner by hand; with no lead running, a sweep that only ran for
  # takers would never fill its assignee, so the card face would show nobody. A registered alive owner fills it.
  def test_a_registered_owner_fills_a_missing_assignee_with_no_taker_running
    kb.register_session(session: "w_1", project: "g/r", type: "worker", by: "op", for_cards: [])
    id = kb.create(slug: "g/r", title: "x", by: "op", column: "doing")
    kb.set_owner(id, session: "w_1", by: "op")
    assert_nil kb.card(id)[:assignee]
    assert_equal [id], kb.adopt_ownerless(live: Set["w_1"])
    assert_equal %w[worker-w_1 w_1], kb.card(id).values_at(:assignee, :owner_session)
    assert_match(/assignee filled from its owner session w_1/, kb.activity(id).last[:body])
    assert_empty kb.adopt_ownerless(live: Set["w_1"]), "settled"
    other = kb.create(slug: "g/r", title: "parked", by: "op", column: "backlog")
    kb.set_owner(other, session: "w_1", by: "op")
    assert_empty kb.adopt_ownerless(live: Set["w_1"]), "an unwatched column (Backlog) is left alone"
  end
end

# A card LOST in a later column (its owner gone while a question waited on it; or approved into Ready to merge with
# nobody left to merge) would sit there for good when no lead runs — the board spawns for every working column, not
# only To do; in a gate only for an APPROVED card (an unapproved one waits for the operator).
class SpawnEveryWorkingColumnTest < SpawnTest
  SpawnTest.public_instance_methods(false).grep(/\Atest_/).each { |m| undef_method m } # only this board's own tests

  def spawn_types = %w[queued working review gate]

  def test_an_ownerless_card_in_any_spawn_column_gets_a_new_worker_and_the_lead_never_takes_it
    @live << "lead_1"
    kb.register_session(session: "lead_1", project: "g/r", type: "lead", launcher: "fullclaude", by: "op")
    ids = %w[qa ready].map { |col| kb.create(slug: "g/r", title: col, by: "op", column: col) }
    db[:"#{KanbanTest::PREFIX}cards"].where(id: ids.last).update(approved_at: @now) # approved into Ready to merge
    assert_empty kb.adopt_ownerless(live: Set["lead_1"]), "spawn columns are never the lead's"
    waiting = kb.create(slug: "g/r", title: "not approved", by: "op", column: "human_check")
    assert_equal ids, @api.spawn_pass.sort
    assert_nil kb.card(waiting)[:owner_session], "a gate card the operator has not approved gets no worker"
    assert_equal [waiting], kb.adopt_ownerless(live: Set["lead_1"]),
                 "the lead takes the unapproved gate card, never the approved one"
    assert_equal %w[qa ready], ids.map { |i| kb.card(i)[:column] }, "a spawn never moves the card"
    assert_equal 2, ids.map { |i| kb.card(i)[:owner_session] }.uniq.size, "one new session per card"
  end

  def test_a_flagged_card_whose_owner_is_gone_gets_a_worker_once_the_answer_clears_the_flag
    id = kb.create(slug: "g/r", title: "x", by: "op", column: "todo")
    @api.spawn_pass
    w = kb.card(id)[:owner_session]
    kb.move(id, column: "doing", by: "worker-#{w}", agent: true)
    kb.ask(id, question: "A or B?", by: "worker-#{w}")
    assert_equal "doing", kb.card(id)[:column]
    kb.watch_owners(Set[], grace: 60)
    @now += 61
    kb.sessions_sync(Set[], grace: 60)
    assert_equal [id], kb.watch_owners(Set[], grace: 60)
    assert_equal ["todo", nil, "A or B?"], kb.card(id).values_at(:column, :owner_session, :question),
                 "released to the queue, still flagged for the operator"
    assert_empty @api.spawn_pass, "a flagged card waits for the operator: nobody to spawn for yet"
    kb.comment(id, body: "B", author: "operator@example.com", operator: true)
    assert_equal ["todo", nil, nil], kb.card(id).values_at(:column, :owner_session, :asked_at)
    assert_equal [id], @api.spawn_pass
    refute_equal w, kb.card(id)[:owner_session]
    assert_match(/spawned for this card/, kb.activity(id).last(3).map { |a| a[:body] }.join("\n"))
  end
end
