# frozen_string_literal: true

require "test_helper"

# kanban_pr_assign / kanban_pr_unassign: the agents that open PRs assign them to their card (metadata prs, a LIST:
# any number per role and repo); the host reads only that. A PR leaves the list only through an explicit unassign.
class PrAssignTest < Minitest::Test
  include KanbanTest::Setup

  L = "https://github.com/o/r_local/pull/5"
  E = "https://github.com/o/eng_local/pull/91" # the engine's local PR: a second local PR, another repo
  P = "https://github.com/o/r/pull/9"

  def setup
    super
    @tools = AgentsKanban::Tools.new(store: kb, attachments: nil, projects: ->(_) {}, sessions: -> { [] },
                                     card_url: CARD_URL)
    @id = kb.create(slug: "g/r", title: "t", by: "agent-1", metadata: { "draft_id" => 7 })
  end

  def ok(args, tool = "kanban_pr_assign") = JSON.parse(@tools.call(tool, JSON.parse(JSON.generate(args))))
  def err(args, tool = "kanban_pr_assign", kind = AgentsKanban::Invalid)
    assert_raises(kind) { @tools.call(tool, args) }.message
  end
  def assign(url, role = "local", by = "agent-1", id: @id) = ok("id" => id, "pr_url" => url, "role" => role, "author" => by)
  def urls(card) = card["metadata"]["prs"].map { |p| p["url"] }

  def test_assigns_add_any_number_per_role_and_repo_and_keep_the_other_metadata
    assign(L)
    @now = 1_100
    assign(E)
    assign("https://github.com/o/r_local/pull/6") # a second PR on the same repo
    c = assign(P, "public", "agent-2")
    assert_equal 7, c["metadata"]["draft_id"]
    assert_equal [L, E, "https://github.com/o/r_local/pull/6", P], urls(c), "oldest first, nothing replaced"
    assert_equal({ "url" => E, "repo" => "o/eng_local", "number" => 91, "role" => "local", "by" => "agent-1", "at" => 1_100 },
                 c["metadata"]["prs"][1])
    lines = kb.activity(@id).select { |e| e[:kind] == "update" }.map { |e| e[:body] }
    assert_equal ["PR local: #{L}", "PR local: #{E}", "PR local: https://github.com/o/r_local/pull/6", "PR public: #{P}"], lines
  end

  def test_the_same_url_again_is_a_no_op_and_under_another_role_is_refused
    assign(L)
    before = kb.card(@id)
    assign(L)
    assign(L.upcase.sub("HTTPS://GITHUB.COM", "https://github.com").sub("PULL", "pull"))
    assert_equal before[:metadata], kb.card(@id)[:metadata]
    assert_equal 1, kb.activity(@id).count { |e| e[:kind] == "update" && e[:body].start_with?("PR local") }
    pr_roles.roles["any"] = { repos: nil, required: false }
    assert_match(/is already the local PR of card ##{@id}: kanban_pr_unassign it first to assign it as any/,
                 err("id" => @id, "pr_url" => L, "role" => "any", "author" => "a"))
  end

  def test_refuses_what_is_not_a_pr_url_or_a_role
    base = { "id" => @id, "author" => "agent-1" }
    %w[https://github.com/o/r/issues/3 http://github.com/o/r/pull/3 https://github.com/o/r/pull/0 #5].each do |u|
      assert_match(/pr_url must be a GitHub pull request URL/, err(base.merge("pr_url" => u, "role" => "local")), u)
    end
    ["Local", "a b", "x" * 33].each do |r|
      assert_match(/role must be a lowercase word/, err(base.merge("pr_url" => L, "role" => r)), r)
    end
    assert_match(/no card 999/, err(base.merge("id" => 999, "pr_url" => L, "role" => "local")))
    assert_nil kb.card(@id)[:metadata]["prs"], "nothing written by a refusal"
  end

  # a bad value stored some other way (an old row, a hand edit): the reader refuses it with what it is
  def raw_metadata!(meta, id = @id) = db[:"#{KanbanTest::PREFIX}cards"].where(id: id).update(metadata: JSON.generate(meta))

  def test_a_prs_value_that_is_not_a_list_of_prs_is_refused
    raw_metadata!("prs" => "x")
    assert_match(/metadata prs is not a list of \{url, role\}: "x"/, err("id" => @id, "pr_url" => L, "role" => "local",
                                                                             "author" => "agent-1"))
    raw_metadata!("prs" => { "local" => L })
    assert_match(/metadata prs is the pre-list \{role => url\} shape: run the host's migration to engine schema 13/,
                 err("id" => @id, "pr_url" => E, "role" => "local", "author" => "agent-1"))
    raw_metadata!("prs" => [], "prs_removed" => "x")
    assert_match(/metadata prs_removed is not a list of \{role, url\}: "x"/,
                 err("id" => @id, "pr_url" => E, "role" => "local", "author" => "agent-1"))
  end

  def test_listed_and_in_the_instructions
    d = @tools.definitions.find { |t| t[:name] == "kanban_pr_assign" }
    assert_equal %w[id pr_url role author], d[:inputSchema][:required]
    assert_match(/It ADDS: a card holds any number of PRs per role and repo/, d[:description])
    u = @tools.definitions.find { |t| t[:name] == "kanban_pr_unassign" }
    assert_equal %w[id pr_url author reason], u[:inputSchema][:required]
    assert_match(/kanban_pr_assign\(id, pr_url, role, author\) at once — every PR, on every repo/, @tools.instructions)
    assert_match(/kanban_pr_unassign\(id, pr_url, author, reason\)/, @tools.instructions)
  end

  def test_assign_refuses_a_role_the_host_does_not_read
    msg = err("id" => @id, "pr_url" => P, "role" => "pub", "author" => "agent-1")
    assert_match(/role "pub" is not one this project reads \(local, public\)/, msg)
    assert_nil kb.card(@id)[:metadata]["prs"], "nothing written by a refusal"
  end

  def test_assign_refuses_a_pr_of_a_repo_its_role_does_not_take
    assert_match(%r{a public PR is on o/r / o/eng, not on o/r_local: assign this PR under the role of its repo},
                 err("id" => @id, "pr_url" => L, "role" => "public", "author" => "a"))
    assert_match(%r{a local PR is on o/r_local / o/eng_local, not on x/y},
                 err("id" => @id, "pr_url" => "https://github.com/x/y/pull/1", "role" => "local", "author" => "a"))
    assert_nil kb.card(@id)[:metadata]["prs"]
    c = assign("https://github.com/O/R/pull/9", "public")
    assert_equal ["https://github.com/O/R/pull/9"], urls(c), "owner/name match in any case"
    pr_roles.roles["public"][:error] = "the public repo's remote has no URL"
    assert_match(/a public PR cannot be assigned on card ##{@id} now: the public repo's remote has no URL/,
                 err("id" => @id, "pr_url" => "https://github.com/o/r/pull/10", "role" => "public", "author" => "a"))
    pr_roles.roles["public"] = { repos: [], required: false }
    assert_match(%r{a public PR is on no repo the host knows, not on o/r},
                 err("id" => @id, "pr_url" => "https://github.com/o/r/pull/10", "role" => "public", "author" => "a"))
    pr_roles.roles = { "pr" => { repos: nil, required: false } } # nil = any repo
    assert assign("https://github.com/x/y/pull/1", "pr")
  end

  def test_one_pr_assigned_to_two_cards_is_refused_naming_the_other
    assign(L)
    other = kb.create(slug: "p", title: "o", by: "agent-1")
    msg = err("id" => other, "pr_url" => L.sub("o/r_local", "O/R_LOCAL"), "role" => "local", "author" => "agent-1")
    assert_match(/is already the local PR of card ##{@id} \(g\/r\): a PR belongs to one card/, msg)
    assert_nil kb.card(other)[:metadata]
    # a PR number that only looks alike (pull/50 vs pull/5) is another PR
    assert assign("https://github.com/o/r_local/pull/50", id: other)
    kb.move(@id, column: "merged", by: "op") # done keeps its PR: still refused elsewhere
    third = kb.create(slug: "g/r", title: "3", by: "agent-1")
    assert_match(/already the local PR of card ##{@id}/, err("id" => third, "pr_url" => L, "role" => "local", "author" => "a"))
  end

  def test_a_cancelled_or_archived_card_gives_its_pr_up
    cancelling = kb.create(slug: "g/r", title: "c", by: "agent-1")
    assign(L, id: cancelling)
    archived = kb.create(slug: "g/r", title: "a", by: "agent-1")
    assign(P, "public", id: archived)
    board = KanbanTest.board_hash
    board["columns"] << { "key" => "cancelled", "label" => "Cancelled", "type" => "cancelled" }
    kb.board_save("g/r", board, by: "op")
    assert_match(/already the local PR of card ##{cancelling}/,
                 err("id" => @id, "pr_url" => L, "role" => "local", "author" => "a"))
    kb.move(cancelling, column: "cancelled", by: "op")
    assert assign(L)
    kb.archive(archived, by: "op")
    assert_equal [L, P], urls(assign(P, "public"))
  end

  def test_unassign_takes_one_pr_off_logged_with_its_reason
    assign(L)
    assign(E)
    @now = 3_000
    c = ok({ "id" => @id, "pr_url" => E, "author" => "agent-1", "reason" => "the engine change moved to card 12" },
           "kanban_pr_unassign")
    assert_equal [L], urls(c), "only that PR left the list"
    assert_equal [{ "url" => E, "repo" => "o/eng_local", "number" => 91, "role" => "local", "by" => "agent-1",
                    "at" => 1_000, "removed_by" => "agent-1", "removed_at" => 3_000,
                    "reason" => "the engine change moved to card 12", }], c["metadata"]["prs_removed"]
    assert_equal "PR local unassigned: #{E} — the engine change moved to card 12",
                 kb.activity(@id).reverse.find { |e| e[:kind] == "update" }[:body]
    other = kb.create(slug: "g/r", title: "o", by: "agent-1")
    assert_equal [E], urls(assign(E, id: other)), "an unassigned PR is free for another card"
    assert_match(/already the local PR of card ##{other}/, err("id" => @id, "pr_url" => E, "role" => "local", "author" => "a"))
  end

  def test_unassign_refusals
    base = { "id" => @id, "pr_url" => L, "author" => "agent-1" }
    assert_match(/reason is required/, err(base.merge("reason" => " "), "kanban_pr_unassign"))
    assert_match(/reason is longer than 500/, err(base.merge("reason" => "x" * 501), "kanban_pr_unassign"))
    assert_match(/is not assigned to card ##{@id} \(its PRs: none\)/, err(base.merge("reason" => "r"), "kanban_pr_unassign"))
    assign(L)
    assert_match(%r{#{E} is not assigned to card ##{@id} \(its PRs: local #{L}\)},
                 err(base.merge("pr_url" => E, "reason" => "r"), "kanban_pr_unassign"))
    msg = err(base.merge("author" => "agent-9", "reason" => "r"), "kanban_pr_unassign", AgentsKanban::Denied)
    assert_match(/was assigned by agent-1: only that agent, the card's assignee \(none\) or the operator unassigns it/, msg)
    assert_equal [L], kb.card(@id)[:metadata]["prs"].map { |p| p["url"] }, "a refusal writes nothing"
    db[:"#{KanbanTest::PREFIX}cards"].where(id: @id).update(assignee: "agent-9")
    assert_empty ok(base.merge("author" => "agent-9", "reason" => "not this card's"), "kanban_pr_unassign")["metadata"]["prs"],
                 "the card's assignee may"
    assert_match(/no card 999/, err(base.merge("id" => 999, "reason" => "r"), "kanban_pr_unassign"))
  end

  def test_the_operator_unassigns_any_pr_through_the_api
    assign(L, "local", "agent-3")
    policy = AgentsKanban::AttachmentPolicy.new(max_bytes: 200, types: "text/plain")
    att = AgentsKanban::Attachments.new(kb, root: Dir.mktmpdir("pr-att"), policy: policy, clock: -> { @now })
    api = AgentsKanban::Api.new(store: kb, attachments: att, markdown: md, projects: ->(_) {})
    status, body = api.pr_unassign(@id, { "pr_url" => L, "reason" => "wrong card" }, by: "op")
    assert_equal 200, status
    assert_empty body[:card][:metadata]["prs"]
    assert_equal "op", body[:card][:metadata]["prs_removed"].first["removed_by"]
    assert_equal 422, api.pr_unassign(@id, { "pr_url" => L, "reason" => "again" }, by: "op").first
    assert_equal [422, { error: "unknown fields: role" }], api.pr_unassign(@id, { "pr_url" => L, "role" => "x" }, by: "op")
    assert_equal 404, api.pr_unassign(999, { "pr_url" => L, "reason" => "r" }, by: "op").first
  end

  def test_the_port_is_required_and_a_port_that_cannot_say_refuses
    pr_roles.down = "the enrolment of g/r is unreadable"
    assert_match(/PR roles of card ##{@id} cannot be read: the enrolment of g\/r is unreadable/,
                 err("id" => @id, "pr_url" => L, "role" => "local", "author" => "a"))
    assert_raises(ArgumentError) { AgentsKanban::Store.new(db, config: config, markdown: md, boards: ->(_) { true }) }
    e = assert_raises(ArgumentError) do
      AgentsKanban::Store.new(db, config: config, markdown: md, boards: ->(_) { true }, ci: approval_ci, prs: 1)
    end
    assert_match(/prs: must answer pr_roles\(card\)/, e.message)
    pr_roles.down = nil
    pr_roles.roles = {} # a host whose cards carry no PRs says so: every role refused, none required
    msg = err("id" => @id, "pr_url" => L, "role" => "local", "author" => "a")
    assert_match(/role "local" is not one this project reads \(\)/, msg)
  end

  def test_metadata_pr_keys_are_written_only_by_the_pr_tools
    assign(L)
    before = kb.card(@id)
    %w[prs prs_removed prs_replaced].each do |k|
      e = assert_raises(AgentsKanban::Invalid) do
        @tools.call("kanban_update", "id" => @id, "author" => "agent-1", "metadata" => { k => [{ "url" => P }] })
      end
      assert_match(/metadata #{k} is written only by kanban_pr_assign \/ kanban_pr_unassign/, e.message)
      e = assert_raises(AgentsKanban::Invalid) { kb.update(@id, { "metadata" => { k => [] } }, by: "op") }
      assert_match(/written only by kanban_pr_assign/, e.message, "the operator too")
      e = assert_raises(AgentsKanban::Invalid) { kb.create(slug: "g/r", title: "x", by: "a", metadata: { k => [] }) }
      assert_match(/written only by kanban_pr_assign/, e.message)
    end
    assert_equal before[:metadata], kb.card(@id)[:metadata], "the card is unchanged"
    assert_equal before[:updated_at], kb.card(@id)[:updated_at]
    # the rest of the metadata is the caller's; the PR keys stay as the PR tools wrote them
    c = kb.update(@id, { "metadata" => { "draft_id" => 8 } }, by: "agent-1")
    assert_equal [8, [L]], [c[:metadata]["draft_id"], c[:metadata]["prs"].map { |p| p["url"] }]
    assert_equal ["prs"], kb.update(@id, { "metadata" => nil }, by: "agent-1")[:metadata].keys
    other = kb.create(slug: "g/r", title: "y", by: "a", metadata: { "k" => 1 })
    assert_nil kb.update(other, { "metadata" => nil }, by: "a")[:metadata]
  end

  def test_the_metadata_cap_names_the_prs
    (1..80).each { |n| assign("https://github.com/o/r_local/pull/#{n}") }
  rescue AgentsKanban::Invalid => e
    assert_match(/card ##{@id}: metadata is longer than 8000 characters as JSON with its PRs — unassign the PRs/, e.message)
  else
    flunk "80 PRs fit in 8000 characters"
  end

  # a report for a human: PR URLs an open card names (pr_url, description, comments, handoffs) but does not hold
  def test_unassigned_pr_mentions_lists_what_a_card_names_but_does_not_hold_and_writes_nothing
    assign(L)
    raw = db[:"#{KanbanTest::PREFIX}cards"]
    raw.where(id: @id).update(pr_url: L, notes: "engine side: #{E}")
    c = kb.comment(@id, body: "also #{E.sub('o/eng_local', 'O/ENG_LOCAL')} and #{P}", author: "a")
    done = kb.create(slug: "g/r", title: "old", by: "a", notes: "https://github.com/o/x/pull/1")
    kb.move(done, column: "merged", by: "op")
    before = raw.order(:id).select_map(%i[id metadata updated_at])
    rows = kb.unassigned_pr_mentions
    assert_equal [[@id, "g/r", "Backlog", E, "description"], [@id, "g/r", "Backlog", P, "comment #{c}"]],
                 rows.map { |r| r.values_at(:card, :project, :column, :url, :seen) }
    assert_equal before, raw.order(:id).select_map(%i[id metadata updated_at]), "reads only"
    kb.unassign_pr(@id, url: L, by: "agent-1", reason: "not this card's", agent: true)
    raw.where(id: @id).update(pr_url: L)
    refute(kb.unassigned_pr_mentions.any? { |r| r[:url] == L }, "a PR taken off on purpose is not listed again")
    raw_metadata!("prs" => { "local" => L })
    assert_match(/metadata prs is the pre-list/, assert_raises(AgentsKanban::Invalid) { kb.unassigned_pr_mentions }.message)
  end

  # two agents assigning one PR to two cards at once: the role and one-card checks read inside the writer's
  # transaction (the host serialises writers), so the second sees the first's write; a refusal rolls back
  def test_the_checks_run_inside_the_transaction
    seen = []
    conn = db
    hook = Object.new
    hook.define_singleton_method(:pr_roles) do |_card|
      seen << conn.in_transaction?
      { "local" => { repos: ["o/r_local"], required: false } }
    end
    racing = AgentsKanban::Store.new(db, config: config, markdown: md, boards: ->(_) { true }, ci: approval_ci, prs: hook)
    racing.assign_pr(@id, url: L, role: "local", by: "a")
    other = kb.create(slug: "g/r", title: "o", by: "agent-1")
    e = assert_raises(AgentsKanban::Invalid) { racing.assign_pr(other, url: L, role: "local", by: "a") }
    assert_match(/already the local PR of card ##{@id}/, e.message, "raised as itself after the rollback")
    assert_equal [true, true], seen
    assert_nil kb.card(other)[:metadata], "rolled back: nothing written"
  end

  def test_an_agent_leaving_the_work_column_needs_at_least_one_pr_of_each_required_role
    pr_roles.roles["local"][:required] = true
    id = kb.create(slug: "g/r", title: "w", by: "agent-1")
    kb.move(id, column: "doing", by: "agent-1", agent: true)
    msg = assert_raises(AgentsKanban::Denied) { kb.move(id, column: "qa", by: "agent-1", agent: true) }.message
    assert_match(/card ##{id} has no local PR assigned — open the PR and /, msg)
    assert_match(/kanban_pr_assign\(#{id}, pr_url, "local", author\) before it leaves In progress/, msg)
    handoff = { qa: "Open /x at 375 and 1280 px and see the list", pr_url: L, ci_url: "https://ci.example/1", ui_change: false,
                by: "agent-1", }
    assert_match(/has no local PR assigned/, assert_raises(AgentsKanban::Denied) { kb.handoff(id, **handoff) }.message)
    assert_equal "doing", kb.card(id)[:column]
    kb.assign_pr(id, url: P, role: "public", by: "agent-1") # a PR of another role does not count
    assert_raises(AgentsKanban::Denied) { kb.move(id, column: "qa", by: "agent-1", agent: true) }
    kb.move(id, column: "todo", by: "agent-1", agent: true) # back to the queue: nothing asked
    kb.move(id, column: "doing", by: "agent-1", agent: true)
    assert_equal "qa", kb.move(id, column: "qa", by: "op")[:column], "the operator's drag is never refused"
    assert_equal "In progress → QA (dragged: no local PR)", kb.activity(id).reverse.find { |e| e[:kind] == "move" }[:body]
    kb.move(id, column: "doing", by: "agent-1", agent: true)
    kb.assign_pr(id, url: E, role: "local", by: "agent-1") # any repo of the role counts (here the engine's)
    assert_equal "qa", kb.move(id, column: "qa", by: "agent-1", agent: true)[:column]
    kb.move(id, column: "doing", by: "op")
    kb.move(id, column: "qa", by: "op")
    assert_equal "In progress → QA", kb.activity(id).reverse.find { |e| e[:kind] == "move" }[:body], "nothing missing"
    pr_roles.down = "no enrolment"
    kb.move(id, column: "doing", by: "op")
    kb.move(id, column: "qa", by: "op")
    assert_match(/In progress → QA \(dragged: PR roles unknown — .*no enrolment\)/,
                 kb.activity(id).reverse.find { |e| e[:kind] == "move" }[:body])
    kb.move(id, column: "doing", by: "op")
    assert_match(/cannot be read: no enrolment/,
                 assert_raises(AgentsKanban::Invalid) { kb.move(id, column: "qa", by: "agent-1", agent: true) }.message)
  end
end
