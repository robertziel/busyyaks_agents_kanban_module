# frozen_string_literal: true

require "test_helper"

# ON HOLD (Store#hold): the operator parks a card where it sits. It keeps its column; it leaves the board's
# normal view (the "On hold" view lists it), every count, waiting list and watch, and every agent's sight.
class HoldTest < Minitest::Test
  include KanbanTest::Setup

  def setup
    super
    @root = Dir.mktmpdir("hold-att")
    @projects = { "g/r" => { slug: "g/r", path: @root, remote: nil } }
    policy = AgentsKanban::AttachmentPolicy.new(max_bytes: 1000, types: "image/png,text/plain")
    @att = AgentsKanban::Attachments.new(kb, root: @root, policy: policy, clock: -> { @now })
    @live = %w[tl_g_r]
    @tools = AgentsKanban::Tools.new(store: kb, attachments: @att, projects: ->(s) { @projects[s] },
                                     sessions: -> { @live }, card_url: CARD_URL)
    @api = AgentsKanban::Api.new(store: kb, attachments: @att, markdown: md, projects: ->(s) { @projects[s] })
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def tool(name, args) = @tools.call(name, JSON.parse(JSON.generate(args)))
  def refused(name, args) = assert_raises(AgentsKanban::Invalid) { tool(name, args) }.message
  def ids(cols) = cols.values.flatten.map { |c| c[:id] }

  # a card in `column`, owned by tl_g_r's session
  def owned(column = "doing", title: "x")
    id = kb.create(slug: "g/r", title: title, by: "op", column: column)
    kb.claim(id, assignee: "agent-a", session: "tl_g_r")
    id
  end

  def test_a_held_card_keeps_its_column_and_leaves_the_normal_view_for_the_on_hold_view
    a = owned(title: "a")
    b = owned(title: "b")
    held = kb.hold(a, by: "op")
    assert_equal %w[doing op], [held[:column], kb.card_json(held)[:on_hold][:by]]
    assert_nil held[:owner_session], "an agent that cannot see the card is not its owner"
    assert_nil held[:assignee]
    assert_equal [b], ids(kb.board("g/r"))
    assert_equal [a], ids(kb.board("g/r", on_hold: true))
    assert_equal [a], kb.board("g/r", on_hold: true)["doing"].map { |c| c[:id] }, "the same column in the On hold view"
    assert_equal 1, kb.on_hold_count("g/r")
    assert_equal 1, kb.counts("g/r")["g/r"]["doing"], "counts are the normal view's"
    line = kb.card_body(kb.card(a))[:activity].map { |x| x[:body] }.last
    assert_equal "put on hold in In progress — owner session tl_g_r and assignee agent-a released", line
    @now += 60
    assert_equal held[:on_hold_at], kb.hold(a, by: "op")[:on_hold_at], "holding a held card changes nothing"
  end

  def test_release_puts_it_back_at_the_bottom_of_its_column_ownerless_and_the_lead_adopts_it
    a = owned("todo", title: "a")
    kb.hold(a, by: "op")
    b = kb.create(slug: "g/r", title: "b", by: "op", column: "todo")
    kb.register_session(session: "tl_g_r", project: "g/r", type: "lead", launcher: "fullclaude", by: "op")
    released = kb.hold(a, by: "op", on_hold: false)
    assert_nil kb.card_json(released)[:on_hold]
    assert_equal [b, a], kb.board("g/r")["todo"].map { |c| c[:id] }
    assert_equal "tl_g_r", released[:owner_session], "the lead takes To do cards: adopted on release"
    assert_equal 0, kb.on_hold_count("g/r")
  end

  def test_a_held_card_waits_for_nobody_and_no_watch_reads_it
    gate = kb.create(slug: "g/r", title: "gate", by: "op", column: "human_check")
    asked = owned
    kb.ask(asked, question: "Q?", by: "agent-a")
    assert_equal 2, kb.waiting_counts(["g/r"]).waiting["g/r"]
    [gate, asked].each { |id| kb.hold(id, by: "op") }
    assert_equal 0, kb.waiting_counts(["g/r"]).waiting["g/r"].to_i
    assert_empty kb.waiting_cards(["g/r"]).by_slug
    assert_empty kb.flagged_counts(["g/r"])
    @now += 30 * 86_400
    assert_empty kb.flag_reminders, "no reminder on a held card"
  end

  def test_the_watchdog_never_releases_a_held_card
    a = owned
    kb.hold(a, by: "op")
    kb.update(a, { "assignee" => "x" }, by: "op") # even a hand-set assignee: the watchdog leaves a held card alone
    kb.watch_owners(Set[], grace: 0)
    assert_equal "doing", kb.card(a)[:column]
  end

  def test_holding_drops_the_pending_pings_and_a_comment_reaches_nobody
    a = owned
    kb.comment(a, body: "first", author: "op", operator: true)
    assert_equal ["pending"], kb.pings(a).map { |p| p[:status] }
    kb.hold(a, by: "op")
    assert_equal [["failed", "card put on hold"]], kb.pings(a).map { |p| [p[:status], p[:error]] }
    assert_equal "none: on hold", kb.delivery(kb.card(a), "op")
    kb.comment(a, body: "while held", author: "op", operator: true)
    assert_equal 1, kb.pings(a).size
  end

  def test_no_session_owns_a_held_card
    a = owned
    kb.hold(a, by: "op")
    e = assert_raises(AgentsKanban::Invalid) { kb.set_owner(a, session: "tl_g_r", by: "op") }
    assert_match(/on hold: release it first/, e.message)
    kb.register_session(session: "tl_g_r", project: "g/r", type: "lead", launcher: "fullclaude", by: "op")
    assert_empty kb.adopt_ownerless(live: Set["tl_g_r"])
  end

  def test_agents_cannot_see_a_held_card_through_any_field
    a = owned
    other = owned
    note = kb.comment(a, body: "n", author: "op", operator: true)
    cl = kb.checklist_add(a, title: "t", by: "op")
    item = kb.item_add(cl, body: "i", by: "op")
    att = @att.add(a, filename: "n.txt", bytes: "x", by: "op")
    kb.hold(a, by: "op")
    board = JSON.parse(tool("kanban_board", project: "g/r", archived: true))
    assert_equal [other], board["columns"].flat_map { |c| c["cards"] }.map { |c| c["id"] }
    assert_equal "no card #{a}", refused("kanban_card", id: a)
    assert_equal "no card #{a}", refused("kanban_move", id: a, column: "qa", author: "agent-a")
    assert_equal "no card #{a}", refused("kanban_comment", id: a, body: "?", author: "agent-a")
    assert_equal "no card #{a}", refused("kanban_claim", id: a, assignee: "agent-a", tmux_session: "tl_g_r")
    assert_equal "no card #{a}", refused("kanban_update", id: other, parent: a, author: "agent-a")
    assert_equal "no comment #{note}", refused("kanban_comment_edit", comment_id: note, body: "x", author: "op")
    assert_equal "no checklist #{cl}", refused("kanban_checklist_rename", checklist_id: cl, title: "u",
                                                                              author: "a")
    assert_equal "no checklist item #{item}", refused("kanban_checklist_toggle", item_id: item, done: true,
                                                                                      author: "a")
    assert_equal "no attachment #{att[:id]}", refused("kanban_attachment_get", attachment_id: att[:id])
    archived = owned
    kb.archive(archived, by: "op")
    kb.hold(other, by: "op")
    kb.archive(other, by: "op")
    listed = JSON.parse(tool("kanban_board", project: "g/r", archived: true))["archived"].map { |c| c["id"] }
    assert_equal [archived], listed, "an archived card on hold stays out of sight"
    e = assert_raises(AgentsKanban::Invalid) { kb.move(a, column: "qa", by: "agent-a", agent: true) }
    assert_equal "no card #{a}", e.message, "the store refuses an agent too, whatever the entry point"
  end

  def test_a_held_cards_pr_stays_its_own_and_the_refusal_names_no_card
    pr = "https://github.com/o/r_local/pull/9"
    a = owned
    kb.assign_pr(a, url: pr, role: "local", by: "agent-a")
    kb.hold(a, by: "op")
    b = owned
    msg = refused("kanban_pr_assign", id: b, pr_url: pr, role: "local", author: "agent-a")
    assert_equal "#{pr} is already the local PR of another card: a PR belongs to one card", msg
    refute_match(/##{a}\b/, msg)
  end

  def test_parents_and_children_never_reach_a_held_card
    parent = owned(title: "parent")
    child = kb.create(slug: "g/r", title: "child", by: "op", column: "todo", parent: parent)
    e = assert_raises(AgentsKanban::Invalid) { kb.hold(parent, by: "op") }
    assert_equal "card ##{parent} has cards waiting for it (##{child}): finish or detach them first", e.message
    kb.update(child, { "parent" => nil }, by: "op")
    kb.hold(parent, by: "op")
    e = assert_raises(AgentsKanban::Invalid) { kb.create(slug: "g/r", title: "c2", by: "op", parent: parent) }
    assert_equal "parent card ##{parent} is on hold: release it first", e.message
    assert_equal "no card #{parent}", refused("kanban_create", project: "g/r", title: "c3", parent: parent,
                                                               author: "agent-a", tmux_session: "tl_g_r")
    # a held CHILD leaves its parent's children and count
    p2 = owned(title: "p2")
    kid = kb.create(slug: "g/r", title: "kid", by: "op", column: "doing", parent: p2)
    kb.hold(kid, by: "op")
    assert_empty kb.children(p2)
    assert_equal 0, kb.card(p2)[:children]
    assert_equal 0, JSON.parse(tool("kanban_card", id: p2))["card"]["children"]
    e = assert_raises(AgentsKanban::Invalid) { kb.hold(p2, by: "op") }
    assert_equal "card ##{p2} has cards waiting for it (##{kid}): finish or detach them first", e.message,
                 "a held child counts: released, it would wait on a held parent"
  end

  def test_a_held_card_adds_nobody_to_the_members
    a = kb.create(slug: "g/r", title: "x", by: "someone-held", column: "doing")
    kb.hold(a, by: "op-held")
    refute_includes kb.members("g/r"), "someone-held"
    refute_includes kb.members("g/r"), "op-held"
  end

  def test_the_operator_moves_a_held_card_by_hand_and_a_terminal_column_ends_the_hold
    a = owned
    kb.hold(a, by: "op")
    kb.move(a, column: "qa", by: "op")
    assert kb.card(a)[:on_hold_at], "moved by hand: still on hold"
    assert_equal [a], ids(kb.board("g/r", on_hold: true))
    kb.move(a, column: "merged", by: "op")
    assert_nil kb.card(a)[:on_hold_at], "its work is over: the hold ends with it"
    line = kb.card_body(kb.card(a))[:activity].map { |x| x[:body] }.last
    assert_match(/on hold cleared — the card is in Merged/, line)
  end

  def test_hold_is_refused_on_an_archived_or_finished_card
    a = owned
    kb.archive(a, by: "op")
    assert_match(/archived/, assert_raises(AgentsKanban::Invalid) { kb.hold(a, by: "op") }.message)
    done = kb.create(slug: "g/r", title: "d", by: "op", column: "merged")
    assert_match(/its work is over/, assert_raises(AgentsKanban::Invalid) { kb.hold(done, by: "op") }.message)
  end

  def test_the_api_holds_releases_and_serves_both_views
    a = owned
    b = owned
    st, body = @api.hold(a, { "on_hold" => true }, by: "op")
    assert_equal 200, st
    assert_equal "op", body[:card][:on_hold][:by]
    normal = @api.board("g/r")[1]
    assert_equal ["board", 1], normal.values_at(:view, :on_hold_count)
    assert_equal [b], normal[:columns].flat_map { |c| c[:cards] }.map { |c| c[:id] }
    held = @api.board("g/r", on_hold: true)[1]
    assert_equal ["on_hold", [a]], [held[:view], held[:columns].flat_map { |c| c[:cards] }.map { |c| c[:id] }]
    refute_equal @api.board_rev("g/r")[1], @api.board_rev("g/r", on_hold: true)[1]
    assert_equal 422, @api.hold(a, { "on_hold" => "maybe" }, by: "op")[0]
    assert_equal 422, @api.hold(a, { "hold" => true }, by: "op")[0]
    assert_equal 404, @api.hold(999_999, { "on_hold" => true }, by: "op")[0]
    assert_nil @api.hold(a, { "on_hold" => false }, by: "op")[1][:card][:on_hold]
  end
end
