# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"

# The gate scripts' own logic: scripts/ci/test.sh (secrets, audit, all, host_path) and scripts/hooks/run, each copied
# into a throwaway git repo and run there with a stub `docker` on PATH that records its argv, answers `inspect` with
# STUB_MOUNT as the container's one mount (the fixture by default, so host_path resolves inside a container too) and
# exits DOCKER_EXIT for a call whose argv matches DOCKER_FAIL (an ERE), 0 otherwise. Every refusal must fail BEFORE any
# container starts; a passing run must hand Docker exactly the mounts and flags the gate depends on; a failing
# container must fail its stage and `all`. The containers themselves (gitleaks, overcommit, the suites) run in the real
# CI stages.
class CiGatesTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__) # ruby/test → the repo root
  TEST_SH = File.join(ROOT, "scripts/ci/test.sh")
  HOOKS_RUN = File.join(ROOT, "scripts/hooks/run")

  STUB_DOCKER = <<~SH
    #!/bin/sh
    printf '%s\\n' "$*" >> "$DOCKER_LOG"
    case "$1" in
      inspect) printf '%s|%s\\n' "$STUB_MOUNT" "$STUB_MOUNT" ;;
      image) exit 0 ;;
      *) if [ -n "$DOCKER_FAIL" ] && printf '%s' "$*" | grep -qE -- "$DOCKER_FAIL"; then exit "$DOCKER_EXIT"; fi ;;
    esac
  SH
  # scripts/hooks/image builds the hooks image from a dozen inputs; the fixture's prints a tag (run's own logic is tested)
  STUB_IMAGE = "#!/usr/bin/env bash\necho agents-kanban-hooks:stub\n"
  # the lint wrappers and the lint image script, for `audit` / `all` (their own runs are the lint stage's business)
  STUB_OK = "#!/bin/sh\necho stub\n"
  # the stages `all` runs, as the script lists them
  STAGES = File.read(TEST_SH)[/^  all\) all_suites (.+) ;;$/, 1].split

  def setup
    @dir = File.realpath(Dir.mktmpdir("ci-gates"))
    @bin = File.join(@dir, "bin")
    @log = File.join(@dir, "docker.log")
    FileUtils.mkdir_p(@bin)
    write_exe(File.join(@bin, "docker"), STUB_DOCKER)
  end

  def teardown = FileUtils.rm_rf(@dir)

  def env(path: "#{@bin}:#{ENV.fetch('PATH')}", fail: nil, code: 1, mount: @dir)
    { "PATH" => path, "DOCKER_LOG" => @log, "STUB_MOUNT" => mount, "DOCKER_FAIL" => fail.to_s, "DOCKER_EXIT" => code.to_s,
      "GIT_AUTHOR_NAME" => "ci", "GIT_AUTHOR_EMAIL" => "ci@example.invalid",
      "GIT_COMMITTER_NAME" => "ci", "GIT_COMMITTER_EMAIL" => "ci@example.invalid",
      "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_INDEX_FILE" => nil,
      "BUILD_TAG" => nil, }
  end

  def write_exe(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    File.chmod(0o755, path)
  end

  def sh!(*cmd, chdir:)
    out, status = Open3.capture2e(env, *cmd, chdir: chdir)
    assert_predicate status, :success?, "#{cmd.join(' ')}: #{out}"
    out
  end

  def run_in(dir, *cmd, **opts) = Open3.capture3(env(**opts), *cmd, chdir: dir)

  def docker_calls = File.exist?(@log) ? File.readlines(@log, chomp: true) : []

  def docker_runs = docker_calls.select { _1.start_with?("run ") }

  def one_run
    runs = docker_runs
    assert_equal 1, runs.size, "one container: #{runs}"
    runs.first
  end

  # a repo holding the given scripts (and extra tracked files) in three commits
  def repo(name, scripts, extra = {})
    dir = File.join(@dir, name)
    sh!("git", "init", "-q", "-b", "main", dir, chdir: @dir)
    scripts.each { |rel, src| write_exe(File.join(dir, rel), src.start_with?("#!") ? src : File.read(src)) }
    extra.each do |rel, body|
      FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
      File.write(File.join(dir, rel), body)
    end
    3.times do |i|
      File.write(File.join(dir, "file.txt"), i.to_s)
      sh!("git", "add", "-A", chdir: dir)
      sh!("git", "commit", "-q", "-m", "commit #{i}", chdir: dir)
    end
    dir
  end

  def ci_repo(extra = {}) = repo("ci", { "scripts/ci/test.sh" => TEST_SH }, extra)

  # everything `all` touches besides docker: the lint wrappers and the lint image
  def full_ci_repo
    stubs = %w[scripts/lint/image scripts/lint/rubocop scripts/lint/shellcheck].to_h { [_1, STUB_OK] }
    repo("full", { "scripts/ci/test.sh" => TEST_SH }.merge(stubs))
  end

  def hooks_repo = repo("hooks", { "scripts/hooks/run" => HOOKS_RUN, "scripts/hooks/image" => STUB_IMAGE })

  # ── scripts/ci/test.sh secrets ──

  def test_secrets_refuses_a_shallow_clone_before_any_container
    full = ci_repo
    sh!("git", "clone", "-q", "--depth", "1", "file://#{full}", "shallow", chdir: @dir)
    _out, err, status = run_in(File.join(@dir, "shallow"), "scripts/ci/test.sh", "secrets")

    assert_equal 1, status.exitstatus
    assert_match "secrets: shallow checkout (1 commits) — the full history is not here to scan", err
    assert_empty docker_runs
  end

  def test_secrets_refuses_an_in_tree_gitleaks_allowlist
    [".gitleaksignore", "nested/.gitleaks.toml"].each_with_index do |file, i|
      dir = repo("allow#{i}", { "scripts/ci/test.sh" => TEST_SH }, file => "x\n")
      _out, err, status = run_in(dir, "scripts/ci/test.sh", "secrets")

      assert_equal 1, status.exitstatus, file
      assert_match "secrets: refused — #{file} in the tree; findings are fixed, never allowlisted", err
    end
    assert_empty docker_runs
  end

  def test_secrets_scans_the_full_history_with_allow_comments_ignored
    dir = ci_repo
    out, err, status = run_in(dir, "scripts/ci/test.sh", "secrets")

    assert_predicate status, :success?, err
    assert_match "over 3 commits", out
    run = one_run
    assert_includes run, "-v #{dir}:/repo:ro"
    assert_includes run, "-w /tmp"
    assert run.end_with?("git --redact --verbose --no-banner --exit-code 1 --ignore-gitleaks-allow /repo"), run
  end

  def test_secrets_fails_when_gitleaks_finds_something
    dir = ci_repo
    _out, _err, status = run_in(dir, "scripts/ci/test.sh", "secrets", fail: "gitleaks")

    assert_equal 1, status.exitstatus
  end

  def test_secrets_in_a_worktree_mounts_the_shared_git_dir
    main = ci_repo
    sh!("git", "worktree", "add", "-q", File.join(@dir, "wt"), chdir: main)
    _out, err, status = run_in(File.join(@dir, "wt"), "scripts/ci/test.sh", "secrets")

    assert_predicate status, :success?, err
    assert_includes one_run, "-v #{main}/.git:#{main}/.git:ro"
  end

  def test_host_path_never_guesses_a_checkout_on_no_mount
    dir = ci_repo
    _out, err, status = run_in(dir, "scripts/ci/test.sh", "secrets", mount: "/elsewhere")

    if File.exist?("/.dockerenv")
      # in a container (the CI suites always are): the checkout is on none of its mounts → refused, nothing started
      assert_equal 1, status.exitstatus
      assert_match "ci: #{dir} is not on any mount of container", err
      assert_empty docker_runs
    else
      # on a host the checkout's own path is the daemon's: no mount is asked for
      assert_predicate status, :success?, err
      refute docker_calls.any? { _1.start_with?("inspect") }, docker_calls.inspect
    end
  end

  # ── scripts/ci/test.sh audit / all ──

  def test_audit_fails_when_either_lockfile_has_an_advisory_and_still_runs_both
    dir = full_ci_repo
    [[nil, 0], ["bundle-audit check --update", 1], ["npm audit --audit-level=low", 1]].each do |fail, code|
      FileUtils.rm_f(@log)
      _out, err, status = run_in(dir, "scripts/ci/test.sh", "audit", fail: fail)

      assert_equal code, status.exitstatus, "#{fail.inspect}: #{err}"
      assert_equal 2, docker_runs.size, "both halves run even when one fails: #{docker_runs}"
    end
  end

  def test_all_runs_every_stage_and_fails_when_one_fails
    dir = full_ci_repo
    out, err, status = run_in(dir, "scripts/ci/test.sh", "all")

    assert_predicate status, :success?, out + err
    assert_match "ci: #{STAGES.map { "#{_1} exit 0" }.join(' · ')}", out

    out, _err, status = run_in(dir, "scripts/ci/test.sh", "all", fail: "gitleaks")

    assert_equal 1, status.exitstatus
    assert_match "ci: #{STAGES.map { "#{_1} exit #{_1 == 'secrets' ? 1 : 0}" }.join(' · ')}", out
  end

  def test_an_unknown_stage_is_a_usage_error
    _out, err, status = run_in(ci_repo, "scripts/ci/test.sh", "nope")

    assert_equal 2, status.exitstatus
    assert_match "usage:", err
  end

  # ── scripts/hooks/run ──

  def worktree_config(dir)
    Open3.capture2(env, "git", "config", "--local", "--get", "extensions.worktreeConfig", chdir: dir).first.strip
  end

  def test_hooks_run_needs_a_hook_name
    _out, err, status = run_in(hooks_repo, "scripts/hooks/run")

    refute_predicate status, :success?
    assert_match "usage: scripts/hooks/run pre-commit|sign", err
  end

  def test_hooks_run_refuses_without_docker
    nodocker = File.join(@dir, "nodocker")
    FileUtils.mkdir_p(nodocker)
    %w[bash git].each { |tool| File.symlink(which(tool), File.join(nodocker, tool)) }
    _out, err, status = run_in(hooks_repo, "scripts/hooks/run", "pre-commit", path: nodocker)

    assert_equal 1, status.exitstatus
    assert_match "hooks: docker not found — the hooks run only in Docker; nothing was checked, so the commit is " \
                 "refused", err
    assert_empty docker_calls
  end

  def test_hooks_run_refuses_a_hook_while_signatures_are_shared
    dir = hooks_repo
    [nil, "false"].each do |value|
      sh!("git", "config", "--local", "extensions.worktreeConfig", value, chdir: dir) if value
      _out, err, status = run_in(dir, "scripts/hooks/run", "pre-commit")

      assert_equal 1, status.exitstatus
      assert_match "extensions.worktreeConfig is #{value || 'not set'} in this repo's config (--local)", err
      assert_match "run scripts/hooks/run sign", err
      assert_equal value.to_s, worktree_config(dir), "a refused hook changes no config"
    end
    assert_empty docker_calls
  end

  def test_sign_turns_per_worktree_signatures_on_and_signs
    dir = hooks_repo
    _out, err, status = run_in(dir, "scripts/hooks/run", "sign")

    assert_predicate status, :success?, err
    assert_match "extensions.worktreeConfig turned on", err
    assert_equal "true", worktree_config(dir)
    assert one_run.end_with?("agents-kanban-hooks:stub sign"), one_run
  end

  def test_pre_commit_hands_docker_the_index_and_the_git_dir_never_the_working_tree
    dir = hooks_repo
    sh!("git", "config", "--local", "extensions.worktreeConfig", "true", chdir: dir)
    _out, err, status = run_in(dir, "scripts/hooks/run", "pre-commit")

    assert_predicate status, :success?, err
    run = one_run
    git = File.join(dir, ".git")
    assert_includes run, "-e GIT_DIR=#{git} -e GIT_WORK_TREE=/deps/snap -e GIT_INDEX_FILE=/tmp/index"
    assert_includes run, "-e GIT_AUTHOR_NAME=ci -e GIT_AUTHOR_EMAIL=ci@example.invalid"
    assert_includes run, "-v #{git}:#{git} -v #{git}/index:/deps/index.in:ro --tmpfs /deps/snap:exec,mode=1777"
    assert run.end_with?("agents-kanban-hooks:stub pre-commit"), run
    assert_equal 2, run.scan(" -v ").size, "only the git dir and the index are mounted: #{run}"
  end

  def test_pre_commit_fails_when_the_hooks_fail
    dir = hooks_repo
    sh!("git", "config", "--local", "extensions.worktreeConfig", "true", chdir: dir)
    _out, _err, status = run_in(dir, "scripts/hooks/run", "pre-commit", fail: "pre-commit$", code: 3)

    assert_equal 3, status.exitstatus
  end

  def which(tool)
    found = ENV.fetch("PATH").split(":").map { File.join(_1, tool) }.find { File.executable?(_1) }
    found or raise "#{tool} not on PATH"
  end
end
