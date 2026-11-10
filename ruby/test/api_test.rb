# frozen_string_literal: true

require "test_helper"

# The operator's API as a host calls it: [status, body] per call, a 404 / 422 / 413 / 503 never raised.
class ApiTest < Minitest::Test
  include KanbanTest::Setup

  def setup
    super
    @root = Dir.mktmpdir("api-att")
    @projects = { "g/r" => { slug: "g/r", path: @root, remote: nil } }
    policy = AgentsKanban::AttachmentPolicy.new(max_bytes: 200, types: "image/png,text/plain")
    @att = AgentsKanban::Attachments.new(kb, root: @root, policy: policy, clock: -> { @now })
    @pressed = []
    card_extras = ->(c, _b) { { links: [{ kind: "repo", label: c[:project_slug], url: "https://x" }] } }
    press = lambda do |**kw|
      @pressed << kw
      raise AgentsKanban::Delivery::Refused, "changed" if @refuse
      raise AgentsKanban::Delivery::Unavailable, "down" if @down
    end
    @api = AgentsKanban::Api.new(store: kb, attachments: @att, markdown: md, projects: ->(s) { @projects[s] },
                                 card_extras: card_extras,
                                 board_extras: ->(p) { { assignees: ["me", p[:slug]] } },
                                 press: press)
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def test_board_lifecycle
    s, j = @api.board("g/r")
    assert_equal 200, s
    assert_equal %w[backlog todo doing qa human_check ready merged], j[:columns].map { |c| c[:column] }
    assert_equal [false, false, false, false, true, true, true], j[:columns].map { |c| c[:operator_only] }
    assert_equal [0, 0], j.values_at(:waiting, :flagged)
    assert_equal ["me", "g/r"], j[:assignees]
    b = kb.board_of("g/r")
    assert_equal [config.to_h, b.keys, b.waiting, b.listened],
                 j.values_at(:config, :columns_order, :waiting_columns, :listened_columns)
    assert_equal [b.to_h["columns"], b.to_h["transitions"], b.rules[:waiting]],
                 [j[:board][:columns], j[:board][:transitions], j[:board][:rules][:waiting]]
    assert_equal %w[parked queued working review gate gate done], j[:columns].map { |c| c[:type] }
    assert_nil j[:backlog_md]
    assert_equal [404, { error: "no project nope" }], @api.board("nope")
    assert_equal 422, @api.board("g/r", column: "x")[0]

    assert_equal 201, @api.label_create("g/r", { "name" => "ui", "color" => "teal" })[0]
    fields = { "title" => "A", "column" => "todo", "labels" => ["ui"], "priority" => "high", "description" => "**d**" }
    s, a = @api.create("g/r", fields, by: "owner@example.com")
    assert_equal 201, s
    id = a[:card][:id]
    assert_equal ["todo", ["ui"], "high", "**d**", "owner@example.com", []],
                 a[:card].values_at(:column, :labels, :priority, :description, :created_by, :attachments)
    assert_equal [], a[:pings]
    assert_equal "repo", a[:links][0][:kind]
    b = @api.create("g/r", { "title" => "B", "column" => "todo" }, by: "op")[1][:card][:id]
    s, m = @api.move(b, { "column" => "todo", "position" => 0 }, by: "op")
    assert_equal [200, 0, 2, nil], [s, m[:card][:position], m[:counts]["todo"], m[:delivered]]
    @api.move(id, { "column" => "human_check" }, by: "op")
    assert_equal "merged", @api.move(id, { "column" => "merged" }, by: "op")[1][:card][:column], "the operator may merge"
    u = @api.update(id, { "title" => "A2", "labels" => [], "priority" => nil }, by: "op")[1]
    assert_equal ["A2", [], nil], u[:card].values_at(:title, :labels, :priority)
    assert_equal "tl_g_r", @api.assign(id, { "assignee" => "tl_g_r" }, by: "op")[1][:card][:assignee]
    s, c = @api.comment(id, { "body" => "done" }, by: "owner@example.com")
    assert_equal [201, 1, "none: no owner session"], [s, c[:card][:comments], c[:delivered]]
    assert_equal %w[create move move update update comment], c[:activity].map { |e| e[:kind] }
    ar = @api.archive(id, { "archived" => true }, by: "op")[1]
    refute_nil ar[:card][:archived]
    assert_equal [id], @api.board("g/r", archived: true)[1][:archived].map { |x| x[:id] }
    s, bs = @api.boards(@projects.values)
    assert_equal [200, 1, 0], [s, bs[:boards].first[:total], bs[:waiting]]
    assert_equal kb.board_template.columns.map { |c| { key: c.key, label: c.label, type: c.type.key } }, bs[:columns]
    assert_equal [kb.board_of("g/r").keys, %w[human_check ready], 0],
                 bs[:boards].first.values_at(:columns_order, :waiting_columns, :flagged)
    assert_equal "A2", @api.card(id)[1][:card][:title]
    assert_match(/\A\h{16}\z/, @api.card_rev(id)[1][:rev])
    assert_match(/\A\h{16}\z/, @api.board_rev("g/r")[1][:rev])
  end

  # the "waiting for you" widget — the FLAGGED cards (a question, a blocker) in any column and the boards' waiting
  # columns (the gates) over every board the host knows, flagged cards first, each with where it waits, since when,
  # and the question's / blocker's / QA's first line; one rev to poll.
  def test_waiting_lists_the_operators_cards_per_project_flagged_first_with_a_rev
    @projects["p"] = { slug: "p", path: @root, remote: nil }
    s, w = @api.waiting(@projects.values)
    assert_equal [200, 0, [], %w[human_check ready]], [s, w[:total], w[:projects], w[:waiting_columns]]
    r0 = @api.waiting_rev(@projects.values)[1][:rev]
    hc = kb.create(slug: "g/r", title: "check me", by: "op", column: "human_check")
    @now += 10
    q = kb.create(slug: "g/r", title: "ask", by: "op", column: "doing")
    kb.set_owner(q, session: "tl_g_r", by: "op")
    kb.ask(q, question: "**Ship A** or B?\n\nmore detail", by: "claude-tl_g_r")
    other = kb.create(slug: "p", title: "p check", by: "op", column: "doing")
    kb.set_owner(other, session: "tl_p", by: "op")
    kb.ask(other, question: "`teamlead_worker_3` is __stopped__", by: "claude-tl_p")
    p_waiting = @api.waiting(@projects.values)[1][:projects].find { |p| p[:slug] == "p" }
    assert_equal "teamlead_worker_3 is stopped", p_waiting[:cards][0][:question_first_line]
    kb.comment(other, body: "go", author: "operator@example.com", operator: true)
    kb.handoff(other, qa: "check it, twenty chars or more", pr_url: "https://github.com/x/y/pull/1", ci_url: "https://ci/1",
                      ui_change: false, by: "claude-tl_p")
    assert_nil kb.card(other)[:question], "the answer cleared the question (the activity keeps it)"
    kb.create(slug: "g/r", title: "not waiting", by: "op", column: "todo")
    kb.create(slug: "o/other", title: "a board the host does not list", by: "op", column: "human_check")
    a = kb.create(slug: "g/r", title: "archived", by: "op", column: "human_check")
    kb.archive(a, archived: true, by: "op")
    _, w = @api.waiting(@projects.values)
    assert_equal 3, w[:total]
    assert_equal [["g/r", 2], ["p", 1]], w[:projects].map { |p| [p[:slug], p[:count]] }, "most waiting first"
    g = w[:projects].first[:cards]
    assert_equal [q, hc], g.map { |c| c[:id] }, "a flagged card before the gate's"
    assert_equal ["In progress", "Ship A or B?", Time.at(1_010).iso8601, true, false],
                 g.first.values_at(:column_label, :question_first_line, :since, :needs_operator, :blocked)
    assert_equal ["human_check", "Human Check", nil, Time.at(1_000).iso8601, false],
                 g.last.values_at(:column, :column_label, :question_first_line, :since, :needs_operator)
    p_cards = w[:projects].last[:cards]
    assert_equal [[other, "human_check", nil]], p_cards.map { |c| c.values_at(:id, :column, :question_first_line) },
                 "an answered question is gone"
    assert_equal "check it, twenty chars or more", p_cards[0][:handoff_first_line], "a handed-off card shows what to check"
    assert_nil g.last[:handoff_first_line], "moved there by the operator: no handoff, nothing to quote"
    r1 = @api.waiting_rev(@projects.values)[1][:rev]
    refute_equal r0, r1
    assert_equal r1, @api.waiting_rev(@projects.values)[1][:rev], "stable while nothing changes"
    @now += 600
    assert_equal r1, @api.waiting_rev(@projects.values)[1][:rev], "time passing changes nothing (the client ages)"
    kb.move(hc, column: "ready", by: "operator@example.com")
    refute_equal r1, @api.waiting_rev(@projects.values)[1][:rev]
    # a blocked card waits too, with its reason; a flagged card in a gate counts once
    bl = kb.create(slug: "g/r", title: "blocked", by: "op", column: "doing")
    kb.block(bl, reason: "CI is down", url: "https://ci/status", by: "claude-tl_g_r")
    kb.set_owner(hc, session: "tl_g_r", by: "op")
    kb.ask(hc, question: "Merge now?", by: "claude-tl_g_r")
    _, w = @api.waiting(@projects.values)
    g = w[:projects].first
    assert_equal [4, [q, bl, hc]], [w[:total], g[:cards].map { |c| c[:id] }.first(3)],
                 "flagged first, longest flagged first (hc's since = when it was asked, not when it entered the gate)"
    b = g[:cards].find { |c| c[:id] == bl }
    assert_equal [true, "CI is down", nil], b.values_at(:blocked, :blocked_first_line, :question_first_line)
    _, bs = @api.boards(@projects.values)
    row = bs[:boards].find { |x| x[:project] == "g/r" }
    assert_equal [3, 2], row.values_at(:waiting, :flagged), "two gate cards (one also flagged) + one flagged elsewhere"
    assert_equal [3, 2], @api.board("g/r")[1].values_at(:waiting, :flagged)
  end

  def test_waiting_puts_a_project_with_a_question_first_whatever_its_count
    @projects["p"] = { slug: "p", path: @root, remote: nil }
    3.times { |i| kb.create(slug: "g/r", title: "check #{i}", by: "op", column: "human_check") }
    a = kb.create(slug: "p", title: "ask", by: "op", column: "doing")
    _, w = @api.waiting(@projects.values)
    assert_equal ["g/r"], w[:projects].map { |p| p[:slug] }
    kb.set_owner(a, session: "tl_p", by: "op")
    kb.ask(a, question: "Q?", by: "claude-tl_p")
    _, w = @api.waiting(@projects.values)
    assert_equal [["p", 1], ["g/r", 3]], w[:projects].map { |p| [p[:slug], p[:count]] }
  end

  def test_refusals_are_statuses_with_reasons
    id = kb.create(slug: "g/r", title: "x", by: "op")
    error = "column must be one of backlog, todo, doing, qa, human_check, ready, merged (got \"done\")"
    assert_equal [422, { error: error }], @api.move(id, { "column" => "done" }, by: "op")
    assert_match(/column is required/, @api.create("g/r", { "title" => "t" }, by: "op")[1][:error])
    assert_match(/title is required/, @api.create("g/r", { "title" => "", "column" => "todo" }, by: "op")[1][:error])
    assert_match(/unknown fields: column/, @api.update(id, { "column" => "todo" }, by: "op")[1][:error])
    assert_match(/archived must be/, @api.archive(id, { "archived" => "maybe" }, by: "op")[1][:error])
    assert_match(/assignee is required/, @api.assign(id, {}, by: "op")[1][:error])
    assert_equal [404, { error: "no card 999999" }], @api.card(999_999)
    assert_equal [404, { error: "no card x" }], @api.card("x")
    assert_equal [404, { error: "no comment 999999" }], @api.comment_delete(999_999, by: "op")
    assert_equal [404, { error: "no checklist 999999" }], @api.item_create(999_999, { "body" => "x" }, by: "op")
    assert_equal [404, { error: "no checklist item 999999" }], @api.item_delete(999_999, by: "op")
    assert_equal [404, { error: "no label 999999" }], @api.label_delete(999_999)
    assert_equal [404, { error: "no attachment 999999" }], @api.attachment_file(999_999)
    assert_match(/body must be a string/, @api.markdown_preview({ "body" => 1 })[1][:error])
    assert_match(/unknown fields: x/, @api.label_create("g/r", { "name" => "y", "color" => "red", "x" => 1 })[1][:error])
  end

  def test_answer_dialog_statuses
    id = kb.create(slug: "g/r", title: "blocked", by: "op", column: "doing")
    kb.set_owner(id, session: "hi-dialog", by: "op")
    d = AgentsKanban::SessionDialog.parse("Do you want to proceed?\n❯ 1. Yes\n  2. No\nEsc to cancel · Tab to amend\n")
    kb.dialog_question(session: "hi-dialog", dialog: d)
    assert_equal %w[1 2 esc], @api.card(id)[1][:card][:dialog][:keys]
    @down = true
    assert_equal [503, { error: "down" }], @api.dialog_answer(id, { "key" => "2" }, by: "op")
    @down = false
    @refuse = true
    assert_equal [422, { error: "changed" }], @api.dialog_answer(id, { "key" => "2" }, by: "op")
    assert kb.card(id)[:dialog_id]
    typed = @api.dialog_answer(id, { "key" => "type this" }, by: "op")
    assert_match(/free-text answers are typed in the session/, typed[1][:error])
    assert_equal 2, @pressed.size, "an invalid key never reaches the launcher"
    @refuse = false
    s, r = @api.dialog_answer(id, { "key" => "2" }, by: "owner@example.com")
    assert_equal [200, "doing", nil], [s, r[:card][:column], r[:card][:dialog]]
    answer = r[:activity].reverse.find { |a| a[:kind] == "answer" }
    assert_equal ["answer", "owner@example.com"], answer.values_at(:kind, :author)
  end

  def test_comments_checklists_labels_markdown
    id = kb.create(slug: "g/r", title: "card", by: "owner@example.com", column: "todo")
    c = @api.comment(id, { "body" => "hi @tl_g_r" }, by: "owner@example.com")[1][:activity].last
    assert_includes c[:body_html], %(<span class="mention">@tl_g_r</span>)
    e = @api.comment_update(c[:id], { "body" => "- one" }, by: "owner@example.com")[1][:activity].find { |a| a[:id] == c[:id] }
    assert_includes e[:body_html], "<li>one</li>"
    agent = kb.comment(id, body: "agent says", author: "agent-a")
    assert_equal 422, @api.comment_update(agent, { "body" => "x" }, by: "owner@example.com")[0]
    assert_equal "delete", @api.comment_delete(c[:id], by: "owner@example.com")[1][:activity].last[:kind]

    s, j = @api.checklist_create(id, { "title" => "Ship", "items" => ["a **b**", "c"] }, by: "op")
    cl = j[:card][:checklists][0]
    assert_equal [201, "Ship", "a <strong>b</strong>"], [s, cl[:title], cl[:items][0][:body_html]]
    j = @api.item_create(cl[:id], { "body" => "d" }, by: "op")[1]
    item = j[:card][:checklists][0][:items][0]
    j = @api.item_update(item[:id], { "done" => true }, by: "owner@example.com")[1]
    first = j[:card][:checklists][0][:items][0]
    assert_equal [true, "owner@example.com", 1], [first[:done], first[:done_by], j[:card][:checklist_done]]
    assert_match(/body or done is required/, @api.item_update(item[:id], {}, by: "op")[1][:error])
    s, j = @api.item_convert(j[:card][:checklists][0][:items][2][:id], by: "op")
    assert_equal [201, "d", "todo", 2], [s, j[:created][:title], j[:created][:column], j[:card][:checklist_total]]
    assert_equal 1, @api.item_delete(item[:id], by: "op")[1][:card][:checklist_total]
    assert_equal "Ship it", @api.checklist_update(cl[:id], { "title" => "Ship it" }, by: "op")[1][:card][:checklists][0][:title]
    assert_equal [], @api.checklist_delete(cl[:id], by: "op")[1][:card][:checklists]

    s, l = @api.label_create("g/r", { "name" => "bug", "color" => "red" })
    assert_equal [201, "bug"], [s, l[:label][:name]]
    assert_equal 422, @api.label_create("g/r", { "name" => "bug", "color" => "red" })[0]
    updated = @api.label_update(l[:label][:id], { "name" => "defect", "color" => "orange" })[1][:label]
    assert_equal %w[defect orange], updated.values_at(:name, :color)
    assert_equal [], @api.label_delete(l[:label][:id])[1][:labels]
    assert_includes @api.markdown_preview({ "body" => "**b** @me <script>x</script>" })[1][:html], "<strong>b</strong>"
    assert_equal "a <em>b</em>", @api.markdown_preview({ "body" => "a *b*", "inline" => true })[1][:html]
  end

  def test_attachments_upload_serve_delete
    id = kb.create(slug: "g/r", title: "T", by: "op")
    io = StringIO.new(PNG)
    s, j = @api.attach(id, filename: "shot.png", io: io, by: "op")
    assert_equal [201, "image/png", true], [s, j[:attachment][:content_type], j[:attachment][:image]]
    aid = j[:attachment][:id]
    s, f = @api.attachment_file(aid)
    assert_equal [200, true, PNG], [s, f[:inline], File.binread(f[:path])]
    refute @api.attachment_file(aid, download: true)[1][:inline]
    assert_equal 413, @api.attach(id, filename: "big.txt", io: StringIO.new("x" * 201), by: "op")[0]
    html = @api.attach(id, filename: "x.png", io: StringIO.new("<html>no</html>"), by: "op")
    assert_match(/the bytes are text\/html, the name says image\/png/, html[1][:error])
    assert_equal 422, @api.attach(id, filename: "a.txt", io: nil, by: "op")[0]
    no_comment = @api.attach(id, filename: "a.txt", io: StringIO.new("x"), by: "op", comment_id: "999999")
    assert_equal [422, "no comment 999999"], no_comment.then { |st, b| [st, b[:error]] }
    assert_equal 1, @api.board("g/r")[1][:columns][0][:cards][0][:attachments]
    d = @api.attachment_delete(aid, by: "op")[1]
    assert_empty d[:card][:attachments]
    assert_equal "deleted attachment shot.png", d[:activity].last[:body]
    assert_match(/was deleted/, @api.attachment_file(aid)[1][:error])
  end

  class FakeLauncher
    attr_reader :started
    attr_accessor :fail
    def initialize = (@started = []; @n = 0)
    def name(project:, base:) = "#{base}_#{@n += 1}"
    def start(**kw)
      raise AgentsKanban::Delivery::Refused, "tmux failed: no server" if @fail

      @started << kw
      { "ok" => true, "remote_control" => "on" }
    end
  end

  def test_launches_launch_and_sessions_over_the_ports
    live = %w[]
    l = FakeLauncher.new
    api = AgentsKanban::Api.new(store: kb, attachments: @att, markdown: md, projects: ->(s) { @projects[s] },
                                sessions: -> { live }, launcher: l, grace: 60)
    a = kb.create(slug: "g/r", title: "A", by: "op", column: "doing")
    s, j = api.launches("g/r")
    assert_equal 200, s
    types = [
      ["lead", "Launch", %w[fullclaude localclaude], true, 0, 0],
      ["team", "Sub team", %w[fullclaude localclaude], true, 0, 0],
      ["plain", "Plain", %w[fullclaude localclaude], false, 0, 0],
    ]
    got = j[:types].map do |t|
      [t[:key], t[:label], t[:launchers].map { |x| x[:key] }, t[:prompt], t[:running], t[:running_here]]
    end
    assert_equal types, got
    assert_equal [6, 0, 6], j[:concurrency].values_at(:max_sessions, :running, :free)
    assert_nil j[:sessions_error]
    # a launch: registered + adopted BEFORE the host starts it, so the prompt names the cards
    # no launcher named and the lead lists two (no spawn_launcher): refused, nothing registered — never the first one
    s, j = api.launch("g/r", { "type" => "lead" }, by: "op")
    refused = "agent type lead runs fullclaude, localclaude and none was named — name the launcher, or set " \
              "agent_types[lead].spawn_launcher"
    assert_equal [422, refused], [s, j[:error]]
    assert_empty l.started
    s, j = api.launch("g/r", { "type" => "lead", "launcher" => "fullclaude" }, by: "op")
    assert_equal 201, s
    assert_equal ["g_r_teamlead_1", "lead", "fullclaude", "claude-g_r_teamlead_1", [a]],
                 j.values_at(:session, :type, :launcher, :agent).push(j[:adopted].map { |c| c[:id] })
    assert_equal({ "ok" => true, "remote_control" => "on" }, j[:result])
    assert_equal 1, j[:concurrency][:running]
    st = l.started.last
    assert_equal ["g_r_teamlead_1", "lead", "fullclaude", "g/r"], [st[:session], st[:type], st[:launcher], st[:project][:slug]]
    assert_equal ["--remote-control", "g_r_teamlead_1"], st[:argv].last(2)
    assert_equal "##{a}", st[:vars][:cards]
    assert_match(/\{dir\}/, st[:prompt_template])
    assert_equal %w[claude-g_r_teamlead_1 g_r_teamlead_1], kb.card(a).values_at(:assignee, :owner_session)
    # the second lead for the board is refused by the type's per-project cap; nothing started
    s, j = api.launch("g/r", { "type" => "lead", "launcher" => "localclaude" }, by: "op")
    assert_equal 422, s
    assert_match(%r{1/1 lead session already runs for g/r}, j[:error])
    assert_equal 1, l.started.size
    # a sub team follows the board's running lead (launcher_follows): another launcher asked for is refused, never
    # swapped
    error = "team sessions of g/r run fullclaude while the lead session g_r_teamlead_1 does " \
            "(agent_types[team].launcher_follows) — localclaude refused"
    assert_equal [422, { error: error }], api.launch("g/r", { "type" => "team", "launcher" => "localclaude" }, by: "op")
    assert_equal 1, l.started.size
    assert_match(/no agent type "x"/, api.launch("g/r", { "type" => "x" }, by: "op")[1][:error])
    assert_match(/unknown fields: slug/, api.launch("g/r", { "type" => "plain", "slug" => "g/r" }, by: "op")[1][:error])
    assert_equal 404, api.launch("nope", { "type" => "plain" }, by: "op").first
    # a start that fails: the registration is ended, what it adopted is released, the host's reason is the answer
    @projects["p"] = { slug: "p", path: @root, remote: nil }
    b = kb.create(slug: "p", title: "B", by: "op", column: "doing")
    l.fail = true
    s, j = api.launch("p", { "type" => "lead", "launcher" => "fullclaude" }, by: "op")
    assert_equal [422, "tmux failed: no server"], [s, j[:error]]
    assert_equal [nil, nil], kb.card(b).values_at(:owner_session, :assignee)
    assert_equal "start failed: tmux failed: no server", kb.sessions_t.where(session: "p_teamlead_2").first[:end_reason]
    l.fail = false
    # the failed start is in the waiting list (the operator's alert, wherever they are) for a day, newest first
    failures = api.waiting(@projects.values)[1][:launch_failures]
    assert_equal [["p_teamlead_2", "p", "lead", "fullclaude", "op", "tmux failed: no server"]],
                 failures.map { |f| f.values_at(:session, :project, :type, :launcher, :launched_by, :reason) }
    rev = api.waiting_rev(@projects.values)[1][:rev]
    assert_empty api.waiting([@projects["g/r"]])[1][:launch_failures], "only the listed projects' failures"
    @now += AgentsKanban::Store::LAUNCH_FAILURE_WINDOW_S + 1
    assert_empty api.waiting(@projects.values)[1][:launch_failures], "older than a day: gone"
    refute_equal rev, api.waiting_rev(@projects.values)[1][:rev]
    @now -= AgentsKanban::Store::LAUNCH_FAILURE_WINDOW_S + 1
    # sessions: running vs ended; the sessions port down: 503 on launch, said on launches
    s, j = api.sessions
    assert_equal [["g_r_teamlead_1"], ["p_teamlead_2"]],
                 [j[:registered].map { |x| x[:session] }, j[:ended].map { |x| x[:session] }]
    down = AgentsKanban::Api.new(store: kb, attachments: @att, markdown: md, projects: ->(s) { @projects[s] }, launcher: l,
                                 sessions: -> { raise AgentsKanban::Delivery::Unavailable, "launcher not reachable" })
    assert_equal [503, { error: "launcher not reachable" }], down.launch("g/r", { "type" => "plain" }, by: "op")
    s, j = down.launches("g/r")
    assert_equal [200, nil, "launcher not reachable"], [s, j[:concurrency], j[:sessions_error]]
    portless = AgentsKanban::Api.new(store: kb, attachments: @att, markdown: md, projects: ->(s) { @projects[s] })
    assert_raises(ArgumentError) { portless.launch("g/r", {}, by: "op") }
  end

  # The operator edits a project's BOARD SHAPE: read (the template's copy until saved), save (validated as a whole,
  # stored), reset (the template again); a move off the saved graph is refused 422 with the transitions there are; a
  # move by transition name works; a column with cards cannot be dropped.
  def test_board_shape_get_save_reset_and_move_by_transition
    s, j = @api.board_shape("g/r")
    assert_equal [200, KanbanTest.board_hash("coding")["columns"], "busyyaks"], [s, j[:columns], j[:updated_by]]
    assert_equal [404, { error: "no project nope" }], @api.board_shape("nope")
    approve = { "name" => "Approve", "from" => "human_check", "to" => "ready", "by" => "operator" }
    transitions = [{ "name" => "Start work", "from" => "todo", "to" => "doing", "by" => "any" }, approve]
    strict = KanbanTest.board_hash("coding").merge("transitions" => transitions)
    s, j = @api.board_shape_save("g/r", strict, by: "owner@example.com")
    assert_equal [200, "owner@example.com", strict["transitions"]], [s, j[:updated_by], j[:transitions]]
    all_done = strict["columns"].map { |c| c.merge("type" => "done") }
    s, j = @api.board_shape_save("g/r", strict.merge("columns" => all_done), by: "owner@example.com")
    assert_equal 422, s
    assert_match(/are both done: a board has at most one done column/, j[:error])
    assert_equal 422, @api.board_shape_save("g/r", strict.merge("x" => 1), by: "o")[0]
    held = strict.merge("columns" => strict["columns"].reject { |c| c["key"] == "todo" }, "transitions" => [approve])

    _, a = @api.create("g/r", { "title" => "A", "column" => "todo" }, by: "owner@example.com")
    id = a[:card][:id]
    s, j = @api.move(id, { "column" => "merged" }, by: "owner@example.com")
    assert_equal 422, s
    assert_match(/no transition To do → Merged.*Start work → In progress/, j[:error])
    s, j = @api.board_shape_save("g/r", held, by: "owner@example.com")
    assert_equal 422, s
    assert_match(/cannot remove a column with cards: To do \(todo\) holds card ##{id}/, j[:error])
    s, j = @api.move(id, { "transition" => "Start work" }, by: "owner@example.com")
    assert_equal [200, "doing"], [s, j[:card][:column]]

    s, j = @api.board_shape_reset("g/r", by: "owner@example.com")
    assert_equal [200, KanbanTest.board_hash("coding")["transitions"], "owner@example.com"],
                 [s, j[:transitions], j[:updated_by]]
    assert_equal 200, @api.board("g/r")[0]
  end

  # a board edit that removed a column a Backlog.md status maps to: the board read stays 200, the tasks carry the reason
  def test_a_board_edit_never_takes_a_backlog_md_board_read_down
    FileUtils.mkdir_p(File.join(@root, "backlog/tasks"))
    File.write(File.join(@root, "backlog/tasks/task-1 - X.md"), "---\nid: TASK-1\ntitle: X\nstatus: QA\n---\n")
    backlog = ->(p, b) { AgentsKanban::BacklogMd.read(p[:path], board: b, status_map: { "qa" => "review" }) }
    api = AgentsKanban::Api.new(store: kb, attachments: @att, markdown: md, projects: ->(s) { @projects[s] }, backlog: backlog)
    assert_equal [%w[TASK-1 qa]], api.board("g/r")[1][:backlog_md][:tasks].map { |t| t.values_at("id", "column") }
    shape = KanbanTest.board_hash("coding")
    transitions = [
      { "name" => "Move", "from" => "*", "to" => "*", "by" => "any" },
      { "name" => "Approve", "from" => "human_check", "to" => "ready", "by" => "operator" },
    ]
    columns = shape["columns"].reject { |c| c["key"] == "qa" }
    s, = api.board_shape_save("g/r", shape.merge("columns" => columns, "transitions" => transitions), by: "op")
    assert_equal 200, s
    s, j = api.board("g/r")
    assert_equal [200, [["TASK-1", nil]]], [s, j[:backlog_md][:tasks].map { |t| t.values_at("id", "column") }]
    assert_match(/no review column/, j[:backlog_md][:errors].first)
  end

  # the board read and the boards list read each project's board ONCE (the batch read), not once per card or per rule
  def test_board_reads_are_batched
    3.times { |i| kb.create(slug: "g/r", title: "c#{i}", by: "op", column: "todo") }
    @projects["p"] = { slug: "p", path: @root, remote: nil }
    kb.create(slug: "p", title: "x", by: "op")
    count = lambda do |&blk|
      n = 0
      l = Object.new
      l.define_singleton_method(:method_missing) { |_m, *a| n += 1 if a.first.to_s.include?("board_transitions") }
      l.define_singleton_method(:respond_to_missing?) { |*| true }
      db.loggers << l
      blk.call
      db.loggers.delete(l)
      n
    end
    assert_operator count.call { assert_equal 200, @api.board("g/r")[0] }, :<=, 1
    assert_operator count.call { assert_equal 200, @api.boards(@projects.values)[0] }, :<=, 1
    assert_operator count.call { assert_equal 200, @api.waiting(@projects.values)[0] }, :<=, 1
  end

  # a stored board the host no longer fits takes the board read down LOUDLY (422 with the reason), never a stand-in
  def test_a_board_the_host_no_longer_fits_is_refused_on_read
    @api.create("g/r", { "title" => "A", "column" => "todo" }, by: "o")
    nohand = AgentsKanban::HostConfig.new(JSON.parse(JSON.generate(config.to_h)).merge("handoff" => nil))
    api = AgentsKanban::Api.new(store: store(nohand), attachments: @att, markdown: md, projects: ->(s) { @projects[s] })
    s, j = api.board("g/r")
    assert_equal 422, s
    assert_match(/the stored board of g\/r no longer fits this host \(column human_check is a gate/, j[:error])
  end
end
