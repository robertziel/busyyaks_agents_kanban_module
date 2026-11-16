# frozen_string_literal: true

require "test_helper"
require "stringio"

# The PR watch: every PR assigned to a live card is watched on each notifier watch pass (the ci: port's closed_prs);
# a PR closed without merging is told ONCE per close — a comment on the card and a ping to its owner, with the host's
# reason — and never on a card in a terminal column.
class PrWatchTest < Minitest::Test
  include KanbanTest::Setup

  class FakeClient
    def notify(**) = { "ok" => true }
    def agents = { "age_s" => 1, "interval_s" => 5, "sessions" => [] }
    def sessions = [{ "name" => "acme_shop" }]
    def dialog(**) = { "ok" => true, "dialog" => nil }
  end

  # the approval port + closed_prs: {card id => [closed PRs]}; down = why it cannot say
  class WatchCi < ApprovalCi
    attr_accessor :closed, :closed_down
    attr_reader :watched

    def closed_prs(card)
      (@watched ||= []) << card[:id]
      raise AgentsKanban::Delivery::Unavailable, @closed_down if @closed_down

      (@closed || {}).fetch(card[:id], [])
    end
  end

  CLOSED = { role: "public", number: 43, closed_at: 5_000, why: "base deleted" }.freeze

  def setup
    super
    @approval_ci = WatchCi.new
    @m = store(board: KanbanTest.board_hash("local_v4"))
    @log = StringIO.new
    @n = AgentsKanban::Notifier.new(@m, client: FakeClient.new, ci: NoCi.new, clock: -> { @now }, grace: 60, log: @log)
  end

  def card(column = "doing", owner: true)
    id = @m.create(slug: "p", title: "t", by: "me", column: column)
    return id unless owner

    @m.update(id, { "assignee" => "claude-shop-lead" }, by: "claude-shop-lead")
    @m.set_owner(id, session: "acme_shop", by: "claude-shop-lead")
    id
  end

  def comments(id) = @m.activity(id).select { |a| a[:kind] == "comment" }.map { |a| a[:body] }

  def test_a_closed_unmerged_pr_is_told_once_on_the_card_and_to_the_owner
    id = card
    approval_ci.closed = { id => [CLOSED] }
    @n.watch
    @n.watch
    assert_equal ["PR #43 (public) closed without merging (base deleted) — pinged acme_shop."], comments(id)
    pings = @m.pings(id)
    assert_equal 1, pings.size
    assert_equal "pr_closed", pings.first[:reason]
    assert_match(/\A\[busyyaks\] PR #43 \(public\) closed without merging \(base deleted\) while card ##{id} "t" is in /,
                 pings.first[:text])
    assert_match(/open a new PR and assign it \(kanban_pr_assign\)/, pings.first[:text])
    assert_equal 1, @log.string.scan("pr watch: card #{id} PR closed without merging, owner pinged").size
  end

  def test_a_reopened_pr_closed_again_is_a_new_close
    id = card
    approval_ci.closed = { id => [CLOSED] }
    @m.pr_watch_pass
    approval_ci.closed = { id => [CLOSED.merge(closed_at: 6_000, why: "closed by robertziel")] }
    assert_equal [[id, :closed]], @m.pr_watch_pass
    assert_equal 2, comments(id).size
    assert_match(/closed by robertziel/, comments(id).last)
  end

  def test_two_roles_closed_at_one_second_are_two_closes
    id = card
    approval_ci.closed = { id => [CLOSED, CLOSED.merge(role: "local", number: 7)] }
    assert_equal [[id, :closed], [id, :closed]], @m.pr_watch_pass
  end

  def test_no_owner_session_is_said_and_pings_nobody
    id = card(owner: false)
    approval_ci.closed = { id => [CLOSED] }
    assert_equal [[id, :closed_nobody]], @m.pr_watch_pass
    assert_equal ["PR #43 (public) closed without merging (base deleted) — no owner session to ping."], comments(id)
    assert_empty @m.pings(id)
  end

  def test_terminal_and_archived_cards_are_not_watched
    live = card
    done = card("done")
    cancelled = card("cancelled")
    approval_ci.closed = { live => [CLOSED], done => [CLOSED], cancelled => [CLOSED] }
    assert_equal [[live, :closed]], @m.pr_watch_pass
    assert_equal [live], approval_ci.watched
  end

  def test_a_card_the_port_cannot_read_is_said_once_and_the_others_are_still_watched
    a = card
    b = card
    approval_ci.closed = { b => [CLOSED] }
    approval_ci.closed_down = "github down"
    assert_equal [[a, "unavailable: github down"], [b, "unavailable: github down"]], @m.pr_watch_pass
    @n.watch
    @n.watch
    assert_equal 1, @log.string.scan("pr watch: card #{a}: github down").size
    approval_ci.closed_down = nil
    @n.watch
    assert_match(/pr watch: card #{a} answered again/, @log.string)
    assert_equal 1, comments(b).size
  end

  def test_a_failed_read_of_one_pr_is_said_while_another_pr_of_the_card_stays_closed
    id = card
    approval_ci.closed = { id => [CLOSED, { error: "local PR #7 on o/r: GitHub read failed: 500" }] }
    assert_equal [[id, :closed], [id, "unavailable: local PR #7 on o/r: GitHub read failed: 500"]], @m.pr_watch_pass
    # the close is told already; the other PR's failure is still said on every pass
    assert_equal [[id, "unavailable: local PR #7 on o/r: GitHub read failed: 500"]], @m.pr_watch_pass
    @n.watch
    @n.watch
    assert_equal 1, @log.string.scan("pr watch: card #{id}: local PR #7 on o/r: GitHub read failed: 500").size
    assert_equal 1, comments(id).size
  end

  def test_two_failed_reads_of_one_card_are_one_line
    id = card
    approval_ci.closed = { id => [{ error: "a down" }, { error: "b down" }] }
    @n.watch
    assert_equal 1, @log.string.scan("pr watch: card #{id}: a down; b down").size
  end

  def test_a_close_with_a_blank_why_or_no_time_is_refused_never_told
    id = card
    bad = [CLOSED.merge(why: ""), CLOSED.merge(why: nil, role: "local"), CLOSED.merge(closed_at: 0, number: 8),
           CLOSED.merge(closed_at: nil, number: 9), CLOSED.merge(number: nil),]
    approval_ci.closed = { id => bad }
    got = @m.pr_watch_pass
    assert_equal [id] * 5, got.map(&:first)
    assert_match(/PR #43 \("public"\) with a blank why/, got[0][1])
    assert_match(/PR #43 \("local"\) with a blank why/, got[1][1])
    assert_match(/PR #8 \("public"\) with closed_at 0, not a positive epoch/, got[2][1])
    assert_match(/PR #9 \("public"\) with closed_at nil, not a positive epoch/, got[3][1])
    assert_match(/PR #nil \("public"\) with no role or number/, got[4][1])
    assert_empty comments(id)
    assert_empty @m.pings(id)
    # the host reads the reason later: told then, once
    approval_ci.closed = { id => [CLOSED] }
    assert_equal [[id, :closed]], @m.pr_watch_pass
  end

  def test_a_port_without_closed_prs_watches_nothing
    @approval_ci = ApprovalCi.new
    m = store(board: KanbanTest.board_hash("local_v4"))
    card
    assert_equal [], m.pr_watch_pass
  end
end
