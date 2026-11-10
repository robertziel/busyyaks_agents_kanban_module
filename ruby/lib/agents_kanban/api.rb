# frozen_string_literal: true

require "json"
require_relative "errors"
require_relative "store"
require_relative "attachments"
require_relative "rev"
require_relative "backlog_md"
require_relative "launch"

module AgentsKanban
  # The OPERATOR's JSON API, framework-neutral: every method takes already-parsed input (a string-keyed Hash body, ids
  # as strings or integers, `by` = the signed-in person) and returns [status, body] — never raises for a client's
  # mistake. A Hanami action or a Rails controller is then one line: parse → call → render. The web user is the
  # operator (no agent restrictions; a comment on an ask-gate card is the answer).
  #
  # Statuses: 200/201 ok, 404 unknown project / card / comment / checklist / item / label / attachment, 422 invalid or
  # refused (the engine's reason), 413 an attachment over the cap, 503 the delivery port unreachable (dialog answers).
  #
  # Ports: store, attachments, markdown (for the preview), projects (->(slug) { project | nil }; a project is a Hash with
  # :slug, :path, :remote — the host's board rows), backlog (->(project, board) { BacklogMd.read | nil } or nil),
  # card_extras (->(card, body) { Hash } merged into every single-card
  # answer — busyyaks adds links, pings, live sessions), board_extras (->(project) { Hash } merged into the board answer —
  # assignee suggestions, sessions), press (->(session:, socket:,
  # hash:, key:) presses a session-dialog key; raises Delivery::Unavailable / Refused), sessions (-> live tmux session
  # names; raises Delivery::*), launcher (the host's LAUNCH port: `name(project:)` → a free tmux session name and
  # `start(session:, project:, type:, launcher:, argv:, prompt_template:, vars:)` → the host's result Hash; raises
  # Delivery::Unavailable / Refused), grace (seconds a registered session counts as running before it is live).
  class Api
    MAX_PREVIEW = 200_000
    CARD_FIELDS = %w[title description labels assignee priority due due_done cover parent metadata].freeze

    def initialize(store:, attachments:, markdown:, projects:,
                   card_extras: ->(_c, _b) { {} }, board_extras: ->(_p) { {} }, backlog: nil, press: nil,
                   sessions: nil, launcher: nil, grace: 60)
      @store = store
      @config = store.config
      @attachments = attachments
      @markdown = markdown
      @projects = projects
      @card_extras = card_extras
      @board_extras = board_extras
      @backlog = backlog
      @press = press
      @sessions = sessions
      @launcher = launcher
      @grace = grace
    end

    attr_reader :store, :config

    # ── reading ───────────────────────────────────────────────────────────────────────────────────

    # Every board with live cards (or a Backlog.md dir): {columns, columns_order, waiting_columns (the TEMPLATE board's),
    # waiting, boards: [{project, columns, columns_order, waiting_columns, counts, total, waiting (the waiting columns'
    # cards + the flagged cards elsewhere), flagged, backlog_md}]} — each board carries its own columns (a project's
    # board may differ from the template's).
    def boards(projects)
      refusing do
        with_cards = @store.cards
                           .where(archived_at: nil, project_slug: projects.map { |p| p[:slug] })
                           .distinct
                           .select_map(:project_slug)
        shown = projects.select { |p| with_cards.include?(p[:slug]) || (@backlog ? BacklogMd.present?(p[:path]) : false) }
        boards = @store.boards_for(shown.map { |p| p[:slug] } + [Board::TEMPLATE]) # one batch read, the template with it
        counts = @store.counts(slugs: shown.map { |p| p[:slug] }, boards: boards)
        flagged = @store.flagged_counts(shown.map { |p| p[:slug] }, boards: boards)
        waits = @store.waiting_counts(shown.map { |p| p[:slug] }, boards: boards)
        rows = shown.map do |p|
          bm = @backlog ? BacklogMd.present?(p[:path]) : false
          b = boards[p[:slug]]
          c = counts[p[:slug]] || b.keys.to_h { |k| [k, 0] }
          { project: p[:slug], columns: columns_json(b), columns_order: b.keys, waiting_columns: b.waiting,
            counts: c, total: c.values.sum, waiting: waits.waiting[p[:slug]], held: waits.held[p[:slug]],
            flagged: flagged[p[:slug]] || 0, backlog_md: bm, }
        end
        tpl = boards[Board::TEMPLATE]
        [200, { columns: columns_json(tpl), columns_order: tpl.keys, waiting_columns: tpl.waiting,
                waiting: rows.sum { |b| b[:waiting] }, held: rows.sum { |b| b[:held] }, boards: rows.sort_by { |b|
 [-b[:total], b[:project]] }, },]
      end
    end

    # The cards waiting for the operator — FLAGGED cards (needs_operator: a question; blocked_external) in any column
    # and the cards in each board's WAITING columns (a gate: a handoff to check) — on every board the host lists, live
    # cards only: {waiting_columns (the template's), total, projects: [{slug, count, waiting_columns, cards: [{id,
    # title, column, column_label, since, needs_operator, blocked, question_first_line, blocked_first_line,
    # handoff_first_line}]}]} — projects with a question first, then most-waiting, cards longest waiting first.
    # since = when the flag was set, else when the card entered the column; nil when the log does not say. No clock
    # in the body: the rev changes only when the content does.
    def waiting(projects)
      refusing do
        slugs = projects.map { |p| p[:slug] }
        w = @store.waiting_cards(slugs)
        by_slug = w.by_slug
        boards = w.boards
        groups = by_slug.map do |slug, cs|
          b = boards[slug]
          { slug: slug, count: cs.size, waiting_columns: b.waiting, cards: cs.map { |c| waiting_card(c, b) } }
        end
        sorted = groups.sort_by do |g|
          asks = g[:cards].any? { |c| c[:needs_operator] }
          [asks ? 0 : 1, -g[:count], g[:slug]]
        end
        held = w.held.map { |slug, cs| { slug: slug, count: cs.size, cards: cs.map { |c| waiting_card(c, boards[slug]) } } }
        [200, { waiting_columns: boards[Board::TEMPLATE].waiting, total: by_slug.values.sum(&:size), projects: sorted,
                held: held.sort_by { |g| [-g[:count], g[:slug]] }, launch_failures: @store.launch_failures(slugs), },]
      end
    end

    def waiting_rev(projects) = [200, { rev: Rev.of(waiting(projects)[1]) }]

    # The board JSON the React Board renders: columns + cards + the board's shape and rules (`board`) + the host config
    # (`config`) + whatever the host adds (board_extras). A stored board the host no longer fits → 422 with the reason
    # (the client offers the reset).
    def board(slug, column: nil, archived: false)
      p = project!(slug) or return not_found("no project #{slug}")
      refusing do
        b = @store.board_of(p[:slug])
        body = board_json(p, column: column, archived: archived, board: b)
        flagged = @store.flagged_counts([p[:slug]], boards: { p[:slug] => b })[p[:slug]] || 0
        gated = body[:columns].select { |col| b.waiting.include?(col[:column]) }.flat_map { |col| col[:cards] }
        held = gated.count { |c| c[:gate_hold] && !c[:needs_operator] && !c[:blocked] } # waiting for CI, not for you
        waiting = gated.size - held + flagged
        [200, body.merge(columns_order: b.keys, waiting_columns: b.waiting, listened_columns: b.listened,
                         waiting: waiting, held: held, flagged: flagged,
                         priorities: @config.priorities, label_colors: @config.label_colors,
                         **@board_extras.call(p)),]
      end
    end

    def board_rev(slug, archived: false)
      p = project!(slug) or return not_found("no project #{slug}")
      refusing { [200, { rev: Rev.of(board_json(p, archived: archived, board: @store.board_of(p[:slug]))) }] }
    end

    def card(id)
      c = card!(id) or return not_found("no card #{id}")
      [200, card_body(c)]
    end

    def card_rev(id)
      c = card!(id) or return not_found("no card #{id}")
      [200, { rev: Rev.of(card_body(c)) }]
    end

    # {card (+ attachments), activity, pings} + the host's extras. The single-card shape every mutation answers with.
    def card_body(c)
      body = @store.card_body(c)
      body[:card] = body[:card].merge(attachments: @attachments.list_json(c[:id]))
      body[:pings] = @store.pings(c[:id], 5).map { |p| @store.ping_json(p) }
      body.merge(@card_extras.call(c, body))
    end

    # ── cards ─────────────────────────────────────────────────────────────────────────────────────

    def create(slug, b, by:)
      p = project!(slug) or return not_found("no project #{slug}")
      refusing do
        raise Invalid, "column is required" unless b.key?("column")

        id = @store.create(slug: p[:slug], title: b["title"], column: b["column"], by: by,
                           notes: b["description"].to_s, labels: b["labels"] || [],
                           assignee: b["assignee"], priority: b["priority"], due: b["due"], parent: b["parent"],
                           metadata: b["metadata"])
        [201, card_body(@store.card(id))]
      end
    end

    def update(id, b, by:)
      c = card!(id) or return not_found("no card #{id}")
      refusing do
        only!(b, CARD_FIELDS)
        attrs = b.slice(*(CARD_FIELDS - ["description"]))
        attrs["notes"] = b["description"] if b.key?("description")
        [200, card_body(@store.update(c[:id], attrs, by: by))]
      end
    end

    # → {card, counts, delivered} (delivered: who the move pings, or why nobody; null when the column did not change)
    def move(id, b, by:)
      c = card!(id) or return not_found("no card #{id}")
      refusing do
        moved = @store.move(c[:id], column: b["column"], transition: b["transition"], position: b["position"], by: by)
        spawn_error = nil
        if moved[:column] != c[:column] && @store.board_of(moved[:project_slug]).spawner_for(moved[:column])
          begin
            spawn_error = "spawned: #{@store.card(c[:id])[:owner_session]}" if spawn_pass(only: c[:id], by: by).any?
          rescue Delivery::Unavailable, Delivery::Refused => e
            spawn_error = "spawn deferred to the notifier pass: #{e.message}"
          end
          moved = @store.card(c[:id])
        end
        delivered = moved[:column] == c[:column] ? nil : (spawn_error || @store.delivery(c, by))
        counts = @store.counts(moved[:project_slug])[moved[:project_slug]]
        [200, { card: @store.card_json(moved, description: true), counts: counts, delivered: delivered }]
      end
    end

    def assign(id, b, by:)
      c = card!(id) or return not_found("no card #{id}")
      refusing do
        raise Invalid, "assignee is required (empty string or null unassigns)" unless b.key?("assignee")

        [200, card_body(@store.update(c[:id], { assignee: b["assignee"] }, by: by))]
      end
    end

    def archive(id, b, by:)
      c = card!(id) or return not_found("no card #{id}")
      refusing do
        [200, card_body(@store.archive(c[:id], archived: flag!(b, "archived"), by: by))]
      end
    end

    def owner(id, b, by:)
      c = card!(id) or return not_found("no card #{id}")
      refusing do
        @store.set_owner(c[:id], session: b["session"].to_s, socket: (b["socket"] || "default").to_s, by: by)
        [200, card_body(@store.card(c[:id]))]
      end
    end

    # The operator approves (approved: true, the default) or withdraws (false).
    def approve(id, b, by:)
      c = card!(id) or return not_found("no card #{id}")
      refusing do
        on = b["approved"].nil? || b["approved"] == true || b["approved"].to_s == "true"
        on ? @store.approve(c[:id], by: by) : @store.unapprove(c[:id], by: by)
        [200, card_body(@store.card(c[:id]))]
      end
    end

    # The operator presses a session-dialog key through the host's `press` port. 422 changed / vanished / bad key
    # (nothing typed, nothing recorded), 503 the port unreachable.
    def dialog_answer(id, b, by:)
      c = card!(id) or return not_found("no card #{id}")
      raise ArgumentError, "Api needs a press: port to answer dialogs" unless @press

      refusing do
        only!(b, %w[key])
        press = lambda do |**kw|
          @press.call(**kw)
        rescue Delivery::Refused => e
          raise Invalid, e.message
        end
        @store.answer_dialog(c[:id], key: b["key"], by: by, press: press)
        [200, card_body(@store.card(c[:id]))]
      end
    rescue Delivery::Unavailable => e
      [503, { error: e.message }]
    end

    # ── launches: the agent types, who runs now against the cap, and starting one ─────────────────

    # {types: [{key, label, launchers: [{key, label}], model, takes (column types), max, max_per_project, running}],
    #  concurrency, sessions_error}
    # — the Launch bar's data. The sessions port down: concurrency null + sessions_error (the bar says so; nothing is
    # launched then, since the cap cannot be checked).
    def launches(slug = nil)
      raise ArgumentError, "Api needs a sessions: port to list launches" unless @sessions

      live, err = live_sessions
      conc = live && @store.concurrency(live, grace: @grace)
      types = @config.agent_types.map do |t|
        launchers = t.launchers.map do |k|
          l = @config.launcher(k)
          { key: l.key, label: l.label, model: t.model_for(k) }
        end
        here = conc && slug ? conc[:sessions].select { |x| x[:type] == t.key && x[:project] == slug } : nil
        follows = live && slug ? @store.followed_launcher(type: t.key, project: slug, live: live, grace: @grace) : nil
        { key: t.key, label: t.label, launchers: launchers, model: t.model,
          takes: t.takes, max: t.max, max_per_project: t.max_per_project, prompt: !t.prompt.nil?,
          running: conc && conc[:types][t.key][:running], running_here: here&.size,
          sessions_here: here&.map { |x| x[:session] },
          launcher_follows: t.launcher_follows, follows: follows, }
      end
      [200, { types: types, concurrency: conc, sessions_error: err }]
    end

    # POST {type, launcher?}: the cap is checked on a fresh live list (422 with who runs), a free session name is taken
    # from the host, the session is REGISTERED (adopting the project's ownerless cards of the type's `takes` columns),
    # the host starts it with the plan (argv, prompt template + values — the host renders {dir}); a start that fails
    # ends the registration and releases what it adopted. 201 {session, type, launcher, agent, adopted, result (the
    # host's), concurrency} · 422 refused · 503 the launcher / sessions port unreachable.
    def launch(slug, b, by:)
      raise ArgumentError, "Api needs sessions: and launcher: ports to launch" unless @sessions && @launcher

      p = project!(slug) or return not_found("no project #{slug}")
      refusing do
        only!(b, %w[type launcher])
        t = @config.agent_type(b["type"])
        live = @sessions.call
        @store.launch_check!(type: t.key, project: p[:slug], live: live, grace: @grace)
        lk = @store.launcher_for!(type: t.key, project: p[:slug], asked: b["launcher"], live: live, grace: @grace)
        session = @launcher.name(project: p, base: @config.session_name(t, slug: p[:slug])).to_s
        reg = @store.register_session(session: session, project: p[:slug], type: t.key, launcher: lk, by: by)
        plan = Launch.plan(@config, type: t.key, launcher: lk, session: session, slug: p[:slug], cards: reg[:adopted])
        result = begin
          start_session(session, p, t, lk, plan)
        rescue Delivery::Unavailable, Delivery::Refused => e
          @store.end_session(session, reason: "#{Store::START_FAILED}#{e.message}", by: by)
          @store.release_session_cards(session, reason: "its launch failed: #{e.message}", by: by)
          raise
        end
        adopted = reg[:adopted].map { |id| @store.card_json(@store.card(id)) }
        [201, { session: session, type: t.key, launcher: lk, agent: reg[:agent], adopted: adopted,
                result: result, concurrency: @store.concurrency(@sessions.call, grace: @grace), },]
      end
    rescue Delivery::Refused => e
      [422, { error: e.message }]
    rescue Delivery::Unavailable => e
      [503, { error: e.message }]
    end

    # THE SPAWN RULE (global): an ownerless card in a column some agent type `spawns_for` gets ONE NEW session of that
    # type, started for it alone — registered with the card as its only card (owner + assignee set before the start),
    # the card id in the prompt ({cards}). Run at once on an operator move into the column and on every notifier pass
    # (so at the host's start, and for a card whose dead worker the watchdog released). Never handed to another
    # session instead:
    #   a cap is full     → the card waits, its note says which cap and who runs; spawned FIFO when a slot frees;
    #   no launcher       → the type runs several, none is followed and no spawn_launcher is set: the card waits, its
    #                       note says so (retried every pass — a lead starting gives it one to follow);
    #   the start fails   → registration ended, card released, note "spawn failed: <why>", retried after SPAWN_RETRY_S.
    # The sessions / launcher ports down raise (Delivery::*): the caller says so, nothing is assigned.
    # → the card ids a session was started for.
    def spawn_pass(only: nil, by: nil)
      return [] if @config.spawn_types.empty?
      raise ArgumentError, "Api needs sessions: and launcher: ports to spawn" unless @sessions && @launcher

      by ||= @config.system_author
      queue = @store.spawn_queue(only: only)
      return [] if queue.empty?

      live = @sessions.call
      started = []
      queue.each do |c|
        next if @store.spawn_backoff?(c[:id])

        t = @store.board_of(c[:project_slug]).spawner_for(c[:column])
        p = @projects.call(c[:project_slug])
        unless p
          @store.spawn_note(c[:id], "spawn failed: no project #{c[:project_slug]} on this host", by)
          next
        end
        begin
          @store.launch_check!(type: t.key, project: p[:slug], live: live, grace: @grace)
        rescue Denied => e
          @store.spawn_note(c[:id], "waiting for a free #{t.key} session — #{e.message}", by)
          next
        end
        begin
          lk = @store.launcher_for!(type: t.key, project: p[:slug], asked: nil, live: live, grace: @grace)
        rescue Invalid => e # several launchers, no session to follow, no spawn_launcher: the card waits, says why
          @store.spawn_note(c[:id], "spawn refused: #{e.message}", by)
          next
        end
        session = @launcher.name(project: p, base: @config.session_name(t, slug: p[:slug])).to_s
        reg = @store.register_session(session: session, project: p[:slug], type: t.key, launcher: lk, by: by,
                                      for_cards: [c[:id]])
        if reg[:adopted].empty? # taken by somebody between the queue read and the registration
          @store.end_session(session, reason: "card ##{c[:id]} was taken before its spawn", by: by)
          next
        end
        plan = Launch.plan(@config, type: t.key, launcher: lk, session: session, slug: p[:slug], cards: reg[:adopted])
        begin
          start_session(session, p, t, lk, plan)
        rescue Delivery::Unavailable, Delivery::Refused => e
          @store.end_session(session, reason: "#{Store::START_FAILED}#{e.message}", by: by)
          @store.release_session_cards(session, reason: "its spawn failed: #{e.message}", by: by)
          @store.spawn_note(c[:id], "spawn failed: #{e.message}", by)
          next
        end
        started << c[:id]
      end
      started
    end

    # The registered sessions: running (against the live list) and the last `ended` ended ones.
    def sessions(ended: 20)
      raise ArgumentError, "Api needs a sessions: port" unless @sessions

      live, err = live_sessions
      rows = @store.sessions_t
                   .where(ended_at: nil)
                   .order(:launched_at, :id)
                   .all
                   .map { |r| @store.session_json(r, live) }
      done = @store.sessions_t
                   .exclude(ended_at: nil)
                   .order(Sequel.desc(:ended_at), Sequel.desc(:id))
                   .limit(ended)
                   .all
                   .map { |r| @store.session_json(r, live) }
      conc = live && @store.concurrency(live, grace: @grace).slice(:max_sessions, :running, :free, :types)
      [200, { concurrency: conc, registered: rows, ended: done, sessions_error: err }]
    end

    # ── comments ─────────────────────────────────────────────────────────────────────────────────

    # 201 {card, activity, delivered} — on an ask-gate card the operator's comment is the answer.
    def comment(id, b, by:)
      c = card!(id) or return not_found("no card #{id}")
      refusing do
        @store.comment(c[:id], body: b["body"], author: by, operator: true)
        [201, card_body(@store.card(c[:id])).merge(delivered: @store.delivery(c, by))]
      end
    end

    def comment_update(comment_id, b, by:)
      e = row(comment_id, "no comment") { |i| @store.comment!(i) } or return not_found("no comment #{comment_id}")
      refusing do
        only!(b, %w[body])
        @store.comment_edit(e[:id], body: b["body"], by: by)
        [200, card_body(@store.card(e[:card_id]))]
      end
    end

    def comment_delete(comment_id, by:)
      e = row(comment_id, "no comment") { |i| @store.comment!(i) } or return not_found("no comment #{comment_id}")
      refusing do
        @store.comment_delete(e[:id], by: by)
        [200, card_body(@store.card(e[:card_id]))]
      end
    end

    # ── checklists ───────────────────────────────────────────────────────────────────────────────

    def checklist_create(card_id, b, by:)
      c = card!(card_id) or return not_found("no card #{card_id}")
      refusing do
        only!(b, %w[title items])
        @store.checklist_add(c[:id], title: b["title"], items: b["items"] || [], by: by)
        [201, card_body(@store.card(c[:id]))]
      end
    end

    def checklist_update(id, b, by:)
      cl = row(id) { |i| @store.checklist!(i) } or return not_found("no checklist #{id}")
      refusing do
        only!(b, %w[title])
        @store.checklist_rename(cl[:id], title: b["title"], by: by)
        [200, card_body(@store.card(cl[:card_id]))]
      end
    end

    def checklist_delete(id, by:)
      cl = row(id) { |i| @store.checklist!(i) } or return not_found("no checklist #{id}")
      refusing do
        @store.checklist_delete(cl[:id], by: by)
        [200, card_body(@store.card(cl[:card_id]))]
      end
    end

    def item_create(checklist_id, b, by:)
      cl = row(checklist_id) { |i| @store.checklist!(i) } or return not_found("no checklist #{checklist_id}")
      refusing do
        only!(b, %w[body])
        @store.item_add(cl[:id], body: b["body"], by: by)
        [201, card_body(@store.card(cl[:card_id]))]
      end
    end

    def item_update(id, b, by:)
      item = row(id) { |i| @store.item!(i) } or return not_found("no checklist item #{id}")
      refusing do
        only!(b, %w[body done])
        raise Invalid, "body or done is required" if b.empty?

        @store.item_update(item[:id], body: b["body"], done: b.key?("done") ? flag!(b, "done") : nil, by: by)
        [200, card_body(@store.card(@store.checklist!(item[:checklist_id])[:card_id]))]
      end
    end

    def item_delete(id, by:)
      item = row(id) { |i| @store.item!(i) } or return not_found("no checklist item #{id}")
      refusing do
        card_id = @store.checklist!(item[:checklist_id])[:card_id]
        @store.item_delete(item[:id], by: by)
        [200, card_body(@store.card(card_id))]
      end
    end

    # 201 {card, activity, created: Card} — card/activity are the parent's; created is the new card.
    def item_convert(id, by:)
      item = row(id) { |i| @store.item!(i) } or return not_found("no checklist item #{id}")
      refusing do
        card_id = @store.checklist!(item[:checklist_id])[:card_id]
        new_id = @store.item_convert(item[:id], by: by)
        [201, card_body(@store.card(card_id)).merge(created: @store.card_json(@store.card(new_id)))]
      end
    end

    # ── labels ────────────────────────────────────────────────────────────────────────────────────

    # ── a project's BOARD SHAPE (its columns with types and their order, its transitions): the
    # operator reads, saves (validated as a whole; a column with cards cannot be dropped) and resets it to the template ──

    # → {columns, transitions, rules, types, updated_by, updated} (Store#board_json)
    def board_shape(slug)
      p = project!(slug) or return not_found("no project #{slug}")
      refusing { [200, @store.board_json(p[:slug])] }
    end

    # body {columns, transitions} → the saved shape; 422 with the reason when it does not validate
    def board_shape_save(slug, b, by:)
      p = project!(slug) or return not_found("no project #{slug}")
      refusing do
        only!(b, Board::KEYS)
        [200, @store.board_save(p[:slug], b, by: by)]
      end
    end

    # → the template instantiated again for the project (refused when cards sit in a column the template lacks)
    def board_shape_reset(slug, by:)
      p = project!(slug) or return not_found("no project #{slug}")
      refusing { [200, @store.board_reset(p[:slug], by: by)] }
    end

    def label_create(slug, b)
      p = project!(slug) or return not_found("no project #{slug}")
      refusing do
        only!(b, %w[name color])
        id = @store.label_create(p[:slug], name: b["name"], color: b["color"])
        [201, { label: @store.label_json(@store.label!(id)), labels: labels_json(p[:slug]) }]
      end
    end

    def label_update(id, b)
      l = row(id) { |i| @store.label!(i) } or return not_found("no label #{id}")
      refusing do
        only!(b, %w[name color])
        raise Invalid, "name or color is required" if b.empty?

        label = @store.label_update(l[:id], name: b["name"], color: b["color"])
        [200, { label: @store.label_json(label), labels: labels_json(l[:project_slug]) }]
      end
    end

    def label_delete(id)
      l = row(id) { |i| @store.label!(i) } or return not_found("no label #{id}")
      refusing do
        @store.label_delete(l[:id])
        [200, { labels: labels_json(l[:project_slug]) }]
      end
    end

    # ── attachments ───────────────────────────────────────────────────────────────────────────────

    # io: the uploaded tempfile (rewindable, with size). 201 {attachment} · 413 over the cap · 422 refused.
    def attach(card_id, filename:, io:, by:, comment_id: nil)
      c = card!(card_id) or return not_found("no card #{card_id}")
      return [422, { error: "file is required (multipart field \"file\")" }] unless io

      a = @attachments.add_file(c[:id], filename: filename.to_s, io: io, by: by, comment_id: comment_id)
      [201, { attachment: @attachments.json(a) }]
    rescue AttachmentPolicy::TooLarge => e
      [413, { error: e.message }]
    rescue AttachmentPolicy::Refused, Invalid => e
      [422, { error: e.message }]
    end

    def attachment_delete(id, by:)
      a = @attachments.find(id) or return not_found("no attachment #{id}")
      refusing do
        @attachments.delete(a[:id], by: by)
        [200, card_body(@store.card(a[:card_id]))]
      end
    end

    # The bytes to serve: [200, {path:, row:, inline:}] (inline = a picture may render in the browser) or 404.
    def attachment_file(id, download: false)
      a = @attachments.find(id) or return not_found("no attachment #{id}")
      return not_found("attachment #{a[:id]} was deleted") if a[:deleted_at]

      path = @attachments.path!(a)
      [200, { path: path, row: a, inline: !download && AttachmentPolicy::INLINE_IMAGES.include?(a[:content_type]) }]
    rescue Invalid => e
      not_found(e.message)
    end

    # ── markdown preview ──────────────────────────────────────────────────────────────────────────

    # {html}: the same server render as saved descriptions / comments (inline: true = a checklist item).
    def markdown_preview(b)
      refusing do
        only!(b, %w[body inline])
        raise Invalid, "body must be a string" unless b["body"].is_a?(String)
        raise Invalid, "body is longer than #{MAX_PREVIEW}" if b["body"].length > MAX_PREVIEW

        [200, { html: b["inline"] == true ? @markdown.inline(b["body"]) : @markdown.card(b["body"]) }]
      end
    end

    # ── helpers ───────────────────────────────────────────────────────────────────────────────────

    def board_json(p, column: nil, archived: false, board: nil)
      b = board || @store.board_of(p[:slug])
      col = column.to_s.empty? ? nil : column.to_s
      raise Invalid, "column must be one of #{b.keys.join(', ')}" if col && !b.column?(col)

      cols = @store.board(p[:slug], board: b)
      cols = cols.slice(col) if col
      out = { project: p[:slug], labels: labels_json(p[:slug]),
              columns: cols.map { |k, cs| column_json(b, k, cs) },
              config: @config.to_h, board: @store.board_json(p[:slug], board: b), }
      out[:archived] = @store.archived(p[:slug]).map { |c| @store.card_json(c) } if archived
      out[:backlog_md] = BacklogMd.json(@backlog&.call(p, b), column: col)
      out
    end

    def columns_json(b) = b.columns.map { |c| { key: c.key, label: c.label, type: c.type.key } }

    private

    def column_json(b, k, cs)
      { column: k, label: b.label(k), type: b.type_of(k).key, operator_only: b.operator_only.include?(k),
        hide_after_hours: b.column(k).hide_after_hours, cards: cs.map { |c| @store.card_json(c) }, }
    end

    def labels_json(slug) = @store.labels(slug).map { |l| @store.label_json(l) }

    # [live session names, nil] or [nil, the reason the port could not say]
    def live_sessions
      [@sessions.call, nil]
    rescue Delivery::Unavailable, Delivery::Refused => e
      [nil, e.message]
    end
    def project!(slug) = @projects.call(slug.to_s)
    def not_found(msg) = [404, { error: msg }]

    def card!(id)
      i = Integer(id.to_s, exception: false)
      i && @store.card(i)
    end

    # A row by id, or nil when the store says it is not there (its own Invalid).
    def row(id, _msg = nil)
      yield(id.to_s)
    rescue Invalid
      nil
    end

    def refusing
      yield
    rescue Invalid => e
      [422, { error: e.message }]
    end

    def only!(b, keys)
      raise Invalid, "body must be a JSON object" unless b.is_a?(Hash)

      unknown = b.keys - keys
      raise Invalid, "unknown fields: #{unknown.join(', ')}" if unknown.any?
    end

    # true/false from JSON or a form string; anything else → Invalid.
    def flag!(b, key)
      raise Invalid, "#{key} is required" unless b.is_a?(Hash) && b.key?(key)

      v = b[key]
      v = { "true" => true, "false" => false, "1" => true, "0" => false }.fetch(v, v) if v.is_a?(String)
      raise Invalid, "#{key} must be true or false" unless [true, false].include?(v)

      v
    end

    def waiting_card(c, b)
      { id: c[:id], title: c[:title], column: c[:column], column_label: c[:column_label], since: Store.iso(c[:since]),
        needs_operator: !c[:asked_at].nil?, blocked: !c[:blocked_at].nil?,
        # the open question (needs_operator); a blocked card's reason
        question_first_line: c[:asked_at] ? first_line(c[:question]) : nil,
        blocked_first_line: c[:blocked_at] ? first_line(c[:blocked_reason]) : nil,
        # what the agent says to check, in a gate
        handoff_first_line: b.gate?(c[:column]) && c[:handoff_at] ? first_line(c[:qa_notes]) : nil,
        gate_hold: c[:gate_hold], }
    end

    # Starts the planned session through the launcher (the launcher's start op with the plan's argv, prompt and vars).
    def start_session(session, project, type, launcher, plan)
      @launcher.start(session: session, project: project, type: type.key, launcher: launcher,
                      argv: plan[:argv], prompt_template: plan[:prompt_template], vars: plan[:vars])
    end

    # The question's first non-blank line as plain text (markdown emphasis / code / heading marks dropped), ≤ 160 chars.
    def first_line(md)
      line = md.to_s.lines.map(&:strip).find { |l| !l.empty? } or return nil
      t = line.gsub(/\*+|__|`/, "").sub(/\A#+\s*/, "").strip # a single _ is a name (teamlead_worker_3), never emphasis
      t.length > 160 ? "#{t[0, 159]}…" : t
    end

  end
end
