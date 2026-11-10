# frozen_string_literal: true

require "test_helper"

# COLUMN RENAME (BoardRepo#rename_columns!, SPEC § 9): a host renames columns (key and / or label) and transitions on
# every stored board that holds them — the template too; the cards, their review rounds and the labels their move /
# create entries name follow; the inverse maps undo it. The fixture pair: mirror_v3 (the v3 migration's target, frozen)
# renamed by MAP is local_v3.
class RenameColumnsTest < Minitest::Test
  include KanbanTest::Setup
  Invalid = AgentsKanban::Invalid

  MAP = {
    "mirror_agent_review" => { "key" => "local_agent_review", "label" => "Local: Agent review" },
    "mirror_author" => { "key" => "local_author", "label" => "Local: Author response" },
    "mirror_human_review" => { "key" => "local_human_review", "label" => "Local: Human review" },
    "mirror_merged" => { "key" => "local_merged_pr", "label" => "Local: Merged" },
    "deploy_check" => { "label" => "Local: Deploy check" },
  }.freeze
  NAMES = { "Open mirror PR" => "Open local PR" }.freeze
  BACK = {
    "local_agent_review" => { "key" => "mirror_agent_review", "label" => "Mirror: Agent review" },
    "local_author" => { "key" => "mirror_author", "label" => "Mirror: Author response" },
    "local_human_review" => { "key" => "mirror_human_review", "label" => "Mirror: Human review" },
    "local_merged_pr" => { "key" => "mirror_merged", "label" => "Mirror merged" },
    "deploy_check" => { "label" => "Local deploy check" },
  }.freeze

  def t(name) = db[:"#{KanbanTest::PREFIX}#{name}"]
  def repo = AgentsKanban::BoardRepo.new(db, tables: kb.tables, host: config, clock: -> { @now }, known: ->(_) { true })

  def rename(columns = MAP, transitions = NAMES)
    repo.rename_columns!(columns: columns, transitions: transitions, cards_t: t(:cards), activity_t: t(:card_activity),
                         by: "migration")
  end

  def card(slug, column, **more)
    t(:cards).insert({ project_slug: slug, column: column, position: 0, title: "c", created_by: "op", created_at: 100,
                       updated_at: 100, }.merge(more))
  end

  def act(id, kind, body) = t(:card_activity).insert(card_id: id, kind: kind, body: body, author: "x", created_at: 200)

  def setup
    super
    kb # the coding template
    repo.save("p", KanbanTest.board_hash("mirror_v3"), by: "op", cards_in: ->(*) { {} })
    repo.fetch("g/r", by: "op") # a coding board: no renamed column
  end

  def test_the_mirror_v3_board_becomes_local_v3_and_its_cards_follow
    rounds = JSON.generate("mirror_agent_review" => 2, "public_agent_review" => 1,
                           "_rereview" => { "mirror_agent_review" => 2 })
    a = card("p", "mirror_human_review", review_rounds: rounds)
    archived = card("p", "mirror_merged", archived_at: 300)
    act(a, "create", "created in In progress · owner session: s (x)")
    act(a, "move", "In progress → Mirror: Agent review (no owner)")
    act(a, "move", "Mirror: Agent review → Mirror: Human review")
    act(archived, "create", "created in Mirror merged")
    act(archived, "move", "Mirror: Human review → Mirror merged")
    act(a, "comment", "Mirror merged soon") # a comment is history: never rewritten
    other = card("g/r", "human_check")
    act(other, "move", "In progress → Human Check")

    report = rename
    assert_equal %w[p], report.keys, "only the board holding the columns (the coding template and g/r have none)"
    assert_equal({ "columns" => 5, "transitions" => 1, "cards" => 2, "rounds" => 1, "activity" => 4 }, report["p"])
    assert_equal KanbanTest.board_hash("local_v3"), repo.fetch("p", by: "x").to_h.slice("columns", "transitions")
    assert_equal %w[local_human_review local_merged_pr], t(:cards).where(id: [a, archived]).order(:id).select_map(:column)
    assert_equal({ "local_agent_review" => 2, "public_agent_review" => 1, "_rereview" => { "local_agent_review" => 2 } },
                 JSON.parse(t(:cards).where(id: a).get(:review_rounds)))
    assert_equal ["created in In progress · owner session: s (x)", "In progress → Local: Agent review (no owner)",
                  "Local: Agent review → Local: Human review", "Mirror merged soon",],
                 t(:card_activity).where(card_id: a).order(:id).select_map(:body)
    assert_equal ["created in Local: Merged", "Local: Human review → Local: Merged"],
                 t(:card_activity).where(card_id: archived).order(:id).select_map(:body)
    assert_equal ["In progress → Human Check"], t(:card_activity).where(card_id: other).select_map(:body)
    assert_equal "human_check", t(:cards).where(id: other).get(:column)
    # the store reads it: the card waits in the renamed gate, its "since" read from the relabelled move
    w = kb.waiting_cards(["p"]).by_slug.fetch("p").first
    assert_equal [a, "Local: Human review", 200], w.values_at(:id, :column_label, :since)
  end

  def test_the_inverse_maps_undo_it
    a = card("p", "mirror_author", review_rounds: JSON.generate("mirror_agent_review" => 1))
    act(a, "move", "Mirror: Agent review → Mirror: Author response")
    rename
    report = rename(BACK, NAMES.invert)
    assert_equal({ "columns" => 5, "transitions" => 1, "cards" => 1, "rounds" => 1, "activity" => 1 }, report["p"])
    assert_equal KanbanTest.board_hash("mirror_v3"), repo.fetch("p", by: "x").to_h.slice("columns", "transitions")
    assert_equal ["mirror_author", '{"mirror_agent_review":1}'], t(:cards).where(id: a).get(%i[column review_rounds])
    assert_equal ["Mirror: Agent review → Mirror: Author response"], t(:card_activity).where(card_id: a).select_map(:body)
    assert_empty rename(BACK), "nothing holds the local keys any more"
  end

  def test_slugs_limits_the_boards
    repo.save("o/other", KanbanTest.board_hash("mirror_v3"), by: "op", cards_in: ->(*) { {} })
    report = repo.rename_columns!(columns: MAP, transitions: NAMES, cards_t: t(:cards), activity_t: t(:card_activity),
                                  by: "migration", slugs: ["o/other", "nope"])
    assert_equal %w[o/other], report.keys
    assert_includes repo.fetch("p", by: "x").keys, "mirror_merged", "p was not named"
    assert_equal "Local deploy check", repo.fetch("p", by: "x").label("deploy_check")
  end

  def test_the_template_is_renamed_too
    repo.save(AgentsKanban::Board::TEMPLATE, KanbanTest.board_hash("mirror_v3"), by: "op", cards_in: ->(*) { {} })
    assert_equal ["", "p"], rename.keys
    assert_includes repo.template.keys, "local_merged_pr"
  end

  def test_a_key_the_board_already_has_is_refused_and_nothing_is_written
    a = card("p", "mirror_author")
    e = assert_raises(Invalid) { rename({ "mirror_author" => { "key" => "doing" } }) }
    assert_equal "board of p: already has column doing — rename refused", e.message
    assert_equal "mirror_author", t(:cards).where(id: a).get(:column)
    assert_includes repo.fetch("p", by: "x").keys, "mirror_author"
  end

  def test_two_columns_may_swap_keys_and_each_card_moves_once
    a = card("p", "mirror_author", updated_at: 100)
    b2 = card("p", "public_author", updated_at: 100)
    report = rename({ "mirror_author" => { "key" => "public_author" }, "public_author" => { "key" => "mirror_author" } }, {})
    assert_equal 2, report["p"]["cards"]
    assert_equal %w[public_author mirror_author], [a, b2].map { |id| t(:cards).where(id: id).get(:column) },
                 "swapped in one statement — not both into one column"
    assert_equal [100, 100], t(:cards).where(id: [a, b2]).select_map(:updated_at), "a rename is no change to the card"
    b = repo.fetch("p", by: "x")
    assert_equal ["Mirror: Author response", "Public: Author response"], [b.label("public_author"), b.label("mirror_author")]
  end

  def test_a_board_that_no_longer_validates_is_refused_with_its_name
    # the review loop's columns are host config: a review column renamed to a working one is still a review column, so
    # the board stays valid — but two columns onto one key, an empty name or an unknown field never reach the boards
    e = assert_raises(Invalid) { rename({ "mirror_author" => { "key" => "x" }, "public_author" => { "key" => "x" } }) }
    assert_equal "column rename: two columns onto x", e.message
    e = assert_raises(Invalid) { rename({ "mirror_author" => { "key" => " " } }) }
    assert_equal "column rename of mirror_author: give a new key or label", e.message
    e = assert_raises(Invalid) { rename({ "mirror_author" => { "type" => "gate" } }) }
    assert_equal "column rename of mirror_author: unknown fields type", e.message
    e = assert_raises(Invalid) { rename({}) }
    assert_equal "a column rename needs at least one column", e.message
    e = assert_raises(Invalid) { rename(MAP, { "Open mirror PR" => "" }) }
    assert_match(/a transition rename needs two non-empty names/, e.message)
    e = assert_raises(Invalid) do
      repo.rename_columns!(columns: MAP, cards_t: t(:cards), activity_t: t(:card_activity), by: " ")
    end
    assert_equal "author is required", e.message
    e = assert_raises(Invalid) { rename({ "mirror_author" => { "key" => "Bad Key!" } }) }
    assert_match(/\Aboard of p after the rename: /, e.message)
    assert_includes repo.fetch("p", by: "x").keys, "mirror_author", "nothing written"
  end
end
