# frozen_string_literal: true

require "test_helper"

# kanban_pr_assign: the agent that opened a PR assigns it to its card (metadata prs.<role>); the host reads only that.
class PrAssignTest < Minitest::Test
  include KanbanTest::Setup

  L = "https://github.com/o/r_local/pull/5"
  P = "https://github.com/o/r/pull/9"

  def setup
    super
    @tools = AgentsKanban::Tools.new(store: kb, attachments: nil, projects: ->(_) {}, sessions: -> { [] },
                                     card_url: CARD_URL)
    @id = kb.create(slug: "g/r", title: "t", by: "agent-1", metadata: { "draft_id" => 7 })
  end

  def ok(args) = JSON.parse(@tools.call("kanban_pr_assign", JSON.parse(JSON.generate(args))))
  def err(args) = assert_raises(AgentsKanban::Invalid) { @tools.call("kanban_pr_assign", args) }.message

  def test_assigns_by_role_and_keeps_the_other_metadata
    ok("id" => @id, "pr_url" => L, "role" => "local", "author" => "agent-1")
    c = ok("id" => @id, "pr_url" => P, "role" => "public", "author" => "agent-1")
    assert_equal({ "draft_id" => 7, "prs" => { "local" => L, "public" => P } }, c["metadata"])
    lines = kb.activity(@id).select { |e| e[:kind] == "update" }.map { |e| e[:body] }
    assert_equal ["PR local: #{L}", "PR public: #{P}"], lines
  end

  def test_a_role_again_replaces_its_pr_and_the_same_url_is_a_no_op
    ok("id" => @id, "pr_url" => L, "role" => "local", "author" => "agent-1")
    ok("id" => @id, "pr_url" => L, "role" => "local", "author" => "agent-1")
    newer = "https://github.com/o/r_local/pull/6"
    c = ok("id" => @id, "pr_url" => newer, "role" => "local", "author" => "agent-1")
    assert_equal({ "local" => newer }, c["metadata"]["prs"])
    assert_equal 2, kb.activity(@id).count { |e| e[:kind] == "update" && e[:body].start_with?("PR local") }
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

  def test_a_prs_value_that_is_not_an_object_is_refused
    kb.update(@id, { "metadata" => { "prs" => "x" } }, by: "agent-1")
    assert_match(/metadata prs is not an object: "x"/,
                 err("id" => @id, "pr_url" => L, "role" => "local", "author" => "agent-1"))
  end

  def test_listed_and_in_the_instructions
    d = @tools.definitions.find { |t| t[:name] == "kanban_pr_assign" }
    assert_equal %w[id pr_url role author], d[:inputSchema][:required]
    assert_match(/kanban_pr_assign\(id, pr_url, role, author\) at once/, @tools.instructions)
  end
end
