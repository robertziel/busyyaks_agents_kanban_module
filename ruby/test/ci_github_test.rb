# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "json"

# scripts/ci/github (the Jenkinsfile's default-branch + commit-status calls) against a fake curl that answers like
# GitHub: it writes the body to -o, prints -w's %{http_code}, keeps the Authorization header it read from the pipe and
# the posted data. The script runs by its own shebang, so one that loses `#!/usr/bin/env bash` (and `<(…)`) fails here.
class CiGithubTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "scripts/ci/github")
  TOKEN = "ghp_#{'t' * 36}".freeze
  SHA = "a" * 40
  REPO = { "id" => 1, "default_branch" => "local", "parent" => { "default_branch" => "main" } }.freeze

  def setup
    @dir = Dir.mktmpdir("ci-github")
    FileUtils.mkdir_p(File.join(@dir, "bin"))
    File.write(File.join(@dir, "bin", "curl"), <<~SH)
      #!/usr/bin/env bash
      printf '%s\\n' "$@" > "#{@dir}/curl-argv"
      out=/dev/null
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -o) out=$2; shift ;;
          @/dev/fd/*) cat "${1#@}" > "#{@dir}/curl-header" ;;
          --data-binary) [ "$2" = @- ] && cat > "#{@dir}/curl-data"; shift ;;
        esac
        shift
      done
      [ "${FAKE_RC:-0}" = 0 ] || { echo "curl: (${FAKE_RC}) Failed to connect" >&2; printf '000'; exit "$FAKE_RC"; }
      cat "#{@dir}/body" > "$out"
      printf '%s' "$FAKE_CODE"
    SH
    File.chmod(0o755, File.join(@dir, "bin", "curl"))
  end

  def teardown = FileUtils.rm_rf(@dir)

  def run_github(*args, body: "", code: 200, rc: 0, token: TOKEN)
    File.write(File.join(@dir, "body"), body)
    env = { "GH_TOKEN" => token, "GH_REPO" => "owner/repo", "GIT_SHA" => SHA, "BUILD_URL" => "https://ci/job/1/",
            "PATH" => "#{@dir}/bin:#{ENV.fetch('PATH')}", "FAKE_CODE" => code.to_s, "FAKE_RC" => rc.to_s, }
    out, err, status = Open3.capture3(env, SCRIPT, *args, chdir: @dir)
    refute_includes out + err, TOKEN, "the token was printed"
    argv = File.join(@dir, "curl-argv")
    refute_includes File.read(argv), TOKEN, "the token was on curl's command line" if File.exist?(argv)
    [out, err, status]
  end

  def header = File.read(File.join(@dir, "curl-header"))

  def test_runs_by_its_bash_shebang
    assert_equal "#!/usr/bin/env bash\n", File.open(SCRIPT, &:gets)
    assert File.executable?(SCRIPT)
  end

  def test_default_branch_reads_the_repo_s_own_branch_through_a_pipe
    out, _e, status = run_github("default-branch", body: JSON.pretty_generate(REPO))

    assert_predicate status, :success?
    assert_equal "local\n", out
    assert_equal "Authorization: Bearer #{TOKEN}", header
    assert_match(%r{^@/dev/fd/\d+$}, File.read(File.join(@dir, "curl-argv")))
  end

  def test_default_branch_of_a_fork_on_one_line_is_its_own_not_the_parent_s
    out, _e, status = run_github("default-branch", body: { "parent" => { "default_branch" => "main" },
                                                           "default_branch" => "local", }.to_json)

    assert_predicate status, :success?
    assert_equal "local\n", out
  end

  def test_default_branch_from_a_body_over_200_kb
    out, _e, status = run_github("default-branch", body: JSON.pretty_generate(REPO.merge("pad" => "x" * 300_000)))

    assert_predicate status, :success?
    assert_equal "local\n", out
  end

  def test_default_branch_missing_says_so
    _o, err, status = run_github("default-branch", body: { "id" => 1 }.to_json)

    refute_predicate status, :success?
    assert_match(%r{GitHub's answer for owner/repo holds no default_branch}, err)
  end

  def test_default_branch_not_json_says_so
    _o, err, status = run_github("default-branch", body: "<html>")

    refute_predicate status, :success?
    assert_match(/holds no default_branch/, err)
  end

  def test_default_branch_on_a_refused_token_says_so
    _o, err, status = run_github("default-branch", body: { "message" => "Bad credentials" }.to_json, code: 401)

    refute_predicate status, :success?
    assert_match(%r{HTTP 401 reading owner/repo \(Bad credentials\) — check credential github-pat}, err)
  end

  def test_default_branch_unreachable_says_so
    _o, err, status = run_github("default-branch", rc: 7)

    refute_predicate status, :success?
    assert_match(%r{cannot reach GitHub to read owner/repo — check the network}, err)
  end

  def test_a_token_that_is_not_token_shaped_is_refused_without_printing_it
    _o, err, status = run_github("default-branch", token: "ghp_x y\"z")

    refute_predicate status, :success?
    assert_match(/GH_TOKEN has characters a GitHub token never has — check credential github-pat/, err)
    refute_match(/x y/, err)
    refute_path_exists File.join(@dir, "curl-argv"), "GitHub was called with a bad token"
  end

  def test_status_posts_the_payload_as_json
    out, _e, status = run_github("status", "success", %(Gates "passed" — 100 %), body: "{}", code: 201)

    assert_predicate status, :success?
    assert_equal "github: status success posted for aaaaaaaa\n", out
    assert_equal({ "context" => "jenkins/ci", "description" => %(Gates "passed" — 100 %), "state" => "success",
                   "target_url" => "https://ci/job/1/", }, JSON.parse(File.read(File.join(@dir, "curl-data"))))
    assert_match(%r{^https://api\.github\.com/repos/owner/repo/statuses/#{SHA}$}, File.read(File.join(@dir, "curl-argv")))
    assert_equal "Authorization: Bearer #{TOKEN}", header
  end

  def test_status_refused_says_why
    _o, err, status = run_github("status", "failure", "x", body: { "message" => "Not Found" }.to_json, code: 404)

    refute_predicate status, :success?
    assert_match(%r{refused status failure for owner/repo@#{SHA} \(HTTP 404: Not Found\) — check credential github-pat},
                 err)
  end

  def test_status_unreachable_says_so
    _o, err, status = run_github("status", "pending", "x", rc: 6)

    refute_predicate status, :success?
    assert_match(/cannot reach GitHub to post status pending .* — check the network/, err)
  end

  def test_status_refuses_an_unknown_state
    _o, err, status = run_github("status", "green", "x")

    refute_predicate status, :success?
    assert_match(/'green' is not a GitHub status state/, err)
  end

  # — (3 bytes) catches a byte cut; é (U+00E9, which perl prints as one Latin-1 byte without ->utf8) a missing encode
  def test_status_cuts_the_description_at_140_characters_never_inside_one
    %w[— é].each do |char|
      _o, _e, status = run_github("status", "success", "#{'x' * 139}#{char} and more", body: "{}", code: 201)

      assert_predicate status, :success?
      sent = File.read(File.join(@dir, "curl-data"), encoding: "UTF-8")
      assert_predicate sent, :valid_encoding?, "#{char}: the payload is not UTF-8"
      assert_equal "#{'x' * 139}#{char}", JSON.parse(sent)["description"]
    end
  end

  def test_without_perl_json_pp_it_says_so
    File.write(File.join(@dir, "bin", "perl"), "#!/usr/bin/env bash\necho \"Can't locate JSON/PP.pm\" >&2\nexit 2\n")
    File.chmod(0o755, File.join(@dir, "bin", "perl"))
    %w[default-branch status].each do |cmd|
      _o, err, status = run_github(cmd, *(cmd == "status" ? %w[success x] : []))

      refute_predicate status, :success?
      assert_match(/perl with JSON::PP is needed to read and write GitHub's JSON/, err)
    end
    refute_path_exists File.join(@dir, "curl-argv"), "GitHub was called without a JSON parser"
  end

  # Every GitHub call goes through lib/github-api.sh's gh_curl: no other curl names a token or an Authorization header,
  # and the Jenkinsfile runs no curl at all.
  def test_no_token_reaches_curl_s_command_line_anywhere
    refute_match(/\bcurl\b|Authorization:/, File.read(File.join(ROOT, "Jenkinsfile")).gsub(%r{^\s*//.*$}, ""))
    Dir[File.join(ROOT, "scripts/ci/**/*")].select { |f| File.file?(f) }.each do |f|
      code = File.readlines(f).grep_v(/^\s*#/)
      code.grep(/Authorization/).each do |l|
        assert_match(/^\s*curl -H @<\(printf 'Authorization: Bearer %s' "\$\{!var\}"\)/, l, "#{f}: #{l}")
      end
      code.grep(/(?<!gh_)\bcurl\b/).grep(/TOKEN/).each { |l| flunk("#{f}: a token next to a plain curl: #{l}") }
    end
  end
end
