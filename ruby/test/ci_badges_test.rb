# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "json"

# scripts/ci/badges: the README badges' JSON, read from a CI build's logs. `publish` is only tested up to the network
# (it refuses before calling GitHub); the real PATCH is exercised by the default branch's Jenkins build.
class CiBadgesTest < Minitest::Test
  SCRIPT = File.expand_path("../../scripts/ci/badges", __dir__)

  RUBY_LOG = <<~LOG
    [2026-11-09T13:19:11.927Z] worker 40    3.1s    1 files  1 runs, 6 assertions, 0 failures, 0 errors, 0 skips
    [2026-11-09T13:19:11.927Z] TOTAL 313 runs, 2589 assertions, 0 failures, 0 errors, 2 skips · 41 workers · 4.5s
    [2026-11-09T13:19:11.927Z] coverage: line 95.45 % (3863 / 4047) · branch 84.76 % (1068 / 1260) · floor line 95 % · branch 84 % · 131 files
  LOG
  VITEST_LOG = <<~LOG
    [2026-11-09T13:19:13.700Z]  Test Files  20 passed (20)
    [2026-11-09T13:19:13.700Z] \e[2m      Tests \e[22m 156 passed\e[39m (156)
  LOG

  def setup = (@dir = Dir.mktmpdir("badges"))
  def teardown = FileUtils.rm_rf(@dir)

  def log(name, text) = File.join(@dir, name).tap { |p| File.write(p, text) }

  def render(*logs) = Open3.capture3(SCRIPT, "render", File.join(@dir, "out"), *logs)

  def badge(name) = JSON.parse(File.read(File.join(@dir, "out", "#{name}.json")))

  def assert_refused(pattern, *logs)
    _out, err, status = render(*logs)
    refute_predicate status, :success?
    assert_match pattern, err
    refute Dir.exist?(File.join(@dir, "out")), "nothing is written when a figure is missing"
  end

  def test_writes_the_three_endpoint_badges
    out, err, status = render(log("ruby.log", RUBY_LOG), log("frontend.log", VITEST_LOG))

    assert_predicate status, :success?, err
    assert_match "311 ruby + 156 vitest = 467 passed", out
    assert_equal({ "schemaVersion" => 1, "label" => "coverage", "message" => "95.45%", "color" => "brightgreen" },
                 badge("coverage"))
    assert_equal({ "schemaVersion" => 1, "label" => "branches", "message" => "84.76%", "color" => "yellowgreen" },
                 badge("branches"))
    assert_equal({ "schemaVersion" => 1, "label" => "tests", "message" => "467 passed", "color" => "brightgreen" },
                 badge("tests"))
  end

  def test_the_same_suite_on_two_databases_counts_once_with_the_lowest_coverage
    pg = RUBY_LOG.sub("line 95.45", "line 94.10").sub("branch 84.76", "branch 85.00")
    _out, err, status = render(log("all.log", RUBY_LOG + pg + VITEST_LOG))

    assert_predicate status, :success?, err
    assert_equal "94.10%", badge("coverage")["message"]
    assert_equal "84.76%", badge("branches")["message"]
    assert_equal "467 passed", badge("tests")["message"]
  end

  def test_refuses_run_counts_that_disagree
    assert_refused(/run counts disagree: 312 313/,
                   log("all.log", RUBY_LOG + RUBY_LOG.sub("TOTAL 313", "TOTAL 312") + VITEST_LOG))
  end

  def test_a_database_specific_skip_counts_the_fewest_passed
    pg = RUBY_LOG.sub("0 errors, 2 skips", "0 errors, 5 skips")
    _out, err, status = render(log("all.log", RUBY_LOG + pg + VITEST_LOG))

    assert_predicate status, :success?, err
    assert_equal "464 passed", badge("tests")["message"]
  end

  def test_refuses_a_failed_ruby_suite
    assert_refused(/Ruby suite failed/, log("all.log", RUBY_LOG.sub("0 failures, 0 errors, 2", "1 failures, 0 errors, 2") +
                                                     VITEST_LOG))
  end

  def test_refuses_missing_figures
    assert_refused(/no 'coverage: line/, log("all.log", RUBY_LOG.lines.first(2).join + VITEST_LOG))
    assert_refused(/no 'TOTAL N runs/, log("all.log", RUBY_LOG.lines.last + VITEST_LOG))
    assert_refused(/no vitest/, log("all.log", RUBY_LOG))
    assert_refused(/no vitest/, log("all.log", RUBY_LOG + "      Tests  150 passed | 6 skipped (156)\n"))
  end

  def test_publish_refuses_without_a_token_or_a_gist_id
    render(log("all.log", RUBY_LOG + VITEST_LOG))
    out = File.join(@dir, "out")
    _o, err, status = Open3.capture3({ "GIST_TOKEN" => "" }, SCRIPT, "publish", "0123456789abcdef0123", out)

    refute_predicate status, :success?
    assert_match(/GIST_TOKEN is empty — a token that may write gists is needed/, err)
    _o, err, status = Open3.capture3({ "GIST_TOKEN" => "t" }, SCRIPT, "publish", "not-a-gist", out)

    refute_predicate status, :success?
    assert_match(/not a gist id/, err)
  end

  def test_publish_refuses_a_token_that_is_not_token_shaped_without_printing_it
    render(log("all.log", RUBY_LOG + VITEST_LOG))
    _o, err, status = Open3.capture3({ "GIST_TOKEN" => "ghp_x y\"z" }, SCRIPT, "publish", "0123456789abcdef0123",
                                     File.join(@dir, "out"))

    refute_predicate status, :success?
    assert_match(/GIST_TOKEN has characters/, err)
    refute_match(/x y/, err, "the value is never printed")
  end

  # /proc/<pid>/cmdline (ps) is readable by every uid, so the token
  # must reach curl through a pipe (-H @/dev/fd/N), never as an argument.
  def test_publish_never_puts_the_token_on_curl_s_command_line
    render(log("all.log", RUBY_LOG + VITEST_LOG))
    token = "ghp_#{'t' * 36}"
    bin = File.join(@dir, "bin")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "curl"), <<~SH)
      #!/usr/bin/env bash
      printf '%s\\n' "$@" > "#{@dir}/curl-argv"
      for a in "$@"; do case "$a" in @/dev/fd/*) cat "${a#@}" > "#{@dir}/curl-header" ;; esac; done
      printf '000'
    SH
    File.chmod(0o755, File.join(bin, "curl"))
    env = { "GIST_TOKEN" => token, "PATH" => "#{bin}:#{ENV.fetch('PATH')}" }
    _o, err, status = Open3.capture3(env, SCRIPT, "publish", "0123456789abcdef0123", File.join(@dir, "out"))

    refute_predicate status, :success?
    assert_match(/HTTP 000/, err)
    argv = File.read(File.join(@dir, "curl-argv"))
    refute_includes argv, token, "the token was on curl's command line"
    assert_match(%r{^@/dev/fd/\d+$}, argv, "the Authorization header is read from a pipe")
    assert_equal "Authorization: Bearer #{token}", File.read(File.join(@dir, "curl-header"))
  end

end
