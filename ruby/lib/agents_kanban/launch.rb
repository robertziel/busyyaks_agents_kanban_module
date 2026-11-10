# frozen_string_literal: true

require "shellwords"
require_relative "errors"

module AgentsKanban
  # How a host STARTS an agent session, built from the board config — never a command name, model id or prompt in
  # code. A launch names an AGENT TYPE (what the session is: a lead, a reviewer, a plain session) and optionally one
  # of that type's launchers (the command: `claude`, a profile function). The engine itself starts nothing; `plan`
  # is what the host's launcher (busyyaks's bin/launcher, content_app's board_worker) hands to tmux, and the prompt it types.
  #
  #   Launch.plan(config, type: "lead", launcher: "fullclaude", session: "tl_g_r", slug: "g/r")
  #     → { type:, launcher:,
  #         argv: ["claude", "--permission-mode", "bypassPermissions", "--model", "opus", "--remote-control", "tl_g_r"],
  #         agent: "claude-tl_g_r", prompt_template: "…{dir}…", vars: { slug:, session:, agent:, type:, cards: } }
  #   Launch.render(template, dir: "/srv/g/r", **vars)   # the host adds what only it knows ({dir}) and renders; a
  #                                                       # placeholder left without a value raises — nothing reaches
  #                                                       # the agent with {braces} in it
  #
  # `--remote-control <session>` is ALWAYS appended LAST, named after the tmux session (unique per session): the
  # operator's rule that every interactive Claude session is reachable from the Claude app. A bash function
  # (localclaude) exists only in an interactive shell's profile, so via_shell runs `bash -ic <line>`. A function
  # that adds its own `--remote-control` (the operator's `fullclaude` names the repo directory — a name two sessions
  # in one repo would share) is still overridden: in Claude Code's parser a repeated option takes its LAST value
  # (measured on Claude Code 2.1.317: `claude --model sonnet --model opus` starts Opus), so the pair this appends
  # at the END of the line is the effective name. The test pins the position; the host asserts the running
  # process carries it (busyyaks's bin/launcher reads /proc).
  module Launch
    SESSION = /\A[A-Za-z0-9._-]{1,100}\z/
    PLACEHOLDER = /\{([^{}\s]*)\}/

    module_function

    # The argv for an agent type (its launcher by key; none named → AgentType#launcher!: the type's spawn_launcher or
    # only launcher, else refused). extra: more flags after the configured args
    # (a host's per-launch options), never a second --remote-control or --model.
    def argv(config, type:, session:, launcher: nil, extra: [])
      t = config.agent_type(type)
      lk = t.launcher!(launcher)
      l = config.launcher(lk)
      model = t.model_for(lk)
      s = session.to_s
      raise Invalid, "session must match #{SESSION.source} (got #{session.inspect})" unless s.match?(SESSION)
      raise Invalid, "extra must be a list of strings" unless extra.is_a?(Array) && extra.all?(String)
      if extra.any? { |x| x.start_with?("--remote-control") }
        raise Invalid, "extra must not set --remote-control: it is named after the session"
      end
      raise Invalid, "extra must not set --model: the agent type's model does" if extra.any? { |x| x.start_with?("--model") }

      words = [l.command, *l.args, *(model ? ["--model", model] : []), *extra, "--remote-control", s]
      l.via_shell ? ["bash", "-ic", Shellwords.join(words)] : words
    end

    # The same as one shell line (for a tmux `send-keys` or a log).
    def line(config, **kw) = Shellwords.join(argv(config, **kw))

    # Everything a host needs to start a session of `type` for board `slug`: the argv, the agent name the session
    # acts as, the prompt template and the values the engine knows for it. cards: the card ids the session adopted at
    # registration (Store#register_session), rendered as "#1, #2" / "none".
    def plan(config, type:, session:, slug:, launcher: nil, cards: [], extra: [])
      t = config.agent_type(type)
      agent = config.agent_name(t, session: session, slug: slug)
      card_list = cards.empty? ? "none" : cards.map { |c| "##{c}" }.join(", ")
      { type: t.key, launcher: t.launcher!(launcher),
        argv: argv(config, type: t.key, session: session, launcher: launcher, extra: extra),
        model: t.model_for(launcher), agent: agent, prompt_template: t.prompt,
        vars: { slug: slug.to_s, session: session.to_s, agent: agent, type: t.key, cards: card_list }, }
    end

    # A template with every {placeholder} replaced by its value. A placeholder with no value given, or a value that
    # is not a string, raises: a prompt is never typed with {braces} or "nil" in it.
    def render(template, **vars)
      v = vars.transform_keys(&:to_s)
      template.to_s.gsub(PLACEHOLDER) do
        key = Regexp.last_match(1)
        unless v.key?(key)
          raise Invalid, "no value for {#{key}} in #{template.inspect[0, 60]} (given: #{v.keys.join(', ')})"
        end
        raise Invalid, "{#{key}} must render a string (got #{v[key].inspect})" unless v[key].is_a?(String)

        v[key]
      end
    end
  end
end
