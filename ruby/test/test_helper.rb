# frozen_string_literal: true

# The suite runs against the database DATABASE_URL names — a throwaway SQLite file by default, a Postgres container
# when the host gives one (docker run … -e DATABASE_URL=postgres://…). KANBAN_PREFIX exercises the table namespace
# (defaults to "kb_" so a collision with a host table of the same name would show here).
require "minitest/autorun"
require "sequel"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../lib/agents_kanban"

module KanbanTest
  ROOT = File.expand_path("../..", __dir__)
  PREFIX = ENV.fetch("KANBAN_PREFIX", "kb_")
  # the content board's tables: its own namespace, so its template never collides with the coding board's in one DB
  CONTENT_PREFIX = "#{PREFIX}c_"
  PREFIXES = [PREFIX, CONTENT_PREFIX].freeze
  URL = ENV.fetch("DATABASE_URL") { "sqlite://#{File.join(Dir.tmpdir, "agents_kanban_test_#{Process.pid}.sqlite3")}" }

  # One connection per test process (a parallel worker is its own process), migrated once at load.
  DB = Sequel.connect(URL).tap { |db| PREFIXES.each { |p| AgentsKanban::Schema.migrate!(db, prefix: p) } }
  # The host fixtures with the suite's table prefix in place of theirs (one database, one namespace under test).
  CONFIGS = %w[coding content].to_h do |name|
    raw = JSON.parse(File.read(File.join(ROOT, "fixtures/boards/#{name}.json")))
    [name, AgentsKanban::HostConfig.new(raw.merge("table_prefix" => name == "content" ? CONTENT_PREFIX : PREFIX))]
  end.freeze

  def self.db = DB
  def self.config(name = "coding") = CONFIGS.fetch(name)
  # The board fixture (columns with types + transitions) as a plain hash — what a host seeds its template from.
  def self.board_hash(name = "coding") = JSON.parse(File.read(File.join(ROOT, "fixtures/boards/#{name}.board.json")))
  def self.markdown(cfg) = AgentsKanban::Markdown.new(attachment_url_prefix: cfg.attachment_url_prefix)

  # Every test starts from empty tables; the clock is a settable integer so timing rules are exact. The board template
  # of the fixture is seeded (a store reads every project's board from the database, instantiated from it).
  module Setup
    # Tools' card_url port: the host's absolute card link (a host-shaped URL, so a test sees slug and id in it).
    CARD_URL = ->(slug, id) { "https://board.example/projects/#{slug}?card=#{id}" }

    attr_accessor :now

    def setup
      super
      db = KanbanTest.db
      KanbanTest::PREFIXES.each { |p| AgentsKanban::Schema::TABLES.reverse_each { |t| db[:"#{p}#{t}"].delete } }
      @now = 1_000
      @boards = %w[g/r p o/other]
      @seeded = {}
    end

    def db = KanbanTest.db
    def config = KanbanTest.config
    def md = KanbanTest.markdown(config)

    # A store on a host config; its board template is the matching fixture's board (coding → coding.board.json) unless
    # one was seeded already for that host.
    def store(cfg = config, board: nil)
      seed_template(cfg, board || KanbanTest.board_hash(cfg.table_prefix == KanbanTest::CONTENT_PREFIX ? "content" : "coding"))
      AgentsKanban::Store.new(
        db,
        config: cfg,
        markdown: KanbanTest.markdown(cfg),
        boards: ->(s) { @boards.include?(s) },
        clock: -> { @now },
        ci: approval_ci,
      )
    end

    # The approval gate's ci: port — green unless a test says otherwise (approval_ci.answer = {...} | nil, .down = "why").
    def approval_ci = (@approval_ci ||= ApprovalCi.new)

    def seed_template(cfg, board)
      repo = AgentsKanban::BoardRepo.new(
        db,
        tables: AgentsKanban::Schema.tables(cfg.table_prefix),
        host: cfg,
        clock: -> { @now },
        known: ->(s) { @boards.include?(s) },
      )
      repo.seed!(template: board, projects: [], by: cfg.system_author) unless repo.template?
      repo
    end

    def kb = (@kb ||= store)
  end
end

PNG = "\x89PNG\r\n\x1A\n\x00\x00\x00\rIHDR".b + ("\x00".b * 40)
JPEG = "\xFF\xD8\xFF\xE0\x00\x10JFIF".b + ("\x00".b * 20)

# The Store's approval-gate port: answers every approval step with `answer` (green by default); `down` raises Unavailable.
class ApprovalCi
  attr_accessor :answer, :down
  attr_reader :asked

  def initialize
    @answer = { number: 7, state: "success", finished_at: 1 }
    @asked = []
  end

  def approval_checks(card, step)
    @asked << [card[:id], step]
    raise AgentsKanban::Delivery::Unavailable, @down if @down

    @answer
  end
end

# A ci: port that knows no PRs (tests that run the notifier on the coding board, which has idle_watch, and don't test it).
class NoCi
  def pr_checks(_card) = nil
  def last_commit_at(_card) = nil
end
