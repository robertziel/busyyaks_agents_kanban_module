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
    @m = store(board: KanbanTest.board_hash("local_v3"))
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
      { number: nil, state: "unpolled", finished_at: nil } =>
        "its PR of card ##{id} — CI not read yet (asked now — hand off again in a minute)",
      { number: 7, state: "blocked", finished_at: nil, reason: "the local PR #7 was merged before its approval" } =>
        "card ##{id} — the local PR #7 was merged before its approval",
    }.each do |answer, said|
      approval_ci.answer = answer
      e = assert_raises(AgentsKanban::Invalid) { @m.handoff(id, **HANDOFF, by: "claude-shop-lead") }
      assert_equal "not handed off (→ Local: Human review): #{said}; hand off once CI is green", e.message
      assert_equal ["local_agent_review", nil], @m.card(id).values_at(:column, :handoff_at)
      refute(@m.activity(id).any? { |a| a[:kind] == "handoff" })
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
    others = %w[doing local_agent_review local_merged_pr awaiting_merge done].map { |c| card(c) }
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
end
