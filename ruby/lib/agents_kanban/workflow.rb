# frozen_string_literal: true

require "json"
require_relative "errors"

module AgentsKanban
  # A WORKFLOW — a value object: the named transitions a card may take between a board's columns (Jira's model:
  # "Start work", "Send for review", "Reject"…). It is one half of a Board (board.rb; the other half is the columns with
  # their types): it says WHICH moves exist, who may take them, and what each is called. A move with no matching edge
  # is refused with the edges that do exist from where the card is (Store#move). Gated moves (handoff / ask / approve)
  # are still governed by their gates first; the workflow must also carry an edge for them.
  #
  #   [ { "name": "Start work",      "from": "todo",          "to": "doing",       "by": "any" },
  #     { "name": "Send for review", "from": ["doing", "qa"], "to": "human_check", "by": "agent" },
  #     { "name": "Move",            "from": "*",             "to": "*",           "by": "any" } ]   # catch-all = a free board
  #
  # `from` / `to`: a column key, a list of keys (from only), or "*" (every column; an edge to "*" fans out and is named by
  # `transition:` only together with the `column` it goes to). `by`: operator | agent | any. A name has one target per
  # source column otherwise. A bad list raises Invalid (an operator's edit, refused with the reason).
  class Workflow
    EDGE_KEYS = %w[name from to by].freeze
    ACTORS = %w[operator agent any].freeze
    ANY = "*"
    EDGE_NAME = /\A[[:alnum:]][[:alnum:] _.\/'-]{0,59}\z/
    MAX_TRANSITIONS = 200
    Edge = Struct.new(:name, :from, :to, :by, :fan_out, keyword_init: true) do
      def usable_by?(actor) = by == "any" || by == actor.to_s
    end

    attr_reader :edges, :declared

    # transitions: the declared list; keys: the board's column keys in order.
    def initialize(transitions, keys:)
      raise Invalid, "transitions must be a list of {#{EDGE_KEYS.join(', ')}}" unless transitions.is_a?(Array)
      raise Invalid, "at most #{MAX_TRANSITIONS} transitions" if transitions.size > MAX_TRANSITIONS

      @keys = keys.map(&:to_s).freeze
      t = JSON.parse(JSON.generate(transitions)) # string keys, detached: what to_a returns and the rows store
      @declared = t.freeze
      @edges = t.each_with_index.flat_map { |e, i| expand(e, i) }.freeze
      unique!
      freeze
    end

    # Edges out of `column` (for `actor` :operator / :agent when given), in the declared order.
    def from(column, actor: nil) = @edges.select { |e| e.from == column && (actor.nil? || e.usable_by?(actor)) }
    # The edge column → to the actor may take, or nil.
    def edge(from:, to:, actor:) = @edges.find { |e| e.from == from && e.to == to && e.usable_by?(actor) }
    # The edge named `name` (case-insensitive) out of `from` for the actor — `to` picks among a fan-out's targets.
    def named(from:, name:, actor:, to: nil)
      @edges.find { |e| e.from == from && e.name.casecmp?(name.to_s) && e.usable_by?(actor) && (to.nil? || e.to == to.to_s) }
    end

    # What was declared (not the expanded edges): what the editor shows and the rows store.
    def to_a = @declared
    def ==(other) = other.is_a?(Workflow) && other.to_a == to_a

    private

    def expand(e, i)
      where = "transitions[#{i}]"
      unless e.is_a?(Hash) && e.keys.sort == EDGE_KEYS.sort
        raise Invalid, "#{where} must be an object with exactly #{EDGE_KEYS.join(', ')}"
      end
      unless e["name"].is_a?(String) && e["name"].match?(EDGE_NAME)
        raise Invalid, "#{where}.name must match #{EDGE_NAME.source} (got #{e['name'].inspect})"
      end
      raise Invalid, "#{where}.by must be one of #{ACTORS.join(', ')} (got #{e['by'].inspect})" unless ACTORS.include?(e["by"])
      raise Invalid, "#{where}.to must be one column or \"*\" (a transition has one target)" if e["to"].is_a?(Array)

      froms = columns!(e["from"], "#{where}.from")
      tos = columns!(e["to"], "#{where}.to")
      froms.product(tos).reject { |f, t| f == t }.map do |f, t|
        Edge.new(name: e["name"], from: f, to: t, by: e["by"], fan_out: e["to"] == ANY).freeze
      end
    end

    def columns!(v, where)
      return @keys if v == ANY

      list = v.is_a?(Array) ? v : [v]
      raise Invalid, "#{where} must be a column key (#{@keys.join(', ')}), a list of them, or \"*\" (got #{v.inspect})" \
        if list.empty? || !list.all? { |k| k.is_a?(String) && @keys.include?(k) }
      raise Invalid, "#{where}: duplicate column" if list.uniq.size != list.size

      list
    end

    def unique!
      dup = @edges.group_by { |e| [e.name.downcase, e.from, e.to, e.by] }.find { |_, v| v.size > 1 }&.first
      raise Invalid, "duplicate transition #{dup[0].inspect} #{dup[1]} → #{dup[2]} (#{dup[3]})" if dup

      # case-insensitive, like the lookup (`named`): "Go" and "go" are one name
      @edges.reject(&:fan_out).group_by { |e| [e.name.downcase, e.from] }.each do |(n, from), es|
        tos = es.map(&:to).uniq
        if tos.size > 1
          raise Invalid, "transition #{n.inspect} from #{from} goes to #{tos.join(' and ')} — one name, one target per column"
        end
      end
    end
  end
end
