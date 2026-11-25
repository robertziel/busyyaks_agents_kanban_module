# frozen_string_literal: true

require "json"
require "date"
require "time"
require "digest"
require "securerandom"
require "openssl"
require_relative "errors"
require_relative "host_config"
require_relative "board_repo"
require_relative "schema"
require_relative "session_dialog"
require_relative "attachment_policy"

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
    # The answers that need the owner to act (gate watch: one ping per completion, finished_at = its time): a failed CI,
    # and one the host calls stuck — pending longer than it allows (finished_at = when it became stuck).
    RED = %w[failure stuck].freeze
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
    MAX_PING_TEXT = 7900 # one pending row's burst
    DRAGGED_NOTE = "It was dragged: CI was not asked — read the PR's checks first."
    FORCED_NOTE = "It was approved with Force: CI was not asked — read the PR's checks first."
    CI_NOT_ASKED = "ci-not-asked" # the approve ping's marker: a drag approved the step, the green-CI gate was not asked
    # Card #497: an approval whose green answer carried rebase: (the PR conflicts with its base) is accepted and marked
    # — a ci_watches row of this kind (ref = the card's nth mark, created_at = the approval time, state = the JSON
    # {state, base, base_sha}); open while
    # commented_at is nil. The approve ping's marker: "rebase:" + that JSON.
    REBASE = "rebase"
    CI_FORCED = "ci-forced" # the approve ping's marker: the operator's Force approved the step, CI was not asked
    URL_RE = %r{\Ahttps?://[^\s<>"]{3,2000}\z}
    DIALOG_REASK = 120 # an answered dialog still on screen this long after the key press is not re-posted
    FIELDS = %i[title notes labels assignee priority due due_done cover parent metadata].freeze
    SCREENSHOT_TYPES = %w[image/png image/jpeg image/webp image/gif].freeze

    attr_reader :db, :config, :markdown, :tables, :repo

    # boards: ->(slug) { true | false } — the host says which boards exist (busyyaks: its projects table); a card is
    # never written for a slug the host does not know.
    # prs: the host's PR roles port — pr_roles(card) → {role => {repos: ["owner/name", …] | nil (any repo),
    # required: bool, error: nil | "why this role takes no PR now" (an assignment under it is refused with that)}}
    # (Delivery::Unavailable with the reason when the host cannot say): the roles kanban_pr_assign takes on that card,
    # the repos a PR of each one may be on (a card may change several repos), and which roles an agent must have at
    # least one PR of before it moves the card out of a working column into review / a gate / done. Required: a host
    # whose cards carry no PRs answers {} (every role refused, none required) — said by the host, never assumed by
    # the engine.
    def initialize(db, config:, markdown:, boards:, prs:, clock: -> { Time.now.to_i }, ci: nil)
      raise ArgumentError, "config must be an AgentsKanban::HostConfig" unless config.is_a?(HostConfig)
      raise ArgumentError, "prs: must answer pr_roles(card) (the host's PR roles port)" unless prs.respond_to?(:pr_roles)
      if ci.respond_to?(:progress) != ci.respond_to?(:progress_kinds)
        raise ConfigError, "the ci: port must answer both progress(card) and progress_kinds (the progress watch's " \
                           "evidence and what it is), or neither"
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
      @prs = prs
      @tables = Schema.tables(config.table_prefix)
      # a session board is never instantiated from the project template: only session_board! creates one
      @repo = BoardRepo.new(db, tables: @tables, host: config, clock: clock,
                                known: ->(s) { !session_slug?(s) && boards.call(s) })
      @session_board = session_board_shape(config)
      @attachment_ref = %r{\(#{Regexp.escape(config.attachment_url_prefix)}/(\d+)(?:/download)?\)}
      check_priorities!
    end

    # A host config whose `priorities` no longer lists a priority a card holds is refused at start: ranking
    # that card would raise inside the shared passes (pings, adoption, the approved queue) for every board. Put the
    # value back in `priorities`, or clear it on those cards first. Before the schema exists there are no cards.
    def check_priorities!
      return unless @db.table_exists?(@tables[:cards])

      held = cards.exclude(priority: nil).exclude(priority: "").exclude(priority: @config.priorities)
                  .order(:id).select_map(%i[priority id]).group_by(&:first)
      return if held.empty?

      list = held.map { |p, rows| "#{p.inspect} (card #{rows.map { |r| "##{r.last}" }.join(', ')})" }.join("; ")
      raise ConfigError, "priorities: #{@config.priorities.join(', ')} drops what cards hold: #{list} — put it back in " \
                         "priorities, or clear it on those cards first"
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
      not_session_shape!(slug)
      green_ci_port!(hash)
      @repo.save(slug, hash, by: who!(by), cards_in: method(:cards_in_columns))
      board_json(slug)
    end

    # A board whose gate waits for green CI (requires_green_ci) needs a Store with a ci: port that answers
    # approval_checks: refused on save, never found out at the first Approve.
    def green_ci_port!(hash)
      cols = hash.is_a?(Hash) && hash["columns"].is_a?(Array) ? hash["columns"] : []
      gated = cols.select { |c| c.is_a?(Hash) && c["requires_green_ci"] == true }.map { |c| c["key"] }
      return if gated.empty? || @ci.respond_to?(:approval_checks)

      raise Invalid, "column #{gated.join(', ')}: requires_green_ci needs a host CI port (Store ci: answering " \
                     "approval_checks) — this host has none: save the gate without it"
    end

    # Back to the template (the project's rows replaced by its copy; refused like a save when cards sit in a column the
    # template lacks). → board_json
    def board_reset(slug, by:)
      board!(slug)
      not_session_shape!(slug)
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

    # ── session boards: a board of ONE agent session, no project (HostConfig#session_boards) ─────────────

    def session_boards? = !@config.session_boards.nil?
    def session_slug?(slug) = session_boards? && slug.to_s.start_with?(@config.session_boards.slug_prefix)
    # The session a session board belongs to (nil for a project's slug).
    def session_of(slug) = session_slug?(slug) ? slug.to_s.delete_prefix(@config.session_boards.slug_prefix) : nil

    def session_slug(session)
      raise Invalid, "session boards are off on this host (session_boards: null)" unless session_boards?

      s = session.to_s.strip
      raise Invalid, "tmux session must match #{SESSION.source}" unless s.match?(SESSION)

      "#{@config.session_boards.slug_prefix}#{s}"
    end

    # The session's own board: created from the host's session_boards.board on the first call, an archived one brought
    # back (its archived cards stay archived), a live one touched — calling it counts as the session being active.
    # → {slug, session, state: "created" | "restored" | "touched"}
    def session_board!(session, by:)
      slug = session_slug(session)
      state = @db.transaction { @repo.open_session_board(slug, @session_board, by: who!(by)) }
      { slug: slug, session: session_of(slug), state: state }
    end

    # The host's session board shape (a Board; nil when session boards are off).
    def board_of_session_shape = @session_board

    # The card a comment / checklist / checklist item sits on (nil when there is none: the tool refuses with its own
    # reason) — what Tools reads to tell whether a call is about a session board.
    def comment_card_id(id) = activity_t.where(id: Integer(id, exception: false) || -1).get(:card_id)
    def checklist_card_id(id) = checklists_t.where(id: Integer(id, exception: false) || -1).get(:card_id)
    def item_card_id(id)
      cl = items_t.where(id: Integer(id, exception: false) || -1).get(:checklist_id)
      cl && checklist_card_id(cl)
    end

    # The last time anything happened on a session board: the board row (created, restored, opened by its session),
    # any card's update, any activity entry on its cards. epoch seconds.
    def session_board_activity(slug, row: nil)
      row ||= @repo.session_row(slug) || raise(Invalid, "no board #{slug}")
      ids = cards.where(project_slug: slug.to_s).select(:id)
      # the engine's own entries (pings, reminders, archive lines — system_author) are not the session being active;
      # cards.updated_at is not read: an engine write touches it too, and every write by an actor logs an entry
      acted = activity_t.where(card_id: ids).exclude(author: @config.system_author).max(:created_at)
      [row[:updated_at], acted].compact.max
    end

    # Session boards with no activity for session_boards.idle_hours: every live card archived (logged by the system
    # author) and the board hidden (boards.archived_at) — kept, never deleted; the session's next session_board! brings
    # the board back. → [slugs archived]
    def session_boards_expire_pass
      return [] unless session_boards?

      now = @clock.call
      idle = @config.session_boards.idle_hours * 3600
      sys = @config.system_author
      @repo.session_rows(@config.session_boards.slug_prefix).filter_map do |row|
        slug = row[:project_slug]
        next if now - session_board_activity(slug, row: row) < idle

        # read again inside the transaction: a touch / restore / card write between the scan and here keeps the board
        @db.transaction do
          fresh = @repo.session_row(slug)
          next nil if fresh.nil? || fresh[:archived_at] || now - session_board_activity(slug, row: fresh) < idle

          live(slug).select(:id).all.each do |c|
            cards.where(id: c[:id]).update(archived_at: now, updated_at: now)
            log(c[:id], "archive", "archived: session board inactive for #{@config.session_boards.idle_hours} h", sys)
          end
          @repo.archive_session_board(slug, at: now)
          slug
        end
      end
    end

    # The session boards for the operator's list: live ones, or every one with archived: true.
    # → [{slug, session, archived, last_activity, expires, counts: {column => n}, cards: [card]}]
    def session_boards(archived: false)
      return [] unless session_boards?

      idle = @config.session_boards.idle_hours * 3600
      rows = @repo.session_rows(@config.session_boards.slug_prefix, archived: archived)
      boards = boards_for(rows.map { |r| r[:project_slug] })
      rows.map do |r|
        slug = r[:project_slug]
        b = boards.fetch(slug)
        last = session_board_activity(slug, row: r)
        cs = r[:archived_at] ? [] : board(slug, board: b).values.flatten
        { slug: slug, session: session_of(slug), archived: iso(r[:archived_at]), last_activity: iso(last),
          expires: r[:archived_at] ? nil : iso(last + idle),
          columns: b.keys.map { |k| { key: k, label: b.label(k), type: b.type_of(k).key } },
          cards: cs.map { |c| card_json(c) }, }
      end
    end

    # ── reading ───────────────────────────────────────────────────────────────────────────────────

    # {column_key => [card]} in the board's order, live cards only, each decorated for its face. on_hold: true → the
    # cards ON HOLD instead (Store#hold: the operator's other view of the same board, the same columns).
    def board(slug, board: nil, on_hold: false)
      b = board || board_of(slug)
      rows = (on_hold ? held_cards(slug) : live(slug)).order(:position, :id).all.map { |c| hydrate(c, b) }
      by_col = decorate(rows, { slug => b }).group_by { |c| c[:column] }
      b.keys.to_h { |k| [k, by_col[k] || []] }
    end

    # with_held: false leaves out the cards ON HOLD (what agents read: Tools never shows one)
    def archived(slug, with_held: true)
      ds = cards.where(project_slug: slug).exclude(archived_at: nil)
      ds = ds.where(on_hold_at: nil) unless with_held
      rows = ds.order(Sequel.desc(:archived_at)).all
      decorate(rows.map { |c| hydrate(c) })
    end

    # {slug => {column_key => n}} over live cards (every column of the project's board, 0 when empty); one project when
    # slug is given, the projects in `slugs` when a list is given (a project with no live card is left out).
    # boards: {slug => Board} when the caller read them already (one batch read for a page).
    def counts(slug = nil, slugs: nil, boards: nil)
      ds = cards.where(archived_at: nil, on_hold_at: nil)
      ds = ds.where(project_slug: slug) if slug
      ds = ds.where(project_slug: slugs) if slugs
      rows = ds.group_and_count(:project_slug, :column).all
      boards ||= boards_for(rows.map { |r| r[:project_slug] }.uniq)
      rows.each_with_object({}) do |r, acc|
        (acc[r[:project_slug]] ||= boards[r[:project_slug]].keys.to_h { |k| [k, 0] })[r[:column]] = r[:count]
      end
    end

    def empty_counts(slug) = board_of(slug).keys.to_h { |k| [k, 0] }

    # How many cards of the project are ON HOLD (the board's "On hold" view; never in counts).
    def on_hold_count(slug) = held_cards(slug).count

    # {slug => n}: live cards flagged needs_operator per project that sit outside their board's waiting columns — what
    # "N waiting for you" adds to the waiting columns' counts (a flagged card in a gate counts once). A card only
    # blocked_external waits for the world, not for the operator (waiting_counts `external`).
    def flagged_counts(slugs, boards: nil)
      rows = cards.where(archived_at: nil, on_hold_at: nil, project_slug: slugs.to_a)
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
    # approved: {slug => [card]} — the gate cards the operator approved whose agent carries them on (carried_on?)
    # workerless: {slug => [card]} — the cards waiting for a worker (card 612) the watch has not escalated yet: the lead's
    # to hand out, not the operator's
    WaitingCards = Struct.new(:by_slug, :boards, :held, :external, :approved, :workerless)

    # Live cards of these projects waiting for the operator: the ones flagged needs_operator (a question asked, a
    # dialog on the owner's screen) in whatever column they sit, and the cards in their boards' WAITING columns (a
    # gate: a handoff to check); decorated, flagged cards first, then the board's waiting order, then longest-waiting
    # first. A card only blocked_external (external?) goes to `external` wherever it sits, a gate card held for CI to
    # `held`: neither waits for the operator. :since is when the flag was set, else when the card entered the column
    # (its last move there, or its creation there); nil when the activity log does not say — unknown, not guessed.
    # → WaitingCards (by_slug + the boards, the template included)
    def waiting_cards(slugs)
      rows = cards.where(archived_at: nil, on_hold_at: nil, project_slug: slugs.to_a).all
      boards = boards_for(rows.map { |c| c[:project_slug] }.uniq + [Board::TEMPLATE])
      picked = rows.select do |c|
        b = boards[c[:project_slug]]
        flagged?(c) || b.waiting.include?(c[:column]) || progress_stale(c, b) || waiting_for_worker?(c, b)
      end
      all = decorate(picked.map { |c| hydrate(c, boards[c[:project_slug]]) }, boards)
      external, rest = all.partition { |c| external?(c) }
      held, rest = rest.partition { |c| c[:gate_hold] && !flagged?(c) }
      approved, rest = rest.partition { |c| carried_on?(c, boards[c[:project_slug]], c[:gate_hold]) }
      # a card waiting for a worker that waits for nobody else (its gate holds, asks nothing) is the lead's, not yours
      workerless, list = rest.partition { |c| c[:waiting_for_worker] && !c[:waiting] }
      acts = activity_t.where(card_id: list.map { |c| c[:id] }, kind: %w[move create])
        .select(:card_id, :body, :created_at)
        .all
        .group_by { |a| a[:card_id] }
      external.each { |c| c[:since] = flag_since(c) }
      approved.each { |c| c[:since] = c[:approved_at] }
      workerless.each { |c| c[:since] = c[:worker_wait_at] }
      list.each do |c|
        c[:since] = flag_since(c) || (c[:progress_stale] && c[:progress_stale_at]) ||
                    (c[:waiting_for_worker]&.dig(:stale) && c[:worker_wait_at]) ||
                    (acts[c[:id]] || []).select { |a| a[:body].end_with?(c[:column_label]) }.map { |a| a[:created_at] }.max
      end
      sorted = list.sort_by do |c|
        b = boards[c[:project_slug]]
        [flagged?(c) ? 0 : 1, b.waiting.index(c[:column]) || -1, c[:since] || 0, c[:id]]
      end
      WaitingCards.new(sorted.group_by { |c| c[:project_slug] }, boards, held.group_by { |c| c[:project_slug] },
                       external.sort_by { |c| [c[:since], c[:id]] }.group_by { |c| c[:project_slug] },
                       approved.sort_by { |c| [c[:since], c[:id]] }.group_by { |c| c[:project_slug] },
                       workerless.sort_by { |c| [c[:since] || 0, c[:id]] }.group_by { |c| c[:project_slug] })
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
    # A card the progress watch escalated to its last step (progress_stale) waits for the operator too.
    def waits_for_operator?(c, b, hold)
      needs_operator?(c) || (!external?(c) && hold.nil? && !carried_on?(c, b, hold) && b.waiting.include?(c[:column])) ||
        !progress_stale(c, b).nil? || !worker_stale(c, b).nil?
    end

    # Approved and carried on by its agent: a card in a waiting gate the operator approved, whose next step is
    # an agent's named transition (Board#agent_next) — e.g. Awaiting merge after the final Approve, while its agent
    # merges. It waits for the agent, not for the operator: counted apart (`approved`), never hidden. Precedence: a
    # question open on it waits for the operator (needs_operator wins); blocked_external wins (`external`); a CI hold
    # wins (`held`: CI red after the Approve says so, hold = Store#gate_hold's why); NO owner session → nobody carries it
    # on, so it waits for the operator ("approved · no agent" on the waiting list) until a session owns it.
    # A card the progress watch escalated to its last step waits for the operator: no longer "agent on it".
    def carried_on?(c, b, hold = nil)
      agents_next_step?(c, b) && hold.nil? && progress_stale(c, b).nil?
    end

    # Approved, owned, and the next step is its agent's — whatever CI says: the progress watch's gate scope.
    def agents_next_step?(c, b)
      !c[:approved_at].nil? && !needs_operator?(c) && !c[:owner_session].to_s.empty? &&
        b.waiting.include?(c[:column]) && !b.agent_next(c[:column]).nil?
    end

    # card JSON `carried_on`: {next_column, next_label, final (= into the done column: its agent merges)} | nil
    def carried_on_json(c, b, hold = c[:gate_hold])
      return nil unless carried_on?(c, b, hold)

      nxt = b.agent_next(c[:column])
      { next_column: nxt, next_label: b.label(nxt), final: b.done?(nxt) }
    end

    # The cards each OPEN registration (agent_sessions, ended_at null) on these projects' boards holds since it registered —
    # the column's type says what each is to the session (`finishes` = in the board's done column: that card is finished).
    # Scoped to the registration, not the name: a tmux name is handed out again once its session ends, and a card in a
    # done column keeps its old owner as history — a new session of the same name must not inherit those. A card counts
    # when it became this owner's (its creation, or its last `owner` activity) at or after the registration's
    # launched_at, on the registration's socket. A session with no open registration is absent: its cards are unknown.
    # Light rows (the agents sidebar reads them every poll). → {[session, socket] => {project_slug:, since:, cards:
    # [{id, project_slug, title, column, column_label, column_type, finishes, updated_at}], agent:, type:}} (the
    # registration's agent name and type: its face), cards in board order.
    def owned_cards(slugs)
      regs = sessions_t.where(ended_at: nil, project_slug: slugs.to_a)
        .select(:session, :socket, :project_slug, :launched_at, :agent_name, :type_key)
        .all
      return {} if regs.empty?

      rows = cards.where(archived_at: nil, on_hold_at: nil, owner_session: regs.map { |r| r[:session] }.uniq)
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
        reg = { project_slug: r[:project_slug], since: r[:launched_at], agent: r[:agent_name], type: r[:type_key] }
        [[r[:session], r[:socket]], reg.merge(cards: list)]
      end
    end

    def card(id)
      c = cards.where(id: Integer(id)).first
      c && decorate([hydrate(c)]).first
    end

    def card!(id) = card(id) || raise(Invalid, "no card #{id}")

    # {id => project_slug} for the ids that are cards (archived too: they still open by ?card=).
    def card_slugs(ids) = ids.empty? ? {} : cards.where(id: ids.to_a).select_hash(:id, :project_slug)

    # the ids among `ids` whose card is ON HOLD (Tools' guard: out of every agent's sight)
    def on_hold_ids(ids) = ids.empty? ? [] : cards.where(id: ids.to_a).exclude(on_hold_at: nil).select_map(:id)

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
            media: c[:media], # the newest picture attachment {id, filename, url} for the face (decorated cards only)
            owner_session: c[:owner_session], owner_socket: c[:owner_socket],
            approved: iso(c[:approved_at]), approved_by: c[:approved_by],
            pr_url: c[:pr_url], ci_url: c[:ci_url], ui_change: c[:ui_change],
            handoff: iso(c[:handoff_at]), handoff_by: c[:handoff_by],
            question: c[:question], question_options: c[:question_options] && JSON.parse(c[:question_options]),
            asked: iso(c[:asked_at]), asked_by: c[:asked_by], dialog: c[:dialog],
            needs_operator: !c[:asked_at].nil?,
            gate_hold: c[:gate_hold], # waiting for CI, not for the operator (gate_hold; decorated cards only)
            # the progress watch's last step: why the card waits for the operator (decorated cards only)
            progress_stale: c[:progress_stale],
            # no worker on it (card 612: a lead is never an assignee): {since, stale} | nil (decorated cards only)
            waiting_for_worker: c[:waiting_for_worker],
            # why the progress watch could not read this card's evidence on its last pass (nil = it could)
            progress_error: progress_watch? ? c[:progress_error] : nil,
            # approved on a PR that conflicts with its base (card #497; decorated cards only): what to rebase onto
            needs_rebase: c[:needs_rebase] && { pr: c[:needs_rebase]["pr"], state: c[:needs_rebase]["state"],
                                                base: c[:needs_rebase]["base"], base_sha: c[:needs_rebase]["base_sha"],
                                                at: iso(c[:needs_rebase]["at"]), },
            waiting: c[:waiting], # waits for the operator now (waits_for_operator?: the counts' rule; decorated cards only)
            # approved and carried on by its agent (carried_on_json: {next_column, next_label, final} | nil;
            # decorated cards only)
            carried_on: c[:carried_on],
            # its place among the approved cards its agents carry on from the same column (decorated only)
            approved_queue: c[:approved_queue],
            blocked: c[:blocked_at] && { reason: c[:blocked_reason], url: c[:blocked_url], by: c[:blocked_author],
                                         at: iso(c[:blocked_at]), },
            review_round: review_rounds(c)[c[:column]],
            parent: c[:parent_id], children: c[:children], blocked_by: c[:blocked_by], metadata: c[:metadata],
            created_by: c[:created_by], created: iso(c[:created_at]), updated: iso(c[:updated_at]),
            archived: iso(c[:archived_at]),
            # the operator's ON HOLD (Store#hold): {at, by} | nil
            on_hold: c[:on_hold_at] && { at: iso(c[:on_hold_at]), by: c[:on_hold_by] }, }
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
        activity: activity(c[:id]).map { |e| activity_json(e) }, agents: agent_types(c[:project_slug]), }
    end

    # Which agent type each agent name of a project registered as ({agent name => type key}; the newest registration
    # wins) — what a face's colour is drawn from. A name no session registered under (a subagent's own name, a person)
    # is absent: its type is unknown, never guessed from the name.
    def agent_types(slug)
      sessions_t.where(project_slug: slug.to_s).order(:launched_at, :id).select(:agent_name, :type_key).all
                .to_h { |r| [r[:agent_name], r[:type_key]] }
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
      # What gets worked is the operator's call — on a board with a parked column an agent's card starts there
      # (Backlog), never straight in the work flow
      if agent && b.operator_exit.any? && !b.operator_exit?(column)
        raise Denied, "agents create cards only in #{b.operator_exit.map { |k| b.label(k) }.join(' / ')}: the operator " \
                      "moves a card into the work flow (#{b.label(column)} refused)"
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
      # a lead owns the cards it creates (their pings reach it) but is never their assignee: they wait for a worker
      lead_made = owner && (lead_reg?(reg) || lead_agent?(by))
      no_lead_assignee!(assignee) unless assignee.nil? # given with or without an owner: a lead named is refused
      who = if lead_made then nil
            elsif owner then by
            else assignee!(assignee)
            end
      # validate before the transaction: Sequel wraps anything raised inside one in a DatabaseError
      row = { project_slug: slug, column: column, title: title!(title), notes: notes.to_s,
              labels: JSON.generate(labels!(labels, slug)),
              assignee: who, priority: priority!(priority), due_at: due!(due),
              created_by: by, created_at: now, updated_at: now,
              parent_id: pid, metadata: metadata.nil? ? nil : JSON.generate(metadata!(no_pr_keys!(metadata))),
              owner_session: owner, owner_socket: owner && owner_socket.to_s, }
      blocked!(b, column, unfinished([pid].compact), "card")
      @db.transaction do
        id = cards.insert(row.merge(position: live(slug).where(column: column).count))
        note = if lead_made then " · owner session: #{owner} (#{by}, a lead: never the assignee)"
               elsif owner then " · owner session: #{owner} (#{by})"
               elsif elsewhere then " · not owned: #{owner_session.to_s.strip} is registered for #{elsewhere}, not #{slug}"
               else ""
               end
        log(id, "create", "created in #{b.label(column)}#{note}", by)
        log(id, "parent", "waits for card ##{pid}", by) if pid
        promote_children(id, by) if b.done?(column) && !agent
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
      no_lead_assignee!(set[:assignee]) if set[:assignee]
      set[:priority] = priority!(a[:priority]) if a.key?(:priority)
      set[:due_at] = due!(a[:due]) if a.key?(:due)
      set[:due_done] = bool!(a[:due_done], "due_done") if a.key?(:due_done)
      set[:cover] = color!(a[:cover], nullable: true) if a.key?(:cover)
      set[:parent_id] = parent!(a[:parent], c[:project_slug], c[:id]) if a.key?(:parent)
      set[:metadata] = metadata_update(c, a[:metadata]) if a.key?(:metadata)
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

    PR_URL = %r{\Ahttps://github\.com/([\w.-]+/[\w.-]+)/pull/([1-9]\d*)\z}
    PR_ROLE = /\A[a-z][a-z0-9_-]{0,31}\z/
    MAX_PR_REASON = 500

    # The agent that opened a PR assigns it to its card: metadata `prs` is a LIST of assigned PRs
    # ([{url, repo, number, role, by, at}], oldest first) — any number per role and per repo (a card may change several
    # repos). The host names the roles and the repos each one takes through the prs: port and reads the list back;
    # nothing is derived from branch names or text. Assigning ADDS: the same URL under the same role again is a no-op,
    # nothing is ever replaced or dropped (a PR leaves the list only through unassign_pr). Refused: a role the host does
    # not read on this card, a PR on a repo its role does not take, the URL already on this card under another role, and
    # a PR already assigned to another card (a PR belongs to one card; a card in a cancelled column gives its PRs up).
    # Logged as an `update` line "PR <role>: <url>".
    def assign_pr(id, url:, role:, by:)
      url = url.to_s.strip
      m = url.match(PR_URL)
      raise Invalid, "pr_url must be a GitHub pull request URL (https://github.com/<owner>/<repo>/pull/<n>)" unless m
      unless role.to_s.match?(PR_ROLE)
        raise Invalid, "role must be a lowercase word (a-z 0-9 _ -, at most 32): #{role.to_s[0, 40].inspect}"
      end

      by = who!(by)
      return card(id) if same_pr!(card!(id), url, role)

      # Every check runs INSIDE the transaction (the host serialises writers: SQLite BEGIN IMMEDIATE, PostgreSQL an
      # advisory lock), so two agents assigning one PR to two cards cannot both pass. A raise inside a transaction
      # reaches the caller wrapped by some hosts, so a refusal rolls back and is raised after it.
      refusal = nil
      @db.transaction do
        c = card!(id)
        begin
          next if same_pr!(c, url, role) # assigned in between: still a no-op

          removed_prs!(c)
          pr_role_check!(c, role, m[1])
          pr_elsewhere!(c, url)
          meta = c[:metadata] ? JSON.parse(JSON.generate(c[:metadata])) : {}
          entry = { "url" => url, "repo" => m[1], "number" => m[2].to_i, "role" => role, "by" => by, "at" => @clock.call }
          meta["prs"] = card_prs!(c) + [entry]
          json = JSON.generate(pr_metadata!(c, meta))
        rescue Invalid => e
          refusal = e
          raise Sequel::Rollback
        end
        cards.where(id: c[:id]).update(metadata: json, updated_at: @clock.call)
        log(c[:id], "update", "PR #{role}: #{url}", by)
      end
      raise refusal if refusal

      card(id)
    end

    # Takes one PR off the card's list (`prs`) — the only way a PR leaves it — and keeps it in metadata `prs_removed`
    # ([{url, repo, number, role, by, at, removed_by, removed_at, reason}], oldest first). `reason` is required.
    # An agent (agent: true) unassigns only a PR it assigned itself (`by`) or one on a card it is the assignee of; the
    # operator any. Logged as an `update` line "PR <role> unassigned: <url> — <reason>".
    def unassign_pr(id, url:, by:, reason:, agent:)
      url = url.to_s.strip
      reason = reason.to_s.strip
      raise Invalid, "reason is required: why this PR is not the card's" if reason.empty?
      raise Invalid, "reason is longer than #{MAX_PR_REASON} characters" if reason.length > MAX_PR_REASON

      by = who!(by)
      card!(id) # no such card: refused before the transaction (a raise inside one reaches the host wrapped)
      refusal = nil
      @db.transaction do
        c = card!(id)
        begin
          prs = card_prs!(c)
          entry = prs.find { |p| p["url"].casecmp?(url) }
          unless entry
            have = prs.empty? ? "none" : prs.map { |p| "#{p['role']} #{p['url']}" }.join(", ")
            raise Invalid, "#{url} is not assigned to card ##{c[:id]} (its PRs: #{have})"
          end
          if agent && entry["by"] != by && c[:assignee] != by
            raise Denied, "#{url} was assigned by #{entry['by'] || 'nobody recorded'}: only that agent, the card's " \
                          "assignee (#{c[:assignee] || 'none'}) or the operator unassigns it"
          end

          meta = JSON.parse(JSON.generate(c[:metadata]))
          meta["prs"] = prs.reject { |p| p.equal?(entry) }
          gone = entry.merge("removed_by" => by, "removed_at" => @clock.call, "reason" => reason)
          meta["prs_removed"] = removed_prs!(c) + [gone]
          json = JSON.generate(pr_metadata!(c, meta))
        rescue Invalid => e
          refusal = e
          raise Sequel::Rollback
        end
        cards.where(id: c[:id]).update(metadata: json, updated_at: @clock.call)
        log(c[:id], "update", "PR #{entry['role']} unassigned: #{entry['url']} — #{reason}", by)
      end
      raise refusal if refusal

      card(id)
    end

    PR_MENTION = %r{https://github\.com/[\w.-]+/[\w.-]+/pull/[1-9]\d*}

    # A report for a human to confirm, never acted on: every PR URL an open card (not archived, its column not of type
    # done / cancelled, not on a session board) names in its own text — its handoff `pr_url`, its description, its
    # comments and handoffs — that is not in its `prs` list → [{card:, project:, column: (label), url:, seen:}]
    # (`seen` = where it is first named: "pr_url", "description", "<kind> <activity id>"), one row per card and URL
    # (any case), in card order. Reads only: a PR is assigned by the agent that opened it (kanban_pr_assign), never
    # derived from text. A card whose `prs` cannot be read → Invalid naming it.
    def unassigned_pr_mentions
      open = cards.where(archived_at: nil).order(:id).all.reject do |c|
        session_slug?(c[:project_slug]) || %w[done cancelled].include?(board_of(c[:project_slug]).type_of(c[:column]).key)
      end
      acts = activity_t.where(card_id: open.map { |c| c[:id] }, kind: %w[comment handoff]).order(:id)
                       .select(:card_id, :id, :kind, :body).all.group_by { |a| a[:card_id] }
      open.flat_map do |row|
        c = hydrate(row)
        # assigned, or taken off on purpose (an unassign, the v14 migration): neither is "named but not assigned"
        have = (card_prs!(c) + removed_prs!(c)).map { |p| p["url"].downcase }
        named = [["pr_url", c[:pr_url].to_s], ["description", c[:notes].to_s]] +
                acts.fetch(c[:id], []).map { |a| ["#{a[:kind]} #{a[:id]}", a[:body].to_s] }
        seen = {}
        named.each do |where, text|
          text.scan(PR_MENTION).each { |u| seen[u.downcase] ||= [u, where] unless have.include?(u.downcase) }
        end
        seen.values.map do |url, where|
          { card: c[:id], project: c[:project_slug], column: board_of(c[:project_slug]).label(c[:column]), url: url,
            seen: where, }
        end
      end
    end

    # true = the URL is already this card's PR under `role` (a no-op); under another role → Invalid
    def same_pr!(c, url, role)
      had = card_prs!(c).find { |p| p["url"].casecmp?(url) }
      return false unless had
      return true if had["role"] == role

      raise Invalid, "#{url} is already the #{had['role']} PR of card ##{c[:id]}: kanban_pr_unassign it first to " \
                     "assign it as #{role}"
    end

    # metadata! with the size cap said for PRs: the list is what grew
    def pr_metadata!(c, meta)
      metadata!(meta)
    rescue Invalid => e
      raise Invalid, "card ##{c[:id]}: #{e.message} with its PRs — unassign the PRs that are not this card's"
    end

    # the card's metadata prs_removed ([] when none); anything but a list of {role, url} objects is refused
    def removed_prs!(c)
      list = c[:metadata].is_a?(Hash) ? c[:metadata]["prs_removed"] : nil
      return [] if list.nil?

      ok = list.is_a?(Array) && list.all? { |r| r.is_a?(Hash) && r["role"].is_a?(String) && r["url"].is_a?(String) }
      return list if ok

      raise Invalid, "card ##{c[:id]} metadata prs_removed is not a list of {role, url}: #{JSON.generate(list)[0, 200]}"
    end

    # The host's PR roles for this card ({role => {repos:, required:, error:}}); the host cannot say → Invalid.
    def pr_roles!(c)
      roles = @prs.pr_roles(c)
      unless roles.is_a?(Hash)
        raise Invalid, "the host's prs: port answered #{roles.class}, not {role => {repos:, required:}}"
      end

      roles
    rescue Delivery::Unavailable, Delivery::Refused => e
      raise Invalid, "the PR roles of card ##{c[:id]} cannot be read: #{e.message}"
    end

    def pr_role_check!(c, role, repo)
      roles = pr_roles!(c)
      spec = roles[role]
      unless spec
        raise Invalid, "role #{role.inspect} is not one this project reads (#{roles.keys.join(', ')}): " \
                       "kanban_pr_assign with one of those"
      end
      raise Invalid, "a #{role} PR cannot be assigned on card ##{c[:id]} now: #{spec[:error]}" if spec[:error]

      want = spec[:repos]
      return if want.nil? || want.any? { |r| r.casecmp?(repo) } # GitHub owner/name: any case

      raise Invalid, "a #{role} PR is on #{want.empty? ? 'no repo the host knows' : want.join(' / ')}, not on " \
                     "#{repo}: assign this PR under the role of its repo"
    end

    # the same PR (any case) assigned to another live card that is not cancelled → Invalid naming it. A card ON HOLD
    # still holds its PR (it comes back on release), but the refusal never names it: no agent learns a held card's id.
    def pr_elsewhere!(c, url)
      number = url[%r{/pull/(\d+)\z}, 1]
      cards.exclude(id: c[:id]).where(archived_at: nil).where(Sequel.like(:metadata, "%/pull/#{number}%")).all.each do |o|
        meta = JSON.parse(o[:metadata])
        prs = meta.is_a?(Hash) && meta["prs"].is_a?(Array) ? meta["prs"] : []
        had = prs.find { |p| p.is_a?(Hash) && p["url"].is_a?(String) && p["url"].casecmp?(url) }
        next unless had
        next if board_of(o[:project_slug]).type_of(o[:column]).key == "cancelled"

        raise Invalid, "#{url} is already the #{had['role']} PR of another card: a PR belongs to one card" if on_hold?(o)

        raise Invalid, "#{url} is already the #{had['role']} PR of card ##{o[:id]} (#{o[:project_slug]}): a PR belongs " \
                       "to one card — open a PR for this card, or work on card ##{o[:id]}"
      end
    end

    # The agent moving a card out of a working column into review, a gate or done must have the PRs the host requires
    # assigned (a session board has no project: nothing asked).
    def required_prs!(b, c, column)
      return unless b.working?(c[:column]) && %w[review gate done].include?(b.type_of(column).key)
      return if session_slug?(c[:project_slug])

      missing = missing_prs(c)
      return if missing.empty?

      raise Denied, "card ##{c[:id]} has no #{missing.join(' / ')} PR assigned — open the PR and " \
                    "kanban_pr_assign(#{c[:id]}, pr_url, #{missing.first.inspect}, author) before it leaves " \
                    "#{b.label(c[:column])}"
    end

    # the roles the host requires on this card that have no PR assigned
    def missing_prs(c) = pr_roles!(c).select { |_, s| s[:required] }.keys - card_prs!(c).map { |p| p["role"] }

    # The operator's drag is never refused by the required-PR rule (like the CI gates): its move line says what it
    # skipped — " (dragged: no local PR)" — or why the roles could not be read. nil = nothing missing / not that move.
    def drag_pr_note(b, c, column)
      return nil unless b.working?(c[:column]) && %w[review gate done].include?(b.type_of(column).key)
      return nil if session_slug?(c[:project_slug])

      missing = missing_prs(c)
      missing.empty? ? nil : " (dragged: no #{missing.join(' / ')} PR)"
    rescue Invalid => e
      " (dragged: PR roles unknown — #{e.message})"
    end

    # The metadata keys only kanban_pr_assign / kanban_pr_unassign write: refused in create / update (by anyone: agents
    # through the tools, the operator through the Api), and kept as they are when an update replaces the rest of the
    # metadata. `prs_replaced` = the pre-list history key (never written now, never accepted).
    PR_KEYS = %w[prs prs_removed prs_replaced].freeze

    def no_pr_keys!(v)
      keys = v.is_a?(Hash) ? v.keys.map(&:to_s) & PR_KEYS : []
      return v if keys.empty?

      raise Invalid, "metadata #{keys.join(' / ')} is written only by kanban_pr_assign / kanban_pr_unassign (their " \
                     "role, repo and one-card checks): leave #{keys.size == 1 ? 'it' : 'them'} out"
    end

    # the update's metadata JSON: the given object (no PR keys) + the card's own PR keys; nil clears everything else
    def metadata_update(c, given)
      kept = c[:metadata].is_a?(Hash) ? c[:metadata].slice(*PR_KEYS) : {}
      return nil if given.nil? && kept.empty?

      meta = given.nil? ? {} : metadata!(no_pr_keys!(given))
      JSON.generate(metadata!(meta.merge(kept)))
    end

    # The card's assigned PRs (metadata `prs`, [] when none), each {url, repo, number, role, by, at}. The pre-list shape
    # ({role => url}, Schema step 13 converts it) or anything else that is not a list of PR entries is refused with
    # what it is — never read as an empty list.
    def card_prs!(c)
      prs = c[:metadata].is_a?(Hash) ? c[:metadata]["prs"] : nil
      return [] if prs.nil?
      if prs.is_a?(Hash)
        raise Invalid, "card ##{c[:id]} metadata prs is the pre-list {role => url} shape: run the host's migration " \
                       "to engine schema 13 (Schema.prs_to_lists!)"
      end
      ok = prs.is_a?(Array) && prs.all? { |p| p.is_a?(Hash) && p["url"].is_a?(String) && p["role"].is_a?(String) }
      return prs if ok

      raise Invalid, "card ##{c[:id]} metadata prs is not a list of {url, role}: #{JSON.generate(prs)[0, 200]}"
    end

    # To column at position (0-based; nil or past the end = last). Both columns are renumbered.
    # `transition:` names a workflow edge out of the card's column instead of a target column (Jira's "Start work").
    # The green-CI gate (a gate column's requires_green_ci) is asked only by an explicit approval:
    # Store#approve (the Approve button) or the step's own named transition ("Approve"). Any other operator move along
    # the step — a drag, the
    # catch-all edge — is never refused by it: it still approves, and its activity line says CI was not asked.
    # `withdraw:` = Store#unapprove's move back to the step's gate: the operator's undo needs no edge in the workflow.
    # `force:` = Store#approve(force: true), the operator's Force button: the explicit approval WITHOUT the green-CI
    # gate (every other check stays); its activity line says "(forced: CI not asked)".
    def move(id, column: nil, by:, position: nil, agent: false, handoff: false, transition: nil, approval: false,
             withdraw: false, force: false)
      raise Denied, "only the operator forces an approval" if force && agent

      c = card!(id)
      named = !transition.to_s.strip.empty?
      raise Invalid, "card #{id} is archived" if c[:archived_at]
      raise Invalid, "no card #{id}" if agent && on_hold?(c) # on hold: out of every agent's sight (Store#hold)

      b = board_of(c[:project_slug])
      parked_exit!(b, c, named ? nil : column) if agent
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
      if force && !step
        raise Invalid, "force: true only approves along an approval step (#{b.label(c[:column])} → #{b.label(column)} is none)"
      end

      checked = step && c[:column] != column && !force &&
                (approval || (named && transition.to_s.strip.casecmp?(step.name)))
      green = checked ? green_ci!(c, b, step) : nil
      rebase = green && rebase_of!(c, green)
      pr_note = !agent && c[:column] != column ? drag_pr_note(b, c, column) : nil
      rounds = c[:column] != column ? review_rounds_after(b, c, column, agent) : nil
      @db.transaction do
        place(c, column, pos)
        if c[:column] != column
          log(c[:id], "move", "#{b.label(c[:column])} → #{b.label(column)}#{' (approval withdrawn)' if withdraw}#{pr_note}",
              by)
          cards.where(id: c[:id]).update(review_rounds: JSON.generate(rounds)) if rounds != review_rounds(c)
          # the gate's head / last view belong to the handoff that brought the card in: any other move ends them (a
          # drag into another gate starts with nothing recorded — its hold is read live)
          cards.where(id: c[:id]).update(gate_head: nil, gate_state: nil) if !handoff && (c[:gate_head] || c[:gate_state])
          # an open needs-rebase mark belongs to the column the approval put the card in: any move out of it ends it
          close_rebase(c, "the card moved #{b.label(c[:column])} → #{b.label(column)}", by) if c[:needs_rebase]
          if step
            # the operator moving a card from an approval step's gate into its target IS that approval (any other move
            # into it — from elsewhere, by a catch-all edge — is a plain move: nobody is pinged to carry on)
            cards.where(id: c[:id]).update(approved_at: @clock.call, approved_by: by)
            note = approval_note(b, step)
            unasked = b.green_ci_step?(step) && !checked
            how = force ? "forced" : "dragged"
            note += " (#{how}: CI not asked)" if unasked
            log(c[:id], "approve", note, by)
            rebase_mark!(c, green, rebase, by) if rebase
            # the ping says it too: the owner carries on from it (a final step merges) and must read CI itself
            # (dragged or forced); a conflicting PR: it rebases first
            marker = (force ? CI_FORCED : CI_NOT_ASKED) if unasked
            enqueue_ping(c, "approve", by, approve_ping_body(step, marker, rebase))
          else
            # leaving the approved column for anywhere but a terminal one (history) withdraws the approval
            cards.where(id: c[:id]).update(approved_at: nil, approved_by: nil) if c[:approved_at] && !b.terminal?(column)
            enqueue_ping(c, "move", by, "moved #{b.label(c[:column])} → #{b.label(column)}:") unless agent
          end
          # Only the operator's finish of a parent promotes its parked children; an agent's leaves them parked
          promote_children(c[:id], by) if b.done?(column) && !agent
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

    # ── on hold: the operator parks a card where it sits ─────────────────────────────────────────

    # ON HOLD: the operator takes a card out of the flow without moving it — e.g. work that is done but not to be
    # released yet. The card keeps its column and its place in the review loop, flags and approvals; it leaves the
    # board's normal view (the operator's "On hold" view lists it, the same columns), every count, waiting list and
    # watch (watchdog, idle / progress / PR / rebase watches, flag reminders, the approval prefetch), and every agent's
    # sight: Tools answers "no card" for it, nobody adopts it, nothing pings for it. Putting it on hold releases its
    # owner session (an agent that cannot see the card must not be told about it) and drops the pings still pending
    # for it; only the operator moves it (by hand). Released → back in the board's normal view at the bottom of its
    # column, ownerless: the board's lead adopts it as any ownerless card. Refused on an archived card, a card in a
    # terminal column, and a session board's card (only its session acts there).
    def hold(id, by:, on_hold: true)
      c = card!(id)
      return c if on_hold == !c[:on_hold_at].nil?

      b = board_of(c[:project_slug])
      raise Invalid, "card ##{c[:id]} is archived" if c[:archived_at]
      raise Invalid, "card ##{c[:id]} is on a session board: only its session acts there" if session_slug?(c[:project_slug])
      raise Invalid, "card ##{c[:id]} is in #{b.label(c[:column])} — its work is over" if on_hold && b.terminal?(c[:column])
      kids = on_hold ? cards.where(parent_id: c[:id], archived_at: nil).order(:id).select_map(:id).map { |k| "##{k}" } : []
      if kids.any?
        # a child waits for its parent to finish: a held parent would hold its children (and show agents its id) — a
        # held child too (released, it would wait on the held parent)
        raise Invalid, "card ##{c[:id]} has cards waiting for it (#{kids.join(', ')}): finish or detach them first"
      end

      by = who!(by)
      now = @clock.call
      @db.transaction do
        if on_hold
          cards.where(id: c[:id]).update(on_hold_at: now, on_hold_by: by, owner_session: nil, owner_socket: nil,
                                         assignee: nil, updated_at: now)
          pings_t.where(card_id: c[:id], status: "pending").update(status: "failed", error: "card put on hold",
                                                                    done_at: now)
          renumber_column(c[:project_slug], c[:column])
          was = [c[:owner_session] && "owner session #{c[:owner_session]}", c[:assignee] && "assignee #{c[:assignee]}"]
                .compact
          was = was.empty? ? "" : " — #{was.join(' and ')} released"
          log(c[:id], "hold", "put on hold in #{b.label(c[:column])}#{was}", by)
        else
          at_end = live(c[:project_slug]).where(column: c[:column]).count
          cards.where(id: c[:id]).update(on_hold_at: nil, on_hold_by: nil, position: at_end, updated_at: now)
          log(c[:id], "hold", "released from hold in #{b.label(c[:column])}", by)
        end
      end
      adopt_ownerless(only: c[:id]) unless on_hold
      card(id)
    end

    def on_hold?(c) = !c[:on_hold_at].nil?

    # ── parents (dependencies): a card waits for its parent ───────────────────────────────────────

    # Live children of a card (any column), oldest first.
    def children(id)
      rows = cards.where(parent_id: Integer(id), archived_at: nil, on_hold_at: nil).order(:id).all
      decorate(rows.map { |c| hydrate(c) })
    end

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
    # transition: (the operator's only) the name of a COMMENT ACTION out of the card's column (a workflow edge
    # with comment: true; column: picks its target when the name has several): the comment is posted and the card moves
    # along it, in ONE transaction — a refused move (any rule Store#move asks) posts nothing.
    def comment(id, body:, author:, operator: false, transition: nil, column: nil)
      return comment_and_move(id, body: body, author: author, transition: transition, column: column) \
        unless transition.to_s.strip.empty? && column.to_s.strip.empty?

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
          enqueue_ping(c, operator ? OPERATOR_COMMENT : "comment", author, body.to_s)
        end
        cid
      end
    end

    def comment_and_move(id, body:, author:, transition:, column:)
      raise Invalid, "a comment action needs its transition's name" if transition.to_s.strip.empty?

      c = card!(id)
      b = board_of(c[:project_slug])
      to = column.to_s.strip.empty? ? nil : column.to_s
      e = b.workflow.named(from: c[:column], name: transition, actor: :operator, to: to)
      unless e&.comment
        acts = b.workflow.from(c[:column], actor: :operator).select(&:comment).map(&:name).uniq
        raise Denied, "workflow: #{transition.to_s.inspect} is no comment action from #{b.label(c[:column])} " \
                      "(#{acts.empty? ? 'none' : acts.join(', ')})"
      end
      raise Invalid, "body is required" if body.to_s.strip.empty?

      # a move refused after the comment rolls both back; the refusal is raised outside the transaction (a raise inside
      # one reaches the host wrapped)
      refusal = nil
      cid = nil
      @db.transaction do
        cid = comment(c[:id], body: body, author: author, operator: true)
        move(c[:id], transition: e.name, column: e.to, by: author)
      rescue Invalid => err # Denied is an Invalid
        refusal = err
        raise Sequel::Rollback
      end
      raise refusal if refusal

      cid
    end

    # ── the needs_operator flag: an agent asks the operator; the card stays where it is ─────────────
    # Requires an owner session — an answer nobody hears is the failure this flag exists to prevent. A new ask on a
    # flagged card replaces the open question. The card keeps its column (a question in review keeps its place in
    # review); while flagged, agents cannot move it; the operator's comment clears the flag.
    # session: an agent that has not claimed the card yet may claim and ask in one step (its live tmux session).
    def ask(id, question:, by:, options: nil, session: nil)
      c = card!(id)
      b = board_of(c[:project_slug])
      if session && c[:owner_session].nil?
        # a lead asking owns the card (the answer reaches it) but never claims it (card 612: no lead assignee)
        lead = lead_reg?(open_session(session.to_s.strip))
        c = lead ? set_owner(c[:id], session: session, by: by) : claim(c[:id], assignee: by, session: session)
      end
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
        tell_lead(c, "ask", by, "asked the operator: #{clip_ping(q)}")
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
        tell_lead(c, "block", by, "is blocked externally: #{clip_ping(r)} (#{u})")
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
      rows = project_cards.where(archived_at: nil, on_hold_at: nil, flag_reminded_at: nil)
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
      return "none: on hold" if c[:on_hold_at]
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
      # A gate with an approval step that waits for green CI (its requires_green_ci) is entered only on green
      # CI, BEFORE writing: the card as it will sit there is asked exactly what the operator's Approve will ask —
      # unread, pending, red or unknown →
      # refused with that state, nothing written ("hand off once CI is green"). Green → the Approve answers at once.
      ci = ci_url.to_s.strip.empty? ? nil : ci_url.to_s.strip
      step = b.approval_from(target)
      # asked as a handoff: the card carries handoff_ci_url = THIS handoff's ci_url (not written yet; nil when none) —
      # a host may check it is the build of the head handed over. Only a handoff carries the key: an Approve or a
      # watch pass asks about the head's CI, never about which build was handed over (a rebuild never parks a card)
      green = step && green_ci!(c.merge(column: target, pr_url: pr || c[:pr_url], handoff_ci_url: ci), b, step,
                                handoff: true)
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
      moved = move(id, column: target, by: by, agent: true, handoff: true)
      tell_lead(c, "handoff", by, "was handed off to #{b.label(target)}#{pr ? " (PR #{pr})" : ''}")
      moved
    end

    # ── approval: the operator approves a card for the next step; its agent then moves it on ──
    # Every approval step of the board (Board#approvals: a gate's one forward operator exit) works the same way.
    # `force: true` = the operator's Force button: the same approval without the green-CI gate (the gate column's
    # requires_green_ci — CI and the PR's state at the handoff's head are not asked); every other refusal stays.
    # Operator only: no MCP
    # tool approves, and Store#move refuses force with agent: true.
    def approve(id, by:, force: false)
      c = card!(id)
      b = board_of(c[:project_slug])
      raise Invalid, "this board has no approval step (no gate with a single forward operator exit)" if b.approvals.empty?

      step = b.approval_from(c[:column])
      into = !step && b.gate?(c[:column]) ? b.approval_into(c[:column]) : nil
      unless step || into
        raise Invalid, "only a card in #{b.approvals.map { |a| b.label(a.from) }.join(' or ')} can be approved " \
                       "(card ##{c[:id]} is in #{b.label(c[:column])})"
      end
      if force && !b.green_ci_step?(step || into)
        raise Invalid, "force: true needs a gate that waits for green CI — #{b.label((step || into).from)} has no " \
                       "requires_green_ci in the workflow, its Approve asks no CI: approve without force"
      end
      return move(id, column: step.to, by: by, approval: true, force: force) if step

      approve_in_place(c, b, into, by, force: force)
    end

    # A card sitting UNAPPROVED in a gate an approval step leads into (the operator dragged it there from anywhere but
    # the step's gate — a plain move): agents never leave a gate unapproved, so the operator approves it where it sits.
    # The same question as the step's Approve (green CI), the same approval, activity line and ping; no move.
    def approve_in_place(c, b, step, by, force: false)
      raise Invalid, "card ##{c[:id]} is archived" if c[:archived_at]
      if c[:approved_at]
        raise Invalid, "card ##{c[:id]} is already approved (by #{c[:approved_by]}) in #{b.label(c[:column])}"
      end

      by = who!(by)
      green = force ? nil : green_ci!(c, b, step)
      rebase = green && rebase_of!(c, green)
      unasked = force && b.green_ci_step?(step)
      @db.transaction do
        cards.where(id: c[:id]).update(approved_at: @clock.call, approved_by: by, updated_at: @clock.call)
        log(c[:id], "approve",
            "#{approval_note(b, step)} (approved in #{b.label(c[:column])})#{' (forced: CI not asked)' if unasked}", by)
        rebase_mark!(c, green, rebase, by) if rebase
        enqueue_ping(c, "approve", by, approve_ping_body(step, (CI_FORCED if unasked), rebase))
      end
      card(c[:id])
    end

    # ── needs rebase (card #497): an approval on a PR that conflicts with its base ────────────────────────────────
    #
    # The operator: "Approve merge should proceed with rebase and merge!" The ci: port's green answer to an approval
    # step may carry rebase: {state:, base:, base_sha:} — the PR's checks are green and nothing else refuses it, but it
    # conflicts with its base (the base moved while the card waited). The approval is accepted, the card is marked
    # needs rebase (card JSON `needs_rebase`) and the approve ping tells the owner to rebase onto that base, re-run CI and
    # merge only on green. While marked, the agent's onward move out of the column (the next handoff, the move to done)
    # is refused until the step's checks, asked live, answer green with no rebase: — then the mark clears and the move
    # goes on. The notifier's watch pass clears it the same way (Store#rebase_watch_pass). Any move out of the column
    # (the operator's withdraw / rework, the agent back to a working column) ends it.

    # A green answer's rebase: as the engine keeps it ({"state", "base", "base_sha"}), nil when none; a malformed one is
    # the port's error, refused — never approved as if clean.
    def rebase_of!(c, pr)
      r = pr[:rebase] or return nil
      bad = !r.is_a?(Hash) || %i[state base base_sha].any? { |k| !r[k].is_a?(String) || r[k].strip.empty? }
      raise Invalid, "card ##{c[:id]}: the CI port answered rebase: #{r.inspect} — want {state:, base:, base_sha:}" if bad

      { "state" => r[:state], "base" => r[:base], "base_sha" => r[:base_sha] }
    end

    def rebase_mark!(c, pr, rebase, by)
      now = @clock.call
      # ref = the card's nth mark (the unique key): two approvals racing for the same n — the loser's insert, in its
      # own savepoint, retries with the next one (a third collision in a row is raised, never swallowed)
      tries = 0
      begin
        @db.transaction(savepoint: true) do
          n = (watches_t.where(card_id: c[:id], kind: REBASE).max(:ref) || 0) + 1
          watches_t.insert(card_id: c[:id], kind: REBASE, ref: n, pr: pr[:number], state: JSON.generate(rebase),
                           pinged_at: c[:owner_session] && now, created_at: now)
        end
      rescue Sequel::UniqueConstraintViolation
        tries += 1
        retry if tries < 3
        raise
      end
      log(c[:id], "gate", "needs rebase: #{rebase_what(pr[:number], rebase)} — approved; the agent rebases, re-runs CI " \
                          "and merges once it is green (approved by #{by})", @config.system_author)
    end

    def rebase_what(number, r)
      pr = number ? "PR ##{number}" : "its PR"
      "#{pr} #{r['state'] == 'conflicts' ? 'conflicts' : r['state']} with #{r['base']} (#{r['base_sha'][0, 7]})"
    end

    # marker = CI_NOT_ASKED (dragged) / CI_FORCED (Force) / nil (CI asked); only an asked approval carries a rebase
    def approve_ping_body(step, marker, rebase)
      return "#{step.from} #{marker}" if marker
      return "#{step.from} #{REBASE}:#{JSON.generate(rebase)}" if rebase

      step.from
    end

    def rebase_instructions(c, b, step, r)
      onward = if step.final
                 "then move the card to #{b.label(step.then)} with kanban_move id=#{c[:id]} column=#{step.then}"
               elsif step.then && b.gate?(step.then)
                 "then hand the card to #{b.label(step.then)} with kanban_handoff id=#{c[:id]} column=#{step.then}"
               elsif step.then
                 "then move the card to #{b.label(step.then)} with kanban_move id=#{c[:id]} column=#{step.then}"
               else
                 "then carry on"
               end
      "approved: rebase onto #{r['base']} (#{r['base_sha'][0, 7]}), re-run CI, then merge. The PR #{r['state']} with " \
        "#{r['base']}: merge #{r['base']} in, resolve every conflict keeping both sides' intent, run the gates and a " \
        "reviewer on the resolution, push, and merge only once CI is green on the new head; #{onward}. " \
        "The board holds the card in #{b.label(step.to)} until the step's checks are green with no conflict. A " \
        "conflict you cannot resolve: kanban_ask on card ##{c[:id]} naming the conflicting files — never a silent hold."
    end

    # {card id => the open mark} ({"pr", "state", "base", "base_sha", "at"}) for the given ids
    def rebase_marks(ids)
      watches_t.where(card_id: ids, kind: REBASE, commented_at: nil).order(:id).all.to_h do |w|
        [w[:card_id], JSON.parse(w[:state]).merge("pr" => w[:pr], "at" => w[:created_at], "id" => w[:id])]
      end
    end

    def close_rebase(c, why, by)
      mark = c[:needs_rebase] or return
      # once: a move that cleared it in its own check (rebase_hold!) holds the card as it was read before
      return false if watches_t.where(id: mark["id"], commented_at: nil).update(commented_at: @clock.call).zero?

      log(c[:id], "gate", "needs rebase cleared: #{why}", by)
      true
    end

    # The step's checks asked live for a marked card: green with no rebase: → the mark clears (→ true); anything else
    # → the hold's words (a String). The port down → its words.
    def rebase_cleared(c, b, ping: false)
      step = b.approval_into(c[:column])
      return "#{b.label(c[:column])} is no approval step's column any more" unless step

      pr = begin
        @ci.approval_checks(c, step.to_h)
      rescue Delivery::Unavailable => e
        return "CI state unknown — #{e.message}"
      end
      return "no PR whose checks could be read" if pr.nil?
      return hold_reason(pr) unless pr[:state] == "success"
      return "#{rebase_what(pr[:number], rebase_of!(c, pr))} — rebase it and re-run CI" if pr[:rebase]

      head = pr[:head] ? " at #{pr[:head][0, 7]}" : ""
      @db.transaction do
        cleared = close_rebase(c, "CI green#{head} and no conflict with #{c[:needs_rebase]['base']}",
                               @config.system_author)
        # the watch pass's clear wakes the owner (it may be waiting on it to merge); a clear at the agent's own move
        # needs no ping — the agent is acting
        rebase_cleared_ping(c, b, step, pr) if cleared && ping
      end
      true
    end

    def rebase_cleared_ping(c, b, step, pr)
      ref = pr[:number] ? "PR ##{pr[:number]}" : "its PR"
      green = pr[:head] ? "CI green on #{pr[:head][0, 7]} — merge now" : "the merge's CI is green — carry on"
      onward = if step.then && b.gate?(step.then)
                 ", then hand the card to #{b.label(step.then)} with kanban_handoff id=#{c[:id]} column=#{step.then}"
               elsif step.then
                 ", then move the card to #{b.label(step.then)} with kanban_move id=#{c[:id]} column=#{step.then}"
               else
                 ""
               end
      enqueue_ping(c.merge(column_label: b.label(c[:column])), "rebase_cleared", @config.system_author,
                   "needs rebase cleared on #{ref} of card ##{c[:id]} \"#{c[:title]}\" (#{c[:project_slug]}): " \
                   "#{green}#{onward}.")
    end

    # Every open mark asked again (notifier watch pass) → [[card_id, :cleared | "held: <why>"], …].
    def rebase_watch_pass
      return [] unless @ci.respond_to?(:approval_checks) # a mark is set only on a green answer of the port

      ids = watches_t.where(kind: REBASE, commented_at: nil).select_map(:card_id).uniq
      return [] if ids.empty?

      cards.where(id: ids, archived_at: nil, on_hold_at: nil).order(:id).all.map do |row|
        c = card(row[:id])
        got = begin
          rebase_cleared(c, board_of(c[:project_slug]), ping: true)
        rescue Invalid => e # a malformed answer is the port's error: said, the mark kept
          e.message
        end
        [c[:id], got == true ? :cleared : "held: #{got}"]
      end
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
        raise Invalid, "card ##{c[:id]} is on hold: release it first — no session owns a card on hold" if on_hold?(c)

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
      raise Invalid, "no card #{id}" if on_hold?(c) # out of every agent's sight (Store#hold)
      blocked!(board_of(c[:project_slug]), nil, c[:blocked_by], "card ##{c[:id]}", claim: true)
      owner_session!(session.to_s.strip, socket) # before the assignee lands: a refused claim changes nothing
      reg = open_session(session.to_s.strip)
      if reg && reg[:project_slug] != c[:project_slug]
        raise Denied, "session #{reg[:session]} is registered for #{reg[:project_slug]}: " \
                      "it cannot own a card on #{c[:project_slug]}'s board — " \
                      "leave it to #{c[:project_slug]}'s sessions"
      end
      parked_work!(board_of(c[:project_slug]), c, "claims")
      if lead_reg?(reg) || lead_agent?(assignee)
        raise Denied, "#{lead_reg?(reg) ? "session #{reg[:session]}" : assignee} is a lead and cannot claim card " \
                      "##{c[:id]}: #{NO_LEAD_ASSIGNEE}"
      end
      update(c[:id], { "assignee" => assignee }, by: assignee)
      set_owner(c[:id], session: session, socket: socket, by: assignee)
    end

    # only the operator moves a card out of a parked column (Backlog), whatever the workflow says: an agent's
    # move out of one is refused before anything else is read (a reorder inside it stays; `column` nil = a named
    # transition, always a way out). The workflow cannot open it either (Board#operator_exit!).
    def parked_exit!(b, c, column)
      return unless b.operator_exit?(c[:column])
      return if column && column.to_s == c[:column]

      raise Denied, "card ##{c[:id]} sits in #{b.label(c[:column])}: only the operator moves a card out of it — agents " \
                    "never prioritise nor start parked work (kanban_ask on a card you own if it should be worked)"
    end

    # no agent works a card in a parked column: no claim, no spawn for it, no adoption (HostConfig refuses a
    # parked type in `takes`). `what` = the act refused.
    def parked_work!(b, c, what)
      return unless b.operator_exit?(c[:column])

      raise Denied, "card ##{c[:id]} sits in #{b.label(c[:column])}: no agent #{what} a parked card — only the operator " \
                    "moves it out, and its work starts there"
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
      c ||= project_cards.where(owner_session: session, archived_at: nil, on_hold_at: nil)
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
    def owner_sessions
      cards.where(archived_at: nil, on_hold_at: nil).exclude(owner_session: nil).distinct.select_map(:owner_session)
    end
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
    # for_cards: a SPAWN registration (kanban_spawn: the lead starts a worker for a card) owns exactly these cards
    # (compare-and-set on the owner being `from_owner` — the lead that spawns it, or nobody: a card somebody else took
    # meanwhile is not taken) instead of adopting the type's `takes` columns.
    #
    # LEAD-FIRST: a session of a type `under` a lead type is registered only with `lead_id` = the OPEN
    # registration of that lead type on the same board (the caller checked it is live) — else Denied, nothing written;
    # the row carries needs_lead = 1 and the DB refuses it without a lead_id (Schema v12's CHECK). A LEAD registration
    # becomes the lead of the board's open `under` sessions a lead before it left behind; with `key_to:` (Team#start,
    # the host's launch path only) it mints a random lead key, stores only its SHA-256 and hands the key to that
    # callable — never in the returned Hash, so no JSON answer, dump or log of a registration can carry it. A lead
    # registered without key_to (kanban_register: a session started by hand) has no key and cannot kanban_spawn.
    def register_session(session:, project:, type:, by:, launcher: nil, socket: "default", for_cards: nil, lead_id: nil,
                         from_owner: nil, key_to: nil)
      board!(project)
      t = @config.agent_type(type)
      l = t.registered_launcher!(launcher) # a launch / spawn passes the launcher it resolved; by hand: named or the only one
      s = session.to_s.strip
      owner_session!(s, socket)
      by = who!(by)
      not_registered!(s)
      lead = lead_row!(t, project, lead_id)
      if for_cards && @config.lead_type?(t)
        raise Denied, "a #{t.key} session is not started for a card: #{NO_LEAD_ASSIGNEE}"
      end
      agent = @config.agent_name(t, session: s, slug: project)
      now = @clock.call
      adopted = []
      Array(for_cards).each { |cid| (c = card!(cid)) && parked_work!(board_of(c[:project_slug]), c, "spawns for") }
      key = key_to && @config.lead_type?(t) ? SecureRandom.hex(32) : nil
      @db.transaction do
        id = sessions_t.insert(session: s, socket: socket.to_s, project_slug: project, type_key: t.key, launcher_key: l,
                               agent_name: agent, launched_by: by, launched_at: now, last_seen_at: nil,
                               lead_id: lead&.dig(:id), needs_lead: t.under ? 1 : 0,
                               lead_key_digest: key && Digest::SHA256.hexdigest(key))
        if key
          orphans = sessions_t.where(project_slug: project, ended_at: nil, needs_lead: 1).exclude(id: id)
          orphans.update(lead_id: id)
        end
        if for_cards
          Array(for_cards).each do |cid|
            n = cards_t_cas(cid, project, s, socket, agent, now, from: from_owner)
            next if n.zero?

            via = lead ? " by the lead #{lead[:agent_name]}" : ""
            log(cid, "owner", "spawned for this card#{via}: #{agent} — session #{s} (#{t.key}) started for #{project}", by)
            relay_undelivered(cid)
            adopted << cid
          end
        elsif (takes = board_of(project).takes_columns(t)).any?
          leads = @config.lead_type?(t) # a lead owns what it adopts (routing) and assigns none of it to itself
          by_priority(live(project).where(column: takes, owner_session: nil).order(:column, :position, :id).all).each do |c|
            cards.where(id: c[:id]).update(owner_session: s, owner_socket: socket.to_s, owner_missing_since: nil,
                                           assignee: leads ? nil : agent, updated_at: now)
            wait = leads ? " · waiting for a worker" : ""
            log(c[:id], "owner", "adopted by #{agent} — session #{s} (#{t.key}) registered for #{project}#{wait}", by)
            relay_undelivered(c[:id])
            adopted << c[:id]
          end
        end
        { id: id, session: s, socket: socket.to_s, type: t.key, launcher: l, agent: agent, project: project,
          adopted: adopted, lead: lead && lead[:session], }.compact
      end.tap { key_to&.call(key) }
    end

    # The lead registration a session of type `t` is registered under: nil for a type that is under none (a lead_id
    # given then is refused); else the OPEN registration `lead_id` of t.under on the same board — none named or not that
    # → Denied (no lead, no session).
    def lead_row!(t, project, lead_id)
      unless t.under
        raise Invalid, "agent type #{t.key} runs under no lead — no lead_id" unless lead_id.nil?

        return nil
      end
      r = lead_id && sessions_t.where(id: lead_id, ended_at: nil).first
      return r if r && r[:project_slug] == project.to_s && r[:type_key] == t.under

      raise Denied, "no #{t.under} session runs for #{project}: a #{t.key} session runs only under the board's " \
                    "#{t.under} — launch the #{t.under} first (lead-first boards)"
    end

    # The board's RUNNING session of a lead type (`type` is under it): {row}, or Denied with what to do — the only
    # lead a session of `type` may run under (Api#launch, kanban_spawn, kanban_register).
    def running_lead!(type:, project:, live:, grace:)
      t = @config.agent_type(type)
      raise Invalid, "agent type #{t.key} runs under no lead" unless t.under

      running_lead(t.under, project, live: live, grace: grace) ||
        raise(Denied, "no #{t.under} session runs for #{project}: a #{t.key} session runs only under the board's " \
                      "#{t.under} — launch the #{t.under} first (lead-first boards)")
    end

    def running_lead(lead_type, project, live:, grace:)
      running_sessions(live, grace: grace).reverse.find do |r|
        r[:type_key] == lead_type && r[:project_slug] == project.to_s
      end
    end

    # The lead whose key this is: the OPEN registration of `session`, of a lead type, whose stored digest matches —
    # else Denied (a worker, a stale key, another session's key). The compare is on digests, in constant time.
    def lead_by_key!(session:, key:)
      r = open_session(session)
      ok = r && !r[:lead_key_digest].nil? && key.is_a?(String) && !key.empty? &&
           OpenSSL.fixed_length_secure_compare(r[:lead_key_digest], Digest::SHA256.hexdigest(key))
      return r if ok

      raise Denied, "#{session} is not a lead this host started: only the board's lead, started from the Launch bar, " \
                    "starts its team (its key, held by the host's launcher, does not match)"
    end

    # A registration of the same type for the same board after this one (a lead launched again since).
    def registered_since?(r)
      sessions_t.where(project_slug: r[:project_slug], type_key: r[:type_key]).where(Sequel[:id] > r[:id]).any?
    end

    # The board's lead now (lead-first boards): nil on a host with no lead type; else {type, label, launch_label,
    # session (running, or nil), ended: {session, reason, at, old_name} (the newest lead registration when none runs,
    # or nil)} — the board says "no lead: press Launch" from it. old_name = the name a launch of the type gets NOW
    # (HostConfig#session_name) when the ended session's name is not one of those (registered under an earlier
    # session_name: the board marks it old, never shows it as if it were today's lead), else nil.
    def lead_state(project, live:, grace:)
      lt = @config.lead_types.first or return nil

      r = running_lead(lt.key, project, live: live, grace: grace)
      last = !r && sessions_t.where(project_slug: project.to_s, type_key: lt.key).exclude(ended_at: nil)
                             .order(Sequel.desc(:ended_at), Sequel.desc(:id)).first
      ended = if last
                { session: last[:session], reason: last[:end_reason], at: iso(last[:ended_at]),
                  old_name: old_session_name(lt, project, last[:session]), }
              end
      { type: lt.key, label: lt.label, launch_label: lt.launch_label, session: r && r[:session], ended: ended }
    end

    # nil when `session` is a name a launch of `type` on `project` gets now (the base, or the base the host made unique
    # with a suffix); else that base
    def old_session_name(type, project, session)
      base = @config.session_name(type, slug: project)
      session.to_s.start_with?(base) ? nil : base
    end

    # The boards whose lead ENDED for any reason but the operator's stop (OPERATOR_STOP) — gone from the host's session
    # list, ended by the watchdog, ended by the agent or a host — within LAUNCH_FAILURE_WINDOW_S and no lead of that type
    # registered since: the operator must press Launch (nothing relaunches it). A start that failed is a launch
    # failure (#launch_failures), not listed twice. → [{id, session, project, type, launcher, ended, reason}], newest
    # first.
    def lead_ends(slugs)
      return [] if @config.lead_types.empty?

      since = @clock.call - LAUNCH_FAILURE_WINDOW_S
      types = @config.lead_types.map(&:key)
      sessions_t.where(project_slug: slugs.to_a, type_key: types).exclude(ended_at: nil)
                .exclude(end_reason: OPERATOR_STOP).exclude(Sequel.like(:end_reason, "#{START_FAILED}%"))
                .where { ended_at >= since }
                .order(Sequel.desc(:ended_at), Sequel.desc(:id))
                .all
                .uniq { |r| [r[:project_slug], r[:type_key]] }
                .reject { |r| registered_since?(r) }
                .first(LAUNCH_FAILURES_SHOWN)
                .map do |r|
        { id: r[:id], session: r[:session], project: r[:project_slug], type: r[:type_key], launcher: r[:launcher_key],
          ended: iso(r[:ended_at]), reason: r[:end_reason], }
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
        taken = takers.flat_map { |_, t| b.takes_columns(t) }.uniq
        # a missing assignee is filled from its alive registered owner in every watched column, with or without a
        # taker running (a worker-owned In progress card would otherwise keep no assignee while no lead runs)
        pool = live(slug).where(column: (taken + b.watched_columns).uniq)
        pool = pool.where(id: only) if only
        by_priority(pool.order(:column, :position, :id).all).each do |c|
          owner_ok = c[:owner_session] && alive.(c[:owner_session])
          next if owner_ok && !c[:assignee].to_s.strip.empty?

          own = owner_ok && rows.find { |r| r[:session] == c[:owner_session] }
          next if own && lead_reg?(own) # the lead owns it and waits for a worker: never its assignee (card 612)

          if owner_ok && own
            r = own
            why = "assignee filled from its owner session #{r[:session]}"
          elsif owner_ok
            next # an alive owner the board never registered: the operator's choice, left alone
          else
            next unless taken.include?(c[:column])

            by_load = ->(x) { [cards.where(project_slug: slug, owner_session: x[:session], archived_at: nil).count, x[:id]] }
            r, t = takers.select { |_, ty| b.takes_columns(ty).include?(c[:column]) }.min_by { |x, _| by_load.(x) } || next
            why = if c[:owner_session]
                    "owner session #{c[:owner_session]} is not alive — handed to session #{r[:session]} (#{t.key})"
                  else
                    "session #{r[:session]} (#{t.key}) takes #{b.label(c[:column])} cards"
                  end
          end
          leads = lead_reg?(r)
          @db.transaction do
            cards.where(id: c[:id]).update(owner_session: r[:session], owner_socket: r[:socket], owner_missing_since: nil,
                                           assignee: leads ? nil : r[:agent_name], updated_at: now)
            if leads
              log(c[:id], "owner",
"owner session #{r[:session]} (#{r[:agent_name]}, the lead) — #{why} · waiting for a worker", by)
            else
              log(c[:id], "owner", "assigned to #{r[:agent_name]} — #{why}", by)
            end
            relay_undelivered(c[:id]) if c[:owner_session] != r[:session]
            enqueue_ping(card(c[:id]), leads ? "lead_dispatch" : "assigned", by, leads ? "waits" : "assigned")
          end
          changed << c[:id]
        end
      end
      changed
    end

    def cards_t_cas(cid, project, session, socket, agent, now, from: nil)
      cards.where(id: cid, project_slug: project, owner_session: from, archived_at: nil)
           .update(owner_session: session, owner_socket: socket.to_s, owner_missing_since: nil, assignee: agent,
                   updated_at: now)
    end

    # A registration ends: the host's launch failed, the watchdog saw the session gone, or the agent said goodbye.
    # Its cards are NOT released here — the watchdog's grace rule does that (a session may be gone for a moment).
    def end_session(session, reason:, by:)
      open = open_session(session.to_s) or raise Invalid, "session #{session} is not registered (or already ended)"
      sessions_t.where(id: open[:id]).update(ended_at: @clock.call, end_reason: reason.to_s, last_seen_at: open[:last_seen_at])
      tell_lead_session_ended(open, reason.to_s, by)
      open[:id]
    end

    # A launch or a spawn whose start failed ends its registration with this reason prefix (Team#start).
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

    # ── terminals: a host's live view of an agent session's screen ─────────────────────────────────────────────────
    # The engine draws no terminal; it answers which sessions work on a card and records who opened / drove one.

    # The open registrations working on a card: its owner session, then every session acting as its assignee (the
    # registration's agent name) — each once, owner first. A card nobody registered works on → []. Sessions only: the
    # host checks each is live.
    def card_sessions(id)
      c = card!(id)
      owner = c[:owner_session] && sessions_t.where(ended_at: nil, session: c[:owner_session],
                                                     socket: c[:owner_socket] || "default").first
      agents = c[:assignee].to_s.strip.empty? ? [] : sessions_t.where(ended_at: nil, agent_name: c[:assignee]).order(:id).all
      [owner, *agents].compact.uniq { |r| [r[:session], r[:socket]] }.map { |r| session_json(r).merge(owner: r.equal?(owner)) }
    end

    # The operator opened, took or released control of a registered session's terminal: one "terminal" event, by them,
    # on every card the session works on (not archived) — the cards it owns and the cards assigned to its agent name,
    # the same two links card_sessions follows — the audit trail. A session with no open registration is refused (a
    # host shows terminals of registered sessions only). → the card ids it was logged on (works on none → []).
    def terminal_event(session:, by:, text:, socket: "default")
      reg = sessions_t.where(ended_at: nil, session: session.to_s, socket: socket.to_s).first
      raise Denied, "session #{session} (socket #{socket}) has no open registration: no terminal" unless reg

      line = text.to_s.strip
      raise Invalid, "terminal event text is required" if line.empty?

      by = who!(by)
      mine = Sequel.&({ owner_session: reg[:session], owner_socket: reg[:socket] })
      mine = Sequel.|(mine, { assignee: reg[:agent_name] }) unless reg[:agent_name].to_s.strip.empty?
      ids = cards.where(archived_at: nil, on_hold_at: nil).where(mine).order(:id).select_map(:id)
      @db.transaction { ids.each { |cid| log(cid, "terminal", "#{line} · session #{reg[:session]}", by) } }
      ids
    end

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

    # Who is at work on a project's cards RIGHT NOW, from the host's live reading of its sessions.
    # live: {session name => {state:, elapsed_s:, card:, …}} (the host's SessionLive; string or symbol keys). Only an OPEN
    # registration of this project whose live state is working or blocked counts, on a card of this project when:
    #   tool     — the tool it runs now names the card (live `card`);
    #   activity — its agent name wrote on the card (a comment, a move, an edit…) since its current turn began (now −
    #              elapsed_s; no elapsed reading → this rule says nothing, never a guessed window);
    #   blocked  — stopped on a dialog / question (state blocked): the card it last wrote on since it registered — the
    #              one it waits on (the agent the operator most needs to see).
    # → {card id => [{session, agent, type, why}]} (tool before activity); a session that stops working, or ends, is gone
    # from the next answer. Ownership alone is not presence: the host shows the assignee's face anyway.
    def presence(slug, live:)
      now = @clock.call
      regs = sessions_t.where(ended_at: nil, project_slug: slug.to_s).order(:launched_at, :id).all
      at_work = regs.filter_map do |r|
        l = live[r[:session]] or next
        l = l.transform_keys(&:to_sym)
        %w[working blocked].include?(l[:state].to_s) ? [r, l] : nil
      end
      return {} if at_work.empty?

      ids = Set.new(live(slug.to_s).select_map(:id))
      out = Hash.new { |h, k| h[k] = [] }
      at_work.each do |r, l|
        who = { session: r[:session], agent: r[:agent_name], type: r[:type_key] }
        tool_card = l[:card].is_a?(Integer) && ids.include?(l[:card]) ? l[:card] : nil
        out[tool_card] << who.merge(why: "tool") if tool_card
        if l[:state].to_s == "blocked"
          last = activity_t.where(author: r[:agent_name], card_id: ids.to_a).where { created_at >= r[:launched_at] }
                           .reverse(:created_at, :id).get(:card_id)
          out[last] << who.merge(why: "blocked") if last && last != tool_card
        end
        next unless l[:elapsed_s].is_a?(Integer)

        activity_t.where(author: r[:agent_name], card_id: ids.to_a).where { created_at >= now - l[:elapsed_s] }
                  .distinct.select_map(:card_id).each do |cid|
          out[cid] << who.merge(why: "activity") unless cid == tool_card
        end
      end
      # blocked, then tool, then activity; the session name breaks ties, so the order holds between polls
      out.transform_values do |ws|
        ws.uniq { |w| w[:session] }.sort_by { |w| [%w[blocked tool activity].index(w[:why]), w[:session]] }
      end
    end

    # Reconcile the registry with the host's LIVE session names: a registered session not in the list is ended as gone
    # — unless it was registered less than `grace` seconds ago (a launch takes a moment to appear). Live ones get
    # last_seen_at. → the ended rows' sessions.
    GONE = "gone from the host's session list" # the session ended on its own (killed, crashed, closed) — Store#lead_ends
    # The end reason of the operator's Stop (the host passes it to #end_session): the one lead end that is not an alert.
    OPERATOR_STOP = "stopped by the operator"
    def sessions_sync(live, grace:)
      now = @clock.call
      gone = []
      ended = []
      sessions_t.where(ended_at: nil).all.each do |r|
        if live.include?(r[:session])
          sessions_t.where(id: r[:id]).update(last_seen_at: now)
        elsif now - r[:launched_at] >= grace
          sessions_t.where(id: r[:id]).update(ended_at: now, end_reason: GONE)
          gone << r[:session]
          ended << r
        end
      end
      # after every row is ended: a lead gone in this same pass hears nothing
      ended.each { |r| tell_lead_session_ended(r, GONE, @config.system_author) }
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
        ended: iso(r[:ended_at]), end_reason: r[:end_reason], lead_id: r[:lead_id],
        live: live.nil? ? nil : live.include?(r[:session]),
        cards: cards.where(owner_session: r[:session], archived_at: nil).count, }
    end

    # The launcher a session of `type` starts with: under a lead → the lead's (another one asked for explicitly is
    # refused with who leads, never silently swapped); else the asked one, or the type's only launcher.
    def launcher_for!(type:, asked:, lead: nil)
      t = @config.agent_type(type)
      return t.launcher!(asked) unless lead

      a = asked.to_s
      unless a.empty? || a == lead[:launcher_key]
        raise Denied, "#{t.key} sessions of #{lead[:project_slug]} run #{lead[:launcher_key]}, the launcher of their " \
                      "#{lead[:type_key]} session #{lead[:session]} (agent_types[#{t.key}].under) — #{a} refused"
      end
      t.launcher!(lead[:launcher_key])
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
      project_cards.where(owner_session: session.to_s, archived_at: nil, on_hold_at: nil).all.each do |c|
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
             when "comment", OPERATOR_COMMENT
               clip = body.length > PING_BODY ? "#{body[0, PING_BODY]}…" : body
               "#{tag} New comment on card ##{c[:id]} \"#{c[:title]}\" (#{b.label(c[:column])}, #{c[:project_slug]}) " \
               "by #{author}:\n\n#{clip}\n\n" \
               "Read the card with kanban_card id=#{c[:id]}, act on it, and reply with kanban_comment."
             when "ci_idle", "pr_closed", "progress", "rebase_cleared"
               "#{tag} #{body}"
             when "lead_dispatch"
               "#{tag} Card ##{c[:id]} \"#{c[:title]}\" (#{b.label(c[:column])}, #{c[:project_slug]}) " \
                 "#{body == "waits" ? 'waits for a worker' : body}. #{DISPATCH_ACTION}"
             when "worker_assigned"
               "#{tag} Card ##{c[:id]} \"#{c[:title]}\" (#{b.label(c[:column])}, #{c[:project_slug]}) " \
                 "is yours: #{body} gave it to you. Read it with kanban_card id=#{c[:id]} and start the work."
             when "assigned"
               "#{tag} Card ##{c[:id]} \"#{c[:title]}\" (#{b.label(c[:column])}, #{c[:project_slug]}) " \
               "is assigned to you — your session takes #{b.label(c[:column])} cards. " \
               "Read it with kanban_card id=#{c[:id]} and start the work."
             when "approve"
               from, how = body.split(" ", 2)
               step = b.approval_from(from)
               # dragged along the step: the green-CI gate was not asked, so the owner reads the PR's checks first
               unasked = case how
                         when CI_NOT_ASKED then " #{DRAGGED_NOTE}"
                         when CI_FORCED then " #{FORCED_NOTE}"
                         else ""
                         end
               rebase = how&.start_with?("#{REBASE}:") ? JSON.parse(how.delete_prefix("#{REBASE}:")) : nil
               if rebase
                 "#{tag} #{author} APPROVED card ##{c[:id]} \"#{c[:title]}\" (#{c[:project_slug]}) " \
                   "— it is in #{b.label(step.to)}, marked needs rebase. #{rebase_instructions(c, b, step, rebase)}"
               elsif step.final
                 # dragged: the merge waits for green checks (a red or unread one is not merged)
                 merge = unasked.empty? ? "Merge it now" : "Merge it once its checks are green (red: do not merge, say so)"
                 "#{tag} #{author} APPROVED card ##{c[:id]} \"#{c[:title]}\" (#{c[:project_slug]}) " \
                   "— it is in #{b.label(step.to)}.#{unasked} #{merge}, then move the card to #{b.label(step.then)} " \
                   "with kanban_move id=#{c[:id]} column=#{step.then} and post the merge commit/PR with kanban_comment." \
                   "#{approved_queue_note(c, b)}"
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
                 # CI not asked (dragged / forced): the next step (a merge, a deploy) waits for green checks too
                 wait = "Take the next step only once the PR's checks are green (red: do not take it, say so)"
                 now = unasked.empty? ? "Do the next step now" : wait
                 "#{tag} #{author} APPROVED card ##{c[:id]} \"#{c[:title]}\" (#{c[:project_slug]}) " \
                   "— #{went}.#{unasked} " \
                   "#{now}#{on}, and post what you did with kanban_comment.#{approved_queue_note(c, b)}"
               end
             else
               "#{tag} #{author} #{body} card ##{c[:id]} \"#{c[:title]}\" (#{c[:project_slug]}). " \
               "Read it with kanban_card id=#{c[:id]} and continue."
             end
      # one pending ping per card+session: a burst of comments arrives as one message, not a stream of prompts
      queue_ping(c[:id], c[:owner_session], c[:owner_socket] || "default", text, reason)
    end

    # A burst joins the newest pending row nothing may have been typed from (attempts 0). Any other may already sit in the
    # session's input, where an engine that reads its input back knows it by its exact text: its text never changes. A
    # burst past MAX_PING_TEXT, or one event longer than that, opens the next rows: nothing is cut.
    def queue_ping(card_id, session, socket, text, reason)
      pending = pings_t.where(card_id: card_id, session: session, status: "pending", attempts: 0)
                       .order(Sequel.desc(:id)).first
      joined = pending && "#{pending[:text]}\n\n---\n\n#{text}"
      if joined && joined.length <= MAX_PING_TEXT
        # the row takes the rank of the most urgent event it now carries
        stronger = PING_RANKS.fetch(reason, PING_RANK_REST) < PING_RANKS.fetch(pending[:reason], PING_RANK_REST)
        pings_t.where(id: pending[:id]).update(text: joined, reason: stronger ? reason : pending[:reason])
        return
      end
      ping_parts(text).each do |part|
        pings_t.insert(card_id: card_id, session: session, socket: socket, text: part, reason: reason, status: "pending",
                       created_at: @clock.call)
      end
    end

    # A text past MAX_PING_TEXT in parts; their join is the text. Cut after a list separator or a line, else at whitespace
    # that does not sit between a word and the "#" after it (a "card #N" stays whole); a word longer than a part is cut
    # where it must be.
    def ping_parts(text)
      parts = []
      rest = text
      while rest.length > MAX_PING_TEXT
        cut = ping_cut(rest)
        parts << rest[0..cut]
        rest = rest[(cut + 1)..]
      end
      (parts << rest).reject { |part| part.strip.empty? }
    end

    # the index of the next part's last character, within MAX_PING_TEXT of the start of `rest`
    def ping_cut(rest)
      sep = rest.rindex(/[,\n]\s/, MAX_PING_TEXT - 2)
      return sep + 1 if sep

      space = rest.rindex(/(?<![\w\s])\s|\s(?!\s*#)/, MAX_PING_TEXT - 1)
      space.nil? || space.zero? ? MAX_PING_TEXT - 1 : space
    end

    # ── the running lead hears about its workers ───────────────────────────────────────
    # One ping per event — ask, handoff, block, session end, the progress watch's first step — never per comment. Only a
    # session registered UNDER a lead has one; none when the lead itself acted, or its registration ended. A row of its
    # own: it never waits for the worker's turn, and a worker's pending pings never hold it back (next_pings).
    LEAD_PINGS = %w[lead_ask lead_handoff lead_block lead_session_end lead_progress lead_dispatch].freeze
    OPERATOR_COMMENT = "operator_comment"
    OPERATOR_PINGS = ["answer", "approve", "move", "relay", OPERATOR_COMMENT].freeze
    # next_pings' order: a row that may sit in the input, the operator's rows, lead events, the rest
    PING_RANK_TYPED = 0
    PING_RANK_REST = 3
    PING_RANKS = OPERATOR_PINGS.to_h { |r| [r, 1] }.merge(LEAD_PINGS.to_h { |r| [r, 2] }).freeze

    def lead_of(reg)
      reg && reg[:lead_id] && sessions_t.where(id: reg[:lead_id], ended_at: nil).first
    end

    def tell_lead(c, event, by, what)
      return if c[:on_hold_at] || c[:owner_session].to_s.empty?

      reg = sessions_t.where(ended_at: nil, session: c[:owner_session], socket: c[:owner_socket] || "default").first
      lead = lead_of(reg)
      return if lead.nil? || [lead[:session], lead[:agent_name]].include?(by)

      text = "[#{@config.system_author}] Your worker #{reg[:session]}: card ##{c[:id]} \"#{c[:title]}\" " \
             "(#{c[:project_slug]}) #{what}. Read it with kanban_card id=#{c[:id]} and act: #{LEAD_ACTIONS.fetch(event)}"
      queue_ping(c[:id], lead[:session], lead[:socket], text, "lead_#{event}")
    end

    LEAD_ACTIONS = {
      "ask" => "the card waits for the operator; keep the rest of the board moving.",
      "block" => "the card waits for the outside world; clear the blocker if you can.",
      "handoff" => "check the worker has its next step; the gate waits for the operator.",
      "progress" => "nudge the worker now, or respawn it if it is stuck.",
    }.freeze

    # One ping for the session, on its first open card, naming all of them. A session that holds none needs no action.
    def tell_lead_session_ended(reg, reason, by)
      lead = lead_of(reg)
      return if lead.nil? || [lead[:session], lead[:agent_name]].include?(by)

      b = board_of(reg[:project_slug])
      held = by_priority(cards.where(owner_session: reg[:session], owner_socket: reg[:socket], archived_at: nil,
                                     on_hold_at: nil).order(:id).all.reject { |c| b.terminal?(c[:column]) })
      return if held.empty?

      waits, spawn = held.partition { |c| needs_operator?(c) || (b.waiting.include?(c[:column]) && !agents_next_step?(c, b)) }
      names = ->(list) { list.map { |c| "card ##{c[:id]}" }.join(", ") }
      text = "[#{@config.system_author}] Your worker #{reg[:session]} ended (#{reason}) holding #{held.size} open " \
             "card(s) on #{reg[:project_slug]}."
      text += " Once each comes back to you, give it a worker with kanban_spawn: #{names.call(spawn)}." if spawn.any?
      text += " Waiting for the operator, no worker needed yet: #{names.call(waits)}." if waits.any?
      queue_ping(held.first[:id], lead[:session], lead[:socket], text, "lead_session_end")
    end

    def clip_ping(text) = text.length > PING_BODY ? "#{text[0, PING_BODY]}…" : text

    def pending_pings(limit = 20) = pings_t.where(status: "pending").order(:created_at, :id).limit(limit).all

    # What the Notifier tries this pass: ONE row per session, the later ones wait for it. Per session the order is
    # (a) a row something may already have been typed from: it is what sits in the composer;
    # (b) the operator's own rows (answer, approve, the operator's comment, move, relay);
    # (c) lead events; (d) the rest. Oldest first within each.
    # A row failed after the give-up releases the next. waiting_since = when this row could first be tried: the give-up
    # counts from there, never from a wait behind another row. Sessions holding an operator's row or a lead event come
    # first in the batch, then the oldest.
    def next_pings(limit = 20)
      queues = pings_t.where(status: "pending").order(:created_at, :id).all.group_by { |p| [p[:session], p[:socket]] }
      done = pings_t.where(session: queues.keys.map(&:first).uniq).exclude(done_at: nil).select_group(:session, :socket)
                    .select_append(Sequel.function(:max, :done_at).as(:last)).all
                    .to_h { |r| [[r[:session], r[:socket]], r[:last]] }
      prio = ping_priorities(queues.values.flatten)
      heads = queues.map do |key, rows|
        first = ping_order(rows, prio).first
        [rows.any? { |p| PING_RANKS.key?(p[:reason]) } ? 0 : 1,
         first.merge(waiting_since: [first[:created_at], done[key]].compact.max),]
      end
      heads.sort_by { |urgent, p| [urgent, prio[p[:card_id]], p[:created_at], p[:id]] }.first(limit).map(&:last)
    end

    # Within each class, the higher-priority card's row first, then the oldest. A row something may already
    # have been typed from stays first whatever its card's priority: it sits in the composer.
    def ping_order(rows, prio = ping_priorities(rows))
      rows.sort_by do |p|
        [p[:attempts].positive? ? PING_RANK_TYPED : PING_RANKS.fetch(p[:reason], PING_RANK_REST), prio[p[:card_id]],
         p[:created_at], p[:id],]
      end
    end

    # card id → priority rank, for the ping rows' cards (a card with no priority ranks last)
    def ping_priorities(rows)
      ranks = cards.where(id: rows.map { |p| p[:card_id] }.uniq).select_hash(:id, :priority)
      Hash.new { |h, id| h[id] = priority_rank(ranks[id]) }
    end

    # How many of its session's pending rows go before this one (next_pings' order).
    def pings_ahead(ping)
      rows = pings_t.where(status: "pending", session: ping[:session], socket: ping[:socket]).all
      ping_order(rows).index { |p| p[:id] == ping[:id] }.to_i
    end

    # tried: false = nothing was typed from this row (a dialog found first, the port's `typed: false`). Anything else may
    # have reached the session's input: `attempts` counts those, and such a row's text never changes (queue_ping).
    def ping_result(ping, status, error: nil, tried: true)
      pings_t.where(id: ping[:id]).update(status: status, error: error, attempts: Sequel[:attempts] + (tried ? 1 : 0),
                                          done_at: status == "pending" ? nil : @clock.call)
      return if status == "pending"

      note = if status == "sent"
               "pinged #{ping[:session]} (#{ping_word(ping[:reason])})"
             else
               "ping to #{ping[:session]} failed: #{error}"
             end
      log(ping[:card_id], "ping", note, @config.system_author)
    end

    def pings(card_id, limit = 10) = pings_t.where(card_id: Integer(card_id)).order(Sequel.desc(:id)).limit(limit).all

    def ping_json(p)
      out = { at: iso(p[:created_at]), done_at: iso(p[:done_at]), session: p[:session], reason: ping_word(p[:reason]),
              status: p[:status], error: p[:error], attempts: p[:attempts], }
      ahead = p[:status] == "pending" ? pings_ahead(p) : 0
      ahead.positive? ? out.merge(queued_behind: ahead) : out
    end

    # an operator's comment is ranked apart, and reads "comment" everywhere
    def ping_word(reason) = reason == OPERATOR_COMMENT ? "comment" : reason

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
      owned = project_cards.exclude(owner_session: nil).where(archived_at: nil, on_hold_at: nil).all
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
          reg = open_session(gone)
          sessions_t.where(session: gone, ended_at: nil).update(ended_at: now, end_reason: "gone (watchdog)")
          tell_lead_session_ended(reg, "gone (watchdog)", sys) if reg # before this card loses its owner: it is named
          cards.where(id: c[:id]).update(owner_session: nil, owner_socket: nil, owner_missing_since: nil, assignee: nil,
                                         updated_at: now)
          unassigned = c[:assignee] ? " #{c[:assignee]}" : ''
          log(c[:id], "watchdog", "session #{gone} is gone (#{now - c[:owner_missing_since]}s) — unassigned#{unassigned}", sys)
          # only the gone session's: the lead's ping about this very card still goes
          pings_t.where(card_id: c[:id], status: "pending", session: gone)
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

    # ── approval prefetch (a gate column's requires_green_ci): Approve never waits for a CI read ───────
    #
    # Every card the operator can Approve has that step's checks asked of the host's ci: port — at the handoff and on
    # every notifier watch pass — so a host that answers asynchronously (a poller holding the token, answering what was
    # asked recently) always holds a fresh answer when the operator clicks Approve. Such a card sits in a gate an
    # approval step leaves from, or UNAPPROVED in a gate a step leads into (the operator dragged it there: Store#approve
    # approves it in place — card #511: such a card was never asked, so its Approve read a request hours old and was
    # refused "not read yet" once per row it reads). Only a question: the answer is discarded here and the gate
    # (green_ci!) asks again and refuses anything but green. A card that left the gate is no longer asked. Every other
    # card in a gate is listed as "skipped: <why>", and a card whose port call raised as "failed: <error>" — the pass
    # goes on to the next card, nothing is silent.
    # → [[card_id, state | "no PR" | "unavailable: <why>" | "skipped: <why>" | "failed: <why>", gate event], …]
    def approval_prefetch_pass
      gate_cards.map do |c, b|
        next [c[:id], "skipped: #{prefetch_skipped(c, b)}", nil] unless b.green_ci_step?(approval_pending(c, b))

        begin
          prefetch_approval(c, b)
        rescue StandardError => e # one card's host error never ends the pass for the others
          [c[:id], "failed: #{e.class}: #{e.message}", nil]
        end
      end
    end

    # The approval step the operator's Approve would take for card c on board b, or nil: the step leaving its gate, or
    # the step leading into its gate while the card sits there unapproved (Store#approve's two cases).
    def approval_pending(c, b)
      b.approval_from(c[:column]) || (c[:approved_at] ? nil : b.approval_into(c[:column]))
    end

    # Every unarchived card the operator can Approve now, with the step it takes, in id order — the cards the prefetch
    # asks: a host's guard checks their reads stayed fresh (card #511) → [[card row, step], …]; [] without the gate.
    def approval_pending_cards
      gate_cards.filter_map { |c, b| (step = approval_pending(c, b)) && b.green_ci_step?(step) && [c, step] }
    end

    # ── PR watch: a PR assigned to a live card closed without merging ───────────────────────────────────────────
    #
    # The host's ci: port may answer closed_prs(card) → [{role:, number:, repo: optional, closed_at: epoch, why: String} |
    # {error: String}, …]: the PRs assigned to the card that are closed WITHOUT merging (why = the host's words, e.g.
    # "base deleted"), and one {error:} per assigned PR it could not read — said beside the closes, never hidden by them;
    # asking it also keeps every PR assigned to the card watched. It raises Delivery::Unavailable when it cannot say at
    # all. Every unarchived project card outside its board's terminal columns is asked on each notifier watch pass. Each
    # close is told ONCE (ci_watches kind "pr_closed:<role>:<repo>#<n>", ref = closed_at — a reopened PR closed again is
    # a new close; one recorded under the older "pr_closed:<role>" key is not told again): a comment by system_author on
    # the card and a "pr_closed" ping to the owner session. A close with no positive closed_at or a blank why is refused
    # as the port's error, never told. A port without closed_prs → no PR watch.
    # → [[card_id, :closed | :closed_nobody | "unavailable: <why>"], …]
    def pr_watch_pass
      return [] unless @ci.respond_to?(:closed_prs)

      rows = project_cards.where(archived_at: nil, on_hold_at: nil).order(:id).all
      boards = boards_for(rows.map { |c| c[:project_slug] }.uniq)
      rows.reject { |c| boards[c[:project_slug]].terminal?(c[:column]) }.flat_map do |c|
        @ci.closed_prs(c).filter_map do |pr|
          bad = pr[:error] || pr_closed_invalid(pr)
          next [c[:id], "unavailable: #{bad}"] if bad

          pr_closed!(c, boards[c[:project_slug]], pr)
        end
      rescue Delivery::Unavailable, Delivery::Refused => e
        [[c[:id], "unavailable: #{e.message}"]]
      end
    end

    # ── approvable now (a gate column's requires_green_ci): a gate card waits for the OPERATOR only while its
    # Approve would pass
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
      return nil unless b.green_ci_step?(b.approval_from(c[:column]))

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

      "new commits since the handoff (#{short_heads(head)} → #{short_heads(pr[:head])}): the reviewer has not seen them"
    end

    # A head the ci: port gave: one sha, or several joined by "+" (a card with several PRs: one per PR, in the host's
    # order) — each shortened to 7.
    def short_heads(head) = head.split("+").map { |h| h[0, 7] }.join("+")

    # {card id => hold} for the given rows (only the held ones)
    def gate_holds(rows, boards)
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
      when "stuck" then "#{ref}: CI is stuck (pending longer than the host allows)"
      when "pending" then "#{ref}: CI is still running"
      when "unpolled" then "#{ref}: CI not read yet"
      when "nochecks" then "#{ref}: no CI checks ran"
      else "#{ref}: CI state #{pr[:state]}"
      end
    end

    # {slug => n}: per project, the cards waiting for the operator — those in the waiting columns that ask or hold
    # nothing (gate_hold), plus the ones asking elsewhere. `held` = {slug => n} of gate cards waiting for CI, `external` =
    # {slug => n} of cards only blocked_external (external?), in any column.
    # `approved` = {slug => n} of gate cards the operator approved whose agent carries them on (carried_on?).
    # `workerless` = {slug => n} of cards waiting for a worker and for nobody else (card 612).
    WaitingCounts = Struct.new(:waiting, :held, :external, :approved, :workerless)

    def waiting_counts(slugs, boards: nil)
      rows = cards.where(archived_at: nil, on_hold_at: nil, project_slug: slugs.to_a).all
      boards ||= boards_for(rows.map { |r| r[:project_slug] }.uniq)
      gated = rows.select { |r| boards[r[:project_slug]].waiting.include?(r[:column]) }
      holds = gate_holds(gated.reject { |r| flagged?(r) }, boards)
      waiting = Hash.new(0)
      held = Hash.new(0)
      external = Hash.new(0)
      approved = Hash.new(0)
      workerless = Hash.new(0)
      rows.each do |r|
        workerless[r[:project_slug]] += 1 if waiting_for_worker?(r, boards[r[:project_slug]]) &&
                                             !waits_for_operator?(r, boards[r[:project_slug]], holds[r[:id]])
        if waits_for_operator?(r, boards[r[:project_slug]], holds[r[:id]])
          waiting[r[:project_slug]] += 1
        elsif external?(r)
          external[r[:project_slug]] += 1
        elsif holds.key?(r[:id])
          held[r[:project_slug]] += 1
        elsif carried_on?(r, boards[r[:project_slug]])
          approved[r[:project_slug]] += 1
        end
      end
      WaitingCounts.new(waiting, held, external, approved, workerless)
    end

    # ── a lead is never a card's assignee; it gives each waiting card to a worker (card 612) ──────────
    #
    # A lead OWNS what it adopts (owner_session: the card's pings reach it, it routes them) but is never a card's
    # ASSIGNEE: every write that would make one is refused (update, claim, create, a spawn for a lead), adoption and the
    # assignee fill leave it empty. A card in a column a lead type takes, open and unflagged, with no assignee is WAITING
    # FOR A WORKER: the lead gives it to an idle worker (assign_worker) or starts one (kanban_spawn).
    NO_LEAD_ASSIGNEE = "a lead is never a card's assignee (card 612) — it gives each card waiting for a worker to an " \
                       "idle worker of the board (kanban_assign_worker) or starts a new one (kanban_spawn)"
    DISPATCH_ACTION = "You never work it yourself: give it to an idle worker with kanban_assign_worker(id, " \
                      "worker_session, tmux_session) — kanban_board lists them under `dispatch` — or start a new one " \
                      "with kanban_spawn(id, type, tmux_session)."

    def lead_type_keys = @config.lead_types.map(&:key)
    def lead_reg?(r) = !r.nil? && lead_type_keys.include?(r[:type_key])

    # The agent name (or the tmux session) of any registration, open or ended, of a lead type: read off the registry,
    # never off the name's shape.
    def lead_agent?(name)
      n = name.to_s.strip
      return false if n.empty? || lead_type_keys.empty?

      sessions_t.where(type_key: lead_type_keys).where(Sequel.|({ agent_name: n }, { session: n })).any?
    end

    def no_lead_assignee!(name)
      raise Denied, "#{name} is a lead: #{NO_LEAD_ASSIGNEE}" if lead_agent?(name)
    end

    # The columns a worker is wanted in: every column a lead type takes on this board.
    def worker_columns(b) = @config.lead_types.flat_map { |t| b.takes_columns(t) }.uniq

    def waiting_for_worker?(c, b)
      return false if lead_type_keys.empty? || session_slug?(c[:project_slug]) || c[:archived_at] || c[:on_hold_at]
      return false if !b.column?(c[:column]) || b.terminal?(c[:column]) || flagged?(c) || !c[:assignee].to_s.strip.empty?

      worker_columns(b).include?(c[:column])
    end

    # Why the card counts as waiting for the operator (the watch pinged the lead and still no worker), or nil.
    def worker_stale(c, b)
      return nil unless @config.worker_watch.on? && c[:worker_wait_told_at] && c[:worker_wait_at] &&
                        waiting_for_worker?(c, b)

      "no worker for #{(c[:worker_wait_told_at] - c[:worker_wait_at]) / 60} min (since #{hhmm(c[:worker_wait_at])})"
    end

    # card JSON `waiting_for_worker`: {since (the first watch pass that saw it; null before), stale (worker_stale)} | nil
    def waiting_for_worker_json(c, b)
      return nil unless waiting_for_worker?(c, b)

      { since: iso(c[:worker_wait_at]), stale: worker_stale(c, b) }
    end

    # Every notifier watch pass: a card that waits for a worker gets its since (worker_wait_at), one that no longer
    # waits loses it; with worker_watch on, a card waiting wait_minutes pings the board's running lead ONCE and counts as
    # waiting for the operator from then on (worker_stale) until it gets a worker. → [[card_id, :waiting | :told |
    # :told_nobody]]
    def worker_watch_pass(live:, grace:)
      return [] if lead_type_keys.empty?

      now = @clock.call
      rows = project_cards.where(archived_at: nil, on_hold_at: nil).order(:id).all
      boards = boards_for(rows.map { |c| c[:project_slug] }.uniq)
      rows.filter_map do |c|
        b = boards[c[:project_slug]]
        unless waiting_for_worker?(c, b)
          cards.where(id: c[:id]).update(worker_wait_at: nil, worker_wait_told_at: nil) if c[:worker_wait_at]
          next
        end
        if c[:worker_wait_at].nil?
          cards.where(id: c[:id]).update(worker_wait_at: now, worker_wait_told_at: nil)
          next [c[:id], :waiting]
        end
        next unless @config.worker_watch.on? && c[:worker_wait_told_at].nil? &&
                    now - c[:worker_wait_at] >= @config.worker_watch.wait_minutes * 60

        [c[:id], worker_wait_told!(c, b, now, live, grace)]
      end
    end

    def worker_wait_told!(c, b, now, live, grace)
      lead = @config.lead_types.lazy.map { |t| running_lead(t.key, c[:project_slug], live: live, grace: grace) }
                    .find(&:itself)
      mins = (now - c[:worker_wait_at]) / 60
      sys = @config.system_author
      @db.transaction do
        cards.where(id: c[:id]).update(worker_wait_told_at: now)
        touch(c[:id])
        if lead
          text = "[#{sys}] Card ##{c[:id]} \"#{c[:title]}\" (#{b.label(c[:column])}, #{c[:project_slug]}) has " \
                 "waited #{mins} min for a worker and now counts as waiting for the operator. #{DISPATCH_ACTION}"
          queue_ping(c[:id], lead[:session], lead[:socket], text, "lead_dispatch")
        end
        who = lead ? "pinged the lead #{lead[:session]}" : "no lead runs to ping — press Launch"
        log(c[:id], "worker", "no worker for #{mins} min — #{who}; counts as waiting for the operator", sys)
      end
      lead ? :told : :told_nobody
    end

    # The idle sessions a lead may give a card to: open registrations under THIS lead (lead_id), on its board, alive
    # (`live`), that own no open card (not archived, not in a terminal column). → rows, oldest first.
    def idle_workers(lead, live:)
      under = @config.agent_types.select { |t| t.under == lead[:type_key] }.map(&:key)
      b = board_of(lead[:project_slug])
      closed = b.keys.select { |k| b.terminal?(k) }
      sessions_t.where(ended_at: nil, project_slug: lead[:project_slug], type_key: under, lead_id: lead[:id])
                .order(:id).all
                .select { |r| live.include?(r[:session]) }
                .reject do |r|
        cards.where(owner_session: r[:session], owner_socket: r[:socket], archived_at: nil).exclude(column: closed).any?
      end
    end

    # The lead gives a card waiting for a worker to one of its idle workers (idle_workers): owner + assignee = that
    # worker, the operator's unheard comments relayed, one `worker_assigned` ping. lead: the caller's lead registration
    # (Tools proved it through the host). Refused: another board's card, a card that is not waiting for a worker, one
    # owned by another session, a worker that is not idle (the refusal names the idle ones), an unfinished parent.
    def assign_worker(id, worker:, lead:, live:, by:)
      c = card!(id)
      raise Invalid, "no card #{id}" if on_hold?(c)
      unless c[:project_slug] == lead[:project_slug]
        raise Denied, "card ##{c[:id]} is on #{c[:project_slug]}, not on #{lead[:project_slug]} (your board)"
      end

      b = board_of(c[:project_slug])
      unless waiting_for_worker?(c, b)
        why = if !c[:assignee].to_s.strip.empty? then "its assignee is #{c[:assignee]}"
              elsif flagged?(c) then "it is flagged (it waits for the operator or the world)"
              else "#{b.label(c[:column])} is no column a worker is wanted in"
              end
        raise Denied, "card ##{c[:id]} is not waiting for a worker: #{why}"
      end
      unless c[:owner_session].nil? || c[:owner_session] == lead[:session]
        raise Denied, "card ##{c[:id]} is owned by #{c[:owner_session]} — a lead hands out only its own or ownerless cards"
      end
      blocked!(b, nil, c[:blocked_by], "card ##{c[:id]}", claim: true)
      idle = idle_workers(lead, live: live)
      w = idle.find { |r| r[:session] == worker.to_s.strip }
      unless w
        names = idle.map { |r| "#{r[:session]} (#{r[:type_key]})" }
        raise Denied, "#{worker} is not an idle worker of #{lead[:project_slug]} (registered under you, alive, owning no " \
                      "open card) — idle now: #{names.empty? ? 'none: start one with kanban_spawn' : names.join(', ')}"
      end
      by = who!(by)
      @db.transaction do
        cards.where(id: c[:id]).update(owner_session: w[:session], owner_socket: w[:socket], owner_missing_since: nil,
                                       assignee: w[:agent_name], worker_wait_at: nil, worker_wait_told_at: nil,
                                       updated_at: @clock.call)
        log(c[:id], "owner", "assigned to #{w[:agent_name]} — session #{w[:session]} (#{w[:type_key]}), an idle " \
                             "worker, by the lead #{lead[:agent_name]}", by)
        relay_undelivered(c[:id])
        enqueue_ping(card(c[:id]), "worker_assigned", by, "the lead #{lead[:agent_name]}")
      end
      card(c[:id])
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
      rows = project_cards.where(archived_at: nil, on_hold_at: nil).all
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
        # the progress watch covers this card: it says "no progress" on the card itself — the idle watch keeps its CI
        # ping but never comments too (one voice per quiet card)
        quiet = progress_watch? && progress_scope?(c, boards[c[:project_slug]])
        if pr && %w[success failure].include?(pr[:state]) && pr[:finished_at]
          done.concat(ci_step(c, pr, last, w, now, sys, comment: !quiet))
        end
        done.concat(idle_step(c, last, w, now, sys, live, ci)) unless quiet
      end
      done
    end

    def last_activity_at(card_id) = activity_t.where(card_id: card_id).exclude(author: @config.system_author).max(:created_at)

    def ci_step(c, pr, last, w, now, sys, comment: true)
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
      elsif comment && row && row[:commented_at].nil? && now - row[:pinged_at] >= w.ci_comment_after_minutes * 60
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

    # ── progress watch (config.progress_watch): a card in a work column that stopped moving ────────────────────────
    #
    # Seen on the first host: five cards sat 1–3 h with their builder subagents idle while the owner session
    # (the lead running them) stayed alive and busy — the watchdog acts on a gone session, the idle watch on CI or on a
    # quiet session, so nothing fired. This watch looks at the CARD.
    #
    # Scope: every unarchived project card in a WORKING or REVIEW column (Board#working? / #review?: never a gate, a
    # terminal or a parked column) that is not flagged (needs_operator / blocked_external: those wait for someone else).
    # Progress = the card's newest activity entry not signed by system_author (a comment, move, edit, checklist,
    # attachment; the engine's own entries never count) or a change in the evidence the Store's ci: port gives:
    #   progress(card) → [{kind: String, key: String, text: String}, …] — one entry per thing it watches for the card
    #   (busyyaks: the assigned PR's head, that head's CI state, each branch the card names); `key` is the state (a sha,
    #   "<sha> success"), `text` how a human reads it ("PR repo#5 head abc1234"); raises Delivery::Unavailable /
    #   Refused when it cannot say. progress_kinds → [String] what it watches (the board JSON says it). A port without
    #   progress → card activity only. An entry's key that differs from the one the last pass stored (or a kind not seen
    #   before) is progress at this pass's time (cards.progress_marks keeps {kind => {key, text, at}}).
    # The stretch: cards.progress_at = the newest progress seen. No progress for stale_minutes (N) →
    #   1. ONE ping to the owner session naming the last evidence (none → said in the entry);
    #   2. N min after the ping, still none → ONE comment by system_author on the card;
    #   3. N min after the comment → progress_stale_at: the card counts as waiting for the operator
    #      ("no progress for M min"), until progress starts a new stretch (every step again, once).
    # A card leaving the scope forgets its stretch and marks. A card the port cannot answer is skipped and said (its
    # stretch is kept; nothing is guessed). → [[card_id, :ping | :ping_nobody | :comment | :waiting |
    # "unavailable: <why>"], …] what this pass did.
    PROGRESS_ACTIVITY = "card activity"
    # the activity kinds that are the card's progress (the spec's: comment, move, checklist, attachment) — never an
    # owner change, an edit, a terminal event, an archive / restore, a flag or the engine's own entries
    PROGRESS_KINDS = %w[comment move checklist attachment].freeze
    UNREAD = "unpolled" # the ci: port's state of a row nobody has read yet
    PROGRESS_RESET = { progress_pinged_at: nil, progress_commented_at: nil, progress_stale_at: nil }.freeze

    def progress_watch? = @config.progress_watch.on?
    def progress_port? = @ci.respond_to?(:progress)

    # The board JSON's statement of the watch: what it counts as progress on this host. nil = off.
    def progress_watch_json
      return nil unless progress_watch?

      { stale_minutes: @config.progress_watch.stale_minutes,
        evidence: [PROGRESS_ACTIVITY, *(progress_port? ? @ci.progress_kinds : [])],
        port: progress_port?, }
    end

    def progress_scope?(c, b)
      return false if !b.column?(c[:column]) || flagged?(c)

      b.working?(c[:column]) || b.review?(c[:column]) || agents_next_step?(c, b)
    end

    # Why the card counts as waiting for the operator (step 3), or nil. Read off the last watch pass (its stretch), so
    # progress since then shows at the next pass. Fixed text: a read's rev changes only when the content does.
    def progress_stale(c, b)
      return nil unless progress_watch? && c[:progress_stale_at] && c[:progress_at] && progress_scope?(c, b)

      "no progress for #{(c[:progress_stale_at] - c[:progress_at]) / 60} min (since #{hhmm(c[:progress_at])})"
    end

    def progress_watch_pass
      return [] unless progress_watch?

      now = @clock.call
      rows = project_cards.where(archived_at: nil, on_hold_at: nil).order(:id).all
      boards = boards_for(rows.map { |c| c[:project_slug] }.uniq)
      rows.filter_map do |c|
        b = boards[c[:project_slug]]
        unless progress_scope?(c, b)
          forget_progress(c)
          next
        end
        progress_card(c, b, now)
      end
    end

    def forget_progress(c)
      return if c[:progress_at].nil? && c[:progress_marks].nil?

      cards.where(id: c[:id]).update(progress_at: nil, progress_marks: nil, progress_error: nil, **PROGRESS_RESET)
    end

    # One card's pass. A port that cannot answer (any error: Delivery::*, a malformed answer, a bug in the port) skips the
    # card for this pass with the reason — logged by the Notifier and kept on the card (progress_error, card JSON) until
    # the port answers again; its stretch is kept, nothing is guessed.
    def progress_card(c, b, now)
      begin
        marks = progress_marks(c, now)
      rescue StandardError => e
        why = e.is_a?(Delivery::Unavailable) || e.is_a?(Delivery::Refused) ? e.message : "#{e.class}: #{e.message}"
        cards.where(id: c[:id]).update(progress_error: why[0, 2000]) if c[:progress_error] != why[0, 2000]
        return [c[:id], "unavailable: #{why}"]
      end
      act = activity_t.where(card_id: c[:id], kind: PROGRESS_KINDS).exclude(author: @config.system_author)
                      .order(Sequel.desc(:created_at), Sequel.desc(:id)).select(:id, :kind, :created_at).first
      # an approval is progress: the agent's stretch on an approved gate card starts no earlier than it
      approved = agents_next_step?(c, b) ? c[:approved_at] : nil
      latest = [c[:created_at], approved, act&.fetch(:created_at), *marks.values.map { |m| m["at"] }].compact.max
      json = marks.empty? ? nil : JSON.generate(marks)
      # progress only moves the stretch FORWARD: a vanished mark (a port kind missing for a pass, a deleted branch) or a
      # deleted comment lowers `latest` — that is no progress, and never restarts the steps
      if c[:progress_at].nil? || latest > c[:progress_at]
        cards.where(id: c[:id]).update(progress_at: latest, progress_marks: json, progress_error: nil, **PROGRESS_RESET)
        c = c.merge(progress_at: latest, **PROGRESS_RESET)
      elsif json != c[:progress_marks] || c[:progress_error]
        cards.where(id: c[:id]).update(progress_marks: json, progress_error: nil)
      end
      step = progress_step(c, b, now)
      step && [c[:id], step.call(progress_last(c, act, marks))]
    end

    # The port's evidence merged into the stored marks: an unchanged key keeps its time, a changed or new one is now. A
    # kind the port no longer answers is KEPT, marked gone (its time unchanged): when it comes back with the same key it
    # is no progress (a flapping answer never restarts the stretch); with another key it is.
    def progress_marks(c, now)
      return {} unless progress_port?

      old = c[:progress_marks] ? JSON.parse(c[:progress_marks]) : {}
      items = @ci.progress(c)
      raise Delivery::Refused, "progress port answered #{items.class}, not a list" unless items.is_a?(Array)

      now_seen = items.each_with_object({}) do |e, acc|
        bad = %i[kind key text].find { |k| !(e.is_a?(Hash) && e[k].is_a?(String) && !e[k].strip.empty?) }
        raise Delivery::Refused, "progress port answered #{e.inspect}: #{bad} must be a non-blank String" if bad
        raise Delivery::Refused, "progress port answered kind #{e[:kind]} twice" if acc.key?(e[:kind])

        prev = old[e[:kind]]
        at = prev && prev["key"] == e[:key] ? prev["at"] : now
        acc[e[:kind]] = { "key" => e[:key], "text" => e[:text], "at" => at }
      end
      gone = old.reject { |k, _| now_seen.key?(k) }.transform_values { |m| m.merge("gone" => true) }
      now_seen.merge(gone)
    end

    # The step due now (a lambda: last-evidence text → the step's symbol), or nil.
    def progress_step(c, b, now)
      period = @config.progress_watch.stale_minutes * 60
      return nil if now - c[:progress_at] < period

      if c[:progress_pinged_at].nil?
        ->(last) { progress_ping!(c, b, now, last) }
      elsif c[:progress_commented_at].nil? && now - c[:progress_pinged_at] >= period
        ->(last) { progress_comment!(c, b, now, last) }
      elsif c[:progress_commented_at] && c[:progress_stale_at].nil? && now - c[:progress_commented_at] >= period
        ->(_) { progress_waiting!(c, now) }
      end
    end

    def progress_last(c, act, marks)
      parts = [act ? "#{act[:kind]} ##{act[:id]} at #{hhmm(act[:created_at])}" : "created at #{hhmm(c[:created_at])}"]
      marks.each_value { |m| parts << "#{m['text']} since #{hhmm(m['at'])}" unless m["gone"] }
      "last: #{parts.join(' · ')}"
    end

    def progress_mins(c, now) = (now - c[:progress_at]) / 60

    def progress_ping!(c, b, now, last)
      sys = @config.system_author
      owner = c[:owner_session]
      nudge = owner ? approved_nudge(c, b) : "" # asks CI: outside the transaction
      @db.transaction do
        cards.where(id: c[:id]).update(progress_pinged_at: now)
        if owner
          enqueue_ping(c, "progress", sys,
                       "No progress on card ##{c[:id]} \"#{c[:title]}\" (#{b.label(c[:column])}, #{c[:project_slug]}) " \
                       "for #{progress_mins(c, now)} min — #{last}. #{nudge}Post what is happening with kanban_comment, " \
                       "push the work, hand it off, or flag what blocks it (kanban_block / kanban_ask).")
          tell_lead(c, "progress", sys, "has shown no progress for #{progress_mins(c, now)} min in " \
                                        "#{b.label(c[:column])} — #{last}")
        end
        log(c[:id], "progress", "no progress for #{progress_mins(c, now)} min — #{last} — " \
                                "#{owner ? "pinged #{owner}" : 'no owner session to ping'}", sys)
      end
      owner ? :ping : :ping_nobody
    end

    # What the agent of an approved card may do now, in whichever column the approval put it (a review, working or gate
    # column). The step that approved it is the question: it knows what counts there (an open PR's head, the merge
    # commit's CI once merged). Red, still running or conflicting is a hold; a row nobody read yet, or a port that cannot
    # answer, is unread: neither a hold nor a go. A step with no green-CI gate asks nothing and says so; a card no approval
    # step leads to, or with no agent step after it, gets no wording.
    def approved_nudge(c, b)
      step = approved_step(c, b)
      return "" unless step&.then

      nxt = b.label(step.then)
      return "It is approved; this step asks no CI: take its next step (#{nxt}). " unless b.green_ci_step?(step)

      kind, why = approved_read(c, step)
      case kind
      when :unread then "It is approved; #{why}. Read its checks before its next step (#{nxt}). "
      when :hold then "It is approved but held: #{why}. Its next step (#{nxt}) waits for green checks. "
      else "It is approved: take its next step (#{nxt}). "
      end
    end

    def approved_step(c, b) = c[:approved_at] && !b.terminal?(c[:column]) ? b.approval_into(c[:column]) : nil

    # ── the approved queue ─────────────────────────────────────────────────────────────────────────────
    # The cards approved into the same column of a board (approved_step: their agents carry each on — merge it, build its
    # next PR), in the order they should go: priority rank (priority_rank), then the oldest approval, then the card id.
    # Order only: nothing is refused for it — a card ahead that is held (red CI, a question) does not hold the others.
    # → {card_id => {column, position (1 = next), of, ahead: [{id, priority}]}} for the approved cards among `list`.
    def approved_queues(list, boards)
      mine = list.select { |c| c[:approved_at] }
      return {} if mine.empty?

      slugs = mine.map { |c| c[:project_slug] }.uniq
      boards = boards ? boards.dup : {}
      slugs.each { |s| boards[s] ||= board_of(s) }
      # only the columns an approval step leads into (Board#approval_into), every other approved card is no queue's
      targets = slugs.flat_map { |s| boards[s].approvals.map(&:to) }.uniq
      rows = project_cards.where(project_slug: slugs, column: targets, archived_at: nil, on_hold_at: nil)
                          .exclude(approved_at: nil).select(:id, :project_slug, :column, :priority, :approved_at).all
      rows.select! { |c| approved_step(c, boards[c[:project_slug]]) }
      queues = rows.group_by { |c| [c[:project_slug], c[:column]] }.transform_values do |q|
        q.sort_by { |c| [priority_rank(c[:priority]), c[:approved_at], c[:id]] }
      end
      mine.to_h do |c|
        q = queues[[c[:project_slug], c[:column]]]
        at = q&.index { |r| r[:id] == c[:id] }
        next [c[:id], nil] unless at

        [c[:id], { column: c[:column], position: at + 1, of: q.size,
                   ahead: q.first(at).map { |r| { id: r[:id], priority: r[:priority] } }, },]
      end
    end

    # the approve ping's line on the queue: the approved cards ahead of this one in its column (none → "")
    def approved_queue_note(c, b)
      q = approved_queues([cards.where(id: c[:id]).first], { c[:project_slug] => b })[c[:id]]
      return "" if q.nil? || q[:ahead].empty?

      ahead = q[:ahead].map { |a| "card ##{a[:id]}#{" (#{a[:priority]})" if a[:priority]}" }.join(", ")
      " Approved queue in #{b.label(q[:column])} at this approval: #{q[:position]} of #{q[:of]} by priority, ahead of " \
        "it: #{ahead}. " \
        "A card ahead that can go now goes first; one held (red CI, a question, no owner) does not hold this one " \
        "(kanban_card shows the live approved_queue)."
    end

    # → [:clear] | [:hold, why] | [:unread, why]
    def approved_read(c, step)
      pr = @ci.approval_checks(c, step.to_h)
      return [:unread, pr[:reason] || "its CI is not read yet (asked now)"] if pr&.dig(:state) == UNREAD
      if pr&.dig(:rebase)
        return [:hold, "#{pr[:number] ? "PR ##{pr[:number]}" : 'its PR'} conflicts with #{pr[:rebase][:base]}"]
      end

      why = hold_from(c, pr)
      why ? [:hold, why] : [:clear]
    rescue StandardError => e # one card's port error never ends the pass
      [:unread, "CI state unknown — #{e.message}"]
    end

    # ── approved cards keep their CI asked ─────────────────────────────────────────────────────────────
    # A host may poll only what was asked recently. The approval prefetch stops at the approval, while the card's agent
    # may take a long time to carry it on, so each watch pass asks the step that approved every such card, in any column.
    # Only a question: the answer is discarded here. → [[card_id, state | "no PR" | "unavailable: <why>" | "failed: <why>"]]
    def approved_ci_pass
      rows = by_priority(project_cards.where(archived_at: nil, on_hold_at: nil).exclude(approved_at: nil).order(:id).all)
      boards = boards_for(rows.map { |c| c[:project_slug] }.uniq)
      rows.filter_map do |c|
        step = approved_step(c, boards[c[:project_slug]])
        next unless step&.then && boards[c[:project_slug]].green_ci_step?(step)

        [c[:id], approved_ci_state(c, step)]
      end
    end

    def approved_ci_state(c, step)
      pr = @ci.approval_checks(c, step.to_h)
      pr ? pr[:state] : "no PR"
    rescue Delivery::Unavailable => e
      "unavailable: #{e.message}"
    rescue StandardError => e # one card's host error never ends the pass for the others
      "failed: #{e.class}: #{e.message}"
    end

    def progress_comment!(c, b, now, last)
      sys = @config.system_author
      pinged = "owner #{c[:owner_session]} was pinged at #{hhmm(c[:progress_pinged_at])}"
      owner = c[:owner_session] ? pinged : "no owner session"
      @db.transaction do
        cards.where(id: c[:id]).update(progress_commented_at: now)
        touch(c[:id])
        log(c[:id], "comment", "**No progress** on this card for #{progress_mins(c, now)} min in #{b.label(c[:column])} " \
                               "(#{owner}) — #{last}. In #{@config.progress_watch.stale_minutes} min more it counts " \
                               "as waiting for the operator.", sys)
      end
      :comment
    end

    def progress_waiting!(c, now)
      @db.transaction do
        cards.where(id: c[:id]).update(progress_stale_at: now)
        touch(c[:id])
        log(c[:id], "progress", "counts as waiting for the operator: no progress for #{progress_mins(c, now)} min",
            @config.system_author)
      end
      :waiting
    end

    # HH:MM in the host's zone; another day than now → MM-DD HH:MM
    def hhmm(t)
      at = Time.at(t)
      at.strftime(at.to_date == Time.at(@clock.call).to_date ? "%H:%M" : "%m-%d %H:%M")
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
    # A card ON HOLD adds nobody (out of every agent's sight).
    def members(slug)
      seen = cards.where(project_slug: slug, on_hold_at: nil)
      (activity_t.where(card_id: seen.select(:id)).distinct.select_map(:author) +
        seen.exclude(assignee: nil).distinct.select_map(:assignee) +
        seen.distinct.select_map(:created_by)).uniq.sort
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

    # the board's cards in sight: not archived, not on hold (Store#hold) — every view, count, watch and agent reads these
    def live(slug) = cards.where(project_slug: slug, archived_at: nil, on_hold_at: nil)
    # the operator's ON HOLD view of a board: its held cards, still in their columns
    def held_cards(slug) = cards.where(project_slug: slug, archived_at: nil).exclude(on_hold_at: nil)

    def board!(slug)
      raise Invalid, "no board #{slug}" unless slug.is_a?(String) && !slug.empty?
      return if session_slug?(slug) ? live_session_board?(slug) : @boards.call(slug)

      raise Invalid, session_slug?(slug) ? session_board_gone(slug) : "no board #{slug}"
    end

    def live_session_board?(slug)
      row = @repo.session_row(slug)
      !row.nil? && row[:archived_at].nil?
    end

    def session_board_gone(slug)
      hours = @config.session_boards.idle_hours
      what = @repo.session_row(slug) ? "was archived after #{hours} h with no activity" : "does not exist"
      "session board #{slug} #{what} — kanban_session_board(tmux_session: #{session_of(slug)}) opens it again"
    end

    def not_session_shape!(slug)
      raise Invalid, "a session board's shape is the host's session_boards.board" if session_slug?(slug)
    end

    # The host's session board shape, validated once: a Board with no gate (nobody but its session acts on it).
    def session_board_shape(config)
      sb = config.session_boards or return nil
      b = Board.new(sb.board, host: config)
      if b.waiting.any?
        raise ConfigError, "session_boards.board: #{b.waiting.map { |k| b.label(k) }.join(', ')} waits for the operator — " \
                           "a session board has no gate"
      end
      b
    rescue Invalid => e
      raise ConfigError, "session_boards.board: #{e.message}"
    end

    # cards on PROJECT boards only: the watchdog, the intake, the spawn queue and the idle watch never touch a session's
    # own board (its cards stay its session's, whatever that session's state)
    def project_cards
      return cards unless session_boards?

      pre = @config.session_boards.slug_prefix
      cards.exclude(Sequel.function(:substr, :project_slug, 1, pre.length) => pre)
    end

    # Every rule a column change must pass, in order: the agent gates, the workflow, the parent dependency. One place —
    # move runs it, and ask / handoff run it BEFORE they write their fields (so a refusal leaves nothing behind).
    def move_check!(b, c, column, agent:, handoff: false, withdraw: false)
      return if column == c[:column]

      agent_move_rules!(b, c, column, handoff: handoff) if agent
      workflow_check!(b, c, column, agent) unless withdraw
      blocked!(b, column, c[:blocked_by], "card ##{c[:id]}")
      # last (card #497): a move refused by any other rule (the agent rules, the workflow, a block) never asks CI nor
      # clears a needs-rebase mark, and says its own reason
      rebase_hold!(b, c, column) if agent
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
    # (move_check! runs them, then the workflow and the blocks, then rebase_hold! last)
    def agent_move_rules!(cfg, c, column, handoff:)
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
      required_prs!(cfg, c, column)
      round_limit!(cfg, c, column)
    end

    # A card marked needs rebase goes on (any agent move but back to a working column) only once the step's checks,
    # asked now, are green with no conflict — the mark then clears; otherwise refused with what holds it.
    def rebase_hold!(b, c, column)
      mark = c[:needs_rebase] or return
      return if b.working?(column)

      got = rebase_cleared(c, b)
      return if got == true

      raise Denied, "card ##{c[:id]} was approved with needs rebase (#{rebase_what(mark['pr'], mark)}) and is held in " \
                    "#{b.label(c[:column])}: #{got}. Rebase onto #{mark['base']}, re-run CI and merge once it is green " \
                    "— a conflict you cannot resolve: kanban_ask on the card naming the files"
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
      gone << "on hold" if c[:on_hold_at] # a held card moved by hand into a terminal column: its work is over
      return if gone.empty?

      cards.where(id: c[:id]).update(dialog_id: nil, question: nil, question_options: nil, asked_at: nil, asked_by: nil,
                                     blocked_at: nil, blocked_author: nil, blocked_reason: nil, blocked_url: nil,
                                     flag_reminded_at: nil, on_hold_at: nil, on_hold_by: nil)
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

    # The transitions out of `column` on board b, for the card JSON and the clients: [{name, to, to_label, by}] + comment:
    # true on a comment action (the comment box's "Comment & <name>").
    def transitions_json(b, column)
      b.workflow.from(column).map do |e|
        { name: e.name, to: e.to, to_label: b.label(e.to), by: e.by }.merge(e.comment ? { comment: true } : {})
      end
    end

    # every unarchived card sitting in a gate column of its board, with that board → [[card row, board], …]
    def gate_cards
      boards = boards_for(cards.where(archived_at: nil, on_hold_at: nil).distinct.select_map(:project_slug))
      gates = boards.values.flat_map(&:gate_columns).uniq
      return [] if gates.empty?

      cards.where(archived_at: nil, on_hold_at: nil, column: gates).order(:id).all.filter_map do |c|
        b = boards[c[:project_slug]]
        [c, b] if b.gate?(c[:column])
      end
    end

    # Why a gate card is not asked (approval_prefetch_pass): approved, its agent carries on — or no step at all.
    def prefetch_skipped(c, b)
      return "approved by #{c[:approved_by]}, its agent carries on" if c[:approved_at] && b.approval_into(c[:column])
      step = approval_pending(c, b)
      return "#{b.label(step.from)} does not wait for green CI (no requires_green_ci in the workflow)" if step

      "no approval step leaves or enters #{b.label(c[:column])}"
    end

    # One gate card's step asked of the ci: port (approval_prefetch_pass) → [id, what it said, gate event] | nil (no
    # step here). The gate event is said once per change, the last state kept on the card (gate_state):
    # :red = its CI turned red (the owner is pinged to fix it), :ready = a hold cleared (it now waits for the operator).
    def prefetch_approval(c, b)
      return nil if c[:archived_at]

      step = approval_pending(c, b)
      return nil unless b.green_ci_step?(step)
      begin
        pr = @ci.approval_checks(c, step.to_h)
      rescue Delivery::Unavailable => e
        return [c[:id], "unavailable: #{e.message}", gate_event(c, b, "CI state unknown — #{e.message}", red: nil)]
      end
      red = RED.include?(pr&.dig(:state)) ? (pr[:finished_at] || 0) : nil
      [c[:id], pr ? pr[:state] : "no PR", gate_event(c, b, hold_from(c, pr), red: red)]
    end

    # Why one closed_prs answer cannot be told (pr_watch_pass), nil when it can: the key and the words must be real.
    def pr_closed_invalid(pr)
      what = "closed_prs answered PR ##{pr[:number].inspect} (#{pr[:role].inspect})"
      return "#{what} with no role or number" unless pr[:role].is_a?(String) && pr[:number].is_a?(Integer)
      return "#{what} with closed_at #{pr[:closed_at].inspect}, not a positive epoch" unless positive?(pr[:closed_at])

      "#{what} with a blank why" if pr[:why].to_s.strip.empty?
    end

    def positive?(value) = value.is_a?(Integer) && value.positive?

    # One closed_prs answer told once (pr_watch_pass) → [id, :closed | :closed_nobody] | nil (told before).
    # A card holds any number of PRs per role: the watch key names the PR (role + optional repo + number);
    # a close recorded under the older per-role key ("pr_closed:<role>", same closed_at) is not told again.
    def pr_closed!(c, b, pr)
      name = pr[:repo] ? "#{pr[:repo]}##{pr.fetch(:number)}" : "##{pr.fetch(:number)}"
      kind = "pr_closed:#{pr.fetch(:role)}:#{name}"
      ref = pr.fetch(:closed_at)
      sys = @config.system_author
      @db.transaction do
        next nil if watches_t.where(card_id: c[:id], kind: [kind, "pr_closed:#{pr.fetch(:role)}"], ref: ref).any?

        owner = c[:owner_session]
        now = @clock.call
        watches_t.insert(card_id: c[:id], kind: kind, ref: ref, pr: pr.fetch(:number), state: "closed",
                         pinged_at: owner && now, created_at: now)
        what = "PR #{pr[:repo] ? name : "##{pr.fetch(:number)}"} (#{pr.fetch(:role)}) closed without merging " \
               "(#{pr.fetch(:why)})"
        text = "#{what} while card ##{c[:id]} \"#{c[:title]}\" is in #{b.label(c[:column])} — open a new PR and " \
               "assign it (kanban_pr_assign), or say on the card why this one is gone."
        enqueue_ping(c.merge(column_label: b.label(c[:column])), "pr_closed", sys, text) if owner
        touch(c[:id])
        log(c[:id], "comment", "#{what} — #{owner ? "pinged #{owner}" : 'no owner session to ping'}.", sys)
        [c[:id], owner ? :closed : :closed_nobody]
      end
    end

    # → :red (pinged the owner) | :red_nobody (no owner session to ping) | :ready | nil. red: the finish time of a
    # RED answer (whatever the host's words for it — a reason: on a red merge CI too), nil when not red: ONE ping per CI
    # completion (ci_watches kind "gate_red", ref = that time).
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

    # The approval gate (the gate column's requires_green_ci): the card's PR checks must be green — asked of the
    # host's ci: port for this step (the host picks the PR: e.g. the local PR at the local step, the public PR at the
    # final one). No PR, not finished, failed, not read yet or the port unreachable → refused with what it saw. An
    # answer's `reason:` is the host's own refusal (e.g. a prerequisite PR not merged), said in place of the CI wording.
    def green_ci!(c, b, step, handoff: false)
      return unless b.green_ci_step?(step)
      unless @ci.respond_to?(:approval_checks)
        raise ConfigError, "#{b.label(step.from)} waits for green CI (requires_green_ci) but the Store got no ci: port " \
                           "answering approval_checks(card, step)"
      end

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
        # card #497: only the APPROVAL accepts a conflicting PR (marked needs rebase); a handoff of one is refused —
        # the conflict is the author's to resolve before the operator reviews it
        if handoff && pr[:rebase]
          raise Invalid, "#{what}: card ##{c[:id]} — #{rebase_what(pr[:number], rebase_of!(c, pr))}: rebase it and " \
                         "re-run CI; #{wait}"
        end
        moved = !handoff && hold_from(c, pr) # approving: the PR must still be at the head the handoff saw
        raise Invalid, "#{what}: card ##{c[:id]} — #{moved}; hand it back for review#{drag}" if moved

        return pr
      end

      ref = pr[:number] ? "PR ##{pr[:number]}" : "its PR"
      raise Invalid, "#{what}: card ##{c[:id]} — #{pr[:reason]}#{handoff ? "; #{wait}" : ''}#{drag}" if pr[:reason]

      why = case pr[:state]
            when "failure" then "CI failed"
            when "stuck" then "CI is stuck (pending longer than the host allows)"
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

    # :comments, :attachments, :media, :checklist_done / :checklist_total, :dialog, :children, :blocked_by, :transitions
    # for the card face.
    def decorate(list, boards = nil)
      ids = list.map { |c| c[:id] }
      n = activity_t.where(card_id: ids, kind: "comment").group_and_count(:card_id).as_hash(:card_id, :count)
      files = attachments_t.where(card_id: ids, deleted_at: nil).group_and_count(:card_id).as_hash(:card_id, :count)
      media = newest_pictures(ids)
      dialogs = dialogs_t.where(id: list.map { |c| c[:dialog_id] }.compact, answered_at: nil).as_hash(:id)
      kids = cards.where(parent_id: ids, archived_at: nil, on_hold_at: nil).group_and_count(:parent_id)
                  .as_hash(:parent_id, :count)
      parents = list.map { |c| c[:parent_id] }.compact.uniq
      open = unfinished(parents)
      items = items_t.join(@tables[:checklists], id: :checklist_id).where(Sequel[@tables[:checklists]][:card_id] => ids)
                     .select(Sequel[@tables[:checklists]][:card_id], Sequel[@tables[:checklist_items]][:done])
                     .all
                     .group_by { |r| r[:card_id] }
      boards ||= boards_for(list.map { |c| c[:project_slug] }.uniq)
      holds = gate_holds(list, boards)
      marks = rebase_marks(ids)
      queues = approved_queues(list, boards)
      list.each do |c|
        b = boards[c[:project_slug]]
        c[:approved_queue] = queues[c[:id]]
        c[:needs_rebase] = marks[c[:id]]
        c[:gate_hold] = holds[c[:id]]
        c[:progress_stale] = progress_stale(c, b)
        c[:waiting_for_worker] = waiting_for_worker_json(c, b)
        c[:waiting] = waits_for_operator?(c, b, c[:gate_hold])
        c[:carried_on] = carried_on_json(c, b)
        c[:transitions] = b.column?(c[:column]) ? transitions_json(b, c[:column]) : []
        c[:comments] = n[c[:id]] || 0
        c[:attachments] = files[c[:id]] || 0
        c[:media] = media[c[:id]]
        its = items[c[:id]] || []
        c[:checklist_total] = its.size
        c[:checklist_done] = its.count { |r| r[:done] == 1 }
        c[:dialog] = dialog_json(dialogs[c[:dialog_id]])
        c[:children] = kids[c[:id]] || 0
        c[:blocked_by] = c[:parent_id] && open.include?(c[:parent_id]) ? [c[:parent_id]] : []
      end
    end

    # card id → its newest live picture attachment {id, filename, url} (newest = created_at, then id; an inline image type
    # only: AttachmentPolicy::INLINE_IMAGES), shown on the card face so a card is found by its picture. No picture → absent.
    # One row per card: row_number over the card's pictures, newest first (SQLite ≥ 3.25 and PostgreSQL alike).
    def newest_pictures(ids)
      rank = Sequel.function(:row_number).over(partition: :card_id, order: [Sequel.desc(:created_at), Sequel.desc(:id)])
      attachments_t.where(card_id: ids, deleted_at: nil, content_type: AttachmentPolicy::INLINE_IMAGES)
                   .select(:id, :card_id, :filename, rank.as(:newest))
                   .from_self
                   .where(newest: 1)
                   .all
                   .to_h { |a| [a[:card_id], picture_json(a)] }
    end

    def picture_json(a) = { id: a[:id], filename: a[:filename], url: "#{config.attachment_url_prefix}/#{a[:id]}" }

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

    # A card's priority rank: its index in the host's `priorities` (first = highest); no priority ranks after
    # every listed one. A stored priority the host no longer lists is refused, naming it: never read as "none". Every
    # order on our side sorts by it first: adoption, the pings, the approved queue.
    def priority_rank(p)
      return @config.priorities.size if p.nil? || p.to_s.empty?

      @config.priorities.index(p.to_s) ||
        raise(Invalid, "a card's priority #{p.inspect} is not one of the host's priorities " \
                       "(#{@config.priorities.join(', ')}): set it again or put it back in the config")
    end

    # rows sorted by priority rank, keeping their given order within a rank (sort_by is not stable: the index decides)
    def by_priority(rows) = rows.each_with_index.sort_by { |c, i| [priority_rank(c[:priority]), i] }.map(&:first)

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
      raise Invalid, "parent card ##{pid} is on hold: release it first" if on_hold?(p)
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
