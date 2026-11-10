# frozen_string_literal: true

require_relative "errors"

module AgentsKanban
  # Column TYPES — what a column DOES, independent of its key or label (Jira's status categories, extended with this
  # engine's gate). A board names a type per column (Board); every rule the engine applies to a column is DERIVED from
  # its type here — one definition per concept, never a column key in code and never a per-column flag list in a
  # config file. Changing a column's type changes its rules. The set is FIXED (workflow v3): seven categories.
  #
  #   parked     nobody listens; agents may create here; the owner watchdog still releases a card whose owner session
  #              is gone, in place (Backlog)
  #   queued     work waiting for a session: listened; the watchdog returns a released work card here; an agent type
  #              may `spawns_for` it (one new session per ownerless card) (To do)
  #   working    a work column (several per board: In progress, Author response): listened; the FIRST one in board
  #              order is THE work column — the watchdog releases from it → the queued column, the idle watch looks
  #              there; a released card in any other working column stays where it is
  #   review     a further work column, an agent's or the system's: listened, no watchdog move (Agent review, Merged)
  #   gate       the card waits for the OPERATOR: waiting, listened, the operator's. Agents enter only with the
  #              handoff gate (kanban_handoff: how to check it, PR, CI, screenshots); the operator's ONE forward exit
  #              is an approval step (approved_at, a ping to the owner); an agent leaves a gate only along a named
  #              agent transition and only once approved (Human review, Local deploy check, Awaiting merge)
  #   done       finished: finishes a parent (dependencies), terminal, the operator's (agents enter only from a gate,
  #              approved — a board without a gate lets anyone finish a card — and never leave), agents cannot create
  #              here, keeps owner / assignee as history (Done, Merged)
  #   cancelled  stopped: terminal, the operator's only (agents never enter nor leave, cannot create here), finishes
  #              nothing (a child of a cancelled parent still waits — cancel it too), keeps owner / assignee as history
  #
  # Flags: waiting ("N waiting for you"), listened (an assignee with no owner session = "no listener"; the watchdog
  # scans it), operator_only (agents never move a card out, nor in except through a gate), agent_no_create, finishes
  # (a parent in it is done), terminal (the card's work is over: the owner watchdog leaves it alone, the review rounds
  # stop counting), singleton (at most one column of the type per board: the rules that need ONE target).
  #
  # Cross-cutting FLAGS on a card (needs_operator, blocked_external) are not types: a flagged card keeps its column.
  #
  # hide_after_hours: the type's DEFAULT for a column's `hide_after_hours` (Board) — a card in the column with no update
  # for that long is folded behind the list's "Load older" (a view rule: nothing is archived or moved). Operator, card
  # #125: the terminal columns 24 h, the parked (backlog) columns a week, every other 72 h; a board's column may
  # override it (0 = never folded).
  module ColumnTypes
    FLAGS = %i[waiting listened operator_only agent_no_create finishes terminal singleton].freeze
    Type = Struct.new(:key, :label, :summary, :hide_after_hours, *FLAGS, keyword_init: true) do
      def to_h
        { key: key, label: label, summary: summary, hide_after_hours: hide_after_hours, **FLAGS.to_h { |f| [f, self[f]] } }
      end
    end

    ALL = [
      Type.new(
        key: "parked", label: "Parked", hide_after_hours: 168,
        summary: "nobody listens; agents may create here; a card whose owner session is gone is released in place",
        waiting: false, listened: false, operator_only: false, agent_no_create: false, finishes: false, terminal: false,
        singleton: false
      ),
      Type.new(
        key: "queued", label: "Queued", hide_after_hours: 72,
        summary: "work waiting for a session: listened; released work cards return here; a spawner type starts one " \
                 "session per card",
        waiting: false, listened: true, operator_only: false, agent_no_create: false, finishes: false, terminal: false,
        singleton: true
      ),
      Type.new(
        key: "working", label: "Working", hide_after_hours: 72,
        summary: "a work column: listened; the first one is where the watchdog releases from and the idle watch looks",
        waiting: false, listened: true, operator_only: false, agent_no_create: false, finishes: false, terminal: false,
        singleton: false
      ),
      Type.new(
        key: "review", label: "Review", hide_after_hours: 72,
        summary: "a further work column (an agent's review, the system's): listened, no watchdog move; review rounds " \
                 "are counted per column",
        waiting: false, listened: true, operator_only: false, agent_no_create: false, finishes: false, terminal: false,
        singleton: false
      ),
      Type.new(
        key: "gate", label: "Gate", hide_after_hours: 72,
        summary: "waits for the operator: agents enter only with kanban_handoff; the operator's one forward exit " \
                 "approves; an agent leaves only along a named transition once approved",
        waiting: true, listened: true, operator_only: true, agent_no_create: false, finishes: false, terminal: false,
        singleton: false
      ),
      Type.new(
        key: "done", label: "Done", hide_after_hours: 24,
        summary: "finished: finishes a parent; terminal; the operator's (agents enter only from a gate, approved); " \
                 "agents cannot create here",
        waiting: false, listened: false, operator_only: true, agent_no_create: true, finishes: true, terminal: true,
        singleton: true
      ),
      Type.new(
        key: "cancelled", label: "Cancelled", hide_after_hours: 24,
        summary: "stopped: terminal; only the operator moves a card in or out; finishes nothing; agents cannot " \
                 "create here",
        waiting: false, listened: false, operator_only: true, agent_no_create: true, finishes: false, terminal: true,
        singleton: true
      ),
    ].each(&:freeze).freeze
    BY_KEY = ALL.to_h { |t| [t.key, t] }.freeze
    KEYS = ALL.map(&:key).freeze
    # workflow v2's types and what each became (BoardRepo#migrate_v3!): the ask column is gone — a card that waited there
    # carries the needs_operator FLAG in the column it came from.
    LEGACY = { "asks_operator" => nil, "handoff" => "gate", "approved" => "gate" }.freeze

    module_function

    def keys = KEYS
    def known?(key) = BY_KEY.key?(key.to_s)
    def fetch(key) = BY_KEY[key.to_s] || raise(Invalid, "unknown column type #{key.inspect} (one of #{KEYS.join(', ')})")
    def json = ALL.map(&:to_h)
  end
end
