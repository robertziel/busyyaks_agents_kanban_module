# frozen_string_literal: true

require "test_helper"
require "shellwords"

# The HOST config (SPEC § 2): settings only — launchers, agent types (whose takes / spawns_for name column TYPES), the
# caps, the enums, the handoff requirements, the idle-watch timings. The boards (columns + workflow) are in the
# database: board_test.rb.
class HostConfigTest < Minitest::Test
  C = AgentsKanban::HostConfig
  E = AgentsKanban::ConfigError

  def coding = C.load(File.join(KanbanTest::ROOT, "fixtures/boards/coding.json"))
  def content = C.load(File.join(KanbanTest::ROOT, "fixtures/boards/content.json"))
  def raw = JSON.parse(File.read(File.join(KanbanTest::ROOT, "fixtures/boards/coding.json")))

  def test_coding_fixture_is_busyyaks_host_config
    assert_equal "busyyaks", coding.system_author
    assert_equal %w[high medium low], coding.priorities
    assert_equal [true, true, 20, true], coding.handoff.to_h.values
    refute coding.dependencies
    assert_equal({ ci_ping_after_minutes: 10, ci_comment_after_minutes: 20, owner_idle_hours: 4 }, coding.idle_watch.to_h)
    assert coding.frozen?
    # the content host: no handoff gate, dependencies enforced, its own sessions
    assert_nil content.handoff
    assert content.dependencies
    assert_nil content.idle_watch
    assert coding.green_ci_gate?
    assert_nil content.approval
    refute content.green_ci_gate?
    refute AgentsKanban::HostConfig.new(raw.merge("approval" => { "requires_green_ci" => false })).green_ci_gate?
    bad = raw.merge("approval" => { "requires_green_ci" => "yes" })
    assert_match(/approval.requires_green_ci must be/,
                 assert_raises(AgentsKanban::ConfigError) { AgentsKanban::HostConfig.new(bad) }.message)
    assert_raises(AgentsKanban::ConfigError) { AgentsKanban::HostConfig.new(raw.merge("approval" => {})) }
    missing = raw.tap { |h| h.delete("approval") }
    assert_match(/missing keys approval/,
                 assert_raises(AgentsKanban::ConfigError) { AgentsKanban::HostConfig.new(missing) }.message)
    assert_equal ["news_articles", "news-articles-*"], content.owner_sessions
    assert_nil coding.owner_sessions
    assert content.owner_session?("news_articles") && content.owner_session?("news-articles-12")
    refute %w[coding_lead acme_content_app xnews_articles].any? { |s| content.owner_session?(s) }
    assert coding.owner_session?("anything")
  end

  def test_digest_matches_the_json_the_client_gets
    assert_equal Digest::SHA256.hexdigest(JSON.generate(coding.to_h)), coding.digest
    assert_equal raw, coding.to_h
    assert_equal coding.digest, C.new(raw).digest
    refute_equal coding.digest, content.digest
  end

  def test_refusals_name_the_key
    bad = ->(mut) { r = raw; mut.call(r); assert_raises(E) { C.new(r) }.message }
    assert_match(/missing keys launchers/, bad.(->(r) { r.delete("launchers") }))
    assert_match(/unknown keys extra/, bad.(->(r) { r["extra"] = 1 }))
    assert_match(/unknown keys columns, gates \(columns, gates and workflow live in the database now: SPEC § 2\)/,
                 bad.(->(r) { r["columns"] = []; r["gates"] = {} }))
    assert_match(/label_colors must include gray/, bad.(->(r) { r["label_colors"] = ["red"] }))
    assert_match(/dependencies must be true or false/, bad.(->(r) { r["dependencies"] = { "done" => ["merged"] } }))
    assert_match(
      /handoff must be an object with exactly requires_pr_url, requires_ci_url, qa_min_chars, ui_change_needs_screenshots/,
      bad.(->(r) { r["handoff"].delete("qa_min_chars") }),
    )
    assert_match(/handoff.qa_min_chars must be an integer/, bad.(->(r) { r["handoff"]["qa_min_chars"] = -1 }))
    assert_match(/attachment_url_prefix must start with/, bad.(->(r) { r["attachment_url_prefix"] = "api/x/" }))
    assert_match(/host config must be an object/, assert_raises(E) { C.new([]) }.message)
    assert_match(/table_prefix must be/, bad.(->(r) { r["table_prefix"] = "Cards" }))
    assert_match(/owner_sessions must be null or a non-empty list/, bad.(->(r) { r["owner_sessions"] = [] }))
    assert_match(/owner_sessions must be null or a non-empty list/, bad.(->(r) { r["owner_sessions"] = ["a b"] }))
    assert_match(/owner_sessions: duplicate pattern/, bad.(->(r) { r["owner_sessions"] = %w[x x] }))
    assert_match(/missing keys owner_sessions/, bad.(->(r) { r.delete("owner_sessions") }))
    assert_match(/theme: "--x" is not a --ak-\* variable/, bad.(->(r) { r["theme"] = { "--x" => "red" } }))
    assert_match(/theme: --ak-ink must be/, bad.(->(r) { r["theme"] = { "--ak-ink" => "red; }" } }))
    # nothing that could end, break or swallow a host's <style>:root{…} rule
    broken = ["red</style><script>x()", "red { x", "red /* x", "red \\", '"Inter', "'Inter", "rgba(0, 0, 0", "a)(b", "[x]",
              "red !important",]
    broken.each do |v|
      msg = bad.(->(r) { r["theme"] = { "--ak-ink" => v } })
      assert_match(/theme: --ak-ink must be a CSS value of letters, digits, spaces/, msg, v)
    end
    # every real token value passes: the engine's own defaults (kanban.css .ak-root) and the shapes hosts map
    defaults = File.read(File.expand_path("../../react/src/styles/kanban.css", __dir__))[/^\.ak-root \{(.*?)^\}/m, 1]
                   .scan(/(--ak-[a-z0-9-]+):\s*([^;]+);/).to_h
    assert_operator defaults.size, :>=, 40
    ok = raw.merge("theme" => defaults.merge("--ak-ink" => "var(--ink)", "--ak-mono" => 'ui-monospace, "SF Mono", Menlo',
                                             "--ak-board-height" => "calc(100vh - 120px)"))
    assert_equal ok["theme"], C.new(ok).theme
    assert_equal ["", "kanban_"], [coding.table_prefix, content.table_prefix]
    assert_match(/not found/, assert_raises(E) { C.load("/nonexistent.json") }.message)
  end

  def test_yaml_loads_like_json_and_the_example_is_complete
    Dir.mktmpdir do |d|
      File.write(File.join(d, "b.yml"), YAML.dump(raw))
      assert_equal coding.digest, C.load(File.join(d, "b.yml")).digest
      File.write(File.join(d, "bad.yml"), "launchers: [\n")
      assert_match(/bad.yml/, assert_raises(E) { C.load(File.join(d, "bad.yml")) }.message)
    end
    ex = C.load(File.join(KanbanTest::ROOT, "config.example.yml"))
    assert_equal C::KEYS.sort, ex.to_h.keys.sort
    # the example is a stranger's starting point: one plain `claude` launcher, no model names, Claude Code's default
    # permission mode (bypass only as a commented, explained option), no caps
    assert_equal [["claude", "claude_code", "claude", [], false]],
                 ex.launchers.map { |l| [l.key, l.kind, l.command, l.args, l.via_shell] }
    assert_equal %w[lead team plain], ex.agent_type_keys
    assert(ex.agent_types.all? { |t| t.launchers == ["claude"] && t.model.nil? && t.spawn_launcher.nil? })
    assert_equal %w[claude claude claude], ex.agent_types.map { |t| t.launcher!(nil) }, "one launcher = unambiguous"
    assert_nil ex.concurrency.max_sessions
    text = File.read(File.join(KanbanTest::ROOT, "config.example.yml"))
    live = text.lines.reject { |x| x.lstrip.start_with?("#") }.join
    refute_match(/bypassPermissions|opus|sonnet|localclaude|busyyaks|content_app/i, live)
    # the example's board template (the shape a fresh host seeds) is a valid board on it
    tpl = YAML.safe_load_file(File.join(KanbanTest::ROOT, "board.example.yml"))
    assert_equal %w[backlog todo doing qa human_check ready merged], AgentsKanban::Board.new(tpl, host: ex).keys
    assert_equal 24, ex.flags.reminder_hours
    assert_equal [3, "unresolved", "red", %w[local_agent_review public_agent_review]], ex.review_loop.to_h.values
  end

  def test_launchers_are_required_and_validated
    bad = ->(mut) { r = raw; mut.call(r); assert_raises(E) { C.new(r) }.message }
    assert_match(/launchers must be a non-empty list/, bad.(->(r) { r["launchers"] = [] }))
    assert_match(/launchers\[\] must be an object with exactly key, label, kind, command, args, via_shell/,
                 bad.(->(r) { r["launchers"] = [{ "command" => "claude" }] }))
    assert_match(/must not set --model: Launch sets --model \(the agent type's model\)/,
                 bad.(->(r) { r["launchers"][0]["args"] = ["--model", "x"] }))
    assert_match(/must not set --model=x/, bad.(->(r) { r["launchers"][0]["args"] = ["--model=x"] }))
    # kind: the CLI family, required, one of Launch::KINDS — no default
    assert_match(/launchers\[fullclaude\].kind must be one of claude_code, hermes \(got nil\)/,
                 bad.(->(r) { r["launchers"][0]["kind"] = nil }))
    assert_match(/kind must be one of claude_code, hermes \(got "codex"\)/,
                 bad.(->(r) { r["launchers"][0]["kind"] = "codex" }))
    hermes = ->(args) { ->(r) { r["launchers"][0].merge!("kind" => "hermes", "args" => args) } }
    assert_match(/must not set -q: Launch sets -m \(the agent type's model\) and -q \(the prompt\)/,
                 bad.(hermes.(["chat", "-q", "x"])))
    assert_match(/must not set -m/, bad.(hermes.(["chat", "-m", "x"])))
    assert_match(/must not set --query-file/, bad.(hermes.(["chat", "--query-file", "f"])))
    # argparse reads a single-dash flag glued to its value (`-mfoo` = `-m foo`): refused as well
    assert_match(/must not set -mqwen/, bad.(hermes.(["chat", "-mqwen"])))
    assert_match(/must not set -qhi/, bad.(hermes.(["chat", "-qhi"])))
    assert_match(/must not set --model=x/, bad.(hermes.(["chat", "--model=x"])))
    assert_match(/launchers\[fullclaude\].command must match/, bad.(->(r) { r["launchers"][0]["command"] = "" }))
    assert_match(/launchers\[fullclaude\].command must match/,
                 bad.(->(r) { r["launchers"][0]["command"] = "claude; rm -rf /" }))
    assert_match(/launchers\[fullclaude\].args must be a list of strings/, bad.(->(r) { r["launchers"][0]["args"] = "--yolo" }))
    assert_match(/must not set --remote-control/, bad.(->(r) { r["launchers"][0]["args"] = ["--remote-control", "x"] }))
    assert_match(/launchers\[fullclaude\].via_shell must be true or false/,
                 bad.(->(r) { r["launchers"][0]["via_shell"] = "yes" }))
    assert_match(/launchers\[\].key must match/, bad.(->(r) { r["launchers"][0]["key"] = "Full Claude" }))
    assert_match(/duplicate key fullclaude/, bad.(->(r) { r["launchers"] << r["launchers"][0].dup }))
    # a launcher removed while a type still names it
    assert_match(/agent_types\[lead\].launchers must be a non-empty list of launcher keys \(fullclaude\)/,
                 bad.(->(r) { r["launchers"].pop }))
    assert_equal %w[fullclaude localclaude], coding.launcher_keys
    assert_equal ["claude_code", "claude", ["--permission-mode", "bypassPermissions"], false],
                 coding.launcher("fullclaude").then { |l| [l.kind, l.command, l.args, l.via_shell] }
    # no default launcher: none named is refused with the keys
    assert_match(/launcher is required \(fullclaude, localclaude\)/,
                 assert_raises(AgentsKanban::Invalid) { coding.launcher(nil) }.message)
    assert_raises(AgentsKanban::Invalid) { coding.launcher("") }
    assert_equal ["localclaude", [], true], coding.launcher("localclaude").then { |l| [l.command, l.args, l.via_shell] }
    assert_match(/no launcher "x" \(fullclaude, localclaude\)/,
                 assert_raises(AgentsKanban::Invalid) { coding.launcher("x") }.message)
    assert_equal "localclaude", content.launcher("localclaude").command
  end

  # Agent types: what a session IS — the library ships none, every one is the host's config, validated at load.
  def test_agent_types_and_concurrency_are_required_and_validated
    bad = ->(mut) { r = raw; mut.call(r); assert_raises(E) { C.new(r) }.message }
    t = ->(r) { r["agent_types"][0] }
    assert_match(/missing keys agent_types/, bad.(->(r) { r.delete("agent_types") }))
    assert_match(/agent_types must be a non-empty list .*the library ships none/, bad.(->(r) { r["agent_types"] = [] }))
    keys = "key, label, launchers, model, prompt, agent_name, session_name, takes, max, max_per_project"
    assert_match(/agent_types\[\] must be an object with exactly #{keys}/,
                 bad.(->(r) { r["agent_types"] = [{ "key" => "x" }] }))
    assert_match(/agent_types\[lead\].launchers must be a non-empty list of launcher keys/,
                 bad.(->(r) { t.(r)["launchers"] = ["nope"] }))
    assert_match(/agent_types\[lead\].launchers: duplicate/, bad.(->(r) { t.(r)["launchers"] = %w[fullclaude fullclaude] }))
    assert_match(/agent_types\[lead\].model must be null, match .*, or map each launcher to one/,
                 bad.(->(r) { t.(r)["model"] = "opus 4" }))
    allowed = '\(allowed: \{slug\} \{dir\} \{session\} \{agent\} \{type\} \{cards\}\)'
    assert_match(/agent_types\[lead\].prompt: unknown placeholder \{dirr\} #{allowed}/,
                 bad.(->(r) { t.(r)["prompt"] = "cd {dirr}" }))
    assert_match(/agent_types\[lead\].agent_name must contain \{session\}/,
                 bad.(->(r) { t.(r)["agent_name"] = "claude-{slug}" }))
    assert_match(/agent_types\[lead\].agent_name: unknown placeholder \{dir\}/,
                 bad.(->(r) { t.(r)["agent_name"] = "{session}-{dir}" }))
    assert_match(/agent_types\[lead\].takes must be a list of column types \(parked, queued, working/,
                 bad.(->(r) { t.(r)["takes"] = ["todo"] }))
    assert_match(/agent_types\[lead\].takes: duplicate type/, bad.(->(r) { t.(r)["takes"] = %w[queued queued] }))
    assert_match(/agent_types\[lead\].max must be null, 0 \(no cap\) or an integer >= 1/, bad.(->(r) { t.(r)["max"] = -1 }))
    assert_match(/agent_types\[lead\].max_per_project must be null, 0 \(no cap\) or an integer >= 1/,
                 bad.(->(r) { t.(r)["max_per_project"] = "1" }))
    assert_match(/agent_types: duplicate key lead/, bad.(->(r) { r["agent_types"] << t.(r).dup }))
    assert_match(/missing keys concurrency/, bad.(->(r) { r.delete("concurrency") }))
    assert_match(/concurrency must be an object with exactly max_sessions/, bad.(->(r) { r["concurrency"] = {} }))
    assert_match(/concurrency.max_sessions must be an integer >= 0/,
                 bad.(->(r) { r["concurrency"] = { "max_sessions" => -1 } }))
    assert_nil(raw.tap { |r| r["concurrency"]["max_sessions"] = 0 }.then { |r| C.new(r).concurrency.max_sessions },
               "0 = no host cap")
    assert_match(/max_sessions must be an integer >= 0/, bad.(->(r) { r["concurrency"] = { "max_sessions" => nil } }))
    zero = raw.tap { |r| r["agent_types"][0].merge!("max" => 0, "max_per_project" => 0) }
    assert_equal [nil, nil], C.new(zero).agent_type("lead").then { |a| [a.max, a.max_per_project] }, "0 = no type cap"
    lead = coding.agent_type("lead")
    takes = %w[queued working review gate]
    assert_equal [%w[fullclaude localclaude], nil, "claude-{session}", takes, nil, 1],
                 [lead.launchers, lead.model, lead.agent_name, lead.takes, lead.max, lead.max_per_project]
    assert_equal "localclaude", lead.launcher!("localclaude")
    # none named: several launchers and no spawn_launcher → refused with the list, never the first one
    %w[lead team plain].each do |k|
      assert_match(/agent type #{k} runs fullclaude, localclaude and none was named — name the launcher, or set /,
                   assert_raises(AgentsKanban::Invalid) { coding.agent_type(k).launcher!(nil) }.message)
    end
    assert_raises(AgentsKanban::Invalid) { lead.launcher!("") }
    # one launcher: unambiguous
    assert_equal "localclaude", content.agent_type("worker").launcher!(nil)
    # spawn_launcher: the operator's explicit choice, used only when none is named; must be one of the type's launchers
    picked = C.new(raw.tap { |r| t.(r)["spawn_launcher"] = "localclaude" }).agent_type("lead")
    assert_equal %w[localclaude fullclaude localclaude],
                 [picked.launcher!(nil), picked.launcher!("fullclaude"), picked.spawn_launcher]
    assert_match(/agent_types\[lead\].spawn_launcher must be one of agent_types\[lead\].launchers \(fullclaude, localclaude\)/,
                 bad.(->(r) { t.(r)["spawn_launcher"] = "nope" }))
    assert_match(/spawn_launcher must be one of/, bad.(->(r) { t.(r)["spawn_launcher"] = 3 }))
    assert_nil lead.spawn_launcher, "optional: absent = none"
    # a session started elsewhere (kanban_register): named, or the only launcher — never spawn_launcher
    assert_match(/agent type lead runs fullclaude, localclaude — name the launcher this session was started with/,
                 assert_raises(AgentsKanban::Invalid) { picked.registered_launcher!(nil) }.message)
    assert_equal "fullclaude", picked.registered_launcher!("fullclaude")
    assert_raises(AgentsKanban::Invalid) { picked.registered_launcher!("nope") }
    assert_equal "localclaude", content.agent_type("worker").registered_launcher!(nil)
    assert_match(/agent type team does not run launcher "nope" \(fullclaude, localclaude\)/,
                 assert_raises(AgentsKanban::Invalid) { coding.agent_type("team").launcher!("nope") }.message)
    assert_equal [[], 2, false], coding.agent_type("team").then { |x| [x.takes, x.max, x.prompt.nil?] }
    assert_match(/agent type is required \(lead, team, plain\)/,
                 assert_raises(AgentsKanban::Invalid) { coding.agent_type(nil) }.message)
    assert_match(/no agent type "boss"/, assert_raises(AgentsKanban::Invalid) { coding.agent_type("boss") }.message)
    assert_equal "claude-tl_g_r", coding.agent_name(lead, session: "tl_g_r", slug: "g/r")
    assert_equal "g_r_teamlead", coding.session_name(lead, slug: "g/r"), "a lead's session says what it is"
    assert_match(/agent_types\[lead\].session_name must contain \{slug\}/, bad.(->(r) {
 t.(r)["session_name"] = "coding_lead" }))
    assert_match(/agent_types\[lead\].session_name: unknown placeholder \{session\}/,
                 bad.(->(r) { t.(r)["session_name"] = "{slug}{session}" }))
    assert_equal 6, coding.concurrency.max_sessions
    assert_equal ["worker"], content.agent_type_keys
  end

  def test_launch_builds_the_argv_for_every_type_with_remote_control_LAST
    with = lambda do |launcher, model: nil|
      r = raw
      r["launchers"] = [{ "key" => "k", "label" => "k", "kind" => "claude_code" }.merge(launcher)]
      r["agent_types"] = [{
        "key" => "t", "label" => "T", "launchers" => ["k"], "model" => model, "prompt" => nil,
        "agent_name" => "a-{session}", "session_name" => "{slug}", "takes" => [], "max" => nil, "max_per_project" => nil,
      }]
      C.new(r)
    end
    l = AgentsKanban::Launch
    claude = { "command" => "claude", "args" => ["--permission-mode", "bypassPermissions"], "via_shell" => false }
    assert_equal ["claude", "--permission-mode", "bypassPermissions", "--remote-control", "tl_g_r"],
                 l.argv(with.(claude), type: "t", session: "tl_g_r")
    assert_equal ["bash", "-ic", "fullclaude --remote-control tl_g_r"],
                 l.argv(with.({ "command" => "fullclaude", "args" => [], "via_shell" => true }), type: "t", session: "tl_g_r")
    local = { "command" => "localclaude", "args" => ["--strict-mcp-config"], "via_shell" => true }
    assert_equal ["bash", "-ic", "localclaude --strict-mcp-config --model qwen3 --remote-control news-articles-12"],
                 l.argv(with.(local, model: "qwen3"), type: "t", session: "news-articles-12")
    # by type + launcher key; none named with several launchers is refused (no default); an unknown key is refused
    assert_equal ["bash", "-ic", "localclaude --remote-control s1"],
                 l.argv(coding, type: "lead", launcher: "localclaude", session: "s1")
    assert_equal ["claude", "--permission-mode", "bypassPermissions", "--remote-control", "s1"],
                 l.argv(coding, type: "lead", launcher: "fullclaude", session: "s1")
    assert_raises(AgentsKanban::Invalid) { l.argv(coding, type: "lead", session: "s1") }
    assert_raises(AgentsKanban::Invalid) { l.argv(coding, type: "lead", launcher: "nope", session: "s1") }
    assert_raises(AgentsKanban::Invalid) { l.argv(coding, type: "team", launcher: "nope", session: "s1") }
    assert_raises(AgentsKanban::Invalid) { l.argv(coding, type: "nope", session: "s1") }
    assert_equal ["claude", "--permission-mode", "bypassPermissions", "--max-runtime", "90m", "--remote-control", "s1"],
                 l.argv(coding, type: "plain", launcher: "fullclaude", session: "s1", extra: ["--max-runtime", "90m"])
    assert_equal "bash -ic localclaude\\ --remote-control\\ s1", l.line(content, type: "worker", session: "s1")
    assert_raises(AgentsKanban::Invalid) { l.argv(coding, type: "lead", session: "bad name") }
    assert_raises(AgentsKanban::Invalid) { l.argv(coding, type: "lead", session: "s1", extra: ["--remote-control", "other"]) }
    assert_raises(AgentsKanban::Invalid) { l.argv(coding, type: "lead", session: "s1", extra: ["--model", "x"]) }
    # a session name is shell-quoted once, so it cannot smuggle a second command through the shell line
    assert_equal ["bash", "-ic", "localclaude --remote-control a.b-c_d"], l.argv(content, type: "worker", session: "a.b-c_d")
    # THE RULE: `--remote-control <session>` is the LAST pair of every launch, whatever the type, launcher, model, args or
    # extras — a bash function's own earlier --remote-control (fullclaude names the repo dir) is overridden, because Claude
    # Code takes a repeated option's last value (measured on 2.1.317 with --model). Exactly one effective name.
    [coding, content].each do |cfg|
      cfg.agent_types.each do |t|
        t.launchers.each do |k|
          argv = l.argv(cfg, type: t.key, launcher: k, session: "one-name", extra: ["--permission-mode", "dontAsk"])
          words = argv.first == "bash" ? Shellwords.split(argv.last) : argv
          assert_equal ["--remote-control", "one-name"], words.last(2), "#{t.key}/#{k}: #{words.inspect}"
          assert_equal 1, words.count("--remote-control")
        end
      end
    end
    # the prompt: claude_code positional, before the --remote-control pair
    assert_equal ["claude", "--permission-mode", "bypassPermissions", "go on", "--remote-control", "tl_g_r"],
                 l.argv(with.(claude), type: "t", session: "tl_g_r", prompt: "go on")
    assert_raises(AgentsKanban::Invalid) { l.argv(with.(claude), type: "t", session: "s", prompt: 1) }
    # a prompt is ONE argv word: starting with "-" it would be an option (`--settings={"hooks":…}`) — refused, rendered
    # (a {placeholder} value) and in the config
    %w[--settings={} -p --mcp-config=x].each do |pr|
      e = assert_raises(AgentsKanban::Invalid) { l.argv(with.(claude), type: "t", session: "s", prompt: pr) }
      assert_match(/prompt must not start with "-"/, e.message)
    end
    assert_equal "x --settings", l.argv(with.(claude), type: "t", session: "s", prompt: "x --settings")[-3]
    r = raw
    r["agent_types"][0]["prompt"] = "--settings={\"hooks\":{}} {slug}"
    assert_match(/agent_types\[lead\].prompt must not start with "-"/, assert_raises(E) { C.new(r) }.message)
  end

  # kind hermes (Hermes Agent): `-m <model>`, `-q <prompt>` (seeds the interactive session), no remote control
  def test_a_hermes_launcher_passes_model_and_prompt_its_own_way_and_has_no_remote_control
    r = raw
    r["launchers"] << { "key" => "hermes", "label" => "hermes", "kind" => "hermes", "command" => "hermes",
                        "args" => ["chat"], "via_shell" => false, }
    plain = r["agent_types"].find { |t| t["key"] == "plain" }
    plain["launchers"] += %w[hermes]
    plain["model"] = { "fullclaude" => nil, "localclaude" => nil, "hermes" => "qwen3" }
    cfg = C.new(r)
    l = AgentsKanban::Launch
    argv = l.argv(cfg, type: "plain", launcher: "hermes", session: "s1", prompt: "hi {there}")
    assert_equal ["hermes", "chat", "-m", "qwen3", "-q", "hi {there}"], argv
    refute_includes argv, "--remote-control"
    assert_equal %w[hermes chat -m qwen3], l.argv(cfg, type: "plain", launcher: "hermes", session: "s1")
    assert_raises(AgentsKanban::Invalid) { l.argv(cfg, type: "plain", launcher: "hermes", session: "s1", extra: ["-q", "x"]) }
    assert_raises(AgentsKanban::Invalid) { l.argv(cfg, type: "plain", launcher: "hermes", session: "s1", extra: ["-qx"]) }
    refute l.kind(cfg, "hermes").remote_control?
    assert l.kind(cfg, "fullclaude").remote_control?
    plan = l.plan(cfg, type: "plain", launcher: "hermes", session: "s1", slug: "g/r")
    assert_equal ["hermes", false], plan.values_at(:kind, :remote_control)
  end

  # The plan a host starts a session from, and the template rendering that never lets a {placeholder} through.
  def test_plan_and_render
    plan = AgentsKanban::Launch.plan(coding, type: "lead", launcher: "fullclaude", session: "tl_g_r", slug: "g/r",
                                           cards: [3, 7])
    assert_equal ["lead", "fullclaude", "claude-tl_g_r", nil], plan.values_at(:type, :launcher, :agent, :model)
    assert_equal ["--remote-control", "tl_g_r"], plan[:argv].last(2)
    assert_equal({ slug: "g/r", session: "tl_g_r", agent: "claude-tl_g_r", type: "lead", cards: "#3, #7" }, plan[:vars])
    assert_match(/\{dir\}/, plan[:prompt_template], "the host renders {dir}")
    text = AgentsKanban::Launch.render(plan[:prompt_template], dir: "/srv/g/r", **plan[:vars])
    assert_includes text, "Lead session for g/r (/srv/g/r). " \
                          "Your tmux session is tl_g_r; on the board you are claude-tl_g_r (lead)."
    assert_includes text, "owns these cards: #3, #7"
    refute_match(/[{}]/, text)
    plain = AgentsKanban::Launch.plan(coding, type: "plain", launcher: "fullclaude", session: "s", slug: "g/r")
    assert_equal "none", plain[:vars][:cards]
    assert_nil plain[:prompt_template]
    assert_match(/no value for \{dir\}/,
                 assert_raises(AgentsKanban::Invalid) { AgentsKanban::Launch.render("x {dir}", slug: "g") }.message)
    assert_match(/\{cards\} must render a string/,
                 assert_raises(AgentsKanban::Invalid) { AgentsKanban::Launch.render("{cards}", cards: [1]) }.message)
    assert_equal "a {b", AgentsKanban::Launch.render("a {b")
  end
end
