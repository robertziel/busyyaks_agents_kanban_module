# frozen_string_literal: true

require "test_helper"

# The MCP tools as an agent calls them (through Tools#call, the host's MCP server only routes to it).
class ToolsTest < Minitest::Test
  include KanbanTest::Setup

  def setup
    super
    @root = Dir.mktmpdir("tools-att")
    @repo = Dir.mktmpdir("tools-repo")
    @live = %w[tl_g_r lead_1]
    @projects = {
      "g/r" => { slug: "g/r", path: @repo, remote: nil },
      "p" => { slug: "p", path: "/nonexistent", remote: nil },
    }
    policy = AgentsKanban::AttachmentPolicy.new(max_bytes: 1000, types: "image/png,text/plain")
    @att = AgentsKanban::Attachments.new(kb, root: @root, policy: policy, clock: -> { @now })
    sessions = lambda do
      @live == :down ? raise(AgentsKanban::Delivery::Unavailable, "launcher not reachable at /x.sock") : @live
    end
    @tools = AgentsKanban::Tools.new(store: kb, attachments: @att, projects: ->(s) { @projects[s] }, sessions: sessions,
                                     card_url: CARD_URL)
  end

  def teardown
    FileUtils.rm_rf([@root, @repo])
    super
  end

  def ok(name, args = {}) = JSON.parse(@tools.call(name, JSON.parse(JSON.generate(args))))
  def err(name, args = {}) = assert_raises(AgentsKanban::Invalid) { @tools.call(name, JSON.parse(JSON.generate(args))) }.message

  def test_definitions_are_worded_for_this_board
    defs = @tools.definitions
    names = defs.map { |t| t[:name] }
    assert_equal AgentsKanban::Tools::NAMES.sort, names.sort
    assert_equal names.uniq.size, names.size
    move = defs.find { |t| t[:name] == "kanban_move" }
    assert_match(/gate \(Human Check \/ Ready to merge\) only through kanban_handoff/, move[:description])
    assert_match(/Ready to merge \(ready\)/, move[:description])
    assert_match(/flagged needs_operator \(kanban_ask\) or blocked_external \(kanban_block\)/, move[:description])
    # worded from the template; no enum: a project's board may differ
    assert_match(/backlog=Backlog, todo=To do/, move[:inputSchema][:properties][:column][:description])
    refute defs.find { |t| t[:name] == "kanban_update" }[:inputSchema][:properties].key?(:assignee)
    claim = defs.find { |t| t[:name] == "kanban_claim" }
    assert_includes claim[:inputSchema][:required], "tmux_session"
    assert_match(/subagent/, claim[:description])
    handoff = defs.find { |t| t[:name] == "kanban_handoff" }
    assert_equal %w[id qa ui_change author pr_url ci_url], handoff[:inputSchema][:required]
    assert_includes handoff[:inputSchema][:properties].keys, :transition
    assert_match(/round limit \(3\).*review_summary.*label "unresolved" only when needs_human \+ open/, handoff[:description])
    assert_equal %w[fixed resolved_by_argument needs_human open],
                 handoff[:inputSchema][:properties][:review_summary][:required]
    ask = defs.find { |t| t[:name] == "kanban_ask" }
    assert_match(/FLAGGED needs_operator and keeps its column/, ask[:description])
    assert_match(/After 24 h unanswered/, ask[:description])
    block = defs.find { |t| t[:name] == "kanban_block" }
    assert_equal %w[id reason url author], block[:inputSchema][:required]
    refute(names.any? { |n| n.match?(/dialog|answer|press/) }, "agents have no tool to answer a dialog")

    content = AgentsKanban::Tools.new(store: store(KanbanTest.config("content")), attachments: @att,
                                      projects: ->(s) { @projects[s] }, sessions: -> { [] }, card_url: CARD_URL)
    cn = content.definitions.map { |t| t[:name] }
    refute_includes cn, "kanban_handoff"
    assert_includes cn, "kanban_ask"
    assert_includes cn, "kanban_block"
    refute_match(/round limit/, content.definitions.find { |t| t[:name] == "kanban_ask" }[:description])
    cmove = content.definitions.find { |t| t[:name] == "kanban_move" }
    assert_match(/Only the operator moves a card out of Done/, cmove[:description])
    cid = content.store.create(slug: "p", title: "x", by: "op")
    handoff_args = { "id" => cid, "qa" => "x", "ui_change" => false, "author" => "a" }
    e = assert_raises(AgentsKanban::Invalid) { content.call("kanban_handoff", handoff_args) }
    assert_match(/no handoff gate \(no gate column\)/, e.message)
  end

  def test_agent_works_a_card_end_to_end
    ok("kanban_label_save", project: "g/r", name: "auth", color: "red", author: "agent-a")
    c = ok("kanban_create", project: "g/r", title: "Fix login", author: "agent-a", tmux_session: "tl_g_r", labels: ["auth"],
                            priority: "high", description: "**why**", metadata: { "draft_id" => 7 })
    assert_equal ["backlog", "Backlog", 0, ["auth"], { "draft_id" => 7 }],
                 c.values_at("column", "column_label", "position", "labels", "metadata")
    assert_equal %w[agent-a tl_g_r], c.values_at("assignee", "owner_session"),
                 "an agent-made card is owned by its session from the start"
    ok("kanban_create", project: "g/r", title: "Other", author: "agent-a", tmux_session: "tl_g_r", column: "todo")
    assert_equal "tl_g_r", ok("kanban_claim", id: c["id"], assignee: "tl_g_r", tmux_session: "tl_g_r")["assignee"]
    moved = ok("kanban_move", id: c["id"], column: "todo", position: 0, author: "tl_g_r")
    assert_equal ["todo", 0], moved.values_at("column", "position")
    ok("kanban_move", id: c["id"], column: "doing", author: "tl_g_r")
    ok("kanban_update", id: c["id"], author: "tl_g_r", title: "Fix login flow", priority: "")
    comment = ok("kanban_comment", id: c["id"], body: "PR ready", author: "tl_g_r")
    assert_equal "none: tl_g_r is the card's owner", comment["delivered"]
    assert_includes err("kanban_move", id: c["id"], column: "human_check", author: "tl_g_r"), "kanban_handoff"
    ok("kanban_handoff", id: c["id"], qa: "Open /x at 375 px and 1280 px; 4 buttons in one row",
                         pr_url: "https://github.com/o/r/pull/7", ci_url: "https://ci.example.com/job/r/7/",
                         ui_change: false, author: "tl_g_r")
    board = ok("kanban_board", project: "g/r")
    assert_equal %w[backlog todo doing qa human_check ready merged], board["columns"].map { |col| col["column"] }
    assert_equal ["Fix login flow"], board["columns"][4]["cards"].map { |x| x["title"] }
    assert_nil board["backlog_md"]
    assert_equal config.to_h, board["config"]
    assert_equal ["Other"], ok("kanban_board", project: "g/r", column: "todo")["columns"][0]["cards"].map { |x| x["title"] }
    card = ok("kanban_card", id: c["id"])
    assert_equal "**why**", card["card"]["description"]
    refute card["card"].key?("description_html")
    assert_includes card["activity"].map { |a| [a["kind"], a["author"]] }, %w[comment tl_g_r]
    assert_includes card["activity"].map { |a| a["body"] }, "In progress → Human Check"
    assert_equal [], card["card"]["attachments"]
  end

  def test_agents_cannot_merge_or_leave_human_check_and_bad_input_is_an_error
    msg = err("kanban_create", project: "g/r", title: "x", author: "a", tmux_session: "tl_g_r", column: "human_check")
    assert_match(/agents cannot create cards in Human Check: create it, do the work, then kanban_handoff/, msg)
    msg = err("kanban_create", project: "g/r", title: "x", author: "a", tmux_session: "tl_g_r", column: "ready")
    assert_match(/agents cannot create cards in Ready to merge: create it, do the work, then kanban_handoff/, msg)
    c = ok("kanban_create", project: "g/r", title: "x", author: "a", tmux_session: "tl_g_r")
    kb.move(c["id"], column: "human_check", by: "op")
    msg = err("kanban_move", id: c["id"], column: "merged", author: "a")
    assert_match(/only the operator moves a card out of Human Check/, msg)
    msg = err("kanban_create", project: "g/r", title: "y", author: "a", tmux_session: "tl_g_r", column: "merged")
    assert_match(/agents cannot create cards in Merged/, msg)
    assert_match(/no project/, err("kanban_board", project: "nope"))
    assert_match(/no card/, err("kanban_card", id: 999_999))
    msg = err("kanban_create", project: "g/r", title: "t", author: "a", tmux_session: "tl_g_r", column: "done")
    assert_match(/column must be one of/, msg)
    assert_match(/author is required/, err("kanban_move", id: 1, column: "todo"))
    assert_match(/unknown tool/, err("kanban_nope", {}))
  end

  def test_claim_requires_a_live_session_and_update_refuses_an_assignee
    c = ok("kanban_create", project: "g/r", title: "T", author: "claude-shop-lead", tmux_session: "tl_g_r")
    kb.set_owner(c["id"], session: "", by: "test") # ownerless and unassigned, for the claim rules below
    kb.update(c["id"], { "assignee" => "" }, by: "test")
    msg = err("kanban_update", id: c["id"], author: "claude-shop-lead", assignee: "claude-shop-lead")
    assert_match(/use kanban_claim\(id, assignee, tmux_session\)/, msg)
    assert_match(/use kanban_claim/, err("kanban_create", project: "g/r", title: "U", author: "a", assignee: "a"))
    assert_match(/tmux_session is required/, err("kanban_claim", id: c["id"], assignee: "lead"))
    msg = err("kanban_claim", id: c["id"], assignee: "lead", tmux_session: "ghost")
    assert_match(/no tmux session "ghost" is running.*live: tl_g_r, lead_1/, msg)
    @live = :down
    msg = err("kanban_claim", id: c["id"], assignee: "lead", tmux_session: "lead_1")
    assert_match(/cannot verify tmux sessions: launcher not reachable/, msg)
    assert_equal [nil, nil], kb.card(c["id"]).values_at(:assignee, :owner_session), "a refused claim changes nothing"
    @live = %w[lead_1]
    got = ok("kanban_claim", id: c["id"], assignee: "claude-shop-lead", tmux_session: "lead_1")
    assert_equal %w[claude-shop-lead lead_1], got.values_at("assignee", "owner_session")
    # a board that names its sessions (content: news_articles, news-articles-*) refuses a LIVE session of another host
    content = AgentsKanban::Tools.new(store: store(KanbanTest.config("content")), attachments: @att,
                                      projects: ->(s) { @projects[s] }, sessions: -> {
 %w[coding_lead news_articles news-articles-4] }, card_url: CARD_URL)
    cc = JSON.parse(content.call("kanban_create", "project" => "p", "title" => "article: japan", "author" => "lead",
                                                  "tmux_session" => "news-articles-4", "column" => "queued"))
    e = assert_raises(AgentsKanban::Invalid) do
      content.call("kanban_claim", "id" => cc["id"], "assignee" => "news-writer", "tmux_session" => "coding_lead")
    end
    assert_match(/session "coding_lead" is not one of this board's sessions \(news_articles, news-articles-\*\)/, e.message)
    content.store.set_owner(cc["id"], session: "", by: "test")
    e = assert_raises(AgentsKanban::Invalid) do
      content.call("kanban_claim", "id" => cc["id"], "assignee" => "news-writer", "tmux_session" => "coding_lead")
    end
    assert_match(/not one of this board/, e.message)
    claimed = content.call("kanban_claim", "id" => cc["id"], "assignee" => "news-writer", "tmux_session" => "news-articles-4")
    assert_equal "news-articles-4", JSON.parse(claimed)["owner_session"]
  end

  def test_ask_flags_the_card_with_a_question_and_block_flags_a_blocker
    c = ok("kanban_create", project: "g/r", title: "Security triage", author: "lead", tmux_session: "tl_g_r", column: "doing")
    kb.set_owner(c["id"], session: "", by: "test")
    assert_match(/no owner session.*kanban_claim/, err("kanban_ask", id: c["id"], question: "Which first?", author: "lead"))
    ok("kanban_claim", id: c["id"], assignee: "lead", tmux_session: "lead_1")
    assert_match(/array of strings/, err("kanban_ask", id: c["id"], question: "Q", options: "A,B", author: "lead"))
    asked = ok("kanban_ask", id: c["id"], question: "Fix **auth** or **imgproc** first?",
                             options: ["Auth first", "Imgproc first"], author: "shop-sec-imgproc")
    assert_equal ["doing", ["Auth first", "Imgproc first"], "shop-sec-imgproc", true],
                 asked.values_at("column", "question_options", "asked_by", "needs_operator")
    doing = ok("kanban_board", project: "g/r")["columns"].find { |col| col["column"] == "doing" }
    assert_equal [[c["id"], true]], doing["cards"].map { |x| x.values_at("id", "needs_operator") }
    q = ok("kanban_card", id: c["id"])["activity"].reverse.find { |a| a["kind"] == "comment" }
    question = "**Question for the operator:**\n\nFix **auth** or **imgproc** first?\n\n" \
               "**Options:** `Auth first` · `Imgproc first`"
    assert_equal question, q["body"]
    assert_match(/waits for the operator's answer/, err("kanban_move", id: c["id"], column: "qa", author: "lead"))
    kb.comment(c["id"], body: "auth", author: "op", operator: true)
    moved = ok("kanban_move", id: c["id"], column: "qa", author: "lead")
    assert_equal "qa", moved["column"], "answered: the agent moves on"
    assert_match(/reason is required/, err("kanban_block", id: c["id"], url: "https://ci/1", author: "lead"))
    blocked = ok("kanban_block", id: c["id"], reason: "CI queue is stuck", url: "https://ci.example.com/queue", author: "lead")
    assert_equal ["qa", "CI queue is stuck", "https://ci.example.com/queue", "lead"],
                 [blocked["column"], *blocked["blocked"].values_at("reason", "url", "by")]
    assert_match(/blocked \(external\)/, err("kanban_move", id: c["id"], column: "doing", author: "lead"))
    assert_nil ok("kanban_unblock", id: c["id"], note: "queue drained", author: "lead")["blocked"]
    assert_match(/not blocked/, err("kanban_unblock", id: c["id"], author: "lead"))
  end

  def test_labels_due_checklists_and_markdown_only
    assert_equal [], ok("kanban_labels", project: "g/r")
    assert_match(/color is required/, err("kanban_label_save", project: "g/r", name: "bug", author: "a"))
    ok("kanban_label_save", project: "g/r", name: "bug", color: "red", author: "a")
    l = ok("kanban_label_save", project: "g/r", name: "bug", color: "orange", new_name: "defect", author: "a")
    assert_equal [%w[defect orange]], l.map { |x| [x["name"], x["color"]] }
    ok("kanban_label_save", project: "g/r", name: "ui", color: "blue", author: "a")
    c = ok("kanban_create", project: "g/r", title: "T", author: "a", tmux_session: "tl_g_r", labels: ["defect"],
                            due: "2026-11-09T12:00Z")
    refute_nil c["due"]
    assert_match(/unknown label nope/, err("kanban_labels_set", id: c["id"], labels: ["nope"], author: "a"))
    assert_equal %w[defect ui], ok("kanban_labels_set", id: c["id"], labels: %w[defect ui], author: "a")["labels"]
    d = ok("kanban_due_set", id: c["id"], due: "2026-11-10T08:00+02:00", done: true, author: "a")
    assert_equal [true, "2026-11-10T06:00:00+00:00"], [d["due_done"], Time.parse(d["due"]).utc.iso8601.sub("Z", "+00:00")]
    assert_nil ok("kanban_due_set", id: c["id"], due: "", author: "a")["due"]
    assert_equal "teal", ok("kanban_update", id: c["id"], cover: "teal", author: "a")["cover"]
    assert_equal %w[ui], ok("kanban_label_delete", project: "g/r", name: "defect", author: "a").map { |x| x["name"] }
    cl = ok("kanban_checklist_add", id: c["id"], title: "Steps", items: ["one", "two `x`"], author: "a")
    assert_equal [0, 2], cl.values_at("checklist_done", "checklist_total")
    list = cl["checklists"][0]
    refute list["items"][0].key?("body_html")
    ok("kanban_checklist_item_add", checklist_id: list["id"], body: "three", author: "a")
    t = ok("kanban_checklist_toggle", item_id: list["items"][0]["id"], done: true, author: "a")
    assert_equal [1, 3, "a"], [t["checklist_done"], t["checklist_total"], t["checklists"][0]["items"][0]["done_by"]]
    msg = err("kanban_checklist_toggle", item_id: list["items"][0]["id"], done: "yes", author: "a")
    assert_match(/done must be true or false/, msg)
    ok("kanban_checklist_item_edit", item_id: list["items"][1]["id"], body: "two **bold**", author: "a")
    ok("kanban_checklist_rename", checklist_id: list["id"], title: "Steps 2", author: "a")
    n = ok("kanban_checklist_item_convert", item_id: list["items"][1]["id"], author: "a")
    assert_equal ["two **bold**", "backlog"], n.values_at("title", "column")
    assert_equal 1, ok("kanban_checklist_item_delete", item_id: list["items"][0]["id"], author: "a")["checklist_total"]
    card = ok("kanban_card", id: c["id"])
    assert_equal "Steps 2", card["card"]["checklists"][0]["title"]
    assert(card["activity"].none? { |e| e.key?("body_html") })
    assert_equal [], ok("kanban_checklist_delete", checklist_id: list["id"], author: "a")["checklists"]
    cid = ok("kanban_comment", id: c["id"], body: "**done**", author: "agent-a")["id"]
    e = ok("kanban_comment_edit", comment_id: cid, body: "edited @op", author: "agent-a")
    assert_equal ["edited @op", false], [e["body"], e.key?("body_html")]
    assert_match(/only agent-a edits/, err("kanban_comment_edit", comment_id: cid, body: "x", author: "agent-b"))
    assert_equal({ "deleted" => cid, "card" => c["id"] }, ok("kanban_comment_delete", comment_id: cid, author: "agent-a"))
  end

  def test_attach_base64_project_path_and_refusals
    card = kb.create(slug: "g/r", title: "T", by: "op")
    kb.set_owner(card, session: "tl_g_r", by: "op")
    r = ok("kanban_attach", id: card, author: "agent-a", filename: "shot.png", content_base64: [PNG].pack("m0"),
                            comment: "the bug:")
    a = r["attachment"]
    assert_equal ["shot.png", "image/png", "agent-a", r["comment_id"]],
                 a.values_at("filename", "content_type", "uploaded_by", "comment_id")
    assert_equal "the bug:\n\n![shot.png](/api/attachments/#{a['id']})", kb.comment!(r["comment_id"])[:body]
    ping = kb.pending_pings.find { |p| p[:card_id] == card }
    assert_includes ping[:text], "/api/attachments/#{a['id']}"
    assert_equal [a["id"]], ok("kanban_attachments", id: card).map { |x| x["id"] }
    g = ok("kanban_attachment_get", attachment_id: a["id"])
    assert_equal ["/api/attachments/#{a['id']}", nil], [g["url"], g["text"]]
    File.write(File.join(@repo, "build.log"), "step 1 ok\nstep 2 FAIL\n")
    b = ok("kanban_attach", id: card, author: "agent-a", filename: "build.log", project_path: "build.log")["attachment"]
    got = ok("kanban_attachment_get", attachment_id: b["id"])
    assert_equal ["step 1 ok\nstep 2 FAIL\n", false], got.values_at("text", "truncated")
    assert_match "is outside g/r", err("kanban_attach", id: card, author: "a", filename: "p.txt", project_path: "/etc/passwd")
    assert_match "exactly one of", err("kanban_attach", id: card, author: "a", filename: "a.txt")
    msg = err("kanban_attach", id: card, author: "a", filename: "a.png", content_base64: ["hello"].pack("m0"))
    assert_match "the name says image/png", msg
    too_large = { "id" => card, "author" => "a", "filename" => "a.txt", "content_base64" => ["x" * 1001].pack("m0") }
    assert_raises(AgentsKanban::AttachmentPolicy::TooLarge) { @tools.call("kanban_attach", too_large) }
    assert_equal 2, ok("kanban_card", id: card)["card"]["attachments"].size
  end

  def test_board_json_carries_backlog_md_when_the_host_reads_one
    FileUtils.mkdir_p(File.join(@repo, "backlog/tasks"))
    File.write(File.join(@repo, "backlog/tasks/task-7 - Y.md"), "---\nid: TASK-7\ntitle: Y\nstatus: Done\n---\n")
    File.write(File.join(@repo, "backlog/tasks/task-8 - Z.md"), "---\nid: TASK-8\ntitle: Z\nstatus: Review\n---\n")
    # Backlog.md statuses → column TYPES (the board's column of that type)
    map = { "done" => "done", "to do" => "queued", "review" => "review" }
    tools = AgentsKanban::Tools.new(store: kb, attachments: @att, projects: ->(s) { @projects[s] }, sessions: -> { [] },
                                    card_url: CARD_URL, backlog: ->(p, b) {
 AgentsKanban::BacklogMd.read(p[:path], board: b, status_map: map) })
    j = JSON.parse(tools.call("kanban_board", { "project" => "g/r" }))
    assert_equal [%w[TASK-7 merged], %w[TASK-8 qa]], j["backlog_md"]["tasks"].map { |t| t.values_at("id", "column") }.sort
    assert_nil JSON.parse(tools.call("kanban_board", { "project" => "p" }))["backlog_md"]
    assert_raises(AgentsKanban::ConfigError) { AgentsKanban::BacklogMd.read(@repo, board: kb.board_of("g/r"), status_map: { "x" => "nope" }) }
    # the operator removes the review column: the board still READS; the task whose status has no column is an error,
    # never guessed
    shape = KanbanTest.board_hash("coding")
    transitions = [
      { "name" => "Move", "from" => "*", "to" => "*", "by" => "any" },
      { "name" => "Approve", "from" => "human_check", "to" => "ready", "by" => "operator" },
    ]
    columns = shape["columns"].reject { |c| c["key"] == "qa" }
    kb.board_save("g/r", shape.merge("columns" => columns, "transitions" => transitions), by: "op")
    j = JSON.parse(tools.call("kanban_board", { "project" => "g/r" }))
    tasks = j["backlog_md"]["tasks"].map { |t| t.values_at("id", "column") }.sort_by { |t| t[0] }
    assert_equal [%w[TASK-7 merged], ["TASK-8", nil]], tasks
    errors = j["backlog_md"]["errors"].join
    assert_match(/status "Review" \(1 task\) maps to type review but this board has no review column/, errors)
  end

  # The session rules: an agent-made card is never ownerless; a session registers itself and adopts; the caps refuse.
  def test_create_is_owned_register_adopts_and_the_cap_refuses
    # no session, no registered author → refused (nothing created)
    msg = err("kanban_create", project: "g/r", title: "orphan", author: "someone")
    assert_match(/owned by its session: pass tmux_session/, msg)
    assert_equal 0, kb.cards.count
    # orphaned work on the board (a reboot released it): doing / human_check cards with no owner
    a = kb.create(slug: "g/r", title: "A", by: "op", column: "doing")
    b = kb.create(slug: "g/r", title: "B", by: "op", column: "human_check")
    kb.create(slug: "g/r", title: "C", by: "op", column: "backlog")
    kb.comment(a, body: "status?", author: "operator@example.com", operator: true)
    # the lead runs two launchers: a session started by hand must say which one it was started with
    msg = err("kanban_register", project: "g/r", type: "lead", tmux_session: "tl_g_r", author: "claude-tl_g_r")
    assert_match(/agent type lead runs fullclaude, localclaude — name the launcher this session was started with/, msg)
    assert_equal 0, kb.sessions_t.count, "nothing registered"
    msg = err("kanban_register", project: "g/r", type: "lead", launcher: "nope", tmux_session: "tl_g_r", author: "x")
    assert_match(/agent type lead does not run launcher "nope" \(fullclaude, localclaude\)/, msg)
    reg = ok("kanban_register", project: "g/r", type: "lead", launcher: "localclaude", tmux_session: "tl_g_r",
                                author: "claude-tl_g_r")
    assert_equal "localclaude", reg["launcher"]
    assert_equal %w[lead claude-tl_g_r tl_g_r], reg.values_at("type", "agent", "session")
    adopted = reg["adopted"].map { |c| c.values_at("id", "column", "column_label") }
    assert_equal [[a, "doing", "In progress"], [b, "human_check", "Human Check"]], adopted
    assert_equal({ "max_sessions" => 6, "running" => 1, "free" => 5 }, reg["concurrency"])
    assert_equal %w[claude-tl_g_r tl_g_r], kb.card(a).values_at(:assignee, :owner_session)
    assert_equal "relay", kb.pings(a).first[:reason], "the operator's unheard comment reaches the new owner"
    # the registered agent name is the author: the card is owned with no tmux_session and no claim
    c = ok("kanban_create", project: "g/r", title: "D", author: "claude-tl_g_r")
    assert_equal %w[claude-tl_g_r tl_g_r], c.values_at("assignee", "owner_session")
    assert_includes ok("kanban_card", id: c["id"])["activity"].first["body"], "owner session: tl_g_r"
    # ask with tmux_session claims and asks in one step
    e = kb.create(slug: "g/r", title: "E", by: "op", column: "doing")
    asked = ok("kanban_ask", id: e, question: "Which?", author: "claude-tl_g_r", tmux_session: "tl_g_r", options: %w[x y])
    assert_equal %w[doing claude-tl_g_r tl_g_r], asked.values_at("column", "assignee", "owner_session")
    # twice is refused; a second lead for the same project is refused by max_per_project
    msg = err("kanban_register", project: "g/r", type: "lead", tmux_session: "tl_g_r", author: "x")
    assert_match(/already registered as lead for g\/r/, msg)
    msg = err("kanban_register", project: "g/r", type: "lead", tmux_session: "lead_1", author: "x")
    assert_match(%r{1/1 lead session already runs for g/r .*tl_g_r \(lead, g/r\)}, msg)
    msg = err("kanban_register", project: "g/r", type: "boss", tmux_session: "lead_1", author: "x")
    assert_match(/no agent type "boss"/, msg)
    msg = err("kanban_register", project: "g/r", type: "plain", tmux_session: "ghost", author: "x")
    assert_match(/no tmux session "ghost"/, msg)
    assert_match(/Your tmux session .* is your identity on the board/, @tools.instructions)
    assert_match(/kanban_ask.*flagged needs_operator/, @tools.instructions)
    assert_match(/the only way into a gate \(Human Check \/ Ready to merge\)/, @tools.instructions)
    assert_match(/Never merge before the operator's approval moves the card to Ready to merge/, @tools.instructions)
  end

  # Every card a tool returns carries its absolute board URL from the host's card_url port, so an agent links a card
  # from data (never by building a URL, never to another source).
  def test_every_card_a_tool_returns_carries_its_url
    id = kb.create(slug: "g/r", title: "Linked", by: "op", column: "todo")
    want = "https://board.example/projects/g/r?card=#{id}"
    assert_equal want, ok("kanban_card", id: id)["card"]["url"]
    board = ok("kanban_board", project: "g/r")
    assert_equal [want], board["columns"].flat_map { |c| c["cards"] }.select { |c| c["id"] == id }.map { |c| c["url"] }
    assert_equal want, ok("kanban_update", id: id, title: "Linked 2", author: "x")["url"]
    kb.archive(id, archived: true, by: "op")
    assert_equal [want], ok("kanban_board", project: "g/r", archived: true)["archived"].map { |c| c["url"] }
    assert_raises(ArgumentError) do
      AgentsKanban::Tools.new(store: kb, attachments: @att, projects: ->(_s) {}, sessions: -> { [] })
    end
  end

  # The links rule, pinned: each reference links to where the thing it names lives, read from data; no `#N` in chat.
  def test_instructions_carry_the_links_rule
    text = @tools.instructions
    assert text.end_with?(AgentsKanban::Tools::LINKS)
    rules = [
      /decide what it IS, then link to where that thing lives, read from data/,
      /never from a default, never one source for everything/,
      /A card → its board card: the card's `url` \(kanban_card, kanban_board\)/,
      /A comment on a card → the card's `url` \+ "comment N"/,
      /A PR → that PR on ITS repo .*reuse the same numbers.*pr_url, its Links, `gh pr view`/,
      /A GitHub issue → that issue on its repo: `gh issue view`/,
      /A commit → the repo that holds it \(its remote\) \+ the sha/,
      /A CI build → the card's ci_url/,
      /A report, note or file → its page from the tool's output, or `path:line`/,
      /look it up — never guess, never fall back to one source/,
      /In chat, link text never puts `#` before a number/,
      /On the board write `card #N`, `PR #N`, `comment #N` as they are/,
    ]
    rules.each { |re| assert_match(re, text) }
  end

  # Agents READ a project's board shape (columns with types, the workflow, the derived rules — to pick a transition),
  # never write it — there is no tool for that.
  def test_kanban_workflow_reads_the_projects_board_shape
    j = ok("kanban_workflow", project: "g/r")
    assert_equal KanbanTest.board_hash("coding"), j.slice("columns", "transitions")
    assert_equal %w[human_check ready], j["rules"]["waiting"]
    assert_equal "busyyaks", j["updated_by"] # instantiated from the template by the engine
    transitions = [
      { "name" => "Go", "from" => "todo", "to" => "doing", "by" => "agent" },
      { "name" => "Approve", "from" => "human_check", "to" => "ready", "by" => "operator" },
    ]
    shape = KanbanTest.board_hash("coding").merge("transitions" => transitions)
    kb.board_save("g/r", shape, by: "op")
    names = ok("kanban_workflow", project: "g/r")["transitions"].map { |t| t["name"] }
    assert_equal [%w[Go Approve], "op"], [names, ok("kanban_workflow", project: "g/r")["updated_by"]]
    refute(@tools.definitions.any? { |t| t[:name].match?(/workflow_(save|reset|set)|board_shape/) })
    id = kb.create(slug: "g/r", title: "a", by: "op", column: "todo")
    assert_equal "doing", ok("kanban_move", id: id, transition: "Go", author: "tl_a")["column"] # a transition by name over MCP
    assert_match(/no transition "Go"/, err("kanban_move", id: id, transition: "Go", author: "tl_a"))
    b = ok("kanban_board", project: "g/r")
    assert_equal %w[parked queued working review gate gate done], b["columns"].map { |c| c["type"] }
    assert_equal %w[Go Approve], b["board"]["transitions"].map { |t| t["name"] }
  end
end
