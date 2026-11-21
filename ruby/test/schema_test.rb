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
    S.migrate!(db, prefix: p, to: 12)
    pw = %i[progress_at progress_marks progress_pinged_at progress_commented_at progress_stale_at]
    assert_empty db.schema(t[:cards]).map(&:first) & pw, "v12 has no progress watch stretch"
    S.migrate!(db, prefix: p, to: 14, prs: nil)
    assert_empty db.schema(t[:cards]).map(&:first) & %i[on_hold_at on_hold_by], "v14 has no hold"
    S.migrate!(db, prefix: p) # = to: VERSION
    assert_equal %i[on_hold_at on_hold_by], db.schema(t[:cards]).map(&:first) & %i[on_hold_at on_hold_by],
                 "v15 = + cards.on_hold_at / on_hold_by"
    assert_equal pw, db.schema(t[:cards]).map(&:first) & pw, "v13 = + the progress watch's stretch on the card"
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

  # v14: a card's prs {role => url} → a list; by / at from the card's own "PR <role>: <url>" line (null when none says);
  # idempotent; prs_to_roles! is the rollback, refused while a card holds what v12 cannot.
  def test_v14_prs_become_lists_and_the_rollback_refuses_what_v11_cannot_hold
    db = KanbanTest.db
    p = "v14_#{Process.pid}_"
    t = S.migrate!(db, prefix: p, to: 11)
    l = "https://github.com/o/r_local/pull/5"
    pub = "https://github.com/o/r/pull/9"
    card = lambda do |meta|
      db[t[:cards]].insert(project_slug: "p", column: "doing", position: 0, title: "t", notes: "", labels: "[]",
                           created_by: "a", created_at: 1, updated_at: 1, metadata: meta && JSON.generate(meta))
    end
    a = card.call("prs" => { "local" => l, "public" => pub }, "draft_id" => 3)
    b = card.call("k" => 1)
    c = card.call(nil)
    d = card.call("prs" => { "local" => "https://github.com/o/r_local/pull/6" },
                  "prs_replaced" => [{ "role" => "local", "url" => "https://github.com/o/r_local/pull/4", "by" => "x",
                                       "at" => 7, }])
    db[t[:card_activity]].insert(card_id: a, kind: "update", body: "PR local: #{l}", author: "agent-1", created_at: 50)
    db[t[:card_activity]].insert(card_id: a, kind: "update", body: "PR local: #{l}5", author: "nope", created_at: 60)
    assert_match(/card #{a} holds PRs in the \{role => url\} shape: migrate!\(…, prs:\) needs the host's PR roles port/,
                 assert_raises(ArgumentError) { S.migrate!(db, prefix: p, to: 14) }.message)
    S.migrate!(db, prefix: p, to: 14, prs: ROLES)
    meta = ->(id) { (m = db[t[:cards]].where(id: id).get(:metadata)) && JSON.parse(m) }
    assert_equal({ "draft_id" => 3, "prs" => [
                   { "url" => l, "repo" => "o/r_local", "number" => 5, "role" => "local", "by" => "agent-1", "at" => 50 },
                   { "url" => pub, "repo" => "o/r", "number" => 9, "role" => "public", "by" => nil, "at" => nil },
                 ], }, meta.call(a))
    assert_equal({ "k" => 1 }, meta.call(b))
    assert_nil meta.call(c)
    assert_equal [["https://github.com/o/r_local/pull/6"], ["https://github.com/o/r_local/pull/4"], nil],
                 [meta.call(d)["prs"].map { |x| x["url"] }, meta.call(d)["prs_removed"].map { |x| x["url"] },
                  meta.call(d)["prs_replaced"],]
    assert_equal "replaced under the one-PR-per-role rule", meta.call(d)["prs_removed"].first["reason"]
    again = meta.call(a)
    S.migrate!(db, prefix: p, to: 14, prs: ROLES)
    assert_equal again, meta.call(a), "idempotent"
    e = assert_raises(ArgumentError) { S.prs_to_roles!(db, prefix: p) }
    assert_match(/cards #{d} hold several PRs of one role or unassigned PRs/, e.message)
    assert_equal again, meta.call(a), "a refused rollback writes nothing"
    db[t[:cards]].where(id: d).delete
    S.prs_to_roles!(db, prefix: p)
    assert_equal({ "draft_id" => 3, "prs" => { "local" => l, "public" => pub } }, meta.call(a))
    bad = card.call("prs" => { "local" => "https://example.com/x" })
    e = assert_raises(ArgumentError) { S.prs_to_lists!(db, prefix: p, prs: ROLES) }
    assert_match(/card #{bad} metadata prs.local is not a GitHub PR URL/, e.message)
    assert_equal({ "local" => l, "public" => pub }, meta.call(a)["prs"], "a raise for one card writes none")
  ensure
    (S::TABLES + [:workflows]).reverse_each { |x| db.drop_table?(:"#{p}#{x}") }
  end

  # the host's PR roles port for the v14 step: an enrolled project's local / public repos (busyyaks + the engine), a
  # plain project's own repo
  class Roles
    def pr_roles(card)
      case card[:project_slug]
      when "p", "group/app", "host"
        { "local" => { repos: %w[o/r_local o/app_mirror o/eng_local],
                       required: true, },
          "public" => { repos: %w[o/r o/app o/eng], required: false }, }
      when "o/site" then { "pr" => { repos: ["o/site"], required: false } }
      when "both" then { "a" => { repos: ["x/y"] }, "b" => { repos: ["x/y"] } }
      when "plain" then { "pr" => { repos: ["o/fleet"], required: false } }
      when "group/other" then { "pr" => { repos: ["o/other"], required: false } }
      else raise "project #{card[:project_slug]} is not a scanned project"
      end
    end
  end
  # the host explains a `local` PR on a project that is not enrolled (busyyaks: PrStates::Roles#unread_reason)
  class Explaining < Roles
    def unread_reason(card, role, repo)
      return nil unless role == "local" && %w[plain group/other].include?(card[:project_slug])

      "v14: #{repo} is in no role this project reads (project not enrolled)"
    end
  end
  ROLES = Roles.new
  EXPLAINING = Explaining.new

  # cards c393 / c394 / c424: a `local` PR on a project that is not enrolled, in no role of the
  # card — removed (kept, logged), never active; without the host's reason the step raises
  def test_v14_keeps_a_pr_in_no_role_as_removed_when_the_host_says_why
    db = KanbanTest.db
    p = "v14u_#{Process.pid}_"
    t = S.migrate!(db, prefix: p, to: 11)
    card = lambda do |slug, prs|
      db[t[:cards]].insert(project_slug: slug, column: "todo", position: 0, title: "t", notes: "", labels: "[]",
                           created_by: "a", created_at: 1, updated_at: 1, metadata: JSON.generate("prs" => prs))
    end
    c393 = card.call("group/other", { "local" => "https://github.com/o/other_local/pull/1" })
    c394 = card.call("plain", { "local" => "https://github.com/o/fleet_local/pull/4" })
    c424 = card.call("plain", { "local" => "https://github.com/o/fleet_local/pull/5" })
    e = assert_raises(ArgumentError) { S.migrate!(db, prefix: p, to: 14, prs: ROLES) }
    assert_match(%r{card #{c393} .*o/other_local is in no role's repos}, e.message)
    S.migrate!(db, prefix: p, to: 14, prs: EXPLAINING, now: 777)
    meta = ->(id) { JSON.parse(db[t[:cards]].where(id: id).get(:metadata)) }
    assert_equal({ "prs" => [], "prs_removed" => [{
                   "url" => "https://github.com/o/fleet_local/pull/4",
                   "repo" => "o/fleet_local",
                   "number" => 4, "role" => "local", "by" => nil, "at" => nil,
                   "reason" => "v14: o/fleet_local is in no role this project reads (project not enrolled)",
                   "removed_by" => "migration", "removed_at" => 777,
                 }], }, meta.call(c394))
    assert_equal [[], ["https://github.com/o/other_local/pull/1"]],
                 meta.call(c393).values_at("prs", "prs_removed").then { |a, r| [a, r.map { |x| x["url"] }] }
    assert_equal ["https://github.com/o/fleet_local/pull/5"], meta.call(c424)["prs_removed"].map { |x| x["url"] }
    line = db[t[:card_activity]].where(card_id: c394).first
    assert_equal ["update", "migration", 777, "PR local removed by the v14 migration: " \
                  "https://github.com/o/fleet_local/pull/4 — v14: o/fleet_local is in no " \
                  "role this project reads (project not enrolled)",], line.values_at(:kind, :author, :created_at, :body)
    S.migrate!(db, prefix: p, to: 14, prs: EXPLAINING, now: 888)
    assert_equal 3, db[t[:card_activity]].count, "a second run logs nothing again"
  ensure
    (S::TABLES + [:workflows]).reverse_each { |x| db.drop_table?(:"#{p}#{x}") }
  end

  # v14 on real-world values: free text naming several PRs, legacy role keys mapped by repo
  def test_v14_splits_free_text_and_maps_legacy_role_keys_by_repo
    db = KanbanTest.db
    p = "v14l_#{Process.pid}_"
    t = S.migrate!(db, prefix: p, to: 11)
    card = lambda do |slug, prs|
      db[t[:cards]].insert(project_slug: slug, column: "doing", position: 0, title: "t", notes: "", labels: "[]",
                           created_by: "a", created_at: 1, updated_at: 1, metadata: JSON.generate("prs" => prs))
    end
    c63 = card.call("group/app", {
      "local" => "https://github.com/o/app_local/pull/1 + /pull/2 (merged: 3f4863a, 48709bb)",
      "public" => "https://github.com/o/app/pull/3 (v1.6.0, 1 commit dcec167; PR 2 closed, superseded)",
    })
    c158 = card.call("group/app", {
      "mirror" => "https://github.com/o/app_mirror/pull/5 (merged → a476b54) + /pull/10 (merged → dcefc04)",
      "public" => "https://github.com/o/app/pull/4 (merged → main 0f912c9)",
    })
    c271 = card.call("host", { "engine" => "https://github.com/o/eng/pull/2" })
    c301 = card.call("host",
                     { "public_engine" => "https://github.com/o/eng/pull/5" })
    c412 = card.call("o/site", { "staging" => "https://github.com/o/site/pull/125" })
    db[t[:card_activity]].insert(card_id: c63, kind: "update", author: "agent-7", created_at: 40,
                                 body: "PR local: https://github.com/o/app_local/pull/1 + /pull/2 " \
                                       "(merged: 3f4863a, 48709bb)")
    S.migrate!(db, prefix: p, to: 14, prs: ROLES)
    got = lambda do |id|
      JSON.parse(db[t[:cards]].where(id: id).get(:metadata))["prs"].map { |e| e.values_at("role", "url", "by") }
    end
    bp = "https://github.com/o/app"
    assert_equal [["local", "#{bp}_local/pull/1", "agent-7"], ["local", "#{bp}_local/pull/2", "agent-7"],
                  ["public", "#{bp}/pull/3", nil],], got.call(c63)
    assert_equal [["local", "#{bp}_mirror/pull/5", nil], ["local", "#{bp}_mirror/pull/10", nil],
                  ["public", "#{bp}/pull/4", nil],],
                 got.call(c158), "mirror = the local repo's role"
    assert_equal [["public", "https://github.com/o/eng/pull/2", nil]], got.call(c271)
    assert_equal ["public"], got.call(c301).map(&:first)
    assert_equal ["pr"], got.call(c412).map(&:first)
  ensure
    (S::TABLES + [:workflows]).reverse_each { |x| db.drop_table?(:"#{p}#{x}") }
  end

  # down restores every mapped entry under its original key(s) (from_roles): the cards below (c271's
  # `engine`, c412's `staging`, a plain project's `local` + `pr` naming one PR) come back exactly as they were
  def test_v14_rollback_restores_the_original_role_keys
    db = KanbanTest.db
    p = "v14d_#{Process.pid}_"
    t = S.migrate!(db, prefix: p, to: 11)
    card = lambda do |slug, prs|
      db[t[:cards]].insert(project_slug: slug, column: "doing", position: 0, title: "t", notes: "", labels: "[]",
                           created_by: "a", created_at: 1, updated_at: 1, metadata: JSON.generate("prs" => prs))
    end
    eng = "https://github.com/o/eng/pull/2"
    dpg = "https://github.com/o/site/pull/124"
    before = {
      card.call("host", { "public" => "https://github.com/o/eng/pull/8",
                                     "engine" => eng, }) => nil,
      card.call("o/site", { "local" => dpg, "public" => dpg, "pr" => dpg }) => nil,
      card.call("o/site", { "staging" => "https://github.com/o/site/pull/125" }) => nil,
    }
    before.each_key { |id| before[id] = db[t[:cards]].where(id: id).get(:metadata) }
    S.migrate!(db, prefix: p, to: 14, prs: ROLES)
    meta = ->(id) { JSON.parse(db[t[:cards]].where(id: id).get(:metadata)) }
    plain = before.keys[1]
    assert_equal [["pr", %w[local public pr]]], meta.call(plain)["prs"].map { |e| e.values_at("role", "from_roles") },
                 "one PR under three keys: one entry naming them"
    assert_equal [["public", nil], ["public", ["engine"]]], meta.call(before.keys[0])["prs"].map { |e|
 e.values_at("role", "from_roles") }
    S.prs_to_roles!(db, prefix: p)
    before.each { |id, json| assert_equal JSON.parse(json), meta.call(id), "card #{id} back exactly" }
  ensure
    (S::TABLES + [:workflows]).reverse_each { |x| db.drop_table?(:"#{p}#{x}") }
  end

  # what v14 cannot read raises naming the card and the value, and writes nothing
  def test_v14_refuses_what_it_cannot_map
    db = KanbanTest.db
    p = "v14r_#{Process.pid}_"
    t = S.migrate!(db, prefix: p, to: 11)
    card = lambda do |slug, prs|
      db[t[:cards]].insert(project_slug: slug, column: "doing", position: 0, title: "t", notes: "", labels: "[]",
                           created_by: "a", created_at: 1, updated_at: 1, metadata: JSON.generate("prs" => prs))
    end
    fine = card.call("p", { "local" => "https://github.com/o/r_local/pull/5" })
    {
      { "local" => "see https://github.com/o/r_local/pull/5" } => /prs.local is not a GitHub PR URL: "see https/,
      { "local" => "https://github.com/o/r_local/pull/5 and http://x.example/pull/6" } =>
        /names a PR link the migration cannot read/,
      { "local" => "https://github.com/o/r_local/pull/5/files" } => /prs.local is not a GitHub PR URL/,
      { "local" => "https://github.com/o/r_local/pull/5 + pull/6" } => /names a PR link the migration cannot read/,
      { "local" => "https://github.com/o/r_local/pull/5 and o/c#3" } => /names a PR link the migration cannot read/,
      { "staging" => "https://github.com/x/z/pull/1" } =>
        %r{role "staging" is not one the host reads \(local, public\) and x/z is in no role's repos},
      { "local" => "https://github.com/o/r_local/pull/5", "public" => "https://github.com/o/r_local/pull/5" } =>
        /is named under two roles \(local, public\)/,
    }.each do |prs, said|
      bad = card.call("p", prs)
      e = assert_raises(ArgumentError) { S.migrate!(db, prefix: p, to: 14, prs: ROLES) }
      assert_match(/card #{bad}/, e.message)
      assert_match(said, e.message)
      assert_kind_of Hash, JSON.parse(db[t[:cards]].where(id: fine).get(:metadata))["prs"], "nothing written"
      db[t[:cards]].where(id: bad).delete
    end
    several = card.call("both", { "c" => "https://github.com/x/y/pull/1" })
    assert_match(/x\/y is in several \(a, b\)'s repos/, assert_raises(ArgumentError) {
 S.migrate!(db, prefix: p, to: 14, prs: ROLES) }.message)
    db[t[:cards]].where(id: several).delete
    gone = card.call("nowhere", { "local" => "https://github.com/o/r_local/pull/9" })
    assert_match(/card #{gone}: its PR roles cannot be read \(project nowhere is not a scanned project\)/,
                 assert_raises(ArgumentError) { S.migrate!(db, prefix: p, to: 14, prs: ROLES) }.message)
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
