# frozen_string_literal: true

require "test_helper"

# Session boards (HostConfig#session_boards): a board of ONE agent session, attached to no project — created by
# kanban_session_board, used only by that session, archived (never deleted) after idle_hours with no activity.
class SessionBoardsTest < Minitest::Test
  include KanbanTest::Setup

  HOUR = 3600
  OWN = { author: "s_one", tmux_session: "s_one" }.freeze

  def setup
    super
    @root = Dir.mktmpdir("sb-att")
    @live = %w[s_one s_two]
    @projects = { "g/r" => { slug: "g/r", path: @root, remote: nil } }
    policy = AgentsKanban::AttachmentPolicy.new(max_bytes: 1000, types: "image/png,text/plain")
    @att = AgentsKanban::Attachments.new(kb, root: @root, policy: policy, clock: -> { @now })
    @tools = AgentsKanban::Tools.new(store: kb, attachments: @att, projects: ->(s) { @projects[s] },
                                     sessions: -> { @live }, card_url: CARD_URL)
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def call(name, args) = @tools.call(name, JSON.parse(JSON.generate(args)))
  def ok(name, args) = JSON.parse(call(name, args))

  def refused(name, args, error = AgentsKanban::Invalid)
    assert_raises(error) { call(name, args) }
  end

  def open_board(session = "s_one") = ok("kanban_session_board", tmux_session: session, author: session)

  # ── config ──────────────────────────────────────────────────────────────────────────────────────

  def test_config_shape_is_checked
    raw = JSON.parse(File.read(File.join(KanbanTest::ROOT, "fixtures/boards/coding.json")))
    good = raw["session_boards"]
    [
      [good.merge("slug_prefix" => "Session:"), /slug_prefix/],
      [good.merge("slug_prefix" => "session"), /slug_prefix/],
      [good.merge("idle_hours" => 0), /idle_hours/],
      [good.merge("board" => { "columns" => [] }), /board/],
      [good.except("board"), /exactly/],
    ].each do |sb, msg|
      e = assert_raises(AgentsKanban::ConfigError) { AgentsKanban::HostConfig.new(raw.merge("session_boards" => sb)) }
      assert_match msg, e.message
    end
    assert_nil KanbanTest.config("content").session_boards
  end

  def test_a_gate_or_an_invalid_shape_is_refused_when_the_store_starts
    raw = JSON.parse(File.read(File.join(KanbanTest::ROOT, "fixtures/boards/coding.json")))
                .merge("table_prefix" => KanbanTest::PREFIX)
    gated = JSON.parse(JSON.generate(raw))
    gated["session_boards"]["board"]["columns"].insert(2, { "key" => "check", "label" => "Check", "type" => "gate" })
    e = assert_raises(AgentsKanban::ConfigError) { store(AgentsKanban::HostConfig.new(gated)) }
    assert_match(/Check waits for the operator/, e.message)

    broken = JSON.parse(JSON.generate(raw))
    broken["session_boards"]["board"]["transitions"] << { "name" => "X", "from" => "nope", "to" => "done", "by" => "any" }
    e = assert_raises(AgentsKanban::ConfigError) { store(AgentsKanban::HostConfig.new(broken)) }
    assert_match(/session_boards.board/, e.message)
  end

  # ── the tool ────────────────────────────────────────────────────────────────────────────────────

  def test_the_tool_is_listed_only_when_the_host_has_session_boards
    assert(@tools.definitions.any? { |d| d[:name] == "kanban_session_board" })
    desc = @tools.definitions.find { |d| d[:name] == "kanban_session_board" }[:description]
    assert_match(/To do → In progress → Done/, desc)
    assert_match(/24 h/, desc)
    content = AgentsKanban::Tools.new(store: store(KanbanTest.config("content")), attachments: @att,
                                      projects: ->(s) { @projects[s] }, sessions: -> { [] }, card_url: CARD_URL)
    refute(content.definitions.any? { |d| d[:name] == "kanban_session_board" })
    e = assert_raises(AgentsKanban::Invalid) do
      content.call("kanban_session_board", { "tmux_session" => "s_one", "author" => "s_one" })
    end
    assert_match(/session boards are off/, e.message)
  end

  def test_first_call_creates_then_touches_and_the_board_works_like_any_board
    b = open_board
    assert_equal "session:s_one", b["project"]
    assert_equal "created", b["state"]
    assert_equal %w[todo doing done], b["columns"].map { |c| c["column"] }
    assert_nil b["backlog_md"]
    @now += 10
    assert_equal "touched", open_board["state"]

    card = ok("kanban_create", project: "session:s_one", title: "Write the plan", author: "s_one", tmux_session: "s_one")
    assert_equal "todo", card["column"]
    assert_equal "s_one", card["owner_session"]
    assert_equal "https://board.example/projects/session:s_one?card=#{card['id']}", card["url"]
    moved = ok("kanban_move", id: card["id"], transition: "Start", author: "s_one", tmux_session: "s_one")
    assert_equal "doing", moved["column"]
    ok("kanban_comment", id: card["id"], body: "halfway", author: "s_one", tmux_session: "s_one")
    cl = ok("kanban_checklist_add", id: card["id"], title: "Steps", items: ["a"], author: "s_one", tmux_session: "s_one")
    item = cl["checklists"].first["items"].first
    ok("kanban_checklist_toggle", item_id: item["id"], done: true, author: "s_one", tmux_session: "s_one")
    assert_equal "done",
ok("kanban_move", id: card["id"], transition: "Finish", author: "s_one", tmux_session: "s_one")["column"]
    assert_equal ["Write the plan"], ok("kanban_board", project: "session:s_one", **OWN)["columns"]
      .find { |c|
 c["column"] == "done" }["cards"].map { |c|
 c["title"] }
    assert_equal %w[Start Pause Finish], ok("kanban_workflow", project: "session:s_one", **OWN)["transitions"]
      .map { |t|
 t["name"] }
  end

  # public review: the tool opens the CALLER's own board — an author that is another session's registered agent
  # cannot open (read, keep alive) a board by naming that session; the same for every guarded tool
  def test_a_session_board_is_opened_only_by_its_own_session
    kb.register_session(session: "s_two", project: "g/r", type: "plain", by: "op", launcher: "fullclaude")
    two = kb.session_for_author("s_two")[:agent_name]
    e = refused("kanban_session_board", { tmux_session: "s_one", author: two }, AgentsKanban::Denied)
    assert_match(/agent of session s_two, not of tmux_session s_one/, e.message)
    assert_nil kb.repo.session_row("session:s_one"), "nothing opened on s_one's behalf"
    # its own registration with no tmux_session opens its own board
    assert_equal "session:s_two", ok("kanban_session_board", author: two)["project"]
    open_board
    card = ok("kanban_create", project: "session:s_one", title: "Mine", **OWN)
    e = assert_raises(AgentsKanban::Denied) { call("kanban_card", { id: card["id"], author: two, tmux_session: "s_one" }) }
    assert_match(/one call names one caller/, e.message)
  end

  def test_the_session_name_must_be_live_and_well_formed
    refused("kanban_session_board", tmux_session: "gone", author: "gone")
    refused("kanban_session_board", tmux_session: "", author: "x")
    assert_raises(AgentsKanban::Invalid) { kb.session_board!("bad name", by: "x") }
  end

  def test_only_its_session_may_use_it
    open_board
    card = ok("kanban_create", project: "session:s_one", title: "Mine", author: "s_one", tmux_session: "s_one")
    cl = ok("kanban_checklist_add", id: card["id"], title: "T", items: ["x"], author: "s_one",
tmux_session: "s_one")["checklists"].first
    comment = ok("kanban_comment", id: card["id"], body: "hello", author: "s_one", tmux_session: "s_one")["id"]
    att = ok("kanban_attach", id: card["id"], filename: "n.txt", content_base64: ["note"].pack("m0"),
                              author: "s_one", tmux_session: "s_one")["attachment"]["id"]

    other = { author: "s_two", tmux_session: "s_two" }
    [
      ["kanban_board", { project: "session:s_one" }],
      ["kanban_workflow", { project: "session:s_one" }],
      ["kanban_create", { project: "session:s_one", title: "Theirs" }],
      ["kanban_labels", { project: "session:s_one" }],
      ["kanban_card", { id: card["id"] }],
      ["kanban_move", { id: card["id"], transition: "Start" }],
      ["kanban_comment", { id: card["id"], body: "x" }],
      ["kanban_comment_edit", { comment_id: comment, body: "y" }],
      ["kanban_checklist_rename", { checklist_id: cl["id"], title: "U" }],
      ["kanban_checklist_toggle", { item_id: cl["items"].first["id"], done: true }],
      ["kanban_attachment_get", { attachment_id: att }],
    ].each do |name, args|
      e = assert_raises(AgentsKanban::Denied, name) { call(name, args.merge(other)) }
      assert_match(/session s_one's own board/, e.message)
    end
    # a bare author string names nobody — not even the session's own name
    assert_raises(AgentsKanban::Denied) { call("kanban_card", { id: card["id"], author: "s_two" }) }
    assert_raises(AgentsKanban::Denied) { call("kanban_card", { id: card["id"], author: "s_one" }) }
    # a tmux_session that is not running is refused, never taken at its word
    @live = %w[s_two]
    assert_raises(AgentsKanban::Invalid) { call("kanban_card", { id: card["id"], author: "x", tmux_session: "s_one" }) }
    @live = %w[s_one s_two]
    assert_equal "Mine", ok("kanban_card", id: card["id"], author: "s_one", tmux_session: "s_one")["card"]["title"]
    # a registered session acts as its agent name (the open registration says which session it is)
    kb.register_session(session: "s_one", project: "g/r", type: "plain", by: "op", launcher: "fullclaude")
    agent = kb.session_for_author("s_one")[:agent_name]
    assert_equal "Mine", ok("kanban_card", id: card["id"], author: agent)["card"]["title"]
  end

  # review round 1 (blocker): every id-carrying field is checked — a project naming another board, a parent on a
  # session board, a card id under a project's slug never slip past the guard
  def test_no_field_reaches_a_session_card_past_the_guard
    open_board
    mine = ok("kanban_create", project: "session:s_one", title: "Mine", author: "s_one", tmux_session: "s_one")
    other = { author: "s_two", tmux_session: "s_two" }
    [
      ["kanban_card", { id: mine["id"], project: "g/r" }],
      ["kanban_move", { id: mine["id"], project: "g/r", transition: "Start" }],
      ["kanban_comment", { id: mine["id"], project: "g/r", body: "x" }],
      ["kanban_create", { project: "g/r", title: "child", parent: mine["id"] }],
    ].each do |name, args|
      e = assert_raises(AgentsKanban::Denied, name) { call(name, args.merge(other)) }
      assert_match(/session s_one's own board/, e.message)
    end
    theirs = kb.create(slug: "g/r", title: "project card", by: "s_two")
    e = assert_raises(AgentsKanban::Denied) { call("kanban_update", { id: theirs, parent: mine["id"], **other }) }
    assert_match(/session s_one's own board/, e.message)
    assert_nil kb.card!(theirs)[:parent_id]
    assert_equal 0, kb.cards.where(title: "child").count
  end

  def test_project_only_tools_are_refused_on_a_session_board
    open_board
    card = ok("kanban_create", project: "session:s_one", title: "Mine", author: "s_one", tmux_session: "s_one")
    e = refused("kanban_register", project: "session:s_one", type: "worker", tmux_session: "s_one", author: "s_one")
    assert_match(/for project boards/, e.message)
    refused("kanban_pr_assign", id: card["id"], pr_url: "https://github.com/o/r/pull/1", role: "pr", author: "s_one",
tmux_session: "s_one")
    refused("kanban_handoff", id: card["id"], qa: "x" * 30, pr_url: "https://github.com/o/r/pull/1",
                              ci_url: "https://ci/1", ui_change: false, author: "s_one", tmux_session: "s_one")
    # nobody but its session acts on it: a question or a block would wait for an operator who cannot answer there
    own = { author: "s_one", tmux_session: "s_one" }
    assert_match(/for project boards/, refused("kanban_ask", id: card["id"], question: "go?", **own).message)
    assert_match(/for project boards/,
refused("kanban_block", id: card["id"], reason: "ci", url: "https://ci/1", **own).message)
    e = assert_raises(AgentsKanban::Invalid) { kb.board_save("session:s_one", KanbanTest.board_hash, by: "op") }
    assert_match(/session_boards.board/, e.message)
    assert_raises(AgentsKanban::Invalid) { kb.board_reset("session:s_one", by: "op") }
  end

  def test_a_session_board_is_never_made_from_the_project_template_and_unknown_ones_are_refused
    e = assert_raises(AgentsKanban::Invalid) do
      kb.create(slug: "session:nobody", title: "x", by: "nobody")
    end
    assert_match(/does not exist — kanban_session_board/, e.message)
    assert_raises(AgentsKanban::Invalid) { kb.board_of("session:nobody") }
    # a host project slug is untouched by the session prefix check
    assert kb.create(slug: "g/r", title: "project card", by: "op")
  end

  # ── expiry: archived, never deleted ───────────────────────────────────────────────────────────

  def test_inactive_boards_are_archived_after_idle_hours_and_come_back
    open_board
    open_board("s_two")
    keep = ok("kanban_create", project: "session:s_one", title: "Old", author: "s_one", tmux_session: "s_one")
    ok("kanban_create", project: "session:s_two", title: "Busy", author: "s_two", tmux_session: "s_two")
    project_card = kb.create(slug: "g/r", title: "project", by: "op")

    @now += (23 * HOUR)
    two = kb.card!(ok("kanban_board", project: "session:s_two", author: "s_two",
tmux_session: "s_two")["columns"].first["cards"].first["id"])
    ok("kanban_comment", id: two[:id], body: "still here", author: "s_two", tmux_session: "s_two") # s_two is active
    assert_equal [], kb.session_boards_expire_pass

    @now += (1 * HOUR) + 1
    assert_equal ["session:s_one"], kb.session_boards_expire_pass
    archived = kb.card!(keep["id"])
    refute_nil archived[:archived_at]
    assert_match(/inactive for 24 h/, kb.card_body(archived)[:activity].last[:body])
    assert_nil kb.card!(project_card)[:archived_at]
    assert_equal ["session:s_two"], kb.session_boards.map { |b| b[:slug] }
    assert_equal %w[session:s_one session:s_two], kb.session_boards(archived: true).map { |b| b[:slug] }

    e = refused("kanban_create", project: "session:s_one", title: "new", author: "s_one", tmux_session: "s_one")
    assert_match(/was archived after 24 h/, e.message)
    assert_equal [], kb.session_boards_expire_pass # nothing twice

    back = open_board
    assert_equal "restored", back["state"]
    assert(back["columns"].all? { |c| c["cards"].empty? }) # its old cards stay archived
    assert_equal ["Old"], ok("kanban_board", project: "session:s_one", author: "s_one", tmux_session: "s_one",
                                             archived: true)["archived"]
      .map { |c| c["title"] }
    assert_equal 1, db[:"#{KanbanTest::PREFIX}cards"].where(project_slug: "session:s_one").count # nothing deleted
  end

  # review round 1 (major): the engine's own entries (reminders, pings, archive lines) never count as the session
  # being active, and a session card gets no flag reminder
  def test_system_entries_do_not_keep_a_board_alive
    open_board
    card = ok("kanban_create", project: "session:s_one", title: "Flagged", author: "s_one", tmux_session: "s_one")
    kb.block(card["id"], reason: "waits", url: "https://ci/1", by: "s_one") # set at the store: the tools refuse it
    @now += (23 * HOUR)
    assert_equal [], kb.flag_reminders # flags.reminder_hours (24 in the fixture) passed? not on a session card
    kb.send(:log, card["id"], "ping", "pinged s_one (reminder)", config.system_author)
    @now += (1 * HOUR) + 1
    assert_equal [], kb.flag_reminders
    assert_equal ["session:s_one"], kb.session_boards_expire_pass
  end

  # review round 1 (minor): a touch between the scan and the archive keeps the board
  def test_a_touch_during_the_expiry_pass_keeps_the_board
    open_board
    @now += (25 * HOUR)
    calls = 0
    orig = kb.method(:session_board_activity)
    kb.define_singleton_method(:session_board_activity) do |slug, row: nil|
      calls += 1
      session_board!("s_one", by: "s_one") if calls == 1 # the session acts right after the scan read
      orig.call(slug, row: calls == 1 ? row : nil)
    end
    assert_equal [], kb.session_boards_expire_pass
    assert_nil kb.repo.session_row("session:s_one")[:archived_at]
  end

  # review round 1 (minor): a first call that loses the INSERT race touches the winner's row — on PostgreSQL too
  # (the INSERT runs in its own savepoint, so the transaction it sits in goes on)
  def test_a_lost_create_race_touches_the_winners_row
    open_board
    repo = kb.repo
    first = true
    orig = repo.method(:session_row)
    repo.define_singleton_method(:session_row) do |slug|
      next orig.call(slug) unless first

      first = false
      nil # the race: the row did not exist when this call looked
    end
    @now += 5
    assert_equal "touched", kb.session_board!("s_one", by: "s_one")[:state]
    assert_equal @now, orig.call("session:s_one")[:updated_at]
  end

  def test_the_notifier_watch_pass_archives_inactive_boards
    open_board
    client = Class.new do
      def sessions = [{ "name" => "s_one" }]
      def dialog(**) = { "ok" => true, "dialog" => nil }
      def agents = { "age_s" => 1, "interval_s" => 5, "sessions" => [] }
    end.new
    log = StringIO.new
    n = AgentsKanban::Notifier.new(kb, client: client, ci: NoCi.new, clock: -> { @now }, grace: 60, log: log)
    @now += (25 * HOUR)
    n.watch
    assert_match(/session boards archived \(inactive\): session:s_one/, log.string)
  end

  # ── a session's own cards are never released, adopted or spawned for ──────────────────────────

  def test_engine_passes_leave_session_cards_alone
    open_board
    card = ok("kanban_create", project: "session:s_one", title: "Mine", author: "s_one", tmux_session: "s_one")
    kb.move(card["id"], transition: "Start", by: "s_one", agent: true)
    @now += 10_000
    assert_equal [], kb.watch_owners(Set.new, grace: 60) # s_one gone: its own board's card is not released
    kb.watch_owners(Set.new, grace: 60)
    assert_equal "s_one", kb.card!(card["id"])[:owner_session]
    kb.release_session_cards("s_one", reason: "start failed", by: "op")
    assert_equal "s_one", kb.card!(card["id"])[:owner_session]
  end

  # review round 1 (minor): each pass checked against a project card it DOES act on, so no assertion is vacuous
  def test_spawn_intake_idle_watch_and_dialogs_skip_session_cards
    raw = JSON.parse(File.read(File.join(KanbanTest::ROOT, "fixtures/boards/coding.json")))
              .merge("table_prefix" => KanbanTest::PREFIX)
    plain = raw["agent_types"].find { |t| t["key"] == "plain" }
    plain["spawns_for"] = ["queued"]
    plain["takes"] = ["working"]
    st = store(AgentsKanban::HostConfig.new(raw))
    st.session_board!("s_one", by: "s_one")
    sess = st.create(slug: "session:s_one", title: "mine", by: "s_one", owner_session: "s_one", agent: true)
    proj = st.create(slug: "g/r", title: "project", by: "op", column: "todo")
    db[:"#{KanbanTest::PREFIX}cards"].where(id: sess).update(owner_session: nil, assignee: nil)
    assert_equal [proj], st.spawn_queue.map { |c| c[:id] }

    # intake: a plain session takes working cards — the project's, never the session board's
    db[:"#{KanbanTest::PREFIX}cards"].where(id: [sess, proj]).update(column: "doing")
    st.register_session(session: "s_two", project: "g/r", type: "plain", by: "op", launcher: "fullclaude")
    st.adopt_ownerless(live: Set["s_two"])
    assert_equal ["s_two", nil], [st.card!(proj)[:owner_session], st.card!(sess)[:owner_session]]

    # idle watch: both owners idle for owner_idle_hours — only the project card is commented on
    db[:"#{KanbanTest::PREFIX}cards"].where(id: sess).update(owner_session: "s_one")
    @now += 5 * HOUR
    done = st.idle_watch_pass(live: Set["s_one", "s_two"], ci: NoCi.new).map(&:first)
    assert_includes done, proj
    refute_includes done, sess

    # a dialog on s_one's screen is asked on a PROJECT card it owns, never on its own board's
    owned = st.create(slug: "g/r", title: "s_one's project card", by: "op", column: "doing")
    db[:"#{KanbanTest::PREFIX}cards"].where(id: owned).update(owner_session: "s_one")
    db[:"#{KanbanTest::PREFIX}cards"].where(id: sess).update(updated_at: @now + 10) # the newest card it owns
    d = AgentsKanban::SessionDialog.parse("Do you want to proceed?\n❯ 1. Yes\n  2. No\nEsc to cancel\n")
    st.dialog_question(session: "s_one", dialog: d)
    assert st.card!(owned)[:asked_at]
    assert_nil st.card!(sess)[:asked_at]
  end

  # review round 1 (minor): the operator reads a session board and writes nothing on it
  def test_the_operator_api_is_read_only_on_session_cards
    api = AgentsKanban::Api.new(store: kb, attachments: @att, markdown: md, projects: ->(s) { @projects[s] })
    open_board
    c = ok("kanban_create", project: "session:s_one", title: "Mine", author: "s_one", tmux_session: "s_one")
    cl = ok("kanban_checklist_add", id: c["id"], title: "T", items: ["x"], author: "s_one", tmux_session: "s_one")
    cl = cl["checklists"].first
    cm = ok("kanban_comment", id: c["id"], body: "hi", author: "s_one", tmux_session: "s_one")["id"]
    assert_equal 200, api.card(c["id"]).first
    [
      api.update(c["id"], { "title" => "x" }, by: "op"), api.move(c["id"], { "column" => "doing" }, by: "op"),
      api.comment(c["id"], { "body" => "x" }, by: "op"), api.archive(c["id"], {}, by: "op"),
      api.comment_update(cm, { "body" => "y" }, by: "op"), api.comment_delete(cm, by: "op"),
      api.checklist_update(cl["id"], { "title" => "U" }, by: "op"),
      api.item_update(cl["items"].first["id"], { "done" => true }, by: "op"),
    ].each do |status, body|
      assert_equal 422, status, body.inspect
      assert_match(/session s_one's own board — read-only for the operator/, body[:error])
    end
    assert_equal "Mine", kb.card!(c["id"])[:title]
    # a project card is untouched by the guard
    pc = kb.create(slug: "g/r", title: "p", by: "op")
    assert_equal 200, api.update(pc, { "title" => "q" }, by: "op").first
  end

  # ── the operator's read ───────────────────────────────────────────────────────────────────────

  def test_the_api_lists_session_boards
    api = AgentsKanban::Api.new(store: kb, attachments: @att, markdown: md, projects: ->(s) { @projects[s] })
    open_board
    ok("kanban_create", project: "session:s_one", title: "Mine", author: "s_one", tmux_session: "s_one")
    status, body = api.session_boards
    assert_equal 200, status
    assert_equal 24, body[:idle_hours]
    b = body[:session_boards].first
    assert_equal "s_one", b[:session]
    assert_equal ["Mine"], b[:cards].map { |c| c[:title] }
    assert_equal ["To do", "In progress", "Done"], b[:columns].map { |c| c[:label] }
    assert_equal Time.at(@now + (24 * HOUR)).iso8601, b[:expires]
    assert_nil b[:archived]

    content = AgentsKanban::Api.new(store: store(KanbanTest.config("content")), attachments: @att, markdown: md,
                                    projects: ->(s) { @projects[s] })
    assert_equal 404, content.session_boards.first
  end
end
