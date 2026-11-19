# frozen_string_literal: true

require "test_helper"
require "stringio"

# The progress watch (config.progress_watch): a card in a working / review column with no progress for N min pings its
# owner naming the last evidence, N min later gets one system comment, N min after that counts as waiting for the
# operator — each step once per stretch; any progress (card activity, a change in the ci: port's evidence) resets it.
class ProgressWatchTest < Minitest::Test
  include KanbanTest::Setup

  N = 30 * 60 # the coding host's stale_minutes

  # The Store's ci: port with the progress evidence (and the approval gate the coding host needs).
  class ProgressCi < ApprovalCi
    attr_accessor :items, :down

    def initialize
      super
      @items = []
    end

    def progress_kinds = ["PR head", "CI on the head", "branch commits"]

    def progress(card)
      raise AgentsKanban::Delivery::Unavailable, @down if @down

      @items.map { |e| e.transform_values { |v| v.is_a?(Proc) ? v.call(card) : v } }
    end
  end

  class FakeClient
    attr_reader :sent

    def initialize = @sent = []
    def notify(session:, socket:, text:) = (@sent << [session, text]; { "ok" => true })
    def agents = { "age_s" => 1, "interval_s" => 5, "sessions" => [] }
    def sessions = [{ "name" => "shop" }]
    def dialog(**) = { "ok" => true, "dialog" => nil }
  end

  def setup
    super
    @pci = ProgressCi.new
    @kb = AgentsKanban::Store.new(db, config: config, markdown: md, boards: ->(s) { @boards.include?(s) },
                                      clock: -> { @now }, ci: @pci, prs: pr_roles)
    seed_template(config, KanbanTest.board_hash)
    @id = kb.create(slug: "p", title: "ship the thing", by: "lead", column: "doing")
    kb.set_owner(@id, session: "shop", by: "lead")
    @t0 = @now
    @client = FakeClient.new
    @log = StringIO.new
    @n = AgentsKanban::Notifier.new(kb, client: @client, ci: NoCi.new, clock: -> { @now }, grace: 60, log: @log)
  end

  def pass = kb.progress_watch_pass
  def acts(kind) = db[:"#{KanbanTest::PREFIX}card_activity"].where(card_id: @id, kind: kind, author: "busyyaks").all
  def comments = acts("comment")
  def pings = db[:"#{KanbanTest::PREFIX}card_pings"].where(card_id: @id, reason: "progress").all
  def waiting? = kb.waiting_counts(["p"]).waiting["p"].to_i == 1
  def card = kb.card(@id)
  # three passes N apart: a stretch that began by now reaches its last step
  def quiet! = 3.times { (@now += N) && pass }

  # Walks the three steps from the stretch that began at t; asserts each happens exactly at its time, and once.
  def escalate(from)
    @now = from + N - 1
    assert_equal [], pass, "nothing before N min"
    @now = from + N
    assert_equal [[@id, :ping]], pass
    assert_equal [], pass, "the ping once"
    @now = from + (2 * N) - 1
    assert_equal [], pass
    @now = from + (2 * N)
    assert_equal [[@id, :comment]], pass
    refute waiting?, "the comment does not make it wait yet"
    @now = from + (3 * N)
    assert_equal [[@id, :waiting]], pass
    assert_equal [], pass, "each step once per stretch"
    @now += 10 * N
    assert_equal [], pass, "and never again while it stays quiet"
  end

  def test_a_quiet_card_is_pinged_then_commented_then_waits_and_each_step_happens_once
    kb.comment(@id, body: "starting", author: "lead")
    @n.deliver # the comment's own ping (one pending ping per card + session: a later one would join it)
    cid = db[:"#{KanbanTest::PREFIX}card_activity"].where(card_id: @id, kind: "comment").get(:id)
    escalate(@t0)
    assert_equal 1, pings.size
    at = Time.at(@t0).strftime("%H:%M")
    assert_includes pings.first[:text], "No progress on card ##{@id} \"ship the thing\" (In progress, p) for 30 min " \
                                        "— last: comment ##{cid} at #{at}."
    assert_equal 1, comments.size
    assert_includes comments.first[:body], "**No progress** on this card for 60 min in In progress (owner shop was " \
                                           "pinged at #{Time.at(@t0 + N).strftime('%H:%M')})"
    assert waiting?
    c = card
    assert c[:waiting]
    assert_equal "no progress for 90 min (since #{at})", c[:progress_stale]
    assert_equal "no progress for 90 min (since #{at})", kb.card_json(c)[:progress_stale]
    w = kb.waiting_cards(["p"])
    assert_equal [@id], w.by_slug["p"].map { |x| x[:id] }
    assert_equal @t0 + (3 * N), w.by_slug["p"].first[:since], "waiting since the step that made it wait"
    @client.sent.clear
    @n.deliver
    assert_equal ["shop"], @client.sent.map(&:first), "the ping reaches the owner"
  end

  def attachments
    @attachments ||= begin
      @att_root = Dir.mktmpdir("pw-att")
      AgentsKanban::Attachments.new(kb, root: @att_root, clock: -> { @now },
                                        policy: AgentsKanban::AttachmentPolicy.new(max_bytes: 200, types: "image/png"))
    end
  end

  def teardown
    FileUtils.rm_rf(@att_root) if @att_root
    super
  end

  # only the spec's kinds are progress: an edit, an owner change, a terminal event are not
  def test_edits_owner_changes_and_other_entries_are_not_progress
    @now = @t0 + N
    assert_equal [[@id, :ping]], pass
    @now += 60
    kb.update(@id, { "title" => "ship it now" }, by: "operator@example.com")
    kb.set_owner(@id, session: "shop2", by: "lead")
    kb.send(:log, @id, "terminal", "operator opened a terminal", "operator@example.com") # Store#terminal_event's kind
    @now = @t0 + (2 * N)
    assert_equal [[@id, :comment]], pass, "the stretch still runs from the card's creation"
  end

  # a kind the port leaves out for a pass (a read that came back empty, a deleted branch) is no progress, and when it
  # comes back with the same key neither — no step ever repeats in one stretch
  def test_a_vanished_or_flapping_mark_never_restarts_the_stretch
    @pci.items = [{ kind: "PR head", key: "aaa", text: "PR o/r#5 head aaa1111" },
                  { kind: "branch card/1", key: "c1", text: "branch card/1 at c1c1c1c" },]
    pass
    @now = @t0 + N
    assert_equal [[@id, :ping]], pass
    @pci.items = [@pci.items.first] # the branch is deleted
    @now += 60
    assert_equal [], pass
    @pci.items = [] # the port answers nothing for a pass
    @now += 60
    assert_equal [], pass
    @pci.items = [{ kind: "PR head", key: "aaa", text: "PR o/r#5 head aaa1111" },
                  { kind: "branch card/1", key: "c1", text: "branch card/1 at c1c1c1c" },]
    @now += 60
    assert_equal [], pass, "back with the same keys: no progress"
    @now = @t0 + (2 * N)
    assert_equal [[@id, :comment]], pass
    @now = @t0 + (3 * N)
    assert_equal [[@id, :waiting]], pass
    assert_equal 1, pings.size, "the ping never repeated"
    assert_equal 1, comments.size, "nor the comment"
    refute_includes kb.card(@id).to_s, "gone", "a gone mark is never shown as evidence"
    @pci.items = [{ kind: "PR head", key: "bbb", text: "PR o/r#5 head bbb2222" }]
    @now += 60
    pass
    refute waiting?, "a new key is progress"
  end

  # any error of the port (not only Delivery::*) skips the card with its reason, kept on the card until it answers
  def test_a_port_error_of_any_class_is_said_on_the_card
    @pci.singleton_class.define_method(:progress) { |_card| raise ArgumentError, "bad row" }
    assert_equal [[@id, "unavailable: ArgumentError: bad row"]], pass
    assert_equal "ArgumentError: bad row", kb.card_json(card)[:progress_error]
    @pci.singleton_class.send(:remove_method, :progress)
    pass
    assert_nil kb.card_json(card)[:progress_error]
  end

  # a watcher that raises (a host port's bug) is said and skipped for the pass: the other watchers still run
  # (the watcher itself raises: a raising port is caught per card inside Store#approval_prefetch_pass,
  # so the watcher's pass is what raises here)
  def test_a_raising_watcher_never_aborts_the_watch_pass
    kb.singleton_class.define_method(:approval_prefetch_pass) { raise "boom" }
    @now = @t0 + N
    @n.watch
    assert_includes @log.string, "approval prefetch skipped: RuntimeError: boom"
    assert_includes @log.string, "progress watch: card #{@id} no progress, owner pinged"
  end

  # the coding host runs both watchers: on a quiet card in the progress watch's scope only the progress watch comments;
  # the idle watch keeps its CI ping (CI finished: hand off or fix) and still comments on a card outside that scope
  def test_one_voice_per_quiet_card_the_progress_watch_supersedes_the_idle_watch_comments
    ci = Class.new do
      attr_accessor :pr
      def pr_checks(_card) = @pr
      def last_commit_at(_card) = nil
    end.new
    ci.pr = { number: 7, state: "success", finished_at: @t0 + 1 }
    n = AgentsKanban::Notifier.new(kb, client: @client, ci: ci, clock: -> { @now }, grace: 60, log: @log)
    sys = ->(kind) { db[:"#{KanbanTest::PREFIX}card_activity"].where(card_id: @id, author: "busyyaks", kind: kind) }
    (1..(5 * 60)).step(5) do |m| # 5 h of watch passes, every 5 min: past the idle watch's 4 h and its CI comment
      @now = @t0 + (m * 60)
      n.watch
    end
    assert_equal 1, sys.call("ci_idle").count, "the CI ping still goes"
    bodies = sys.call("comment").select_map(:body)
    assert_equal 1, bodies.size, "one comment: #{bodies.inspect}"
    assert_match(/\A\*\*No progress\*\*/, bodies.first)
    # outside the scope (the progress watch is off) the idle watch comments as before
    off = AgentsKanban::HostConfig.new(config.raw.merge("progress_watch" => { "stale_minutes" => nil }))
    st = AgentsKanban::Store.new(db, config: off, markdown: md, boards: ->(x) { @boards.include?(x) }, clock: -> { @now },
                                     ci: @pci, prs: pr_roles)
    @now += 5 * 3600
    assert_equal [[@id, :idle_comment]], st.idle_watch_pass(live: ["shop"], ci: ci).select { |_, w| w == :idle_comment }
  end

  def test_the_engines_own_entries_are_not_progress
    @now = @t0 + N
    pass # the ping logs a "progress" entry and a ping row; the delivery logs a "ping" entry — all by busyyaks
    @n.deliver
    @now = @t0 + (2 * N)
    assert_equal [[@id, :comment]], pass, "the stretch still runs from the card's creation"
  end

  def test_card_activity_of_every_kind_resets_the_stretch
    acts = {
      comment: -> { kb.comment(@id, body: "still on it", author: "lead") },
      move: -> { kb.move(@id, column: "qa", by: "lead") },
      checklist: -> { kb.checklist_add(@id, title: "steps", by: "lead", items: ["a"]) },
      attachment: -> { attachments.add(@id, filename: "shot.png", bytes: PNG, by: "lead") },
    }
    acts.each do |kind, act|
      quiet!
      assert waiting?, "#{kind}: quiet for 3 N"
      @now += 60
      act.call
      pass
      refute waiting?, "#{kind}: progress clears the wait at the next pass"
      assert_nil card[:progress_stale]
      escalate(@now) # a new stretch: every step again, once
    end
  end

  def test_each_kind_of_port_evidence_resets_the_stretch
    @pci.items = [{ kind: "PR head", key: "aaa", text: "PR o/r#5 head aaa1111" },
                  { kind: "CI on the head", key: "aaa pending", text: "CI pending on aaa1111" },
                  { kind: "branch card/1", key: "c1", text: "branch card/1 at c1c1c1c" },]
    pass # first seen: progress now
    @now = @t0 + N
    pass
    at = Time.at(@t0).strftime("%H:%M")
    assert_includes pings.first[:text], "PR o/r#5 head aaa1111 since #{at} · CI pending on aaa1111 since #{at} · " \
                                        "branch card/1 at c1c1c1c since #{at}"
    [[0, "bbb"], [1, "aaa success"], [2, "c2"]].each do |i, key|
      quiet!
      assert waiting?
      @now += 60
      @pci.items[i] = @pci.items[i].merge(key: key)
      pass
      refute waiting?, "#{@pci.items[i][:kind]}: a new key is progress"
      escalate(@now)
    end
    quiet!
    @pci.items << { kind: "branch card/2", key: "d1", text: "branch card/2 at d1d1d1d" }
    pass
    refute waiting?, "a kind not seen before is progress"
    @pci.items.pop
    quiet!
    assert waiting?, "a kind that went away is no progress"
  end

  def test_scope_gates_terminal_parked_queued_and_flagged_cards_are_not_watched
    out = {}
    { "backlog" => "parked", "todo" => "queued", "human_check" => "gate", "merged" => "done" }.each do |col, _|
      out[col] = kb.create(slug: "p", title: col, by: "operator@example.com", column: col)
    end
    asked = kb.create(slug: "p", title: "asked", by: "lead", column: "doing")
    kb.set_owner(asked, session: "shop", by: "lead")
    kb.ask(asked, question: "A or B?", by: "lead")
    blocked = kb.create(slug: "p", title: "blocked", by: "lead", column: "qa")
    kb.block(blocked, reason: "waits on CI", url: "https://ci.example/1", by: "lead")
    review = kb.create(slug: "p", title: "in review", by: "lead", column: "qa")
    @now = @t0 + N
    assert_equal [[@id, :ping], [review, :ping_nobody]], pass, "working + review only; a flagged card waits for others"
    assert_match(/no owner session to ping\z/,
                 db[:"#{KanbanTest::PREFIX}card_activity"].where(card_id: review, kind: "progress").get(:body))
    # a stale card leaving the scope forgets its stretch: a gate's wait is the operator's own
    @now = @t0 + (2 * N)
    pass
    @now = @t0 + (3 * N)
    pass
    assert_equal 4, kb.waiting_counts(["p"]).waiting["p"], "@id + review wait, beside the gate card and the question"
    kb.ask(review, question: "stuck?", by: "lead", session: "shop")
    pass
    assert_nil kb.card(review)[:progress_stale], "flagged: the question waits, not the watch"
    assert_nil db[:"#{KanbanTest::PREFIX}cards"].where(id: review).get(:progress_at), "its stretch is forgotten"
  end

  def test_an_unreadable_port_skips_the_card_and_keeps_its_stretch
    @now = @t0 + N
    pass
    @pci.down = "github down"
    @now = @t0 + (2 * N)
    assert_equal [[@id, "unavailable: github down"]], pass
    assert_empty comments, "nothing guessed while the port cannot say"
    @n.watch
    @n.watch
    assert_equal 1, @log.string.scan("progress watch: card #{@id}: github down").size, "said once per reason"
    @pci.down = nil
    @n.watch
    assert_includes @log.string, "progress watch: card #{@id} answered again"
    assert_includes @log.string, "progress watch: card #{@id} no progress, commented"
  end

  def test_a_bad_port_answer_is_refused_never_used
    [[{ kind: "PR head", key: " ", text: "x" }], [{ kind: "a", key: "1", text: "x" }, { kind: "a", key: "2", text: "y" }],
     [{ kind: "a", key: 1, text: "x" }],].each do |items|
      @pci.items = items
      what = pass.first
      assert_equal @id, what[0]
      assert_match(/\Aunavailable: progress port answered/, what[1])
    end
  end

  def test_board_json_states_what_counts_as_progress
    assert_equal({ stale_minutes: 30, evidence: ["card activity", "PR head", "CI on the head", "branch commits"],
                   port: true, }, kb.progress_watch_json)
    plain = store # ApprovalCi: no progress port
    assert_equal({ stale_minutes: 30, evidence: ["card activity"], port: false }, plain.progress_watch_json)
    api = AgentsKanban::Api.new(store: plain, attachments: nil, markdown: md, projects: ->(s) { { slug: s, path: nil } })
    assert_equal ["card activity"], api.board("p")[1][:progress_watch][:evidence]
  end

  def test_off_watches_nothing
    off = AgentsKanban::HostConfig.new(config.raw.merge("progress_watch" => { "stale_minutes" => nil }))
    st = AgentsKanban::Store.new(db, config: off, markdown: md, boards: ->(s) { @boards.include?(s) }, clock: -> { @now },
                                     ci: @pci, prs: pr_roles)
    @now = @t0 + (10 * N)
    assert_equal [], st.progress_watch_pass
    assert_nil st.progress_watch_json
    db[:"#{KanbanTest::PREFIX}cards"].where(id: @id).update(progress_at: @t0, progress_stale_at: @now)
    assert_nil st.card(@id)[:progress_stale], "off: a stored stretch makes nothing wait"
  end

  def test_a_port_with_half_the_progress_contract_is_refused
    half = Class.new(ApprovalCi) { def progress(_card) = [] }.new
    e = assert_raises(AgentsKanban::ConfigError) do
      AgentsKanban::Store.new(db, config: config, markdown: md, boards: ->(_) { true }, ci: half, prs: pr_roles)
    end
    assert_match(/progress\(card\) and progress_kinds/, e.message)
  end

  def test_config_is_required_and_strict
    raw = config.raw
    bad = [
      [raw.except("progress_watch"), /missing keys progress_watch/],
      [raw.merge("progress_watch" => nil), /progress_watch must be an object with exactly stale_minutes/],
      [raw.merge("progress_watch" => {}), /progress_watch must be an object with exactly stale_minutes/],
      [raw.merge("progress_watch" => { "stale_minutes" => 30, "x" => 1 }), /exactly stale_minutes/],
      [raw.merge("progress_watch" => { "stale_minutes" => 0 }), /stale_minutes must be null \(off\) or an integer >= 1/],
      [raw.merge("progress_watch" => { "stale_minutes" => "30" }), /got "30"/],
      [raw.merge("progress_watch" => { "stale_minutes" => 1.5 }), /got 1.5/],
    ]
    bad.each do |h, msg|
      e = assert_raises(AgentsKanban::ConfigError) { AgentsKanban::HostConfig.new(h) }
      assert_match msg, e.message
    end
    assert_equal 30, config.progress_watch.stale_minutes
    refute AgentsKanban::HostConfig.new(raw.merge("progress_watch" => { "stale_minutes" => nil })).progress_watch.on?
  end
end
