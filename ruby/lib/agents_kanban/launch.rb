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
  #     → { type:, launcher:, kind: "claude_code", remote_control: true,
  #         argv: ["claude", "--permission-mode", "bypassPermissions", "--model", "opus", "--remote-control", "tl_g_r"],
  #         agent: "claude-tl_g_r", prompt_template: "…{dir}…", vars: { slug:, session:, agent:, type:, cards: } }
  #   Launch.render(template, dir: "/srv/g/r", **vars)   # the host adds what only it knows ({dir}) and renders; a
  #                                                       # placeholder left without a value raises — nothing reaches
  #                                                       # the agent with {braces} in it
  #
  # How the model, the prompt and the session name are passed is the launcher's KIND (Kind below: claude_code appends
  # `--remote-control <session>` LAST; hermes has no remote control). A bash function (localclaude) exists only in an
  # interactive shell's profile, so via_shell runs `bash -ic <line>`. The tests pin each kind's argv; the host asserts
  # the running process carries what its kind promises (busyyaks's bin/launcher reads /proc).
  module Launch
    SESSION = /\A[A-Za-z0-9._-]{1,100}\z/
    PLACEHOLDER = /\{([^{}\s]*)\}/
    PROMPT_DASH = "the prompt is one argv word, and a word starting with - is parsed as an option (claude_code) or " \
                  "refused as -q's value (hermes)"

    # A launcher's KIND = the CLI family its command is: how the type's model, the prompt and the session name reach
    # it. One class per family over this base; a new CLI is a new kind here, never an `if command ==` anywhere.
    class Kind
      def initialize(key, model_flags:, prompt_flags:, reserved_why:)
        @key = key
        @model_flags = model_flags # the first one is what `words` passes; every one is refused in args / extra
        @prompt_flags = prompt_flags
        @reserved_why = reserved_why
      end
      attr_reader :key, :reserved_why

      # an option this kind sets itself, refused in a launcher's args and a launch's extra (a repeated option takes
      # its LAST value in both CLIs, so a configured one would silently fight the computed one): the flag, `--flag=…`,
      # and for a single-dash flag any word it starts (argparse reads `-mfoo` as `-m foo`, `-qmx` as `-q mx`)
      def reserved?(arg)
        reserved.any? do |f|
          short = f.match?(/\A-[^-]\z/)
          arg == f || arg.start_with?("#{f}=") || (short && arg.start_with?(f))
        end
      end
      def reserved = @model_flags + @prompt_flags + session_flags
      # true = the session must carry `--remote-control <session>` (a host checks it came up)
      def remote_control? = false
      def session_flags = []
    end

    # Claude Code: `<command> <args> [--model M] <extra> [<prompt>] --remote-control <session>` — the prompt positional,
    # `--remote-control <session>` ALWAYS LAST, named after the tmux session (unique per session): the operator's rule
    # that every interactive Claude session is reachable from the Claude app. A profile function that adds its own
    # `--remote-control` is overridden by this last one (Claude Code takes a repeated option's LAST value; measured on
    # 2.1.317: `claude --model sonnet --model opus` starts Opus); the host asserts the running process carries it.
    class ClaudeCode < Kind
      def initialize = super("claude_code", model_flags: ["--model"], prompt_flags: [],
                                            reserved_why: "Launch sets --model (the agent type's model) and " \
                                                          "--remote-control (named after the session)")
      def remote_control? = true
      def session_flags = ["--remote-control"]

      def words(base, model:, extra:, prompt:, session:)
        [*base, *(model ? ["--model", model] : []), *extra, *(prompt ? [prompt] : []), "--remote-control", session]
      end
    end

    # Hermes Agent (`hermes chat`: put `chat` in the launcher's args): `<command> <args> [-m M] <extra> [-q <prompt>]` —
    # on a TTY `-q` seeds the interactive session with the prompt as its first turn. No remote control: hermes has none,
    # so the host checks the pane runs the command instead.
    class Hermes < Kind
      def initialize = super("hermes", model_flags: ["-m", "--model"], prompt_flags: ["-q", "--query", "--query-file"],
                                       reserved_why: "Launch sets -m (the agent type's model) and -q (the prompt)")

      def words(base, model:, extra:, prompt:, **) # no session: hermes takes no name for it
        [*base, *(model ? ["-m", model] : []), *extra, *(prompt ? ["-q", prompt] : [])]
      end
    end

    KINDS = [ClaudeCode.new, Hermes.new].to_h { |k| [k.key, k] }.freeze

    module_function

    def kind(config, launcher) = KINDS.fetch(config.launcher(launcher).kind)

    # The argv for an agent type (its launcher by key; none named → AgentType#launcher!: the type's spawn_launcher or
    # only launcher, else refused), built by the launcher's kind. prompt: the rendered prompt (Launch.render) or nil.
    # extra: more flags after the configured args (a host's per-launch options), never one the kind sets itself.
    def argv(config, type:, session:, launcher: nil, extra: [], prompt: nil)
      t = config.agent_type(type)
      lk = t.launcher!(launcher)
      l = config.launcher(lk)
      k = KINDS.fetch(l.kind)
      s = session.to_s
      raise Invalid, "session must match #{SESSION.source} (got #{session.inspect})" unless s.match?(SESSION)
      raise Invalid, "extra must be a list of strings" unless extra.is_a?(Array) && extra.all?(String)
      raise Invalid, "prompt must be a string or nil" unless prompt.nil? || prompt.is_a?(String)
      raise Invalid, "prompt must not start with \"-\": #{PROMPT_DASH}" if prompt&.start_with?("-")

      reserved = extra.find { |x| k.reserved?(x) }
      raise Invalid, "extra must not set #{reserved}: #{k.reserved_why}" if reserved

      words = k.words([l.command, *l.args], model: t.model_for(lk), extra: extra, prompt: prompt, session: s)
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
      lk = t.launcher!(launcher)
      { type: t.key, launcher: lk, kind: config.launcher(lk).kind, remote_control: kind(config, lk).remote_control?,
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
