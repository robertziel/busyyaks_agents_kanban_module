# frozen_string_literal: true

require "test_helper"

# WORKFLOW v3 (BoardRepo#migrate_v3!, SPEC § 9): every stored board — the template too — moves to the fixed type set:
# the ask column is removed (its cards return to the column they came from, flagged needs_operator), handoff and
# approved columns become gates, stale questions outside the ask column are cleared; a `reshape` replaces a board's
# whole shape and moves its cards by a map (the private local-repo boards, named mirror boards then). The legacy rows
# are written directly: Board.new refuses the v2 types now.
class MigrateV3Test < Minitest::Test
  include KanbanTest::Setup
  Invalid = AgentsKanban::Invalid

  V2_CODING = {
    "columns" => [%w[backlog Backlog parked], ["todo", "To do", "queued"], ["human_input", "Human input", "asks_operator"],
                  ["doing", "In progress", "working"], %w[qa QA review], ["human_check", "Human Check", "handoff"],
                  ["ready", "Ready to merge", "approved"], %w[merged Merged done],],
    "transitions" => [
      { "name" => "Start work", "from" => "todo", "to" => "doing", "by" => "any" },
      { "name" => "Ask the operator", "from" => %w[doing qa], "to" => "human_input", "by" => "agent" },
      { "name" => "Answer", "from" => "human_input", "to" => "doing", "by" => "any" },
      { "name" => "Ask alone", "from" => "qa", "to" => "human_input", "by" => "agent" },
      { "name" => "Hand over", "from" => %w[doing human_input], "to" => "human_check", "by" => "agent" },
      { "name" => "Approve", "from" => "human_check", "to" => "ready", "by" => "operator" },
      { "name" => "Merge", "from" => "ready", "to" => "merged", "by" => "any" },
      { "name" => "Move", "from" => "*", "to" => "*", "by" => "any" },
    ],
  }.freeze

  def t(name) = db[:"#{KanbanTest::PREFIX}#{name}"]

  # the v2 rows as the live DB holds them (the legacy_v2 fixture for the v2 private board)
  def write_v2(slug, shape)
    t(:boards).where(project_slug: slug).delete
    t(:board_columns).where(project_slug: slug).delete
    t(:board_transitions).where(project_slug: slug).delete
    t(:boards).insert(project_slug: slug, updated_by: "op", updated_at: 500, created_at: 500)
    shape["columns"].each_with_index do |c, i|
      key, label, type = c.is_a?(Array) ? c : c.values_at("key", "label", "type")
      row = { project_slug: slug, key: key, label: label, type: type, position: i, hide_after_hours: type == "done" ? 24 : 72 }
      if t(:board_columns).columns.include?(:x) # a v8 table still has the graph positions
        row[:x] = i * 10
        row[:y] = 0
      end
      t(:board_columns).insert(row)
    end
    shape["transitions"].each_with_index do |tr, i|
      t(:board_transitions).insert(project_slug: slug, position: i, name: tr["name"], from_keys: JSON.generate(tr["from"]),
                                   to_key: tr["to"], by: tr["by"])
    end
  end

  def card(slug, column, title, **more)
    t(:cards).insert({ project_slug: slug, column: column, position: 0, title: title, created_by: "op", created_at: 100,
                       updated_at: 100, }.merge(more))
  end

  def move(id, body, at)
    t(:card_activity).insert(card_id: id, kind: "move", body: body, author: "x", created_at: at)
  end

  def repo = AgentsKanban::BoardRepo.new(db, tables: kb.tables, host: config, clock: -> { @now }, known: ->(_) { true })
  def migrate(reshape: {})
    repo.migrate_v3!(cards_t: t(:cards), activity_t: t(:card_activity), by: "migration", reshape: reshape)
  end

  def setup
    super
    kb # seeds the (v3) template; the tests below overwrite the rows with v2 shapes
    write_v2("", V2_CODING)
    write_v2("g/r", V2_CODING)
  end

  def test_the_mechanical_migration_flags_returned_cards_and_retypes_the_gates
    asked = card("g/r", "human_input", "asked", asked_at: 700, question: "Which?")
    move(asked, "In progress → Human input", 650)
    dialog = card("g/r", "human_input", "dialog", question: "press 1")
    move(dialog, "To do → In progress", 300)
    move(dialog, "QA → Human input (session dialog: 1/2/esc)", 710)
    stale = card("g/r", "qa", "answered long ago", asked_at: 400, question: "old", question_options: '["a"]')
    archived = card("g/r", "human_input", "archived", archived_at: 800, asked_at: 790)
    move(archived, "In progress → Human input", 780)
    checked = card("g/r", "human_check", "handed")
    report = migrate
    assert_equal %w[g/r], report.keys - [""], "the template and the project"
    assert_equal({ "human_check" => "handoff → gate", "ready" => "approved → gate" }, report["g/r"]["columns"])
    assert_equal [3, 1], report["g/r"].values_at("flagged", "flag_cleared")
    assert_equal({}, report["g/r"]["moved"])
    assert_equal({ "columns" => { "human_check" => "handoff → gate", "ready" => "approved → gate" }, "flagged" => 0,
                   "flag_cleared" => 0, "moved" => {}, }, report[""])
    b = repo.fetch("g/r", by: "x")
    assert_equal %w[backlog todo doing qa human_check ready merged], b.keys
    assert_equal %w[gate gate], %w[human_check ready].map { |k| b.type_of(k).key }
    assert_equal ["Start work", "Hand over", "Approve", "Merge", "Move"],
                 b.to_h["transitions"].map { |x| x["name"] }, "the edges into / out of the ask column are gone"
    assert_equal "doing", b.to_h["transitions"][1]["from"], "a list that lost the ask column shrinks to one key"
    rows = t(:cards).where(id: [asked, dialog, stale, archived, checked]).order(:id).all
    assert_equal ["doing", 700, "Which?"], rows[0].values_at(:column, :asked_at, :question), "back where it came from, flagged"
    assert_equal ["qa", 710, "press 1"], rows[1].values_at(:column, :asked_at, :question),
                 "the LAST move into the ask column names the column; asked_at filled from it"
    assert_equal ["qa", nil, nil, nil], rows[2].values_at(:column, :asked_at, :question, :question_options), "stale: cleared"
    assert_equal ["doing", 790], rows[3].values_at(:column, :asked_at), "archived cards leave the column too"
    assert_equal ["human_check", nil], rows[4].values_at(:column, :asked_at)
    assert_equal ["Human input → In progress (workflow v3: Human input is a flag — needs_operator kept)", "migration"],
                 t(:card_activity).where(card_id: asked, kind: "move").order(:id).last.values_at(:body, :author)
    assert_equal 1, t(:cards).where(project_slug: "g/r", column: "doing").where { position > 0 }.count, "positions appended"
    # the store reads the migrated board and shows the flag
    assert kb.card_json(kb.card(asked))[:needs_operator]
    assert_equal({ "g/r" => 2 }, kb.flagged_counts(["g/r"]))
  end

  def test_a_card_whose_origin_is_unknown_refuses_the_migration
    lost = card("g/r", "human_input", "created here")
    e = assert_raises(Invalid) { migrate }
    assert_match(/card ##{lost} \(g\/r\) sits in Human input and the activity log does not say which column it came from/,
                 e.message)
    assert_equal "asks_operator", t(:board_columns).where(project_slug: "g/r", key: "human_input").get(:type), "nothing written"
    assert_equal "human_input", t(:cards).where(id: lost).get(:column)
  end

  def test_reshape_replaces_a_boards_shape_and_moves_its_cards_by_the_map
    write_v2("p", KanbanTest.board_hash("legacy_v2"))
    asked = card("p", "human_input", "asked", asked_at: 700, question: "Deploy?")
    move(asked, "PR approved (mirror) → Human input", 690)
    deployed = card("p", "deployed", "deployed")
    done = card("p", "merged", "public", archived_at: 900)
    v2keys = KanbanTest.board_hash("legacy_v2")["columns"].map { |c| c["key"] }
    map = { "backlog" => "backlog", "todo" => "todo", "doing" => "doing", "human_check" => "mirror_human_review",
            "approved_mirror" => "mirror_merged", "local_merged" => "mirror_merged", "deployed" => "deploy_check",
            "make_public" => "public_agent_review", "public_review" => "public_human_review", "ready" => "awaiting_merge",
            "merged" => "done", }
    assert_equal v2keys - ["human_input"], map.keys
    report = migrate(reshape: { "p" => { "board" => KanbanTest.board_hash("mirror_v3"), "cards" => map } })
    assert_equal 1, report["p"]["flagged"]
    assert_equal({ "approved_mirror → mirror_merged" => 1, "deployed → deploy_check" => 1, "merged → done" => 1 },
                 report["p"]["moved"])
    b = repo.fetch("p", by: "x")
    assert_equal KanbanTest.board_hash("mirror_v3")["columns"].map { |c| c["key"] }, b.keys
    assert_equal 3, b.approvals.size
    rows = t(:cards).where(id: [asked, deployed, done]).order(:id).all
    assert_equal [%w[mirror_merged deploy_check done], [700, nil, nil]],
                 [rows.map { |r| r[:column] }, rows.map { |r| r[:asked_at] }]
    assert_equal "approved_mirror → mirror_merged (workflow v3)",
                 t(:card_activity).where(card_id: asked, kind: "move").order(:id).last[:body]
    assert_equal 500, t(:boards).where(project_slug: "p").get(:updated_at), "the board row keeps its time"
    # a map that misses a column the cards sit in is refused, nothing written
    write_v2("o/other", KanbanTest.board_hash("legacy_v2"))
    card("o/other", "deployed", "x")
    e = assert_raises(Invalid) {
 migrate(reshape: { "o/other" => { "board" => KanbanTest.board_hash("mirror_v3"), "cards" => {} } }) }
    assert_match(/board of o\/other: no v3 column for cards in deployed/, e.message)
    assert_equal "parked", t(:board_columns).where(project_slug: "o/other", key: "deployed").get(:type)
  end

  def test_a_board_that_does_not_fit_after_v3_is_named
    shape = { "columns" => [%w[a A working], %w[h H handoff]], "transitions" => [] } # no done column
    write_v2("p", shape)
    e = assert_raises(Invalid) { migrate }
    assert_match(/board of p after v3: the board has no done column/, e.message)
  end
end
