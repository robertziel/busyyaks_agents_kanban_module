# frozen_string_literal: true

require "test_helper"

class SchemaTest < Minitest::Test
  S = AgentsKanban::Schema

  def test_migrate_is_idempotent_and_prefixed
    db = KanbanTest.db
    before = S::TABLES.map { |t| db.schema(:"#{KanbanTest::PREFIX}#{t}").map(&:first) }
    t = S.migrate!(db, prefix: KanbanTest::PREFIX) # a second run changes nothing
    assert_equal before, S::TABLES.map { |x| db.schema(:"#{KanbanTest::PREFIX}#{x}").map(&:first) }
    assert_equal :"#{KanbanTest::PREFIX}cards", t[:cards]
    cols = db.schema(t[:cards]).map(&:first)
    %i[parent_id metadata question dialog_id approved_at pr_url due_at owner_session].each { |c| assert_includes cols, c }
    assert_includes db.schema(t[:card_activity]).map(&:first), :undelivered
  end

  # A host migration is pinned to the schema step it introduced (`to:`): on a fresh DB an old migration creates only what
  # existed then (v5 still has `workflows`, v6 the boards tables), so a rollback lands on the shape main's code expects.
  def test_migrate_to_a_version_creates_only_that_versions_tables
    db = KanbanTest.db
    p = "v_#{Process.pid}_"
    t = S.migrate!(db, prefix: p, to: 3)
    assert db.table_exists?(t[:agent_sessions])
    refute db.table_exists?(:"#{p}ci_watches")
    refute db.table_exists?(:"#{p}workflows")
    S.migrate!(db, prefix: p, to: 5)
    assert db.table_exists?(:"#{p}ci_watches")
    assert db.table_exists?(:"#{p}workflows"), "v5 = the first workflow version's table"
    refute db.table_exists?(t[:boards])
    S.migrate!(db, prefix: p, to: 6)
    assert db.table_exists?(t[:boards])
    refute db.schema(t[:board_columns]).map(&:first).include?(:hide_after_hours), "v6 has no hide_after_hours"
    assert db.schema(t[:board_columns]).map(&:first).include?(:x), "v6 has the graph positions"
    S.migrate!(db, prefix: p, to: 7)
    assert db.schema(t[:board_columns]).map(&:first).include?(:hide_after_hours), "v7 = + board_columns.hide_after_hours"
    refute db.schema(t[:cards]).map(&:first).include?(:blocked_at), "v7 has no card flags"
    S.migrate!(db, prefix: p, to: 8)
    v8 = %i[blocked_at blocked_author blocked_reason blocked_url flag_reminded_at review_rounds]
    assert_equal v8, db.schema(t[:cards]).map(&:first) & v8, "v8 = the card flags + review_rounds"
    assert db.schema(t[:board_columns]).map(&:first).include?(:y), "v8 still has the graph positions"
    S.migrate!(db, prefix: p, to: 9)
    assert_empty db.schema(t[:board_columns]).map(&:first) & %i[x y], "v9 = − board_columns.x / y"
    assert_empty db.schema(t[:cards]).map(&:first) & %i[gate_head gate_state], "v9 has no gate head / state"
    S.migrate!(db, prefix: p) # = to: VERSION
    assert_equal %i[gate_head gate_state], db.schema(t[:cards]).map(&:first) & %i[gate_head gate_state],
                 "v10 = + cards.gate_head / gate_state"
    assert db.table_exists?(:"#{p}workflows"), "migrate! never drops: BoardRepo#seed! carries the rows over and drops it"
    assert_raises(ArgumentError) { S.migrate!(db, prefix: p, to: 99) }
  ensure
    (S::TABLES + [:workflows]).reverse_each { |x| db.drop_table?(:"#{p}#{x}") }
  end

  # A host's v6 migration seeds the boards on a fresh DB before its v7 step adds hide_after_hours: BoardRepo writes the
  # v6 rows, and they read back with the column types' defaults.
  def test_board_repo_seeds_a_v6_database
    db = KanbanTest.db
    p = "v6_#{Process.pid}_"
    t = S.migrate!(db, prefix: p, to: 6)
    host = KanbanTest.config
    repo = AgentsKanban::BoardRepo.new(db, tables: t, host: host, known: ->(_) { true })
    rep = repo.seed!(template: KanbanTest.board_hash("coding"), projects: %w[p], by: "migration")
    assert_equal %w[p], rep[:created]
    refute db.schema(t[:board_columns]).map(&:first).include?(:hide_after_hours)
    # the v6 rows carry the serpentine the v6 editor drew from (x / y are NOT NULL there)
    xy = db[t[:board_columns]].where(project_slug: "p").order(:position).select_map(%i[x y]).first(3)
    assert_equal [[60, 80], [230, 260], [400, 80]], xy
    S.migrate!(db, prefix: p, to: 7)
    hide = AgentsKanban::BoardRepo.new(db, tables: t, host: host, known: ->(_) { true }).fetch("p", by: "x").hide_after_hours
    assert_equal({ "merged" => 24, "backlog" => 168, "todo" => 72 }, hide.slice("merged", "backlog", "todo"))
    S.migrate!(db, prefix: p, to: 9)
    assert_equal AgentsKanban::Board.new(KanbanTest.board_hash("coding"), host: host),
                 AgentsKanban::BoardRepo.new(db, tables: t, host: host, known: ->(_) { true }).fetch("p", by: "x")
  ensure
    (S::TABLES + [:workflows]).reverse_each { |x| db.drop_table?(:"#{p}#{x}") }
  end

  # A host's rollback of its v9 migration: x / y back, NOT NULL, each row at its board position's v6 – v8 serpentine.
  def test_restore_xy_is_the_v9_rollback
    db = KanbanTest.db
    p = "v9_#{Process.pid}_"
    t = S.migrate!(db, prefix: p)
    repo = AgentsKanban::BoardRepo.new(db, tables: t, host: KanbanTest.config, known: ->(_) { true })
    repo.seed!(template: KanbanTest.board_hash("coding"), projects: %w[p], by: "migration")
    S.restore_xy!(db, prefix: p)
    sch = db.schema(t[:board_columns]).to_h
    assert_equal [false, false], [sch[:x][:allow_null], sch[:y][:allow_null]]
    assert_equal [nil, nil], [sch[:x][:ruby_default], sch[:y][:ruby_default]], "no default, as v6 created them"
    xy = db[t[:board_columns]].where(project_slug: "p").order(:position).select_map(%i[position x y])
    assert_equal(xy.map { |i, _, _| [i, 60 + (i * 170), i.even? ? 80 : 260] }, xy)
  ensure
    (S::TABLES + [:workflows]).reverse_each { |x| db.drop_table?(:"#{p}#{x}") }
  end

  # A host DB that predates v2 (busyyaks's live SQLite) gets only the new columns: migrate! on a v1-shaped table.
  def test_adds_missing_columns_to_an_older_table
    db = KanbanTest.db
    p = "old_#{Process.pid}_"
    db.create_table(:"#{p}cards") do
      primary_key :id
      String :project_slug, null: false
      String :column, null: false
      Integer :position, null: false
      String :title, null: false
      String :notes, text: true, null: false, default: ""
      String :labels, text: true, null: false, default: "[]"
      String :assignee
      String :priority
      String :created_by, null: false
      Integer :created_at, null: false
      Integer :updated_at, null: false
      Integer :archived_at
    end
    db[:"#{p}cards"].insert(
      project_slug: "x", column: "todo", position: 0, title: "t", created_by: "me", created_at: 1, updated_at: 1,
    )
    S.migrate!(db, prefix: p)
    cols = db.schema(:"#{p}cards").map(&:first)
    assert_includes cols, :parent_id
    assert_includes cols, :metadata
    assert_equal "t", db[:"#{p}cards"].first[:title], "existing rows survive"
    assert db.table_exists?(:"#{p}session_dialogs")
  ensure
    S::TABLES.reverse_each { |x| db.drop_table?(:"#{p}#{x}") }
  end
end
