# frozen_string_literal: true

require "test_helper"

# A host's terminals: which registered sessions work on a card, and the audit events of who opened
# or drove one.
class TerminalTest < Minitest::Test
  include KanbanTest::Setup

  def setup
    super
    kb.register_session(session: "lead_1", project: "p", type: "lead", launcher: "fullclaude", by: "op")
    @id = kb.create(slug: "p", title: "t", by: "me", column: "doing")
  end

  def test_card_sessions_are_the_owner_then_the_assignees_registrations
    assert_empty kb.card_sessions(@id), "nobody registered works on it"
    kb.set_owner(@id, session: "lead_1", by: "me")
    kb.register_session(session: "worker_1", project: "p", type: "team", launcher: "fullclaude", by: "op")
    agent = kb.open_session("worker_1")[:agent_name]
    kb.update(@id, { "assignee" => agent }, by: "me")
    rows = kb.card_sessions(@id)
    assert_equal [["lead_1", true], ["worker_1", false]], rows.map { |r| r.values_at(:session, :owner) }
    assert_equal "default", rows.first[:socket]
  end

  def test_an_ended_owner_is_not_listed
    kb.set_owner(@id, session: "lead_1", by: "me")
    kb.end_session("lead_1", reason: "gone", by: "op")
    assert_empty kb.card_sessions(@id)
  end

  def test_terminal_event_logs_on_every_card_the_session_owns
    other = kb.create(slug: "p", title: "u", by: "me", column: "doing")
    gone = kb.create(slug: "p", title: "archived", by: "me", column: "doing")
    [@id, other, gone].each { |c| kb.set_owner(c, session: "lead_1", by: "me") }
    kb.archive(gone, by: "me")
    ids = kb.terminal_event(session: "lead_1", by: "op@x", text: "opened the terminal")
    assert_equal [@id, other], ids
    e = kb.activity(@id).find { |a| a[:kind] == "terminal" }
    assert_equal ["op@x", "opened the terminal · session lead_1"], e.values_at(:author, :body)
    assert_empty kb.activity(gone).select { |a| a[:kind] == "terminal" }
  end

  # an assignee-only session (a worker on a card another session owns) is logged on the cards assigned to it too
  def test_terminal_event_logs_on_the_cards_assigned_to_the_session
    kb.set_owner(@id, session: "lead_1", by: "me")
    kb.register_session(session: "worker_1", project: "p", type: "team", launcher: "fullclaude", by: "op")
    kb.update(@id, { "assignee" => kb.open_session("worker_1")[:agent_name] }, by: "me")
    other = kb.create(slug: "p", title: "not its card", by: "me", column: "doing")
    assert_equal [@id], kb.terminal_event(session: "worker_1", by: "op", text: "took control of the terminal")
    assert_equal ["took control of the terminal · session worker_1"],
                 kb.activity(@id).select { |a| a[:kind] == "terminal" }.map { |a| a[:body] }
    assert_empty kb.activity(other).select { |a| a[:kind] == "terminal" }
  end

  def test_terminal_event_refusals
    assert_raises(AgentsKanban::Denied) { kb.terminal_event(session: "nobody", by: "op", text: "opened") }
    assert_raises(AgentsKanban::Denied) { kb.terminal_event(session: "lead_1", socket: "other", by: "op", text: "x") }
    assert_raises(AgentsKanban::Invalid) { kb.terminal_event(session: "lead_1", by: "op", text: " ") }
    assert_raises(AgentsKanban::Invalid) { kb.terminal_event(session: "lead_1", by: " ", text: "opened") }
    assert_equal [], kb.terminal_event(session: "lead_1", by: "op", text: "opened"), "owns nothing: logged nowhere"
  end
end
