# frozen_string_literal: true

require "test_helper"

# Comment actions: a workflow transition with `comment: true` is offered in the operator's comment box as
# "Comment & <name>" — the comment is posted and the card moves along it, in one go. Defined in the workflow (the
# board's data), never a list in code.
class CommentActionsTest < Minitest::Test
  include KanbanTest::Setup
  Invalid = AgentsKanban::Invalid
  Denied = AgentsKanban::Denied

  FIXES = { "name" => "Fixes needed", "from" => %w[qa human_check], "to" => "doing", "by" => "any" }.freeze

  def shape = KanbanTest.board_hash("coding")
  def workflow(h) = AgentsKanban::Workflow.new(h, keys: kb.board_of("g/r").keys)

  # the coding board with "Fixes needed" a comment action
  def with_action!
    trs = shape["transitions"].map { |t| t["name"] == "Fixes needed" ? t.merge("comment" => true) : t }
    kb.board_save("g/r", shape.merge("transitions" => trs), by: "op")
  end

  def test_comment_is_an_optional_boolean_on_an_operator_edge_with_one_target
    on = workflow([FIXES.merge("comment" => true)])
    assert(on.from("qa").all?(&:comment))
    assert_equal [FIXES.merge("comment" => true)], on.to_a
    assert_equal [FIXES], workflow([FIXES.merge("comment" => false)]).to_a, "false is absent: one spelling"
    refute(workflow([FIXES]).from("qa").any?(&:comment), "absent = no comment action")
    bad = lambda do |h, msg|
      e = assert_raises(Invalid) { workflow([h]) }
      assert_equal msg, e.message
    end
    bad.call(FIXES.merge("comment" => "yes"),
             "transitions[0].comment must be true or false (absent = false; got \"yes\")")
    bad.call(FIXES.merge("comment" => true, "by" => "agent"),
             "transitions[0].comment: a comment action is the operator's — by must be operator or any")
    bad.call(FIXES.merge("comment" => true, "to" => "*"),
             "transitions[0].comment: a comment action needs one target column, not \"*\"")
    bad.call(FIXES.merge("extra" => 1),
             "transitions[0] must be an object with name, from, to, by (optional: comment)")
  end

  def test_the_flag_round_trips_the_rows_and_reaches_the_card_json
    with_action!
    stored = kb.board_of("g/r").to_h["transitions"].find { |t| t["name"] == "Fixes needed" }
    assert_equal true, stored["comment"]
    refute(kb.board_of("g/r").to_h["transitions"].any? { |t| t["name"] == "Start work" && t.key?("comment") })
    id = kb.create(slug: "g/r", title: "c", by: "op", column: "qa")
    trs = kb.card_json(kb.card(id))[:transitions]
    assert_equal [true], trs.select { |t| t[:name] == "Fixes needed" }.map { |t| t[:comment] }
    refute(trs.any? { |t| t[:name] != "Fixes needed" && t.key?(:comment) })
  end

  def test_comment_and_move_is_one_step_and_a_refusal_posts_nothing
    with_action!
    id = kb.create(slug: "g/r", title: "c", by: "claude-tl_g_r", owner_session: "tl_g_r", column: "qa")
    kb.comment(id, body: "rework the header", author: "op", operator: true, transition: "fixes needed")
    c = kb.card(id)
    assert_equal "doing", c[:column]
    acts = kb.activity(id).last(2)
    assert_equal [%w[comment op], %w[move op]], acts.map { |a| [a[:kind], a[:author]] }
    assert_equal ["rework the header", "QA → In progress"], acts.map { |a| a[:body] }
    pings = kb.pings(id)
    assert_equal 1, pings.size, "one ping: the comment and the move it took"
    assert_includes pings.first[:text], "rework the header"
    assert_includes pings.first[:text], "moved QA → In progress"

    n = kb.activity(id).size
    e = assert_raises(Denied) { kb.comment(id, body: "x", author: "op", operator: true, transition: "Send for QA") }
    assert_equal "workflow: \"Send for QA\" is no comment action from In progress (none)", e.message
    assert_equal n, kb.activity(id).size, "refused: nothing posted"
    assert_raises(Invalid) { kb.comment(id, body: "x", author: "op", operator: true, column: "qa") }

    # a move the rules refuse rolls the comment back: an archived card
    q = kb.create(slug: "g/r", title: "q", by: "op", column: "qa")
    kb.archive(q, by: "op")
    m = kb.activity(q).size
    assert_raises(Invalid) { kb.comment(q, body: "later", author: "op", operator: true, transition: "Fixes needed") }
    assert_equal m, kb.activity(q).size, "the move refused: the comment rolled back with it"
    assert_raises(Invalid) { kb.comment(id, body: " ", author: "op", operator: true, transition: "Fixes needed") }

  end

  # the operator's comment on a flagged card IS the answer (it clears needs_operator); a comment-move whose move is
  # refused rolls that answer back with the comment: the question stays open, no answer ping queued
  def test_a_refused_comment_move_keeps_the_question_open
    with_action!
    f = kb.create(slug: "g/r", title: "f", by: "claude-tl_g_r", owner_session: "tl_g_r", column: "qa")
    kb.ask(f, question: "which header?", by: "claude-tl_g_r")
    refute_nil kb.card(f)[:asked_at]
    n = kb.activity(f).size
    pings = kb.pings(f).size
    kb.define_singleton_method(:move) { |*, **| raise AgentsKanban::Denied, "refused by a move rule" }
    e = assert_raises(Denied) do
      kb.comment(f, body: "the left one", author: "op", operator: true, transition: "Fixes needed")
    end
    assert_equal "refused by a move rule", e.message
    c = kb.card(f)
    assert_equal ["qa", "which header?"], [c[:column], c[:question]]
    refute_nil c[:asked_at], "the needs_operator flag survives a refused comment-move"
    assert_equal n, kb.activity(f).size, "no comment, no answer line"
    assert_equal pings, kb.pings(f).size, "no answer ping"
  end

  def test_the_operators_api_takes_a_transition_with_the_comment
    with_action!
    id = kb.create(slug: "g/r", title: "c", by: "op", column: "human_check")
    root = Dir.mktmpdir("comment-actions")
    policy = AgentsKanban::AttachmentPolicy.new(max_bytes: 200, types: "text/plain")
    att = AgentsKanban::Attachments.new(kb, root: root, policy: policy, clock: -> { @now })
    api = AgentsKanban::Api.new(store: kb, attachments: att, markdown: md, projects: ->(_) {},
                                card_extras: ->(*) { {} }, board_extras: ->(*) { {} }, press: ->(**) {})
    s, j = api.comment(id, { "body" => "the footer overlaps", "transition" => "Fixes needed" }, by: "op")
    assert_equal [201, "doing"], [s, j[:card][:column]]
    assert j[:counts], "the columns' counts come back with a move"
    s, j = api.comment(id, { "body" => "x", "transition" => "Approve" }, by: "op")
    assert_equal 422, s
    assert_match(/is no comment action from In progress/, j[:error])
    s, j = api.comment(id, { "body" => "just a word" }, by: "op")
    assert_equal [201, "doing"], [s, j[:card][:column]]
    assert_nil j[:counts], "no move, no counts"
  ensure
    FileUtils.rm_rf(root) if root
  end
end
