# frozen_string_literal: true

require "test_helper"

# A card's priority orders everything on our side — the cards a session adopts, the pings a session is typed, and
# the approved queue (the cards approved into one column, which their agents carry on: merge). Rank = the host's
# `priorities` order, none last; ties keep the order there was (position / oldest). Order only: nothing is refused
# for it.
class PriorityOrderTest < Minitest::Test
  include KanbanTest::Setup

  OP = "operator@x"

  def pings_t = db[:"#{KanbanTest::PREFIX}card_pings"]

  def test_rank_follows_the_hosts_priorities_and_none_ranks_last
    assert_equal [0, 1, 2, 3, 3], ["high", "medium", "low", nil, ""].map { |p| kb.send(:priority_rank, p) }
  end

  # a stored priority the host no longer lists is refused, never read as "none" (no fallback)
  def test_a_priority_the_host_no_longer_lists_is_refused_naming_it
    e = assert_raises(AgentsKanban::Invalid) { kb.send(:priority_rank, "urgent") }
    assert_includes e.message, "\"urgent\" is not one of the host's priorities (high, medium, low)"
  end

  # a config that drops a priority a card holds is refused at start, naming the cards — never a raise inside the shared
  # ping / adoption passes on every board
  def test_a_config_dropping_a_held_priority_is_refused_at_start
    id = kb.create(slug: "p", title: "low", by: OP, column: "todo", priority: "low")
    raw = JSON.parse(File.read(File.join(KanbanTest::ROOT, "fixtures/boards/coding.json")))
    cfg = AgentsKanban::HostConfig.new(raw.merge("table_prefix" => KanbanTest::PREFIX, "priorities" => %w[high medium]))
    e = assert_raises(AgentsKanban::ConfigError) { store(cfg) }
    assert_includes e.message, "drops what cards hold: \"low\" (card ##{id})"
    kb.update(id, { priority: nil }, by: OP)
    store(cfg) # cleared on the card: the narrower list starts
  end

  # the lead hears which cards its ended worker held: the high card first
  def test_the_lead_hears_an_ended_workers_cards_by_priority
    lead = kb.register_session(session: "p_lead", project: "p", type: "lead", launcher: "fullclaude", by: OP)
    kb.register_session(session: "p_w", project: "p", type: "team", launcher: "fullclaude", by: OP, lead_id: lead[:id])
    low = kb.create(slug: "p", title: "low", by: OP, column: "doing", priority: "low")
    high = kb.create(slug: "p", title: "high", by: OP, column: "doing", priority: "high")
    [low, high].each { |id| kb.set_owner(id, session: "p_w", by: OP) }
    pings_t.delete
    kb.end_session("p_w", reason: "done", by: OP)
    text = pings_t.where(session: "p_lead", reason: "lead_session_end").get(:text)
    assert_includes text, "card ##{high}, card ##{low}"
  end

  def test_a_lead_adopts_the_higher_priority_cards_first
    low = kb.create(slug: "p", title: "low", by: OP, column: "todo", priority: "low")
    none = kb.create(slug: "p", title: "none", by: OP, column: "todo")
    high = kb.create(slug: "p", title: "high", by: OP, column: "todo", priority: "high")
    medium = kb.create(slug: "p", title: "medium", by: OP, column: "todo", priority: "medium")
    lead = kb.register_session(session: "p_lead", project: "p", type: "lead", launcher: "fullclaude", by: OP)
    assert_equal [high, medium, low, none], lead[:adopted]
  end

  def test_ownerless_cards_are_handed_over_by_priority
    kb.register_session(session: "p_lead", project: "p", type: "lead", launcher: "fullclaude", by: OP)
    low = kb.create(slug: "p", title: "low", by: OP, column: "todo", priority: "low")
    high = kb.create(slug: "p", title: "high", by: OP, column: "todo", priority: "high")
    assert_equal [high, low], kb.adopt_ownerless(only: [low, high])
  end

  def test_a_sessions_pings_go_higher_priority_first_within_a_class
    low = kb.create(slug: "p", title: "low", by: OP, column: "doing", priority: "low")
    high = kb.create(slug: "p", title: "high", by: OP, column: "doing", priority: "high")
    [low, high].each { |id| kb.set_owner(id, session: "s1", by: OP) }
    pings_t.delete
    kb.comment(low, body: "first", author: OP, operator: true)
    @now += 5
    kb.comment(high, body: "second", author: OP, operator: true)
    assert_equal [high], kb.next_pings.map { |p| p[:card_id] }, "same class: the high card's row goes first"
    row = pings_t.where(card_id: high).first
    assert_equal 0, kb.pings_ahead(row)
    assert_equal 1, kb.pings_ahead(pings_t.where(card_id: low).first)

    # a row something may already have been typed from stays first, whatever its card's priority
    pings_t.where(card_id: low).update(attempts: 1)
    assert_equal [low], kb.next_pings.map { |p| p[:card_id] }
  end

  def test_sessions_heads_in_one_class_go_higher_priority_first
    low = kb.create(slug: "p", title: "low", by: OP, column: "doing", priority: "low")
    high = kb.create(slug: "p", title: "high", by: OP, column: "doing", priority: "high")
    kb.set_owner(low, session: "s1", by: OP)
    kb.set_owner(high, session: "s2", by: OP)
    pings_t.delete
    kb.comment(low, body: "older", author: OP, operator: true)
    @now += 5
    kb.comment(high, body: "newer", author: OP, operator: true)
    assert_equal [high, low], kb.next_pings.map { |p| p[:card_id] }
  end
end

# The approved queue: the cards approved into one column of a board, by priority, then the oldest approval.
class ApprovedQueueTest < Minitest::Test
  include KanbanTest::Setup

  OP = "operator@x"

  def setup
    super
    @m = store(board: KanbanTest.board_hash("local_v4"))
  end

  def pings_t = db[:"#{KanbanTest::PREFIX}card_pings"]

  # into Awaiting merge by the final Approve, owned by its own session
  def approved!(title, priority)
    id = @m.create(slug: "p", title: title, by: OP, column: "doing", priority: priority)
    @m.set_owner(id, session: "s_#{title}", by: OP)
    @m.move(id, column: "public_human_review", by: OP)
    @now += 10
    @m.approve(id, by: OP)
    id
  end

  def queue(id) = @m.card(id)[:approved_queue]

  def test_priority_then_the_oldest_approval_orders_the_queue
    none = approved!("none", nil)
    low = approved!("low", "low")
    high = approved!("high", "high")
    low2 = approved!("low2", "low")
    assert_equal [[1, 4], [2, 4], [3, 4], [4, 4]], [high, low, low2, none].map { |id| queue(id).values_at(:position, :of) }
    assert_equal [{ id: high, priority: "high" }, { id: low, priority: "low" }], queue(low2)[:ahead]
    assert_equal "awaiting_merge", queue(high)[:column]
    assert_empty queue(high)[:ahead]
  end

  def test_the_card_json_and_the_board_carry_it_and_an_unapproved_card_has_none
    a = approved!("a", "low")
    b = approved!("b", "high")
    plain = @m.create(slug: "p", title: "plain", by: OP, column: "public_human_review", priority: "high")
    face = @m.board("p").values.flatten.find { |c| c[:id] == a }
    assert_equal 2, @m.card_json(face)[:approved_queue][:position]
    assert_equal [{ id: b, priority: "high" }], @m.card_json(@m.card(a))[:approved_queue][:ahead]
    assert_nil @m.card_json(@m.card(plain))[:approved_queue]
  end

  def test_leaving_the_column_leaves_the_queue
    a = approved!("a", "high")
    b = approved!("b", "low")
    @m.move(a, column: "done", by: "s_a", agent: true)
    assert_equal [1, 1], queue(b).values_at(:position, :of)
  end

  def test_the_approve_ping_names_the_cards_ahead
    high = approved!("high", "high")
    refute_includes texts(high), "Approved queue", "the head of the queue: no line"
    pings_t.delete
    low = approved!("low", "low")
    assert_includes texts(low), "Approved queue in Awaiting merge at this approval: 2 of 2 by priority, ahead of it: " \
                                "card ##{high} (high)."
  end

  # a step that is not final (Local: Human review → Local: Merged, the agent merges the local PR): its ping says it too
  def test_the_carry_on_approve_ping_names_the_cards_ahead
    first = local_merged!("first", "high")
    pings_t.delete
    second = local_merged!("second", "medium")
    assert_includes texts(second), "Approved queue in Local: Merged at this approval: 2 of 2 by priority, ahead of " \
                                   "it: card ##{first} (high)."
    assert_equal [1, 2], [first, second].map { |id| queue(id)[:position] }
  end

  def local_merged!(title, priority)
    id = @m.create(slug: "p", title: title, by: OP, column: "doing", priority: priority)
    @m.set_owner(id, session: "s_#{title}", by: OP)
    @m.move(id, column: "local_human_review", by: OP)
    @now += 10
    @m.approve(id, by: OP)
    assert_equal "local_merged_pr", @m.card(id)[:column]
    id
  end

  # the approve event joins the pending move row (one ping per card + session): read every row of the card
  def texts(id) = pings_t.where(card_id: id).select_map(:text).join("\n")
end

# The watch pass asks the approved cards' CI by priority (a gate that waits for green CI).
class ApprovedCiPassOrderTest < Minitest::Test
  include KanbanTest::Setup

  OP = "operator@x"

  def setup
    super
    @m = store(board: KanbanTest.board_hash("local_v4", green_ci: true))
    approval_ci.answer = { number: 7, state: "success", finished_at: 5, head: "a1a1a1a1a1" }
  end

  def test_approved_ci_pass_asks_the_higher_priority_card_first
    ids = [["none", nil], %w[low low], %w[high high]].map do |title, priority|
      id = @m.create(slug: "p", title: title, by: OP, column: "doing", priority: priority)
      @m.set_owner(id, session: "s_#{title}", by: OP)
      @m.move(id, column: "public_human_review", by: OP)
      @m.approve(id, by: OP)
      id
    end
    assert_equal ids.reverse, @m.approved_ci_pass.map(&:first)
  end
end
