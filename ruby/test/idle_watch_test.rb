# frozen_string_literal: true

require "test_helper"
require "stringio"

# The idle watch (config.idle_watch): CI finished + owner silent → ping once, comment once; owner acted → nothing;
# a live owner quiet for X hours → one comment; the port failing skips the step; the config is strict.
class IdleWatchTest < Minitest::Test
  include KanbanTest::Setup

  N = 600   # ci_ping_after_minutes 10
  M = 1200  # ci_comment_after_minutes 20
  X = 14_400 # owner_idle_hours 4

  class FakeCi
    attr_accessor :pr, :commit, :down
    # down: true (every card) or the ids of the cards whose PR the port cannot answer
    def pr_checks(card)
      raise AgentsKanban::Delivery::Unavailable, "github down" if @down == true || Array(@down).include?(card[:id])

      @pr
    end
    def last_commit_at(_card) = @commit
  end

  class FakeClient
    attr_reader :sent
    def initialize = (@sent = []; @live = ["shop"])
    def notify(session:, socket:, text:) = (@sent << [session, text]; { "ok" => true })
    def agents = { "age_s" => 1, "interval_s" => 5, "sessions" => [] }
    def sessions = @live.map { |n| { "name" => n } }
    def dialog(**) = { "ok" => true, "dialog" => nil }
    def drop(name) = @live.delete(name)
  end

  def setup
    super
    @id = kb.create(slug: "p", title: "ship the thing", by: "lead", column: "doing")
    kb.update(@id, { "assignee" => "lead" }, by: "lead")
    kb.set_owner(@id, session: "shop", by: "lead")
    @ci = FakeCi.new
    @client = FakeClient.new
    @log = StringIO.new
    @n = AgentsKanban::Notifier.new(kb, client: @client, ci: @ci, clock: -> { @now }, grace: 60, log: @log)
    @t0 = @now # the owner's last activity
    @fin = @t0 + 100
  end

  def finish(state) = @ci.pr = { number: 112, state: state, finished_at: @fin }
  def watch = @n.watch
  def system_comments = db[:"#{KanbanTest::PREFIX}card_activity"].where(card_id: @id, author: "busyyaks", kind: "comment").all
  def pings = db[:"#{KanbanTest::PREFIX}card_pings"].where(card_id: @id, reason: "ci_idle").all

  def test_ping_on_green_only_after_n_minutes
    finish("success")
    @now = @fin + N - 1
    watch
    assert_empty pings
    @now = @fin + N
    watch
    assert_equal 1, pings.size
    assert_includes pings.first[:text], "CI on PR #112 finished (success) — hand off or fix"
    @n.deliver
    assert_equal ["shop"], @client.sent.map(&:first)
  end

  def test_ping_on_red
    finish("failure")
    @now = @fin + N
    watch
    assert_includes pings.first[:text], "CI on PR #112 finished (failure) — hand off or fix"
  end

  def test_no_ping_when_checks_are_pending_or_no_pr
    @ci.pr = { number: 112, state: "pending", finished_at: nil }
    @now = @fin + N * 5
    watch
    @ci.pr = nil
    watch
    assert_empty pings
    assert_empty system_comments
  end

  def test_no_ping_when_the_owner_acted_after_ci_finished
    finish("success")
    @now = @fin + 30
    kb.comment(@id, body: "on it, fixing", author: "lead")
    @now = @fin + N * 10
    watch
    assert_empty pings
    assert_empty system_comments
  end

  def test_the_operator_acting_counts_as_activity
    finish("success")
    @now = @fin + 30
    kb.comment(@id, body: "status?", author: "operator@example.com", operator: true)
    @now = @fin + N * 10
    watch
    assert_empty pings
  end

  def test_comment_m_minutes_after_the_ping_and_dedupe
    finish("success")
    @now = @fin + N
    watch
    ping_at = @now
    @now = ping_at + M - 1
    watch
    assert_empty system_comments
    @now = ping_at + M
    watch
    assert_equal 1, system_comments.size
    assert_match(/PR #112 finished \(success\)/, system_comments.first[:body])
    4.times { @now += 3600; watch } # many passes later: still one ping, one comment
    assert_equal 1, pings.size
    assert_equal 1, system_comments.count { |c| c[:body].include?("PR #112") }
  end

  def test_owner_acting_between_ping_and_comment_cancels_the_comment
    finish("failure")
    @now = @fin + N
    watch
    @now += 60
    kb.comment(@id, body: "fixing", author: "lead")
    @now += M
    watch
    assert_empty system_comments
  end

  def test_a_new_ci_completion_pings_again
    finish("failure")
    @now = @fin + N
    watch
    @n.deliver
    @now += 60
    kb.comment(@id, body: "pushed a fix", author: "lead")
    @fin = @now + 100
    finish("success")
    @now = @fin + N
    # the owner's comment (before the new finish) is older than the new completion → idle again → a second ping
    watch
    assert_equal 2, pings.size, "each CI completion pings once"
  end

  def test_no_owner_session_still_comments_but_pings_nobody
    begin
      kb.set_owner(@id, session: nil, by: "lead")
    rescue StandardError
      db[:"#{KanbanTest::PREFIX}cards"].where(id: @id).update(owner_session: nil)
    end
    finish("success")
    @now = @fin + N
    watch
    assert_empty pings
    @now += M
    watch
    assert_match(/no owner session/, system_comments.first[:body])
  end

  def test_idle_owner_flagged_once_per_stretch
    @ci.pr = nil
    @now = @t0 + X - 1
    watch
    assert_empty system_comments
    @now = @t0 + X
    watch
    assert_equal 1, system_comments.size
    assert_match(/no activity for 4 h/, system_comments.first[:body])
    watch
    @now += 3600
    watch
    assert_equal 1, system_comments.size, "the system's own comment is not activity, and the stretch is flagged once"
  end

  def test_recent_commit_or_dead_owner_is_not_idle
    @ci.pr = nil
    @now = @t0 + X + 10
    @ci.commit = @now - 60
    watch
    assert_empty system_comments
    @ci.commit = nil
    @client.drop("shop")
    watch
    assert_empty system_comments, "a gone owner is the watchdog's job, not the idle flag"
  end

  def test_port_down_skips_the_step_loudly
    @ci.down = true
    @now = @fin + N * 5
    watch
    assert_match(/idle watch: CI skipped: github down on card #{@id}/, @log.string)
    assert_empty pings
  end

  # one card the port cannot answer is skipped and said; the others still get their CI ping
  def test_one_card_the_port_cannot_answer_does_not_silence_the_others
    other = kb.create(slug: "p", title: "the other", by: "lead", column: "doing")
    kb.set_owner(other, session: "shop", by: "lead")
    @ci.down = [@id]
    finish("success")
    @now = @fin + N * 5
    watch
    assert_match(/idle watch: CI skipped: github down on card #{@id}/, @log.string)
    assert_empty pings
    other_pings = db[:"#{KanbanTest::PREFIX}card_pings"].where(card_id: other, reason: "ci_idle").count
    assert_equal 1, other_pings, @log.string
  end

  def test_config_is_strict_and_the_port_required
    raw = JSON.parse(JSON.generate(config.to_h))
    %w[ci_ping_after_minutes ci_comment_after_minutes owner_idle_hours].each do |k|
      bad = raw.merge("idle_watch" => raw["idle_watch"].reject { |kk, _| kk == k })
      assert_raises(AgentsKanban::ConfigError) { AgentsKanban::HostConfig.new(bad) }
    end
    with_watch = ->(over) { raw.merge("idle_watch" => raw["idle_watch"].merge(over)) }
    assert_raises(AgentsKanban::ConfigError) { AgentsKanban::HostConfig.new(with_watch.call("owner_idle_hours" => 0)) }
    # the column is the board's working one
    assert_raises(AgentsKanban::ConfigError) { AgentsKanban::HostConfig.new(with_watch.call("column" => "doing")) }
    assert_raises(AgentsKanban::ConfigError) { AgentsKanban::HostConfig.new(raw.reject { |k, _| k == "idle_watch" }) }
    assert_raises(AgentsKanban::ConfigError) { AgentsKanban::Notifier.new(kb, client: @client, log: StringIO.new) }
    assert_nil AgentsKanban::HostConfig.new(raw.merge("idle_watch" => nil)).idle_watch
  end
end
