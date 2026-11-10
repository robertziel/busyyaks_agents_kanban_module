# frozen_string_literal: true

require "test_helper"
require "stringio"

# The notifier over a fake delivery port, and session dialogs: parse → one question → the operator's key press.
class NotifierDialogTest < Minitest::Test
  include KanbanTest::Setup
  SD = AgentsKanban::SessionDialog

  class FakeClient
    attr_accessor :answers, :sent, :snap, :screen
    def initialize = (@answers = {}; @sent = []; @screen = nil; @snap = { "age_s" => 1, "interval_s" => 5, "sessions" => [] })
    def notify(session:, socket:, text:) = (@sent << [session, text]; @answers.fetch(session, { "ok" => true }))
    def agents = @snap
    attr_accessor :live
    def sessions = (@live ||= []).map { |n| { "name" => n } }
    def dialog(**) = { "ok" => true, "dialog" => @screen && JSON.parse(JSON.generate(SD.parse(@screen))) }
  end

  EXACT = "This shell -c script runs rm and could not be checked\nDo you want to proceed?\n" \
          "❯ 1. Yes\n  2. No\nEsc to cancel · Tab to amend\n"
  BOXED = File.read(File.join(KanbanTest::ROOT, "fixtures/screens/boxed_permission.txt"))
  ASK = "☐ Deploy\n\nWhich region first?\n\n❯ 1. eu-west\n     Closest to users\n  2. us-east\n     Cheapest\n" \
        "  3. Type something.\n\nEnter to select · ↑/↓ to navigate · Esc to cancel\n"

  # an agent snapshot: session shop is waiting on a permission prompt
  def prompt_snap
    shop = { "name" => "shop", "panes" => [{ "waiting_for" => "permission prompt" }] }
    { "age_s" => 1, "interval_s" => 5, "sessions" => [shop] }
  end

  def setup
    super
    @id = kb.create(slug: "p", title: "branch cleanup", by: "me", column: "doing")
    kb.update(@id, { "assignee" => "lead" }, by: "lead")
    kb.set_owner(@id, session: "shop", by: "lead")
    @client = FakeClient.new
    @n = AgentsKanban::Notifier.new(kb, client: @client, ci: NoCi.new, clock: -> { @now },
                                        give_up: 600, grace: 60, log: StringIO.new)
  end

  def test_parses_the_screens_and_refuses_a_changed_one
    d = SD.parse(EXACT)
    assert_equal "This shell -c script runs rm and could not be checked\nDo you want to proceed?", d[:question]
    assert_nil d[:command]
    assert_equal [%w[1 Yes], %w[2 No]], d[:options].map { |o| [o[:key], o[:label]] }
    assert_equal [true, true, %w[1 2 esc]], [d[:escape], d[:free_text], SD.keys(d)]
    moved = EXACT.sub("❯ 1. Yes", "  1. Yes").sub("  2. No", "❯ 2. No")
    assert_equal d[:hash], SD.parse(moved)[:hash], "the cursor is not the dialog"
    b = SD.parse(BOXED)
    assert_equal "sh -c 'rm -rf build/ && make test'\nClean and rerun the tests", b[:command]
    assert_equal %w[1 2 3 esc], SD.keys(b)
    a = SD.parse(ASK)
    assert_equal ["Which region first?", [false, false, true], %w[1 2 esc]],
                 [a[:question], a[:options].map { |o| o[:free] }, SD.keys(a)]
    assert_nil SD.parse("~/x $ ls\nREADME.md\n> ")
    assert_nil SD.parse("Esc to cancel\n")
    h = d[:hash]
    assert_nil SD.refuse_answer(EXACT, hash: h, key: "esc")
    assert_equal "the dialog on its screen changed", SD.refuse_answer(BOXED, hash: h, key: "2")
    assert_equal "no dialog on its screen any more", SD.refuse_answer("~/x $ ", hash: h, key: "2")
    assert_match(/3 is not an option/, SD.refuse_answer(EXACT, hash: h, key: "3"))
  end

  # Claude Code's unattended-session countdown ("will automatically block this request in 1:27") ticks every second:
  # it is not the dialog, so the hash ignores it — else every click is refused as "changed".
  def test_the_auto_block_countdown_is_not_the_dialog
    c = File.read(File.join(KanbanTest::ROOT, "fixtures/screens/countdown_permission.txt"))
    d = SD.parse(c)
    assert_equal "Do you want to proceed?", d[:question]
    assert_includes d[:command], "block this request in 1:27"
    later = c.sub("in 1:27", "in 0:56")
    assert_equal d[:hash], SD.parse(later)[:hash]
    assert_equal d[:hash], SD.parse(c.sub("in 1:27", "in 12:05"))[:hash]
    assert_nil SD.refuse_answer(later, hash: d[:hash], key: "1")
    refute_equal d[:hash], SD.parse(c.sub("frames/* && ls", "frames/* && pwd"))[:hash], "the command still is"
  end

  def test_delivery_sent_pending_gave_up_gone
    kb.comment(@id, body: "do steps 1-4", author: "operator@example.com")
    kb.comment(@id, body: "on it", author: "lead") # the owner's own agent: no ping
    @n.deliver
    assert_equal 1, @client.sent.size
    assert_includes @client.sent.first[1], "do steps 1-4"
    assert_equal "sent", kb.pings(@id).first[:status]
    @client.answers["shop"] = { "ok" => false, "retry" => true, "error" => "a question is on its screen" }
    kb.comment(@id, body: "x", author: "me")
    @n.deliver
    assert_equal "pending", kb.pings(@id).first[:status]
    @now += 601
    @n.deliver
    assert_match(/gave up after 10 min: a question/, kb.pings(@id).first[:error])
    @client.answers["shop"] = { "ok" => false, "gone" => true, "error" => "session is not running" }
    kb.comment(@id, body: "y", author: "me")
    @n.deliver
    assert_equal ["failed", "session is not running"], kb.pings(@id).first.values_at(:status, :error)
  end

  # A tmux session `shop` exists but the agent-detection snapshot does not list it; the
  # watchdog must not "release" its cards as gone. Liveness is the host's session list, never the detection snapshot.
  def test_a_live_session_the_agent_snapshot_does_not_list_is_never_released
    @client.live = ["shop"]
    @client.snap = { "age_s" => 1, "interval_s" => 5, "sessions" => [] }
    3.times { @now += 61; assert_equal [], @n.watch }
    assert_equal "shop", kb.card(@id)[:owner_session]
  end

  def test_port_down_skips_the_pass_and_a_stale_snapshot_never_releases
    kb.comment(@id, body: "x", author: "me")
    down = Object.new
    def down.notify(**) = raise(AgentsKanban::Delivery::Unavailable, "launcher not reachable")
    def down.agents = raise(AgentsKanban::Delivery::Unavailable, "launcher not reachable")
    def down.sessions = raise(AgentsKanban::Delivery::Unavailable, "launcher not reachable")
    def down.dialog(**) = raise(AgentsKanban::Delivery::Unavailable, "launcher not reachable")
    log = StringIO.new
    n = AgentsKanban::Notifier.new(kb, client: down, ci: NoCi.new, clock: -> { @now }, grace: 60, log: log)
    n.deliver
    assert_equal [], n.watch
    assert_equal "pending", kb.pings(@id).first[:status]
    assert_match(/skipped/, log.string)
    @client.live = ["shop"]
    @client.snap = { "age_s" => 600, "interval_s" => 5, "sessions" => [] }
    @now += 1000
    assert_equal [], @n.watch # a stale detection snapshot skips only the dialog scan
    assert_equal "shop", kb.card(@id)[:owner_session]
  end

  # A host with no agent collector (busyyaks `agents.collector: none`) refuses the snapshot op.
  class NoCollectorClient < FakeClient
    attr_accessor :refuse
    def agents = refuse ? raise(AgentsKanban::Delivery::Refused, refuse) : super
  end

  # Only the dialog scan is off, said once per change of reason — the registry sync and the owner watchdog still run,
  # and nothing claims the watchdog was skipped.
  def test_a_refused_collector_turns_off_only_the_dialog_scan_and_says_so_once
    client = NoCollectorClient.new
    client.refuse = "unsupported op agents: agents.collector is none"
    log = StringIO.new
    n = AgentsKanban::Notifier.new(kb, client: client, ci: NoCi.new, clock: -> { @now }, grace: 60, log: log)
    client.live = ["shop"]
    3.times { @now += 61; assert_equal [], n.watch }
    client.live = []
    assert_equal [], n.watch # first pass without the owner: missing since now
    @now += 61
    assert_equal [@id], n.watch, "the owner watchdog runs although the dialog scan is off"
    assert_nil kb.card(@id)[:owner_session]
    lines = log.string.lines.map(&:chomp)
    assert_equal ["dialog scan off: unsupported op agents: agents.collector is none"],
                 lines.grep(/dialog scan/), "one line for five passes"
    assert_includes lines, "watchdog released cards #{@id}"
    assert_empty lines.grep(/watchdog skipped/)
    client.refuse = "launcher: collector restarting"
    2.times { n.watch }
    client.refuse = nil
    2.times { n.watch }
    assert_equal ["dialog scan off: unsupported op agents: agents.collector is none",
                  "dialog scan off: launcher: collector restarting",
                  "dialog scan on: collector answers again",],
                 log.string.lines.map(&:chomp).grep(/dialog scan/)
  end

  # A client whose screen read fails for the sessions listed in `broken`.
  class BrokenScreenClient < FakeClient
    attr_accessor :broken, :read
    def dialog(session:, **)
      (@read ||= []) << session
      raise AgentsKanban::Delivery::Unavailable, broken[session] if broken[session]

      super
    end
  end

  # One owner's screen that cannot be read skips only that session: the next owner's dialog is still asked, and the
  # failure is logged once per change of reason per session, and once when it answers again.
  def test_a_failed_screen_read_skips_only_that_session_and_says_so_once
    other = kb.create(slug: "p", title: "other", by: "me", column: "doing")
    kb.set_owner(other, session: "shop2", by: "lead")
    client = BrokenScreenClient.new
    client.broken = { "shop" => "tmux: no server on socket default" }
    client.live = %w[shop shop2]
    waiting = [{ "waiting_for" => "permission prompt" }]
    sessions = [{ "name" => "shop", "panes" => waiting }, { "name" => "shop2", "panes" => waiting }]
    client.snap = { "age_s" => 1, "interval_s" => 5, "sessions" => sessions }
    client.screen = EXACT
    log = StringIO.new
    n = AgentsKanban::Notifier.new(kb, client: client, ci: NoCi.new, clock: -> { @now }, grace: 60, log: log)
    3.times { n.watch; @now += 31 }
    assert kb.card(other)[:dialog_id], "shop2's dialog asked although shop's screen failed"
    assert_equal "doing", kb.card(@id)[:column]
    assert_operator client.read.index("shop"), :<, client.read.index("shop2"), "shop2 read after shop failed"
    client.broken = { "shop" => "tmux: pane not found" }
    2.times { n.watch }
    client.broken = {}
    2.times { n.watch }
    assert_equal ["dialog read failed on shop: tmux: no server on socket default",
                  "dialog read failed on shop: tmux: pane not found",
                  "dialog read on shop: answers again",],
                 log.string.lines.map(&:chomp).grep(/dialog read/)
    assert_empty log.string.lines.grep(/skipped/)
  end

  # The real watchdog failure keeps its line: the host's session list is the liveness source, so without it the whole
  # pass is skipped — every pass, nothing released.
  def test_an_unreachable_session_list_still_skips_the_watchdog_and_says_so
    client = @client
    def client.sessions = raise(AgentsKanban::Delivery::Unavailable, "launcher not reachable")
    log = StringIO.new
    n = AgentsKanban::Notifier.new(kb, client: client, ci: NoCi.new, clock: -> { @now }, grace: 60, log: log)
    2.times { @now += 61; assert_equal [], n.watch }
    assert_equal ["watchdog skipped: launcher not reachable"] * 2, log.string.lines.map(&:chomp)
    assert_equal "shop", kb.card(@id)[:owner_session]
  end

  def test_a_dialog_becomes_one_question_and_the_ping_waits
    older = kb.create(slug: "p", title: "older", by: "me", column: "todo")
    kb.set_owner(older, session: "shop", by: "lead")
    kb.comment(older, body: "status?", author: "operator@example.com", operator: true)
    @client.screen = EXACT
    3.times { @n.deliver }
    assert_empty @client.sent, "never typed into a dialog"
    c = kb.card(older)
    assert_equal %w[todo busyyaks], c.values_at(:column, :asked_by), "flagged in place, not moved"
    assert kb.card_json(c)[:needs_operator]
    assert_equal ["1. Yes", "2. No", "Esc = cancel"], JSON.parse(c[:question_options])
    assert_equal %w[1 2 esc], c[:dialog][:keys]
    assert_equal 1, kb.activity(older).count { |a| a[:kind] == "question" }, "deduped by the dialog's hash"
    assert_match(/asked on card ##{older} \(needs_operator, To do\)/, kb.pings(older).first[:error])
    assert_equal "doing", kb.card(@id)[:column]
  end

  def test_watch_pass_posts_on_the_most_recent_card_and_the_operator_presses_through_the_port
    @client.live = ["shop"]
    @client.snap = prompt_snap
    @client.screen = BOXED
    @n.watch
    @n.watch
    assert_equal ["doing", true], [kb.card(@id)[:column], kb.card_json(kb.card(@id))[:needs_operator]]
    assert_equal 1, kb.dialogs_t.count
    q = kb.activity(@id).find { |a| a[:kind] == "question" }
    assert_includes q[:body], "```text\nsh -c 'rm -rf build/ && make test'"
    assert_includes q[:body], "busyyaks never types into a dialog"
    kb.comment(@id, body: "pressing it in a minute", author: "operator@example.com", operator: true)
    assert kb.card(@id)[:asked_at], "a comment on a dialog card is not an answer"

    pressed = []
    refuse = ->(**) { raise AgentsKanban::Invalid, "shop: the dialog on its screen changed" }
    e = assert_raises(AgentsKanban::Invalid) { kb.answer_dialog(@id, key: "2", by: "op", press: refuse) }
    assert_match(/changed/, e.message)
    assert kb.card(@id)[:dialog_id], "a refused press records nothing"
    assert_raises(AgentsKanban::Invalid) { kb.answer_dialog(@id, key: "9", by: "op", press: ->(**a) { pressed << a }) }
    assert_empty pressed
    kb.answer_dialog(@id, key: "2", by: "op", press: ->(**a) { pressed << a })
    assert_equal [{ session: "shop", socket: "default", hash: SD.parse(BOXED)[:hash], key: "2" }], pressed
    c = kb.card(@id)
    assert_equal ["doing", nil, nil, nil], [c[:column], c[:dialog_id], c[:dialog], c[:asked_at]]
    pressed_body = "pressed 2. Yes, and don't ask again for rm commands in /x in shop (the dialog on its screen)"
    assert_equal ["answer", "op", pressed_body], kb.activity(@id).last.values_at(:kind, :author, :body)
    @n.watch # the same dialog still on screen right after the press: not re-posted
    assert_equal 1, kb.activity(@id).count { |a| a[:kind] == "question" }
    @client.screen = EXACT
    @n.watch
    assert_equal 2, kb.dialogs_t.count, "a different dialog on the same session is a new question"
  end

  # a dialog question said what was on the screen, never why the agent was there.
  def test_the_dialog_question_quotes_the_agents_last_comment_or_says_there_was_none
    @client.screen = EXACT
    kb.comment(@id, body: "running the cleanup script now\nit removes build/", author: "lead")
    kb.comment(@id, body: "operator chatter", author: "operator@example.com", operator: true)
    @n.dialog("shop", "default")
    q = kb.activity(@id).find { |a| a[:kind] == "question" }[:body]
    assert_match(/\*\*Why\*\* — lead's last comment \(comment #\d+, /, q)
    assert_includes q, "> running the cleanup script now\n> it removes build/"
    refute_includes q, "operator chatter"

    other = kb.create(slug: "p", title: "quiet", by: "me", column: "doing")
    kb.set_owner(other, session: "quiet", by: "lead")
    kb.comment(other, body: "an hour ago", author: "lead")
    @now += 11 * 60
    kb.dialog_question(session: "quiet", dialog: SD.parse(EXACT))
    assert_includes kb.activity(other).find { |a| a[:kind] == "question" }[:body],
                    "the agent gave no reason — no comment on this card in the last 10 min"
  end

  # The session's newest card sat in Human Check, so its dialog question landed on a card waiting for the operator's
  # check. A card in an operator column is never the dialog's card.
  def test_a_dialog_is_never_asked_on_a_card_in_an_operator_column
    handed = kb.create(slug: "p", title: "handed", by: "me", column: "doing")
    kb.set_owner(handed, session: "shop", by: "lead")
    kb.handoff(handed, qa: "open /x and check the share row", pr_url: "https://github.com/o/r/pull/1",
                       ci_url: "https://ci.example.com/1", ui_change: false, by: "lead")
    @now += 5
    kb.comment(handed, body: "fresh activity on the handed card", author: "operator@example.com", operator: true)
    assert_equal @id, kb.dialog_question(session: "shop", dialog: SD.parse(EXACT), card_id: handed),
                 "not the pending ping's card in Human Check either"
    assert_equal "human_check", kb.card(handed)[:column]
    assert_equal 0, kb.activity(handed).count { |a| a[:kind] == "question" }

    only = kb.create(slug: "p", title: "only", by: "me", column: "doing")
    kb.set_owner(only, session: "solo", by: "lead")
    kb.handoff(only, qa: "open /y and check the share row", pr_url: "https://github.com/o/r/pull/2",
                     ci_url: "https://ci.example.com/2", ui_change: false, by: "lead")
    assert_nil kb.dialog_question(session: "solo", dialog: SD.parse(BOXED))
    @client.screen = BOXED
    kb.comment(only, body: "ping me", author: "operator@example.com", operator: true)
    @n.deliver
    assert_empty @client.sent, "a dialog with no card to ask on still never gets a ping typed into it"
    assert_match(/no card to ask it on/, kb.pings(only).first[:error])
  end

  # 79 dialog questions a week expired within seconds: a dialog is asked only once it stays.
  def test_a_dialog_is_asked_only_once_it_has_stayed_settle_seconds
    dialogs = { "settle_seconds" => 30, "context_minutes" => 10 }
    cfg = AgentsKanban::HostConfig.new(config.raw.merge("session_dialogs" => dialogs))
    s = store(cfg)
    id = s.create(slug: "p", title: "x", by: "me", column: "doing")
    s.set_owner(id, session: "shop", by: "lead")
    n = AgentsKanban::Notifier.new(s, client: @client, ci: NoCi.new, clock: -> { @now }, grace: 60, log: StringIO.new)
    @client.screen = EXACT
    assert_match(/asked if it is still there in 30s/, n.dialog("shop", "default"))
    @now += 29
    assert_match(/in 1s/, n.dialog("shop", "default"))
    assert_equal "doing", s.card(id)[:column]
    @client.screen = nil # cleared within the window: never reaches the operator
    assert_nil n.dialog("shop", "default")
    @client.screen = EXACT
    n.dialog("shop", "default")
    @now += 30
    assert_match(/asked on card ##{id}/, n.dialog("shop", "default"))
    assert_equal ["doing", 1], [s.card(id)[:column], s.activity(id).count { |a| a[:kind] == "question" }]
    assert s.card(id)[:asked_at]
    @client.screen = BOXED # a different dialog settles on its own
    assert_match(/in 30s/, n.dialog("shop", "default"))
  end

  # A session that owns only cards in the operator's columns (or none) has no card to carry its dialog: nothing is
  # asked, and still a ping to it waits rather than being typed into the dialog.
  def test_a_session_with_no_askable_card_posts_no_dialog
    s = store(KanbanTest.config("content"))
    id = s.create(slug: "p", title: "x", by: "me", column: "done")
    s.set_owner(id, session: "news-articles-1", by: "me")
    assert_nil s.dialog_question(session: "news-articles-1", dialog: SD.parse(EXACT))
    @client.screen = EXACT
    notifier = AgentsKanban::Notifier.new(s, client: @client, ci: NoCi.new, log: StringIO.new)
    assert_match(/no card to ask it on/, notifier.dialog("news-articles-1", "default"))
  end

  def test_watch_pass_reconciles_sessions_and_expires_a_dialog_that_left_the_screen
    @client.live = ["shop"]
    kb.register_session(session: "shop", project: "p", type: "lead", launcher: "fullclaude", by: "op")
    @client.snap = prompt_snap
    @client.screen = EXACT
    @n.watch
    assert_equal ["doing", true], [kb.card(@id)[:column], kb.card_json(kb.card(@id))[:needs_operator]]
    @client.screen = nil # answered in the terminal
    @n.watch
    c = kb.card(@id)
    assert_equal ["doing", nil, nil], c.values_at(:column, :dialog_id, :asked_at)
    assert_match(/expired/, kb.dialogs_t.first[:answer])
    # a pending ping on a session whose dialog is gone: the deliver pass expires it too, then delivers
    @client.screen = EXACT
    @n.watch
    kb.comment(@id, body: "go on", author: "operator@example.com", operator: true)
    @n.deliver
    assert_empty @client.sent
    @client.screen = nil
    @n.deliver
    assert_equal 1, @client.sent.size
    assert_equal "doing", kb.card(@id)[:column]
    # the session vanishes from tmux: ended after the grace, its card released by the watchdog
    @client.live = []
    @now += 61
    @n.watch
    assert_equal "gone from the host's session list", kb.sessions_t.first[:end_reason]
    @now += 61
    assert_equal [@id], @n.watch
  end
end
