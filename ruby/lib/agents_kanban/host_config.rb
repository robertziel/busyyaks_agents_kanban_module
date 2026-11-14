# frozen_string_literal: true

require "json"
require "yaml"
require "digest"
require_relative "errors"
require_relative "column_types"
require_relative "launch"

module AgentsKanban
  # What one HOST runs — its settings, injected once at boot. NOT the boards: a project's columns (with their types)
  # and its workflow live in the database (Board, BoardRepo), edited by the operator. What stays here is what a
  # deployment decides for every board at once: the enums, who signs engine entries, the attachment route, the
  # commands that start a session and the agent types (what a session IS; which column TYPES it takes / spawns for),
  # the caps, the owner-session rule, the table prefix, the theme, the idle watch's timings, the handoff gate's
  # requirements and whether parent dependencies are enforced. Every key is required (a block may be null where the
  # doc says so), unknown keys are refused: a wrong file fails at boot with its path.
  #
  # Rule glossary (where the engine reads each key):
  #   priorities, label_colors  the enums (gray required)
  #   system_author             signs the engine's own activity entries and prefixes its pings ("[busyyaks] …")
  #   attachment_url_prefix     the host's route for attachment bytes: "<prefix>/<id>" views, "<prefix>/<id>/download"
  #                             downloads
  #   launchers                 [{key, label, kind, command, args, via_shell}]: the COMMANDS that start an agent session
  #                             (Launch); kind = the CLI family the command is (Launch::KINDS: claude_code, hermes), which
  #                             decides how the model, the prompt and the session name reach it
  #   agent_types               [{key, label, launchers, model, prompt, agent_name, session_name, takes, max, max_per_project,
  #                             spawns_for?, launcher_follows?, spawn_launcher?}]: WHAT is launched. A start that names no
  #                             launcher (a spawn with no session to follow, kanban_register without one) runs the type's
  #                             `spawn_launcher`, or its only launcher; a type with several and none configured refuses.
  #                             `takes` / `spawns_for` name column TYPES (ColumnTypes):
  #                             a board's columns of those types are the ones the session adopts / gets a session per card
  #   concurrency               {max_sessions}: registered agent sessions running at once on the host (0 = no cap)
  #   owner_sessions            null (the host's rule) or session-name globs a card may be owned by
  #   table_prefix              namespaces the engine's tables ("" = the unprefixed names busyyaks started with)
  #   theme                     {"--ak-<token>": "<css value>"}: the React board's CSS variables ({} = the library's own)
  #   approval                  null or {requires_green_ci}: true = every approval step (Store#approve, the operator's
  #                             drag along a step) is refused unless the host's ci: port (Store.new ci:, approval_checks)
  #                             says the card's PR checks are green; the refusal names the PR and its state
  #   idle_watch                null or {ci_ping_after_minutes, ci_comment_after_minutes, owner_idle_hours}: the timings of
  #                             the idle watch on every board's WORKING column (Store#idle_watch_pass; needs the Notifier's
  #                             ci: port)
  #   handoff                   null or {requires_pr_url, requires_ci_url, qa_min_chars, ui_change_needs_screenshots}: what
  #                             kanban_handoff requires on a board with a handoff column (a handoff column + null = refused)
  #   dependencies              true = parent dependencies are ENFORCED (a child cannot enter a work column nor be claimed
  #                             while a parent is unfinished; a finished parent promotes its parked children to the queued
  #                             column); false = parents are recorded and shown only
  #   flags                     {reminder_hours}: a card flagged needs_operator / blocked_external for that long gets ONE
  #                             reminder comment by system_author (Store#flag_reminders)
  #   review_loop               null or {max_rounds, unresolved_label, unresolved_color, columns}: the agent review
  #                             loop's round limit per loop column (columns = review column keys); at the limit an
  #                             agent's loop move is refused and a handoff out of the loop column carries the label
  #                             (created on the board when missing)
  #
  # Loaded from JSON or YAML (HostConfig.load picks by extension); config.example.yml at the repo root documents every
  # key, fixtures/boards/*.json are complete examples (coding.json + coding.board.json are busyyaks's).
  class HostConfig
    KEYS = %w[priorities label_colors system_author attachment_url_prefix launchers agent_types concurrency owner_sessions
              table_prefix theme idle_watch handoff approval dependencies session_dialogs flags review_loop
              session_boards].freeze
    OWNER_SESSION_GLOB = /\A[A-Za-z0-9._*?-]{1,100}\z/
    TABLE_PREFIX = /\A[a-z][a-z0-9_]{0,30}_\z|\A\z/
    THEME_VAR = /\A--ak-[a-z0-9-]{1,40}\z/
    # A theme value is written into a host's <style>:root{…} rule, so it must not be able to end, break or swallow that
    # rule: an ALLOWLIST of characters (no ; { } < [ ] \\ !), no /* comment, quotes in pairs,
    # parentheses balanced. Enough for every real token: colours, rgba()/var()/calc()/blur(), shadows, font lists.
    THEME_VALUE = %r{\A[A-Za-z0-9\s#%.,()/+*"'_-]+\z}
    LAUNCHER_KEYS = %w[key label kind command args via_shell].freeze
    LAUNCHER_KEY = /\A[a-z][a-z0-9_-]{0,39}\z/
    LAUNCHER_COMMAND = /\A[A-Za-z0-9_][A-Za-z0-9_.\/-]{0,200}\z/
    Launcher = Struct.new(:key, :label, :kind, :command, :args, :via_shell, keyword_init: true)
    AGENT_TYPE_KEYS = %w[key label launchers model prompt agent_name session_name takes max max_per_project].freeze
    OPTIONAL_AGENT_TYPE_KEYS = %w[spawns_for launcher_follows spawn_launcher].freeze
    AgentType = Struct.new(:key, :label, :launchers, :model, :prompt, :agent_name, :session_name, :takes, :max,
                           :max_per_project, :spawns_for, :launcher_follows, :spawn_launcher, keyword_init: true) do
      # The launcher key a start the ENGINE performs (Api#launch, Api#spawn_pass, Launch.argv / plan) runs: the one
      # named (refused unless the type lists it); none named → the operator's `spawn_launcher`, or the type's ONLY
      # launcher. Several and no spawn_launcher → refused with the list: the code never picks one of them.
      def launcher!(key)
        return registered_launcher!(key) unless key.nil? || key.to_s.empty?
        return spawn_launcher if spawn_launcher
        return launchers.first if launchers.size == 1

        raise Invalid, "agent type #{self.key} runs #{launchers.join(', ')} and none was named — name the launcher, " \
                       "or set agent_types[#{self.key}].spawn_launcher"
      end

      # The launcher a session started ELSEWHERE runs (kanban_register / Store#register_session with no launcher): the one
      # named, or the type's only launcher. Never spawn_launcher — the engine did not start that session, so it cannot
      # know which launcher runs it, and a recorded guess would be followed by its workers (launcher_follows).
      def registered_launcher!(key)
        if key.nil? || key.to_s.empty?
          return launchers.first if launchers.size == 1

          raise Invalid, "agent type #{self.key} runs #{launchers.join(', ')} — name the launcher this session was " \
                         "started with"
        end
        return key.to_s if launchers.include?(key.to_s)

        raise Invalid, "agent type #{self.key} does not run launcher #{key.inspect} (#{launchers.join(', ')})"
      end

      # The --model this type runs under launcher `key` (null = the launcher's own): `model` is one value for every
      # launcher, or a map launcher key → value (a gateway launcher such as localclaude picks its own model, and a
      # --model would override it — Claude Code takes the LAST --model).
      def model_for(key)
        l = launcher!(key)
        model.is_a?(Hash) ? model.fetch(l) : model
      end
    end
    PROMPT_VARS = %w[slug dir session agent type cards].freeze
    AGENT_NAME_VARS = %w[session slug type].freeze
    SESSION_NAME_VARS = %w[slug type].freeze
    MODEL = /\A[A-Za-z0-9][A-Za-z0-9._:-]{0,80}\z/
    CONCURRENCY_KEYS = %w[max_sessions].freeze
    Concurrency = Struct.new(:max_sessions, keyword_init: true)
    HANDOFF_KEYS = %w[requires_pr_url requires_ci_url qa_min_chars ui_change_needs_screenshots].freeze
    HandoffParams = Struct.new(:requires_pr_url, :requires_ci_url, :qa_min_chars, :ui_change_needs_screenshots,
                               keyword_init: true)
    IDLE_WATCH_KEYS = %w[ci_ping_after_minutes ci_comment_after_minutes owner_idle_hours].freeze
    APPROVAL_KEYS = %w[requires_green_ci].freeze
    Approval = Struct.new(:requires_green_ci, keyword_init: true)
    IdleWatch = Struct.new(:ci_ping_after_minutes, :ci_comment_after_minutes, :owner_idle_hours, keyword_init: true)
    SESSION_DIALOG_KEYS = %w[settle_seconds context_minutes].freeze
    SessionDialogs = Struct.new(:settle_seconds, :context_minutes, keyword_init: true)
    # flags: the cross-cutting card flags (needs_operator, blocked_external): reminder_hours = after how long a flagged
    # card gets ONE reminder comment by the system author (Store#flag_reminders, the notifier's watch pass)
    FLAGS_KEYS = %w[reminder_hours].freeze
    Flags = Struct.new(:reminder_hours, keyword_init: true)
    # review_loop: the agent review loop on the review columns named in `columns` (column keys, on every board that has
    # them; any other review column — a coding board's QA — has no round limit) — max_rounds = entries into one loop
    # column before the loop must end at a gate (an agent's further loop move is refused); unresolved_label /
    # unresolved_color = the label put on a card handed off from a loop column at the limit (created on the board when
    # missing)
    REVIEW_LOOP_KEYS = %w[max_rounds unresolved_label unresolved_color columns].freeze
    ReviewLoop = Struct.new(:max_rounds, :unresolved_label, :unresolved_color, :columns, keyword_init: true)
    # session_boards: a board that belongs to ONE agent session, not to a project (Store#session_board!): its slug is
    # slug_prefix + the session name, its shape `board` (columns + transitions, validated as a Board by the Store; no
    # gate: nobody but the session acts on it), and after idle_hours with no activity its cards are archived and the
    # board is hidden (Store#session_boards_expire_pass, the notifier's watch pass) — kept, never deleted
    SESSION_BOARD_KEYS = %w[slug_prefix idle_hours board].freeze
    SESSION_BOARD_PREFIX = /\A[a-z][a-z0-9_-]{0,30}:\z/
    SessionBoards = Struct.new(:slug_prefix, :idle_hours, :board, keyword_init: true)

    attr_reader :priorities, :label_colors, :system_author, :attachment_url_prefix, :launchers, :agent_types, :concurrency,
                :owner_sessions, :table_prefix, :theme, :idle_watch, :handoff, :approval, :dependencies, :session_dialogs,
                :flags, :review_loop, :session_boards, :raw

    def self.load(path)
      raise ConfigError, "host config not found: #{path}" unless File.file?(path)

      data = path.to_s.match?(/\.ya?ml\z/) ? YAML.safe_load_file(path) : JSON.parse(File.read(path))
      new(data)
    rescue JSON::ParserError, Psych::Exception => e
      raise ConfigError, "#{path}: #{e.message}"
    rescue ConfigError => e
      raise ConfigError, "#{path}: #{e.message}"
    end

    def initialize(hash)
      raise ConfigError, "host config must be an object" unless hash.is_a?(Hash)

      unknown = hash.keys - KEYS
      missing = KEYS - hash.keys
      if unknown.any?
        moved = (unknown & %w[columns gates workflow waiting listened]).any?
        hint = " (columns, gates and workflow live in the database now: SPEC § 2)" if moved
        raise ConfigError, "host config: unknown keys #{unknown.join(', ')}#{hint}"
      end
      raise ConfigError, "host config: missing keys #{missing.join(', ')}" if missing.any?

      # a plain, string-keyed, detached, frozen copy — what to_h and the digest see
      @raw = deep_freeze(JSON.parse(JSON.generate(hash)))
      @priorities = names!(hash["priorities"], "priorities")
      @label_colors = names!(hash["label_colors"], "label_colors")
      raise ConfigError, "label_colors must include gray (the explicit no-colour label)" unless @label_colors.include?("gray")

      @system_author = str!(hash["system_author"], "system_author")
      @attachment_url_prefix = str!(hash["attachment_url_prefix"], "attachment_url_prefix")
      raise ConfigError, "attachment_url_prefix must start with / and not end with /" \
        unless @attachment_url_prefix.start_with?("/") && !@attachment_url_prefix.end_with?("/")

      @launchers = parse_launchers(hash["launchers"])
      @agent_types = parse_agent_types(hash["agent_types"])
      @concurrency = parse_concurrency(hash["concurrency"])
      @owner_sessions = parse_owner_sessions(hash["owner_sessions"])
      @table_prefix = hash["table_prefix"]
      raise ConfigError, "table_prefix must be \"\" or [a-z][a-z0-9_]*_ (got #{@table_prefix.inspect})" \
        unless @table_prefix.is_a?(String) && @table_prefix.match?(TABLE_PREFIX)

      @theme = parse_theme(hash["theme"])
      @idle_watch = hash["idle_watch"] && parse_idle_watch(hash["idle_watch"])
      @handoff = hash["handoff"] && parse_handoff(hash["handoff"])
      @approval = hash["approval"] && parse_approval(hash["approval"])
      @dependencies = bool!(hash["dependencies"], "dependencies")
      @session_dialogs = parse_session_dialogs(hash["session_dialogs"])
      @flags = parse_flags(hash["flags"])
      @review_loop = hash["review_loop"] && parse_review_loop(hash["review_loop"])
      @session_boards = hash["session_boards"] && parse_session_boards(hash["session_boards"])
      freeze
    end

    # The launcher by key; none named or an unknown key is refused — there is no default launcher.
    def launcher(key)
      raise Invalid, "launcher is required (#{launcher_keys.join(', ')})" if key.nil? || key.to_s.empty?

      @launchers.find { |l| l.key == key.to_s } || raise(Invalid, "no launcher #{key.inspect} (#{launcher_keys.join(', ')})")
    end
    def launcher_keys = @launchers.map(&:key)

    # true when every approval step must see the card's PR checks green first (Store's ci: port, approval_checks)
    def green_ci_gate? = !@approval.nil? && @approval.requires_green_ci
    # The agent type by key: there is no default type — a launch names what it starts; an unknown key is refused.
    def agent_type(key)
      k = key.to_s
      raise Invalid, "agent type is required (#{agent_type_keys.join(', ')})" if k.empty?

      @agent_types.find { |t| t.key == k } || raise(Invalid, "no agent type #{key.inspect} (#{agent_type_keys.join(', ')})")
    end
    def agent_type_keys = @agent_types.map(&:key)
    # The column TYPES some agent type spawns for (one spawner type per column type).
    def spawn_types = @agent_types.flat_map(&:spawns_for).uniq
    # The author name a session of `type` acts as on the board ("claude-{session}" → "claude-tl_g_r").
    def agent_name(type, session:, slug:) = Launch.render(type.agent_name, session: session, slug: slug, type: type.key)
    # The tmux session name a launch of this type asks the host for (slug's "/" → "_"); the host only makes it unique.
    def session_name(type, slug:) = Launch.render(type.session_name, slug: slug.to_s.tr("/", "_"), type: type.key)
    # May a card of this host's boards be owned by this tmux session? Every session when owner_sessions is null.
    def owner_session?(name)
      return true if @owner_sessions.nil?

      @owner_sessions.any? { |pat| File.fnmatch?(pat, name.to_s, File::FNM_DOTMATCH) }
    end

    # The digest a client can compare against: the same JSON the host sends to the browser (to_h), canonical.
    def digest = Digest::SHA256.hexdigest(JSON.generate(to_h))
    def to_h = @raw
    def to_json(*a) = JSON.generate(to_h, *a)

    private

    def deep_freeze(v)
      case v
      when Hash then v.each_value { |x| deep_freeze(x) }.freeze
      when Array then v.each { |x| deep_freeze(x) }.freeze
      else v.freeze
      end
    end

    def names!(v, where)
      names = v.is_a?(Array) && v.any? && v.all? { |x| x.is_a?(String) && x.match?(/\A[a-z][a-z0-9_]*\z/) }
      raise ConfigError, "#{where} must be a non-empty list of distinct [a-z] names" unless names && v.uniq.size == v.size

      v.freeze
    end

    def str!(v, where)
      raise ConfigError, "#{where} must be a non-empty string" unless v.is_a?(String) && !v.strip.empty?

      v
    end

    def bool!(v, where)
      raise ConfigError, "#{where} must be true or false" unless [true, false].include?(v)

      v
    end

    def shape!(v, keys, where)
      raise ConfigError, "#{where} must be an object with exactly #{keys.join(', ')}" \
        unless v.is_a?(Hash) && v.keys.sort == keys.sort
    end

    def types!(v, where)
      raise ConfigError, "#{where} must be a list of column types (#{ColumnTypes.keys.join(', ')})" \
        unless v.is_a?(Array) && v.all? { |t| ColumnTypes.known?(t) }
      raise ConfigError, "#{where}: duplicate type" if v.uniq.size != v.size

      v.map(&:to_s).freeze
    end

    def parse_handoff(v)
      shape!(v, HANDOFF_KEYS, "handoff")
      min = v["qa_min_chars"]
      raise ConfigError, "handoff.qa_min_chars must be an integer >= 0" unless min.is_a?(Integer) && min >= 0

      HandoffParams.new(
        requires_pr_url: bool!(v["requires_pr_url"], "handoff.requires_pr_url"),
        requires_ci_url: bool!(v["requires_ci_url"], "handoff.requires_ci_url"),
        qa_min_chars: min,
        ui_change_needs_screenshots: bool!(v["ui_change_needs_screenshots"], "handoff.ui_change_needs_screenshots")
      ).freeze
    end

    def parse_approval(v)
      shape!(v, APPROVAL_KEYS, "approval")
      Approval.new(requires_green_ci: bool!(v["requires_green_ci"], "approval.requires_green_ci")).freeze
    end

    def parse_idle_watch(v)
      shape!(v, IDLE_WATCH_KEYS, "idle_watch")
      n = IDLE_WATCH_KEYS.to_h do |k|
        raise ConfigError, "idle_watch.#{k} must be an integer >= 1" unless v[k].is_a?(Integer) && v[k] >= 1

        [k.to_sym, v[k]]
      end
      IdleWatch.new(**n).freeze
    end

    def parse_session_dialogs(v)
      shape!(v, SESSION_DIALOG_KEYS, "session_dialogs")
      settle = v["settle_seconds"]
      context = v["context_minutes"]
      raise ConfigError, "session_dialogs.settle_seconds must be an integer >= 0" unless settle.is_a?(Integer) && settle >= 0
      raise ConfigError, "session_dialogs.context_minutes must be an integer >= 1" unless context.is_a?(Integer) && context >= 1

      SessionDialogs.new(settle_seconds: v["settle_seconds"], context_minutes: v["context_minutes"]).freeze
    end

    def parse_flags(v)
      shape!(v, FLAGS_KEYS, "flags")
      h = v["reminder_hours"]
      raise ConfigError, "flags.reminder_hours must be an integer >= 1" unless h.is_a?(Integer) && h >= 1

      Flags.new(reminder_hours: h).freeze
    end

    def parse_review_loop(v)
      shape!(v, REVIEW_LOOP_KEYS, "review_loop")
      n = v["max_rounds"]
      raise ConfigError, "review_loop.max_rounds must be an integer >= 1" unless n.is_a?(Integer) && n >= 1

      name = str!(v["unresolved_label"], "review_loop.unresolved_label")
      raise ConfigError, "review_loop.unresolved_label cannot contain a comma" if name.include?(",")

      color = v["unresolved_color"]
      unless @label_colors.include?(color)
        raise ConfigError, "review_loop.unresolved_color must be one of label_colors (#{@label_colors.join(', ')})"
      end

      cols = v["columns"]
      unless cols.is_a?(Array) && !cols.empty? && cols.all? { |k| k.is_a?(String) && !k.strip.empty? }
        raise ConfigError, "review_loop.columns must be a non-empty list of review column keys"
      end

      ReviewLoop.new(max_rounds: n, unresolved_label: name.strip, unresolved_color: color,
                     columns: cols.map(&:strip).freeze).freeze
    end

    def parse_session_boards(v)
      shape!(v, SESSION_BOARD_KEYS, "session_boards")
      prefix = v["slug_prefix"]
      unless prefix.is_a?(String) && prefix.match?(SESSION_BOARD_PREFIX)
        raise ConfigError, "session_boards.slug_prefix must be [a-z][a-z0-9_-]* ending in \":\" (got #{prefix.inspect})"
      end

      h = v["idle_hours"]
      raise ConfigError, "session_boards.idle_hours must be an integer >= 1" unless h.is_a?(Integer) && h >= 1

      board = v["board"]
      unless board.is_a?(Hash) && board.key?("columns") && board.key?("transitions")
        raise ConfigError, "session_boards.board must be a board {columns, transitions}"
      end

      SessionBoards.new(slug_prefix: prefix, idle_hours: h, board: board).freeze
    end

    def parse_theme(v)
      raise ConfigError, "theme must be an object of --ak-* CSS variables" unless v.is_a?(Hash)

      v.each do |k, val|
        raise ConfigError, "theme: #{k.inspect} is not a --ak-* variable" unless k.is_a?(String) && k.match?(THEME_VAR)
        raise ConfigError, "theme: #{k} must be a CSS value of letters, digits, spaces and # % . , ( ) / + * _ - \" ' — " \
                           "quotes in pairs, parentheses balanced, no /*" unless theme_value?(val)
      end
      v.freeze
    end

    def theme_value?(val)
      return false unless val.is_a?(String) && !val.strip.empty? && val.match?(THEME_VALUE) && !val.include?("/*")
      return false if val.count('"').odd? || val.count("'").odd?

      depth = 0
      val.each_char do |c|
        depth += 1 if c == "("
        depth -= 1 if c == ")"
        return false if depth.negative?
      end
      depth.zero?
    end

    def parse_launchers(v)
      raise ConfigError, "launchers must be a non-empty list of {key, label, kind, command, args, via_shell}" \
        unless v.is_a?(Array) && v.any?

      list = v.map { |l| parse_launcher(l) }
      dup = list.map(&:key).tally.select { |_, n| n > 1 }.keys
      raise ConfigError, "launchers: duplicate key #{dup.first}" if dup.any?

      list.freeze
    end

    def parse_launcher(v)
      shape!(v, LAUNCHER_KEYS, "launchers[]")
      raise ConfigError, "launchers[].key must match #{LAUNCHER_KEY.source}" \
        unless v["key"].is_a?(String) && v["key"].match?(LAUNCHER_KEY)
      where = "launchers[#{v['key']}]"
      raise ConfigError, "#{where}.command must match #{LAUNCHER_COMMAND.source} (a program or a bash function name)" \
        unless v["command"].is_a?(String) && v["command"].match?(LAUNCHER_COMMAND)
      args = v["args"]
      raise ConfigError, "#{where}.args must be a list of strings" \
        unless args.is_a?(Array) && args.all? { |x| x.is_a?(String) && !x.empty? }
      kind = Launch::KINDS[v["kind"]]
      raise ConfigError, "#{where}.kind must be one of #{Launch::KINDS.keys.join(', ')} (got #{v['kind'].inspect})" if kind.nil?

      reserved = args.find { |x| kind.reserved?(x) }
      raise ConfigError, "#{where}.args must not set #{reserved}: #{kind.reserved_why}" if reserved

      Launcher.new(key: v["key"], label: str!(v["label"], "#{where}.label"), kind: v["kind"], command: v["command"],
                   args: args.dup.freeze, via_shell: bool!(v["via_shell"], "#{where}.via_shell")).freeze
    end

    def parse_agent_types(v)
      raise ConfigError, "agent_types must be a non-empty list of {#{AGENT_TYPE_KEYS.join(', ')}} (the library ships none)" \
        unless v.is_a?(Array) && v.any?

      list = v.map { |t| parse_agent_type(t) }
      dup = list.map(&:key).tally.select { |_, n| n > 1 }.keys
      raise ConfigError, "agent_types: duplicate key #{dup.first}" if dup.any?
      twice = list.flat_map(&:spawns_for).tally.select { |_, n| n > 1 }.keys
      if twice.any?
        raise ConfigError, "agent_types: column type #{twice.first} is in more than one type's spawns_for " \
                           "(one spawner per column type)"
      end
      list.each do |t|
        f = t.launcher_follows
        next unless f

        where = "agent_types[#{t.key}].launcher_follows"
        src = list.find { |x| x.key == f } or
          raise ConfigError, "#{where}: no agent type #{f.inspect} (#{list.map(&:key).join(', ')})"
        raise ConfigError, "#{where} must name another type" if src.key == t.key
        raise ConfigError, "#{where}: #{f} itself follows #{src.launcher_follows} (one level only)" if src.launcher_follows
        missing = src.launchers - t.launchers
        if missing.any?
          raise ConfigError, "#{where}: #{f} runs #{missing.join(', ')}, which #{t.key}.launchers lacks — " \
                             "it could never follow it"
        end
      end

      list.freeze
    end

    def parse_agent_type(v)
      # `spawns_for` / `launcher_follows` / `spawn_launcher` are optional (a host without per-card sessions / a lead / a
      # type with one launcher omits them); every other key is required
      shape!(v.is_a?(Hash) ? v.reject { |k, _| OPTIONAL_AGENT_TYPE_KEYS.include?(k) } : v, AGENT_TYPE_KEYS, "agent_types[]")
      raise ConfigError, "agent_types[].key must match #{LAUNCHER_KEY.source}" \
        unless v["key"].is_a?(String) && v["key"].match?(LAUNCHER_KEY)
      where = "agent_types[#{v['key']}]"
      ls = v["launchers"]
      raise ConfigError, "#{where}.launchers must be a non-empty list of launcher keys (#{launcher_keys.join(', ')})" \
        unless ls.is_a?(Array) && ls.any? && ls.all? { |k| launcher_keys.include?(k) }
      raise ConfigError, "#{where}.launchers: duplicate key" if ls.uniq.size != ls.size
      model = v["model"]
      one = ->(m) { m.nil? || (m.is_a?(String) && m.match?(MODEL)) }
      if model.is_a?(Hash)
        unless model.keys.sort == ls.sort
          raise ConfigError, "#{where}.model: a map must name exactly #{where}.launchers (#{ls.join(', ')}), " \
                             "got #{model.keys.join(', ')}"
        end
        bad = model.find { |_, m| !one.(m) }
        raise ConfigError, "#{where}.model[#{bad[0]}] must be null or match #{MODEL.source}" if bad
        model = model.dup.freeze
      else
        raise ConfigError, "#{where}.model must be null, match #{MODEL.source}, or map each launcher to one" unless one.(model)
      end
      follows = v["launcher_follows"]
      raise ConfigError, "#{where}.launcher_follows must be an agent type key or null" \
        unless follows.nil? || (follows.is_a?(String) && follows.match?(LAUNCHER_KEY))
      spawn = v["spawn_launcher"]
      raise ConfigError, "#{where}.spawn_launcher must be one of #{where}.launchers (#{ls.join(', ')}) or null" \
        unless spawn.nil? || ls.include?(spawn)
      raise ConfigError, "#{where}.prompt must be a string or null" unless v["prompt"].nil? || v["prompt"].is_a?(String)
      # the prompt is ONE argv word: one starting with "-" would be read as an option (a `--settings` with hooks)
      raise ConfigError, "#{where}.prompt must not start with \"-\": #{Launch::PROMPT_DASH}" if v["prompt"]&.start_with?("-")
      placeholders!(v["prompt"], PROMPT_VARS, "#{where}.prompt") if v["prompt"]
      name = str!(v["agent_name"], "#{where}.agent_name")
      placeholders!(name, AGENT_NAME_VARS, "#{where}.agent_name")
      raise ConfigError, "#{where}.agent_name must contain {session} (one name per session)" unless name.include?("{session}")
      sname = str!(v["session_name"], "#{where}.session_name")
      placeholders!(sname, SESSION_NAME_VARS, "#{where}.session_name")
      raise ConfigError, "#{where}.session_name must contain {slug} (the tmux session is named after its board)" \
        unless sname.include?("{slug}")
      %w[max max_per_project].each do |k|
        raise ConfigError, "#{where}.#{k} must be null, 0 (no cap) or an integer >= 1" \
          unless v[k].nil? || (v[k].is_a?(Integer) && v[k] >= 0)
      end
      AgentType.new(
        key: v["key"], label: str!(v["label"], "#{where}.label"), launchers: ls.dup.freeze, model: model, prompt: v["prompt"],
        agent_name: name, session_name: sname, takes: types!(v["takes"], "#{where}.takes"),
        max: v["max"]&.nonzero?, max_per_project: v["max_per_project"]&.nonzero?,
        spawns_for: types!(v.fetch("spawns_for", []), "#{where}.spawns_for"), launcher_follows: follows,
        spawn_launcher: spawn
      ).freeze
    end

    # Every {placeholder} in a template must be one the engine renders — an unknown one would reach the agent verbatim.
    def placeholders!(tpl, allowed, where)
      bad = tpl.scan(/\{([^{}\s]*)\}/).flatten.uniq - allowed
      return if bad.empty?

      raise ConfigError, "#{where}: unknown placeholder {#{bad.first}} (allowed: #{allowed.map { |a| "{#{a}}" }.join(' ')})"
    end

    def parse_concurrency(v)
      shape!(v, CONCURRENCY_KEYS, "concurrency")
      m = v["max_sessions"]
      unless m.is_a?(Integer) && m >= 0
        raise ConfigError, "concurrency.max_sessions must be an integer >= 0 " \
                           "(agent sessions running at once on the host; 0 = no cap)"
      end
      m = nil if m.zero? # 0 = endless: the engine reads nil as "no cap"

      Concurrency.new(max_sessions: m).freeze
    end

    def parse_owner_sessions(v)
      return nil if v.nil?
      unless v.is_a?(Array) && v.any? && v.all? { |x| x.is_a?(String) && x.match?(OWNER_SESSION_GLOB) }
        raise ConfigError, "owner_sessions must be null or a non-empty list of session-name globs " \
                           "(#{OWNER_SESSION_GLOB.source})"
      end
      raise ConfigError, "owner_sessions: duplicate pattern" if v.uniq.size != v.size

      v.map(&:dup).each(&:freeze).freeze
    end
  end
end
