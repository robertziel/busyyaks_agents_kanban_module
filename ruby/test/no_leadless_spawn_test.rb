# frozen_string_literal: true

require "minitest/autorun"

# ARCHITECTURE (lead-first boards): the engine never starts an agent session on its own. Exactly ONE place
# in the library calls the host's launcher `start` — Team#start, which refuses a session under a lead while the
# board's lead does not run — and only the operator's Launch (Api#launch) and the lead's kanban_spawn reach it. No
# pass, no notifier, no watchdog starts anything; the spawn code that did (Api#spawn_pass, spawns_for) is gone, and
# this test fails the day it comes back.
class NoLeadlessSpawnTest < Minitest::Test
  LIB = File.expand_path("../lib/agents_kanban", __dir__)
  REACT = File.expand_path("../../react/src", __dir__)

  def sources = Dir[File.join(LIB, "*.rb")].to_h { |f| [File.basename(f), File.read(f)] }
  def code(text) = text.lines.reject { |l| l.strip.start_with?("#") }.join

  def test_only_team_calls_the_launchers_start
    callers = sources.select { |_, t| code(t).match?(/@launcher\.start\b|launcher\.start\(/) }.keys
    assert_equal ["team.rb"], callers
  end

  def test_only_the_operators_launch_and_the_leads_spawn_reach_team
    callers = sources.select { |_, t| code(t).match?(/Team\.new|\bteam\.start\b/) }.keys.sort
    assert_equal %w[api.rb tools.rb], callers
    api = code(sources.fetch("api.rb"))
    assert_equal 1, api.scan(/\bteam\.start\(/).size, "Api#launch only"
    tools = code(sources.fetch("tools.rb"))
    assert_equal 1, tools.scan(/Team\.new/).size, "kanban_spawn only"
  end

  def test_a_registration_is_written_by_team_and_by_kanban_register_only
    callers = sources.select { |_, t| code(t).match?(/\.register_session\(/) }.keys.sort
    assert_equal %w[team.rb tools.rb], callers
    assert_equal 1, code(sources.fetch("tools.rb")).scan(/\.register_session\(/).size
  end

  def test_the_spawn_code_is_gone
    gone = /\bspawn_pass\b|\bspawn_queue\b|\bspawn_columns\b|\bspawner_for\b|\bspawn_types\b|\bfollowed_launcher\b/
    sources.each { |name, t| refute_match(gone, t, "#{name} brings the leadless spawn back") }
    notifier = code(sources.fetch("notifier.rb"))
    refute_match(/spawn|launch/i, notifier, "the notifier starts nothing")
    react = Dir[File.join(REACT, "**/*.{ts,tsx}")].reject { |f| f.include?(".test.") }
    removed = /spawn_columns|spawns_for|spawn_launcher|launcher_follows/
    react.each { |f| refute File.read(f).match?(removed), "#{f} names the removed spawn config" }
  end
end
