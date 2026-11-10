# frozen_string_literal: true

require "json"
require_relative "errors"
require_relative "column_types"
require_relative "workflow"

module AgentsKanban
  # A BOARD — the value object every rule reads: a project's columns (key, label, TYPE, order) and its
  # workflow (named transitions). Kept per project in the database (BoardRepo; SPEC § 2), edited by the operator in
  # the graph editor, instantiated from the template row for a project that has none yet. Nothing here is a constant of
  # the engine and nothing is configured twice: every rule a column obeys is DERIVED from its type (ColumnTypes) and the
  # host's few parameters (HostConfig: the handoff gate's requirements, whether dependencies are enforced).
  #
  #   { "columns": [ { "key": "todo", "label": "To do", "type": "queued", "hide_after_hours": 72 }, … ],
  #     "transitions": [ { "name": "Start work", "from": "todo", "to": "doing", "by": "any" }, … ] }
  #
  # Validation (Invalid with the reason — an operator's save refused, a stored row that no longer fits named loudly):
  #   - at least one column; keys [a-z][a-z0-9_]{0,39}, unique; labels non-empty; a known type each (no graph position:
  #     the editor lays the graph out itself every time — SPEC § 2; an `x` / `y` is an unknown key, refused)
  #   - hide_after_hours (optional on input): an integer 0..MAX_HIDE_HOURS — a card with no update for that long is folded
  #     behind the list's "Load older" (0 = never); absent = the type's default (ColumnTypes); to_h always carries it
  #   - at most one column of each singleton type (queued, done, cancelled)
  #   - exactly one done column: what "finished" means on this board
  #   - a gate column needs the host's `handoff` parameters (HostConfig) — null there and a gate column = refused
  #   - the transitions as Workflow validates them (known columns, actors, no duplicates, one name → one target)
  #
  # Derived (the one place; the client gets the same under `rules`): default_column = the FIRST column; waiting /
  # listened / operator_only / agent_no_create / terminal = the columns whose type carries the flag; the gates: handoff
  # = the gate columns + the host's parameters (agents enter a gate only with kanban_handoff), approvals = the approval
  # STEPS (derive_approvals: each gate's ONE forward operator exit), watchdog = the first working column → the queued
  # column (both present); dependencies (when the host enforces them): done = the done column, blocked = queued +
  # working + review, promote = parked → queued; idle_column = the first working column; review_columns = where review
  # rounds are counted; the watchdog's watched columns = the listened ones.
  class Board
    KEYS = %w[columns transitions].freeze
    COLUMN_KEYS = %w[key label type].freeze
    OPTIONAL_COLUMN_KEYS = %w[hide_after_hours].freeze
    MAX_HIDE_HOURS = 24 * 365
    KEY_RE = /\A[a-z][a-z0-9_]{0,39}\z/
    MAX_COLUMNS = 30
    MAX_LABEL = 60
    TEMPLATE = "" # the template board's project slug in the repository: the board of no project in particular

    Column = Struct.new(:key, :label, :type, :hide_after_hours, keyword_init: true) do
      def to_h = { key: key, label: label, type: type.key, hide_after_hours: hide_after_hours }
    end
    # The handoff gate: the gate columns (agents enter them only with kanban_handoff) + what the host requires of one.
    Handoff = Struct.new(:columns, :requires_pr_url, :requires_ci_url, :qa_min_chars, :ui_change_needs_screenshots,
                         keyword_init: true)
    # One approval step: the operator moving a card `from` (a gate) → `to` approves it (approved_at / approved_by, a
    # ping to the owner); `then` = where its agent takes it next (nil = no single named way on); `name` = the declared
    # transition's name; `final` = `then` is the done column (the agent merges and finishes).
    Approval = Struct.new(:from, :to, :then, :name, :final, keyword_init: true) do
      def to_h = { from: from, to: to, then: self.then, name: name, final: final }
    end
    Watchdog = Struct.new(:from, :to, keyword_init: true)
    Promote = Struct.new(:from, :to, keyword_init: true)
    Dependencies = Struct.new(:done, :blocked, :promote, keyword_init: true)

    attr_reader :columns, :workflow, :handoff, :approvals, :watchdog, :dependencies

    # host: HostConfig (handoff parameters, dependencies on/off, the agent types' takes / spawns_for by type).
    def initialize(hash, host:)
      raise Invalid, "a board must be an object {columns, transitions}" unless hash.is_a?(Hash)

      h = JSON.parse(JSON.generate(hash))
      unknown = h.keys - KEYS
      missing = KEYS - h.keys
      raise Invalid, "board: unknown keys #{unknown.join(', ')}" if unknown.any?
      raise Invalid, "board: missing keys #{missing.join(', ')}" if missing.any?

      @host = host
      @columns = parse_columns(h["columns"])
      @by_key = @columns.to_h { |c| [c.key, c] }.freeze
      singletons!
      @workflow = Workflow.new(h["transitions"], keys: keys)
      @handoff = derive_handoff
      @approvals = derive_approvals
      @watchdog = derive_watchdog
      @dependencies = derive_dependencies
      done_column!
      freeze
    end

    # ── the columns ───────────────────────────────────────────────────────────────────────────────

    def keys = @columns.map(&:key)
    def labels = @columns.to_h { |c| [c.key, c.label] }
    def column?(key) = @by_key.key?(key.to_s)
    def column(key) = @by_key.fetch(key.to_s) { raise Invalid, "no column #{key.inspect} (#{keys.join(', ')})" }
    def label(key) = column(key).label
    def type_of(key) = column(key).type
    def of_type(*types) = @columns.select { |c| types.flatten.map(&:to_s).include?(c.type.key) }.map(&:key)
    def one_of_type(type) = of_type(type).first
    def default_column = @columns.first.key
    def index(key) = keys.index(key.to_s)
    # {key => hours}: how long a card in the column may go without an update before the list folds it (0 = never).
    def hide_after_hours = @columns.to_h { |c| [c.key, c.hide_after_hours] }

    # ── the derived rules ─────────────────────────────────────────────────────────────────────────

    def waiting = flagged(:waiting)
    def listened = flagged(:listened)
    def operator_only = flagged(:operator_only)
    def agent_no_create = flagged(:agent_no_create)
    def no_create_for_agents = agent_no_create
    def terminal = flagged(:terminal)
    def done_columns = flagged(:finishes)
    def done?(key) = column?(key) && type_of(key).finishes
    def terminal?(key) = column?(key) && type_of(key).terminal
    def gate_columns = of_type("gate")
    def gate?(key) = column?(key) && type_of(key).key == "gate"
    def working_columns = of_type("working")
    def working?(key) = column?(key) && type_of(key).key == "working"
    def review_columns = of_type("review")
    def review?(key) = column?(key) && type_of(key).key == "review"
    # The approval step the operator's move from → to IS (nil = a plain move), the step out of / into a column.
    def approval_for(from, to) = @approvals.find { |a| a.from == from && a.to == to }
    def approval_from(column) = @approvals.find { |a| a.from == column }
    def approval_into(column) = @approvals.find { |a| a.to == column }

    # May an agent never move a card INTO this column except through a gate? The operator-only columns — but a done
    # column on a board with no gate is open to anyone (that is how a worker finishes a card there).
    def agent_closed?(key) = operator_only.include?(key) && !(done?(key) && gate_columns.empty?)
    # The columns the watchdog watches: a card elsewhere (parked, terminal) keeps its owner and assignee as history.
    def watched_columns = (listened + [@watchdog&.from].compact).uniq
    # The columns whose cards the owner watchdog releases when their owner session is gone: every column but the
    # terminal ones (a finished or cancelled card keeps its owner as history). Parked too: a Backlog card created by a
    # worker that has since ended kept that dead session as owner, so moving it to To do spawned nobody and the
    # operator's move pinged a session that was not running. Released there = owner + assignee cleared, no move.
    def owner_watched_columns = @columns.map(&:key) - terminal
    # The work column the idle watch looks at: the first working column (nil = none on this board).
    def idle_column = one_of_type("working")
    # The agent type whose sessions ADOPT ownerless cards here (its `takes` names column types) → the column keys.
    def takes_columns(agent_type) = of_type(agent_type.takes)
    # One new session per ownerless card: the columns some agent type `spawns_for` (by type), and the type for a column.
    def spawn_columns = of_type(@host.agent_types.flat_map(&:spawns_for))
    def spawner_for(column) = @host.agent_types.find { |t| t.spawns_for.include?(type_of(column).key) }
    # The columns an agent may move a card to from `column` by a named edge (fan-outs excluded).
    def agent_targets(column) = @workflow.from(column, actor: :agent).reject(&:fan_out).map(&:to).uniq
    # The gate columns an agent in `column` may hand a card to: the named agent edges out of it into a gate.
    def handoff_targets(column)
      @workflow.from(column, actor: :agent).reject(&:fan_out).map(&:to).select { |k| gate?(k) }.uniq
    end

    # ── JSON ──────────────────────────────────────────────────────────────────────────────────────

    # What was declared: what the editor shows and the rows store.
    def to_h = { "columns" => @columns.map { |c| JSON.parse(JSON.generate(c.to_h)) }, "transitions" => @workflow.to_a }
    def ==(other) = other.is_a?(Board) && other.to_h == to_h

    # The rules the client renders from (the same derivation the engine enforces), beside the declared shape.
    def rules
      { default_column: default_column, waiting: waiting, listened: listened, operator_only: operator_only,
        agent_no_create: no_create_for_agents, terminal: terminal,
        gates: { handoff: @handoff&.to_h, approvals: @approvals.map(&:to_h), watchdog: @watchdog&.to_h },
        dependencies: @dependencies && { done: @dependencies.done, blocked: @dependencies.blocked,
                                         promote: @dependencies.promote&.to_h, },
        idle_column: idle_column, review_columns: review_columns, spawn_columns: spawn_columns,
        hide_after_hours: hide_after_hours, }
    end

    private

    def flagged(flag) = @columns.select { |c| c.type[flag] }.map(&:key)

    def parse_columns(v)
      raise Invalid, "columns must be a non-empty list of {#{COLUMN_KEYS.join(', ')}}" unless v.is_a?(Array) && v.any?
      raise Invalid, "at most #{MAX_COLUMNS} columns" if v.size > MAX_COLUMNS

      cols = v.each_with_index.map do |c, i|
        where = "columns[#{i}]"
        unless c.is_a?(Hash) && (COLUMN_KEYS - c.keys).empty? && (c.keys - COLUMN_KEYS - OPTIONAL_COLUMN_KEYS).empty?
          raise Invalid, "#{where} must be an object with #{COLUMN_KEYS.join(', ')} " \
                         "(and optionally #{OPTIONAL_COLUMN_KEYS.join(', ')})"
        end
        unless c["key"].is_a?(String) && c["key"].match?(KEY_RE)
          raise Invalid, "#{where}.key #{c['key'].inspect} must match #{KEY_RE.source}"
        end
        where = "column #{c['key']}"
        unless c["label"].is_a?(String) && !c["label"].strip.empty? && c["label"].strip.length <= MAX_LABEL
          raise Invalid, "#{where}: label must be a non-empty string (≤ #{MAX_LABEL})"
        end
        unless ColumnTypes.known?(c["type"])
          legacy = ColumnTypes::LEGACY.key?(c["type"].to_s)
          hint = legacy ? " (a workflow v2 type: BoardRepo#migrate_v3! retypes stored boards)" : ""
          raise Invalid, "#{where}: type #{c['type'].inspect} is not one of #{ColumnTypes.keys.join(', ')}#{hint}"
        end
        type = ColumnTypes.fetch(c["type"])
        hide = c.fetch("hide_after_hours", nil)
        hide = type.hide_after_hours if hide.nil?
        unless hide.is_a?(Integer) && (0..MAX_HIDE_HOURS).cover?(hide)
          raise Invalid, "#{where}: hide_after_hours must be an integer 0..#{MAX_HIDE_HOURS} (0 = never hide)"
        end

        Column.new(key: c["key"], label: c["label"].strip, type: type, hide_after_hours: hide).freeze
      end
      dup = cols.map(&:key).tally.select { |_, n| n > 1 }.keys
      raise Invalid, "duplicate column key #{dup.first}" if dup.any?

      cols.freeze
    end

    def singletons!
      @columns.group_by { |c| c.type }.each do |t, cs|
        next unless t.singleton && cs.size > 1

        raise Invalid, "columns #{cs.map(&:key).join(' and ')} are both #{t.key}: a board has at most one #{t.key} column"
      end
    end

    # Every board ends in exactly one done column: what "finished" means on it (a card there finishes a parent; a session
    # whose cards all sit there is finished). No done column = no way to tell a finished card from a parked one.
    def done_column!
      return if one_of_type("done")

      raise Invalid, "the board has no done column (type done): every board needs one, where a finished card goes"
    end

    def derive_handoff
      cols = gate_columns
      return nil if cols.empty?

      p = @host.handoff or
        raise Invalid, "column #{cols.first} is a gate but the host config has handoff: null (the gate's requirements)"
      Handoff.new(columns: cols, requires_pr_url: p.requires_pr_url, requires_ci_url: p.requires_ci_url,
                  qa_min_chars: p.qa_min_chars, ui_change_needs_screenshots: p.ui_change_needs_screenshots).freeze
    end

    # The approval STEPS: every operator move a card waits for in a gate before its agent carries on, so the card
    # dialog offers an approve button on each. Read off the types + the workflow, no key named: a gate's ONE named
    # operator-only transition FORWARD (into a non-terminal column later in board order — Human review → Merged,
    # Public review → Awaiting merge, Human Check → Ready to merge). Backward exits (Changes requested, Rework) and
    # exits into a cancelled column are never approvals; two or more forward exits are a choice of route: no step.
    # `then` = where the agent takes the card from `to` (next_for_agent); `final` = that is the done column.
    def derive_approvals
      steps = gate_columns.filter_map do |g|
        exits = @workflow.edges.select do |e|
          e.from == g && e.by == "operator" && !e.fan_out && !terminal?(e.to) && index(e.to) > index(g)
        end
        next unless exits.size == 1

        e = exits.first
        on = next_for_agent(e.to)
        Approval.new(from: e.from, to: e.to, then: on, name: e.name, final: !on.nil? && done?(on)).freeze
      end
      clash = steps.map(&:to).tally.find { |_, n| n > 1 }
      if clash
        raise Invalid, "two approval steps lead into column #{clash.first} — an approval moves a card from ONE gate into " \
                       "ONE column"
      end

      steps.freeze
    end

    # Where an agent takes a card next from `column`: the ONE named transition agents may take out of it that is not
    # back to a work column, or nil.
    def next_for_agent(column)
      tos = @workflow.from(column, actor: :agent).reject { |e| e.fan_out || working?(e.to) }.map(&:to).uniq
      tos.size == 1 ? tos.first : nil
    end

    def derive_watchdog
      from = one_of_type("working")
      to = one_of_type("queued")
      from && to ? Watchdog.new(from: from, to: to).freeze : nil
    end

    def derive_dependencies
      return nil unless @host.dependencies

      done = done_columns
      raise Invalid, "the host enforces dependencies but the board has no done column (what finishes a parent)" if done.empty?

      parked = of_type("parked")
      queued = one_of_type("queued")
      promote = parked.any? && queued ? Promote.new(from: parked, to: queued).freeze : nil
      Dependencies.new(done: done, blocked: of_type("queued", "working", "review"), promote: promote).freeze
    end
  end
end
