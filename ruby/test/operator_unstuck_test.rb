# frozen_string_literal: true

require "test_helper"

# The operator can always move a card around the columns by dragging: no operator move
# leaves a card where nobody can carry on. Each test is one such corner on the local v4 board (two review loops, four
# gates) or the coding board.
class OperatorUnstuckTest < Minitest::Test
  include KanbanTest::Setup
  Invalid = AgentsKanban::Invalid
  Denied = AgentsKanban::Denied

  LEAD = "claude-shop-lead"
  OP = "operator@x"

  def handoff_ok
    { qa: "Open the page at 375 and 1280 px and check the row", pr_url: "https://github.com/o/r/pull/1",
      ci_url: "https://ci.example.com/job/r/1/", ui_change: false, }
  end

  def local = (@local ||= store(board: KanbanTest.board_hash("local_v4")))

  def local_card(column: "doing")
    id = local.create(slug: "p", title: "t", by: "me", column: column)
    local.update(id, { "assignee" => LEAD }, by: LEAD)
    local.set_owner(id, session: "acme_shop", by: LEAD)
    id
  end

  # a card at the round limit of the local loop, sitting in Local: Agent review
  def at_the_limit
    id = local_card
    local.move(id, transition: "Open local PR", by: LEAD, agent: true)
    2.times do
      local.move(id, transition: "Comments posted", by: "reviewer", agent: true)
      local.move(id, transition: "All threads answered", by: LEAD, agent: true)
    end
    assert_equal 3, local.card_json(local.card(id))[:review_round]
    id
  end

  def round(id) = local.card_json(local.card(id))[:review_round]

  # At the limit the agents' way on is the handoff out of the loop column. The operator dragging the card back to the
  # loop's work column asked for one more answer: from there no gate is reachable, so the limit would leave the author
  # with no move at all. The drag is the operator's Changes requested: exactly one more round.
  def test_the_operators_drag_back_to_the_loops_work_column_at_the_limit_gives_one_more_round
    id = at_the_limit
    local.move(id, column: "local_author", by: OP)
    local.move(id, transition: "All threads answered", by: LEAD, agent: true)
    assert_equal ["local_agent_review", 4], [local.card(id)[:column], round(id)]
    e = assert_raises(Denied) { local.move(id, transition: "Comments posted", by: "reviewer", agent: true) }
    assert_match(/the one re-round after the operator's Changes requested is done/, e.message)
    local.handoff(id, **handoff_ok, by: "reviewer")
    assert_equal ["local_human_review", []], local.card(id).values_at(:column, :labels), "a re-round is no deadlock"
  end

  # the same drag below the limit changes nothing: the loop still has its rounds
  def test_the_operators_drag_back_below_the_limit_keeps_the_rounds
    id = local_card
    local.move(id, transition: "Open local PR", by: LEAD, agent: true)
    local.move(id, column: "local_author", by: OP)
    local.move(id, transition: "All threads answered", by: LEAD, agent: true)
    local.move(id, transition: "Comments posted", by: "reviewer", agent: true)
    local.move(id, transition: "All threads answered", by: LEAD, agent: true)
    assert_equal 3, round(id)
    e = assert_raises(Denied) { local.move(id, transition: "Comments posted", by: "reviewer", agent: true) }
    assert_match(%r{review round limit reached \(3/3 in Local: Agent review\)}, e.message)
  end

  # A card parked at the limit (the operator dragged it out of the loop column to To do / Backlog) starts over when its
  # work starts again: "Open local PR" from In progress is round 1, not a refusal naming a gate In progress cannot reach.
  def test_start_work_after_the_operator_parked_a_card_at_the_limit_starts_the_rounds_over
    %w[todo backlog].each do |parked|
      id = at_the_limit
      local.move(id, column: parked, by: OP)
      local.move(id, column: "todo", by: OP) if parked == "backlog"
      local.move(id, transition: "Start work", by: LEAD, agent: true)
      local.move(id, transition: "Open local PR", by: LEAD, agent: true)
      assert_equal ["local_agent_review", 1], [local.card(id)[:column], round(id)], "via #{parked}"
    end
  end

  # every other operator drag out of the loop column at the limit leaves the agents a move
  def test_no_operator_drag_at_the_limit_leaves_the_agents_without_a_move
    b = local.board_of("p")
    (b.keys - %w[local_agent_review]).each do |col|
      id = at_the_limit
      local.move(id, column: col, by: OP)
      next if b.terminal?(col) || b.gate?(col) # the operator's columns: nothing is asked of an agent there

      if b.working?(col)
        to = b.agent_targets(col).first
        local.move(id, column: to, by: LEAD, agent: true)
        assert_equal to, local.card(id)[:column], "from #{col}"
      end
      # back into the loop by the operator: the agents can always hand the card to the gate
      local.move(id, column: "local_agent_review", by: OP)
      local.handoff(id, **handoff_ok, review_summary: { fixed: 1, resolved_by_argument: 0, needs_human: 0, open: 0 },
                                      by: "reviewer")
      assert_equal "local_human_review", local.card(id)[:column], "via #{col}"
    end
  end

  # A card the operator dragged into an approval step's target that is a gate (Awaiting merge) from anywhere but the
  # step's gate is not approved, and agents never leave a gate unapproved: the operator approves it where it sits.
  def test_a_card_dragged_into_a_gate_an_approval_leads_to_is_approved_in_place
    id = local_card
    local.move(id, column: "awaiting_merge", by: OP)
    assert_nil local.card(id)[:approved_at], "a drag from elsewhere approves nothing"
    e = assert_raises(Denied) { local.move(id, transition: "Merge", by: LEAD, agent: true) }
    assert_match(/sits in Awaiting merge without the operator's approval/, e.message)
    assert_match(/or the operator's Approve on the card in Awaiting merge/, e.message)

    approval_ci.answer = { number: 9, state: "pending", finished_at: nil }
    e = assert_raises(Invalid) { local.approve(id, by: OP) }
    assert_match(/\Anot approved \(Public: Human review → Awaiting merge\): PR #9 of card ##{id} — CI is still running/,
                 e.message)
    assert_nil local.card(id)[:approved_at], "the Approve button asks CI in place too"
    step = local.board_of("p").approval_into("awaiting_merge").to_h
    assert_equal [id, step], approval_ci.asked.last

    approval_ci.answer = { number: 9, state: "success", finished_at: 1 }
    c = local.approve(id, by: OP)
    assert_equal ["awaiting_merge", OP, @now], c.values_at(:column, :approved_by, :approved_at)
    assert_equal "approved for merge — the agent merges and moves it to Done (approved in Awaiting merge)",
                 local.activity(id).reverse.find { |a| a[:kind] == "approve" }[:body]
    assert_includes local.pending_pings.last[:text], "APPROVED card ##{id}"
    e = assert_raises(Invalid) { local.approve(id, by: OP) }
    assert_equal "card ##{id} is already approved (by #{OP}) in Awaiting merge", e.message
    assert_equal "done", local.move(id, transition: "Merge", by: LEAD, agent: true)[:column]
  end

  # ... and the approval given in place is withdrawn like any other: back to the step's gate
  def test_an_approval_given_in_place_is_withdrawn_to_the_steps_gate
    id = local_card
    local.move(id, column: "awaiting_merge", by: OP)
    local.approve(id, by: OP)
    c = local.unapprove(id, by: OP)
    assert_equal ["public_human_review", nil, nil], c.values_at(:column, :approved_at, :approved_by)
  end

  # in place on a step that is not the last one: the ping says the card stays and names the agent's next move
  def test_an_approval_in_place_on_a_step_that_is_not_final_says_the_card_stays
    hash = KanbanTest.board_hash("local_v4")
    hash["transitions"].find { |t| t["name"] == "Merge" }["to"] = "deploy_check"
    local.board_save("p", hash, by: OP)
    id = local_card
    local.move(id, column: "awaiting_merge", by: OP)
    local.approve(id, by: OP)
    text = local.pending_pings.last[:text]
    assert_includes text, "APPROVED card ##{id} \"t\" (p) — it stays in Awaiting merge. Do the next step now, then hand " \
                          "the card to Local: Deploy check with kanban_handoff id=#{id} column=deploy_check"
    assert_equal "approved Public: Human review → Awaiting merge — the agent carries on and moves it to Local: Deploy " \
                 "check (approved in Awaiting merge)", local.activity(id).reverse.find { |a| a[:kind] == "approve" }[:body]
  end

  # a step's target that is no gate (Local: Merged) holds no agent back: nothing to approve there
  def test_a_step_target_that_is_no_gate_has_nothing_to_approve_in_place
    id = local_card
    local.move(id, column: "local_merged_pr", by: OP)
    e = assert_raises(Invalid) { local.approve(id, by: OP) }
    assert_match(/only a card in Local: Human review or .* can be approved \(card ##{id} is in Local: Merged\)/, e.message)
  end

  # the Approve button refused by the gate says what the operator can still do
  def test_a_refused_approve_names_the_drag
    id = local_card
    local.move(id, transition: "Open local PR", by: LEAD, agent: true)
    local.handoff(id, **handoff_ok, by: LEAD)
    approval_ci.answer = { number: 7, state: "blocked", finished_at: nil,
                           reason: "the local PR #7 was merged before its approval", }
    e = assert_raises(Invalid) { local.approve(id, by: OP) }
    assert_equal "not approved (Local: Human review → Local: Merged): card ##{id} — the local PR #7 was merged before " \
                 "its approval. A drag into Local: Merged approves without asking CI", e.message
    e = assert_raises(Invalid) { local.handoff(local_ready, **handoff_ok, by: LEAD) }
    refute_match(/drag/, e.message, "an agent's handoff is told nothing about a drag")
  end

  def local_ready
    id = local_card
    local.move(id, transition: "Open local PR", by: LEAD, agent: true)
    id
  end

  # Withdraw approval is the operator's own undo: it needs no edge back in the workflow (a board without the catch-all
  # "Move" has none Ready to merge → Human Check; the button was refused by the graph).
  def test_withdraw_needs_no_workflow_edge_back
    hash = KanbanTest.board_hash
    hash["transitions"] = hash["transitions"].reject { |t| t["from"] == "*" }
    kb.board_save("g/r", hash, by: OP)
    id = kb.create(slug: "g/r", title: "t", by: "me", column: "doing")
    kb.update(id, { "assignee" => LEAD }, by: LEAD)
    kb.set_owner(id, session: "tl_g_r", by: LEAD)
    kb.handoff(id, **handoff_ok, by: LEAD)
    kb.approve(id, by: OP)
    e = assert_raises(Denied) { kb.move(id, column: "human_check", by: OP) }
    assert_match(/workflow: no transition Ready to merge → Human Check for the operator/, e.message)
    c = kb.unapprove(id, by: OP)
    assert_equal ["human_check", nil], c.values_at(:column, :approved_at)
    assert_equal "Ready to merge → Human Check (approval withdrawn)",
                 kb.activity(id).reverse.find { |a| a[:kind] == "move" }[:body]
  end

  # a Withdraw with nothing to withdraw says so (a stale button), it is not a silent 200
  def test_withdraw_with_nothing_to_withdraw_is_refused
    id = local_card
    e = assert_raises(Invalid) { local.unapprove(id, by: OP) }
    assert_equal "card ##{id} is in In progress — no approval to withdraw there", e.message
    local.move(id, column: "awaiting_merge", by: OP)
    e = assert_raises(Invalid) { local.unapprove(id, by: OP) }
    assert_equal "card ##{id} is not approved — nothing to withdraw", e.message
  end

  # the flags hold AGENTS, never the operator: a flagged card is dragged anywhere, a column at a time or across
  def test_a_flagged_card_is_moved_by_the_operator
    id = local_card
    local.ask(id, question: "which one?", by: LEAD)
    local.block(id, reason: "CI is down", url: "https://ci.example.com/", by: LEAD)
    %w[local_agent_review local_human_review local_merged_pr deploy_check backlog doing].each do |col|
      assert_equal col, local.move(id, column: col, by: OP)[:column]
    end
    c = local.card(id)
    refute_nil c[:asked_at], "the question still waits for its answer"
    local.comment(id, body: "the first", author: OP, operator: true)
    assert_equal [nil, nil], local.card(id).values_at(:asked_at, :blocked_at), "the operator's comment clears both"
    assert_equal "local_agent_review", local.move(id, transition: "Open local PR", by: LEAD, agent: true)[:column]
  end

  # an approved card dragged back into its gate, or into another gate, carries no stale approval or gate view
  def test_a_gate_re_entered_by_a_drag_holds_nothing_stale
    id = local_ready
    local.handoff(id, **handoff_ok, by: LEAD)
    local.approve(id, by: OP)
    %w[local_human_review deploy_check awaiting_merge public_human_review local_human_review].each do |gate|
      c = local.move(id, column: gate, by: OP)
      assert_equal [gate, nil, nil, nil], c.values_at(:column, :approved_at, :gate_head, :gate_state)
    end
    assert_equal "local_merged_pr", local.approve(id, by: OP)[:column], "approvable again, asked live"
  end

  # The rule itself: on a board with the operator's catch-all edge a drag between ANY two columns goes through —
  # a flagged card, at the review round limit, with CI red (the gate would refuse every approval).
  def test_the_operator_drags_a_card_between_any_two_columns
    approval_ci.answer = { number: 7, state: "failure", finished_at: 5 }
    keys = local.board_of("p").keys
    id = at_the_limit
    local.ask(id, question: "which one?", by: LEAD)
    local.block(id, reason: "CI is down", url: "https://ci.example.com/", by: LEAD)
    keys.product(keys).reject { |a, b| a == b }.each do |from, to|
      local.move(id, column: from, by: OP)
      assert_equal to, local.move(id, column: to, by: OP)[:column], "#{from} → #{to}"
    end
  end

  # The operator's API: Approve on the card where it sits, and a Withdraw with nothing to withdraw is a 422 with why.
  def test_the_api_approves_in_place_and_refuses_an_empty_withdraw
    root = Dir.mktmpdir("unstuck-att")
    policy = AgentsKanban::AttachmentPolicy.new(max_bytes: 200, types: "image/png")
    att = AgentsKanban::Attachments.new(local, root: root, policy: policy, clock: -> { @now })
    api = AgentsKanban::Api.new(store: local, attachments: att, markdown: md,
                                projects: ->(s) { { slug: s, path: root, remote: nil } })
    id = local_card
    status, body = api.approve(id, { "approved" => false }, by: OP)
    assert_equal [422, "card ##{id} is in In progress — no approval to withdraw there"], [status, body[:error]]
    local.move(id, column: "awaiting_merge", by: OP)
    status, body = api.approve(id, {}, by: OP)
    assert_equal [200, "awaiting_merge", OP], [status, body[:card][:column], body[:card][:approved_by]]
    status, body = api.approve(id, { "approved" => false }, by: OP)
    assert_equal [200, "public_human_review", nil], [status, body[:card][:column], body[:card][:approved_by]]
  ensure
    FileUtils.rm_rf(root)
  end

  # dependencies (a host that enforces them): the refusal says how the operator ends the wait
  def test_a_child_of_an_archived_parent_is_told_the_way_out
    s = store(KanbanTest.config("content"))
    parent = s.create(slug: "p", title: "article", by: "lead", column: "queued")
    child = s.create(slug: "p", title: "translation", by: "lead", parent: parent)
    s.archive(parent, by: "op")
    e = assert_raises(Invalid) { s.move(child, column: "queued", by: "op") }
    assert_equal "card ##{child} cannot enter Queued while it waits for card ##{parent} (not yet in Done; " \
                 "##{parent} is archived and never finishes) — clear the card's parent to end the wait", e.message
    s.update(child, { "parent" => nil }, by: "op")
    assert_equal "queued", s.move(child, column: "queued", by: "op")[:column]
  end
end
