# frozen_string_literal: true

require "test_helper"
require "set"
require "stringio"

# A board's running lead hears about its workers without polling: one ping on ask, handoff, block, session
# end and the progress watch's first step; none on a comment, when the lead acted, or with no lead running.
class LeadPingsTest < Minitest::Test
  include KanbanTest::Setup

  N = 30 * 60
  LEAD = "shop_lead"
  WORKER = "shop_worker"
  AGENT = "worker-shop_worker"
  URL = "https://ci.example.com/1"

  class Client
    attr_accessor :busy, :answer
    attr_reader :sent, :calls

    def initialize = (@sent = []; @busy = []; @calls = [])
    def sessions = []
    def dialog(**) = { "ok" => true, "dialog" => nil }

    def notify(session:, socket:, text:)
      @calls << [session, text]
      raise @answer if @answer.is_a?(Exception)
      return @answer if @answer
      return { "ok" => false, "error" => "busy" } if @busy.include?(session)

      @sent << [session, text]
      { "ok" => true }
    end
  end

  def raw_config
    raw = JSON.parse(File.read(File.join(KanbanTest::ROOT, "fixtures/boards/coding.json")))
    raw["table_prefix"] = KanbanTest::PREFIX
    raw["agent_types"] << { "key" => "worker", "label" => "Worker", "launchers" => %w[fullclaude localclaude],
                            "model" => { "fullclaude" => "opus", "localclaude" => nil }, "under" => "lead",
                            "prompt" => "Worker {session}", "agent_name" => "worker-{session}",
                            "session_name" => "{slug}_worker", "takes" => [], "max" => nil, "max_per_project" => nil, }
    raw
  end

  def config = (@cfg ||= AgentsKanban::HostConfig.new(raw_config))

  def setup
    super
    @lead = kb.register_session(session: LEAD, project: "p", type: "lead", launcher: "fullclaude", by: "op")
    @reg = kb.register_session(session: WORKER, project: "p", type: "worker", launcher: "fullclaude", by: "op",
                               lead_id: @lead[:id])
    @id = kb.create(slug: "p", title: "ship it", by: AGENT, column: "doing")
    kb.set_owner(@id, session: WORKER, by: "op")
    pings_t.delete
  end

  def pings_t = db[:"#{KanbanTest::PREFIX}card_pings"]
  def to_lead = pings_t.where(session: LEAD).all
  def lead_name = kb.open_session(LEAD)[:agent_name]

  def assert_one(reason, text)
    assert_equal [reason], to_lead.map { |p| p[:reason] }
    assert_includes to_lead.first[:text], text
  end

  def end_lead! = kb.sessions_t.where(session: LEAD).update(ended_at: @now, end_reason: "gone")

  def test_ask_pings_the_lead_once
    kb.ask(@id, question: "merge it?", by: AGENT)
    assert_one "lead_ask", "merge it?"
  end

  def test_block_pings_the_lead_once
    kb.block(@id, reason: "CI down", url: URL, by: AGENT)
    assert_one "lead_block", "CI down"
  end

  def test_handoff_pings_the_lead_once
    kb.move(@id, column: "qa", by: AGENT, agent: true)
    kb.handoff(@id, qa: "open the page and check the title", pr_url: "https://github.com/o/r/pull/7", ci_url: URL,
                    ui_change: false, by: AGENT)
    assert_one "lead_handoff", "pull/7"
  end

  def test_a_comment_does_not_ping_the_lead
    kb.comment(@id, body: "progress", author: AGENT)
    assert_empty to_lead
  end

  def test_session_gone_pings_the_lead_once_naming_its_cards
    other = kb.create(slug: "p", title: "two", by: AGENT, column: "doing")
    kb.set_owner(other, session: WORKER, by: "op")
    pings_t.delete
    kb.sessions_sync(Set[LEAD], grace: 0)
    assert_one "lead_session_end", "card ##{@id}, card ##{other}"
    kb.sessions_sync(Set[LEAD], grace: 0)
    assert_equal 1, to_lead.size
  end

  def test_the_watchdog_keeps_the_leads_ping_about_the_card_it_releases
    kb.sessions_sync(Set[LEAD], grace: 0)
    2.times { kb.watch_owners(Set[LEAD], grace: 0) }
    assert_nil kb.card(@id)[:owner_session]
    assert_equal ["pending"], to_lead.map { |p| p[:status] }
  end

  def test_a_session_end_the_watchdog_finds_first_pings_the_lead_once
    2.times { kb.watch_owners(Set[LEAD], grace: 0) }
    assert_equal ["lead_session_end"], to_lead.map { |p| p[:reason] }
    assert_equal ["pending"], to_lead.map { |p| p[:status] }
  end

  def test_a_session_holding_no_open_card_pings_nobody
    kb.set_owner(@id, session: "", by: "op")
    pings_t.delete
    kb.end_session(WORKER, reason: "done", by: "op")
    assert_empty to_lead
  end

  def test_none_when_the_lead_is_the_actor
    kb.ask(@id, question: "merge it?", by: lead_name)
    kb.block(@id, reason: "CI down", url: URL, by: LEAD)
    assert_empty to_lead
    kb.end_session(WORKER, reason: "start failed", by: lead_name)
    assert_empty to_lead
  end

  def test_none_when_no_lead_runs
    end_lead!
    kb.ask(@id, question: "merge it?", by: AGENT)
    kb.end_session(WORKER, reason: "done", by: "op")
    assert_empty to_lead
  end

  def test_a_lead_gone_in_the_same_pass_hears_nothing
    kb.sessions_sync(Set[], grace: 0)
    assert_empty to_lead
  end

  def test_a_card_the_lead_owns_itself_pings_nobody_extra
    kb.set_owner(@id, session: LEAD, by: "op")
    pings_t.delete
    kb.ask(@id, question: "merge it?", by: "someone")
    assert_empty to_lead
  end

  def test_the_leads_ping_is_delivered_while_the_worker_is_busy
    client = Client.new
    client.busy = [WORKER]
    n = AgentsKanban::Notifier.new(kb, client: client, ci: NoCi.new, clock: -> { @now }, log: StringIO.new)
    kb.comment(@id, body: "from the operator", author: "op", operator: true)
    kb.ask(@id, question: "merge it?", by: AGENT)
    n.deliver
    assert_equal [LEAD], client.sent.map(&:first)
    assert_equal "pending", pings_t.where(session: WORKER).get(:status)
  end

  def test_a_full_batch_of_worker_pings_does_not_hold_the_lead_back
    25.times do |i|
      pings_t.insert(card_id: @id, session: "busy_#{i}", socket: "default", text: "x", reason: "comment",
                     status: "pending", created_at: @now - 100)
    end
    kb.ask(@id, question: "merge it?", by: AGENT)
    assert_includes kb.next_pings.map { |p| p[:session] }, LEAD
  end

  # a burst past the row's limit opens a new pending row, the newest event is never cut
  def test_a_long_burst_keeps_the_leads_last_event
    6.times { |i| kb.ask(@id, question: "question #{i} #{'x' * 1400}", by: AGENT) }
    kb.ask(@id, question: "THE LAST EVENT", by: AGENT)
    rows = to_lead.sort_by { |p| p[:id] }
    assert_operator rows.size, :>, 1
    assert(rows.all? { |p| p[:text].length <= AgentsKanban::Store::MAX_PING_TEXT && p[:status] == "pending" })
    assert_includes rows.last[:text], "THE LAST EVENT"
    6.times { |i| assert_equal 1, rows.count { |p| p[:text].include?("question #{i} ") }, "event #{i} once" }
  end

  # Hermes: a ping pasted but not submitted waits in the composer and is recognised by its EXACT text, so the
  # text of a row a delivery has tried never changes: a new event opens the next row.
  def test_a_row_a_delivery_tried_keeps_its_text_and_the_next_event_opens_a_row
    kb.ask(@id, question: "first", by: AGENT)
    row = to_lead.first
    kb.ping_result(row, "pending", error: "a dialog is on its screen (the line waits in its input)")
    kb.block(@id, reason: "second", url: URL, by: AGENT)
    rows = to_lead.sort_by { |p| p[:id] }
    assert_equal 2, rows.size
    assert_equal row[:text], rows.first[:text]
    assert_includes rows.last[:text], "second"
    kb.unblock(@id, by: AGENT)
    kb.block(@id, reason: "third", url: URL, by: AGENT)
    assert_equal 2, to_lead.size, "a row not tried yet still takes the burst"
    assert_includes to_lead.max_by { |p| p[:id] }[:text], "third"
  end

  # the notifier held the ping back for a dialog: nothing was typed, so the row may still take the burst
  def test_a_ping_held_back_before_any_typing_still_coalesces
    client = Client.new
    client.define_singleton_method(:dialog) { |**|
 { "ok" => true, "dialog" => { "kind" => "permission", "hash" => "a" * 64, "options" => [] } } }
    n = AgentsKanban::Notifier.new(kb, client: client, ci: NoCi.new, clock: -> { @now }, log: StringIO.new)
    n.instance_variable_set(:@settle, 30) # the dialog has not settled yet: the ping just waits
    kb.ask(@id, question: "first", by: AGENT)
    n.deliver
    assert_empty client.sent
    assert_equal [0], to_lead.map { |p| p[:attempts] }
    kb.block(@id, reason: "second", url: URL, by: AGENT)
    assert_equal 1, to_lead.size
  end

  # the launcher refuses a text over 8000 characters: a session holding very many cards is told in several rows
  def test_one_event_longer_than_a_row_is_split_with_nothing_lost
    ids = [@id] + Array.new(900) do
      id = kb.create(slug: "p", title: "c", by: AGENT, column: "doing")
      kb.set_owner(id, session: WORKER, by: "op")
      id
    end
    pings_t.delete
    kb.end_session(WORKER, reason: "gone", by: "op")
    rows = to_lead.sort_by { |p| p[:id] }
    assert_operator rows.sum { |p| p[:text].length }, :>, AgentsKanban::Store::MAX_PING_TEXT
    assert_operator rows.size, :>, 1
    assert(rows.all? { |p| p[:text].length <= AgentsKanban::Store::MAX_PING_TEXT })
    named = rows.flat_map { |p| p[:text].scan(/card #(\d+)/).flatten.map(&:to_i) }
    assert_equal ids.sort, named.sort, "read row by row: every card once, no number cut in two"
  end

  # ── delivery: one attempt per session per pass, its oldest row first ──

  def notifier(client) = AgentsKanban::Notifier.new(kb, client: client, ci: NoCi.new, clock: -> { @now }, log: StringIO.new)

  def a_card(title)
    id = kb.create(slug: "p", title: title, by: AGENT, column: "doing")
    kb.set_owner(id, session: WORKER, by: "op")
    id
  end

  def test_a_burst_to_a_busy_lead_is_one_call_per_pass_in_order_with_nothing_lost
    ids = Array.new(10) { |i| a_card("card #{i}") }
    pings_t.delete
    ids.each_with_index { |id, i| kb.ask(id, question: "question #{i}", by: AGENT) }
    client = Client.new
    client.busy = [LEAD]
    n = notifier(client)
    3.times { n.deliver }
    assert_equal 3, client.calls.size, "one attempt per pass"
    assert_equal 1, client.calls.map(&:last).uniq.size, "always its oldest row"
    assert_includes client.calls.first.last, "question 0"
    client.busy = []
    10.times { n.deliver }
    assert_equal (0...10).map { |i| "question #{i}" }, client.sent.map { |_, t| t[/question \d+/] }
    assert_equal %w[sent], to_lead.map { |p| p[:status] }.uniq
  end

  def test_one_session_waiting_never_holds_another_back
    kb.ask(@id, question: "for the lead", by: AGENT)
    kb.comment(@id, body: "for the worker", author: "op", operator: true)
    client = Client.new
    client.busy = [WORKER]
    notifier(client).deliver
    assert_equal [LEAD, WORKER], client.calls.map(&:first)
    assert_equal [LEAD], client.sent.map(&:first)
  end

  def test_a_stuck_row_gives_up_and_the_next_gets_its_own_window
    other = a_card("second")
    pings_t.delete
    kb.ask(@id, question: "stuck", by: AGENT)
    @now += 60
    kb.ask(other, question: "next", by: AGENT)
    client = Client.new
    client.busy = [LEAD]
    n = notifier(client)
    @now += (30 * 60) + 1
    n.deliver
    assert_equal %w[failed pending], to_lead.sort_by { |p| p[:id] }.map { |p| p[:status] }, "the give-up releases it"
    @now += 60
    n.deliver
    assert_equal "pending", to_lead.max_by { |p| p[:id] }[:status], "it waited behind the stuck row: not given up on sight"
    client.busy = []
    n.deliver
    assert_equal %w[failed sent], to_lead.sort_by { |p| p[:id] }.map { |p| p[:status] }
    assert_includes client.sent.last.last, "next"
  end

  # ── which row of a session goes first: typed, the operator's, lead events, the rest ──

  def row!(reason, attempts: 0, session: WORKER, at: @now)
    pings_t.insert(card_id: @id, session: session, socket: "default", text: "row #{reason}", reason: reason,
                   status: "pending", attempts: attempts, created_at: at)
  end

  def head(session = WORKER) = kb.next_pings.find { |p| p[:session] == session }

  def test_a_session_tries_typed_then_the_operators_then_lead_events_then_the_rest
    pings_t.delete
    rest = row!("ci_idle", at: 1)
    lead = row!("lead_ask", at: 2)
    move = row!("move", at: 3)
    answer = row!("answer", at: 4)
    typed = row!("progress", attempts: 1, at: 5)
    [typed, move, answer, lead, rest].each do |id|
      assert_equal id, head[:id]
      kb.ping_result(head, "sent")
    end
    assert_nil head
  end

  def test_an_operators_answer_goes_before_two_stuck_rows_nothing_was_typed_from
    pings_t.delete
    2.times { row!("ci_idle", at: @now - 100) }
    kb.ask(@id, question: "which?", by: AGENT)
    pings_t.where(session: LEAD).delete
    kb.comment(@id, body: "this one", author: "operator@x", operator: true)
    assert_equal "answer", head[:reason]
    assert_includes head[:text], "this one"
  end

  def test_every_operator_kind_outranks_the_rest_and_an_agents_comment_does_not
    pings_t.delete
    row!("ci_idle", at: @now - 100)
    kb.comment(@id, body: "from an agent", author: "someone-else")
    assert_equal "ci_idle", head[:reason], "an agent's comment is the rest"
    kb.comment(@id, body: "from the operator", author: "operator@x", operator: true)
    assert_includes head[:text], "from the operator", "joined into the row, which now ranks as the operator's"
  end

  def test_an_operators_comment_still_reads_comment_on_the_card
    pings_t.delete
    kb.comment(@id, body: "hello", author: "operator@x", operator: true)
    assert_includes head[:text], "New comment on card"
    assert_equal "comment", kb.ping_json(kb.pings(@id).first)[:reason]
    kb.ping_result(head, "sent")
    assert_equal "pinged #{WORKER} (comment)", kb.activity(@id).last[:body]
  end

  def test_an_answer_behind_a_typed_row_waits_and_the_card_says_why
    pings_t.delete
    row!("ci_idle", attempts: 1, at: @now - 100)
    row!("progress", attempts: 1, at: @now - 90)
    kb.ask(@id, question: "which?", by: AGENT)
    pings_t.where(session: LEAD).delete
    kb.comment(@id, body: "this one", author: "operator@x", operator: true)
    assert_equal "ci_idle", head[:reason], "what sits in the composer goes first"
    answer = kb.pings(@id).find { |p| p[:reason] == "answer" }
    assert_equal 2, kb.ping_json(answer)[:queued_behind]
    assert_nil kb.ping_json(kb.pings(@id).find { |p| p[:reason] == "ci_idle" })[:queued_behind], "the one being tried"
    kb.ping_result(head, "sent")
    assert_equal 1, kb.ping_json(kb.pings(@id).find { |p| p[:reason] == "answer" })[:queued_behind]
  end

  def test_a_card_number_on_the_window_edge_stays_with_its_word
    max = AgentsKanban::Store::MAX_PING_TEXT
    text = "#{'x' * (max - 6)} card #12345 end"
    assert_equal " ", text[max - 1]
    assert_equal "#", text[max]
    got = kb.send(:ping_parts, text)
    assert_equal text, got.join
    assert got.last.start_with?("card #12345"), got.last[0, 20]
    two = "#{'x' * (max - 7)} card  #12345 end"
    assert kb.send(:ping_parts, two).last.start_with?("card  #12345"), "two spaces too"
  end

  # ── what an answer says was typed: only an explicit `typed: false` leaves a row open to the burst ──

  { "nothing typed" => [{ "ok" => false, "typed" => false, "error" => "input_busy" }, 0, 1],
    "typed" => [{ "ok" => false, "typed" => true, "error" => "a dialog (the line waits in its input)" }, 1, 2],
    "the port does not say" => [{ "ok" => false, "error" => "tmux failed" }, 1, 2], }.each do |what, (answer, tries, rows)|
    define_method(:"test_an_answer_of_#{what.tr(' ', '_')}") do
      kb.ask(@id, question: "first", by: AGENT)
      client = Client.new
      client.answer = answer
      notifier(client).deliver
      assert_equal [tries], to_lead.map { |p| p[:attempts] }
      kept = to_lead.first[:text]
      kb.block(@id, reason: "second", url: URL, by: AGENT)
      assert_equal rows, to_lead.size
      assert_equal kept, to_lead.min_by { |p| p[:id] }[:text] if rows == 2
    end
  end

  def test_a_call_that_broke_midway_counts_as_typed
    kb.ask(@id, question: "first", by: AGENT)
    client = Client.new
    client.answer = AgentsKanban::Delivery::Unavailable.new("launcher went away")
    notifier(client).deliver
    row = to_lead.first
    assert_equal ["pending", 1, "launcher went away"], row.values_at(:status, :attempts, :error)
    kb.block(@id, reason: "second", url: URL, by: AGENT)
    assert_equal 2, to_lead.size, "it may sit in the input: its text stays"
  end

  def test_an_over_long_text_with_no_separator_is_cut_with_nothing_lost
    max = AgentsKanban::Store::MAX_PING_TEXT
    { "x" * ((2 * max) + 5) => 3, "word " * max => 2 }.each do |text, parts|
      got = kb.send(:ping_parts, text)
      assert_equal text, got.join
      assert_operator got.size, :>=, parts
      assert(got.all? { |part| part.length <= max })
    end
  end

  # only the cards a new worker can act on are named for kanban_spawn
  def test_session_end_names_for_spawn_only_what_a_worker_can_act_on
    gate = kb.create(slug: "p", title: "waits", by: AGENT, column: "doing")
    kb.set_owner(gate, session: WORKER, by: "op")
    kb.move(gate, column: "human_check", by: "op")
    approved = kb.create(slug: "p", title: "approved", by: AGENT, column: "doing")
    kb.set_owner(approved, session: WORKER, by: "op")
    kb.move(approved, column: "human_check", by: "op")
    kb.approve(approved, by: "op")
    asked = kb.create(slug: "p", title: "asked", by: AGENT, column: "doing")
    kb.set_owner(asked, session: WORKER, by: "op")
    kb.ask(asked, question: "which one?", by: AGENT)
    pings_t.delete
    kb.end_session(WORKER, reason: "done", by: "op")
    text = to_lead.first[:text]
    spawn = text[/kanban_spawn[^:]*: ([^.]*)\./, 1]
    waits = text[/Waiting for the operator[^:]*: ([^.]*)\./, 1]
    assert_equal ["card ##{@id}", "card ##{approved}"], spawn.split(", ")
    assert_equal ["card ##{gate}", "card ##{asked}"], waits.split(", ")
  end

  def test_session_end_holding_only_operator_cards_asks_for_no_spawn
    kb.move(@id, column: "human_check", by: "op")
    pings_t.delete
    kb.end_session(WORKER, reason: "done", by: "op")
    refute_includes to_lead.first[:text], "kanban_spawn"
    assert_includes to_lead.first[:text], "Waiting for the operator"
  end

  # ── the progress watch: an approved gate card its agent must carry on ──

  def approve!
    kb.move(@id, column: "human_check", by: "op")
    kb.approve(@id, by: "op")
    assert_equal "ready", kb.card(@id)[:column]
    pings_t.delete
    @t = @now
  end

  def sent! = pings_t.where(status: "pending").update(status: "sent")
  def progress_to(session) = pings_t.where(session: session, reason: session == LEAD ? "lead_progress" : "progress").count

  def test_a_quiet_approved_gate_card_pings_owner_and_lead_once_per_stretch
    approve!
    @now = @t + N - 1
    assert_equal [], kb.progress_watch_pass, "the stretch starts at the approval"
    @now = @t + N
    assert_equal [[@id, :ping]], kb.progress_watch_pass
    assert_equal [1, 1], [progress_to(WORKER), progress_to(LEAD)]
    assert_includes pings_t.where(session: WORKER).get(:text), "It is approved"
    sent!
    assert_equal [], kb.progress_watch_pass
    @now = @t + (2 * N)
    assert_equal [[@id, :comment]], kb.progress_watch_pass
    assert_equal [1, 1], [progress_to(WORKER), progress_to(LEAD)], "only the first step tells the lead"
    kb.comment(@id, body: "merging now", author: AGENT)
    sent!
    @now += 1
    kb.progress_watch_pass # the comment starts a new stretch
    @now += N
    assert_equal [[@id, :ping]], kb.progress_watch_pass
    assert_equal [2, 2], [progress_to(WORKER), progress_to(LEAD)], "a new stretch: once more"
  end

  def test_an_approved_card_escalated_to_the_last_step_waits_for_the_operator
    approve!
    assert_equal 1, kb.waiting_counts(["p"]).approved["p"].to_i
    3.times { |i| (@now = @t + ((i + 1) * N)) && kb.progress_watch_pass }
    counts = kb.waiting_counts(["p"])
    assert_equal [1, 0], [counts.waiting["p"].to_i, counts.approved["p"].to_i]
  end

  def test_an_unapproved_gate_card_stays_out_of_the_watch
    kb.move(@id, column: "human_check", by: "op")
    pings_t.delete
    @now += 10 * N
    assert_equal [], kb.progress_watch_pass
    assert_empty to_lead
  end

  def test_a_quiet_working_card_tells_the_lead_too
    @now += N
    kb.progress_watch_pass
    @now += N
    kb.progress_watch_pass
    assert_equal 1, progress_to(LEAD)
  end
end

# Wherever the progress watch pings about an approved card, on the local_v4 board's three kinds of
# approved column (review, working, gate), it says what the CI of the step that approved the card says.
module ApprovedNudge
  N = 30 * 60
  GREEN = { number: 7, state: "success", finished_at: 5, head: "a1a1a1a1a1" }.freeze
  # the approval gate → the column the approval puts the card in → the label of the agent's next step
  STEPS = { "local_merged_pr" => ["local_human_review", "Local: Deploy check"],
            "public_create_pr" => ["deploy_check", "Public: Agent review"],
            "awaiting_merge" => %w[public_human_review Done], }.freeze

  def approve_into(column)
    @id = @m.create(slug: "p", title: "ship", by: "me", column: "doing")
    @m.set_owner(@id, session: "acme_shop", by: "op")
    approval_ci.answer = GREEN
    @m.move(@id, column: STEPS.fetch(column).first, by: "op")
    @m.approve(@id, by: "op")
    assert_equal column, @m.card(@id)[:column]
    db[:"#{KanbanTest::PREFIX}card_pings"].delete
    approval_ci.asked.clear
    @now += N
  end

  def nudge
    assert_equal [[@id, :ping]], @m.progress_watch_pass
    db[:"#{KanbanTest::PREFIX}card_pings"].where(reason: "progress").get(:text)
  end
end

class LeadPingsCiHoldTest < Minitest::Test
  include KanbanTest::Setup
  include ApprovedNudge

  def setup
    super
    @m = store(board: KanbanTest.board_hash("local_v4", green_ci: true))
  end

  STEPS.each do |column, (gate, nxt)|
    define_method(:"test_#{column}_green_says_take_the_next_step") do
      approve_into(column)
      assert_includes nudge, "It is approved: take its next step (#{nxt})"
      assert_equal gate, approval_ci.asked.last.last[:from], "the step that approved it is asked"
    end

    { "failure" => "PR #7: CI failed", "pending" => "PR #7: CI is still running" }.each do |state, says|
      define_method(:"test_#{column}_#{state}_is_a_hold") do
        approve_into(column)
        approval_ci.answer = GREEN.merge(state: state)
        text = nudge
        refute_includes text, "take its next step"
        assert_includes text, "It is approved but held: #{says}. Its next step (#{nxt}) waits for green checks"
      end
    end

    define_method(:"test_#{column}_unreadable_ci_is_said_never_read_as_green") do
      approve_into(column)
      approval_ci.down = "GitHub is down"
      text = nudge
      refute_includes text, "take its next step"
      assert_includes text, "CI state unknown — GitHub is down"
    end

    define_method(:"test_#{column}_a_conflict_is_a_hold") do
      approve_into(column)
      approval_ci.answer = GREEN.merge(rebase: { state: "conflicts", base: "local", base_sha: "b" * 40 })
      text = nudge
      refute_includes text, "take its next step"
      assert_includes text, "conflicts with local"
    end
  end

  STEPS.each do |column, (gate, nxt)|
    define_method(:"test_#{column}_an_unread_row_says_unread_never_a_hold") do
      approve_into(column)
      approval_ci.answer = { number: nil, state: "unpolled", finished_at: nil }
      text = nudge
      assert_includes text, "It is approved; its CI is not read yet (asked now). Read its checks before its next step (#{nxt})"
      refute_includes text, "held"
      refute_includes text, "take its next step"
    end

    define_method(:"test_#{column}_an_unread_answer_says_the_ports_own_words") do
      approve_into(column)
      why = "the PR's mergeable state is not read yet (asked now)"
      approval_ci.answer = { number: 7, state: "unpolled", finished_at: nil, reason: why }
      text = nudge
      assert_includes text, "It is approved; #{why}. Read its checks before its next step (#{nxt})"
      refute_includes text, "held"
    end

    define_method(:"test_#{column}_stays_asked_on_every_pass") do
      approve_into(column)
      2.times { assert_equal [[@id, "success"]], @m.approved_ci_pass }
      assert_equal [gate, gate], approval_ci.asked.map { |_, step| step[:from] }
    end
  end

  def test_the_approved_ci_pass_says_a_port_that_cannot_answer_and_goes_on
    approve_into("local_merged_pr")
    approval_ci.down = "GitHub is down"
    assert_equal [[@id, "unavailable: GitHub is down"]], @m.approved_ci_pass
  end

  def test_the_approved_ci_pass_asks_no_unapproved_held_or_archived_card
    approve_into("awaiting_merge")
    @m.hold(@id, by: "op")
    other = @m.create(slug: "p", title: "not approved", by: "me", column: "local_merged_pr")
    @m.set_owner(other, session: "acme_shop", by: "op")
    assert_equal [], @m.approved_ci_pass
    assert_empty approval_ci.asked
  end

  def test_the_notifier_keeps_an_approved_card_asked_and_says_a_failure_once
    approve_into("public_create_pr")
    client = Class.new do
      def sessions = [{ "name" => "acme_shop" }]
      def agents = { "age_s" => 1, "interval_s" => 5, "sessions" => [] }
      def dialog(**) = { "ok" => true, "dialog" => nil }
    end.new
    log = StringIO.new
    n = AgentsKanban::Notifier.new(@m, client: client, ci: NoCi.new, clock: -> { @now }, grace: 60, log: log)
    n.watch
    assert_includes approval_ci.asked.map { |id, step| [id, step[:from]] }, [@id, "deploy_check"]
    approval_ci.down = "GitHub is down"
    2.times { n.watch }
    assert_equal 1, log.string.scan("approved CI: card #{@id}: GitHub is down").size
    approval_ci.down = nil
    n.watch
    assert_includes log.string, "approved CI: card #{@id} answered again"
  end

  def test_a_card_that_is_not_approved_gets_no_approval_wording
    @id = @m.create(slug: "p", title: "ship", by: "me", column: "local_merged_pr")
    @m.set_owner(@id, session: "acme_shop", by: "op")
    db[:"#{KanbanTest::PREFIX}card_pings"].delete
    @now += N
    refute_includes nudge, "approved"
    assert_empty approval_ci.asked
  end
end

# A gate that does not wait for green CI (requires_green_ci off) has no CI question: nothing is asked, and it says so.
class LeadPingsNoCiStepTest < Minitest::Test
  include KanbanTest::Setup
  include ApprovedNudge

  def setup
    super
    @m = store(board: KanbanTest.board_hash("local_v4"))
  end

  STEPS.each do |column, (_gate, nxt)|
    define_method(:"test_#{column}_says_its_step_asks_no_ci") do
      approve_into(column)
      assert_includes nudge, "It is approved; this step asks no CI: take its next step (#{nxt})"
      assert_empty approval_ci.asked
    end
  end
end
