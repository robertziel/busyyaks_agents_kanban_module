# frozen_string_literal: true

require "test_helper"
require "stringio"

# Card #497, the operator: "Approve merge should proceed with rebase and merge!" — an approval on a PR whose checks
# are green but which conflicts with its base (the ci: port's green answer carries rebase:) is accepted: the card moves
# along the step, is marked needs rebase (card JSON) and the owner gets ONE ping to rebase, re-run CI and merge on
# green. Its onward move is held until the step's checks answer green with no conflict; every other refusal stands.
class RebaseApprovalTest < Minitest::Test
  include KanbanTest::Setup

  class FakeClient
    def notify(**) = { "ok" => true }
    def agents = { "age_s" => 1, "interval_s" => 5, "sessions" => [] }
    def sessions = [{ "name" => "acme_shop" }]
    def dialog(**) = { "ok" => true, "dialog" => nil }
  end

  HANDOFF = { qa: "Open the page at 375 and 1280 px and check the row", pr_url: "https://github.com/o/r/pull/1",
              ci_url: "https://ci.example.com/job/r/1/", ui_change: false, }.freeze
  SHA = "b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"
  GREEN = { number: 7, state: "success", finished_at: 5, head: "a1a1a1a1a1" }.freeze
  CONFLICT = GREEN.merge(rebase: { state: "conflicts", base: "local", base_sha: SHA }).freeze
  LEAD = "claude-shop-lead"

  def setup
    super
    @m = store(board: KanbanTest.board_hash("local_v4"))
    @log = StringIO.new
    @n = AgentsKanban::Notifier.new(@m, client: FakeClient.new, ci: NoCi.new, clock: -> { @now }, grace: 60, log: @log)
    @id = @m.create(slug: "p", title: "ship", by: "me", column: "doing")
    @m.update(@id, { "assignee" => LEAD }, by: LEAD)
    @m.set_owner(@id, session: "acme_shop", by: LEAD)
    @m.move(@id, transition: "Open local PR", by: LEAD, agent: true)
    approval_ci.answer = GREEN
    @m.handoff(@id, **HANDOFF, by: LEAD)
  end

  def approve_pings = db[:"#{KanbanTest::PREFIX}card_pings"].where(card_id: @id, reason: "approve").all
  def gate_lines = @m.activity(@id).select { |a| a[:kind] == "gate" }.map { |a| a[:body] }
  def json = @m.card_json(@m.card(@id))
  def deploy = @m.handoff(@id, **HANDOFF, column: "deploy_check", by: LEAD)

  def test_an_approve_on_a_conflicting_pr_is_accepted_marked_and_pings_once
    approval_ci.answer = CONFLICT
    @m.approve(@id, by: "me")
    c = @m.card(@id)
    assert_equal "local_merged_pr", c[:column], "the approval moved it along the step"
    refute_nil c[:approved_at]
    mark = json[:needs_rebase]
    assert_equal({ pr: 7, state: "conflicts", base: "local", base_sha: SHA, at: Time.at(@now).iso8601 }, mark)
    assert_equal 1, approve_pings.size, "one ping"
    text = approve_pings[0][:text]
    assert_includes text, "APPROVED card ##{@id} \"ship\" (p) — it is in Local: Merged, marked needs rebase. " \
                          "approved: rebase onto local (b0b0b0b), re-run CI, then merge."
    assert_match(/merge only once CI is green on the new head; then hand the card to Local: Deploy check/, text)
    assert_match(/A conflict you cannot resolve: kanban_ask on card ##{@id} naming the conflicting files/, text)
    assert_equal ["needs rebase: PR #7 conflicts with local (b0b0b0b) — approved; the agent rebases, re-runs CI and " \
                  "merges once it is green (approved by me)"], gate_lines
  end

  def test_a_clean_approve_carries_no_mark
    @m.approve(@id, by: "me")
    assert_nil json[:needs_rebase]
    refute_match(/rebase/, approve_pings[0][:text])
  end

  def test_the_onward_move_is_held_until_the_rebased_pr_is_green_without_conflict
    approval_ci.answer = CONFLICT
    @m.approve(@id, by: "me")
    e = assert_raises(AgentsKanban::Denied) { deploy }
    assert_includes e.message, "card ##{@id} was approved with needs rebase (PR #7 conflicts with local (b0b0b0b)) " \
                               "and is held in Local: Merged: PR #7 conflicts with local (b0b0b0b) — rebase it and " \
                               "re-run CI"
    approval_ci.answer = { number: 7, state: "pending", finished_at: nil, head: "c2c2c2c2" }
    e = assert_raises(AgentsKanban::Denied) { deploy }
    assert_match(/held in Local: Merged: PR #7: CI is still running/, e.message)
    approval_ci.answer = { number: 7, state: "failure", finished_at: 9, head: "c2c2c2c2" }
    e = assert_raises(AgentsKanban::Denied) { deploy }
    assert_match(/held in Local: Merged: PR #7: CI failed/, e.message)
    approval_ci.down = "github down"
    e = assert_raises(AgentsKanban::Denied) { deploy }
    assert_match(/held in Local: Merged: CI state unknown — github down/, e.message)
    approval_ci.down = nil
    assert_equal "local_merged_pr", @m.card(@id)[:column]
    refute_nil json[:needs_rebase], "still marked"
    approval_ci.answer = GREEN.merge(head: "c2c2c2c2")
    deploy
    assert_equal "deploy_check", @m.card(@id)[:column]
    assert_nil json[:needs_rebase]
    assert_equal 1, gate_lines.count { |l| l == "needs rebase cleared: CI green at c2c2c2c and no conflict with local" }
  end

  def test_the_watch_pass_clears_the_mark_once_green_and_says_a_hold_once
    approval_ci.answer = CONFLICT
    @m.approve(@id, by: "me")
    2.times { @n.watch }
    assert_equal 1, @log.string.scan("rebase watch: card #{@id} held: PR #7 conflicts with local").size
    refute_nil json[:needs_rebase]
    approval_ci.answer = GREEN.merge(head: "c2c2c2c2")
    @n.watch
    assert_nil json[:needs_rebase]
    assert_match(/rebase watch: card #{@id} rebased, CI green: mark cleared/, @log.string)
    assert_equal 1, approve_pings.size, "clearing pings nobody"
    @n.watch
    assert_equal 1, @log.string.scan("mark cleared").size
  end

  def all_pings = db[:"#{KanbanTest::PREFIX}card_pings"].where(card_id: @id).all
  def cleared_pings = all_pings.sum { |p| p[:text].scan("needs rebase cleared on").size }

  # the lead (card #497 round 2): a waiting agent must wake when the mark clears — ONE ping per clear by the watch pass,
  # none while it holds, none when the agent's own move cleared it
  def test_the_watch_pass_clear_pings_the_owner_once
    approval_ci.answer = CONFLICT
    @m.approve(@id, by: "me")
    db[:"#{KanbanTest::PREFIX}card_pings"].where(card_id: @id).update(status: "sent") # the approve ping went out
    2.times { @n.watch }
    assert_equal 0, cleared_pings, "held: nobody pinged"
    approval_ci.answer = GREEN.merge(head: "c2c2c2c2")
    3.times { @n.watch }
    assert_equal 1, cleared_pings
    text = all_pings.find { |p| p[:reason] == "rebase_cleared" }[:text]
    assert_equal "[busyyaks] needs rebase cleared on PR #7 of card ##{@id} \"ship\" (p): CI green on c2c2c2c — merge " \
                 "now, then hand the card to Local: Deploy check with kanban_handoff id=#{@id} column=deploy_check.",
                 text.sub(/\A\[[^\]]+\]/, "[busyyaks]")
  end

  def test_a_clear_at_the_agents_own_move_pings_nobody
    approval_ci.answer = CONFLICT
    @m.approve(@id, by: "me")
    approval_ci.answer = GREEN.merge(head: "c2c2c2c2")
    deploy
    assert_equal 0, cleared_pings
  end

  # rebase_hold! runs after every other agent-move rule: a move refused anyway asks no CI and keeps the mark
  def test_a_move_refused_by_another_rule_asks_no_ci
    approval_ci.answer = CONFLICT
    @m.approve(@id, by: "me")
    approval_ci.answer = GREEN.merge(head: "c2c2c2c2")
    asked = approval_ci.asked.size
    e = assert_raises(AgentsKanban::Denied) { @m.move(@id, column: "done", by: LEAD, agent: true) }
    refute_match(/needs rebase/, e.message)
    assert_equal asked, approval_ci.asked.size
    refute_nil json[:needs_rebase]
  end

  # the workflow and the blocks run before the hold too: green + clean, but a move the workflow refuses (a review
  # column with no agent edge from Local: Merged) clears nothing
  def test_a_move_the_workflow_refuses_asks_no_ci_and_keeps_the_mark
    approval_ci.answer = CONFLICT
    @m.approve(@id, by: "me")
    approval_ci.answer = GREEN.merge(head: "c2c2c2c2")
    asked = approval_ci.asked.size
    e = assert_raises(AgentsKanban::Denied) { @m.move(@id, column: "local_agent_review", by: LEAD, agent: true) }
    assert_match(/workflow: no transition Local: Merged → Local: Agent review/, e.message)
    assert_equal asked, approval_ci.asked.size, "CI not asked"
    refute_nil json[:needs_rebase], "the mark stays"
    refute(gate_lines.any? { |l| l.include?("needs rebase cleared") })
  end

  def test_moving_the_card_out_ends_the_mark
    approval_ci.answer = CONFLICT
    @m.approve(@id, by: "me")
    @m.move(@id, transition: "Rework", by: "me")
    assert_nil json[:needs_rebase]
    assert_includes gate_lines, "needs rebase cleared: the card moved Local: Merged → In progress"
  end

  def test_a_drag_marks_nothing_the_named_transition_and_approve_in_place_do
    approval_ci.answer = CONFLICT
    @m.move(@id, column: "local_merged_pr", by: "me") # a drag: CI not asked, no mark
    assert_nil json[:needs_rebase]
    @m.unapprove(@id, by: "me")
    @m.move(@id, transition: "Approve", by: "me")
    assert_equal "conflicts", json[:needs_rebase][:state], "the step's named transition is an explicit approval"
    @m.move(@id, transition: "Rework", by: "me")
    @m.move(@id, column: "awaiting_merge", by: "me") # into the final step's gate from elsewhere: unapproved
    assert_nil json[:needs_rebase]
    @m.approve(@id, by: "me") # approved where it sits
    assert_equal "conflicts", json[:needs_rebase][:state]
    text = approve_pings.last[:text]
    assert_match(/marked needs rebase\. approved: rebase onto local .*then move the card to Done with kanban_move/, text)
    e = assert_raises(AgentsKanban::Denied) { @m.move(@id, transition: "Merge", by: LEAD, agent: true) }
    assert_match(/held in Awaiting merge: PR #7 conflicts with local/, e.message)
  end

  # card #512's Force approves without asking CI, so it knows of no conflict: it marks nothing, at the step and in place
  def test_a_forced_approve_marks_nothing
    approval_ci.answer = CONFLICT
    asked = approval_ci.asked.size
    @m.approve(@id, by: "me", force: true)
    assert_equal "local_merged_pr", @m.card(@id)[:column]
    assert_nil json[:needs_rebase]
    assert_equal asked, approval_ci.asked.size, "CI not asked"
    text = approve_pings.last[:text]
    assert_includes text, AgentsKanban::Store::FORCED_NOTE
    refute_match(/rebase/, text)
    @m.move(@id, transition: "Rework", by: "me")
    @m.move(@id, column: "awaiting_merge", by: "me")
    @m.approve(@id, by: "me", force: true) # approved in place
    assert_nil json[:needs_rebase]
    assert_includes approve_pings.last[:text], AgentsKanban::Store::FORCED_NOTE
  end

  # the card moves only conflicts to after the APPROVAL: a handoff of a conflicting PR is still refused
  def test_a_handoff_of_a_conflicting_pr_is_refused
    id = @m.create(slug: "p", title: "two", by: "me", column: "doing")
    @m.update(id, { "assignee" => LEAD }, by: LEAD)
    @m.set_owner(id, session: "acme_shop", by: LEAD)
    @m.move(id, transition: "Open local PR", by: LEAD, agent: true)
    approval_ci.answer = CONFLICT
    e = assert_raises(AgentsKanban::Invalid) { @m.handoff(id, **HANDOFF, by: LEAD) }
    assert_equal "not handed off (→ Local: Human review): card ##{id} — PR #7 conflicts with local (b0b0b0b): rebase " \
                 "it and re-run CI; hand off once CI is green", e.message
    assert_equal ["local_agent_review", nil], @m.card(id).values_at(:column, :handoff_at)
  end

  def test_every_other_refusal_is_unchanged
    {
      { number: 7, state: "pending", finished_at: nil, rebase: CONFLICT[:rebase] } =>
        "PR #7 of card ##{@id} — CI is still running",
      { number: nil, state: "unpolled", finished_at: nil } => "its PR of card ##{@id} — CI not read yet",
      { number: 7, state: "blocked", finished_at: nil, reason: "the local PR #7 is based on feature/x, not local" } =>
        "card ##{@id} — the local PR #7 is based on feature/x, not local",
      { number: 7, state: "blocked", finished_at: nil, reason: "GitHub is still computing whether the local PR #7 " \
                                                               "merges cleanly", } =>
        "card ##{@id} — GitHub is still computing whether the local PR #7 merges cleanly",
      { number: 7, state: "failure", finished_at: 5, rebase: CONFLICT[:rebase] } => "PR #7 of card ##{@id} — CI failed",
      { number: 7, state: "blocked", finished_at: nil, reason: "the local PR #7 is a draft" } =>
        "card ##{@id} — the local PR #7 is a draft",
      { number: 7, state: "blocked", finished_at: nil, reason: "the local PR #7 has GitHub auto-merge on" } =>
        "card ##{@id} — the local PR #7 has GitHub auto-merge on",
    }.each do |answer, said|
      approval_ci.answer = answer
      e = assert_raises(AgentsKanban::Invalid) { @m.approve(@id, by: "me") }
      assert_match(/\Anot approved \(Local: Human review → Local: Merged\): #{Regexp.escape(said)}/, e.message)
      assert_equal "local_human_review", @m.card(@id)[:column]
    end
    assert_empty approve_pings
  end

  def test_a_malformed_rebase_answer_is_refused
    approval_ci.answer = GREEN.merge(rebase: { state: "conflicts", base: "local" })
    e = assert_raises(AgentsKanban::Invalid) { @m.approve(@id, by: "me") }
    assert_match(/the CI port answered rebase: .* — want \{state:, base:, base_sha:\}/, e.message)
    assert_equal "local_human_review", @m.card(@id)[:column]
  end
end
