# frozen_string_literal: true

require "test_helper"
require "stringio"

# Approvable now (card #248, the operator: "Tickets waiting to approve that can't be approved due to things like CI etc.
# should not be here!!"): a card in an approval gate counts as waiting for the operator only while its Approve would
# pass now — the step's checks green and the PR still at the head the handoff saw. Otherwise it holds ("waiting for
# CI"): not in the waiting counts (board, Projects, waiting list), its JSON says why; the watch pass pings the owner
# once when its CI turns red and logs once when the hold clears.
class GateHoldTest < Minitest::Test
  include KanbanTest::Setup

  class FakeClient
    def notify(**) = { "ok" => true }
    def agents = { "age_s" => 1, "interval_s" => 5, "sessions" => [] }
    def sessions = [{ "name" => "acme_shop" }]
    def dialog(**) = { "ok" => true, "dialog" => nil }
  end

  HANDOFF = { qa: "Open the page at 375 and 1280 px and check the row", pr_url: "https://github.com/o/r/pull/1",
              ci_url: "https://ci.example.com/job/r/1/", ui_change: false, }.freeze
  GREEN = { number: 7, state: "success", finished_at: 5, head: "a1a1a1a1a1" }.freeze

  def setup
    super
    @m = store(board: KanbanTest.board_hash("local_v4"))
    @projects = { "p" => { slug: "p", path: "/nonexistent", remote: nil } }
    att = AgentsKanban::Attachments.new(@m, root: Dir.mktmpdir,
                                            policy: AgentsKanban::AttachmentPolicy.new(max_bytes: 100, types: "image/png"))
    @api = AgentsKanban::Api.new(store: @m, attachments: att, markdown: md, projects: ->(s) { @projects[s] })
    @log = StringIO.new
    @n = AgentsKanban::Notifier.new(@m, client: FakeClient.new, ci: NoCi.new, clock: -> { @now }, grace: 60, log: @log)
    @id = @m.create(slug: "p", title: "ship", by: "me", column: "doing")
    @m.update(@id, { "assignee" => "claude-shop-lead" }, by: "claude-shop-lead")
    @m.set_owner(@id, session: "acme_shop", by: "claude-shop-lead")
    @m.move(@id, transition: "Open local PR", by: "claude-shop-lead", agent: true)
    approval_ci.answer = GREEN
    @m.handoff(@id, **HANDOFF, by: "claude-shop-lead")
  end

  def board = @api.board("p")[1]
  def boards = @api.boards([@projects["p"]])[1]
  def gate_card = board[:columns].find { |c| c[:column] == "local_human_review" }[:cards].first
  def pings = db[:"#{KanbanTest::PREFIX}card_pings"].where(card_id: @id, reason: "gate_red").all
  def gate_lines = @m.activity(@id).select { |a| a[:kind] == "gate" }.map { |a| a[:body] }

  def counts = [board[:waiting], board[:held], boards[:waiting], boards[:held], @api.waiting([@projects["p"]])[1][:total]]

  def test_a_green_card_waits_for_the_operator
    assert_equal "a1a1a1a1a1", db[:"#{KanbanTest::PREFIX}cards"].where(id: @id).get(:gate_head), "the handoff's head"
    assert_nil gate_card[:gate_hold]
    assert_equal [1, 0, 1, 0, 1], counts
    @n.watch
    assert_empty gate_lines, "handed off green: nothing changed for anyone"
  end

  # reads take the watch pass's view (gate_state): a change shows after the next pass (NOTIFIER_WATCH_SECONDS)
  def test_pending_holds_it_out_of_the_waiting_counts_then_green_counts_it_once
    approval_ci.answer = { number: 7, state: "pending", finished_at: nil }
    assert_equal [1, 0, 1, 0, 1], counts, "until the watch pass looks, the handoff's green view stands"
    asked = approval_ci.asked.size
    counts
    assert_equal asked, approval_ci.asked.size, "a read asks nothing: it takes the watch pass's view"
    @n.watch
    assert_equal "PR #7: CI is still running", gate_card[:gate_hold]
    assert_equal [0, 1, 0, 1, 0], counts
    held = @api.waiting([@projects["p"]])[1][:held]
    assert_equal [["p", 1, "PR #7: CI is still running"]], held.map { |g| [g[:slug], g[:count], g[:cards][0][:gate_hold]] }
    assert_empty pings, "pending: nobody to ping"
    approval_ci.answer = GREEN
    2.times { @n.watch }
    assert_equal ["ready for your approval: Local: Human review, CI green (was: PR #7: CI is still running)"], gate_lines
    assert_equal [1, 0, 1, 0, 1], counts
  end

  def test_red_holds_it_and_pings_the_owner_once_per_ci_completion
    approval_ci.answer = { number: 7, state: "failure", finished_at: 9 }
    2.times { @n.watch }
    assert_equal "PR #7: CI failed", gate_card[:gate_hold]
    assert_equal [0, 1, 0, 1, 0], counts
    assert_equal 1, pings.size
    assert_match(/PR #7: CI failed while card ##{@id} "ship" waits in Local: Human review — fix it/, pings[0][:text])
    assert_equal ["waiting for CI: PR #7: CI failed — pinged acme_shop"], gate_lines
    assert_includes @log.string, "gate watch: card #{@id} CI failed, owner pinged"
    approval_ci.answer = { number: 7, state: "pending", finished_at: nil } # a re-run …
    @n.watch
    approval_ci.answer = { number: 7, state: "failure", finished_at: 9 } # … that answers the same completion: no ping
    @n.watch
    red = -> { gate_lines.count { |l| l.start_with?("waiting for CI: PR #7: CI failed") } } # a ping each (pending pings merge)
    assert_equal 1, red.call
    approval_ci.answer = { number: 7, state: "failure", finished_at: 20 } # a new red completion, no pending seen between
    @n.watch
    assert_equal 2, red.call, "red → red: a new CI completion is told even with the same words"
    @n.watch
    assert_equal 2, red.call, "the same completion once"
    approval_ci.answer = { number: 7, state: "pending", finished_at: nil }
    @n.watch
    approval_ci.answer = { number: 7, state: "failure", finished_at: 31 }
    @n.watch
    assert_equal 3, red.call, "one ping per red CI completion"
    assert_equal 3, pings.first[:text].scan("CI failed while").size, "all in the owner's (merged) ping"
  end

  # a host's own words for red (busyyaks: the merge commit's CI at Local deploy check) still ping: red = state failure
  def test_a_red_answer_with_the_host_s_reason_pings
    approval_ci.answer = { number: 7, state: "failure", finished_at: 9, reason: "jenkins/ci for the merge is failure" }
    @n.watch
    assert_equal 1, pings.size
    assert_equal ["waiting for CI: jenkins/ci for the merge is failure — pinged acme_shop"], gate_lines
  end

  def test_red_with_no_owner_session_is_said_so
    @m.set_owner(@id, session: "", by: "operator@x")
    approval_ci.answer = { number: 7, state: "failure", finished_at: 9 }
    @n.watch
    assert_empty pings
    assert_includes @log.string, "gate watch: card #{@id} CI failed, no owner session to ping"
  end

  def test_new_commits_after_the_handoff_hold_it_and_refuse_the_approval
    approval_ci.answer = GREEN.merge(head: "b2b2b2b2b2")
    @n.watch
    moved = "new commits since the handoff (a1a1a1a → b2b2b2b): the reviewer has not seen them"
    assert_equal moved, gate_card[:gate_hold]
    assert_equal [0, 1, 0, 1, 0], counts
    e = assert_raises(AgentsKanban::Invalid) { @m.approve(@id, by: "operator@x") }
    assert_equal "not approved (Local: Human review → Local: Merged): card ##{@id} — #{moved}; hand it back for review",
                 e.message
  end

  def test_an_unreadable_ci_holds_it
    approval_ci.down = "github down"
    @n.watch
    assert_equal "CI state unknown — github down", gate_card[:gate_hold]
    assert_equal [0, 1, 0, 1, 0], counts
  end

  # any move but the handoff ends the gate's head and view: a drag into another gate is read live, with no old head
  def test_a_drag_into_another_gate_starts_with_nothing_recorded
    @m.move(@id, column: "public_human_review", by: "operator@x")
    row = db[:"#{KanbanTest::PREFIX}cards"].where(id: @id).first
    assert_equal [nil, nil], row.values_at(:gate_head, :gate_state)
    approval_ci.answer = GREEN.merge(head: "c3c3c3c3c3")
    assert_nil board[:columns].find { |c| c[:column] == "public_human_review" }[:cards].first[:gate_hold],
               "no head recorded: green is approvable"
  end

  def test_a_flagged_card_still_waits_for_the_operator
    approval_ci.answer = { number: 7, state: "pending", finished_at: nil }
    @n.watch
    @m.ask(@id, question: "merge order?", by: "claude-shop-lead")
    assert_equal [1, 0, 1, 0, 1], counts
  end
end
