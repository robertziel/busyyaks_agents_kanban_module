# frozen_string_literal: true

require "json"
require_relative "errors"
require_relative "board"
require_relative "schema"

module AgentsKanban
  # The BOARD REPOSITORY: a project's Board (columns with types + workflow) kept in three tables — `boards` (one row per
  # project: who saved it when), `board_columns` (key, label, type, position = board order) and
  # `board_transitions` (position, name, from, to, by) — and the TEMPLATE board under the slug Board::TEMPLATE (""):
  # the board a project gets when it has none yet (instantiated as its own rows the first time it is asked for, so it
  # can be edited independently from then on — only for a slug the host's `known` port confirms is a project, never a
  # ghost row for a typo; two processes racing on that first read both end up with the winner's rows). No template and
  # no row = Invalid, loudly: nothing in the engine invents a column.
  #
  # Every read validates the rows as a Board against the host (HostConfig); a stored board the host no longer accepts
  # (the host turned `handoff` to null while a project has a handoff column) raises Invalid naming the project — never
  # a stand-in board. A save validates the whole board first, refuses to drop a column that still holds cards (naming
  # them), then replaces the project's rows in one transaction.
  class BoardRepo
    # known: ->(slug) { the host has this project } — the only slugs the template is instantiated for.
    def initialize(db, tables:, host:, known:, clock: -> { Time.now.to_i })
      raise ArgumentError, "known must be callable: ->(slug) { project? }" unless known.respond_to?(:call)

      @db = db
      @t = tables
      @host = host
      @known = known
      @clock = clock
    end

    def boards_t = @db[@t[:boards]]
    def columns_t = @db[@t[:board_columns]]
    def transitions_t = @db[@t[:board_transitions]]

    # The project's Board: its rows, else the template instantiated for it (by: who is recorded as the author of that
    # copy — the engine's system author). Raises Invalid when neither exists or the rows do not fit the host.
    def fetch(slug, by:)
      fetch_many([slug], by: by).fetch(slug)
    end

    # {slug => Board} for several projects in two reads; missing ones are instantiated from the template.
    def fetch_many(slugs, by:)
      slugs = slugs.map(&:to_s).uniq
      return {} if slugs.empty?

      have = loaded(slugs)
      (slugs - have.keys).each { |s| have[s] = instantiate(s, by: by) }
      have
    end

    def exists?(slug) = boards_t.where(project_slug: slug.to_s).any?
    def template? = exists?(Board::TEMPLATE)
    def template
      loaded([Board::TEMPLATE])[Board::TEMPLATE] ||
        raise(Invalid, "no board template: seed one (BoardRepo#seed!) before boards are read")
    end

    # {columns, transitions, rules, types, updated_by, updated} — the editor's data. board: the Board when the caller
    # read it already.
    def json(slug, by:, board: nil)
      b = board || fetch(slug, by: by)
      row = boards_t.where(project_slug: slug.to_s).first
      { **b.to_h.transform_keys(&:to_sym), rules: b.rules, types: ColumnTypes.json,
        updated_by: row[:updated_by], updated: Store.iso(row[:updated_at]), }
    end

    # Validate, refuse to drop a column with cards in it (cards_in: ->(slug, keys) { {key => [card ids]} }), then
    # replace the project's rows. → the Board.
    def save(slug, hash, by:, cards_in:)
      s = slug.to_s
      b = Board.new(hash, host: @host)
      who = by.to_s.strip
      raise Invalid, "author is required" if who.empty?

      old = loaded([s])[s]
      if old
        gone = old.keys - b.keys
        held = gone.any? ? cards_in.call(s, gone) : {}
        held = held.reject { |_, ids| ids.empty? }
        list = lambda do |h, board|
          h.map do |k, ids|
            more = ids.size > 20 ? ", … #{ids.size} in all" : ''
            "#{board.label(k)} (#{k}) holds card#{'s' if ids.size > 1} ##{ids.first(20).join(', #')}#{more}"
          end
        end
        if held.any?
          raise Invalid, "cannot remove #{held.size == 1 ? 'a column' : 'columns'} with cards: " \
                         "#{list.(held, old).join('; ')} — move them first"
        end
        # a column turned into one that waits for the operator would put its cards in front of the operator with nobody
        # having asked or handed anything over (no question, no QA): refused while it holds cards, like a removal
        now_waiting = (b.waiting - old.waiting) & old.keys
        held = now_waiting.any? ? cards_in.call(s, now_waiting).reject { |_, ids| ids.empty? } : {}
        if held.any?
          raise Invalid, "cannot make #{held.size == 1 ? 'a column' : 'columns'} with cards wait for the operator: " \
                         "#{list.(held, b).join('; ')} — move them first"
        end
      end
      write(s, b, by: who)
      b
    end

    # The project's rows deleted and the template instantiated again for it (refused like a save when cards sit in a
    # column the template lacks). → the Board.
    def reset(slug, by:, cards_in:)
      b = save(slug, template.to_h, by: by, cards_in: cards_in)
      b
    end

    # ── session boards (HostConfig#session_boards): a board row whose slug is the host's prefix + a session name ──

    # The session board's row, or nil (archived ones too).
    def session_row(slug) = boards_t.where(project_slug: slug.to_s).first

    # Create the session's board from `board` (the host's session_boards.board), or bring an archived one back; an
    # existing live one is touched (the session used it). → "created" | "restored" | "touched"
    def open_session_board(slug, board, by:)
      now = @clock.call
      row = session_row(slug)
      if row.nil?
        begin
          # its own savepoint: on PostgreSQL a failed INSERT aborts the enclosing transaction unless rolled back to one
          @db.transaction(savepoint: true) { write(slug, board, by: by, create: true) }
          return "created"
        rescue Sequel::UniqueConstraintViolation
          row = session_row(slug) || raise # a racing first call won: touch its row
        end
      end
      boards_t.where(id: row[:id]).update(archived_at: nil, updated_by: by, updated_at: now)
      row[:archived_at] ? "restored" : "touched"
    end

    def archive_session_board(slug, at:) = boards_t.where(project_slug: slug.to_s, archived_at: nil).update(archived_at: at)

    # The session boards' rows: [{project_slug, updated_at, archived_at, …}] — live ones only unless archived: true.
    def session_rows(prefix, archived: false)
      q = boards_t.where(Sequel.function(:substr, :project_slug, 1, prefix.length) => prefix)
      q = q.where(archived_at: nil) unless archived
      q.order(:project_slug).all
    end

    # The projects that have their own rows (not the template).
    def slugs = boards_t.exclude(project_slug: Board::TEMPLATE).order(:project_slug).select_map(:project_slug)

    # THE MIGRATION / FIRST SEED (a host's data migration calls it once): the template row from `template` (a Board
    # hash) unless one exists; then a board for every slug in `projects`
    # that has none: the template's columns + the project's LEGACY `workflows` row (the first workflow version, a
    # {name, transitions} JSON per project) when that table exists and has one, else the template's transitions. The
    # legacy table is dropped once every row of it was carried over. Everything inside one transaction.
    # → {template: "created" | "kept", created: [slugs], from_workflows: [slugs], dropped_workflows: true | false}
    def seed!(template:, projects:, by:)
      who = by.to_s.strip
      raise Invalid, "author is required" if who.empty?

      legacy = :"#{@t[:cards].to_s.delete_suffix('cards')}workflows"
      report = { template: "kept", created: [], from_workflows: [], dropped_workflows: false }
      @db.transaction do
        if template?
          tpl = self.template
        else
          tpl = Board.new(template, host: @host)
          write(Board::TEMPLATE, tpl, by: who)
          report[:template] = "created"
        end
        rows = @db.table_exists?(legacy) ? @db[legacy].all.to_h { |r| [r[:project_slug], r] } : {}
        (projects.map(&:to_s).uniq + rows.keys).uniq.each do |slug|
          next if slug == Board::TEMPLATE || exists?(slug)

          transitions = tpl.to_h["transitions"]
          r = rows[slug]
          if r
            body = JSON.parse(r[:body])
            unless body.is_a?(Hash) && body["transitions"].is_a?(Array)
              raise Invalid, "legacy workflows row of #{slug} has no transitions list"
            end

            transitions = body["transitions"]
            report[:from_workflows] << slug
          end
          begin
            b = Board.new({ "columns" => tpl.to_h["columns"], "transitions" => transitions }, host: @host)
          rescue Invalid => e
            raise Invalid, "board of #{slug} from its legacy workflow: #{e.message}"
          end
          write(slug, b, by: r ? r[:updated_by] : who, at: r && r[:updated_at])
          report[:created] << slug
        end
        if @db.table_exists?(legacy)
          @db.drop_table(legacy)
          report[:dropped_workflows] = true
        end
      end
      report
    end

    # WORKFLOW v3 (the host's data migration calls it once, after Schema v8): every stored board — the template too —
    # moves to the fixed type set. Mechanical, per board: the asks_operator column is REMOVED (its cards go back to the
    # column they came from — the last move into it in the activity log — with the needs_operator flag kept: asked_at
    # stays, the question stays; a card with no such move is named and the migration refused: move it by hand first);
    # the transitions into / out of it are dropped; handoff and approved columns become gates; a card outside the ask
    # column that still carried asked_at (an answered question) loses the flag. `reshape` = {slug => {"board" => the new
    # shape, "cards" => {old column key => new column key}}} replaces a board's whole shape instead (the private
    # local-repo boards): its ask-column cards are returned first, then every card (archived too) is moved by the map —
    # a card in a column the map has not is named and refused. Everything in one transaction. → {slug => report} per
    # board.
    # cards_t: the host's cards table dataset; activity_t: card_activity. by: who signs the moves.
    def migrate_v3!(cards_t:, activity_t:, by:, reshape: {}, clock: @clock)
      who = by.to_s.strip
      raise Invalid, "author is required" if who.empty?

      reports = {}
      # (Sequel wraps an exception raised inside a transaction: the migration's own refusal comes back out as Invalid)
      begin
        @db.transaction { migrate_v3_boards!(reports, cards_t, activity_t, who, reshape, clock) }
      rescue Sequel::DatabaseError => e
        raise e.cause if e.cause.is_a?(Invalid)

        raise
      end
      reports
    end

    # COLUMN RENAME (a host's data migration calls it; its down calls it again with the inverse maps): on every stored
    # board — the template too — that holds a key of `columns` ({old key => {"key" => new key, "label" => new label}},
    # each of the two optional, one required), that column gets its new key and label, every transition its new from / to
    # keys, and `transitions` ({old name => new name}) renames THOSE boards' transitions (a board holding none of the
    # columns keeps its names). The cards follow, archived ones too: their column, the keys of their review_rounds (a loop
    # column's count and the _rereview map); the move / create entries of their activity name the new label, so the
    # waiting order (the last move into a column, read by its label) still reads. Refused, nothing written: a board
    # that holds a new key already (other than by this rename), or one that no longer validates for the host
    # afterwards. One transaction. by: who signs the boards. slugs: only these boards (Board::TEMPLATE for the template;
    # nil = every stored board) — for a host whose key means another column on other boards. → {slug => {"columns",
    # "transitions", "cards", "rounds", "activity" => rows changed}} for the boards it touched.
    def rename_columns!(columns:, cards_t:, activity_t:, by:, transitions: {}, slugs: nil)
      who = by.to_s.strip
      raise Invalid, "author is required" if who.empty?

      map = rename_map!(columns)
      names = transitions.to_h { |k, v| [k.to_s, v.to_s] }
      if names.any? { |k, v| k.empty? || v.empty? }
        raise Invalid, "a transition rename needs two non-empty names: #{names.inspect}"
      end

      reports = {}
      begin
        @db.transaction { rename_boards!(reports, map, names, slugs, cards_t, activity_t, who) }
      rescue Sequel::DatabaseError => e
        raise e.cause if e.cause.is_a?(Invalid)

        raise
      end
      reports
    end

    private

    # {old key => {"key" =>, "label" =>}} checked: string keys, non-empty values, no two old keys onto one new key.
    def rename_map!(columns)
      raise Invalid, "a column rename needs at least one column" if columns.nil? || columns.empty?

      map = columns.to_h do |old, to|
        to = to.to_h { |k, v| [k.to_s, v.to_s.strip] }
        unknown = to.keys - %w[key label]
        raise Invalid, "column rename of #{old}: unknown fields #{unknown.join(', ')}" if unknown.any?
        raise Invalid, "column rename of #{old}: give a new key or label" if to.empty? || to.values.any?(&:empty?)

        [old.to_s, to]
      end
      new_keys = map.map { |old, to| to.fetch("key", old) }
      dup = new_keys.tally.select { |_, n| n > 1 }.keys
      raise Invalid, "column rename: two columns onto #{dup.join(', ')}" if dup.any?

      map
    end

    def rename_boards!(reports, map, names, only, cards_t, activity_t, who)
      all = boards_t.order(:project_slug).select_map(:project_slug)
      (only ? all & only.map(&:to_s) : all).each do |slug|
        cols = columns_t.where(project_slug: slug).order(:position, :id).all
        # a column the map names whose key and label are already the new ones is left alone (a re-run is a no-op)
        hit = cols.select do |c|
          to = map[c[:key]]
          to && (to.fetch("key", c[:key]) != c[:key] || to.fetch("label", c[:label]) != c[:label])
        end
        next if hit.empty?

        keys = cols.map { |c| c[:key] }
        renamed = hit.to_h { |c| [c[:key], map[c[:key]].fetch("key", c[:key])] }
        clash = renamed.filter_map { |old, new| new if old != new && keys.include?(new) && !renamed.key?(new) }
        raise Invalid, "board of #{board_name(slug)}: already has column #{clash.join(', ')} — rename refused" if clash.any?

        labels = hit.to_h { |c| [c[:label], map[c[:key]].fetch("label", c[:label])] }.reject { |a, b| a == b }
        key = ->(k) { renamed.fetch(k, k) }
        hash = {
          "columns" => cols.map do |c|
            { "key" => key.(c[:key]), "label" => map.dig(c[:key], "label") || c[:label], "type" => c[:type],
              "hide_after_hours" => c[:hide_after_hours], }
          end,
          "transitions" => transitions_t.where(project_slug: slug).order(:position, :id).all.map do |r|
            from = JSON.parse(r[:from_keys])
            { "name" => names.fetch(r[:name], r[:name]), "from" => from.is_a?(Array) ? from.map(&key) : key.(from),
              "to" => key.(r[:to_key]), "by" => r[:by], }
          end,
        }
        b = begin
          Board.new(hash, host: @host)
        rescue Invalid => e
          raise Invalid, "board of #{board_name(slug)} after the rename: #{e.message}"
        end
        report = { "columns" => hit.size,
                   "transitions" => transitions_t.where(project_slug: slug).where(name: names.keys).count, }
        report.merge!(rename_cards(slug, renamed, labels, cards_t, activity_t))
        row = boards_t.where(project_slug: slug).first
        write(slug, b, by: who, at: row[:updated_at])
        reports[slug] = report
      end
    end

    def board_name(slug) = slug == Board::TEMPLATE ? "the template" : slug

    # The board's cards (archived too) in the renamed columns, their review_rounds keys and their move / create entries.
    # ONE update for every column (a CASE), so a swap or a chain (a → b, b → c) moves each card once. updated_at is left
    # alone: the card did not change, its column's name did.
    def rename_cards(slug, renamed, labels, cards_t, activity_t)
      out = { "cards" => 0, "rounds" => 0, "activity" => 0 }
      mine = cards_t.where(project_slug: slug)
      moving = renamed.reject { |from, to| from == to }
      unless moving.empty?
        to = Sequel.case(moving.map { |from, new| [{ column: from }, new] }, Sequel[:column])
        out["cards"] = mine.where(column: moving.keys).update(column: to)
      end
      mine.exclude(review_rounds: nil).select(:id, :review_rounds).all.each do |c|
        was = JSON.parse(c[:review_rounds])
        rr = rename_rounds(was, renamed)
        next if rr == was

        cards_t.where(id: c[:id]).update(review_rounds: JSON.generate(rr))
        out["rounds"] += 1
      end
      return out if labels.empty?

      by_len = labels.keys.sort_by { |l| -l.length }
      activity_t.where(card_id: mine.select(:id), kind: %w[move create]).select(:id, :kind, :body).all.each do |a|
        body = a[:kind] == "move" ? relabel_move(a[:body], labels, by_len) : relabel_create(a[:body], labels, by_len)
        next if body == a[:body]

        activity_t.where(id: a[:id]).update(body: body)
        out["activity"] += 1
      end
      out
    end

    def rename_rounds(rounds, renamed)
      rounds.to_h do |k, v|
        k == Store::REREVIEW && v.is_a?(Hash) ? [k, v.transform_keys { |x| renamed.fetch(x, x) }] : [renamed.fetch(k, k), v]
      end
    end

    # "A → B" / "A → B (note)" with A or B an old label → the new one. A label is matched whole, the longest first.
    def relabel_move(body, labels, by_len)
      from, sep, rest = body.partition(" → ")
      return body if sep.empty?

      to = by_len.find { |l| rest == l || rest.start_with?("#{l} (") }
      rest = labels[to] + rest.delete_prefix(to) if to
      "#{labels.fetch(from, from)}#{sep}#{rest}"
    end

    # "created in A" / "created in A · owner session: …" with A an old label → the new one.
    def relabel_create(body, labels, by_len)
      head = "created in "
      return body unless body.start_with?(head)

      rest = body.delete_prefix(head)
      l = by_len.find { |x| rest == x || rest.start_with?("#{x} · ") }
      l ? "#{head}#{labels[l]}#{rest.delete_prefix(l)}" : body
    end

    def migrate_v3_boards!(reports, cards_t, activity_t, who, reshape, clock)
      boards_t.order(:project_slug).select_map(:project_slug).each do |slug|
        cols = columns_t.where(project_slug: slug).order(:position, :id).all
        trs = transitions_t.where(project_slug: slug).order(:position, :id).all
        report = { "columns" => {}, "flagged" => 0, "flag_cleared" => 0, "moved" => Hash.new(0) }
        ask = cols.find { |c| c[:type] == "asks_operator" }
        # an old question on a card that is not waiting in the ask column: answered — the flag would lie
        stale = cards_t.where(project_slug: slug).exclude(asked_at: nil)
        stale = stale.exclude(column: ask[:key]) if ask
        report["flag_cleared"] = stale.update(asked_at: nil, asked_by: nil, question: nil, question_options: nil)
        if ask
          report["flagged"] = return_asked(slug, ask, cols, cards_t, activity_t, who, clock.call)
          cols = cols.reject { |c| c[:id] == ask[:id] }
          trs = drop_column_edges(trs, ask[:key])
        end
        columns = cols.map do |c|
          type = ColumnTypes::LEGACY.fetch(c[:type], c[:type])
          report["columns"][c[:key]] = "#{c[:type]} → #{type}" if type != c[:type]
          { "key" => c[:key], "label" => c[:label], "type" => type,
            "hide_after_hours" => c[:hide_after_hours], }
        end
        transitions = trs.map do |r|
          { "name" => r[:name], "from" => JSON.parse(r[:from_keys]), "to" => r[:to_key], "by" => r[:by] }
        end
        hash = { "columns" => columns, "transitions" => transitions }
        rs = reshape[slug]
        if rs
          hash = rs.fetch("board")
          report["moved"] = remap_cards(slug, rs.fetch("cards"), cards_t, who, clock.call)
        end
        b = begin
          Board.new(hash, host: @host)
        rescue Invalid => e
          raise Invalid, "board of #{slug == Board::TEMPLATE ? 'the template' : slug} after v3: #{e.message}"
        end
        stray = cards_t.where(project_slug: slug).exclude(column: b.keys).select_map(:column).uniq
        raise Invalid, "board of #{slug}: cards sit in columns the v3 board has not: #{stray.join(', ')}" if stray.any?

        row = boards_t.where(project_slug: slug).first
        write(slug, b, by: who, at: row[:updated_at])
        reports[slug] = report
      end
    end

    # The ask column's cards go back where they came from: the last `move` entry "X → <ask label>" names X (a card
    # created in the ask column, or one moved there by an untracked path, is named and refused — no guess).
    def return_asked(slug, ask, cols, cards_t, activity_t, by, now)
      by_label = cols.reject { |c| c[:id] == ask[:id] }.group_by { |c| c[:label] }
      n = 0
      cards_t.where(project_slug: slug, column: ask[:key]).order(:id).all.each do |c|
        moves = activity_t.where(card_id: c[:id], kind: "move").order(Sequel.desc(:created_at), Sequel.desc(:id)).all
        last = moves.find { |m| m[:body].match?(/ → #{Regexp.escape(ask[:label])}(?: \(.*\))?\z/) }
        from = last && last[:body][/\A(.+?) → #{Regexp.escape(ask[:label])}/, 1]
        cands = from ? by_label.fetch(from, []) : []
        if cands.size != 1
          raise Invalid, "card ##{c[:id]} (#{slug}) sits in #{ask[:label]} and the activity log does not say which column " \
                         "it came from — move it to its column by hand, then migrate"
        end

        target = cands.first[:key]
        pos = cards_t.where(project_slug: slug, column: target, archived_at: nil).count
        cards_t.where(id: c[:id]).update(column: target, position: pos, asked_at: c[:asked_at] || last[:created_at],
                                         updated_at: now)
        activity_t.insert(card_id: c[:id], kind: "move", body: "#{ask[:label]} → #{cands.first[:label]} (workflow v3: " \
                                                                "Human input is a flag — needs_operator kept)",
                          author: by, created_at: now)
        n += 1
      end
      n
    end

    # Transitions without the removed column: `from` lists lose it (an edge left with no source is dropped), edges into
    # it are dropped, "*" stays "*".
    def drop_column_edges(trs, key)
      trs.filter_map do |r|
        next nil if r[:to_key] == key

        from = JSON.parse(r[:from_keys])
        if from.is_a?(Array)
          from -= [key]
          next nil if from.empty?

          from = from.first if from.size == 1
        elsif from == key
          next nil
        end
        r.merge(from_keys: JSON.generate(from))
      end
    end

    # Every card of the board (archived too) moved by the map; a column the map lacks is named and refused.
    def remap_cards(slug, map, cards_t, by, now)
      moved = Hash.new(0)
      have = cards_t.where(project_slug: slug).select_map(:column).uniq
      missing = have - map.keys
      raise Invalid, "board of #{slug}: no v3 column for cards in #{missing.join(', ')}" if missing.any?

      map.each do |from, to|
        next if from == to

        ids = cards_t.where(project_slug: slug, column: from).order(:position, :id).select_map(:id)
        next if ids.empty?

        base = cards_t.where(project_slug: slug, column: to, archived_at: nil).count
        ids.each_with_index do |id, i|
          cards_t.where(id: id).update(column: to, position: base + i, updated_at: now)
          @db[@t[:card_activity]].insert(card_id: id, kind: "move", body: "#{from} → #{to} (workflow v3)", author: by,
                                         created_at: now)
        end
        moved["#{from} → #{to}"] += ids.size
      end
      moved
    end

    # The rows of these slugs → {slug => Board} (only the slugs that have rows). A row set that does not validate
    # raises Invalid naming the project.
    def loaded(slugs)
      slugs = boards_t.where(project_slug: slugs).select_map(:project_slug) # a board IS its `boards` row
      return {} if slugs.empty?

      cols = columns_t.where(project_slug: slugs).order(:project_slug, :position, :id).all.group_by { |r| r[:project_slug] }
      trs = transitions_t.where(project_slug: slugs).order(:project_slug, :position, :id).all.group_by { |r| r[:project_slug] }
      cols.to_h do |slug, cs|
        columns = cs.map do |c|
          { "key" => c[:key], "label" => c[:label], "type" => c[:type],
            "hide_after_hours" => c[:hide_after_hours], }
        end
        transitions = (trs[slug] || []).map do |r|
          { "name" => r[:name], "from" => JSON.parse(r[:from_keys]), "to" => r[:to_key], "by" => r[:by] }
        end
        [slug, board!(slug, { "columns" => columns, "transitions" => transitions })]
      end
    end

    def board!(slug, hash)
      Board.new(hash, host: @host)
    rescue Invalid => e
      where = slug == Board::TEMPLATE ? "the board template" : "the stored board of #{slug}"
      raise Invalid, "#{where} no longer fits this host (#{e.message}) — save a new one or reset it to the template"
    end

    # The template copied as the project's own rows (its first board) — for a project the host knows; no template → loud.
    # A concurrent first read may have written the rows meanwhile: the unique project_slug refuses the second insert and
    # the winner's rows are read instead (never overwritten).
    def instantiate(slug, by:)
      raise Invalid, "no board #{slug}: not a project of this host" unless @known.call(slug)

      tpl = template
      begin
        write(slug, tpl, by: by.to_s, create: true)
      rescue Sequel::UniqueConstraintViolation
        return loaded([slug]).fetch(slug)
      end
      tpl
    end

    # The `boards` row first (create: an INSERT — its unique project_slug is the lock two first readers race on, the
    # loser's violation is the signal; a save updates or inserts), then the rows.
    def write(slug, board, by:, at: nil, create: false)
      now = at || @clock.call
      @db.transaction(savepoint: true) do
        n = create ? 0 : boards_t.where(project_slug: slug).update(updated_by: by, updated_at: now)
        boards_t.insert(project_slug: slug, updated_by: by, updated_at: now, created_at: now) if n.zero?
        columns_t.where(project_slug: slug).delete
        transitions_t.where(project_slug: slug).delete
        # a v6 table (the host's v6 migration seeding a fresh DB, before its v7 step) has no hide_after_hours yet:
        # the rows then carry none and read back as the column type's default
        hide = columns_t.columns.include?(:hide_after_hours)
        # a v6 – v8 table (the same replay, before its v9 step drops them) has the graph positions x / y NOT NULL that
        # the v6 – v8 editor drew from: the rows get that version's serpentine, and v9 drops the columns
        legacy_xy = columns_t.columns.include?(:x)
        board.columns.each_with_index do |c, i|
          row = { project_slug: slug, key: c.key, label: c.label, type: c.type.key, position: i }
          row[:hide_after_hours] = c.hide_after_hours if hide
          row.merge!(Schema.legacy_xy(i)) if legacy_xy
          columns_t.insert(row)
        end
        board.workflow.to_a.each_with_index do |t, i|
          transitions_t.insert(project_slug: slug, position: i, name: t["name"], from_keys: JSON.generate(t["from"]),
                               to_key: t["to"], by: t["by"])
        end
      end
    end
  end
end
