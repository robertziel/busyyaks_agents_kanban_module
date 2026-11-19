# frozen_string_literal: true

require "test_helper"
require "stringio"

# The approval prefetch (approval.requires_green_ci): every card sitting in a gate an approval step leaves from keeps
# its step's PR checks asked of the host's ci: port — at the handoff and on every notifier watch pass — so the host's
# poller always holds a fresh answer and Approve answers at once. The answer is the host's to keep; the engine only
# asks (the gate itself still refuses anything but green: store_test test_approval_waits_for_green_ci_at_every_step).
class ApprovalPrefetchTest < Minitest::Test
  include KanbanTest::Setup

  class FakeClient
    def notify(**) = { "ok" => true }
    def agents = { "age_s" => 1, "interval_s" => 5, "sessions" => [] }
    def sessions = [{ "name" => "acme_shop" }]
    def dialog(**) = { "ok" => true, "dialog" => nil }
  end

  HANDOFF = { qa: "Open the page at 375 and 1280 px and check the row", pr_url: "https://github.com/o/r/pull/1",
              ci_url: "https://ci.example.com/job/r/1/", ui_change: false, }.freeze

  def setup
    super
    @m = store(board: KanbanTest.board_hash("local_v4"))
    @log = StringIO.new
    @n = AgentsKanban::Notifier.new(@m, client: FakeClient.new, ci: NoCi.new, clock: -> { @now }, grace: 60, log: @log)
  end

  def card(column = "doing")
    id = @m.create(slug: "p", title: "t", by: "me", column: column)
    @m.update(id, { "assignee" => "claude-shop-lead" }, by: "claude-shop-lead")
    @m.set_owner(id, session: "acme_shop", by: "claude-shop-lead")
    id
  end

  def handed_off
    id = card
    @m.move(id, transition: "Open local PR", by: "claude-shop-lead", agent: true)
    @m.handoff(id, **HANDOFF, by: "claude-shop-lead")
    id
  end

  def asked_ids = approval_ci.asked.map(&:first)

  def test_the_handoff_asks_for_the_gates_approval_checks
    id = handed_off
    step = { from: "local_human_review", to: "local_merged_pr", then: "deploy_check", name: "Approve", final: false }
    assert_equal [[id, step]], approval_ci.asked.uniq, "the handoff's check (+ the returned card's gate_hold)"
  end

  # the operator: "Local: Human review should be after CI passes, not before!" — a handoff into a gate with an approval
  # step is refused, nothing written, until the step's checks are read and green; then the Approve answers at once
  def test_a_handoff_waits_for_green_ci_and_then_approve_answers_on_the_first_click
    id = card
    @m.move(id, transition: "Open local PR", by: "claude-shop-lead", agent: true)
    {
      { number: 7, state: "pending", finished_at: nil } => "PR #7 of card ##{id} — CI is still running",
      { number: 7, state: "failure", finished_at: 5 } => "PR #7 of card ##{id} — CI failed",
      { number: 7, state: "stuck", finished_at: 5 } =>
        "PR #7 of card ##{id} — CI is stuck (pending longer than the host allows)",
      { number: nil, state: "unpolled", finished_at: nil } =>
        "its PR of card ##{id} — CI not read yet (asked now — hand off again in a minute)",
      { number: 7, state: "blocked", finished_at: nil, reason: "the local PR #7 was merged before its approval" } =>
        "card ##{id} — the local PR #7 was merged before its approval",
    }.each do |answer, said|
      approval_ci.answer = answer
      e = assert_raises(AgentsKanban::Invalid) { @m.handoff(id, **HANDOFF, by: "claude-shop-lead") }
      assert_equal "not handed off (→ Local: Human review): #{said}; hand off once CI is green", e.message
      assert_equal ["local_agent_review", nil, nil], @m.card(id).values_at(:column, :handoff_at, :ci_url)
      refute(@m.activity(id).any? { |a| a[:kind] == "handoff" })
      # asked with THIS handoff's ci_url before anything is written: a host may check it is the head's build
      assert_equal ["local_human_review", HANDOFF[:ci_url]], approval_ci.cards.last.values_at(:column, :handoff_ci_url)
    end
    approval_ci.down = "github down"
    e = assert_raises(AgentsKanban::Invalid) { @m.handoff(id, **HANDOFF, by: "claude-shop-lead") }
    assert_match(/not handed off .*CI state of card ##{id} is unknown — github down/, e.message)
    approval_ci.down = nil
    approval_ci.answer = nil
    assert_match(/has no PR whose checks could be read/,
                 assert_raises(AgentsKanban::Invalid) { @m.handoff(id, **HANDOFF, by: "claude-shop-lead") }.message)

    approval_ci.answer = { number: 7, state: "success", finished_at: 5 }
    @m.handoff(id, **HANDOFF, by: "claude-shop-lead")
    assert_equal "local_human_review", @m.card(id)[:column]
    asked = approval_ci.asked.last
    assert_equal [id, "local_human_review", "https://github.com/o/r/pull/1"],
                 [asked[0], *@m.card(id).values_at(:column, :pr_url)], "asked for the card as it sits in the gate"
    @m.approve(id, by: "operator@x")
    refute approval_ci.cards.last.key?(:handoff_ci_url), "an Approve asks about the head's CI, not the handed-over build"
    assert_equal "local_merged_pr", @m.card(id)[:column]
  end

  # each gate an agent hands into asks ITS approval step: Local: Deploy check (the local merge's CI), Public: Human
  # review (the public PR, final)
  def test_every_approval_gate_s_handoff_asks_its_own_step
    { "local_merged_pr" => ["Deploy locally", "deploy_check", false],
      "public_agent_review" => ["Hand over", "public_human_review", true], }.each do |from, (name, gate, final)|
      id = card(from)
      approval_ci.answer = { number: 7, state: "pending", finished_at: nil }
      e = assert_raises(AgentsKanban::Invalid) { @m.handoff(id, **HANDOFF, transition: name, by: "claude-shop-lead") }
      assert_match(/\Anot handed off \(→ #{Regexp.escape(@m.board_of('p').label(gate))}\): PR #7 .* CI is still running/,
                   e.message)
      assert_equal [id, gate, final], [approval_ci.asked.last[0], approval_ci.asked.last[1][:from],
                                       approval_ci.asked.last[1][:final],]
      approval_ci.answer = { number: 7, state: "success", finished_at: 5 }
      @m.handoff(id, **HANDOFF, transition: name, by: "claude-shop-lead")
      assert_equal gate, @m.card(id)[:column]
    end
  end

  # a gate no approval step leaves from (here a second gate the coding board's agents may hand into) never asks CI
  def test_a_gate_with_no_approval_step_is_handed_off_without_asking
    board = KanbanTest.board_hash("coding")
    board["transitions"] << { "name" => "Hand to ready", "from" => "doing", "to" => "ready", "by" => "agent" }
    @m.board_save("o/other", board, by: "operator")
    id = @m.create(slug: "o/other", title: "t", by: "me", column: "doing")
    @m.set_owner(id, session: "acme_shop", by: "claude-shop-lead")
    approval_ci.down = "github down"
    @m.handoff(id, **HANDOFF, transition: "Hand to ready", by: "claude-shop-lead")
    assert_equal "ready", @m.card(id)[:column]
    assert_empty approval_ci.asked
  end

  def test_the_agents_are_told_to_hand_off_on_green_ci
    policy = AgentsKanban::AttachmentPolicy.new(max_bytes: 1000, types: "image/png")
    att = AgentsKanban::Attachments.new(@m, root: Dir.mktmpdir, policy: policy)
    tools = AgentsKanban::Tools.new(store: @m, attachments: att, projects: ->(_s) {}, sessions: -> { [] },
                                    card_url: CARD_URL)
    handoff = tools.definitions.find { |d| d[:name] == "kanban_handoff" }[:description]
    assert_includes handoff, "refused until that step's PR checks are read and green"
    assert_includes tools.instructions, "Hand off only once the PR's CI is green"
  end

  # an error that is not "cannot answer" (a host bug) refuses the handoff before anything is written: the agent's
  # retry is not refused for a handoff half done
  def test_a_port_error_refuses_the_handoff_with_nothing_written
    id = card
    @m.move(id, transition: "Open local PR", by: "claude-shop-lead", agent: true)
    approval_ci.define_singleton_method(:approval_checks) { |*| raise ArgumentError, "host bug" }
    assert_raises(ArgumentError) { @m.handoff(id, **HANDOFF, by: "claude-shop-lead") }
    assert_equal ["local_agent_review", nil], @m.card(id).values_at(:column, :handoff_at)
    refute(@m.activity(id).any? { |a| a[:kind] == "handoff" })
  end

  def test_an_unanswerable_card_is_logged_once_per_reason_and_once_when_it_answers_again
    id = handed_off
    approval_ci.down = "github down"
    2.times { @n.watch }
    approval_ci.down = "rate limited"
    @n.watch
    approval_ci.down = nil
    2.times { @n.watch }
    lines = @log.string.lines.grep(/approval prefetch/).map(&:chomp)
    assert_equal ["approval prefetch: card #{id}: github down", "approval prefetch: card #{id}: rate limited",
                  "approval prefetch: card #{id} answered again",], lines
  end

  def test_a_card_that_left_the_gate_while_unanswerable_is_not_said_to_answer
    id = handed_off
    approval_ci.down = "github down"
    @n.watch
    @m.move(id, transition: "Rework", by: "operator@x")
    approval_ci.down = nil
    @n.watch
    assert_equal 1, @log.string.lines.grep(/approval prefetch/).size
  end

  def test_every_watch_pass_asks_for_each_card_in_an_approval_gate_with_its_step
    gated = handed_off
    later = card("deploy_check")
    final = card("public_human_review")
    others = %w[doing local_agent_review local_merged_pr done].map { |c| card(c) }
    approval_ci.asked.clear
    @now += 30
    @n.watch
    assert_equal [gated, later, final].sort, asked_ids.sort
    steps = approval_ci.asked.to_h
    assert_equal %w[local_human_review deploy_check public_human_review],
                 [gated, later, final].map { |id| steps[id][:from] }
    assert steps[final][:final]
    refute_includes asked_ids, others.first
    @n.watch
    assert_equal 6, approval_ci.asked.size, "asked again on the next pass: the host's request stays fresh"
  end

  def test_a_card_that_left_the_gate_is_no_longer_asked
    id = handed_off
    @m.move(id, transition: "Rework", by: "operator@x")
    approval_ci.asked.clear
    @n.watch
    assert_empty approval_ci.asked
  end

  def test_a_port_that_cannot_answer_one_card_is_logged_and_the_others_are_still_asked
    a = handed_off
    b = card("deploy_check")
    approval_ci.down = "github down"
    approval_ci.asked.clear
    @n.watch
    assert_equal [a, b].sort, asked_ids.sort
    assert_includes @log.string, "approval prefetch: card #{a}: github down"
    assert_includes @log.string, "approval prefetch: card #{b}: github down"
  end

  def test_an_archived_card_is_not_asked
    id = handed_off
    db[:"#{KanbanTest::PREFIX}cards"].where(id: id).update(archived_at: @now)
    approval_ci.asked.clear
    @n.watch
    assert_empty approval_ci.asked
  end

  def test_a_host_without_the_green_ci_gate_asks_nothing
    content = KanbanTest.config("content")
    m = store(content)
    assert_empty m.approval_prefetch_pass
  end

  # ── card #511: every gate the operator can Approve in keeps its reads fresh ─────────────────────────────────────

  # A host's poller as busyyaks runs it (CiChecks): a request not asked again within `window` seconds falls out of
  # the poll — the next ask finds it "not read yet" and asks it afresh; asked within the window it answers green.
  class WindowedCi
    attr_reader :asked

    def initialize(clock, window)
      @clock = clock
      @window = window
      @last = {}
      @asked = []
    end

    def approval_checks(card, step)
      @asked << [card[:id], step[:from]]
      now = @clock.call
      last = @last[card[:id]]
      @last[card[:id]] = now
      return { number: nil, state: "unpolled", finished_at: nil } if last.nil? || now - last > @window

      { number: 7, state: "success", finished_at: 1 }
    end
  end

  WINDOW = 600 # busyyaks: CiChecks.wanted_for(60)
  PASS = 30 # NOTIFIER_WATCH_SECONDS

  # the four gates of the local_v4 board: three an approval step leaves from, and Awaiting merge, which the final step
  # leads into — a card the operator dragged there sits in it UNAPPROVED and is approved in place (card #499)
  def test_each_approval_gate_s_first_approve_succeeds_after_waiting_longer_than_the_poll_window
    ci = WindowedCi.new(-> { @now }, WINDOW)
    m = AgentsKanban::Store.new(db, config: config, markdown: md, boards: ->(s) { @boards.include?(s) },
                                clock: -> { @now }, ci: ci, prs: pr_roles)
    n = AgentsKanban::Notifier.new(m, client: FakeClient.new, ci: NoCi.new, clock: -> { @now }, grace: 60, log: @log)
    gates = %w[local_human_review deploy_check public_human_review awaiting_merge]
    ids = gates.to_h { |g| [g, card(g)] }
    # each card waits in its gate longer than the window, the notifier passing every PASS seconds
    ((2 * WINDOW) / PASS).times do
      @now += PASS
      n.watch
    end
    ids.each do |gate, id|
      assert_includes ci.asked.map(&:first), id, "#{gate}: the prefetch never asked card ##{id}"
      m.approve(id, by: "operator@x") # refused "CI not read yet" when the pass never asked it
      assert m.card(id)[:approved_at], "#{gate}: approved on the first click"
    end
  end

  def test_an_unapproved_card_in_awaiting_merge_is_asked_with_the_final_step
    id = card("awaiting_merge")
    approval_ci.asked.clear
    @n.watch
    step = approval_ci.asked.to_h.fetch(id)
    assert_equal ["public_human_review", "awaiting_merge", true], step.values_at(:from, :to, :final)
  end

  def test_an_approved_card_in_awaiting_merge_is_not_asked_and_said_once
    id = card("awaiting_merge")
    @m.approve(id, by: "operator@x")
    approval_ci.asked.clear
    2.times { @n.watch }
    refute_includes asked_ids, id
    assert_equal ["approval prefetch: card #{id} not asked: approved by operator@x, its agent carries on"],
                 @log.string.lines.grep(/approval prefetch/).map(&:chomp)
  end

  def test_a_gate_card_whose_port_call_raises_is_logged_and_the_others_are_still_asked
    a = card("local_human_review")
    b = card("deploy_check")
    ci = approval_ci
    ci.define_singleton_method(:approval_checks) do |card, step|
      @asked << [card[:id], step]
      raise ArgumentError, "host bug" if card[:id] == a

      @answer
    end
    ci.asked.clear
    2.times { @n.watch }
    assert_equal [a, b, a, b], asked_ids
    assert_equal ["approval prefetch: card #{a}: failed: ArgumentError: host bug"],
                 @log.string.lines.grep(/approval prefetch/).map(&:chomp)
  end

  def test_approval_pending_cards_are_the_cards_the_prefetch_asks_with_their_step
    gated = %w[local_human_review deploy_check public_human_review awaiting_merge].map { |g| card(g) }
    approved = card("awaiting_merge")
    @m.approve(approved, by: "operator@x")
    card("doing")
    pending = @m.approval_pending_cards
    assert_equal gated, pending.map { |c, _| c[:id] }
    assert_equal %w[local_human_review deploy_check public_human_review public_human_review],
                 pending.map { |_, step| step.from }
    approval_ci.asked.clear
    @n.watch
    assert_equal gated, asked_ids
  end
end
