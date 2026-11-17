# frozen_string_literal: true

require "test_helper"

# Approved and carried on: a card in a gate the
# operator approved, whose next step is its agent's named transition (Awaiting merge after the final Approve: the agent
# merges), waits for the agent, not for the operator. It leaves every "waiting for you" surface — the board's and the
# Projects page's `waiting`, Api#waiting's list and total, the card's `waiting` — and is counted apart (`approved`),
# never hidden. A question open on it still waits for the operator; an unapproved card in the same gate still does.
class CarriedOnTest < Minitest::Test
  include KanbanTest::Setup

  OP = "operator@x"
  AGENT = "claude-shop-lead"

  def setup
    super
    @m = store(board: KanbanTest.board_hash("local_v4"))
    @projects = { "p" => { slug: "p", path: "/nonexistent", remote: nil } }
    att = AgentsKanban::Attachments.new(@m, root: Dir.mktmpdir,
                                            policy: AgentsKanban::AttachmentPolicy.new(max_bytes: 100, types: "image/png"))
    @api = AgentsKanban::Api.new(store: @m, attachments: att, markdown: md, projects: ->(s) { @projects[s] })
    @id = @m.create(slug: "p", title: "ship", by: "me", column: "doing")
    @m.set_owner(@id, session: "acme_shop", by: AGENT)
  end

  def board = @api.board("p")[1]
  def boards = @api.boards([@projects["p"]])[1]
  def waiting = @api.waiting([@projects["p"]])[1]
  def face = board[:columns].flat_map { |c| c[:cards] }.find { |c| c[:id] == @id }

  # [board waiting, board approved, Projects waiting, Projects approved, Api#waiting total, Api#waiting approved count]
  def counts
    w = waiting
    [board[:waiting], board[:approved], boards[:waiting], boards[:approved], w[:total], w[:approved].sum { |g| g[:count] }]
  end

  # the operator's final Approve: Public: Human review → Awaiting merge (the agent's next step: Merge → Done)
  def approve_final!
    @m.move(@id, column: "public_human_review", by: OP)
    assert_equal [1, 0, 1, 0, 1, 0], counts, "in the gate before the Approve: the operator's to check"
    @m.approve(@id, by: OP)
    assert_equal "awaiting_merge", @m.card(@id)[:column]
  end

  def test_board_names_the_agents_way_on_from_a_gate
    b = @m.board_of("p")
    assert_equal "done", b.agent_next("awaiting_merge"), "Merge: the agent's one named way on"
    assert_nil b.agent_next("local_human_review"), "Approve is the operator's (Rework back to work is no way on)"
    assert_nil b.agent_next("deploy_check"), "no agent edge out"
    assert_nil b.agent_next("doing"), "not a gate"
  end

  def test_the_final_approve_takes_the_card_off_waiting_for_you_and_counts_it_apart
    approve_final!
    assert_equal [0, 1, 0, 1, 0, 1], counts
    assert_equal false, face[:waiting], "the face: not highlighted as needs-you"
    assert_equal({ next_column: "done", next_label: "Done", final: true }, face[:carried_on])
    row = waiting[:approved].first
    assert_equal ["p", 1], [row[:slug], row[:count]]
    c = row[:cards].first
    assert_equal [@id, OP, "acme_shop", { next_column: "done", next_label: "Done", final: true }],
                 [c[:id], c[:approved_by], c[:owner_session], c[:carried_on]]
    refute_nil c[:approved]
    refute_nil c[:since], "since = when it was approved"
    assert_empty waiting[:projects], "nothing waits for the operator"
    assert_empty waiting[:held]
  end

  def test_the_agent_merging_it_ends_the_approved_count
    approve_final!
    @m.move(@id, transition: "Merge", by: AGENT, agent: true)
    assert_equal [0, 0, 0, 0, 0, 0], counts
  end

  # dragged into Awaiting merge (a plain move, not the step) — unapproved, so it waits for the
  # operator's Approve in place; that Approve moves it to the approved count
  def test_an_unapproved_card_in_the_gate_waits_until_approved_in_place
    @m.move(@id, column: "awaiting_merge", by: OP)
    assert_equal [1, 0, 1, 0, 1, 0], counts
    assert_nil face[:carried_on]
    assert_equal true, face[:waiting]
    @m.approve(@id, by: OP)
    assert_equal [0, 1, 0, 1, 0, 1], counts
  end

  def test_a_question_on_an_approved_card_waits_for_the_operator
    approve_final!
    @m.ask(@id, question: "Rebase onto the moved base, or wait?", by: AGENT)
    assert_equal [1, 0, 1, 0, 1, 0], counts, "needs_operator wins over approved"
    assert_nil face[:carried_on]
    @m.comment(@id, body: "rebase", author: OP, operator: true)
    assert_equal [0, 1, 0, 1, 0, 1], counts, "answered: the agent carries it on again"
  end

  def test_blocked_external_wins_over_approved
    approve_final!
    @m.block(@id, reason: "public CI is down", url: "https://ci.example.com/", by: AGENT)
    assert_equal [0, 0, 0, 0, 0, 0], counts
    assert_equal 1, board[:external]
  end

  # nobody owns it (its session gone): nobody carries it on, so it waits for the operator ("approved · no agent")
  def test_an_approved_card_with_no_owner_waits_for_the_operator
    approve_final!
    @m.set_owner(@id, session: "", by: OP)
    assert_equal [1, 0, 1, 0, 1, 0], counts
    row = waiting[:projects].first[:cards].first
    assert_equal [@id, OP, nil, nil], [row[:id], row[:approved_by], row[:owner_session], row[:carried_on]]
    refute_nil row[:approved]
    assert_equal true, face[:waiting]
    @m.set_owner(@id, session: "acme_shop", by: OP)
    assert_equal [0, 1, 0, 1, 0, 1], counts, "owned again: its agent carries it on"
  end

  # a CI hold wins over approved: CI red after the Approve is "held: <why>", not "approved · agent merging"
  def test_a_ci_hold_wins_over_approved
    approve_final!
    c = @m.card(@id)
    b = @m.board_of("p")
    assert_equal true, @m.carried_on?(c, b)
    assert_equal false, @m.carried_on?(c, b, "PR #7: CI failed")
    assert_nil @m.carried_on_json(c, b, "PR #7: CI failed")
  end

  def test_the_operator_dragging_it_back_withdraws_the_approval_and_it_waits_again
    approve_final!
    @m.unapprove(@id, by: OP)
    assert_equal "public_human_review", @m.card(@id)[:column]
    assert_equal [1, 0, 1, 0, 1, 0], counts
  end
end
