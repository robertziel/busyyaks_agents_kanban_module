# frozen_string_literal: true

require "json"
require "date"
require "time"
require_relative "errors"
require_relative "host_config"
require_relative "board_repo"
require_relative "schema"
require_relative "session_dialog"

module AgentsKanban
  # The kanban engine over a Sequel connection the HOST hands in (tables: Schema, namespaced by `prefix`). Every column
  # rule reads the BOARD of the card's project (Board: its columns' types + its workflow, kept in the database by
  # BoardRepo and instantiated from the template row for a project that has none yet); the host config carries only
  # settings. Nothing here names a column. Used by the operator's JSON API (Api) and the agents' MCP tools (Tools);
  # every bad input raises Invalid with the reason, a rule refusal Denied.
  #
  # Roles: the host says who it is. `agent: true` on create / move / item_convert applies the agent rules (gates,
  # operator_only); `operator: true` on comment makes the comment an ANSWER on an ask-gate card. The engine never
  # guesses from the author's name. Every change is recorded in card_activity with who made it.
  #
  # Ports: db (Sequel), config (HostConfig), markdown (an object with card(md) and inline(md) → HTML; Markdown is the
  # shipped one), clock (-> epoch seconds). No ENV, no HTTP, no shelling out.
  class Store
    MAX_QUESTION = 8000
    MAX_OPTIONS = 8
    MAX_OPTION = 200
    MAX_TITLE = 200
    MAX_LABELS = 12
    MAX_LABEL = 40
    MAX_ASSIGNEE = 80
    MAX_ITEM = 1000
    MAX_METADATA = 8000 # JSON characters
    MAX_BLOCK_REASON = 2000
    REREVIEW = "_rereview" # review_rounds key: {loop column => its rounds when the operator requested changes}
    DUE = /\A(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d)(?::(\d\d))?(Z|[+-]\d\d:?\d\d)?\z/
    SESSION = /\A[A-Za-z0-9._-]{1,100}\z/
    PING_BODY = 1500
    DRAGGED_NOTE = "It was dragged: CI was not asked — read the PR's checks first."
    CI_NOT_ASKED = "ci-not-asked" # the approve ping's marker: a drag approved the step, the green-CI gate was not asked
    URL_RE = %r{\Ahttps?://[^\s<>"]{3,2000}\z}
    DIALOG_REASK = 120 # an answered dialog still on screen this long after the key press is not re-posted
    FIELDS = %i[title notes labels assignee priority due due_done cover parent metadata].freeze
    SCREENSHOT_TYPES = %w[image/png image/jpeg image/webp image/gif].freeze

    attr_reader :db, :config, :markdown, :tables, :repo

    # boards: ->(slug) { true | false } — the host says which boards exist (busyyaks: its projects table); a card is
    # never written for a slug the host does not know.
    def initialize(db, config:, markdown:, boards:, clock: -> { Time.now.to_i }, ci: nil)
      raise ArgumentError, "config must be an AgentsKanban::HostConfig" unless config.is_a?(HostConfig)
      if config.green_ci_gate? && !ci.respond_to?(:approval_checks)
        raise ConfigError, "host config has approval.requires_green_ci but the Store got no ci: port answering " \
                           "approval_checks(card, step)"
      end
      unless markdown.respond_to?(:card) && markdown.respond_to?(:inline)
        raise ArgumentError, "markdown must answer card(md) and inline(md)"
      end
      raise ArgumentError, "boards must be callable: ->(slug) { exists? }" unless boards.respond_to?(:call)
      @db = db
      @config = config
      @markdown = markdown
      @boards = boards
      @clock = clock
      @ci = ci
      @tables = Schema.tables(config.table_prefix)
      @repo = BoardRepo.new(db, tables: @tables, host: config, clock: clock, known: boards)
      @attachment_ref = %r{\(#{Regexp.escape(config.attachment_url_prefix)}/(\d+)(?:/download)?\)}
    end

    def cards = @db[@tables[:cards]]
    def activity_t = @db[@tables[:card_activity]]
    def labels_t = @db[@tables[:board_labels]]
    def checklists_t = @db[@tables[:checklists]]
    def items_t = @db[@tables[:checklist_items]]
    def pings_t = @db[@tables[:card_pings]]
    def attachments_t = @db[@tables[:card_attachments]]
    def dialogs_t = @db[@tables[:session_dialogs]]
    def sessions_t = @db[@tables[:agent_sessions]]
    def watches_t = @db[@tables[:ci_watches]]

    # ── boards: a project's columns (typed) + workflow, from the database (BoardRepo) ───────────

    # The Board every rule of this project's cards reads — its own rows, or the template instantiated for it on first
    # use (recorded as the system author's copy). No template → Invalid, loudly.
    def board_of(slug) = @repo.fetch(slug.to_s, by: @config.system_author)
    # {slug => Board} in two reads for a list of projects (a board decorates every card with its transitions).
    def boards_for(slugs) = @repo.fetch_many(slugs, by: @config.system_author)
    def board_template = @repo.template

    # {columns, transitions, rules, types, updated_by, updated} — the graph editor's data. board: when the caller read
    # it already.
    def board_json(slug, board: nil) = @repo.json(slug.to_s, by: @config.system_author, board: board)

    # Validate the whole board (Board), refuse to drop a column that still holds cards (live or archived: a card
    # references its column key), then replace the project's rows. → board_json
    def board_save(slug, hash, by:)
      board!(slug)
      @repo.save(slug, hash, by: who!(by), cards_in: method(:cards_in_columns))
      board_json(slug)
    end

    # Back to the template (the project's rows replaced by its copy; refused like a save when cards sit in a column the
    # template lacks). → board_json
    def board_reset(slug, by:)
      board!(slug)
      @repo.reset(slug, by: who!(by), cards_in: method(:cards_in_columns))
      board_json(slug)
    end

    # {column => [card ids]} for cards (live and archived) of the project in these columns — what a column removal is
    # checked against.
    def cards_in_columns(slug, keys)
      cards.where(project_slug: slug, column: keys)
        .order(:id)
        .all
        .group_by { |c| c[:column] }
        .transform_values { |cs| cs.map { |c| c[:id] } }
    end

    # ── reading ───────────────────────────────────────────────────────────────────────────────────

    # {column_key => [card]} in the board's order, live cards only, each decorated for its face.
    def board(slug, board: nil)
      b = board || board_of(slug)
      rows = live(slug).order(:position, :id).all.map { |c| hydrate(c, b) }
      by_col = decorate(rows, { slug => b }).group_by { |c| c[:column] }
      b.keys.to_h { |k| [k, by_col[k] || []] }
    end

    def archived(slug)
      rows = cards.where(project_slug: slug).exclude(archived_at: nil).order(Sequel.desc(:archived_at)).all
      decorate(rows.map { |c| hydrate(c) })
    end

    # {slug => {column_key => n}} over live cards (every column of the project's board, 0 when empty); one project when
    # slug is given, the projects in `slugs` when a list is given (a project with no live card is left out).
    # boards: {slug => Board} when the caller read them already (one batch read for a page).
    def counts(slug = nil, slugs: nil, boards: nil)
      ds = cards.where(archived_at: nil)
      ds = ds.where(project_slug: slug) if slug
      ds = ds.where(project_slug: slugs) if slugs
      rows = ds.group_and_count(:project_slug, :column).all
      boards ||= boards_for(rows.map { |r| r[:project_slug] }.uniq)
      rows.each_with_object({}) do |r, acc|
        (acc[r[:project_slug]] ||= boards[r[:project_slug]].keys.to_h { |k| [k, 0] })[r[:column]] = r[:count]
      end
    end

    def empty_counts(slug) = board_of(slug).keys.to_h { |k| [k, 0] }

    # {slug => n}: live cards flagged needs_operator per project that sit outside their board's waiting columns — what
    # "N waiting for you" adds to the waiting columns' counts (a flagged card in a gate counts once). A card only
    # blocked_external waits for the world, not for the operator (waiting_counts `external`).
    def flagged_counts(slugs, boards: nil)
      rows = cards.where(archived_at: nil, project_slug: slugs.to_a)
                  .exclude(asked_at: nil) # needs_operator?
                  .select(:project_slug, :column)
                  .all
      boards ||= boards_for(rows.map { |r| r[:project_slug] }.uniq)
      rows.reject { |r| boards[r[:project_slug]].waiting.include?(r[:column]) }.group_by { |r| r[:project_slug] }
          .transform_values(&:size)
    end

    # {slug => [card]} and the boards read for them (one batch), for the caller to reuse
    # held: {slug => [card]} — the gate cards waiting for CI (gate_hold), not for the operator; external: {slug => [card]}
    # — the cards only blocked_external (waiting for the world: another card, CI, a third party), not for the operator
    WaitingCards = Struct.new(:by_slug, :boards, :held, :external)

    # Live cards of these projects waiting for the operator: the ones flagged needs_operator (a question asked, a
    # dialog on the owner's screen) in whatever column they sit, and the cards in their boards' WAITING columns (a
    # gate: a handoff to check); decorated, flagged cards first, then the board's waiting order, then longest-waiting
    # first. A card only blocked_external (external?) goes to `external` wherever it sits, a gate card held for CI to
    # `held`: neither waits for the operator. :since is when the flag was set, else when the card entered the column
    # (its last move there, or its creation there); nil when the activity log does not say — unknown, not guessed.
    # → WaitingCards (by_slug + the boards, the template included)
    def waiting_cards(slugs)
      rows = cards.where(archived_at: nil, project_slug: slugs.to_a).all
      boards = boards_for(rows.map { |c| c[:project_slug] }.uniq + [Board::TEMPLATE])
      picked = rows.select { |c| flagged?(c) || boards[c[:project_slug]].waiting.include?(c[:column]) }
      all = decorate(picked.map { |c| hydrate(c, boards[c[:project_slug]]) }, boards)
      external, rest = all.partition { |c| external?(c) }
      held, list = rest.partition { |c| c[:gate_hold] && !flagged?(c) }
      acts = activity_t.where(card_id: list.map { |c| c[:id] }, kind: %w[move create])
        .select(:card_id, :body, :created_at)
        .all
        .group_by { |a| a[:card_id] }
      external.each { |c| c[:since] = flag_since(c) }
      list.each do |c|
        c[:since] = flag_since(c) ||
                    (acts[c[:id]] || []).select { |a| a[:body].end_with?(c[:column_label]) }.map { |a| a[:created_at] }.max
      end
      sorted = list.sort_by do |c|
        [flagged?(c) ? 0 : 1, boards[c[:project_slug]].waiting.index(c[:column]) || -1, c[:since] || 0, c[:id]]
      end
      WaitingCards.new(sorted.group_by { |c| c[:project_slug] }, boards, held.group_by { |c| c[:project_slug] },
                       external.sort_by { |c| [c[:since], c[:id]] }.group_by { |c| c[:project_slug] })
    end

    # The cross-cutting flags (SPEC § 4): a flagged card keeps its column, waits for the operator (or the world) and
    # refuses agent moves. needs_operator = an open question (asked_at); blocked_external = blocked_at.
    def flagged?(c) = !(c[:asked_at].nil? && c[:blocked_at].nil?)
    # needs_operator: an open question (kanban_ask, a dialog on the owner's screen) — the card waits for the operator
    def needs_operator?(c) = !c[:asked_at].nil?
    # blocked_external with no open question: the card waits for the world (another card, CI, a third party) — it is not
    # waiting for the operator, so no "waiting for you" count holds it (a card that also asks does: the question waits)
    def external?(c) = c[:asked_at].nil? && !c[:blocked_at].nil?
    def flag_since(c) = [c[:asked_at], c[:blocked_at]].compact.min
    # The one rule of "waiting for the operator" for a card (its face, the counts): a question open on it wherever it
    # sits, or it sits in a WAITING column (a gate) with nothing held (hold = Store#gate_hold's why, nil = approvable
    # now) and is not only blocked_external (that waits for the world).
    def waits_for_operator?(c, b, hold) = needs_operator?(c) || (!external?(c) && hold.nil? && b.waiting.include?(c[:column]))

    # The cards each OPEN registration (agent_sessions, ended_at null) on these projects' boards holds since it registered —
    # the column's type says what each is to the session (`finishes` = in the board's done column: that card is finished).
    # Scoped to the registration, not the name: a tmux name is handed out again once its session ends, and a card in a
    # done column keeps its old owner as history — a new session of the same name must not inherit those. A card counts
    # when it became this owner's (its creation, or its last `owner` activity) at or after the registration's
    # launched_at, on the registration's socket. A session with no open registration is absent: its cards are unknown.
    # Light rows (the agents sidebar reads them every poll). → {[session, socket] => {project_slug:, since:, cards:
    # [{id, project_slug, title, column, column_label, column_type, finishes, updated_at}]}}, cards in board order.
    def owned_cards(slugs)
      regs = sessions_t.where(ended_at: nil, project_slug: slugs.to_a)
        .select(:session, :socket, :project_slug, :launched_at)
        .all
      return {} if regs.empty?

      rows = cards.where(archived_at: nil, owner_session: regs.map { |r| r[:session] }.uniq)
                  .select(:id, :project_slug, :title, :column, :position, :owner_session, :owner_socket, :created_at,
                          :updated_at)
                  .all
      owned_at = activity_t.where(card_id: rows.map { |c| c[:id] }, kind: "owner").group_and_count(:card_id)
                           .select_append { max(:created_at).as(:at) }.as_hash(:card_id, :at)
      boards = boards_for(regs.map { |r| r[:project_slug] }.uniq)
      regs.to_h do |r|
        b = boards[r[:project_slug]]
        mine = rows.select do |c|
          c[:owner_session] == r[:session] && c[:owner_socket] == r[:socket] && c[:project_slug] == r[:project_slug] &&
            [c[:created_at], owned_at[c[:id]]].compact.max >= r[:launched_at]
        end
        list = mine.sort_by { |c| [b.keys.index(c[:column]) || b.keys.size, c[:position], c[:id]] }.map do |c|
          t = b.column?(c[:column]) ? b.type_of(c[:column]) : nil
          { id: c[:id], project_slug: c[:project_slug], title: c[:title], column: c[:column],
            column_label: t ? b.label(c[:column]) : c[:column],
            column_type: t&.key, finishes: t ? t.finishes : nil, updated_at: c[:updated_at], }
        end
        [[r[:session], r[:socket]], { project_slug: r[:project_slug], since: r[:launched_at], cards: list }]
      end
    end

    def card(id)
      c = cards.where(id: Integer(id)).first
      c && decorate([hydrate(c)]).first
    end

    def card!(id) = card(id) || raise(Invalid, "no card #{id}")

    # {id => project_slug} for the ids that are cards (archived too: they still open by ?card=).
    def card_slugs(ids) = ids.empty? ? {} : cards.where(id: ids.to_a).select_hash(:id, :project_slug)

    def self.iso(ts) = ts && Time.at(ts).iso8601
    def iso(ts) = Store.iso(ts)

    # The one JSON shape of a card (MCP tools and the API). description: true adds the markdown description (+ its
    # server render); checklists: rows (Store#checklists) to include.
    def card_json(c, description: false, checklists: nil)
      j = { id: c[:id], project: c[:project_slug], column: c[:column], column_label: c[:column_label],
            position: c[:position], title: c[:title],
            labels: c[:labels], assignee: c[:assignee], priority: c[:priority], comments: c[:comments],
            due: iso(c[:due_at]), due_done: c[:due_done], cover: c[:cover], has_description: !c[:notes].to_s.strip.empty?,
            checklist_done: c[:checklist_done], checklist_total: c[:checklist_total], attachments: c[:attachments],
            owner_session: c[:owner_session], owner_socket: c[:owner_socket],
            approved: iso(c[:approved_at]), approved_by: c[:approved_by],
            pr_url: c[:pr_url], ci_url: c[:ci_url], ui_change: c[:ui_change],
            handoff: iso(c[:handoff_at]), handoff_by: c[:handoff_by],
            question: c[:question], question_options: c[:question_options] && JSON.parse(c[:question_options]),
            asked: iso(c[:asked_at]), asked_by: c[:asked_by], dialog: c[:dialog],
            needs_operator: !c[:asked_at].nil?,
            gate_hold: c[:gate_hold], # waiting for CI, not for the operator (gate_hold; decorated cards only)
            waiting: c[:waiting], # waits for the operator now (waits_for_operator?: the counts' rule; decorated cards only)
            blocked: c[:blocked_at] && { reason: c[:blocked_reason], url: c[:blocked_url], by: c[:blocked_author],
                                         at: iso(c[:blocked_at]), },
            review_round: review_rounds(c)[c[:column]],
            parent: c[:parent_id], children: c[:children], blocked_by: c[:blocked_by], metadata: c[:metadata],
            created_by: c[:created_by], created: iso(c[:created_at]), updated: iso(c[:updated_at]),
            archived: iso(c[:archived_at]), }
      j[:transitions] = c[:transitions] || []
      return j unless description

      # *_html: the markdown rendered server-side (raw HTML dropped, @mentions marked) — a client injects it, it never
      # renders markdown.
      j = j.merge(description: c[:notes], description_html: @markdown.card(c[:notes]),
                  qa_notes: c[:qa_notes], qa_html: c[:qa_notes] ? @markdown.card(c[:qa_notes]) : nil,
                  question_html: c[:question] ? @markdown.card(c[:question]) : nil)
      checklists ? j.merge(checklists: checklists.map { |cl| checklist_json(cl) }) : j
    end

    def checklist_json(cl)
      { id: cl[:id], title: cl[:title], position: cl[:position],
        items: cl[:items].map do |i|
          { id: i[:id], body: i[:body], body_html: @markdown.inline(i[:body]), done: i[:done] == 1, position: i[:position],
            done_by: i[:done_by], done_at: iso(i[:done_at]), }
        end, }
    end

    def activity_json(e)
      j = { id: e[:id], at: iso(e[:created_at]), kind: e[:kind], author: e[:author], body: e[:body] }
      return j.merge(body_html: @markdown.card(e[:body]), edited: iso(e[:edited_at])) if e[:kind] == "comment"

      e[:kind] == "question" ? j.merge(body_html: @markdown.card(e[:body])) : j
    end

    def label_json(l) = { id: l[:id], name: l[:name], color: l[:color] }

    # {card (with description + checklists), activity} — the single-card shape. The host merges the attachment list
    # (Attachments#json) over :attachments and whatever else it knows (links, pings, sessions).
    def card_body(c)
      { card: card_json(c, description: true, checklists: checklists(c[:id])),
        activity: activity(c[:id]).map { |e| activity_json(e) }, }
    end

    # A change made elsewhere (attachments) recorded like every other: the card is touched, the activity says who. → activity id
    def event(card_id, kind, body, by)
      by = who!(by)
      touch(card_id)
      log(card_id, kind, body, by)
    end

    # ── cards ─────────────────────────────────────────────────────────────────────────────────────

    # project_exists: the host says whether the board exists (a slug it knows). → the new card's id.
    # owner_session: the card is OWNED from its first second (assignee = by, owner = that session): the rule for a card
    # an agent creates — Tools pass the agent's session, so no card an agent made ever waits for a claim.
    def create(slug:, title:, by:, column: nil, notes: "", labels: [], assignee: nil, priority: nil, due: nil, parent: nil,
               metadata: nil, agent: false, owner_session: nil, owner_socket: "default")
      board!(slug)
      b = board_of(slug)
      column = column.nil? ? b.default_column : column!(b, column)
      raise Denied, "agents cannot create cards in #{b.label(column)}" if agent && b.no_create_for_agents.include?(column)
      # the operator's columns: a card reaches them only through their gates (kanban_handoff, the operator's approval)
      if agent && b.agent_closed?(column)
        if b.gate?(column)
          raise Denied, "agents cannot create cards in #{b.label(column)}: create it, do the work, then kanban_handoff " \
                        "(QA steps, PR, CI)"
        end

        raise Denied, "agents cannot create cards in #{b.label(column)}: only the operator moves a card there"
      end

      by = who!(by)
      now = @clock.call
      pid = parent!(parent, slug, nil)
      owner = owner_session.to_s.strip
      owner = nil if owner.empty?
      owner_session!(owner, owner_socket) if owner
      # A session owns cards only on the board it is registered for: an agent of project A creating a
      # card on B's board leaves it ownerless there — B's intake (a spawned worker, B's lead) takes it, B's sessions get
      # its pings — and the creator is only `created_by`. An unregistered session (started by hand) cannot be checked.
      reg = owner && open_session(owner)
      elsewhere = reg && reg[:project_slug] != slug ? reg[:project_slug] : nil
      owner = nil if elsewhere
      # validate before the transaction: Sequel wraps anything raised inside one in a DatabaseError
      row = { project_slug: slug, column: column, title: title!(title), notes: notes.to_s,
              labels: JSON.generate(labels!(labels, slug)),
              assignee: owner ? by : assignee!(assignee), priority: priority!(priority), due_at: due!(due),
              created_by: by, created_at: now, updated_at: now,
              parent_id: pid, metadata: metadata.nil? ? nil : JSON.generate(metadata!(metadata)),
              owner_session: owner, owner_socket: owner && owner_socket.to_s, }
      blocked!(b, column, unfinished([pid].compact), "card")
      @db.transaction do
        id = cards.insert(row.merge(position: live(slug).where(column: column).count))
        note = if owner then " · owner session: #{owner} (#{by})"
               elsif elsewhere then " · not owned: #{owner_session.to_s.strip} is registered for #{elsewhere}, not #{slug}"
               else ""
               end
        log(id, "create", "created in #{b.label(column)}#{note}", by)
        log(id, "parent", "waits for card ##{pid}", by) if pid
        promote_children(id, by) if b.done?(column)
        id
      end
    end

    # Only the keys given change. Logs which fields changed.
    def update(id, attrs, by:)
      c = card!(id)
      a = attrs.transform_keys(&:to_sym)
      unknown = a.keys - FIELDS
      raise Invalid, "unknown fields: #{unknown.join(', ')}" if unknown.any?

      set = {}
      set[:title] = title!(a[:title]) if a.key?(:title)
      set[:notes] = a[:notes].to_s if a.key?(:notes)
      set[:labels] = labels!(a[:labels], c[:project_slug]) if a.key?(:labels)
      set[:assignee] = assignee!(a[:assignee]) if a.key?(:assignee)
      set[:priority] = priority!(a[:priority]) if a.key?(:priority)
      set[:due_at] = due!(a[:due]) if a.key?(:due)
      set[:due_done] = bool!(a[:due_done], "due_done") if a.key?(:due_done)
      set[:cover] = color!(a[:cover], nullable: true) if a.key?(:cover)
      set[:parent_id] = parent!(a[:parent], c[:project_slug], c[:id]) if a.key?(:parent)
      set[:metadata] = a[:metadata].nil? ? nil : JSON.generate(metadata!(a[:metadata])) if a.key?(:metadata)
      changed = set.reject { |k, v| c[k] == v }
      return c if changed.empty?

      by = who!(by)
      @db.transaction do
        row = changed.merge(updated_at: @clock.call)
        row[:labels] = JSON.generate(row[:labels]) if row.key?(:labels)
        row[:due_done] = row[:due_done] ? 1 : 0 if row.key?(:due_done)
        cards.where(id: c[:id]).update(row)
        log(c[:id], "update", changed.map { |k, v| describe(k, v) }.join(" · "), by)
      end
      card(id)
    end

    PR_URL = %r{\Ahttps://github\.com/[\w.-]+/[\w.-]+/pull/[1-9]\d*\z}
    PR_ROLE = /\A[a-z][a-z0-9_-]{0,31}\z/

    # The agent that opened a PR assigns it to its card: metadata `prs.<role>` = the PR URL (the host names the roles,
    # e.g. local · public, and reads them back; nothing is derived from branch names or text). Merged into the card's
    # metadata in one transaction — the other keys stay. Re-assigning a role replaces its PR; the same URL again is a
    # no-op. Logged as an `update` line "PR <role>: <url>".
    def assign_pr(id, url:, role:, by:)
      url = url.to_s.strip
      unless url.match?(PR_URL)
        raise Invalid, "pr_url must be a GitHub pull request URL (https://github.com/<owner>/<repo>/pull/<n>)"
      end
      unless role.to_s.match?(PR_ROLE)
        raise Invalid, "role must be a lowercase word (a-z 0-9 _ -, at most 32): #{role.to_s[0, 40].inspect}"
      end

      by = who!(by)
      prs = card_prs!(card!(id)) # refused before the transaction: a raise inside one reaches the host wrapped
      return card(id) if prs[role] == url

      @db.transaction do
        c = card!(id) # read again inside: the host serialises writers (SQLite BEGIN IMMEDIATE, PostgreSQL lock)
        meta = c[:metadata] ? JSON.parse(JSON.generate(c[:metadata])) : {}
        meta["prs"] = card_prs!(c).merge(role => url)
        cards.where(id: c[:id]).update(metadata: JSON.generate(metadata!(meta)), updated_at: @clock.call)
        log(c[:id], "update", "PR #{role}: #{url}", by)
      end
      card(id)
    end

    # the card's metadata prs ({} when none); anything but an object is refused with what it is
    def card_prs!(c)
      prs = c[:metadata].is_a?(Hash) ? c[:metadata]["prs"] : nil
      return {} if prs.nil?
      raise Invalid, "card ##{c[:id]} metadata prs is not an object: #{JSON.generate(prs)[0, 200]}" unless prs.is_a?(Hash)

      prs
    end

    # To column at position (0-based; nil or past the end = last). Both columns are renumbered.
    # `transition:` names a workflow edge out of the card's column instead of a target column (Jira's "Start work").
    # The green-CI gate (approval.requires_green_ci) is asked only by an explicit approval: Store#approve (the Approve
    # button) or the step's own named transition ("Approve"). Any other operator move along the step — a drag, the
    # catch-all edge — is never refused by it: it still approves, and its activity line says CI was not asked.
    # `withdraw:` = Store#unapprove's move back to the step's gate: the operator's undo needs no edge in the workflow.
    def move(id, column: nil, by:, position: nil, agent: false, handoff: false, transition: nil, approval: false,
             withdraw: false)
      c = card!(id)
      named = !transition.to_s.strip.empty?
      raise Invalid, "card #{id} is archived" if c[:archived_at]

      b = board_of(c[:project_slug])
      column = transition_target!(b, c, column, transition, agent) if named
      raise Invalid, "column or transition is required" if column.nil? || column.to_s.empty?

      column = column!(b, column)
      move_check!(b, c, column, agent: agent, handoff: handoff, withdraw: withdraw)
      by = who!(by)
      pos = position.nil? || position.to_s.empty? ? nil : Integer(position, exception: false)
      if !position.nil? && !position.to_s.empty? && (pos.nil? || pos.negative?)
        raise Invalid, "position must be an integer >= 0 (got #{position.inspect})"
      end

      step = !agent && b.approval_for(c[:column], column)
      checked = step && c[:column] != column && (approval || (named && transition.to_s.strip.casecmp?(step.name)))
      green_ci!(c, b, step) if checked
      rounds = c[:column] != column ? review_rounds_after(b, c, column, agent) : nil
      @db.transaction do
        place(c, column, pos)
        if c[:column] != column
          log(c[:id], "move", "#{b.label(c[:column])} → #{b.label(column)}#{' (approval withdrawn)' if withdraw}", by)
          cards.where(id: c[:id]).update(review_rounds: JSON.generate(rounds)) if rounds != review_rounds(c)
          # the gate's head / last view belong to the handoff that brought the card in: any other move ends them (a
          # drag into another gate starts with nothing recorded — its hold is read live)
          cards.where(id: c[:id]).update(gate_head: nil, gate_state: nil) if !handoff && (c[:gate_head] || c[:gate_state])
          if step
            # the operator moving a card from an approval step's gate into its target IS that approval (any other move
            # into it — from elsewhere, by a catch-all edge — is a plain move: nobody is pinged to carry on)
            cards.where(id: c[:id]).update(approved_at: @clock.call, approved_by: by)
            note = approval_note(b, step)
            unasked = @config.green_ci_gate? && !checked
            note += " (dragged: CI not asked)" if unasked
            log(c[:id], "approve", note, by)
            # the ping says it too: the owner carries on from it (a final step merges) and must read CI itself
            enqueue_ping(c, "approve", by, unasked ? "#{step.from} #{CI_NOT_ASKED}" : step.from)
          else
            # leaving the approved column for anywhere but a terminal one (history) withdraws the approval
            cards.where(id: c[:id]).update(approved_at: nil, approved_by: nil) if c[:approved_at] && !b.terminal?(column)
            enqueue_ping(c, "move", by, "moved #{b.label(c[:column])} → #{b.label(column)}:") unless agent
          end
          promote_children(c[:id], by) if b.done?(column)
          clear_flags_at_end(c, b, column, by) if b.terminal?(column)
        end
      end
      adopt_ownerless(only: c[:id]) if c[:column] != column && !agent
      card(id)
    end

    def archive(id, by:, archived: true)
      c = card!(id)
      return c if archived == !c[:archived_at].nil?

      by = who!(by)
      @db.transaction do
        if archived
          cards.where(id: c[:id]).update(archived_at: @clock.call, updated_at: @clock.call)
          renumber_column(c[:project_slug], c[:column])
        else
          at_end = live(c[:project_slug]).where(column: c[:column]).count
          cards.where(id: c[:id]).update(archived_at: nil, updated_at: @clock.call, position: at_end)
        end
        log(c[:id], "archive", archived ? "archived" : "restored", by)
      end
      card(id)
    end

    # ── parents (dependencies): a card waits for its parent ───────────────────────────────────────

    # Live children of a card (any column), oldest first.
    def children(id) = decorate(cards.where(parent_id: Integer(id), archived_at: nil).order(:id).all.map { |c| hydrate(c) })

    # The ids among `parent_ids` that are not in a done column of their board (or are archived — an archived parent never
    # finishes). Nothing is unfinished on a host that does not enforce dependencies.
    def unfinished(parent_ids)
      return [] if parent_ids.empty? || !@config.dependencies

      ps = cards.where(id: parent_ids).all
      boards = boards_for(ps.map { |p| p[:project_slug] }.uniq)
      ps.reject { |p| !p[:archived_at] && boards[p[:project_slug]].done?(p[:column]) }.map { |p| p[:id] }
    end

    # ── comments ─────────────────────────────────────────────────────────────────────────────────

    # → the comment's activity id. operator: true = the web user. The operator's comment on a card flagged
    # needs_operator (an agent's question — not a session dialog, which is answered by pressing a key) IS the answer:
    # the flag clears (the card keeps its column; logged as the operator's answer) and the owner gets ONE ping that
    # carries the answer and says so.
    def comment(id, body:, author:, operator: false)
      c = card!(id)
      raise Invalid, "body is required" if body.to_s.strip.empty?

      author = who!(author)
      b = board_of(c[:project_slug])
      answer = operator && c[:asked_at] && !c[:archived_at] && !c[:dialog_id]
      # the operator's comment on an externally blocked card is the operator's word that the blocker is gone (the
      # operator's way to clear the flag — kanban_unblock is the agent's)
      unblock = operator && c[:blocked_at] && !c[:archived_at]
      @db.transaction do
        touch(c[:id])
        cid = log(c[:id], "comment", body.to_s, author)
        # the operator's words that reached nobody are kept marked: relayed in one ping when the card gains an owner
        activity_t.where(id: cid).update(by_operator: true, undelivered: !c[:owner_session]) if operator
        # the author's own attachments this comment shows belong to it
        refs = body.to_s.scan(@attachment_ref).flatten.map(&:to_i)
        if refs.any?
          attachments_t.where(id: refs, card_id: c[:id], activity_id: nil, uploaded_by: author).update(activity_id: cid)
        end
        if unblock
          cards.where(id: c[:id]).update(blocked_at: nil, blocked_author: nil, blocked_reason: nil, blocked_url: nil,
                                         flag_reminded_at: nil, updated_at: @clock.call)
          log(c[:id], "flag", "blocked_external cleared by the operator's comment", author)
        end
        if answer
          clear_question(c[:id])
          log(c[:id], "answer", "answered the question — the card stays in #{b.label(c[:column])}, work resumes", author)
          enqueue_ping(c, "answer", author, body.to_s)
        else
          enqueue_ping(c, "comment", author, body.to_s)
        end
        cid
      end
    end

    # ── the needs_operator flag: an agent asks the operator; the card stays where it is ─────────────
    # Requires an owner session — an answer nobody hears is the failure this flag exists to prevent. A new ask on a
    # flagged card replaces the open question. The card keeps its column (a question in review keeps its place in
    # review); while flagged, agents cannot move it; the operator's comment clears the flag.
    # session: an agent that has not claimed the card yet may claim and ask in one step (its live tmux session).
    def ask(id, question:, by:, options: nil, session: nil)
      c = card!(id)
      b = board_of(c[:project_slug])
      c = claim(c[:id], assignee: by, session: session) if session && c[:owner_session].nil?
      raise Invalid, "card ##{c[:id]} is archived" if c[:archived_at]
      if b.terminal?(c[:column])
        raise Denied, "card ##{c[:id]} is in #{b.label(c[:column])} — its work is over; ask with kanban_comment"
      end

      q = question.to_s.strip
      raise Invalid, "question is required: what the operator must answer or decide (markdown)" if q.empty?
      raise Invalid, "question is longer than #{MAX_QUESTION}" if q.length > MAX_QUESTION

      opts = options!(options)
      unless c[:owner_session]
        raise Denied, "card ##{c[:id]} has no owner session — nobody would hear the answer. " \
                      "Claim it first: kanban_claim(id, assignee, tmux_session)"
      end

      by = who!(by)
      @db.transaction do
        cards.where(id: c[:id]).update(question: q, question_options: opts && JSON.generate(opts), asked_at: @clock.call,
                                       asked_by: by, dialog_id: nil, flag_reminded_at: nil, updated_at: @clock.call)
        body = opts ? "#{q}\n\n**Options:** #{opts.map { |o| "`#{o.tr('`', "'")}`" }.join(' · ')}" : q
        # a normal comment: the operator reads the agent's words in the activity like any comment,
        # not a separate entry kind; the card's question box carries the open question and its options
        log(c[:id], "comment", "**Question for the operator:**\n\n#{body}", by)
        log(c[:id], "flag", "needs_operator set — the card waits in #{b.label(c[:column])}", by)
      end
      card(id)
    end

    # ── the blocked_external flag: an agent waits for the world (CI, a third party) ───────────────
    # reason + url required; the card keeps its column; agents cannot move it until kanban_unblock.
    def block(id, reason:, url:, by:)
      c = card!(id)
      b = board_of(c[:project_slug])
      raise Invalid, "card ##{c[:id]} is archived" if c[:archived_at]
      raise Denied, "card ##{c[:id]} is in #{b.label(c[:column])} — its work is over" if b.terminal?(c[:column])

      r = reason.to_s.strip
      raise Invalid, "reason is required: what the card waits for (CI, an API, a person outside the board)" if r.empty?
      raise Invalid, "reason is longer than #{MAX_BLOCK_REASON}" if r.length > MAX_BLOCK_REASON

      u = url.to_s.strip
      raise Invalid, "url is required: where the blocker is seen (a CI build, an issue, a status page)" if u.empty?
      raise Invalid, "url must be an http(s) URL (got #{u[0, 80].inspect})" unless u.match?(URL_RE)

      by = who!(by)
      @db.transaction do
        cards.where(id: c[:id]).update(blocked_at: @clock.call, blocked_author: by, blocked_reason: r, blocked_url: u,
                                       flag_reminded_at: nil, updated_at: @clock.call)
        log(c[:id], "comment", "**Blocked (external):** #{r}\n\n#{u}", by)
        log(c[:id], "flag", "blocked_external set — the card waits in #{b.label(c[:column])}", by)
      end
      card(id)
    end

    def unblock(id, by:, note: nil)
      c = card!(id)
      raise Invalid, "card ##{c[:id]} is not blocked" unless c[:blocked_at]

      by = who!(by)
      @db.transaction do
        cards.where(id: c[:id]).update(blocked_at: nil, blocked_author: nil, blocked_reason: nil, blocked_url: nil,
                                       flag_reminded_at: nil, updated_at: @clock.call)
        why = note.to_s.strip
        log(c[:id], "flag", "blocked_external cleared#{why.empty? ? '' : " — #{why}"}", by)
      end
      card(id)
    end

    # ONE reminder per flag: a card flagged for `flags.reminder_hours` with no reminder yet gets a comment by the
    # system author (the board and the daily report show it; the owner is pinged like for any comment). → card ids
    def flag_reminders
      now = @clock.call
      after = @config.flags.reminder_hours * 3600
      sys = @config.system_author
      rows = cards.where(archived_at: nil, flag_reminded_at: nil)
                  .where(Sequel.|(Sequel.~(asked_at: nil), Sequel.~(blocked_at: nil)))
                  .all
      rows.select { |c| now - flag_since(c) >= after }.map do |c|
        b = board_of(c[:project_slug])
        what = []
        what << "a question for the operator (#{(now - c[:asked_at]) / 3600} h): #{first_line(c[:question])}" if c[:asked_at]
        if c[:blocked_at]
          what << "blocked (external, #{(now - c[:blocked_at]) / 3600} h): #{c[:blocked_reason]} #{c[:blocked_url]}"
        end
        @db.transaction do
          cards.where(id: c[:id]).update(flag_reminded_at: now, updated_at: now)
          log(c[:id], "comment", "**Reminder** — card ##{c[:id]} has waited in #{b.label(c[:column])} for " \
                                 "#{@config.flags.reminder_hours} h: #{what.join('; ')}", sys)
          enqueue_ping(c, "comment", sys, "Reminder: the card still waits — #{what.join('; ')}")
        end
        c[:id]
      end
    end

    # What a comment / move by `author` on card c does: who it pings, or why nobody. Returned to the operator
    # (API `delivered`) so a message never vanishes silently.
    def delivery(c, author)
      return "none: no owner session" unless c[:owner_session]
      return "none: #{author} is the card's owner" if author == c[:owner_session] || (c[:assignee] && author == c[:assignee])

      "queued: #{c[:owner_session]}"
    end

    # ── handoff gate: an agent hands a card to a GATE column with what a human needs to check it ──
    # The gate: the one the card's column has a named agent transition into — several → `transition` (its name) or
    # `column` picks; none → refused with the board's gates. At the review loop's round limit the handoff carries the
    # host's unresolved label (review_loop).
    def handoff(id, qa:, pr_url:, ci_url:, ui_change:, by:, transition: nil, column: nil, review_summary: nil)
      c = card!(id)
      b = board_of(c[:project_slug])
      g = b.handoff or raise Invalid, "this board has no handoff gate (no gate column)"
      raise Invalid, "card ##{c[:id]} is archived" if c[:archived_at]
      raise Invalid, "card ##{c[:id]} is in #{b.label(c[:column])} — its work is over" if b.terminal?(c[:column])

      target = handoff_target!(b, c, transition, column)
      qa = qa.to_s.strip
      if qa.length < g.qa_min_chars
        raise Invalid, "qa is required: how to check it — steps, URLs (preview/prod), what to look for"
      end
      urls = { "pr_url" => [pr_url, g.requires_pr_url, "the GitHub PR"],
               "ci_url" => [ci_url, g.requires_ci_url, "the CI (Jenkins) build"], }
      urls.each do |k, (v, required, what)|
        if v.to_s.strip.empty?
          raise Invalid, "#{k} is required: #{what} URL" if required

          next
        end
        raise Invalid, "#{k} must be an http(s) URL (got #{v.to_s[0, 80].inspect})" unless v.to_s.strip.match?(URL_RE)
      end
      raise Invalid, "ui_change must be true or false" unless [true, false].include?(ui_change)
      if ui_change && g.ui_change_needs_screenshots
        shots = attachments_t.where(card_id: c[:id], deleted_at: nil, content_type: SCREENSHOT_TYPES).count
        if shots.zero?
          raise Invalid, "ui_change: attach screenshots first (kanban_attach, before/after at mobile + desktop) — " \
                         "card ##{c[:id]} has none"
        end
      end

      move_check!(b, c, target, agent: true, handoff: true) # BEFORE writing: a refused move leaves no handoff behind
      by = who!(by)
      pr = pr_url.to_s.strip.empty? ? nil : pr_url.to_s.strip
      # A gate with an approval step is entered only on green CI (approval.requires_green_ci), BEFORE writing: the card
      # as it will sit there is asked exactly what the operator's Approve will ask — unread, pending, red or unknown →
      # refused with that state, nothing written ("hand off once CI is green"). Green → the Approve answers at once.
      step = b.approval_from(target)
      green = step && green_ci!(c.merge(column: target, pr_url: pr || c[:pr_url]), b, step, handoff: true)
      ci = ci_url.to_s.strip.empty? ? nil : ci_url.to_s.strip
      exhausted = loop_exhausted?(b, c)
      summary = review_summary!(b, c, review_summary, exhausted)
      unresolved = summary && (summary["needs_human"] + summary["open"])
      @db.transaction do
        cards.where(id: c[:id]).update(qa_notes: qa, pr_url: pr, ci_url: ci, ui_change: ui_change, handoff_at: @clock.call,
                                       handoff_by: by, updated_at: @clock.call,
                                       gate_head: green.is_a?(Hash) ? green[:head] : nil,
                                       gate_state: green.is_a?(Hash) ? "ready" : nil)
        parts = ["handed to #{b.label(target)}:"]
        parts << "PR #{pr}" if pr
        parts << "CI #{ci}" if ci
        parts << "UI change, screenshots attached" if ui_change
        parts << summary_note(summary) if summary
        log(c[:id], "handoff", parts.join(" · ").sub(": ·", ":"), by)
        # ... and the agent's QA as a normal comment: a handoff reached the operator as a bare
        # move row, the QA only in the panel
        links = [pr && "PR #{pr}", ci && "CI #{ci}", ui_change ? "UI change, screenshots attached" : nil].compact
        log(c[:id], "comment", "**Handed to #{b.label(target)}**#{links.any? ? " · #{links.join(' · ')}" : ''}\n\n#{qa}", by)
        unresolved_label!(c, by, unresolved) if exhausted && unresolved.positive?
      end
      move(id, column: target, by: by, agent: true, handoff: true)
    end

    # ── approval: the operator approves a card for the next step; its agent then moves it on ──
    # Every approval step of the board (Board#approvals: a gate's one forward operator exit) works the same way.
    def approve(id, by:)
      c = card!(id)
      b = board_of(c[:project_slug])
      raise Invalid, "this board has no approval step (no gate with a single forward operator exit)" if b.approvals.empty?

      step = b.approval_from(c[:column])
      return move(id, column: step.to, by: by, approval: true) if step

      into = b.gate?(c[:column]) ? b.approval_into(c[:column]) : nil
      unless into
        raise Invalid, "only a card in #{b.approvals.map { |a| b.label(a.from) }.join(' or ')} can be approved " \
                       "(card ##{c[:id]} is in #{b.label(c[:column])})"
      end

      approve_in_place(c, b, into, by)
    end

    # A card sitting UNAPPROVED in a gate an approval step leads into (the operator dragged it there from anywhere but
    # the step's gate — a plain move): agents never leave a gate unapproved, so the operator approves it where it sits.
    # The same question as the step's Approve (green CI), the same approval, activity line and ping; no move.
    def approve_in_place(c, b, step, by)
      raise Invalid, "card ##{c[:id]} is archived" if c[:archived_at]
      if c[:approved_at]
        raise Invalid, "card ##{c[:id]} is already approved (by #{c[:approved_by]}) in #{b.label(c[:column])}"
      end

      by = who!(by)
      green_ci!(c, b, step)
      @db.transaction do
        cards.where(id: c[:id]).update(approved_at: @clock.call, approved_by: by, updated_at: @clock.call)
        log(c[:id], "approve", "#{approval_note(b, step)} (approved in #{b.label(c[:column])})", by)
        enqueue_ping(c, "approve", by, step.from)
      end
      card(c[:id])
    end

    # Back from an approval step's target to the gate it came from: the approval is withdrawn (move clears it). Only
    # while the card still sits there approved — once its agent moved it on there is nothing to withdraw, and the call
    # says so. The operator's undo of the operator's own approval: it asks the workflow for no edge back.
    def unapprove(id, by:)
      c = card!(id)
      b = board_of(c[:project_slug])
      raise Invalid, "this board has no approval step (no gate with a single forward operator exit)" if b.approvals.empty?

      step = b.approval_into(c[:column])
      raise Invalid, "card ##{c[:id]} is in #{b.label(c[:column])} — no approval to withdraw there" unless step
      raise Invalid, "card ##{c[:id]} is not approved — nothing to withdraw" unless c[:approved_at]

      move(id, column: step.from, by: by, withdraw: true)
    end

    # ── owner session: the agent session responsible for a card ──────────────────────────────────

    def set_owner(id, session:, by:, socket: "default")
      c = card!(id)
      s = session.to_s.strip
      if s.empty?
        cards.where(id: c[:id]).update(owner_session: nil, owner_socket: nil, owner_missing_since: nil, updated_at: @clock.call)
        log(c[:id], "owner", "owner session cleared", who!(by))
      else
        owner_session!(s, socket)
        @db.transaction do
          cards.where(id: c[:id]).update(owner_session: s, owner_socket: socket.to_s, owner_missing_since: nil,
                                         updated_at: @clock.call)
          log(c[:id], "owner", "owner session: #{s}", who!(by))
          relay_undelivered(c[:id]) if c[:owner_session] != s
        end
      end
      card(id)
    end

    # An agent claims a card: assignee + owner session in one step, refused while a parent is unfinished (the work
    # cannot start). The host verified the session is live before calling.
    def claim(id, assignee:, session:, socket: "default")
      c = card!(id)
      blocked!(board_of(c[:project_slug]), nil, c[:blocked_by], "card ##{c[:id]}", claim: true)
      owner_session!(session.to_s.strip, socket) # before the assignee lands: a refused claim changes nothing
      reg = open_session(session.to_s.strip)
      if reg && reg[:project_slug] != c[:project_slug]
        raise Denied, "session #{reg[:session]} is registered for #{reg[:project_slug]}: " \
                      "it cannot own a card on #{c[:project_slug]}'s board — " \
                      "leave it to #{c[:project_slug]}'s sessions"
      end
      update(c[:id], { "assignee" => assignee }, by: assignee)
      set_owner(c[:id], session: session, socket: socket, by: assignee)
    end

    # A session that may own a card here: the name alphabet, and — when the board names its sessions
    # (config.owner_sessions) — one of them. A session of ANOTHER board's host (another app's, another project's) is
    # refused by name, so a ping can never be typed into it (an unfiltered picker would list every tmux session).
    def owner_session!(s, socket = "default")
      raise Invalid, "tmux session must match #{SESSION.source}" unless s.match?(SESSION) && socket.to_s.match?(SESSION)
      return if @config.owner_session?(s)

      raise Invalid, "session #{s.inspect} is not one of this board's sessions (#{@config.owner_sessions.join(', ')})"
    end

    # A card that just gained an owner session: the operator's comments posted since the last agent comment that went to
    # nobody (no owner then) are queued as ONE ping in the operator's own words (author = the operator). Nothing is posted
    # on the card. All undelivered marks on the card are cleared (older ones were followed by an agent's comment).
    def relay_undelivered(card_id)
      acts = activity_t.where(card_id: card_id, kind: "comment")
      last_agent = acts.exclude(by_operator: true).max(:id) || 0
      lost = acts.where(by_operator: true, undelivered: true).where { id > last_agent }.order(:id).all
      activity_t.where(card_id: card_id, undelivered: true).update(undelivered: false)
      return if lost.empty?

      body = lost.map do |e|
        "#{e[:body]}\n— #{Time.at(e[:created_at]).strftime('%Y-%m-%d %H:%M')} (comment ##{e[:id]})"
      end.join("\n\n---\n\n")
      enqueue_ping(card(card_id), "relay", lost.last[:author], body)
    end

    # ── session dialogs: an owner session blocked on a dialog becomes an ask-gate question ───────

    # dialog: SessionDialog.parse output (symbol or string keys). Posts ONE "question" (author = system_author) on the
    # pending ping's card, else the session's most recently updated card — never a card in an operator_only column
    # (a gate, Done: the session's work there is handed over, a dialog is not about it) — and flags it needs_operator
    # (the card keeps its column). The question quotes the agent's latest comment on that card within
    # session_dialogs.context_minutes (why it is asking), or says it gave none. The same dialog (session + hash) is
    # posted once. → the card id, or nil (already posted / the session owns no live card outside the operator's columns).
    def dialog_question(session:, dialog:, socket: "default", card_id: nil)
      d = JSON.parse(JSON.generate(dialog))
      h = d["hash"].to_s
      raise Invalid, "dialog hash must be a sha256 hex digest" unless h.match?(/\A\h{64}\z/)
      raise Invalid, "dialog has no options" unless d["options"].is_a?(Array) && !d["options"].empty?

      unanswered_or_recent = Sequel.|({ answered_at: nil }, Sequel[:answered_at] > @clock.call - DIALOG_REASK)
      seen = dialogs_t.where(session: session, hash: h).where(unanswered_or_recent).first
      return nil if seen

      askable = lambda do |x|
        x && x[:owner_session] == session && !x[:archived_at] && !board_of(x[:project_slug]).operator_only.include?(x[:column])
      end
      c = card_id && card(card_id)
      c = nil unless askable.(c)
      c ||= cards.where(owner_session: session, archived_at: nil)
        .order(Sequel.desc(:updated_at), Sequel.desc(:id))
        .all
        .lazy
        .map { |r| card(r[:id]) }
        .find(&askable)
      return nil unless c

      b = board_of(c[:project_slug])
      keys = SessionDialog.keys(d)
      labels = d["options"].reject { |o| o["free"] }.map { |o| "#{o['key']}. #{o['label']}" } +
               (d["escape"] ? ["Esc = cancel"] : [])
      body = dialog_markdown(session, d, why: agent_reason(c))
      sys = @config.system_author
      @db.transaction do
        did = dialogs_t.insert(session: session, socket: socket.to_s, hash: h, card_id: c[:id], dialog: JSON.generate(d),
                               posted_at: @clock.call)
        cards.where(id: c[:id]).update(question: body, question_options: JSON.generate(labels), asked_at: @clock.call,
                                       asked_by: sys, dialog_id: did, flag_reminded_at: nil, updated_at: @clock.call)
        log(c[:id], "question", body, sys)
        log(c[:id], "flag", "needs_operator set in #{b.label(c[:column])} (session dialog: #{keys.join('/')})", sys)
      end
      c[:id]
    end

    # Live cards' owner sessions; the card an open (unanswered) dialog of this session + hash was posted on.
    def owner_sessions = cards.where(archived_at: nil).exclude(owner_session: nil).distinct.select_map(:owner_session)
    def dialog_card(session, hash) = dialogs_t.where(session: session, hash: hash.to_s).order(Sequel.desc(:id)).get(:card_id)

    def open_dialog!(c)
      d = c[:dialog_id] && dialogs_t.where(id: c[:dialog_id], answered_at: nil).first
      d || raise(Invalid, "card ##{c[:id]} has no open session dialog")
    end

    # The operator answers a session dialog: `press` (the host's launcher) presses the key only while the screen still
    # shows the same dialog (hash) and raises with the reason otherwise — then nothing is recorded. On success: the
    # answer is logged as the operator's, the card's flag clears; queued pings deliver once the screen is free.
    def answer_dialog(id, key:, by:, press:)
      c = card!(id)
      d = open_dialog!(c)
      dialog = JSON.parse(d[:dialog])
      k = key.to_s.strip.downcase
      keys = SessionDialog.keys(dialog)
      unless keys.include?(k)
        raise Invalid, "key must be one of #{keys.join(', ')} (free-text answers are typed in the session, never here)"
      end

      by = who!(by)
      press.call(session: d[:session], socket: d[:socket], hash: d[:hash], key: k)
      label = k == "esc" ? "Esc = cancel" : "#{k}. #{dialog['options'].find { |o| o['key'] == k }['label']}"
      @db.transaction do
        dialogs_t.where(id: d[:id]).update(answered_at: @clock.call, answered_by: by, answer: label)
        clear_question(c[:id])
        log(c[:id], "answer", "pressed #{label} in #{d[:session]} (the dialog on its screen)", by)
      end
      card(id)
    end

    # The agent's latest comment on the card within session_dialogs.context_minutes (not the operator's, not the
    # system author's) — what the session said it was doing when it stopped on the dialog. nil = it said nothing.
    def agent_reason(c)
      since = @clock.call - @config.session_dialogs.context_minutes * 60
      activity_t.where(card_id: c[:id], kind: "comment").where { created_at >= since }
                .where(Sequel.|({ by_operator: nil }, { by_operator: false })).exclude(author: @config.system_author)
                .order(Sequel.desc(:created_at), Sequel.desc(:id)).first
    end

    def dialog_markdown(session, d, why: nil)
      fence = ->(s) { "`" * [3, (s.scan(/`+/).map(&:size).max || 0) + 1].max }
      parts = ["**#{session}** is stopped on a dialog on its screen:"]
      parts << "#{fence.(d['command'])}text\n#{d['command']}\n#{fence.(d['command'])}" if d["command"].to_s.strip != ""
      parts << d["question"].to_s.strip unless d["question"].to_s.strip.empty?
      opts = d["options"].map { |o| "- `#{o['key']}` #{o['label']}#{o['free'] ? ' — free text: type it in the session' : ''}" }
      opts << "- `Esc` cancel" if d["escape"]
      parts << opts.join("\n")
      if d["free_text"]
        parts << "_Free text (Tab to amend / Type something) is typed in the session itself — " \
                 "#{@config.system_author} never types into a dialog._"
      end
      mins = @config.session_dialogs.context_minutes
      parts << if why
                 quote = why[:body].to_s.strip.lines.map { |l| "> #{l.rstrip}" }.join("\n")
                 at = Time.at(why[:created_at]).strftime('%H:%M')
                 "**Why** — #{why[:author]}'s last comment (comment ##{why[:id]}, #{at}):\n\n#{quote}"
               else
                 "**Why:** _the agent gave no reason — no comment on this card in the last #{mins} min._"
               end
      parts.join("\n\n")
    end

    # ── agent sessions: the registry of launched sessions, what they adopt, the concurrency cap ───

    # The engine is told about a session of `type` for board `slug` (the host's launch — before tmux starts it — or an
    # agent registering the session it runs in with kanban_register). The session is OWNED by its registration: it
    # becomes the owner (and its agent name the assignee) of every ownerless live card of the board in the type's
    # `takes` columns — a project's orphaned work (a reboot, a watchdog release) is picked up by the next session of a
    # type that takes it, by rule, not by a prompt. The operator's comments that reached nobody on those cards are
    # relayed (set_owner's rule). Refused: an unknown type / launcher, a session name the board does not own, a session
    # already registered and not ended. → {id, session, socket, type, launcher, agent, project, adopted: [card ids]}
    # for_cards: a SPAWN registration (Api#spawn_pass) owns exactly these cards (compare-and-set on an empty owner: a card
    # somebody took meanwhile is not taken) instead of adopting the type's `takes` columns.
    def register_session(session:, project:, type:, by:, launcher: nil, socket: "default", for_cards: nil)
      board!(project)
      t = @config.agent_type(type)
      l = t.registered_launcher!(launcher) # a launch / spawn passes the launcher it resolved; by hand: named or the only one
      s = session.to_s.strip
      owner_session!(s, socket)
      by = who!(by)
      not_registered!(s)
      agent = @config.agent_name(t, session: s, slug: project)
      now = @clock.call
      adopted = []
      @db.transaction do
        id = sessions_t.insert(session: s, socket: socket.to_s, project_slug: project, type_key: t.key, launcher_key: l,
                               agent_name: agent, launched_by: by, launched_at: now, last_seen_at: nil)
        if for_cards
          Array(for_cards).each do |cid|
            n = cards_t_cas(cid, project, s, socket, agent, now)
            next if n.zero?

            log(cid, "owner", "spawned for this card: #{agent} — session #{s} (#{t.key}) started for #{project}", by)
            relay_undelivered(cid)
            adopted << cid
          end
        elsif (takes = board_of(project).takes_columns(t)).any?
          live(project).where(column: takes, owner_session: nil).order(:column, :position, :id).all.each do |c|
            cards.where(id: c[:id]).update(owner_session: s, owner_socket: socket.to_s, owner_missing_since: nil,
                                           assignee: agent, updated_at: now)
            log(c[:id], "owner", "adopted by #{agent} — session #{s} (#{t.key}) registered for #{project}", by)
            relay_undelivered(c[:id])
            adopted << c[:id]
          end
        end
        { id: id, session: s, socket: socket.to_s, type: t.key, launcher: l, agent: agent, project: project, adopted: adopted }
      end
    end

    # THE INTAKE RULE (global): every live card in a column that a REGISTERED running session's agent type `takes` must
    # end up with an ALIVE owner session AND an assignee. Run on every notifier pass (so at the host's start too) and at
    # once on an operator move. A card is fixed when it has
    #   - no owner                      → the taker with the fewest owned cards in the project gets it;
    #   - an owner but no assignee      → the owner's registered agent name — in every watched column, even with no taker
    #                                     running (else it is handed to a taker);
    #   - an owner that is not alive    → (only when `live` is given) handed to a live taker — alive = in `live`, or
    #                                     registered less than `grace` seconds ago (a launch takes a moment to appear).
    # Each change is logged and pings the new assignee (it is the go-ahead). Nobody running → the card waits, visibly.
    # → the changed card ids. only: restrict to one card.
    def adopt_ownerless(live: nil, only: nil, by: nil, grace: 0)
      by ||= @config.system_author
      now = @clock.call
      open = sessions_t.where(ended_at: nil).order(:launched_at, :id).all
      alive = lambda do |name|
        live.nil? || live.include?(name) || open.any? { |r| r[:session] == name && now - r[:launched_at] < grace }
      end
      changed = []
      open.group_by { |r| r[:project_slug] }.each do |slug, rows|
        b = board_of(slug)
        takers = rows.select { |r| alive.(r[:session]) }
          .map { |r| [r, @config.agent_type(r[:type_key])] }
          .reject { |_, t| b.takes_columns(t).empty? }
        # spawn columns are Api#spawn_pass's — a gate only for its APPROVED cards (an unapproved gate card is the taker's)
        taken = takers.flat_map { |_, t| b.takes_columns(t) }.uniq - (b.spawn_columns - b.gate_columns)
        # a missing assignee is filled from its alive registered owner in every watched column, with or without a
        # taker running (a worker-owned In progress card would otherwise keep no assignee while no lead runs)
        pool = live(slug).where(column: (taken + b.watched_columns).uniq)
        pool = pool.where(id: only) if only
        pool.order(:column, :position, :id).all.each do |c|
          owner_ok = c[:owner_session] && alive.(c[:owner_session])
          next if owner_ok && !c[:assignee].to_s.strip.empty?

          own = owner_ok && rows.find { |r| r[:session] == c[:owner_session] }
          if owner_ok && own
            r = own
            why = "assignee filled from its owner session #{r[:session]}"
          elsif owner_ok
            next # an alive owner the board never registered: the operator's choice, left alone
          else
            next unless taken.include?(c[:column])
            next if c[:approved_at] && b.gate?(c[:column]) && b.spawn_columns.include?(c[:column])

            by_load = ->(x) { [cards.where(project_slug: slug, owner_session: x[:session], archived_at: nil).count, x[:id]] }
            r, t = takers.select { |_, ty| b.takes_columns(ty).include?(c[:column]) }.min_by { |x, _| by_load.(x) } || next
            why = if c[:owner_session]
                    "owner session #{c[:owner_session]} is not alive — handed to session #{r[:session]} (#{t.key})"
                  else
                    "session #{r[:session]} (#{t.key}) takes #{b.label(c[:column])} cards"
                  end
          end
          @db.transaction do
            cards.where(id: c[:id]).update(owner_session: r[:session], owner_socket: r[:socket], owner_missing_since: nil,
                                           assignee: r[:agent_name], updated_at: now)
            log(c[:id], "owner", "assigned to #{r[:agent_name]} — #{why}", by)
            relay_undelivered(c[:id]) if c[:owner_session] != r[:session]
            enqueue_ping(card(c[:id]), "assigned", by, "assigned")
          end
          changed << c[:id]
        end
      end
      changed
    end

    # ── the spawn queue (Api#spawn_pass) ──────────────────────────────────────────────────────────
    SPAWN_RETRY_S = 300

    # Ownerless live cards in spawn columns, FIFO (longest waiting first); a FLAGGED card waits for the operator (or
    # the world) — nobody is started for it until the flag clears. only: one card.
    def spawn_queue(only: nil)
      return [] if @config.spawn_types.empty?

      q = cards.where(archived_at: nil, owner_session: nil, asked_at: nil, blocked_at: nil)
      q = q.where(id: only) if only
      rows = q.order(:updated_at, :id).all
      boards = boards_for(rows.map { |c| c[:project_slug] }.uniq)
      # a gate card waits for the operator: only an APPROVED one (Awaiting merge, Ready to merge) gets a worker to carry on
      rows.select do |c|
        b = boards[c[:project_slug]]
        b.spawn_columns.include?(c[:column]) && (!b.gate?(c[:column]) || c[:approved_at])
      end
    end

    # A spawn that failed for this card less than SPAWN_RETRY_S ago: the card waits (visibly, its note says why) instead
    # of starting a new failing session every pass.
    def spawn_backoff?(card_id)
      at = activity_t.where(card_id: card_id, kind: "owner").where(Sequel.like(:body, "spawn failed%")).max(:created_at)
      !at.nil? && @clock.call - at < SPAWN_RETRY_S
    end

    # The card's spawn state, logged only when it CHANGES (a card waiting for a slot does not grow a line per pass).
    def spawn_note(card_id, body, by)
      last = activity_t.where(card_id: card_id, kind: "owner").order(Sequel.desc(:id)).get(:body)
      log(card_id, "owner", body, who!(by)) unless last == body
    end

    def cards_t_cas(cid, project, session, socket, agent, now)
      cards.where(id: cid, project_slug: project, owner_session: nil, archived_at: nil)
           .update(owner_session: session, owner_socket: socket.to_s, owner_missing_since: nil, assignee: agent,
                   updated_at: now)
    end

    # A registration ends: the host's launch failed, the watchdog saw the session gone, or the agent said goodbye.
    # Its cards are NOT released here — the watchdog's grace rule does that (a session may be gone for a moment).
    def end_session(session, reason:, by:)
      open = open_session(session.to_s) or raise Invalid, "session #{session} is not registered (or already ended)"
      sessions_t.where(id: open[:id]).update(ended_at: @clock.call, end_reason: reason.to_s, last_seen_at: open[:last_seen_at])
      open[:id]
    end

    # A launch or a spawn whose start failed ends its registration with this reason prefix (Api#launch, Api#spawn_pass).
    START_FAILED = "start failed: "
    LAUNCH_FAILURE_WINDOW_S = 86_400 # the waiting list shows the failed starts of the last day …
    LAUNCH_FAILURES_SHOWN = 10 # … the newest this many

    # The registrations on these projects whose start FAILED (claude never came up: the session was killed, its cards
    # released) within LAUNCH_FAILURE_WINDOW_S, newest first — what the operator must see at once, wherever they are
    # (Api#waiting). → [{id, session, project, type, launcher, launched_by, ended, reason}]
    def launch_failures(slugs)
      since = @clock.call - LAUNCH_FAILURE_WINDOW_S
      sessions_t.where(project_slug: slugs.to_a)
                .where(Sequel.like(:end_reason, "#{START_FAILED}%"))
                .where { ended_at >= since }
                .order(Sequel.desc(:ended_at), Sequel.desc(:id))
                .limit(LAUNCH_FAILURES_SHOWN)
                .all
                .map do |r|
        { id: r[:id], session: r[:session], project: r[:project_slug], type: r[:type_key], launcher: r[:launcher_key],
          launched_by: r[:launched_by], ended: iso(r[:ended_at]), reason: r[:end_reason].delete_prefix(START_FAILED), }
      end
    end

    def open_session(session) = sessions_t.where(session: session.to_s, ended_at: nil).first

    # One registration per session: a second one (the same session registering twice) is refused with the first.
    def not_registered!(session)
      open = open_session(session) or return

      raise Denied, "session #{session} is already registered as #{open[:type_key]} for #{open[:project_slug]} " \
                    "(since #{iso(open[:launched_at])}) — one registration per session"
    end
    # The open registration an author name resolves to: the session that acts as this agent name, or the session itself.
    def session_for_author(author)
      a = author.to_s.strip
      return nil if a.empty?

      sessions_t.where(ended_at: nil).where(Sequel.|({ agent_name: a }, { session: a })).order(Sequel.desc(:id)).first
    end

    # Reconcile the registry with the host's LIVE session names: a registered session not in the list is ended as gone
    # — unless it was registered less than `grace` seconds ago (a launch takes a moment to appear). Live ones get
    # last_seen_at. → the ended rows' sessions.
    def sessions_sync(live, grace:)
      now = @clock.call
      gone = []
      sessions_t.where(ended_at: nil).all.each do |r|
        if live.include?(r[:session])
          sessions_t.where(id: r[:id]).update(last_seen_at: now)
        elsif now - r[:launched_at] >= grace
          sessions_t.where(id: r[:id]).update(ended_at: now, end_reason: "gone from the host's session list")
          gone << r[:session]
        end
      end
      gone
    end

    # The sessions counted as RUNNING: registered, not ended, and in the live list — or registered within `grace`
    # seconds (starting). Nothing the engine did not register is counted: the host's own snapshot shows the rest.
    def running_sessions(live, grace:)
      now = @clock.call
      sessions_t.where(ended_at: nil)
        .order(:launched_at, :id)
        .all
        .select { |r| live.include?(r[:session]) || now - r[:launched_at] < grace }
    end

    # The cap state for the UI and the refusal: {max_sessions, running, free, sessions: [...], types: {key => {running,
    # max, max_per_project}}}
    def concurrency(live, grace:)
      rows = running_sessions(live, grace: grace)
      cap = @config.concurrency.max_sessions
      types = @config.agent_types.to_h do |t|
        [t.key, { running: rows.count { |r| r[:type_key] == t.key }, max: t.max, max_per_project: t.max_per_project }]
      end
      { max_sessions: cap, running: rows.size, free: (cap && [cap - rows.size, 0].max),
        sessions: rows.map { |r| session_json(r, live) },
        types: types, }
    end

    def session_json(r, live = nil)
      { id: r[:id], session: r[:session], socket: r[:socket], project: r[:project_slug], type: r[:type_key],
        launcher: r[:launcher_key], agent: r[:agent_name],
        launched_by: r[:launched_by], launched: iso(r[:launched_at]), last_seen: iso(r[:last_seen_at]),
        ended: iso(r[:ended_at]), end_reason: r[:end_reason],
        live: live.nil? ? nil : live.include?(r[:session]),
        cards: cards.where(owner_session: r[:session], archived_at: nil).count, }
    end

    # THE FOLLOW RULE: a type with `launcher_follows: <type>` runs the launcher of the project's RUNNING session of that
    # type (a lead started on localclaude → the workers spawned and the sub teams launched for its board run
    # localclaude too). → {type, session, launcher} of the newest such session, or nil (the type follows none, or
    # none runs — then the type's own launchers apply).
    def followed_launcher(type:, project:, live:, grace:)
      t = @config.agent_type(type)
      return nil unless t.launcher_follows

      r = running_sessions(live, grace: grace).reverse.find do |x|
        x[:type_key] == t.launcher_follows && x[:project_slug] == project.to_s
      end
      r && { type: r[:type_key], session: r[:session], launcher: r[:launcher_key] }
    end

    # The launcher a session of `type` starts with for `project`: the followed session's while one runs — another one
    # asked for explicitly is refused (Denied, with who is followed), never silently swapped —, else the asked one, else
    # the type's spawn_launcher or only launcher (AgentType#launcher!: several and none configured → Invalid).
    def launcher_for!(type:, project:, asked:, live:, grace:)
      t = @config.agent_type(type)
      f = followed_launcher(type: t.key, project: project, live: live, grace: grace)
      return t.launcher!(asked) unless f

      a = asked.to_s
      unless a.empty? || a == f[:launcher]
        raise Denied, "#{t.key} sessions of #{project} run #{f[:launcher]} while the #{f[:type]} session #{f[:session]} does " \
                      "(agent_types[#{t.key}].launcher_follows) — #{a} refused"
      end
      t.launcher!(f[:launcher])
    end

    # May one more session of `type` start for `project` now? Raises Denied with the reason (who runs, which cap) —
    # the global concurrency.max_sessions, then the type's max, then its max_per_project. Never queued, never exceeded.
    def launch_check!(type:, project:, live:, grace:)
      t = @config.agent_type(type)
      rows = running_sessions(live, grace: grace)
      who = ->(rs) { rs.map { |r| "#{r[:session]} (#{r[:type_key]}, #{r[:project_slug]})" }.join(", ") }
      max = @config.concurrency.max_sessions
      if max && rows.size >= max
        raise Denied, "#{rows.size}/#{max} agent sessions are running — the host's cap (concurrency.max_sessions): " \
                      "#{who.(rows)}"
      end

      mine = rows.select { |r| r[:type_key] == t.key }
      if t.max && mine.size >= t.max
        raise Denied, "#{mine.size}/#{t.max} #{t.key} sessions are running — this type's cap (agent_types[#{t.key}].max): " \
                      "#{who.(mine)}"
      end

      here = mine.select { |r| r[:project_slug] == project }
      if t.max_per_project && here.size >= t.max_per_project
        raise Denied, "#{here.size}/#{t.max_per_project} #{t.key} session#{'s' if here.size > 1} " \
                      "already run#{'s' if here.size == 1} for #{project} (agent_types[#{t.key}].max_per_project): " \
                      "#{who.(here)}"
      end

      concurrency(live, grace: grace)
    end

    # Cards a registration adopted or owns, released because its launch FAILED (the session never came up): owner and
    # assignee cleared, logged — the next registration takes them again.
    def release_session_cards(session, reason:, by:)
      now = @clock.call
      cards.where(owner_session: session.to_s, archived_at: nil).all.each do |c|
        cards.where(id: c[:id]).update(owner_session: nil, owner_socket: nil, owner_missing_since: nil, assignee: nil,
                                       updated_at: now)
        log(c[:id], "owner", "owner session #{session} released: #{reason}", who!(by))
        pings_t.where(card_id: c[:id], status: "pending", session: session.to_s)
          .update(status: "failed", error: reason.to_s, done_at: now)
      end
    end

    # ── session dialogs that are no longer on the screen ──────────────────────────────────────────

    # check: ->(session, socket) { the delivery port's dialog answer }. Every OPEN dialog question whose session no
    # longer shows that dialog (gone, a clear screen, a different dialog — somebody answered it in the terminal, or
    # the session ended) is closed: answered by the system with the reason, the card's dialog and flag cleared (it
    # waits for nobody now). A stale question never sits on a card (a dialog from the day before would otherwise
    # still be attached). → closed card ids
    def expire_dialogs(check:, session: nil)
      sys = @config.system_author
      closed = []
      ds = dialogs_t.where(answered_at: nil)
      ds = ds.where(session: session.to_s) if session
      ds.order(:id).all.group_by { |d| [d[:session], d[:socket]] }.each do |(sess, sock), rows|
        r = check.call(sess, sock)
        on_screen = r["ok"] && r["dialog"] ? r["dialog"]["hash"].to_s : nil
        why = if !r["ok"] then "session #{sess} is #{r['gone'] ? 'gone' : "unreadable (#{r['error']})"}"
              elsif on_screen then "a different dialog is on its screen"
              else "the dialog is no longer on its screen (answered in the session)"
              end
        next if !r["ok"] && !r["gone"] # unreadable for a moment: not a verdict

        rows.each do |d|
          next if on_screen == d[:hash]

          now = @clock.call
          @db.transaction do
            dialogs_t.where(id: d[:id]).update(answered_at: now, answered_by: sys, answer: "expired: #{why}")
            c = card(d[:card_id])
            next unless c && c[:dialog_id] == d[:id]

            clear_question(c[:id])
            log(c[:id], "answer", "session dialog expired: #{why}", sys)
            closed << c[:id]
          end
        end
      end
      closed
    end

    # ── pings ─────────────────────────────────────────────────────────────────────────────────────

    # A comment (or the operator moving the card) pings the owner session — unless the owner's own agent did it
    # (author == assignee). No owner session = nothing to ping: `delivery` says so to the operator.
    def enqueue_ping(c, reason, author, body)
      return unless delivery(c, author).start_with?("queued") # no owner session, or the owner's own words

      tag = "[#{@config.system_author}]"
      b = board_of(c[:project_slug])
      text = case reason
             when "answer"
               clip = body.length > PING_BODY ? "#{body[0, PING_BODY]}…" : body
               "#{tag} #{author} ANSWERED your question on card ##{c[:id]} \"#{c[:title]}\" (#{c[:project_slug]}):" \
               "\n\n#{clip}\n\n" \
               "The needs_operator flag is cleared; the card stays in #{b.label(c[:column])}. " \
               "Read it with kanban_card id=#{c[:id]}, " \
               "continue the work, and reply with kanban_comment."
             when "relay"
               "#{tag} #{author} commented on card ##{c[:id]} \"#{c[:title]}\" " \
               "(#{b.label(c[:column])}, #{c[:project_slug]}) while no session owned it — " \
               "it reached nobody until now (your session just became the owner):\n\n#{body[0, 6000]}\n\n" \
               "Read the card with kanban_card id=#{c[:id]}, act on it, and reply with kanban_comment."
             when "comment"
               clip = body.length > PING_BODY ? "#{body[0, PING_BODY]}…" : body
               "#{tag} New comment on card ##{c[:id]} \"#{c[:title]}\" (#{b.label(c[:column])}, #{c[:project_slug]}) " \
               "by #{author}:\n\n#{clip}\n\n" \
               "Read the card with kanban_card id=#{c[:id]}, act on it, and reply with kanban_comment."
             when "ci_idle"
               "#{tag} #{body}"
             when "assigned"
               "#{tag} Card ##{c[:id]} \"#{c[:title]}\" (#{b.label(c[:column])}, #{c[:project_slug]}) " \
               "is assigned to you — your session takes #{b.label(c[:column])} cards. " \
               "Read it with kanban_card id=#{c[:id]} and start the work."
             when "approve"
               from, how = body.split(" ", 2)
               step = b.approval_from(from)
               # dragged along the step: the green-CI gate was not asked, so the owner reads the PR's checks first
               unasked = how == CI_NOT_ASKED ? " #{DRAGGED_NOTE}" : ""
               if step.final
                 # dragged: the merge waits for green checks (a red or unread one is not merged)
                 merge = unasked.empty? ? "Merge it now" : "Merge it once its checks are green (red: do not merge, say so)"
                 "#{tag} #{author} APPROVED card ##{c[:id]} \"#{c[:title]}\" (#{c[:project_slug]}) " \
                   "— it is in #{b.label(step.to)}.#{unasked} #{merge}, then move the card to #{b.label(step.then)} " \
                   "with kanban_move id=#{c[:id]} column=#{step.then} and post the merge commit/PR with kanban_comment."
               else
                 on = if step.then && b.gate?(step.then)
                        # a gate is entered only by a handoff (agents never kanban_move into one)
                        ", then hand the card to #{b.label(step.then)} with kanban_handoff id=#{c[:id]} " \
                          "column=#{step.then} (qa, pr_url, ci_url, ui_change)"
                      elsif step.then
                        ", then move the card to #{b.label(step.then)} with kanban_move id=#{c[:id]} column=#{step.then}"
                      else
                        ""
                      end
                 # approved where it sat (Store#approve_in_place): nothing moved
                 went = "it moved #{b.label(step.from)} → #{b.label(step.to)}"
                 went = "it stays in #{b.label(step.to)}" if c[:column] == step.to
                 "#{tag} #{author} APPROVED card ##{c[:id]} \"#{c[:title]}\" (#{c[:project_slug]}) " \
                   "— #{went}.#{unasked} " \
                   "Do the next step now#{on}, and post what you did with kanban_comment."
               end
             else
               "#{tag} #{author} #{body} card ##{c[:id]} \"#{c[:title]}\" (#{c[:project_slug]}). " \
               "Read it with kanban_card id=#{c[:id]} and continue."
             end
      # one pending ping per card+session: a burst of comments arrives as one message, not a stream of prompts
      pending = pings_t.where(card_id: c[:id], session: c[:owner_session], status: "pending").first
      if pending
        pings_t.where(id: pending[:id]).update(text: "#{pending[:text]}\n\n---\n\n#{text}"[0, 7900])
        return
      end
      pings_t.insert(card_id: c[:id], session: c[:owner_session], socket: c[:owner_socket] || "default", text: text,
                     reason: reason, status: "pending", created_at: @clock.call)
    end

    def pending_pings(limit = 20) = pings_t.where(status: "pending").order(:created_at, :id).limit(limit).all

    def ping_result(ping, status, error: nil)
      pings_t.where(id: ping[:id]).update(status: status, error: error, attempts: Sequel[:attempts] + 1,
                                          done_at: status == "pending" ? nil : @clock.call)
      return if status == "pending"

      note = status == "sent" ? "pinged #{ping[:session]} (#{ping[:reason]})" : "ping to #{ping[:session]} failed: #{error}"
      log(ping[:card_id], "ping", note, @config.system_author)
    end

    def pings(card_id, limit = 10) = pings_t.where(card_id: Integer(card_id)).order(Sequel.desc(:id)).limit(limit).all

    def ping_json(p)
      { at: iso(p[:created_at]), done_at: iso(p[:done_at]), session: p[:session], reason: p[:reason], status: p[:status],
        error: p[:error], attempts: p[:attempts], }
    end

    # Watchdog: cards whose owner session is gone. `live` = session names the collector sees now. A card missing
    # for longer than `grace` seconds is released: owner + assignee cleared, watchdog.from → watchdog.to, pending pings
    # failed, all logged. Only "gone" releases: a busy session (or one blocked on a dialog) is live and keeps its
    # cards; a released ask-column card stays there (it still waits for the operator), a released parked card stays
    # parked. Every column but the done ones is scanned (Board#owner_watched_columns): a finished card (done, merged)
    # keeps its owner and assignee as history — the watchdog never unassigns a Done card.
    # → released card ids.
    def watch_owners(live, grace:)
      now = @clock.call
      sys = @config.system_author
      released = []
      owned = cards.exclude(owner_session: nil).where(archived_at: nil).all
      boards = boards_for(owned.map { |c| c[:project_slug] }.uniq)
      owned.each do |c|
        b = boards[c[:project_slug]]
        next unless b.owner_watched_columns.include?(c[:column])

        wd = b.watchdog
        if live.include?(c[:owner_session])
          cards.where(id: c[:id]).update(owner_missing_since: nil) if c[:owner_missing_since]
          next
        end
        if c[:owner_missing_since].nil?
          cards.where(id: c[:id]).update(owner_missing_since: now)
          next
        end
        next if now - c[:owner_missing_since] < grace

        @db.transaction do
          gone = c[:owner_session]
          sessions_t.where(session: gone, ended_at: nil).update(ended_at: now, end_reason: "gone (watchdog)")
          cards.where(id: c[:id]).update(owner_session: nil, owner_socket: nil, owner_missing_since: nil, assignee: nil,
                                         updated_at: now)
          unassigned = c[:assignee] ? " #{c[:assignee]}" : ''
          log(c[:id], "watchdog", "session #{gone} is gone (#{now - c[:owner_missing_since]}s) — unassigned#{unassigned}", sys)
          pings_t.where(card_id: c[:id], status: "pending")
            .update(status: "failed", error: "owner session #{gone} is gone", done_at: now)
          if wd && c[:column] == wd.from
            renumber(live(c[:project_slug]).where(column: wd.to).order(:position, :id).select_map(:id) + [c[:id]])
            cards.where(id: c[:id]).update(column: wd.to)
            renumber_column(c[:project_slug], wd.from)
            log(c[:id], "move", "#{b.label(wd.from)} → #{b.label(wd.to)} (no owner)", sys)
          end
        end
        released << c[:id]
      end
      released
    end

    # ── approval prefetch (approval.requires_green_ci): Approve never waits for a CI read ─────────────────────
    #
    # Every card sitting in a gate an approval step leaves from has that step's checks asked of the host's ci: port —
    # at the handoff and on every notifier watch pass — so a host that answers asynchronously (a poller holding the
    # token, answering what was asked recently) always holds a fresh answer when the operator clicks Approve. Only a
    # question: the answer is discarded here and the gate (green_ci!) asks again and refuses anything but green. A card
    # that left the gate is no longer asked. → [[card_id, state | "no PR" | "unavailable: <why>", gate event], …]
    def approval_prefetch_pass
      return [] unless @config.green_ci_gate?

      boards = boards_for(cards.where(archived_at: nil).distinct.select_map(:project_slug))
      gates = boards.values.flat_map { |b| b.approvals.map(&:from) }.uniq
      return [] if gates.empty?

      cards.where(archived_at: nil, column: gates).order(:id).all.filter_map do |c|
        prefetch_approval(c, boards[c[:project_slug]])
      end
    end

    # ── approvable now (approval.requires_green_ci): a gate card waits for the OPERATOR only while its Approve would pass
    #
    # The operator, card #248: "Tickets waiting to approve that can't be approved due to things like CI etc. should not
    # be here!!" A card in a gate an approval step leaves from HOLDS (→ the reason) while that step's checks are not
    # green, cannot be read, or its PR has moved on from the head the handoff saw (new commits nobody reviewed); a hold
    # is "waiting for CI", not "waiting for you": the waiting counts, waiting_cards and card JSON's `gate_hold` say so.
    # nil = approvable now, or not such a gate, or no green-CI gate on this host.
    # Reads (board, waiting list, sidebar) take the watch pass's last view (gate_state, refreshed every notifier watch
    # pass; "ready" from the handoff's green answer) — only a card with none recorded yet is asked live. The operator's
    # Approve always asks live (green_ci!).
    def gate_hold(c, b)
      return nil unless @config.green_ci_gate?

      b.approval_from(c[:column]) or return nil
      return nil if c[:gate_state] == "ready"
      return c[:gate_state] if c[:gate_state]

      live_hold(c, b)
    end

    def live_hold(c, b)
      step = b.approval_from(c[:column])
      hold_from(c, @ci.approval_checks(c, step.to_h))
    rescue Delivery::Unavailable => e
      "CI state unknown — #{e.message}"
    end

    # the hold an approval_checks answer means for card c (nil = approvable now)
    def hold_from(c, pr)
      return "no PR whose checks could be read" if pr.nil?
      return hold_reason(pr) unless pr[:state] == "success"

      head = c[:gate_head]
      return nil unless head && pr[:head] && pr[:head] != head

      "new commits since the handoff (#{head[0, 7]} → #{pr[:head][0, 7]}): the reviewer has not seen them"
    end

    # {card id => hold} for the given rows (only the held ones)
    def gate_holds(rows, boards)
      return {} unless @config.green_ci_gate?

      rows.each_with_object({}) do |c, acc|
        why = gate_hold(c, boards[c[:project_slug]])
        acc[c[:id]] = why if why
      end
    end

    def hold_reason(pr)
      return pr[:reason] if pr[:reason]

      ref = pr[:number] ? "PR ##{pr[:number]}" : "its PR"
      case pr[:state]
      when "failure" then "#{ref}: CI failed"
      when "pending" then "#{ref}: CI is still running"
      when "unpolled" then "#{ref}: CI not read yet"
      when "nochecks" then "#{ref}: no CI checks ran"
      else "#{ref}: CI state #{pr[:state]}"
      end
    end

    # {slug => n}: per project, the cards waiting for the operator — those in the waiting columns that ask or hold
    # nothing (gate_hold), plus the ones asking elsewhere. `held` = {slug => n} of gate cards waiting for CI, `external` =
    # {slug => n} of cards only blocked_external (external?), in any column.
    WaitingCounts = Struct.new(:waiting, :held, :external)

    def waiting_counts(slugs, boards: nil)
      rows = cards.where(archived_at: nil, project_slug: slugs.to_a).all
      boards ||= boards_for(rows.map { |r| r[:project_slug] }.uniq)
      gated = rows.select { |r| boards[r[:project_slug]].waiting.include?(r[:column]) }
      holds = gate_holds(gated.reject { |r| flagged?(r) }, boards)
      waiting = Hash.new(0)
      held = Hash.new(0)
      external = Hash.new(0)
      rows.each do |r|
        if waits_for_operator?(r, boards[r[:project_slug]], holds[r[:id]])
          waiting[r[:project_slug]] += 1
        elsif external?(r)
          external[r[:project_slug]] += 1
        elsif holds.key?(r[:id])
          held[r[:project_slug]] += 1
        end
      end
      WaitingCounts.new(waiting, held, external)
    end

    # ── idle watch (config.idle_watch): CI finished and nobody acted; a live owner gone quiet ─────────────────────
    #
    # ci: the host's port — pr_checks(card) → nil (the card has no PR) | {number:, state: "success"|"failure"|"pending"|…,
    # finished_at: epoch|nil} and last_commit_at(card) → epoch|nil. It raises Delivery::Unavailable when it cannot say
    # (no stand-in answer is ever made up). "Activity" = any card_activity entry NOT signed by system_author (comments,
    # moves, edits by the owner or the operator); the engine's own pings / comments never count as the owner acting.
    # → [[card_id, :ci_ping | :ci_comment | :idle_comment], …] what this pass did.
    def idle_watch_pass(live:, ci:)
      w = @config.idle_watch or return []
      now = @clock.call
      sys = @config.system_author
      done = []
      rows = cards.where(archived_at: nil).all
      boards = boards_for(rows.map { |c| c[:project_slug] }.uniq)
      rows.select { |c| c[:column] == boards[c[:project_slug]].idle_column }.each do |c|
        c = c.merge(column_label: boards[c[:project_slug]].label(c[:column]))
        last = last_activity_at(c[:id]) || c[:created_at]
        begin
          pr = ci.pr_checks(c)
        rescue Delivery::Unavailable, Delivery::Refused => e
          # one card's PR the port cannot answer (e.g. a bad assignment) skips that card, said — never the others'
          done << [c[:id], "CI skipped: #{e.message}"]
          pr = nil
        end
        if pr && %w[success failure].include?(pr[:state]) && pr[:finished_at]
          done.concat(ci_step(c, pr, last, w, now, sys))
        end
        done.concat(idle_step(c, last, w, now, sys, live, ci))
      end
      done
    end

    def last_activity_at(card_id) = activity_t.where(card_id: card_id).exclude(author: @config.system_author).max(:created_at)

    def ci_step(c, pr, last, w, now, sys)
      return [] if last > pr[:finished_at] # the owner (or the operator) acted after the checks finished

      done = []
      row = watches_t.where(card_id: c[:id], kind: "ci", ref: pr[:finished_at]).first
      if row.nil? && now - pr[:finished_at] >= w.ci_ping_after_minutes * 60
        @db.transaction do
          watches_t.insert(card_id: c[:id], kind: "ci", ref: pr[:finished_at], pr: pr[:number], state: pr[:state],
                           pinged_at: now, created_at: now)
          if c[:owner_session]
            text = "CI on PR ##{pr[:number]} finished (#{pr[:state]}) — hand off or fix " \
                   "(card ##{c[:id]} \"#{c[:title]}\", #{c[:column_label]}, no activity for #{w.ci_ping_after_minutes} min)."
            enqueue_ping(c, "ci_idle", sys, text)
          end
          log(c[:id], "ci_idle", "CI on PR ##{pr[:number]} finished (#{pr[:state]}); " \
                                 "no activity for #{w.ci_ping_after_minutes} min — " \
                                 "#{c[:owner_session] ? "pinged #{c[:owner_session]}" : 'no owner session to ping'}", sys)
        end
        done << [c[:id], :ci_ping]
      elsif row && row[:commented_at].nil? && now - row[:pinged_at] >= w.ci_comment_after_minutes * 60
        @db.transaction do
          watches_t.where(id: row[:id]).update(commented_at: now)
          touch(c[:id])
          mins_ago = (now - pr[:finished_at]) / 60
          owner_note = c[:owner_session] ? "owner #{c[:owner_session]} was pinged" : 'no owner session'
          log(c[:id], "comment", "CI on PR ##{pr[:number]} finished (#{row[:state]}) " \
                                 "#{mins_ago} min ago and the card is still #{c[:column_label]} " \
                                 "with no activity (#{owner_note}). Hand off or fix.", sys)
        end
        done << [c[:id], :ci_comment]
      end
      done
    end

    def idle_step(c, last, w, now, sys, live, ci)
      return [] unless c[:owner_session] && live.include?(c[:owner_session])
      return [] if now - last < w.owner_idle_hours * 3600
      return [] if watches_t.where(card_id: c[:id], kind: "idle", ref: last).any?

      commit = ci.last_commit_at(c)
      return [] if commit && now - commit < w.owner_idle_hours * 3600

      @db.transaction do
        watches_t.insert(card_id: c[:id], kind: "idle", ref: last, commented_at: now, created_at: now)
        touch(c[:id])
        log(c[:id], "comment", "Owner #{c[:owner_session]} is alive but #{c[:column_label]} card ##{c[:id]} " \
                               "has had no activity for #{(now - last) / 3600} h " \
                               "and #{commit ? "no commit for #{(now - commit) / 3600} h" : 'no commit on its branch'}.", sys)
      end
      [[c[:id], :idle_comment]]
    end

    # ── comment edit / delete ─────────────────────────────────────────────────────────────────────

    def who!(v)
      w = v.to_s.strip
      raise Invalid, "author is required" if w.empty?

      w
    end

    def comment!(comment_id)
      e = activity_t.where(id: Integer(comment_id, exception: false) || -1, kind: "comment").first
      e || raise(Invalid, "no comment #{comment_id}")
    end

    # Only the author edits their comment; it keeps an edited_at mark.
    def comment_edit(comment_id, body:, by:)
      e = own_comment!(comment_id, by)
      raise Invalid, "body is required" if body.to_s.strip.empty?
      return e if body.to_s == e[:body]

      @db.transaction do
        activity_t.where(id: e[:id]).update(body: body.to_s, edited_at: @clock.call)
        touch(e[:card_id])
      end
      comment!(e[:id])
    end

    # Only the author deletes their comment; the deletion stays in the history (kind "delete").
    def comment_delete(comment_id, by:)
      e = own_comment!(comment_id, by)
      @db.transaction do
        activity_t.where(id: e[:id]).delete
        attachments_t.where(activity_id: e[:id]).update(activity_id: nil) # the files stay on the card
        touch(e[:card_id])
        log(e[:card_id], "delete", "deleted a comment from #{Time.at(e[:created_at]).strftime('%Y-%m-%d %H:%M')}", e[:author])
      end
      e[:card_id]
    end

    # Comments and history, oldest first.
    def activity(id) = activity_t.where(card_id: Integer(id)).order(:created_at, :id).all

    # Everyone who has touched this board: activity authors, assignees, card creators (members / assignee candidates).
    def members(slug)
      ids = cards.where(project_slug: slug).select(:id)
      (activity_t.where(card_id: ids).distinct.select_map(:author) +
        cards.where(project_slug: slug).exclude(assignee: nil).distinct.select_map(:assignee) +
        cards.where(project_slug: slug).distinct.select_map(:created_by)).uniq.sort
    end

    # ── labels (the board's set) ─────────────────────────────────────────────────────────────────

    def labels(slug) = labels_t.where(project_slug: slug).order(:id).all
    def label!(id) = labels_t.where(id: Integer(id, exception: false) || -1).first || raise(Invalid, "no label #{id}")

    def label_by_name!(slug, name)
      labels_t.where(project_slug: slug, name: name.to_s.strip).first || raise(Invalid, "no label #{name.inspect} on #{slug}")
    end

    def label_create(slug, name:, color:)
      board!(slug)
      n = label_name!(name)
      raise Invalid, "label #{n.inspect} already exists on #{slug}" if labels_t.where(project_slug: slug, name: n).any?

      labels_t.insert(project_slug: slug, name: n, color: color!(color), created_at: @clock.call)
    end

    # Rename and/or recolour. A rename rewrites every card of the board that carries it.
    def label_update(id, name: nil, color: nil)
      l = label!(id)
      set = {}
      set[:name] = label_name!(name) unless name.nil?
      set[:color] = color!(color) unless color.nil?
      if set[:name] && set[:name] != l[:name] && labels_t.where(project_slug: l[:project_slug], name: set[:name]).any?
        raise Invalid, "label #{set[:name].inspect} already exists on #{l[:project_slug]}"
      end

      @db.transaction do
        labels_t.where(id: l[:id]).update(set) unless set.empty?
        relabel(l[:project_slug]) { |ls| ls.map { |x| x == l[:name] ? set[:name] : x } } if set[:name] && set[:name] != l[:name]
      end
      label!(id)
    end

    # Removes the label from the set and from every card of the board.
    def label_delete(id)
      l = label!(id)
      @db.transaction do
        relabel(l[:project_slug]) { |ls| ls - [l[:name]] }
        labels_t.where(id: l[:id]).delete
      end
      l
    end

    # ── checklists ───────────────────────────────────────────────────────────────────────────────

    # [{id, title, position, items: [...]}] in order.
    def checklists(card_id)
      cls = checklists_t.where(card_id: Integer(card_id)).order(:position, :id).all
      items = items_t.where(checklist_id: cls.map { |c| c[:id] }).order(:position, :id).all.group_by { |i| i[:checklist_id] }
      cls.map { |c| c.merge(items: items[c[:id]] || []) }
    end

    def checklist!(id)
      checklists_t.where(id: Integer(id, exception: false) || -1).first || raise(Invalid, "no checklist #{id}")
    end
    def item!(id) = items_t.where(id: Integer(id, exception: false) || -1).first || raise(Invalid, "no checklist item #{id}")

    # → checklist id. items: optional initial item bodies (markdown).
    def checklist_add(card_id, title:, by:, items: [])
      c = card!(card_id)
      t = checklist_title!(title)
      raise Invalid, "items must be an array of strings" unless items.is_a?(Array) && items.all? { |i| i.is_a?(String) }

      bodies = items.map { |i| item_body!(i) }
      by = who!(by)
      @db.transaction do
        id = checklists_t.insert(card_id: c[:id], title: t, position: checklists_t.where(card_id: c[:id]).count,
                                 created_at: @clock.call)
        bodies.each_with_index { |b, i| items_t.insert(checklist_id: id, body: b, position: i, created_at: @clock.call) }
        touch(c[:id])
        log(c[:id], "checklist", "added checklist “#{t}”", by)
        id
      end
    end

    def checklist_rename(id, title:, by:)
      cl = checklist!(id)
      t = checklist_title!(title)
      by = who!(by)
      return cl if t == cl[:title]

      @db.transaction do
        checklists_t.where(id: cl[:id]).update(title: t)
        touch(cl[:card_id])
        log(cl[:card_id], "checklist", "renamed checklist “#{cl[:title]}” → “#{t}”", by)
      end
      checklist!(id)
    end

    def checklist_delete(id, by:)
      cl = checklist!(id)
      by = who!(by)
      @db.transaction do
        checklists_t.where(id: cl[:id]).delete
        renumber_rows(checklists_t, checklists_t.where(card_id: cl[:card_id]))
        touch(cl[:card_id])
        log(cl[:card_id], "checklist", "removed checklist “#{cl[:title]}”", by)
      end
      cl
    end

    # → item id (appended).
    def item_add(checklist_id, body:, by:)
      cl = checklist!(checklist_id)
      b = item_body!(body)
      who!(by)
      @db.transaction do
        id = items_t.insert(checklist_id: cl[:id], body: b, position: items_t.where(checklist_id: cl[:id]).count,
                            created_at: @clock.call)
        touch(cl[:card_id])
        id
      end
    end

    # body: new markdown; done: true/false (a toggle is logged with who did it).
    def item_update(item_id, by:, body: nil, done: nil)
      i = item!(item_id)
      cl = checklist!(i[:checklist_id])
      by = who!(by)
      set = {}
      set[:body] = item_body!(body) unless body.nil?
      unless done.nil?
        d = bool!(done, "done")
        set.merge!(done: d ? 1 : 0, done_by: d ? by : nil, done_at: d ? @clock.call : nil) if d != (i[:done] == 1)
      end
      return i if set.empty? || set == { body: i[:body] }

      @db.transaction do
        items_t.where(id: i[:id]).update(set)
        touch(cl[:card_id])
        if set.key?(:done)
          log(cl[:card_id], "checklist", "#{set[:done] == 1 ? 'completed' : 'unchecked'} “#{i[:body]}” in #{cl[:title]}", by)
        end
      end
      item!(item_id)
    end

    def item_delete(item_id, by:)
      i = item!(item_id)
      cl = checklist!(i[:checklist_id])
      who!(by)
      @db.transaction do
        items_t.where(id: i[:id]).delete
        renumber_rows(items_t, items_t.where(checklist_id: cl[:id]))
        touch(cl[:card_id])
      end
      i
    end

    # The item becomes a card at the bottom of the parent card's column (title = the item, or its first MAX_TITLE
    # chars with the whole item as the description); the item is removed. Logged on both cards. → new card id.
    def item_convert(item_id, by:, agent: false)
      i = item!(item_id)
      cl = checklist!(i[:checklist_id])
      parent = card!(cl[:card_id])
      by = who!(by)
      b = board_of(parent[:project_slug])
      if agent && b.no_create_for_agents.include?(parent[:column])
        raise Denied, "agents cannot create cards in #{b.label(parent[:column])}"
      end

      plain = i[:body].gsub(/\s+/, " ").strip
      title, notes = plain.length <= MAX_TITLE ? [plain, ""] : ["#{plain[0, MAX_TITLE - 1].rstrip}…", i[:body]]
      @db.transaction do
        id = create(slug: parent[:project_slug], title: title, notes: notes, column: parent[:column], by: by, agent: agent)
        log(id, "checklist", "converted from checklist item on ##{parent[:id]} (#{cl[:title]})", by)
        items_t.where(id: i[:id]).delete
        renumber_rows(items_t, items_t.where(checklist_id: cl[:id]))
        touch(parent[:id])
        log(parent[:id], "checklist", "converted “#{i[:body]}” to card ##{id}", by)
        id
      end
    end

    private

    def live(slug) = cards.where(project_slug: slug, archived_at: nil)

    def board!(slug)
      raise Invalid, "no board #{slug}" unless slug.is_a?(String) && !slug.empty? && @boards.call(slug)
    end

    # Every rule a column change must pass, in order: the agent gates, the workflow, the parent dependency. One place —
    # move runs it, and ask / handoff run it BEFORE they write their fields (so a refusal leaves nothing behind).
    def move_check!(b, c, column, agent:, handoff: false, withdraw: false)
      return if column == c[:column]

      agent_move!(b, c, column, handoff: handoff) if agent
      workflow_check!(b, c, column, agent) unless withdraw
      blocked!(b, column, c[:blocked_by], "card ##{c[:id]}")
    end

    # The workflow's rule for a column change: an edge column → column the actor may take, else refused with the edges
    # there are.
    def workflow_check!(b, c, column, agent)
      wf = b.workflow
      return if wf.edge(from: c[:column], to: column, actor: actor_of(agent))

      out = wf.from(c[:column], actor: actor_of(agent)).map { |e| "#{e.name} → #{b.label(e.to)}" }
      raise Denied, "workflow: no transition #{b.label(c[:column])} → #{b.label(column)} for #{actor_label(agent)}. " \
                    "Allowed from #{b.label(c[:column])}: " \
                    "#{out.empty? ? "none — #{actor_label(agent)} cannot move it from here" : out.join(', ')}"
    end

    # A transition NAME (+ the column, for a fan-out "*" edge) → its target column; a name that does not lead there, or
    # is not an edge out of the card's column for the actor, is refused with the names there are.
    def transition_target!(b, c, column, name, agent)
      wf = b.workflow
      to = column.to_s.empty? ? nil : column.to_s
      e = wf.named(from: c[:column], name: name, actor: actor_of(agent), to: to)
      unless e
        out = wf.from(c[:column], actor: actor_of(agent)).map(&:name).uniq
        raise Denied, "workflow: no transition #{name.to_s.inspect}#{to ? " to #{b.label(to)}" : ''} " \
                      "from #{b.label(c[:column])} " \
                      "for #{actor_label(agent)} (#{out.empty? ? 'none' : out.join(', ')})"
      end
      raise Invalid, "transition #{e.name.inspect} goes to any column: give the column too" if e.fan_out && to.nil?

      e.to
    end

    def actor_of(agent) = agent ? :agent : :operator
    def actor_label(agent) = agent ? "an agent" : "the operator"

    # The agent rules for a column change: a flagged card stays; a gate is entered with kanban_handoff only; the
    # approval is the operator's; a gate is left only along a named agent transition, once approved; the operator's
    # columns are otherwise closed; the review loop ends at its round limit.
    def agent_move!(cfg, c, column, handoff:)
      if c[:asked_at]
        raise Denied, "card ##{c[:id]} waits for the operator's answer (needs_operator) — it stays in " \
                      "#{cfg.label(c[:column])} until the operator comments"
      end
      if c[:blocked_at]
        raise Denied, "card ##{c[:id]} is blocked (external): #{c[:blocked_reason]} — kanban_unblock it first"
      end

      step = cfg.approval_for(c[:column], column)
      if step
        raise Denied, "only the operator moves a card #{cfg.label(step.from)} → #{cfg.label(step.to)} (that is the approval)"
      end
      if cfg.gate?(column) && !handoff
        raise Denied, "agents hand a card to #{cfg.label(column)} with kanban_handoff " \
                      "(how to check it, PR, CI build, screenshots for UI changes) — not kanban_move"
      end
      # out of a gate: along a transition the board names for agents (not the catch-all "*"), approved
      if cfg.gate?(c[:column])
        e = cfg.workflow.edge(from: c[:column], to: column, actor: :agent)
        raise Denied, "only the operator moves a card out of #{cfg.label(c[:column])}" unless e && !e.fan_out
        unless c[:approved_at]
          into = cfg.approval_into(c[:column])
          how = if into
                  " (approval = the operator's move #{cfg.label(into.from)} → #{cfg.label(into.to)}, or the " \
                    "operator's Approve on the card in #{cfg.label(into.to)})"
                else
                  ""
                end
          raise Denied, "card ##{c[:id]} sits in #{cfg.label(c[:column])} without the operator's approval#{how} " \
                        "— agents never skip it; kanban_ask the operator"
        end
        return if cfg.done?(column)
      elsif cfg.operator_only.include?(c[:column])
        raise Denied, "only the operator moves a card out of #{cfg.label(c[:column])}"
      end
      if cfg.done?(column) && cfg.agent_closed?(column)
        from = cfg.gate_columns.map { |k| cfg.label(k) }.join(" / ")
        raise Denied, "only an approved card in #{from} can be moved to #{cfg.label(column)}; agents stop at the gate"
      end
      raise Denied, "only the operator moves a card into #{cfg.label(column)}" if cfg.agent_closed?(column) && !handoff
      round_limit!(cfg, c, column)
    end

    # ── the review loop (config.review_loop): rounds per review column, the limit, the unresolved label ──

    def review_rounds(c) = c[:review_rounds] ? JSON.parse(c[:review_rounds]) : {}

    # A loop column: a review column the review loop runs in (review_loop.columns; no review_loop = every review column
    # counts rounds, none is limited).
    def loop_column?(b, key)
      lp = @config.review_loop
      b.review?(key) && (lp.nil? || lp.columns.include?(key))
    end

    # The loop column that sends cards to the work column `w` by a named agent edge (Comments posted → Author response).
    def loop_feeding(b, w) = b.review_columns.find { |k| loop_column?(b, k) && b.agent_targets(k).include?(w) }

    # The rounds after a move: entering a loop column from a work column or a gate counts a round for it; the operator
    # sending a card back into a loop's work column — from a gate (Changes requested), or from the loop column itself
    # once its rounds are used up (a drag: no gate is reachable from the work column, so the limit would leave the
    # author no move at all) — allows exactly ONE more round of that loop (REREVIEW: {loop column => its rounds at that
    # moment}); entering a work column by any other move than a review column's own agent edge into it (Rework from a
    # review column or a gate, Deploy failed, Start work) starts over.
    def review_rounds_after(b, c, column, agent)
      r = review_rounds(c)
      from = c[:column]
      feed = b.working?(column) ? loop_feeding(b, column) : nil
      if loop_column?(b, column) && (b.working?(from) || b.gate?(from))
        r.merge(column => (r[column] || 0) + 1)
      elsif feed && (b.gate?(from) || (!agent && from == feed && rounds_used_up?(c, feed)))
        r.merge(REREVIEW => { feed => r[feed] || 0 })
      elsif b.working?(column) && !b.working?(from) && !(b.review?(from) && b.agent_targets(from).include?(column))
        {} # Rework / Deploy failed / Start work: not a review column's own edge back to its work column
      else
        r
      end
    end

    # Has the loop column used up its rounds (round_limit! would refuse the agents' next loop move)?
    def rounds_used_up?(c, review) = !@config.review_loop.nil? && (review_rounds(c)[review] || 0) >= round_cap(c, review)

    # How many rounds the loop column may reach: one more than at the operator's Changes requested, else max_rounds.
    def round_cap(c, review)
      rr = review_rounds(c)[REREVIEW]
      rr&.key?(review) ? rr[review] + 1 : @config.review_loop.max_rounds
    end

    # The round limit (review_loop.max_rounds) ends the loop: at the limit an agent neither sends the card back to a
    # work column from the review column nor into it again — it hands the card to the gate (kanban_handoff).
    def round_limit!(b, c, column)
      lp = @config.review_loop or return
      review = if loop_column?(b, column) && b.working?(c[:column]) then column
               elsif loop_column?(b, c[:column]) && b.working?(column) then c[:column]
               end
      return unless review

      n = review_rounds(c)[review] || 0
      cap = round_cap(c, review)
      return if n < cap

      gates = b.handoff_targets(review).map { |k| b.label(k) }
      to = gates.empty? ? "the gate" : gates.join(" / ")
      if review_rounds(c)[REREVIEW]&.key?(review)
        raise Denied, "the one re-round after the operator's Changes requested is done (#{b.label(review)}, round " \
                      "#{n}): the loop ends here — kanban_handoff the card back to #{to}"
      end

      raise Denied, "review round limit reached (#{n}/#{lp.max_rounds} in #{b.label(review)}): the loop ends here — " \
                    "kanban_handoff the card to #{to} with review_summary (it carries the label " \
                    "#{lp.unresolved_label.inspect} when needs_human + open > 0)"
    end

    # At the round limit of a loop the operator did not reopen (Changes requested): the handoff carries the label.
    def loop_exhausted?(b, c)
      lp = @config.review_loop or return false
      return false unless loop_column?(b, c[:column])
      return false if review_rounds(c)[REREVIEW]&.key?(c[:column])

      (review_rounds(c)[c[:column]] || 0) >= lp.max_rounds
    end

    # The reviewer's SUMMARY counts (review_loop): {fixed, resolved_by_argument, needs_human, open} — integers >= 0,
    # every key, no other. Required at the round limit; the unresolved label goes on only when needs_human + open is
    # above 0 (card #248: 7 fixed, 0 open, still labelled). Elsewhere optional (named in the handoff line when given).
    SUMMARY_KEYS = %w[fixed resolved_by_argument needs_human open].freeze

    def review_summary!(b, c, summary, exhausted)
      if summary.nil?
        return nil unless exhausted

        raise Invalid, "review_summary is required at the review round limit " \
                       "(#{review_rounds(c)[c[:column]]}/#{@config.review_loop.max_rounds} in #{b.label(c[:column])}): " \
                       "the reviewer's SUMMARY counts {#{SUMMARY_KEYS.join(', ')}}"
      end
      raise Invalid, "review_summary must be an object {#{SUMMARY_KEYS.join(', ')}}" unless summary.is_a?(Hash)

      h = summary.transform_keys(&:to_s)
      unless h.keys.sort == SUMMARY_KEYS.sort
        raise Invalid, "review_summary must have exactly #{SUMMARY_KEYS.join(', ')} (got #{h.keys.join(', ')})"
      end
      h.each do |k, v|
        raise Invalid, "review_summary.#{k} must be an integer >= 0 (got #{v.inspect})" unless v.is_a?(Integer) && v >= 0
      end
      h
    end

    def summary_note(h)
      "review: fixed #{h['fixed']} · resolved-by-argument #{h['resolved_by_argument']} · needs_human " \
        "#{h['needs_human']} · open #{h['open']}"
    end

    # The host's unresolved label on the card (created on the board when missing), logged.
    def unresolved_label!(c, by, unresolved)
      lp = @config.review_loop
      name = lp.unresolved_label
      unless labels_t.where(project_slug: c[:project_slug], name: name).any?
        labels_t.insert(project_slug: c[:project_slug], name: name, color: lp.unresolved_color, created_at: @clock.call)
      end
      have = JSON.parse(c[:labels].is_a?(String) ? c[:labels] : JSON.generate(c[:labels]))
      return if have.include?(name)

      cards.where(id: c[:id]).update(labels: JSON.generate(have + [name]))
      log(c[:id], "update", "labels: #{(have + [name]).join(', ')} (review rounds exhausted: #{lp.max_rounds}; " \
                            "#{unresolved} thread#{'s' if unresolved > 1} needs_human / open)", by)
    end

    # The gate a handoff goes to: the named one, else the ONE gate the card's column has an agent transition into.
    def handoff_target!(b, c, transition, column)
      name = transition.to_s.strip
      col = column.to_s.strip
      return transition_target!(b, c, col.empty? ? nil : col, name, true) unless name.empty?
      return column!(b, col) unless col.empty?

      targets = b.handoff_targets(c[:column])
      return targets.first if targets.size == 1

      gates = b.gate_columns.map { |k| "#{b.label(k)} (#{k})" }.join(", ")
      if targets.empty?
        raise Denied, "no transition from #{b.label(c[:column])} into a gate for an agent — the board's gates: #{gates}; " \
                      "agents hand off along a named agent transition"
      end

      raise Invalid, "#{b.label(c[:column])} hands off to #{targets.map { |k| b.label(k) }.join(' or ')}: give transition " \
                     "(the name) or column"
    end

    # A card that reaches a terminal column (Done, Cancelled) waits for nobody: its open flags are cleared and logged.
    def clear_flags_at_end(c, b, column, by)
      gone = []
      gone << "needs_operator" if c[:asked_at]
      gone << "blocked_external" if c[:blocked_at]
      return if gone.empty?

      cards.where(id: c[:id]).update(dialog_id: nil, question: nil, question_options: nil, asked_at: nil, asked_by: nil,
                                     blocked_at: nil, blocked_author: nil, blocked_reason: nil, blocked_url: nil,
                                     flag_reminded_at: nil)
      log(c[:id], "flag", "#{gone.join(' + ')} cleared — the card is in #{b.label(column)}", by)
    end

    # A question answered or expired: the needs_operator flag and its question are cleared (the activity keeps them).
    def clear_question(card_id)
      cards.where(id: card_id).update(dialog_id: nil, question: nil, question_options: nil, asked_at: nil, asked_by: nil,
                                      flag_reminded_at: nil, updated_at: @clock.call)
    end

    # The question's first non-blank line as plain text, ≤ 160 chars (the reminder, the waiting list).
    def first_line(md)
      line = md.to_s.lines.map(&:strip).find { |l| !l.empty? } or return nil
      t = line.gsub(/\*+|__|`/, "").sub(/\A#+\s*/, "").strip
      t.length > 160 ? "#{t[0, 159]}…" : t
    end

    # The transitions out of `column` on board b, for the card JSON and the clients: [{name, to, to_label, by}].
    def transitions_json(b, column)
      b.workflow.from(column).map { |e| { name: e.name, to: e.to, to_label: b.label(e.to), by: e.by } }
    end

    # One card's approval step asked of the ci: port (approval_prefetch_pass) → [id, what it said] | nil (no step here).
    # One gate card's step asked of the ci: port (approval_prefetch_pass) → [id, what it said, gate event] | nil (no
    # step here). The gate event is said once per change, the last state kept on the card (gate_state):
    # :red = its CI turned red (the owner is pinged to fix it), :ready = a hold cleared (it now waits for the operator).
    def prefetch_approval(c, b)
      return nil unless @config.green_ci_gate? && !c[:archived_at]

      step = b.approval_from(c[:column]) or return nil
      begin
        pr = @ci.approval_checks(c, step.to_h)
      rescue Delivery::Unavailable => e
        return [c[:id], "unavailable: #{e.message}", gate_event(c, b, "CI state unknown — #{e.message}", red: nil)]
      end
      red = pr&.dig(:state) == "failure" ? (pr[:finished_at] || 0) : nil
      [c[:id], pr ? pr[:state] : "no PR", gate_event(c, b, hold_from(c, pr), red: red)]
    end

    # → :red (pinged the owner) | :red_nobody (no owner session to ping) | :ready | nil. red: the finish time of a
    # "failure" answer (whatever the host's words for it — a reason: on a red merge CI too), nil when not red: ONE ping
    # per CI completion (ci_watches kind "gate_red", ref = that time).
    def gate_event(c, b, why, red:)
      now = why || "ready"
      new_red = !red.nil? && watches_t.where(card_id: c[:id], kind: "gate_red", ref: red).empty? # a red completion not told
      return nil if now == c[:gate_state] && !new_red

      sys = @config.system_author
      was = c[:gate_state]
      @db.transaction do
        cards.where(id: c[:id]).update(gate_state: now)
        if why.nil?
          next nil unless was # the first look at a card nobody recorded: nothing changed for anyone

          log(c[:id], "gate", "ready for your approval: #{b.label(c[:column])}, CI green (was: #{was})", sys)
          next :ready
        end
        next nil unless new_red

        owner = c[:owner_session]
        watches_t.insert(card_id: c[:id], kind: "gate_red", ref: red, state: "failure", pinged_at: owner && @clock.call,
                         created_at: @clock.call)
        text = "#{why} while card ##{c[:id]} \"#{c[:title]}\" waits in #{b.label(c[:column])} — fix it; it is not " \
               "counted as waiting for the operator until CI is green again."
        enqueue_ping(c.merge(column_label: b.label(c[:column])), "gate_red", sys, text) if owner
        log(c[:id], "gate", "waiting for CI: #{why} — #{owner ? "pinged #{owner}" : 'no owner session to ping'}", sys)
        owner ? :red : :red_nobody
      end
    end

    # The approval gate (host config approval.requires_green_ci): the card's PR checks must be green — asked of the
    # host's ci: port for this step (the host picks the PR: e.g. the local PR at the local step, the public PR at the
    # final one). No PR, not finished, failed, not read yet or the port unreachable → refused with what it saw. An
    # answer's `reason:` is the host's own refusal (e.g. a prerequisite PR not merged), said in place of the CI wording.
    def green_ci!(c, b, step, handoff: false)
      return unless @config.green_ci_gate?

      what = handoff ? "not handed off (→ #{b.label(step.from)})" : "not approved (#{b.label(step.from)} → #{b.label(step.to)})"
      again = handoff ? "hand off again in a minute" : "approve again in a minute"
      wait = handoff ? "hand off once CI is green" : "approval waits for green CI"
      # the operator is never stuck behind the gate: a drag along the step approves without asking (Store#move)
      drag = !handoff && c[:column] == step.from ? ". A drag into #{b.label(step.to)} approves without asking CI" : ""
      begin
        pr = @ci.approval_checks(c, step.to_h)
      rescue Delivery::Unavailable => e
        raise Invalid, "#{what}: CI state of card ##{c[:id]} is unknown — #{e.message}#{drag}"
      end
      raise Invalid, "#{what}: card ##{c[:id]} has no PR whose checks could be read#{drag}" if pr.nil?
      if pr[:state] == "success"
        moved = !handoff && hold_from(c, pr) # approving: the PR must still be at the head the handoff saw
        raise Invalid, "#{what}: card ##{c[:id]} — #{moved}; hand it back for review#{drag}" if moved

        return pr
      end

      ref = pr[:number] ? "PR ##{pr[:number]}" : "its PR"
      raise Invalid, "#{what}: card ##{c[:id]} — #{pr[:reason]}#{handoff ? "; #{wait}" : ''}#{drag}" if pr[:reason]

      why = case pr[:state]
            when "failure" then "CI failed"
            when "pending" then "CI is still running"
            when "unpolled" then "CI not read yet (asked now — #{again})"
            when "nochecks" then "no CI checks ran"
            else "CI state #{pr[:state]}"
            end
      raise Invalid, "#{what}: #{ref} of card ##{c[:id]} — #{why}; #{wait}#{drag}"
    end

    # The activity line of an approval: the approve gate's wording as before; a step names where its agent goes next.
    def approval_note(b, step)
      return "approved for merge — the agent merges and moves it to #{b.label(step.then)}" if step.final

      onward = step.then ? " and moves it to #{b.label(step.then)}" : ""
      "approved #{b.label(step.from)} → #{b.label(step.to)} — the agent carries on#{onward}"
    end

    # The dependency rule: `column` (nil = a claim) is refused while any parent is unfinished.
    def blocked!(b, column, unfinished_ids, what, claim: false)
      deps = b.dependencies
      return if !deps || unfinished_ids.nil? || unfinished_ids.empty?
      return unless claim || deps.blocked.include?(column)

      verb = claim ? "cannot be claimed" : "cannot enter #{b.label(column)}"
      never = never_finishing(unfinished_ids)
      dead = never.empty? ? "" : "; #{never.join(', ')} and never finish#{'es' if never.size == 1}"
      out = never.empty? ? "" : " — clear the card's parent to end the wait"
      raise Invalid, "#{what} #{verb} while it waits for " \
                     "card#{'s' if unfinished_ids.size > 1} ##{unfinished_ids.join(', #')} " \
                     "(not yet in #{deps.done.map { |k| b.label(k) }.join(' / ')}#{dead})#{out}"
    end

    # The unfinished parents that will never finish as they are — archived, or in a terminal column that finishes
    # nothing (Cancelled) — each as "#id is archived" / "#id is in <column>": the refusal names the way out.
    def never_finishing(ids)
      ps = cards.where(id: ids).order(:id).all
      boards = boards_for(ps.map { |p| p[:project_slug] }.uniq)
      ps.filter_map do |p|
        pb = boards[p[:project_slug]]
        if p[:archived_at] then "##{p[:id]} is archived"
        elsif pb.terminal?(p[:column]) then "##{p[:id]} is in #{pb.label(p[:column])}"
        end
      end
    end

    # A parent just finished: its children that still sit in a promote.from column move to promote.to (bottom), logged
    # by the system.
    def promote_children(parent_id, by)
      parent = cards.where(id: parent_id).first or return
      b = board_of(parent[:project_slug])
      pr = b.dependencies&.promote or return
      cards.where(parent_id: parent_id, archived_at: nil, column: pr.from).order(:position, :id).all.each do |ch|
        next if unfinished([ch[:parent_id]]).any? # (a child may wait for a parent that is now archived)

        from = ch[:column]
        place(ch, pr.to, nil)
        log(ch[:id], "move", "#{b.label(from)} → #{b.label(pr.to)} (parent ##{parent_id} done, by #{by})",
            @config.system_author)
      end
    end

    # Put card c in column at pos (nil = bottom); renumbers the target and (when it changed) the source column.
    def place(c, column, pos)
      ids = live(c[:project_slug]).where(column: column).exclude(id: c[:id]).order(:position, :id).select_map(:id)
      ids.insert([pos || ids.size, ids.size].min, c[:id])
      renumber(ids)
      cards.where(id: c[:id]).update(column: column, updated_at: @clock.call)
      renumber_column(c[:project_slug], c[:column]) if c[:column] != column
    end

    # nil / [] = a free answer; else 1..MAX_OPTIONS distinct non-empty strings.
    def options!(v)
      return nil if v.nil? || (v.is_a?(Array) && v.empty?)
      unless v.is_a?(Array) && v.all?(String)
        raise Invalid, "options must be an array of strings (the choices the operator clicks)"
      end

      list = v.map(&:strip)
      raise Invalid, "options: empty choice" if list.any?(&:empty?)
      raise Invalid, "options: at most #{MAX_OPTIONS}" if list.size > MAX_OPTIONS
      raise Invalid, "options: a choice is longer than #{MAX_OPTION}" if list.any? { |o| o.length > MAX_OPTION }
      raise Invalid, "options: duplicate choices" if list.uniq.size != list.size

      list
    end

    def touch(card_id) = cards.where(id: card_id).update(updated_at: @clock.call)

    def log(card_id, kind, body, author)
      activity_t.insert(card_id: card_id, kind: kind, body: body, author: author, created_at: @clock.call)
    end

    def own_comment!(comment_id, by)
      e = comment!(comment_id)
      by = who!(by)
      raise Denied, "only #{e[:author]} edits or deletes comment #{e[:id]} (you are #{by})" unless e[:author] == by

      e
    end

    def relabel(slug)
      cards.where(project_slug: slug).select(:id, :labels).all.each do |r|
        before = JSON.parse(r[:labels])
        after = yield(before).uniq
        cards.where(id: r[:id]).update(labels: JSON.generate(after)) if after != before
      end
    end

    def describe(key, value)
      case key
      when :notes then "description edited"
      when :labels then "labels: #{value.empty? ? '—' : value.join(', ')}"
      when :due_at then "due: #{value ? Time.at(value).strftime('%Y-%m-%d %H:%M') : '—'}"
      when :due_done then value ? "due: done" : "due: not done"
      when :parent_id then value ? "parent: ##{value}" : "parent: —"
      when :metadata then "metadata edited"
      else "#{key}: #{value.nil? ? '—' : value}"
      end
    end

    def renumber(ids) = ids.each_with_index { |cid, i| cards.where(id: cid).update(position: i) }
    def renumber_column(slug, column) = renumber(live(slug).where(column: column).order(:position, :id).select_map(:id))
    def renumber_rows(table, ds)
      ds.order(:position, :id).select_map(:id).each_with_index { |rid, i| table.where(id: rid).update(position: i) }
    end

    # b: the card's board (loaded when not given). A card in a column its board no longer has is shown with its key as
    # the label — it is still a card; a save that removed the column with cards in it is refused, so this is history only.
    def hydrate(c, b = nil)
      b ||= board_of(c[:project_slug])
      c.merge(labels: JSON.parse(c[:labels]), column_label: b.column?(c[:column]) ? b.label(c[:column]) : c[:column],
              due_done: c[:due_done] == 1, metadata: c[:metadata] ? JSON.parse(c[:metadata]) : nil)
    end

    # :comments, :attachments, :checklist_done / :checklist_total, :dialog, :children, :blocked_by, :transitions for the
    # card face.
    def decorate(list, boards = nil)
      ids = list.map { |c| c[:id] }
      n = activity_t.where(card_id: ids, kind: "comment").group_and_count(:card_id).as_hash(:card_id, :count)
      files = attachments_t.where(card_id: ids, deleted_at: nil).group_and_count(:card_id).as_hash(:card_id, :count)
      dialogs = dialogs_t.where(id: list.map { |c| c[:dialog_id] }.compact, answered_at: nil).as_hash(:id)
      kids = cards.where(parent_id: ids, archived_at: nil).group_and_count(:parent_id).as_hash(:parent_id, :count)
      parents = list.map { |c| c[:parent_id] }.compact.uniq
      open = unfinished(parents)
      items = items_t.join(@tables[:checklists], id: :checklist_id).where(Sequel[@tables[:checklists]][:card_id] => ids)
                     .select(Sequel[@tables[:checklists]][:card_id], Sequel[@tables[:checklist_items]][:done])
                     .all
                     .group_by { |r| r[:card_id] }
      boards ||= boards_for(list.map { |c| c[:project_slug] }.uniq)
      holds = gate_holds(list, boards)
      list.each do |c|
        b = boards[c[:project_slug]]
        c[:gate_hold] = holds[c[:id]]
        c[:waiting] = waits_for_operator?(c, b, c[:gate_hold])
        c[:transitions] = b.column?(c[:column]) ? transitions_json(b, c[:column]) : []
        c[:comments] = n[c[:id]] || 0
        c[:attachments] = files[c[:id]] || 0
        its = items[c[:id]] || []
        c[:checklist_total] = its.size
        c[:checklist_done] = its.count { |r| r[:done] == 1 }
        c[:dialog] = dialog_json(dialogs[c[:dialog_id]])
        c[:children] = kids[c[:id]] || 0
        c[:blocked_by] = c[:parent_id] && open.include?(c[:parent_id]) ? [c[:parent_id]] : []
      end
    end

    # The open session dialog on a card face / JSON: what the operator may press (SessionDialog.keys) and what is shown only.
    def dialog_json(row)
      return nil unless row

      d = JSON.parse(row[:dialog])
      { id: row[:id], session: row[:session], keys: SessionDialog.keys(d), escape: d["escape"], free_text: d["free_text"],
        options: d["options"].map { |o| { key: o["key"], label: o["label"], free: o["free"] } }, posted: iso(row[:posted_at]), }
    end

    def column!(b, v)
      b.column?(v.to_s) ? v.to_s : raise(Invalid, "column must be one of #{b.keys.join(', ')} (got #{v.inspect})")
    end

    def title!(v)
      t = v.to_s.strip
      raise Invalid, "title is required" if t.empty?
      raise Invalid, "title is longer than #{MAX_TITLE}" if t.length > MAX_TITLE

      t
    end

    def checklist_title!(v)
      t = v.to_s.strip
      raise Invalid, "checklist title is required" if t.empty?
      raise Invalid, "checklist title is longer than #{MAX_TITLE}" if t.length > MAX_TITLE

      t
    end

    def item_body!(v)
      raise Invalid, "item body must be a string" unless v.is_a?(String)

      t = v.strip
      raise Invalid, "item body is required" if t.empty?
      raise Invalid, "item body is longer than #{MAX_ITEM}" if t.length > MAX_ITEM

      t
    end

    # Array of strings or a comma-separated string → stripped, de-duplicated, non-empty; each must be in the board's set.
    def labels!(v, slug)
      list = v.is_a?(Array) ? v : v.to_s.split(",")
      raise Invalid, "labels must be strings" unless list.all? { |l| l.is_a?(String) }

      list = list.map(&:strip).reject(&:empty?).uniq
      raise Invalid, "at most #{MAX_LABELS} labels" if list.size > MAX_LABELS

      known = labels_t.where(project_slug: slug).select_map(:name)
      unknown = list - known
      if unknown.any?
        raise Invalid, "unknown label#{'s' if unknown.size > 1} #{unknown.join(', ')} — " \
                       "#{slug} has #{known.empty? ? 'no labels' : known.join(', ')}; " \
                       "create one first (the board's labels endpoint or kanban_label_save)"
      end

      list
    end

    def label_name!(v)
      n = v.to_s.strip
      raise Invalid, "label name is required" if n.empty?
      raise Invalid, "a label is longer than #{MAX_LABEL}" if n.length > MAX_LABEL
      raise Invalid, "a label name cannot contain a comma" if n.include?(",")

      n
    end

    def color!(v, nullable: false)
      return nil if nullable && (v.nil? || v.to_s.empty?)

      cs = @config.label_colors
      return v.to_s if cs.include?(v.to_s)

      raise Invalid, "colour must be one of #{cs.join(', ')}#{' or empty' if nullable} (got #{v.inspect})"
    end

    # ISO 8601 "YYYY-MM-DDTHH:MM[:SS][Z|±HH:MM]" (no offset = the server's TZ), nil/"" clears.
    def due!(v)
      return nil if v.nil? || v.to_s.empty?

      m = v.to_s.match(DUE) or raise Invalid, "due must be ISO 8601 YYYY-MM-DDTHH:MM[:SS][offset] or empty (got #{v.inspect})"
      y, mo, d, h, mi, s = m.captures[0, 6].map(&:to_i)
      raise Invalid, "due #{v.inspect} is not a real date/time" unless Date.valid_date?(y, mo, d) && h < 24 && mi < 60 && s < 60

      zone = m[7] == "Z" ? "+00:00" : m[7]&.sub(/\A([+-]\d\d)(\d\d)\z/, '\1:\2')
      (zone ? Time.new(y, mo, d, h, mi, s, zone) : Time.new(y, mo, d, h, mi, s)).to_i
    end

    def bool!(v, key)
      v = { "true" => true, "false" => false, "1" => true, "0" => false }.fetch(v, v) if v.is_a?(String)
      [true, false].include?(v) ? v : raise(Invalid, "#{key} must be true or false (got #{v.inspect})")
    end

    def assignee!(v)
      a = v.to_s.strip
      raise Invalid, "assignee is longer than #{MAX_ASSIGNEE}" if a.length > MAX_ASSIGNEE

      a.empty? ? nil : a
    end

    def priority!(v)
      return nil if v.nil? || v.to_s.empty?

      ps = @config.priorities
      ps.include?(v.to_s) ? v.to_s : raise(Invalid, "priority must be one of #{ps.join(', ')} or empty (got #{v.inspect})")
    end

    # A parent: a live card of the SAME board, not the card itself, not one of its own descendants (no cycles).
    def parent!(v, slug, self_id)
      return nil if v.nil? || v.to_s.empty?

      pid = Integer(v, exception: false) or raise Invalid, "parent must be a card id (got #{v.inspect})"
      p = cards.where(id: pid).first or raise Invalid, "no card #{pid} to be the parent"
      raise Invalid, "parent card ##{pid} is on #{p[:project_slug]}, not on #{slug}" unless p[:project_slug] == slug
      raise Invalid, "parent card ##{pid} is archived" if p[:archived_at]
      raise Invalid, "a card cannot be its own parent" if self_id && pid == self_id

      if self_id
        cur = p
        while cur && cur[:parent_id]
          raise Invalid, "card ##{pid} already waits for ##{self_id} — a cycle" if cur[:parent_id] == self_id

          cur = cards.where(id: cur[:parent_id]).first
        end
      end
      pid
    end

    def metadata!(v)
      raise Invalid, "metadata must be a JSON object (got #{v.class.name.downcase})" unless v.is_a?(Hash)
      raise Invalid, "metadata keys must be strings" unless v.keys.all?(String)

      s = JSON.generate(v)
      raise Invalid, "metadata is longer than #{MAX_METADATA} characters as JSON" if s.length > MAX_METADATA

      JSON.parse(s) # a detached, plain copy
    end
  end
end
