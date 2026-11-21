# frozen_string_literal: true

require "test_helper"

# The operator's Force: Approve without the green-CI gate. The same approval, move, activity and ping as the
# Approve button; only the CI / PR-state question is skipped, and the activity + ping say so. Operator only.
class ForceApproveTest < Minitest::Test
  include KanbanTest::Setup
  Invalid = AgentsKanban::Invalid
  Denied = AgentsKanban::Denied

  LEAD = "claude-shop-lead"
  OP = "operator@x"

  def handoff_ok
    { qa: "Open the page at 375 and 1280 px and check the row", pr_url: "https://github.com/o/r/pull/1",
      ci_url: "https://ci.example.com/job/r/1/", ui_change: false, }
  end

  def local = (@local ||= store(board: KanbanTest.board_hash("local_v4", green_ci: true)))

  def in_human_review
    id = local.create(slug: "p", title: "t", by: "me", column: "doing")
    local.update(id, { "assignee" => LEAD }, by: LEAD)
    local.set_owner(id, session: "acme_shop", by: LEAD)
    local.move(id, transition: "Open local PR", by: LEAD, agent: true)
    local.handoff(id, **handoff_ok, by: LEAD)
    local.pending_pings.each { |p| local.ping_result(p, "sent") }
    id
  end

  def approve_line(id) = local.activity(id).reverse.find { |a| a[:kind] == "approve" }[:body]

  def api
    @root ||= Dir.mktmpdir("force-att")
    policy = AgentsKanban::AttachmentPolicy.new(max_bytes: 200, types: "image/png")
    att = AgentsKanban::Attachments.new(local, root: @root, policy: policy, clock: -> { @now })
    AgentsKanban::Api.new(store: local, attachments: att, markdown: md,
                          projects: ->(s) { { slug: s, path: @root, remote: nil } })
  end

  def teardown
    FileUtils.rm_rf(@root) if @root
    super
  end

  def test_force_approves_a_step_whose_ci_is_red_and_says_so
    id = in_human_review
    approval_ci.answer = { number: 7, state: "failure", finished_at: 5 }
    assert_raises(Invalid) { local.approve(id, by: OP) } # unforced: unchanged, refused
    n = approval_ci.asked.size
    c = local.approve(id, by: OP, force: true)
    assert_equal ["local_merged_pr", OP, @now], c.values_at(:column, :approved_by, :approved_at)
    assert_equal n, approval_ci.asked.size, "Force never asks CI"
    assert_equal "approved Local: Human review → Local: Merged — the agent carries on and moves it to Local: Deploy " \
                 "check (forced: CI not asked)", approve_line(id)
    text = local.pending_pings.last[:text]
    assert_includes text, "It was approved with Force: CI was not asked — read the PR's checks first. Take the next " \
                          "step only once the PR's checks are green (red: do not take it, say so), then hand the card"
    refute_includes text, "Do the next step now", "a forced step never says go now"
    refute_includes text, AgentsKanban::Store::CI_FORCED, "the marker is read, never shown"
  end

  def test_force_skips_the_pr_state_question_too
    id = in_human_review
    approval_ci.answer = { number: 7, state: "blocked", finished_at: nil, reason: "the local PR #7 is not merged" }
    assert_equal "local_merged_pr", local.approve(id, by: OP, force: true)[:column]
    approval_ci.answer = nil
    approval_ci.down = "github down"
    local.move(id, column: "public_human_review", by: OP)
    local.pending_pings.each { |p| local.ping_result(p, "sent") }
    assert_equal "awaiting_merge", local.approve(id, by: OP, force: true)[:column]
    text = local.pending_pings.last[:text]
    assert_includes text, "It was approved with Force"
    assert_includes text, "Merge it once its checks are green (red: do not merge, say so)"
    refute_includes text, "Merge it now"
  end

  def test_force_in_place_approves_a_card_dragged_into_the_steps_gate
    id = in_human_review
    local.move(id, column: "awaiting_merge", by: OP)
    approval_ci.answer = { number: 9, state: "pending", finished_at: nil }
    assert_raises(Invalid) { local.approve(id, by: OP) }
    c = local.approve(id, by: OP, force: true)
    assert_equal ["awaiting_merge", OP], c.values_at(:column, :approved_by)
    assert_equal "approved for merge — the agent merges and moves it to Done (approved in Awaiting merge) " \
                 "(forced: CI not asked)", approve_line(id)
    assert_includes local.pending_pings.last[:text], "It was approved with Force"
  end

  def test_every_other_refusal_still_applies
    id = local.create(slug: "p", title: "t", by: "me", column: "doing")
    e = assert_raises(Invalid) { local.approve(id, by: OP, force: true) }
    assert_match(/only a card in Local: Human review or .* can be approved/, e.message)
    id = in_human_review
    local.approve(id, by: OP, force: true)
    local.move(id, column: "awaiting_merge", by: OP)
    local.move(id, column: "public_human_review", by: OP)
    local.move(id, column: "awaiting_merge", by: OP) # approved by the move along the step (dragged)
    e = assert_raises(Invalid) { local.approve(id, by: OP, force: true) }
    assert_match(/is already approved/, e.message)
  end

  def test_an_agent_cannot_force
    id = in_human_review
    e = assert_raises(Denied) { local.move(id, column: "local_merged_pr", by: LEAD, agent: true, force: true) }
    assert_equal "only the operator forces an approval", e.message
    assert_equal ["local_human_review", nil], local.card(id).values_at(:column, :approved_at)
    tools = AgentsKanban::Tools.new(store: local, attachments: nil, projects: ->(_s) {}, sessions: -> { [] },
                                    card_url: ->(_c) { "u" }).definitions
    refute tools.any? { |t| t[:name].include?("approve") || t.dig(:inputSchema, :properties)&.key?(:force) },
           "no MCP tool approves or forces"
  end

  def test_force_is_refused_at_a_gate_that_asks_no_ci
    s = store(board: KanbanTest.board_hash("local_v4"))
    id = s.create(slug: "p", title: "t", by: "me", column: "local_human_review")
    e = assert_raises(Invalid) { s.approve(id, by: OP, force: true) }
    assert_equal "force: true needs a gate that waits for green CI — Local: Human review has no requires_green_ci in " \
                 "the workflow, its Approve asks no CI: approve without force", e.message
    assert_nil s.card(id)[:approved_at]
    assert_equal "local_merged_pr", s.approve(id, by: OP)[:column]
  end

  def test_force_on_a_move_that_is_no_approval_step_is_refused
    id = local.create(slug: "p", title: "t", by: "me", column: "doing")
    e = assert_raises(Invalid) { local.move(id, column: "todo", by: OP, force: true) }
    assert_equal "force: true only approves along an approval step (In progress → To do is none)", e.message
  end

  def test_the_api_takes_force
    id = in_human_review
    approval_ci.answer = { number: 7, state: "failure", finished_at: 5 }
    status, body = api.approve(id, { "approved" => true }, by: OP)
    assert_equal 422, status
    assert_match(/CI failed/, body[:error])
    status, body = api.approve(id, { "force" => "yes" }, by: OP)
    assert_equal [422, "force must be true or false (got \"yes\")"], [status, body[:error]]
    status, body = api.approve(id, { "approved" => false, "force" => true }, by: OP)
    assert_equal [422, "force: true approves; it cannot withdraw (approved: false)"], [status, body[:error]]
    status, body = api.approve(id, { "approved" => true, "force" => true }, by: OP)
    assert_equal [200, "local_merged_pr", OP], [status, body[:card][:column], body[:card][:approved_by]]
    assert_match(/\(forced: CI not asked\)\z/, approve_line(id))
  end
end
