# frozen_string_literal: true

require "test_helper"

# The engine on the coding board (the rules busyyaks ran before the engine, ported test for test) — columns, moves,
# agent gates, labels, due, comments, checklists — and the generic additions: parents, metadata, the content board
# without gates.
class StoreTest < Minitest::Test
  include KanbanTest::Setup
  Invalid = AgentsKanban::Invalid
  Denied = AgentsKanban::Denied

  def titles(col) = kb.board("g/r")[col].map { |c| c[:title] }
  def handoff_ok
    {
      qa: "Open the page at 375 and 1280 px and check the row",
      pr_url: "https://github.com/o/r/pull/1",
      ci_url: "https://ci.example.com/job/r/1/",
      ui_change: false,
    }
  end

  def test_board_has_the_configured_columns_and_create_appends_and_validates
    assert_equal %w[backlog todo doing qa human_check ready merged], kb.board("g/r").keys
    kb.create(slug: "g/r", title: "a", by: "op")
    %w[x y].each { |n| kb.label_create("g/r", name: n, color: "blue") }
    id = kb.create(slug: "g/r", title: " b ", by: "op", labels: "x, y,,x", priority: "high", assignee: " tl_r ")
    assert_equal %w[a b], titles("backlog")
    c = kb.card(id)
    assert_equal [%w[x y], "high", "tl_r", 1], [c[:labels], c[:priority], c[:assignee], c[:position]]
    assert_match(/no board nope/, assert_raises(Invalid) { kb.create(slug: "nope", title: "a", by: "op") }.message)
    assert_raises(Invalid) { kb.create(slug: "g/r", title: " ", by: "op") }
    assert_raises(Invalid) { kb.create(slug: "g/r", title: "a", by: "op", column: "done") }
    assert_raises(Invalid) { kb.create(slug: "g/r", title: "a", by: "op", priority: "urgent") }
    assert_raises(Invalid) { kb.label_create("nope", name: "x", color: "red") }
  end

  def test_move_reorders_and_renumbers_both_columns
    a, b, c = %w[a b c].map { |t| kb.create(slug: "g/r", title: t, by: "op") }
    kb.move(c, column: "backlog", position: 0, by: "op")
    assert_equal %w[c a b], titles("backlog")
    kb.move(a, column: "doing", by: "op")
    kb.move(b, column: "doing", position: 0, by: "op")
    assert_equal %w[c], titles("backlog")
    assert_equal %w[b a], titles("doing")
    assert_equal [0, 1], kb.board("g/r")["doing"].map { |x| x[:position] }
    assert_equal 0, kb.card(c)[:position]
    kb.move(a, column: "doing", position: 99, by: "op")
    assert_equal %w[b a], titles("doing")
    counts = { "backlog" => 1, "todo" => 0, "doing" => 2, "qa" => 0, "human_check" => 0, "ready" => 0, "merged" => 0 }
    assert_equal({ "g/r" => counts }, kb.counts)
    assert_raises(Invalid) { kb.move(a, column: "doing", position: -1, by: "op") }
  end

  def test_agents_stop_at_human_check
    id = kb.create(slug: "g/r", title: "a", by: "op", column: "doing")
    e = assert_raises(Denied) { kb.move(id, column: "human_check", by: "agent-1", agent: true) }
    assert_match(/kanban_handoff/, e.message)
    kb.handoff(id, **handoff_ok, by: "agent-1")
    e = assert_raises(Denied) { kb.move(id, column: "merged", by: "agent-1", agent: true) }
    assert_match(/only the operator moves a card out of Human Check/, e.message)
    assert_raises(Denied) { kb.move(id, column: "doing", by: "agent-1", agent: true) }
    kb.move(id, column: "human_check", position: 0, by: "op") # reorder inside
    kb.move(id, column: "merged", by: "op")
    e = assert_raises(Denied) { kb.create(slug: "g/r", title: "x", by: "agent-1", column: "merged", agent: true) }
    assert_match(/agents cannot create cards in Merged/, e.message)
    e = assert_raises(Denied) { kb.create(slug: "g/r", title: "x", by: "agent-1", column: "ready", agent: true) }
    assert_match(/agents cannot create cards in Ready to merge: create it, do the work, then kanban_handoff/, e.message)
    moves = kb.activity(id).select { |a| a[:kind] == "move" }.map { |a| [a[:author], a[:body]] }
    assert_equal [["agent-1", "In progress → Human Check"], ["op", "Human Check → Merged"]], moves
    d = kb.create(slug: "g/r", title: "z", by: "a")
    assert_match(/only an approved card in Human Check \/ Ready to merge can be moved to Merged; agents stop at the gate/,
                 assert_raises(Denied) { kb.move(d, column: "merged", by: "a", agent: true) }.message)
    assert_match(/kanban_handoff/, assert_raises(Denied) { kb.move(d, column: "ready", by: "a", agent: true) }.message)
    assert_equal "doing", kb.move(d, column: "doing", by: "a", agent: true)[:column], "an ordinary agent move"
  end

  def test_update_archive_comment_and_activity
    id = kb.create(slug: "g/r", title: "a", by: "op")
    kb.create(slug: "g/r", title: "b", by: "op")
    kb.label_create("g/r", name: "ui", color: "purple")
    kb.update(id, { title: "a2", assignee: "s1", labels: ["ui"], notes: "**x**" }, by: "op")
    assert_match(/unknown fields: column/, assert_raises(Invalid) { kb.update(id, { column: "x" }, by: "op") }.message)
    kb.comment(id, body: "hello", author: "s1")
    assert_raises(Invalid) { kb.comment(id, body: " ", author: "s1") }
    kb.archive(id, by: "op")
    assert_equal %w[b], titles("backlog")
    assert_equal 0, kb.board("g/r")["backlog"].first[:position]
    assert_equal [id], kb.archived("g/r").map { |c| c[:id] }
    assert_raises(Invalid) { kb.move(id, column: "todo", by: "op") }
    kb.archive(id, archived: false, by: "op")
    assert_equal %w[b a2], titles("backlog")
    assert_equal %w[create update comment archive archive], kb.activity(id).map { |a| a[:kind] }
    assert_equal 1, kb.board("g/r")["backlog"].last[:comments]
    j = kb.card_json(kb.card(id), description: true)
    assert_includes j[:description_html], "<strong>x</strong>"
    assert_equal [nil, 0, [], nil], j.values_at(:parent, :children, :blocked_by, :metadata)
  end

  def test_label_set_create_rename_recolour_delete
    a = kb.label_create("g/r", name: " bug ", color: "red")
    kb.label_create("g/r", name: "ui", color: "blue")
    assert_equal [%w[bug red], %w[ui blue]], kb.labels("g/r").map { |l| [l[:name], l[:color]] }
    assert_match(/already exists/, assert_raises(Invalid) { kb.label_create("g/r", name: "bug", color: "red") }.message)
    assert_match(/colour must be one of/, assert_raises(Invalid) { kb.label_create("g/r", name: "x", color: "#f00") }.message)
    assert_raises(Invalid) { kb.label_create("g/r", name: "", color: "red") }
    assert_raises(Invalid) { kb.label_create("g/r", name: "a,b", color: "red") }
    id = kb.create(slug: "g/r", title: "c", by: "op", labels: %w[bug ui])
    assert_match(/unknown label nope — g\/r has bug, ui/,
                 assert_raises(Invalid) { kb.update(id, { labels: ["nope"] }, by: "op") }.message)
    kb.label_update(a, name: "defect", color: "orange")
    assert_equal %w[defect ui], kb.card(id)[:labels]
    assert_equal "orange", kb.label!(a)[:color]
    assert_raises(Invalid) { kb.label_update(a, name: "ui") }
    kb.label_delete(kb.label_by_name!("g/r", "ui")[:id])
    assert_equal %w[defect], kb.card(id)[:labels]
    assert_equal %w[defect], kb.labels("g/r").map { |l| l[:name] }
    assert_raises(Invalid) { kb.label!(999_999) }
  end

  def test_due_date_done_and_cover
    id = kb.create(slug: "g/r", title: "c", by: "op", due: "2026-11-05T18:00:00+01:00")
    assert_equal Time.utc(2026, 11, 5, 17).to_i, kb.card(id)[:due_at]
    kb.update(id, { due: "2026-11-06T09:30Z", due_done: true, cover: "green" }, by: "op")
    c = kb.card(id)
    assert_equal [Time.utc(2026, 11, 6, 9, 30).to_i, true, "green"], [c[:due_at], c[:due_done], c[:cover]]
    j = kb.card_json(c)
    assert_equal [true, "green"], [j[:due_done], j[:cover]]
    refute_nil j[:due]
    kb.update(id, { due: "", cover: nil, due_done: "false" }, by: "op")
    assert_equal [nil, false, nil], kb.card(id).values_at(:due_at, :due_done, :cover)
    assert_match(/ISO 8601/, assert_raises(Invalid) { kb.update(id, { due: "tomorrow" }, by: "op") }.message)
    assert_match(/not a real date/, assert_raises(Invalid) { kb.update(id, { due: "2026-02-30T10:00" }, by: "op") }.message)
    assert_raises(Invalid) { kb.update(id, { due_done: "maybe" }, by: "op") }
    assert_raises(Invalid) { kb.update(id, { cover: "chartreuse" }, by: "op") }
    log = kb.activity(id).select { |e| e[:kind] == "update" }.map { |e| e[:body] }
    assert_match(/due: 2026-11-06/, log[0])
    assert_match(/due: done/, log[0])
    assert_match(/cover: green/, log[0])
  end

  def test_comment_edit_and_delete_by_author_only
    id = kb.create(slug: "g/r", title: "c", by: "op")
    cid = kb.comment(id, body: "first `x`", author: "agent-a")
    assert_match(/only agent-a edits or deletes comment/,
                 assert_raises(Denied) { kb.comment_edit(cid, body: "hijack", by: "op") }.message)
    assert_raises(Invalid) { kb.comment_edit(cid, body: " ", by: "agent-a") }
    edited = kb.comment_edit(cid, body: "first **edited**", by: "agent-a")
    refute_nil edited[:edited_at]
    j = kb.activity_json(edited)
    assert_includes j[:body_html], "<strong>edited</strong>"
    refute_nil j[:edited]
    assert_raises(Denied) { kb.comment_delete(cid, by: "op") }
    assert_equal id, kb.comment_delete(cid, by: "agent-a")
    assert_equal %w[create delete], kb.activity(id).map { |a| a[:kind] }
    assert_equal 0, kb.card(id)[:comments]
    assert_raises(Invalid) { kb.comment!(cid) }
    assert_raises(Invalid) { kb.comment_edit(kb.activity(id).first[:id], body: "x", by: "op") } # not a comment
  end

  def test_checklists_items_toggle_progress_convert
    id = kb.create(slug: "g/r", title: "c", by: "op", column: "doing")
    cl = kb.checklist_add(id, title: "Ship", items: ["write **tests**", "deploy"], by: "op")
    cl2 = kb.checklist_add(id, title: "Later", by: "op")
    assert_raises(Invalid) { kb.checklist_add(id, title: " ", by: "op") }
    assert_raises(Invalid) { kb.checklist_add(id, title: "x", items: [1], by: "op") }
    i3 = kb.item_add(cl2, body: "docs", by: "op")
    assert_raises(Invalid) { kb.item_add(cl2, body: "", by: "op") }
    assert_raises(Invalid) { kb.item_add(cl2, body: "x" * 1001, by: "op") }
    lists = kb.checklists(id)
    assert_equal [%w[Ship Later], [2, 1]], [lists.map { |l| l[:title] }, lists.map { |l| l[:items].size }]
    first = lists[0][:items][0]
    kb.item_update(first[:id], done: true, by: "agent-a")
    c = kb.card(id)
    assert_equal [1, 3], [c[:checklist_done], c[:checklist_total]]
    assert_equal [1, 3], kb.board("g/r")["doing"][0].values_at(:checklist_done, :checklist_total)
    assert_equal [1, "agent-a"], kb.item!(first[:id]).values_at(:done, :done_by)
    kb.item_update(first[:id], body: "write tests", by: "op")
    kb.item_update(first[:id], done: false, by: "op")
    assert_nil kb.item!(first[:id])[:done_by]
    assert_raises(Invalid) { kb.item_update(first[:id], done: "perhaps", by: "op") }
    json = kb.card_json(kb.card(id), description: true, checklists: kb.checklists(id))
    assert_equal "deploy", json[:checklists][0][:items][1][:body_html]
    kb.checklist_rename(cl, title: "Ship it", by: "op")
    new_id = kb.item_convert(i3, by: "op")
    n = kb.card(new_id)
    assert_equal ["docs", "doing", 1], [n[:title], n[:column], n[:position]]
    assert_equal 0, kb.checklists(id)[1][:items].size
    assert_match(/converted “docs” to card ##{new_id}/, kb.activity(id).last[:body])
    long = kb.item_add(cl2, body: "y" * 300, by: "op")
    l = kb.card(kb.item_convert(long, by: "op"))
    assert_equal [200, "y" * 300], [l[:title].length, l[:notes]]
    kb.item_delete(kb.checklists(id)[0][:items][0][:id], by: "op")
    assert_equal [0], kb.checklists(id)[0][:items].map { |i| i[:position] }
    kb.checklist_delete(cl, by: "op")
    assert_equal [["Later", 0]], kb.checklists(id).map { |x| [x[:title], x[:position]] }
    m = kb.create(slug: "g/r", title: "m", by: "op", column: "merged")
    item = kb.item_add(kb.checklist_add(m, title: "T", by: "op"), body: "x", by: "op")
    assert_raises(Denied) { kb.item_convert(item, by: "agent", agent: true) }
    assert kb.item_convert(item, by: "op")
  end

  def test_members_are_everyone_seen_on_the_board
    id = kb.create(slug: "g/r", title: "c", by: "op@x", assignee: "tl_g_r")
    kb.comment(id, body: "hi", author: "claude-7")
    assert_equal %w[claude-7 op@x tl_g_r], kb.members("g/r")
  end

  # ── the needs_operator flag (kanban_ask) ──────────────────────────────────────────────────────
  def owned_card
    id = kb.create(slug: "p", title: "security triage", by: "me", column: "doing")
    kb.update(id, { "assignee" => "claude-shop-lead" }, by: "claude-shop-lead")
    kb.set_owner(id, session: "acme_shop", by: "claude-shop-lead")
    id
  end

  # what a session owns decides whether it is finished — scoped to its OPEN registration
  def test_owned_cards_are_the_registrations_since_it_registered_with_their_column_type
    @now = 1_000
    old = kb.create(slug: "p", title: "an earlier s1's", by: "me", column: "merged")
    kb.set_owner(old, session: "s1", by: "me") # a previous session of the same name: history, not the new one's
    @now = 2_000
    kb.register_session(session: "s1", project: "p", type: "lead", launcher: "fullclaude", by: "op")
    a = kb.create(slug: "p", title: "doing it", by: "me", column: "doing")
    kb.set_owner(a, session: "s1", by: "me")
    b = kb.create(slug: "p", title: "done one", by: "me", column: "merged")
    kb.set_owner(b, session: "s1", by: "me")
    kb.create(slug: "p", title: "nobody's", by: "me", column: "doing")
    gone = kb.create(slug: "p", title: "archived", by: "me", column: "doing")
    kb.set_owner(gone, session: "s1", by: "me")
    kb.archive(gone, by: "me")
    other = kb.create(slug: "p", title: "same name, other socket", by: "me", column: "doing")
    kb.set_owner(other, session: "s1", socket: "elsewhere", by: "me")
    loose = kb.create(slug: "p", title: "unregistered owner", by: "me", column: "doing")
    kb.set_owner(loose, session: "s2", by: "me")
    owned = kb.owned_cards(@boards)
    assert_equal [%w[s1 default]], owned.keys, "a session with no open registration is absent (unknown), not empty"
    r = owned[%w[s1 default]]
    assert_equal ["p", 2_000], r.values_at(:project_slug, :since)
    assert_equal [[a, "doing", "In progress", "working", false], [b, "merged", "Merged", "done", true]],
                 r[:cards].map { |c| c.values_at(:id, :column, :column_label, :column_type, :finishes) }
    assert_empty kb.owned_cards([])
  end

  # A question is a FLAG: the card keeps its column (a question asked in review keeps its place in review), agents
  # cannot move it while it waits, the operator's comment answers it — the flag clears, the card stays, the owner is
  # pinged with the answer.
  def test_ask_flags_the_card_in_place_and_the_operators_comment_clears_the_flag
    id = owned_card
    kb.move(id, column: "qa", by: "claude-shop-lead", agent: true)
    @now = 2_000
    c = kb.ask(id, question: "  Auth or **imgproc** first?  ", options: [" Auth first ", "Imgproc first"],
                   by: "shop-sec-imgproc")
    assert_equal ["qa", "Auth or **imgproc** first?", '["Auth first","Imgproc first"]', 2_000, "shop-sec-imgproc"],
                 c.values_at(:column, :question, :question_options, :asked_at, :asked_by)
    assert kb.flagged?(c)
    assert_equal [true, nil], kb.card_json(c).values_at(:needs_operator, :blocked)
    acts = kb.activity(id).last(2)
    assert_equal [%w[comment shop-sec-imgproc], %w[flag shop-sec-imgproc]], acts.map { |a| [a[:kind], a[:author]] },
                 "the question is a normal comment; the flag is logged"
    assert_equal "**Question for the operator:**\n\nAuth or **imgproc** first?\n\n**Options:** `Auth first` · `Imgproc first`",
                 acts.first[:body]
    assert_equal "needs_operator set — the card waits in QA", acts.last[:body]
    refute kb.activity(id).any? { |a| a[:kind] == "move" && a[:author] == "shop-sec-imgproc" }, "no move: the card stays"
    assert_includes kb.activity_json(acts.first)[:body_html], "<strong>imgproc</strong>"
    assert_equal ["Auth first", "Imgproc first"], kb.card_json(c)[:question_options]
    assert_includes kb.card_json(c, description: true)[:question_html], "<strong>imgproc</strong>"
    assert_empty kb.pending_pings, "asking pings nobody (the operator sees it on the board)"
    c = kb.ask(id, question: "Only auth?", by: "claude-shop-lead")
    assert_equal ["qa", "Only auth?", nil], c.values_at(:column, :question, :question_options)
    w = kb.waiting_cards(@boards)
    assert_equal [[id, 2_000]], w.by_slug["p"].map { |x| x.values_at(:id, :since) }, "a flagged card waits in any column"
    assert_equal({ "p" => 1 }, kb.flagged_counts(@boards))
    assert_equal "queued: acme_shop", kb.delivery(kb.card(id), "x")
    # while flagged, agents cannot move it
    e = assert_raises(Denied) { kb.move(id, column: "doing", by: "claude-shop-lead", agent: true) }
    assert_match(/waits for the operator's answer \(needs_operator\) — it stays in QA until the operator comments/, e.message)
    assert_raises(Denied) { kb.handoff(id, **handoff_ok, by: "claude-shop-lead") }
    assert_equal "doing", kb.move(id, column: "doing", by: "operator@example.com")[:column], "the operator may"
    kb.move(id, column: "qa", by: "operator@example.com")
    assert kb.card(id)[:asked_at], "a move does not answer"
    kb.pending_pings.each { |p| kb.ping_result(p, "sent") }

    kb.comment(id, body: "Imgproc", author: "operator@example.com", operator: true)
    c = kb.card(id)
    assert_equal ["qa", nil, nil, nil], c.values_at(:column, :asked_at, :question, :question_options)
    refute kb.flagged?(c)
    ans = kb.activity(id).reverse.find { |a| a[:kind] == "answer" }
    assert_equal ["answered the question — the card stays in QA, work resumes", "operator@example.com"],
                 ans.values_at(:body, :author)
    assert_equal 1, kb.pending_pings.size
    text = kb.pending_pings.first[:text]
    assert_includes text, "[busyyaks] operator@example.com ANSWERED your question on card ##{id}"
    assert_includes text, "Imgproc"
    assert_includes text, "the card stays in QA"
    assert_equal "answer", kb.pending_pings.first[:reason]
    assert_empty kb.waiting_cards(@boards).by_slug
    assert_equal "doing", kb.move(id, column: "doing", by: "claude-shop-lead", agent: true)[:column], "work resumes"
    kb.pending_pings.each { |p| kb.ping_result(p, "sent") }
    kb.comment(id, body: "thanks", author: "operator@example.com", operator: true)
    assert_equal "comment", kb.pending_pings.last[:reason], "a comment on an unflagged card is a comment"
  end

  # blocked_external: a reason and a URL, the card stays, agents wait for kanban_unblock
  def test_block_and_unblock
    id = owned_card
    assert_match(/reason is required/, assert_raises(Invalid) { kb.block(id, reason: " ", url: "https://x", by: "a") }.message)
    assert_match(/url is required/, assert_raises(Invalid) { kb.block(id, reason: "CI red", url: "", by: "a") }.message)
    assert_match(/url must be an http\(s\) URL/,
                 assert_raises(Invalid) { kb.block(id, reason: "CI red", url: "javascript:x", by: "a") }.message)
    assert_raises(Invalid) { kb.block(id, reason: "x" * 2001, url: "https://ci/1", by: "a") }
    assert_match(/not blocked/, assert_raises(Invalid) { kb.unblock(id, by: "a") }.message)
    @now = 3_000
    c = kb.block(id, reason: "Jenkins is down", url: "https://ci.example.com/job/1", by: "claude-shop-lead")
    assert_equal ["doing", 3_000, "claude-shop-lead", "Jenkins is down", "https://ci.example.com/job/1"],
                 c.values_at(:column, :blocked_at, :blocked_author, :blocked_reason, :blocked_url)
    assert_equal({ reason: "Jenkins is down", url: "https://ci.example.com/job/1", by: "claude-shop-lead",
                   at: Time.at(3_000).iso8601, }, kb.card_json(c)[:blocked])
    refute kb.card_json(c)[:needs_operator]
    assert_equal [%w[comment claude-shop-lead], %w[flag claude-shop-lead]],
                 kb.activity(id).last(2).map { |a| [a[:kind], a[:author]] }
    assert_equal "**Blocked (external):** Jenkins is down\n\nhttps://ci.example.com/job/1", kb.activity(id).last(2).first[:body]
    assert_equal [3_000], kb.waiting_cards(@boards).by_slug["p"].map { |x| x[:since] }
    e = assert_raises(Denied) { kb.move(id, column: "qa", by: "claude-shop-lead", agent: true) }
    assert_match(/blocked \(external\): Jenkins is down — kanban_unblock it first/, e.message)
    kb.comment(id, body: "I see it", author: "claude-shop-lead")
    assert kb.card(id)[:blocked_at], "an agent's comment does not unblock"
    c = kb.unblock(id, by: "claude-shop-lead", note: "build 2 green")
    assert_equal [nil, nil, nil, nil], c.values_at(:blocked_at, :blocked_author, :blocked_reason, :blocked_url)
    assert_equal "blocked_external cleared — build 2 green", kb.activity(id).last[:body]
    assert_equal "qa", kb.move(id, column: "qa", by: "claude-shop-lead", agent: true)[:column]
    done = kb.create(slug: "p", title: "d", by: "me", column: "merged")
    assert_match(/its work is over/, assert_raises(Denied) { kb.block(done, reason: "x", url: "https://x/y", by: "a") }.message)
  end

  # ONE reminder per flag after flags.reminder_hours, by the system author, pinging the owner
  def test_flag_reminders_once_after_the_configured_hours
    id = owned_card
    other = owned_card
    kb.ask(id, question: "Which colour?", by: "claude-shop-lead")
    kb.block(other, reason: "API quota", url: "https://status.example.com", by: "claude-shop-lead")
    kb.pending_pings.each { |p| kb.ping_result(p, "sent") }
    @now += (24 * 3600) - 1
    assert_equal [], kb.flag_reminders, "not yet"
    @now += 1
    assert_equal [id, other].sort, kb.flag_reminders.sort
    r = kb.activity(id).last
    assert_equal %w[comment busyyaks], r.values_at(:kind, :author)
    reminder = "**Reminder** — card ##{id} has waited in In progress for 24 h: " \
               "a question for the operator (24 h): Which colour?"
    assert_equal reminder, r[:body]
    assert_match(/blocked \(external, 24 h\): API quota https:\/\/status.example.com/, kb.activity(other).last[:body])
    assert_equal 2, kb.pending_pings.size
    assert_includes kb.pending_pings.first[:text], "Reminder: the card still waits"
    @now += 48 * 3600
    assert_equal [], kb.flag_reminders, "reminded once"
    kb.comment(id, body: "blue", author: "operator@example.com", operator: true)
    kb.ask(id, question: "And the font?", by: "claude-shop-lead")
    @now += 24 * 3600
    assert_equal [id], kb.flag_reminders, "a new question is reminded again"
  end

  def test_ask_validation_and_agent_comment_is_not_an_answer
    id = owned_card
    assert_raises(Invalid) { kb.ask(id, question: "", by: "a") }
    assert_raises(Invalid) { kb.ask(id, question: "x" * 8001, by: "a") }
    assert_raises(Invalid) { kb.ask(id, question: "q", options: [""], by: "a") }
    assert_raises(Invalid) { kb.ask(id, question: "q", options: (1..9).map(&:to_s), by: "a") }
    assert_raises(Invalid) { kb.ask(id, question: "q", options: ["x" * 201], by: "a") }
    assert_raises(Invalid) { kb.ask(id, question: "q", options: %w[A A], by: "a") }
    assert_nil kb.ask(id, question: "q", options: [], by: "a")[:question_options], "[] = a free answer"
    kb.comment(id, body: "more context", author: "shop-sec-imgproc")
    assert kb.card(id)[:asked_at], "an agent's comment is not the answer"
    assert_equal "comment", kb.pending_pings.first[:reason], "a subagent's comment still routes to the lead's session"
    hc = kb.create(slug: "p", title: "hc", by: "op", column: "human_check")
    kb.set_owner(hc, session: "lead_1", by: "op")
    assert_equal "human_check", kb.ask(hc, question: "Q?", by: "lead")[:column], "a gate card may ask too (it stays)"
    done = kb.create(slug: "p", title: "done", by: "op", column: "merged")
    kb.set_owner(done, session: "lead_1", by: "op")
    assert_match(/its work is over/, assert_raises(Denied) { kb.ask(done, question: "Q?", by: "lead") }.message)
    kb.set_owner(id, session: "", by: "me")
    assert_match(/no owner session — nobody would hear the answer/,
                 assert_raises(Denied) { kb.ask(id, question: "q", by: "a") }.message)
  end

  def test_delivery_says_who_hears_it_or_why_nobody
    id = owned_card
    c = kb.card(id)
    assert_equal "queued: acme_shop", kb.delivery(c, "operator@example.com")
    assert_equal "none: claude-shop-lead is the card's owner", kb.delivery(c, "claude-shop-lead")
    kb.set_owner(id, session: "", by: "me")
    assert_equal "none: no owner session", kb.delivery(kb.card(id), "operator@example.com")
    kb.comment(id, body: "Ok, so what's the decision now?", author: "operator@example.com", operator: true)
    assert_empty kb.pending_pings
  end

  # ── handoff + approval ────────────────────────────────────────────────────────────────────────
  def test_agents_reach_human_check_only_through_a_complete_handoff
    id = owned_card
    ok = { qa: "Open /article/x at 375 and 1280 px; the share row shows 4 buttons", pr_url: "https://github.com/o/r/pull/100",
           ci_url: "https://jenkins.example.com/job/shop/job/main/42/", by: "claude-shop-lead", }
    assert_raises(Invalid) { kb.handoff(id, **ok, qa: "short", ui_change: false) }
    assert_match(/pr_url is required/, assert_raises(Invalid) { kb.handoff(id, **ok, pr_url: "", ui_change: false) }.message)
    assert_raises(Invalid) { kb.handoff(id, **ok, ci_url: "javascript:x", ui_change: false) }
    assert_match(/attach screenshots first/, assert_raises(Invalid) { kb.handoff(id, **ok, ui_change: true) }.message)
    kb.attachments_t.insert(card_id: id, filename: "after.png", content_type: "image/png", size: 10, sha256: "x" * 64,
                            stored_path: "/tmp/x", uploaded_by: "claude-shop-lead", created_at: 1)
    kb.handoff(id, **ok, ui_change: true)
    c = kb.card(id)
    assert_equal ["human_check", "https://github.com/o/r/pull/100", true], c.values_at(:column, :pr_url, :ui_change)
    h = kb.activity(id).find { |a| a[:kind] == "handoff" }
    links = "PR https://github.com/o/r/pull/100 · CI https://jenkins.example.com/job/shop/job/main/42/ · " \
            "UI change, screenshots attached"
    assert_equal "handed to Human Check: #{links}", h[:body]
    qa = kb.activity(id).reverse.find { |a| a[:kind] == "comment" }
    assert_equal ["claude-shop-lead", "**Handed to Human Check** · #{links}\n\n#{ok[:qa]}"],
                 qa.values_at(:author, :body), "the QA is a normal comment — not a bare move"
    assert_empty kb.pending_pings, "an agent's move pings nobody"
  end

  def test_approval_moves_to_ready_pings_and_lets_the_agent_merge_then_unapprove
    id = owned_card
    kb.handoff(id, **handoff_ok, by: "claude-shop-lead")
    assert_match(/out of Human Check/,
                 assert_raises(Denied) { kb.move(id, column: "merged", by: "claude-shop-lead", agent: true) }.message)
    assert_raises(Denied) { kb.move(id, column: "ready", by: "claude-shop-lead", agent: true) }
    assert_raises(Invalid) { kb.approve(kb.create(slug: "p", title: "t", by: "me"), by: "me") }
    kb.approve(id, by: "operator@x")
    c = kb.card(id)
    assert_equal ["ready", "operator@x"], [c[:column], c[:approved_by]]
    assert_includes kb.pending_pings.last[:text], "APPROVED card ##{id}"
    assert_includes kb.pending_pings.last[:text], "kanban_move id=#{id} column=merged"
    assert_raises(Denied) { kb.move(id, column: "qa", by: "claude-shop-lead", agent: true) }
    kb.move(id, column: "merged", by: "claude-shop-lead", agent: true)
    assert_equal ["merged", "operator@x"], kb.card(id).values_at(:column, :approved_by), "the approval stays as history"
    assert_match(/its work is over/, assert_raises(Invalid) { kb.handoff(id, **handoff_ok, by: "x") }.message)

    other = owned_card
    kb.handoff(other, **handoff_ok, by: "claude-shop-lead")
    kb.move(other, column: "ready", by: "operator@x")
    assert_equal "operator@x", kb.card(other)[:approved_by]
    kb.unapprove(other, by: "operator@x")
    assert_equal ["human_check", nil], kb.card(other).values_at(:column, :approved_at)
    assert_includes kb.pending_pings.last[:text], "moved Ready to merge → Human Check:"
    # an agent in a gate without the approval: refused with how the approval is given
    third = owned_card
    kb.handoff(third, **handoff_ok, by: "claude-shop-lead")
    kb.move(third, column: "ready", by: "operator@x")
    kb.unapprove(third, by: "operator@x")
    kb.move(third, column: "ready", position: 0, by: "operator@x") # a reorder inside the gate approves nothing
    kb.move(third, column: "human_check", by: "operator@x")
    kb.move(third, transition: "Move", column: "ready", by: "operator@x") # a drag along the step IS the approval
    assert_equal "operator@x", kb.card(third)[:approved_by]
    kb.move(third, column: "doing", by: "operator@x")
    assert_nil kb.card(third)[:approved_at], "leaving the approved column withdraws it"
  end

  # The local v3 board (fixtures/boards/local_v3.board.json): two agent review loops, three operator gates, Cancel.
  def local_card(m)
    id = m.create(slug: "p", title: "t", by: "me", column: "doing")
    m.update(id, { "assignee" => "claude-shop-lead" }, by: "claude-shop-lead")
    m.set_owner(id, session: "acme_shop", by: "claude-shop-lead")
    id
  end

  def test_local_v3_walks_from_in_progress_to_done_through_both_loops
    m = store(board: KanbanTest.board_hash("local_v3"))
    id = local_card(m)
    m.move(id, transition: "Open local PR", by: "claude-shop-lead", agent: true)
    assert_equal ["local_agent_review", 1], [m.card(id)[:column], m.card_json(m.card(id))[:review_round]]
    m.move(id, transition: "Comments posted", by: "reviewer", agent: true)
    assert_nil m.card_json(m.card(id))[:review_round], "a work column counts no round"
    m.move(id, transition: "All threads answered", by: "claude-shop-lead", agent: true)
    assert_equal 2, m.card_json(m.card(id))[:review_round]
    e = assert_raises(Denied) { m.move(id, column: "local_human_review", by: "reviewer", agent: true) }
    assert_match(/kanban_handoff/, e.message)
    m.handoff(id, **handoff_ok, by: "reviewer") # the one gate the review column leads to
    assert_equal "local_human_review", m.card(id)[:column]
    e = assert_raises(Denied) { m.move(id, column: "local_merged_pr", by: "claude-shop-lead", agent: true) }
    assert_match(/only the operator moves a card Local: Human review → Local: Merged \(that is the approval\)/, e.message)
    m.move(id, transition: "Changes requested", by: "operator@x")
    assert_equal ["local_author", nil], m.card(id).values_at(:column, :approved_at), "no approval"
    m.move(id, transition: "All threads answered", by: "claude-shop-lead", agent: true)
    assert_equal 3, m.card_json(m.card(id))[:review_round], "Changes requested → exactly one re-round"
    e = assert_raises(Denied) { m.move(id, transition: "Comments posted", by: "reviewer", agent: true) }
    assert_equal "the one re-round after the operator's Changes requested is done (Local: Agent review, round 3): " \
                 "the loop ends here — kanban_handoff the card back to Local: Human review", e.message
    m.handoff(id, **handoff_ok, by: "reviewer")
    assert_equal ["local_human_review", []], m.card(id).values_at(:column, :labels), "a re-round is not a deadlock"
    m.approve(id, by: "operator@x")
    c = m.card(id)
    assert_equal ["local_merged_pr", "operator@x"], c.values_at(:column, :approved_by)
    assert_equal "approved Local: Human review → Local: Merged — the agent carries on and moves it to Local: Deploy check",
                 m.activity(id).find { |a| a[:kind] == "approve" }[:body]
    assert_includes m.pending_pings.last[:text], "kanban_handoff id=#{id} column=deploy_check"
    e = assert_raises(Denied) { m.move(id, transition: "Deploy locally", by: "claude-shop-lead", agent: true) }
    assert_match(/kanban_handoff/, e.message, "the next column is a gate: a handoff (the deploy receipt)")
    m.handoff(id, **handoff_ok, by: "claude-shop-lead")
    assert_equal ["deploy_check", nil], m.card(id).values_at(:column, :approved_at), "moving on ended the approval"
    m.move(id, transition: "Deploy failed", by: "operator@x")
    assert_equal "doing", m.card(id)[:column]
    m.move(id, transition: "Open local PR", by: "claude-shop-lead", agent: true)
    assert_equal 1, m.card_json(m.card(id))[:review_round], "rounds start over after rework"
    m.handoff(id, **handoff_ok, by: "reviewer")
    m.approve(id, by: "operator@x")
    m.handoff(id, **handoff_ok, by: "claude-shop-lead")
    m.approve(id, by: "operator@x") # OK → open public PR
    assert_equal ["public_agent_review", "operator@x"], m.card(id).values_at(:column, :approved_by)
    assert_equal 1, m.card_json(m.card(id))[:review_round], "entering the public loop from its gate is round 1"
    assert_includes m.pending_pings.last[:text], "kanban_handoff id=#{id} column=public_human_review"
    m.handoff(id, **handoff_ok, by: "reviewer")
    assert_nil m.card(id)[:approved_at]
    e = assert_raises(Denied) { m.move(id, column: "awaiting_merge", by: "claude-shop-lead", agent: true) }
    assert_match(/only the operator moves a card Public: Human review → Awaiting merge \(that is the approval\)/, e.message)
    e = assert_raises(Denied) { m.move(id, column: "public_author", by: "claude-shop-lead", agent: true) }
    assert_match(/only the operator moves a card out of Public: Human review/, e.message)
    m.approve(id, by: "operator@x")
    assert_equal ["awaiting_merge", "operator@x"], m.card(id).values_at(:column, :approved_by)
    assert_includes m.pending_pings.last[:text], "Merge it now, then move the card to Done"
    e = assert_raises(Denied) { m.move(id, transition: "Move", column: "doing", by: "claude-shop-lead", agent: true) }
    assert_match(/for an agent/, e.message, "the catch-all is the operator's")
    m.move(id, transition: "Merge", by: "claude-shop-lead", agent: true)
    assert_equal ["done", "operator@x"], m.card(id).values_at(:column, :approved_by), "the final approval stays as history"
    assert_raises(Denied) { m.move(id, transition: "Reopen", by: "claude-shop-lead", agent: true) }
    m.move(id, transition: "Reopen", by: "operator@x")
    assert_equal ["doing", nil], m.card(id).values_at(:column, :approved_at)
    m.move(id, transition: "Cancel", by: "operator@x")
    assert_equal "cancelled", m.card(id)[:column]
    assert_raises(Denied) { m.move(id, column: "doing", by: "claude-shop-lead", agent: true) }
    assert_raises(Denied) { m.create(slug: "p", title: "x", by: "a", column: "cancelled", agent: true) }
    e = assert_raises(Denied) { m.move(local_card(m), transition: "Cancel", by: "claude-shop-lead", agent: true) }
    assert_match(/for an agent/, e.message)
  end

  # An agent leaves a gate only once approved and only along a named agent edge; a card approved into a gate (the
  # operator's drag along the step) may then take that edge.
  def test_gate_exit_needs_the_approval_and_a_named_agent_edge
    m = store(board: KanbanTest.board_hash("local_v3"))
    id = local_card(m)
    m.move(id, column: "awaiting_merge", by: "operator@x") # a plain drag: no approval
    e = assert_raises(Denied) { m.move(id, transition: "Merge", by: "claude-shop-lead", agent: true) }
    approval = "\\(approval = the operator's move Public: Human review → Awaiting merge\\)"
    assert_match(/sits in Awaiting merge without the operator's approval #{approval} — agents never skip it/, e.message)
    m.move(id, column: "public_human_review", by: "operator@x")
    m.move(id, column: "awaiting_merge", by: "operator@x")
    assert m.card(id)[:approved_at]
    m.move(id, transition: "Merge", by: "claude-shop-lead", agent: true)
    assert_equal "done", m.card(id)[:column]
    # a gate with no named agent exit: the operator only, approved or not
    other = local_card(m)
    m.move(other, column: "local_human_review", by: "operator@x")
    e = assert_raises(Denied) { m.move(other, column: "doing", by: "claude-shop-lead", agent: true) }
    assert_match(/only the operator moves a card out of Local: Human review/, e.message)
  end

  # Which gate a handoff goes to: the one the card's column leads to; several need the transition or column; none is
  # refused with the board's gates.
  def test_handoff_target_resolution
    cols = [{ "key" => "w", "label" => "Work", "type" => "working" },
            { "key" => "g1", "label" => "Gate one", "type" => "gate" },
            { "key" => "g2", "label" => "Gate two", "type" => "gate" },
            { "key" => "d", "label" => "Done", "type" => "done" },]
    ts = [{ "name" => "To one", "from" => "w", "to" => "g1", "by" => "agent" },
          { "name" => "To two", "from" => "w", "to" => "g2", "by" => "agent" },
          { "name" => "Move", "from" => "*", "to" => "*", "by" => "operator" },]
    kb.board_save("g/r", { "columns" => cols, "transitions" => ts }, by: "op")
    id = kb.create(slug: "g/r", title: "a", by: "op", column: "w")
    e = assert_raises(Invalid) { kb.handoff(id, **handoff_ok, by: "a") }
    assert_match(/Work hands off to Gate one or Gate two: give transition \(the name\) or column/, e.message)
    e = assert_raises(Denied) { kb.handoff(id, **handoff_ok, by: "a", transition: "Nope") }
    assert_match(/no transition "Nope" from Work for an agent \(To one, To two\)/, e.message)
    assert_equal "g2", kb.handoff(id, **handoff_ok, by: "a", transition: "to two")[:column]
    b = kb.create(slug: "g/r", title: "b", by: "op", column: "w")
    assert_equal "g1", kb.handoff(b, **handoff_ok, by: "a", column: "g1")[:column]
    c = kb.create(slug: "g/r", title: "c", by: "op", column: "w")
    assert_raises(Invalid) { kb.handoff(c, **handoff_ok, by: "a", column: "zz") }
  end

  # review_loop.max_rounds: entries into a review column from a work column are counted; at the limit the agent's loop
  # moves are refused and the handoff out of the review column carries the unresolved label (created on the board).
  def test_review_round_limit_ends_the_loop_with_the_unresolved_label
    m = store(board: KanbanTest.board_hash("local_v3"))
    id = local_card(m)
    m.move(id, transition: "Open local PR", by: "claude-shop-lead", agent: true)
    2.times do
      m.move(id, transition: "Comments posted", by: "reviewer", agent: true)
      m.move(id, transition: "All threads answered", by: "claude-shop-lead", agent: true)
    end
    assert_equal 3, m.card_json(m.card(id))[:review_round]
    e = assert_raises(Denied) { m.move(id, transition: "Comments posted", by: "reviewer", agent: true) }
    limit = "review round limit reached (3/3 in Local: Agent review): the loop ends here — kanban_handoff the card to " \
            "Local: Human review with review_summary (it carries the label \"unresolved\" when needs_human + open > 0)"
    assert_equal limit, e.message
    assert_equal "local_author", m.move(id, column: "local_author", by: "operator@x")[:column], "the operator may"
    e = assert_raises(Denied) { m.move(id, transition: "All threads answered", by: "claude-shop-lead", agent: true) }
    assert_match(/review round limit reached/, e.message)
    m.move(id, column: "local_agent_review", by: "operator@x")
    assert_equal 4, m.card_json(m.card(id))[:review_round], "the operator's move still counts"
    assert_empty m.labels("p")
    e = assert_raises(Invalid) { m.handoff(id, **handoff_ok, by: "reviewer") }
    assert_equal "review_summary is required at the review round limit (4/3 in Local: Agent review): the " \
                 "reviewer's SUMMARY counts {fixed, resolved_by_argument, needs_human, open}", e.message
    sum = { "fixed" => 5, "resolved_by_argument" => 1, "needs_human" => 1, "open" => 0 }
    { sum.merge("open" => -1) => /review_summary.open must be an integer >= 0/,
      sum.merge("open" => "0") => /review_summary.open must be an integer >= 0/,
      sum.except("fixed") => /must have exactly fixed, resolved_by_argument, needs_human, open/,
      sum.merge("extra" => 1) => /must have exactly/,
      "0 open" => /must be an object/, }.each do |bad, msg|
      assert_match(msg, assert_raises(Invalid) { m.handoff(id, **handoff_ok, review_summary: bad, by: "reviewer") }.message)
    end
    m.handoff(id, **handoff_ok, review_summary: sum, by: "reviewer")
    c = m.card(id)
    assert_equal ["local_human_review", ["unresolved"]], c.values_at(:column, :labels)
    assert_includes m.activity(id).find { |a| a[:kind] == "handoff" }[:body],
                    "review: fixed 5 · resolved-by-argument 1 · needs_human 1 · open 0"
    assert_equal [%w[unresolved red]], m.labels("p").map { |l| l.values_at(:name, :color) }, "created on the board"
    relabel = m.activity(id).reverse.find { |a| a[:kind] == "update" }
    assert_match(/labels: unresolved \(review rounds exhausted: 3; 1 thread needs_human \/ open\)/, relabel[:body])
    # at the limit with every thread resolved: no label (the operator, card #248: 7 fixed, 0 open, still labelled)
    done = local_card(m)
    m.move(done, transition: "Open local PR", by: "claude-shop-lead", agent: true)
    2.times do
      m.move(done, transition: "Comments posted", by: "reviewer", agent: true)
      m.move(done, transition: "All threads answered", by: "claude-shop-lead", agent: true)
    end
    clean_sum = { fixed: 7, resolved_by_argument: 0, needs_human: 0, open: 0 } # symbol keys too
    m.handoff(done, **handoff_ok, review_summary: clean_sum, by: "reviewer")
    assert_equal ["local_human_review", []], m.card(done).values_at(:column, :labels)
    assert_includes m.activity(done).find { |a| a[:kind] == "handoff" }[:body],
                    "review: fixed 7 · resolved-by-argument 0 · needs_human 0 · open 0"
    # below the limit a handoff carries no label; a clean board without review_loop counts rounds but limits nothing
    clean = local_card(m)
    m.move(clean, transition: "Open local PR", by: "claude-shop-lead", agent: true)
    m.handoff(clean, **handoff_ok, by: "reviewer")
    assert_equal [], m.card(clean)[:labels]
    s = store(KanbanTest.config("content"))
    cols = KanbanTest.board_hash("content")["columns"] +
           [{ "key" => "rev", "label" => "Review", "type" => "review" }]
    loop = [ # the loop's named edges
      { "name" => "Review", "from" => "running", "to" => "rev", "by" => "agent" },
      { "name" => "Rework", "from" => "rev", "to" => "running", "by" => "agent" },
    ]
    s.board_save("p", { "columns" => cols, "transitions" => KanbanTest.board_hash("content")["transitions"] + loop },
                 by: "op")
    x = s.create(slug: "p", title: "x", by: "lead", column: "running")
    5.times do
      s.move(x, column: "rev", by: "w", agent: true)
      s.move(x, column: "running", by: "w", agent: true)
    end
    assert_equal "rev", s.move(x, column: "rev", by: "w", agent: true)[:column]
    assert_equal 6, s.card_json(s.card(x))[:review_round]
  end

  # The public loop is entered from a gate (Local: Deploy check → Open public PR): that entry is round 1, so the
  # public loop has the same max_rounds as the local one.
  def test_public_loop_counts_its_entry_from_the_gate
    m = store(board: KanbanTest.board_hash("local_v3"))
    id = local_card(m)
    m.move(id, column: "deploy_check", by: "operator@x")
    m.move(id, transition: "Open public PR", by: "operator@x")
    2.times do
      m.move(id, transition: "Comments posted", by: "reviewer", agent: true)
      m.move(id, transition: "All threads answered", by: "claude-shop-lead", agent: true)
    end
    assert_equal 3, m.card_json(m.card(id))[:review_round]
    e = assert_raises(Denied) { m.move(id, transition: "Comments posted", by: "reviewer", agent: true) }
    assert_match(/review round limit reached \(3\/3 in Public: Agent review\)/, e.message)
  end

  # review_loop.columns: only the named review columns are loops; a coding board's QA counts no rounds, is never limited
  def test_review_columns_outside_review_loop_columns_are_not_limited
    s = store
    x = s.create(slug: "g/r", title: "x", by: "lead", column: "doing")
    5.times do
      s.move(x, column: "qa", by: "w", agent: true)
      s.move(x, column: "doing", by: "w", agent: true)
    end
    assert_equal "qa", s.move(x, column: "qa", by: "w", agent: true)[:column]
    assert_nil s.card_json(s.card(x))[:review_round], "not a loop column: no rounds"
  end

  # Rework out of a review column (Local: Merged, an Agent review) is a fresh start: the rounds of the old loop do not
  # block the next "Open local PR"; the operator's drag back along the loop's own edge keeps them.
  def test_rework_from_a_review_column_starts_the_rounds_over
    m = store(board: KanbanTest.board_hash("local_v3"))
    id = local_card(m)
    m.move(id, transition: "Open local PR", by: "claude-shop-lead", agent: true)
    2.times do
      m.move(id, transition: "Comments posted", by: "reviewer", agent: true)
      m.move(id, transition: "All threads answered", by: "claude-shop-lead", agent: true)
    end
    m.handoff(id, **handoff_ok, review_summary: { fixed: 1, resolved_by_argument: 0, needs_human: 0, open: 0 },
                                by: "reviewer")
    m.approve(id, by: "operator@x")
    assert_equal "local_merged_pr", m.card(id)[:column]
    m.move(id, transition: "Rework", by: "operator@x")
    m.move(id, transition: "Open local PR", by: "claude-shop-lead", agent: true)
    assert_equal 1, m.card_json(m.card(id))[:review_round]
    m.move(id, transition: "Rework", by: "operator@x") # straight out of the Agent review
    m.move(id, transition: "Open local PR", by: "claude-shop-lead", agent: true)
    assert_equal 1, m.card_json(m.card(id))[:review_round]
  end

  # A card that reaches a terminal column waits for nobody: its flags are cleared (waiting counts, reminders, the
  # Agents sidebar stop seeing it).
  def test_done_or_cancelled_clears_the_flags
    m = store(board: KanbanTest.board_hash("local_v3"))
    id = local_card(m)
    m.ask(id, question: "which colour?", by: "claude-shop-lead")
    m.block(id, reason: "CI runner offline", url: "https://ci.example.com/1", by: "claude-shop-lead")
    assert m.flagged?(m.card(id))
    m.move(id, transition: "Cancel", by: "operator@x")
    c = m.card(id)
    assert_equal ["cancelled", nil, nil, nil], c.values_at(:column, :asked_at, :blocked_at, :question)
    refute m.flagged?(c)
    assert_equal "needs_operator + blocked_external cleared — the card is in Cancelled",
                 m.activity(id).reverse.find { |a| a[:kind] == "flag" }[:body]
  end

  # The operator's comment on an externally blocked card clears blocked_external (the operator's way; agents use
  # kanban_unblock); an agent's comment does not.
  def test_the_operators_comment_clears_blocked_external
    m = store(board: KanbanTest.board_hash("local_v3"))
    id = local_card(m)
    m.block(id, reason: "waiting on the vendor API", url: "https://status.example.com", by: "claude-shop-lead")
    m.comment(id, body: "still down", author: "claude-shop-lead")
    refute_nil m.card(id)[:blocked_at], "an agent's comment is no answer"
    m.comment(id, body: "vendor is back", author: "operator@x", operator: true)
    assert_nil m.card(id)[:blocked_at]
    assert_equal "blocked_external cleared by the operator's comment",
                 m.activity(id).reverse.find { |a| a[:kind] == "flag" }[:body]
  end

  # approval.requires_green_ci — every approval step (button or drag along it) asks the ci: port for
  # that step and is refused, nothing moved or logged, unless the card's PR checks are green.
  def test_approval_waits_for_green_ci_at_every_step
    m = store(board: KanbanTest.board_hash("local_v3"))
    id = local_card(m)
    m.move(id, transition: "Open local PR", by: "claude-shop-lead", agent: true)
    m.handoff(id, **handoff_ok, by: "claude-shop-lead")
    refused = lambda do |pattern, &blk|
      e = assert_raises(Invalid, &blk)
      assert_match(pattern, e.message)
      assert_equal ["local_human_review", nil], m.card(id).values_at(:column, :approved_at)
      refute m.activity(id).any? { |a| a[:kind] == "approve" }
    end
    {
      { number: 7, state: "pending", finished_at: nil } =>
        /PR #7 of card ##{id} — CI is still running; approval waits for green CI/,
      { number: 7, state: "failure", finished_at: 5 } => /PR #7 of card ##{id} — CI failed/,
      { number: nil, state: "unpolled", finished_at: nil } => /its PR of card ##{id} — CI not read yet/,
      { number: 7, state: "nochecks", finished_at: nil } => /no CI checks ran/,
    }.each do |answer, pattern|
      approval_ci.answer = answer
      step = /\Anot approved \(Local: Human review → Local: Merged\): .*#{pattern.source}/
      refused.call(step) { m.approve(id, by: "operator@x") }
      refused.call(pattern) { m.move(id, column: "local_merged_pr", by: "operator@x") }
    end
    approval_ci.answer = { number: 7, state: "blocked", finished_at: nil, reason: "the local PR #3 is not merged (open)" }
    blocked = "not approved (Local: Human review → Local: Merged): card ##{id} — the local PR #3 is not merged (open)"
    refused.call(/\A#{Regexp.escape(blocked)}\z/) { m.approve(id, by: "operator@x") }
    approval_ci.answer = nil
    refused.call(/card ##{id} has no PR whose checks could be read/) { m.approve(id, by: "operator@x") }
    approval_ci.answer = { number: 7, state: "success", finished_at: 5 }
    approval_ci.down = "github down"
    refused.call(/CI state of card ##{id} is unknown — github down/) { m.approve(id, by: "operator@x") }

    approval_ci.down = nil
    m.approve(id, by: "operator@x")
    assert_equal ["local_merged_pr", "operator@x"], m.card(id).values_at(:column, :approved_by)
    assert_equal({ from: "local_human_review", to: "local_merged_pr", then: "deploy_check", name: "Approve", final: false },
                 approval_ci.asked.last[1])

    m.move(id, column: "public_human_review", by: "operator@x")
    approval_ci.answer = { number: 3, state: "pending", finished_at: nil }
    e = assert_raises(Invalid) { m.approve(id, by: "operator@x") }
    assert_match(/not approved \(Public: Human review → Awaiting merge\): PR #3 .* CI is still running/, e.message)
    assert approval_ci.asked.last[1][:final], "the final step is asked as such: the host reads the public PR there"
    assert_equal "public_human_review", m.card(id)[:column]
    approval_ci.answer = { number: 3, state: "success", finished_at: 9 }
    m.approve(id, by: "operator@x")
    assert_equal ["awaiting_merge", "operator@x"], m.card(id).values_at(:column, :approved_by)

    n = approval_ci.asked.size
    m.move(id, column: "doing", by: "operator@x")
    m.move(id, column: "local_merged_pr", by: "operator@x")
    assert_equal n, approval_ci.asked.size, "a move that is no approval step never asks CI"
  end

  def test_a_store_with_the_green_ci_gate_needs_the_port
    e = assert_raises(AgentsKanban::ConfigError) do
      AgentsKanban::Store.new(db, config: config, markdown: KanbanTest.markdown(config), boards: ->(_s) { true })
    end
    assert_match(/approval.requires_green_ci but the Store got no ci: port/, e.message)
    content = KanbanTest.config("content")
    assert AgentsKanban::Store.new(db, config: content, markdown: KanbanTest.markdown(content), boards: ->(_s) { true })
  end

  # ── pings + watchdog ─────────────────────────────────────────────────────────────────────────
  def test_pings_coalesce_and_the_owner_never_pings_itself
    id = owned_card
    kb.comment(id, body: "reply as session", author: "acme_shop")
    assert_empty kb.pending_pings
    kb.comment(id, body: "first", author: "me")
    kb.comment(id, body: "second", author: "other-agent")
    assert_equal 1, kb.pending_pings.size
    assert_includes kb.pending_pings.first[:text], "second"
    kb.ping_result(kb.pending_pings.first, "sent")
    assert_equal ["sent", 1], kb.pings(id).first.values_at(:status, :attempts)
    assert_includes kb.activity(id).map { |a| a[:kind] }, "ping"
    sent = {
      at: Time.at(1_000).iso8601, done_at: Time.at(1_000).iso8601, session: "acme_shop",
      reason: "comment", status: "sent", error: nil, attempts: 1,
    }
    assert_equal(sent, kb.ping_json(kb.pings(id).first))
  end

  def test_watchdog_releases_after_grace_and_moves_doing_back_and_stays_in_human_input
    id = owned_card
    assert_equal [], kb.watch_owners(["other"].to_set, grace: 60), "first miss only marks it"
    @now += 30
    assert_equal [], kb.watch_owners([].to_set, grace: 60), "still inside the grace"
    kb.watch_owners(["acme_shop"].to_set, grace: 60)
    assert_nil kb.card(id)[:owner_missing_since], "back = reset"
    kb.watch_owners([].to_set, grace: 60)
    @now += 61
    assert_equal [id], kb.watch_owners([].to_set, grace: 60)
    c = kb.card(id)
    assert_equal [nil, nil, "todo"], c.values_at(:owner_session, :assignee, :column)
    assert_includes kb.activity(id).map { |a| a[:kind] }, "watchdog"

    q = owned_card
    kb.move(q, column: "qa", by: "op")
    kb.ask(q, question: "Which first?", by: "claude-shop-lead")
    kb.watch_owners([].to_set, grace: 60)
    @now += 61
    assert_equal [q], kb.watch_owners([].to_set, grace: 60)
    assert_equal ["qa", nil, nil, "Which first?"], kb.card(q).values_at(:column, :owner_session, :assignee, :question),
                 "released in place, still flagged for the operator"
  end

  def test_gaining_an_owner_relays_the_operators_undelivered_comments_in_one_ping
    id = kb.create(slug: "p", title: "card 19", by: "me", column: "doing")
    kb.comment(id, body: "old, answered", author: "operator@example.com", operator: true)
    kb.comment(id, body: "Stopped. Waiting for go.", author: "shop-sec-imgproc")
    kb.comment(id, body: "Ok, so what's the decision now?", author: "operator@example.com", operator: true)
    kb.comment(id, body: "And the deploy?", author: "operator@example.com", operator: true)
    assert_empty kb.pending_pings
    kb.set_owner(id, session: "acme_shop", by: "operator@example.com")
    pings = kb.pending_pings
    assert_equal 1, pings.size
    t = pings.first[:text]
    assert_includes t, "operator@example.com commented on card ##{id}"
    assert_includes t, "Ok, so what's the decision now?"
    assert_includes t, "And the deploy?"
    refute_includes t, "old, answered"
    assert_equal "relay", pings.first[:reason]
    kb.set_owner(id, session: "other", by: "operator@example.com")
    assert_equal 1, kb.pending_pings.size, "relayed once"
  end

  # ── parents + metadata (generic) on the content board ─────────────────────────────────────────
  def content = store(KanbanTest.config("content"))

  def test_content_board_has_no_gate_and_agents_may_move_freely_to_done
    s = content
    id = s.create(slug: "p", title: "article: japan", by: "lead", agent: true)
    assert_equal "waiting", s.card(id)[:column]
    assert_match(/no handoff gate \(no gate column\)/,
                 assert_raises(Invalid) { s.handoff(id, qa: "x", pr_url: "", ci_url: "", ui_change: false, by: "a") }.message)
    assert_match(/no approval step/, assert_raises(Invalid) { s.approve(id, by: "op") }.message)
    assert_equal "done", s.move(id, column: "done", by: "worker", agent: true)[:column]
    assert_raises(Denied) { s.move(id, column: "running", by: "worker", agent: true) }
  end

  # An unfiltered owner picker lists every tmux session on the host (another app's, other projects'), and picking one
  # would type this board's pings into it. A board that names its sessions refuses any other.
  def test_owner_and_claim_refuse_a_session_that_is_not_one_of_the_boards
    s = content
    id = s.create(slug: "p", title: "article: japan", by: "lead", column: "queued")
    e = assert_raises(Invalid) { s.set_owner(id, session: "coding_lead", by: "op") }
    assert_match(/session "coding_lead" is not one of this board's sessions \(news_articles, news-articles-\*\)/, e.message)
    assert_raises(Invalid) { s.claim(id, assignee: "news-writer", session: "acme_content_app") }
    assert_equal [nil, nil], s.card(id).values_at(:assignee, :owner_session),
                 "a refused claim changes nothing — no assignee without a listener"
    assert_equal "news-articles-7", s.claim(id, assignee: "news-writer", session: "news-articles-7")[:owner_session]
    assert_equal "news_articles", s.set_owner(id, session: "news_articles", by: "op")[:owner_session]
    assert_nil s.set_owner(id, session: "", by: "op")[:owner_session], "clearing is always allowed"
    assert_equal "anything",
                 kb.set_owner(kb.create(slug: "p", title: "t", by: "me"), session: "anything", by: "op")[:owner_session],
                 "null = the host's rule"
  end

  # A watchdog that scans every owned card would unassign cards already in Done. Only the watched columns (listened +
  # watchdog.from) are released; a finished card keeps its history.
  def test_watchdog_leaves_a_finished_cards_owner_and_assignee_as_history
    s = content
    done = s.create(slug: "p", title: "article: japan", by: "lead", column: "queued")
    s.claim(done, assignee: "news-writer", session: "news-articles-2")
    s.move(done, column: "done", by: "news-writer", agent: true)
    run = s.create(slug: "p", title: "article: mexico", by: "lead", column: "queued")
    s.claim(run, assignee: "news-writer", session: "news-articles-3")
    s.move(run, column: "running", by: "news-writer", agent: true)
    s.watch_owners([].to_set, grace: 60)
    @now += 61
    assert_equal [run], s.watch_owners([].to_set, grace: 60)
    assert_equal ["queued", nil, nil], s.card(run).values_at(:column, :assignee, :owner_session)
    assert_equal ["done", "news-writer", "news-articles-2", nil],
                 s.card(done).values_at(:column, :assignee, :owner_session, :owner_missing_since)
    refute_includes s.activity(done).map { |a| a[:kind] }, "watchdog"
    # the coding board: a Merged card is outside listened too
    m = owned_card
    kb.move(m, column: "human_check", by: "op")
    kb.approve(m, by: "op")
    kb.move(m, column: "merged", by: "op")
    kb.watch_owners([].to_set, grace: 60)
    @now += 61
    assert_equal [], kb.watch_owners([].to_set, grace: 60)
    assert_equal %w[claude-shop-lead acme_shop], kb.card(m).values_at(:assignee, :owner_session)
  end

  def test_a_child_waits_for_its_parent_then_is_promoted_and_claimable
    s = content
    parent = s.create(slug: "p", title: "article", by: "lead", column: "queued",
                      metadata: { "draft_id" => 12, "region" => "japan" })
    child = s.create(slug: "p", title: "translation", by: "lead", parent: parent, metadata: { "draft_id" => 12 })
    c = s.card(child)
    assert_equal [parent, [parent], { "draft_id" => 12 }, "waiting"], c.values_at(:parent_id, :blocked_by, :metadata, :column)
    assert_equal [1, []], s.card(parent).values_at(:children, :blocked_by)
    assert_equal [{ "draft_id" => 12 }, parent, [parent]], s.card_json(c).values_at(:metadata, :parent, :blocked_by)
    assert_equal [child], s.children(parent).map { |x| x[:id] }
    e = assert_raises(Invalid) { s.move(child, column: "queued", by: "op") }
    assert_match(/card ##{child} cannot enter Queued while it waits for card ##{parent} \(not yet in Done\)/, e.message)
    assert_match(/cannot be claimed/,
                 assert_raises(Invalid) { s.claim(child, assignee: "w", session: "news-articles-1") }.message)
    assert_equal "done", s.move(child, column: "done", by: "op")[:column], "a column outside dependencies.blocked is fine"
    s.move(child, column: "waiting", by: "op")
    assert_match(/cannot enter/,
                 assert_raises(Invalid) { s.create(slug: "p", title: "x", by: "l", column: "running", parent: parent) }.message)

    s.move(parent, column: "done", by: "worker", agent: true)
    c = s.card(child)
    assert_equal ["queued", []], c.values_at(:column, :blocked_by), "promoted when the parent finished"
    mv = s.activity(child).last
    assert_equal ["board", "Waiting → Queued (parent ##{parent} done, by worker)"], mv.values_at(:author, :body)
    s.claim(child, assignee: "w", session: "news-articles-1")
    assert_equal %w[w news-articles-1], s.card(child).values_at(:assignee, :owner_session)
    assert_equal 1, s.card(parent)[:children]
  end

  def test_parent_validation_and_metadata_rules
    s = content
    a = s.create(slug: "p", title: "a", by: "l")
    b = s.create(slug: "p", title: "b", by: "l", parent: a)
    far = s.create(slug: "g/r", title: "far", by: "l")
    assert_match(/is on g\/r, not on p/, assert_raises(Invalid) { s.update(a, { parent: far }, by: "l") }.message)
    assert_match(/cannot be its own parent/, assert_raises(Invalid) { s.update(a, { parent: a }, by: "l") }.message)
    assert_match(/a cycle/, assert_raises(Invalid) { s.update(a, { parent: b }, by: "l") }.message)
    assert_match(/no card 999/, assert_raises(Invalid) { s.update(a, { parent: 999 }, by: "l") }.message)
    assert_match(/must be a card id/, assert_raises(Invalid) { s.update(a, { parent: "x" }, by: "l") }.message)
    s.archive(a, by: "l")
    assert_match(/is archived/, assert_raises(Invalid) { s.create(slug: "p", title: "c", by: "l", parent: a) }.message)
    assert_equal [a], s.card(b)[:blocked_by], "an archived parent never finishes"
    s.update(b, { parent: nil }, by: "l")
    assert_equal [nil, []], s.card(b).values_at(:parent_id, :blocked_by)
    assert_match(/parent: —/, s.activity(b).last[:body])
    assert_match(/must be a JSON object/, assert_raises(Invalid) { s.update(b, { metadata: [1] }, by: "l") }.message)
    assert_match(/longer than/, assert_raises(Invalid) { s.update(b, { metadata: { "x" => "y" * 9000 } }, by: "l") }.message)
    s.update(b, { metadata: { "k" => [1, { "n" => nil }] } }, by: "l")
    assert_equal({ "k" => [1, { "n" => nil }] }, s.card(b)[:metadata])
    assert_equal "metadata edited", s.activity(b).last[:body]
    s.update(b, { metadata: nil }, by: "l")
    assert_nil s.card(b)[:metadata]
  end

  def test_coding_board_without_dependencies_ignores_parents_for_rules
    a = kb.create(slug: "g/r", title: "a", by: "op")
    b = kb.create(slug: "g/r", title: "b", by: "op", parent: a)
    assert_equal [a, []], kb.card(b).values_at(:parent_id, :blocked_by)
    assert_equal "doing", kb.move(b, column: "doing", by: "op")[:column]
    kb.move(a, column: "merged", by: "op")
    assert_equal "doing", kb.card(b)[:column], "no promote rule"
  end

  # ── agent sessions: registration adopts, the registry reconciles, the caps refuse ─────────────────────────────

  # THE INTAKE RULE: a card landing ownerless in a column a running session's type takes is assigned to it at once
  # (the operator's move into To do), and a card already waiting there is picked up by the next sweep.
  def test_a_card_moved_into_a_taken_column_is_assigned_to_the_running_session_and_the_session_is_pinged
    waiting = kb.create(slug: "g/r", title: "waiting", by: "op", column: "todo")
    assert_nil kb.card(waiting)[:owner_session], "no session registered: stays ownerless"
    assert_empty kb.adopt_ownerless(live: Set["tl_g_r"])
    # adopts `waiting` at registration
    kb.register_session(session: "tl_g_r", project: "g/r", type: "lead", launcher: "fullclaude", by: "op")
    assert_equal "tl_g_r", kb.card(waiting)[:owner_session]
    id = kb.create(slug: "g/r", title: "parked", by: "op", column: "backlog")
    assert_nil kb.card(id)[:owner_session], "Backlog is parked"
    kb.move(id, column: "todo", by: "operator@example.com")
    c = kb.card(id)
    assert_equal %w[claude-tl_g_r tl_g_r todo], c.values_at(:assignee, :owner_session, :column)
    assert_match(/assigned to claude-tl_g_r — session tl_g_r \(lead\) takes To do cards/,
                 kb.activity(id).map { |a| a[:body] }.join("\n"))
    assert_includes kb.pings(id).map { |p| p[:reason] }, "assigned"
    assert_empty kb.adopt_ownerless(live: Set["tl_g_r"]), "an owned card is never re-assigned"
  end

  # The operator sets the owner session by hand, no assignee — the sweep fills it. And a card
  # whose owner is dead is handed to a live session on the next pass (the host's start included), not left waiting.
  def test_the_sweep_fills_a_missing_assignee_and_hands_a_dead_owners_card_to_a_live_session
    kb.register_session(session: "tl_g_r", project: "g/r", type: "lead", launcher: "fullclaude", by: "op")
    hand = kb.create(slug: "g/r", title: "owner by hand", by: "op", column: "todo")
    kb.set_owner(hand, session: "tl_g_r", by: "op")
    assert_equal [nil, "tl_g_r"], kb.card(hand).values_at(:assignee, :owner_session)
    dead = kb.create(slug: "g/r", title: "dead owner", by: "op", column: "human_check")
    kb.update(dead, { "assignee" => "claude-old" }, by: "op")
    kb.set_owner(dead, session: "old", by: "op")
    assert_equal [hand], kb.adopt_ownerless, "without a live list only the missing assignee is fixed"
    assert_equal %w[claude-tl_g_r tl_g_r], kb.card(hand).values_at(:assignee, :owner_session)
    assert_match(/assignee filled from its owner session tl_g_r/, kb.activity(hand).last[:body])
    assert_equal [dead], kb.adopt_ownerless(live: Set["tl_g_r"], grace: 60)
    assert_equal %w[claude-tl_g_r tl_g_r], kb.card(dead).values_at(:assignee, :owner_session)
    assert_match(/owner session old is not alive — handed to session tl_g_r/, kb.activity(dead).map { |a| a[:body] }.join("\n"))
    assert_includes kb.pings(dead).map { |p| p[:reason] }, "assigned"
    assert_empty kb.adopt_ownerless(live: Set["tl_g_r"], grace: 60), "settled: nothing changes twice"
  end

  def test_the_sweep_assigns_a_card_a_session_released_and_skips_sessions_not_live
    kb.register_session(session: "tl_g_r", project: "g/r", type: "lead", launcher: "fullclaude", by: "op")
    id = kb.create(slug: "g/r", title: "x", by: "op", column: "todo") # created directly in To do: no move event
    assert_equal [], kb.adopt_ownerless(live: Set[]), "a session not in the host list takes nothing"
    assert_equal [id], kb.adopt_ownerless(live: Set["tl_g_r"])
    assert_equal "tl_g_r", kb.card(id)[:owner_session]
  end

  def test_register_adopts_the_projects_ownerless_cards_of_the_types_columns_and_relays
    a = kb.create(slug: "g/r", title: "A", by: "op", column: "doing")
    b = kb.create(slug: "g/r", title: "B", by: "op", column: "ready")
    kb.create(slug: "g/r", title: "C", by: "op", column: "backlog")        # parked: not a lead's column
    other = kb.create(slug: "p", title: "P", by: "op", column: "doing")     # another board
    owned = kb.create(slug: "g/r", title: "O", by: "op", column: "doing")
    kb.set_owner(owned, session: "lead_1", by: "op")
    kb.comment(a, body: "please look", author: "operator@example.com", operator: true)
    r = kb.register_session(session: "tl_g_r", project: "g/r", type: "lead", launcher: "fullclaude", by: "operator@example.com")
    assert_equal ["tl_g_r", "default", "lead", "fullclaude", "claude-tl_g_r", "g/r", [a, b]],
                 r.values_at(:session, :socket, :type, :launcher, :agent, :project, :adopted)
    assert_equal %w[claude-tl_g_r tl_g_r], kb.card(a).values_at(:assignee, :owner_session)
    assert_equal %w[claude-tl_g_r tl_g_r], kb.card(b).values_at(:assignee, :owner_session)
    assert_equal [nil, nil], kb.card(other).values_at(:assignee, :owner_session)
    assert_equal "lead_1", kb.card(owned)[:owner_session], "an owned card is never taken"
    assert_match(/adopted by claude-tl_g_r — session tl_g_r \(lead\) registered for g\/r/, kb.activity(a).last[:body])
    assert_equal "relay", kb.pings(a).first[:reason], "the operator's unheard comment is relayed to the adopter"
    assert_empty kb.pings(b)
    # a type that takes nothing adopts nothing; a plain session's name is still the board's
    s = kb.register_session(session: "lead_1", project: "g/r", type: "plain", by: "op", launcher: "localclaude")
    assert_equal [[], "localclaude", "claude-lead_1"], s.values_at(:adopted, :launcher, :agent)
    assert_equal "tl_g_r", kb.session_for_author("claude-tl_g_r")[:session]
    assert_equal "tl_g_r", kb.session_for_author("tl_g_r")[:session]
    assert_nil kb.session_for_author("nobody")
    # refusals: unknown type / launcher, a second registration, a board that does not own the session
    assert_raises(AgentsKanban::Invalid) { kb.register_session(session: "x", project: "g/r", type: "boss", by: "op") }
    assert_raises(AgentsKanban::Invalid) { kb.register_session(session: "x", project: "g/r", type: "team", launcher: "nope", by: "op") }
    e = assert_raises(AgentsKanban::Denied) { kb.register_session(session: "tl_g_r", project: "p", type: "plain", launcher: "fullclaude", by: "op") }
    assert_match(/already registered as lead for g\/r/, e.message)
    assert_raises(AgentsKanban::Invalid) { kb.register_session(session: "x", project: "nope", type: "lead", launcher: "fullclaude", by: "op") }
    content = store(KanbanTest.config("content"))
    e = assert_raises(AgentsKanban::Invalid) do
      content.register_session(session: "coding_lead", project: "p", type: "worker", by: "op")
    end
    assert_match(/not one of this board's sessions/, e.message)
    # a card created with the registered agent's session is owned from its first second
    id = kb.create(slug: "g/r", title: "D", by: "claude-tl_g_r", owner_session: "tl_g_r")
    assert_equal %w[claude-tl_g_r tl_g_r], kb.card(id).values_at(:assignee, :owner_session)
    assert_equal "created in Backlog · owner session: tl_g_r (claude-tl_g_r)", kb.activity(id).first[:body]
  end

  # a session registered for g/r creating a card on p's board does not own it, and cannot claim it
  def test_a_session_owns_cards_only_on_the_board_it_is_registered_for
    kb.register_session(session: "tl_g_r", project: "g/r", type: "lead", launcher: "fullclaude", by: "op")
    id = kb.create(slug: "p", title: "for p", by: "claude-tl_g_r", owner_session: "tl_g_r", column: "todo", agent: true)
    c = kb.card(id)
    assert_equal [nil, nil, "claude-tl_g_r"], c.values_at(:owner_session, :assignee, :created_by)
    assert_equal "created in To do · not owned: tl_g_r is registered for g/r, not p", kb.activity(id).first[:body]
    e = assert_raises(AgentsKanban::Denied) { kb.claim(id, assignee: "claude-tl_g_r", session: "tl_g_r") }
    assert_match(/registered for g\/r: it cannot own a card on p's board/, e.message)
    assert_equal [nil, nil], kb.card(id).values_at(:owner_session, :assignee), "a refused claim changes nothing"
    # its own board: owned as before; an unregistered session (started by hand) cannot be checked → owned
    own = kb.create(slug: "g/r", title: "mine", by: "claude-tl_g_r", owner_session: "tl_g_r", agent: true)
    assert_equal "tl_g_r", kb.card(own)[:owner_session]
    kb.claim(id, assignee: "hand", session: "hand_1")
    assert_equal "hand_1", kb.card(id)[:owner_session]
  end

  def test_sessions_sync_ends_gone_sessions_after_the_grace_and_the_caps_refuse_with_who_runs
    kb.register_session(session: "s1", project: "g/r", type: "lead", launcher: "fullclaude", by: "op")
    @now += 10
    kb.register_session(session: "s2", project: "p", type: "team", launcher: "fullclaude", by: "op")
    # s2 is not live yet but was registered 0 s ago: starting, counts as running; s1 live
    assert_equal [], kb.sessions_sync(%w[s1].to_set, grace: 60)
    c = kb.concurrency(%w[s1].to_set, grace: 60)
    assert_equal [6, 2, 4], c.values_at(:max_sessions, :running, :free)
    assert_equal [["s1", true, 0], ["s2", false, 0]], c[:sessions].map { |x| x.values_at(:session, :live, :cards) }
    assert_equal({ running: 1, max: nil, max_per_project: 1 }, c[:types]["lead"])
    assert_equal({ running: 1, max: 2, max_per_project: nil }, c[:types]["team"])
    # per-project cap: a second lead for g/r; type cap: a third team; the global cap
    e = assert_raises(AgentsKanban::Denied) { kb.launch_check!(type: "lead", project: "g/r", live: %w[s1].to_set, grace: 60) }
    assert_equal "1/1 lead session already runs for g/r (agent_types[lead].max_per_project): s1 (lead, g/r)", e.message
    assert_equal 2, kb.launch_check!(type: "lead", project: "p", live: %w[s1].to_set, grace: 60)[:running],
                 "a lead for another project may start"
    kb.register_session(session: "s3", project: "g/r", type: "team", launcher: "fullclaude", by: "op")
    e = assert_raises(AgentsKanban::Denied) { kb.launch_check!(type: "team", project: "o/other", live: %w[s1 s2 s3].to_set, grace: 60) }
    assert_match(
      %r{2/2 team sessions are running — this type's cap \(agent_types\[team\].max\): s2 \(team, p\), s3 \(team, g/r\)},
      e.message,
    )
    %w[s4 s5 s6].each do |x|
      kb.register_session(session: x, project: "o/other", type: "plain", launcher: "fullclaude", by: "op")
    end
    e = assert_raises(AgentsKanban::Denied) { kb.launch_check!(type: "plain", project: "p", live: %w[s1 s2 s3 s4 s5 s6].to_set, grace: 60) }
    assert_match(%r{\A6/6 agent sessions are running — the host's cap \(concurrency.max_sessions\): s1 \(lead, g/r\), s2},
                 e.message)
    # no host cap: the same sixth launch is allowed, free is unknown
    nocap_raw = JSON.parse(File.read(File.join(KanbanTest::ROOT, "fixtures/boards/coding.json")))
                    .merge("table_prefix" => KanbanTest::PREFIX)
                    .tap { |r| r["concurrency"]["max_sessions"] = 0 }
    nocap = AgentsKanban::HostConfig.new(nocap_raw)
    live = %w[s1 s2 s3 s4 s5 s6].to_set
    open_kb = store(nocap)
    assert_equal [nil, 6, nil], open_kb.concurrency(live, grace: 60).values_at(:max_sessions, :running, :free)
    assert_equal 6, open_kb.launch_check!(type: "plain", project: "p", live: live, grace: 60)[:running]
    # the grace passes: s2 was never seen → ended as gone; the others live
    @now += 61
    assert_equal ["s2"], kb.sessions_sync(%w[s1 s3 s4 s5 s6].to_set, grace: 60)
    assert_equal "gone from the host's session list", kb.sessions_t.where(session: "s2").first[:end_reason]
    assert_equal 5, kb.concurrency(%w[s1 s3 s4 s5 s6].to_set, grace: 60)[:running]
    kb.launch_check!(type: "plain", project: "p", live: %w[s1 s3 s4 s5 s6].to_set, grace: 60)
    # end_session by hand; a second end is refused; a released launch gives the adopted cards back
    kb.end_session("s6", reason: "operator closed it", by: "op")
    assert_raises(AgentsKanban::Invalid) { kb.end_session("s6", reason: "again", by: "op") }
    a = kb.create(slug: "g/r", title: "A", by: "op", column: "doing")
    kb.set_owner(a, session: "s1", by: "op")
    kb.comment(a, body: "x", author: "op", operator: true)
    kb.release_session_cards("s1", reason: "its launch failed: tmux failed", by: "op")
    assert_equal [nil, nil], kb.card(a).values_at(:owner_session, :assignee)
    assert_equal ["failed", "its launch failed: tmux failed"], kb.pings(a).first.values_at(:status, :error)
    # the watchdog ends the registration of a session whose cards it releases
    kb.set_owner(a, session: "s3", by: "op")
    kb.watch_owners([].to_set, grace: 60)
    @now += 61
    assert_equal [a], kb.watch_owners([].to_set, grace: 60)
    assert_equal "gone (watchdog)", kb.sessions_t.where(session: "s3").first[:end_reason]
  end

  def test_an_open_dialog_question_expires_when_the_dialog_is_no_longer_on_the_screen
    d = AgentsKanban::SessionDialog.parse("Do you want to proceed?\n❯ 1. Yes\n  2. No\nEsc to cancel\n")
    id = owned_card
    kb.dialog_question(session: "acme_shop", dialog: d)
    assert_equal ["doing", true], [kb.card(id)[:column], kb.card_json(kb.card(id))[:needs_operator]], "flagged in place"
    still = ->(*) { { "ok" => true, "dialog" => JSON.parse(JSON.generate(d)) } }
    assert_equal [], kb.expire_dialogs(check: still), "the same dialog is still there"
    unreadable = ->(*) { { "ok" => false, "error" => "capture failed" } }
    assert_equal [], kb.expire_dialogs(check: unreadable), "an unreadable screen is not a verdict"
    clear = ->(*) { { "ok" => true, "dialog" => nil } }
    assert_equal [id], kb.expire_dialogs(check: clear)
    c = kb.card(id)
    assert_equal ["doing", nil, nil, nil], c.values_at(:column, :dialog_id, :dialog, :question)
    assert_match(/expired: the dialog is no longer on its screen/, kb.dialogs_t.first[:answer])
    expired = "session dialog expired: the dialog is no longer on its screen (answered in the session)"
    assert_equal ["answer", "busyyaks", expired], kb.activity(id).last.values_at(:kind, :author, :body)
    assert_equal [], kb.expire_dialogs(check: clear), "closed once"
    # gone session → expired too; scoped to one session (the same dialog is re-posted only after DIALOG_REASK)
    @now += AgentsKanban::Store::DIALOG_REASK + 1
    kb.dialog_question(session: "acme_shop", dialog: d)
    assert_equal [], kb.expire_dialogs(check: ->(*) { { "ok" => false, "gone" => true } }, session: "other")
    assert_equal [id], kb.expire_dialogs(check: ->(*) { { "ok" => false, "gone" => true } }, session: "acme_shop")
    assert_match(/session acme_shop is gone/, kb.dialogs_t.order(:id).last[:answer])
  end
end
