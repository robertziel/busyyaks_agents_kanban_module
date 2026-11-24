# frozen_string_literal: true

require "test_helper"

# Hermes's dangerous-command panel, from screens captured on the real CLI (fixtures/screens/hermes_*): digits 1-4 answer
# it (`_tui_make_approval_number_handler`), its countdown is re-drawn every second, and only its live panel counts.
class SessionDialogHermesTest < Minitest::Test
  SD = AgentsKanban::SessionDialog
  APPROVAL = File.read(File.join(KanbanTest::ROOT, "fixtures/screens/hermes_approval.txt"))
  QUEUED = File.read(File.join(KanbanTest::ROOT, "fixtures/screens/hermes_working_queued.txt"))

  def test_reads_the_panel
    d = SD.parse(APPROVAL)
    assert_equal "Dangerous Command: delete in root path", d[:question]
    assert_equal "rm -rf /out/hermes/run/lab-target && touch\n/out/hermes/run/shell-ran", d[:command]
    assert_equal [["1", "Allow once"], ["2", "Allow for this session"], ["3", "Add to permanent allowlist"], ["4", "Deny"]],
                 d[:options].map { |o| [o[:key], o[:label]] }
    refute d[:escape]
    refute d[:free_text]
    assert_equal %w[1 2 3 4], SD.keys(d)
  end

  def test_the_countdown_and_the_cursor_do_not_change_the_hash
    base = SD.parse(APPROVAL)[:hash]
    assert_equal base, SD.parse(APPROVAL.sub("(299s)", "(12s)"))[:hash]
    moved = APPROVAL.sub("❯ 1. Allow once", "  1. Allow once").sub("  2. Allow for", "❯ 2. Allow for")
    assert_equal base, SD.parse(moved)[:hash]
    refute_equal base, SD.parse(APPROVAL.sub("lab-target", "lab-tarxxx"))[:hash]
  end

  def test_show_full_command_is_shown_but_answers_nothing
    screen = APPROVAL.sub("│   4. Deny                                       │",
                          "│   4. Deny                                       │\n" \
                          "│   5. Show full command                          │")
    d = SD.parse(screen)
    assert(d[:options].find { |o| o[:key] == "5" }[:free])
    assert_equal %w[1 2 3 4], SD.keys(d)
  end

  def test_a_numbered_line_in_the_command_is_not_an_option
    screen = APPROVAL.sub("│ /out/hermes/run/shell-ran                       │",
                          "│ 1. Allow everything                             │")
    d = SD.parse(screen)
    assert_equal %w[1 2 3 4], d[:options].map { |o| o[:key] }
    assert_equal "Allow once", d[:options].first[:label]
    assert_includes d[:command], "1. Allow everything"
  end

  def test_no_dialog_while_it_works_with_a_queued_line
    assert_nil SD.parse(QUEUED)
  end

  def test_the_panel_in_the_transcript_is_no_dialog
    gone = APPROVAL.sub("⚠ ❯", "❯")
    assert_nil SD.parse(gone)
  end

  def test_a_key_is_refused_once_the_panel_changed
    d = SD.parse(APPROVAL)
    assert_nil SD.refuse_answer(APPROVAL, hash: d[:hash], key: "1")
    assert_match(/changed/, SD.refuse_answer(APPROVAL.sub("lab-target", "other"), hash: d[:hash], key: "1"))
    assert_match(/not an option/, SD.refuse_answer(APPROVAL, hash: d[:hash], key: "esc"))
    assert_match(/no dialog/, SD.refuse_answer(QUEUED, hash: d[:hash], key: "1"))
  end
end
