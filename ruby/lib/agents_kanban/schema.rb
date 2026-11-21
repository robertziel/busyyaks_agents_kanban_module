# frozen_string_literal: true

require "json"
require "sequel"

module AgentsKanban
  # The engine's tables, as plain Sequel DDL the HOST runs from its own migration (Hanami/ROM or Rails/Sequel alike):
  #
  #   AgentsKanban::Schema.migrate!(db, prefix: "kanban_")
  #
  # Idempotent by introspection: a table is created only when missing, a column added only when missing, so the host
  # calls it once per library bump from a new migration and its own ledger records that. No ledger of ours — two
  # ledgers over one database is how a step gets applied twice or never. `prefix` namespaces every table
  # (kanban_cards, kanban_card_activity, …) so the engine cannot collide with a host table; busyyaks's tables predate
  # the library and keep prefix "" (their names unchanged, no data migration). Portable DDL only: `Integer` epochs
  # (never DateTime — SQLite has none), `String, text: true` for anything that may exceed 255 characters (Postgres
  # would otherwise make it varchar(255)), 0/1 integers for done flags, TrueClass only where the hosts already had it.
  module Schema
    # 1 = the eight tables busyyaks had before the library; 2 = + parent_id / metadata on cards; 3 = + agent_sessions;
    # 4 = + ci_watches;
    # 5 = + workflows (the first workflow version); 6 = boards / board_columns / board_transitions (the board shape per
    # project, BoardRepo) — `workflows` is carried over and dropped by BoardRepo#seed!, the host's data migration;
    # 7 = + board_columns.hide_after_hours (null = the column type's default);
    # 8 = workflow v3: the card FLAGS (blocked_at / blocked_author / blocked_reason / blocked_url, flag_reminded_at; the
    # needs_operator flag is asked_at) and review_rounds (JSON {review column => entries});
    # 9 = − board_columns.x / y: the editor lays the graph out itself every time (SPEC § 2), nothing about the drawing
    # is stored (a host's rollback re-adds them with restore_xy!);
    # 10 = cards.gate_head (the approval PR's head sha the CI port gave at the handoff: a card in a gate counts as waiting
    # for the operator only while its PR still has that head) and cards.gate_state (what the last watch pass saw of
    # the card's gate: "ready" | the hold, so a change is said once);
    # 11 = boards.archived_at (a SESSION board hidden after HostConfig#session_boards.idle_hours with no activity; its
    # cards archived, nothing deleted);
    # 12 = agent_sessions.lead_id / needs_lead / lead_key_digest + CHECK (needs_lead = 0 OR lead_id IS NOT NULL):
    # lead-first boards — a session of a type `under` a lead exists only under a lead registration;
    # 13 = the progress watch's stretch on the card (Store#progress_watch_pass): cards.progress_at (the last progress the
    # watch saw), progress_marks (JSON {kind => {key, text, at}}: the ci: port's evidence as last seen, at = when it
    # changed), progress_pinged_at / progress_commented_at / progress_stale_at (the stretch's escalation steps),
    # progress_error (why the last pass could not read the card's evidence);
    # 14 = a card's PRs are a LIST (no DDL, a data step): metadata `prs` {role => url} → [{url, repo, number, role, by,
    # at}] (by / at read off the card's "PR <role>: <url>" activity line, null when none says), the never-released
    # `prs_replaced` → `prs_removed` entries (prs_to_lists!; prs_to_roles! is the host's rollback);
    # 15 = cards.on_hold_at / on_hold_by: the operator's ON HOLD (Store#hold) — the card keeps its column, leaves the
    # board's normal view, every watch and count, and every agent's sight (Tools: no such card) until released
    # 16 = + board_columns.requires_green_ci (0/1, null = 0): a gate column's own choice whether its approval step waits
    # for green CI — was the host-wide approval.requires_green_ci; no data step: every gate starts at 0
    VERSION = 16
    TABLES = %i[cards card_activity board_labels checklists checklist_items card_pings card_attachments session_dialogs
                agent_sessions ci_watches boards board_columns board_transitions].freeze

    module_function

    def tables(prefix = "")
      TABLES.to_h { |t| [t, :"#{prefix}#{t}"] }
    end

    # to: the schema VERSION a host migration introduced — it creates what existed at that step and nothing later, so a
    # fresh DB replays the host's migrations step by step and a rollback lands on the shape that version's code expects
    # (busyyaks: 20261112 → 2, 20261113 → 3, 20261114 → 4, 20261115 → 5, 20261116 → 6, 20261120 → 7, 20261122 → 8,
    # 20261124 → 9, 20261125 → 10).
    # Default: the current version.
    # prs: the host's PR roles port (Store.new's), needed by step 13 once a card holds PRs in the old shape
    def migrate!(db, prefix: "", to: VERSION, prs: nil, now: Time.now.to_i)
      raise ArgumentError, "to must be 1..#{VERSION} (got #{to.inspect})" unless to.is_a?(Integer) && (1..VERSION).cover?(to)

      t = tables(prefix)
      create_cards(db, t, to)
      create_activity(db, t)
      create_labels(db, t)
      create_checklists(db, t)
      create_pings(db, t)
      create_attachments(db, t)
      create_dialogs(db, t)
      create_sessions(db, t) if to >= 3
      create_ci_watches(db, t) if to >= 4
      create_workflows(db, :"#{prefix}workflows") if to == 5 # v5 only: v6 (BoardRepo#seed!) carries its rows over and drops it
      create_boards(db, t) if to >= 6
      add_missing(db, t[:board_columns], [[:hide_after_hours, Integer]]) if to >= 7
      if to >= 8
        add_missing(db, t[:cards], [
                      [:blocked_at, Integer], [:blocked_author, String], [:blocked_reason, String, { text: true }],
                      [:blocked_url, String, { text: true }], [:flag_reminded_at, Integer],
                      [:review_rounds, String, { text: true }],
                    ])
      end
      drop_xy(db, t) if to >= 9
      add_missing(db, t[:cards], [[:gate_head, String], [:gate_state, String, { text: true }]]) if to >= 10
      add_missing(db, t[:boards], [[:archived_at, Integer]]) if to >= 11
      add_lead(db, t[:agent_sessions]) if to >= 12
      if to >= 13
        add_missing(db, t[:cards], [
                      [:progress_at, Integer], [:progress_marks, String, { text: true }], [:progress_pinged_at, Integer],
                      [:progress_commented_at, Integer], [:progress_stale_at, Integer],
                      [:progress_error, String, { text: true }],
                    ])
      end
      prs_to_lists!(db, prefix: prefix, prs: prs, now: now) if to >= 14
      add_missing(db, t[:cards], [[:on_hold_at, Integer], [:on_hold_by, String]]) if to >= 15
      add_missing(db, t[:board_columns], [[:requires_green_ci, Integer]]) if to >= 16
      t
    end

    PR_URL = %r{\Ahttps://github\.com/([\w.-]+/[\w.-]+)/pull/([1-9]\d*)\z}

    # v14 (idempotent: a card whose `prs` is already a list is left as it is): every card's metadata `prs`
    # {role => value} becomes [{url, repo, number, role, by, at}], role order kept, then the order each value names its
    # PRs. A value is one PR URL, or text naming several: every full PR URL in it, and a bare "/pull/N" after one (= the
    # same repo), each its own entry; the rest of the text (prose: "(merged: 3f4863a)") is dropped only when it names no
    # other PR link — a value that starts with no PR URL, or keeps a "github.com" / "/pull/" / "http" the parse did not
    # read, raises naming the card and the value. A role the host does not read on that card (`prs:` = the Store's
    # port, pr_roles(card)) is mapped by its PR's repo: the one host role whose `repos` holds it (an old `engine` key
    # naming the public engine repo → `public`); none or several → raise naming the card, the value and the candidates.
    # `by` / `at` = the author and time of the card's newest activity line "PR <role>: <value>" (null when no line
    # says: never guessed). A `prs_replaced` entry ({role, url, by, at}: the one-PR-per-role history that never shipped
    # in a release) becomes a `prs_removed` entry with reason "replaced under the one-PR-per-role rule". Any raise →
    # nothing is written. `prs:` is required once a card holds the {role => value} shape (a fresh DB needs none).
    # A PR in no role at all is kept off the list only when the port says why (optional `unread_reason(card, role,
    # repo)` → a reason, or nil = raise): it becomes a `prs_removed` entry (removed_by "migration", that reason) and
    # the card gets an activity line "PR <role> removed by the v14 migration: <url> — <reason>" (at `now`).
    def prs_to_lists!(db, prefix: "", prs: nil, now: Time.now.to_i)
      t = tables(prefix)
      lines = []
      each_pr_card(db, t) do |row, meta|
        id = row[:id]
        old_prs = meta["prs"]
        next nil unless old_prs.is_a?(Hash) || meta.key?("prs_replaced")

        out = meta.except("prs", "prs_replaced")
        removed = []
        out["prs"] = old_prs.is_a?(Hash) ? list_of(db, t, row, old_prs, prs, removed) : old_prs
        removed.each do |e|
          out["prs_removed"] = (out["prs_removed"] || []) +
                               [e.merge("removed_by" => "migration", "removed_at" => now)]
          lines << { card_id: id, kind: "update", author: "migration", created_at: now,
                     body: "PR #{e['role']} removed by the v14 migration: #{e['url']} — #{e['reason']}", }
        end
        old = meta["prs_replaced"]
        if old
          raise ArgumentError, "card #{id} metadata prs_replaced is not a list" unless old.is_a?(Array)

          out["prs_removed"] = (meta["prs_removed"] || []) + old.map do |r|
            pr_entry(db, t, id, r["role"], r["url"], by: r["by"], at: r["at"])
              .merge("removed_by" => r["by"], "removed_at" => r["at"], "reason" => "replaced under the one-PR-per-role rule")
          end
        end
        out
      end
      lines.each { |l| db[t[:card_activity]].insert(l) }
    end

    # one card's {role => value} → its list (see prs_to_lists!); removed collects the PRs in no role the port explains
    def list_of(db, t, row, old_prs, port, removed = [])
      id = row[:id]
      unless port.respond_to?(:pr_roles)
        raise ArgumentError, "card #{id} holds PRs in the {role => url} shape: migrate!(…, prs:) needs the host's PR " \
                             "roles port to map them"
      end

      roles = begin
        port.pr_roles(row)
      rescue StandardError => e
        raise ArgumentError, "card #{id}: its PR roles cannot be read (#{e.message}), so its prs cannot be mapped"
      end
      seen = {} # url → its entry: the same PR under two old keys mapped to one role is one entry naming both keys
      list = old_prs.flat_map do |role, value|
        pr_urls(id, role, value).filter_map do |url, repo|
          to = roles.key?(role) ? role : legacy_role(id, role, value, repo, roles, port, row)
          if to.is_a?(Hash) # in no role, explained by the port: kept as removed
            removed << pr_entry(db, t, id, role, url, said: value).merge("reason" => to[:reason])
            next nil
          end
          had = seen[url.downcase]
          if had
            unless had["role"] == to
              raise ArgumentError, "card #{id}: #{url} is named under two roles (#{had['role']}, #{to}) in its prs"
            end

            had["from_roles"] << role
            next nil
          end
          seen[url.downcase] = pr_entry(db, t, id, role, url, said: value).merge("role" => to, "from_roles" => [role])
        end
      end
      # from_roles: the old keys an entry came from, kept only when they differ from its role (prs_to_roles! restores
      # them exactly)
      list.each { |e| e.delete("from_roles") if e["from_roles"] == [e["role"]] }
    end

    PR_TOKEN = %r{https://github\.com/(?<repo>[\w.-]+/[\w.-]+)/pull/(?<n>[1-9]\d*)(?![\w/])|(?<![\w/])/pull/(?<bn>[1-9]\d*)(?![\w/])}

    # every PR a {role => value} value names → [[url, repo], …] in order (see prs_to_lists!)
    def pr_urls(id, role, value)
      text = value.is_a?(String) ? value.strip : nil
      if text.nil? || !text.match?(%r{\Ahttps://github\.com/[\w.-]+/[\w.-]+/pull/[1-9]\d*(?![\w/])})
        raise ArgumentError, "card #{id} metadata prs.#{role} is not a GitHub PR URL: #{value.to_s[0, 200].inspect}"
      end

      repo = nil
      out = []
      text.scan(PR_TOKEN) do
        m = Regexp.last_match
        repo = m[:repo] if m[:repo]
        out << ["https://github.com/#{repo}/pull/#{m[:n] || m[:bn]}", repo]
      end
      rest = text.gsub(PR_TOKEN, "")
      # a PR named some other way ("pull/2", "a/c#3") is a PR the parse did not read: never dropped silently
      if rest.match?(%r{github\.com|/pull/|https?:|\bpull/\d|#\d}i)
        raise ArgumentError, "card #{id} metadata prs.#{role} names a PR link the migration cannot read: " \
                             "#{value[0, 200].inspect}"
      end

      out
    end

    # the one host role whose repos hold this PR's repo, for a role key the host does not read
    # (or {reason:} when it fits no role and the port's unread_reason explains it)
    def legacy_role(id, role, value, repo, roles, port = nil, row = nil)
      hits = roles.select { |_, s| s.is_a?(Hash) && (s[:repos].nil? || s[:repos].any? { |r| r.casecmp?(repo) }) }.keys
      return hits.first if hits.size == 1

      why = hits.empty? && port.respond_to?(:unread_reason) ? port.unread_reason(row, role, repo) : nil
      return { reason: why } if why

      raise ArgumentError, "card #{id} metadata prs.#{role} (#{value.to_s[0, 200].inspect}): role #{role.inspect} is not " \
                           "one the host reads (#{roles.keys.join(', ')}) and #{repo} is in " \
                           "#{hits.empty? ? 'no role' : "several (#{hits.join(', ')})"}'s repos"
    end

    # The host's rollback of v14: each card's `prs` list → {role => url}; an entry up mapped (an old `engine` key, `local`
    # on a plain project that reads only `pr`) carries `from_roles` and goes back under those exact keys.
    # Refused (ArgumentError naming the cards, nothing written) when a card holds two PRs of one role or has PRs
    # unassigned (`prs_removed`): v12 can hold neither.
    def prs_to_roles!(db, prefix: "")
      t = tables(prefix)
      bad = []
      each_pr_card(db, t, write: false) do |row, meta|
        id = row[:id]
        prs = meta["prs"]
        many = prs.is_a?(Array) && prs.flat_map { |p| p["from_roles"] || [p["role"]] }.tally.any? { |_, n| n > 1 }
        bad << id if many || meta.key?("prs_removed")
        nil
      end
      unless bad.empty?
        raise ArgumentError, "cards #{bad.join(', ')} hold several PRs of one role or unassigned PRs, which the " \
                             "{role => url} shape cannot hold: restore the backup taken before the migration"
      end

      each_pr_card(db, t) do |_, meta|
        prs = meta["prs"]
        next nil unless prs.is_a?(Array)

        # each entry back under the old key(s) it came from (from_roles), else its role
        meta.merge("prs" => prs.flat_map { |p| (p["from_roles"] || [p["role"]]).map { |r| [r, p["url"]] } }.to_h)
      end
    end

    # yields (card row {id, project_slug, metadata}, metadata Hash) for every card whose metadata names prs; the
    # non-nil block values are written back
    # once every card has been read (a raise for one card writes none)
    def each_pr_card(db, t, write: true)
      rows = db[t[:cards]].exclude(metadata: nil).where(Sequel.like(:metadata, "%prs%"))
                          .select(:id, :project_slug, :metadata).all
      out = rows.filter_map do |r|
        meta = JSON.parse(r[:metadata])
        next unless meta.is_a?(Hash)

        changed = yield(r, meta)
        changed && [r[:id], changed]
      end
      out.each { |id, meta| db[t[:cards]].where(id: id).update(metadata: JSON.generate(meta)) } if write
    end

    # said: the old value the activity line named (a free-text value names several PRs; default: the URL)
    def pr_entry(db, t, id, role, url, by: nil, at: nil, said: url)
      m = url.to_s.match(PR_URL)
      raise ArgumentError, "card #{id} metadata prs.#{role} is not a GitHub PR URL: #{url.to_s[0, 200].inspect}" unless m

      said = "PR #{role}: #{said}"
      line = db[t[:card_activity]].where(card_id: id, kind: "update").order(Sequel.desc(:id))
                                  .select(:body, :author, :created_at).all
                                  .find { |a| a[:body] == said || a[:body].start_with?("#{said} ") }
      { "url" => url, "repo" => m[1], "number" => m[2].to_i, "role" => role,
        "by" => by || line&.fetch(:author), "at" => at || line&.fetch(:created_at), }
    end

    # v9: the graph positions go (guarded: a second run changes nothing).
    def drop_xy(db, t)
      have = db.schema(t[:board_columns]).map(&:first)
      gone = %i[x y] & have
      db.alter_table(t[:board_columns]) { gone.each { |c| drop_column c } } if gone.any?
    end

    # The v6 – v8 graph position of the column at board position `i`: the serpentine those versions' template seeding
    # drew (BoardRepo writes it into a pre-v9 table during a fresh replay; restore_xy! on a rollback to v8).
    def legacy_xy(i) = { x: 60 + (i * 170), y: i.even? ? 80 : 260 }

    # A host's v9 rollback: x / y back as v6 created them (NOT NULL, no default), every row at legacy_xy of its board
    # position. Added with a default (a NOT NULL column cannot be added to rows without one), filled, then the default
    # dropped.
    def restore_xy!(db, prefix: "")
      t = tables(prefix)[:board_columns]
      db.alter_table(t) do
        add_column :x, Integer, null: false, default: 0
        add_column :y, Integer, null: false, default: 0
      end
      db[t].select(:id, :position).all.each { |r| db[t].where(id: r[:id]).update(legacy_xy(r[:position])) }
      db.alter_table(t) do
        set_column_default :x, nil
        set_column_default :y, nil
      end
    end

    # v12 (lead-first boards): agent_sessions.lead_id (the lead registration a session runs under),
    # needs_lead (1 = its type is `under` a lead) and lead_key_digest (a lead's key, SHA-256 hex; the key itself is
    # never stored). The CHECK makes a session that needs a lead and has none unwritable — by any code path. Added with
    # the columns, once (an existing row predates lead-first: needs_lead 0).
    def add_lead(db, table)
      return if db.schema(table).map(&:first).include?(:needs_lead)

      db.alter_table(table) do
        add_column :lead_id, Integer
        add_column :needs_lead, Integer, null: false, default: 0
        add_column :lead_key_digest, String
        add_constraint(:"#{table}_lead_required", Sequel.lit("needs_lead = 0 OR lead_id IS NOT NULL"))
      end
    end

    # Column additions after the first shape (each guarded: an existing host DB already has some of them).
    def add_missing(db, table, columns)
      have = db.schema(table).map(&:first)
      db.alter_table(table) do
        columns.each do |name, type, opts|
          next if have.include?(name)

          add_column name, type, **(opts || {})
        end
      end
    end

    def create_cards(db, t, to = VERSION)
      db.create_table?(t[:cards]) do
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
        index %i[project_slug column position]
      end
      add_missing(db, t[:cards], [
                    [:due_at, Integer], [:due_done, Integer, { null: false, default: 0 }], [:cover, String],
                    [:owner_session, String], [:owner_socket, String], [:owner_missing_since, Integer],
                    [:approved_at, Integer], [:approved_by, String],
                    [:qa_notes, String, { text: true }], [:pr_url, String, { text: true }], [:ci_url, String, { text: true }],
                    [:ui_change, TrueClass], [:handoff_at, Integer], [:handoff_by, String],
                    [:question, String, { text: true }], [:question_options, String, { text: true }],
                    [:asked_at, Integer], [:asked_by, String],
                    [:dialog_id, Integer],
                  ])
      # v2: a parent card this one waits for (same table; no FK — SQLite cannot add one to an existing table without a
      # rebuild, and the engine validates the id), and a JSON object of host data.
      add_missing(db, t[:cards], [[:parent_id, Integer], [:metadata, String, { text: true }]]) if to >= 2
    end

    def create_activity(db, t)
      cards = t[:cards]
      db.create_table?(t[:card_activity]) do
        primary_key :id
        foreign_key :card_id, cards, null: false, on_delete: :cascade
        String :kind, null: false
        String :body, text: true, null: false
        String :author, null: false
        Integer :created_at, null: false
        index :card_id
      end
      add_missing(db, t[:card_activity], [[:edited_at, Integer], [:by_operator, TrueClass], [:undelivered, TrueClass]])
    end

    def create_labels(db, t)
      db.create_table?(t[:board_labels]) do
        primary_key :id
        String :project_slug, null: false
        String :name, null: false
        String :color, null: false
        Integer :created_at, null: false
        index %i[project_slug name], unique: true
      end
    end

    def create_checklists(db, t)
      cards = t[:cards]
      db.create_table?(t[:checklists]) do
        primary_key :id
        foreign_key :card_id, cards, null: false, on_delete: :cascade
        String :title, null: false
        Integer :position, null: false
        Integer :created_at, null: false
        index :card_id
      end
      lists = t[:checklists]
      db.create_table?(t[:checklist_items]) do
        primary_key :id
        foreign_key :checklist_id, lists, null: false, on_delete: :cascade
        String :body, text: true, null: false
        Integer :done, null: false, default: 0
        Integer :position, null: false
        String :done_by
        Integer :done_at
        Integer :created_at, null: false
        index :checklist_id
      end
    end

    def create_pings(db, t)
      db.create_table?(t[:card_pings]) do
        primary_key :id
        Integer :card_id, null: false
        String :session, null: false
        String :socket, null: false
        String :text, text: true, null: false
        String :reason, null: false  # comment | move | answer | relay | approve
        String :status, null: false  # pending | sent | failed
        Integer :attempts, null: false, default: 0
        String :error, text: true
        Integer :created_at, null: false
        Integer :done_at
        index %i[status created_at]
      end
    end

    def create_attachments(db, t)
      db.create_table?(t[:card_attachments]) do
        primary_key :id
        Integer :card_id, null: false
        Integer :activity_id            # the comment it belongs to; nil = the card
        String :filename, null: false
        String :content_type, null: false
        Integer :size, null: false
        String :sha256, null: false
        String :stored_path, null: false
        String :uploaded_by, null: false
        Integer :created_at, null: false
        Integer :deleted_at
        String :deleted_by
        index %i[card_id deleted_at]
        index :activity_id
      end
    end

    # v3: the agent sessions the engine launched or was told about (Store#register_session): what type they are, for
    # which board, the author name they act as, and when they ended (the watchdog marks a gone session). Running =
    # ended_at null AND in the host's live snapshot; the concurrency cap counts these.
    def create_sessions(db, t)
      db.create_table?(t[:agent_sessions]) do
        primary_key :id
        String :session, null: false
        String :socket, null: false
        String :project_slug, null: false
        String :type_key, null: false
        String :launcher_key, null: false
        String :agent_name, null: false
        String :launched_by, null: false
        Integer :launched_at, null: false
        Integer :last_seen_at
        Integer :ended_at
        String :end_reason, text: true
        index %i[session ended_at]
        index %i[project_slug ended_at]
      end
    end

    # What the idle watch already did: one row per (card, kind, ref) — kind "ci" = a CI completion (ref = the epoch the
    # PR's checks finished, pr = its number), "idle" = an idle stretch (ref = the epoch of the card's last activity) —
    # so a completion pings once and comments once, an idle stretch comments once.
    def create_ci_watches(db, t)
      db.create_table?(t[:ci_watches]) do
        primary_key :id
        Integer :card_id, null: false
        String :kind, null: false
        Integer :ref, null: false
        Integer :pr
        String :state
        Integer :pinged_at
        Integer :commented_at
        Integer :created_at, null: false
        unique %i[card_id kind ref]
      end
    end

    # v5 (the first workflow version): a project's own workflow as JSON — created only by a host migration pinned to
    # `to: 5`; v6's BoardRepo#seed! copies its rows into board_transitions and drops it.
    def create_workflows(db, name)
      db.create_table?(name) do
        primary_key :id
        String :project_slug, null: false, unique: true
        String :body, text: true, null: false
        String :updated_by, null: false
        Integer :updated_at, null: false
      end
    end

    # v6: a project's BOARD (BoardRepo) — `boards` one row per project (project_slug "" = the template), its columns
    # (key, label, type, position = board order, x / y = the graph editor's node until v9) and its transitions (position, name,
    # from = JSON: a key, a list of keys or "*", to = a key or "*", by = operator | agent | any).
    def create_boards(db, t)
      db.create_table?(t[:boards]) do
        primary_key :id
        String :project_slug, null: false, unique: true
        String :updated_by, null: false
        Integer :updated_at, null: false
        Integer :created_at, null: false
      end
      db.create_table?(t[:board_columns]) do
        primary_key :id
        String :project_slug, null: false
        String :key, null: false
        String :label, null: false
        String :type, null: false
        Integer :position, null: false
        Integer :x, null: false
        Integer :y, null: false
        unique %i[project_slug key]
      end
      db.create_table?(t[:board_transitions]) do
        primary_key :id
        String :project_slug, null: false
        Integer :position, null: false
        String :name, null: false
        String :from_keys, text: true, null: false
        String :to_key, null: false
        String :by, null: false
        index :project_slug
      end
    end

    def create_dialogs(db, t)
      db.create_table?(t[:session_dialogs]) do
        primary_key :id
        String :session, null: false
        String :socket, null: false
        String :hash, null: false
        Integer :card_id, null: false
        String :dialog, text: true, null: false # SessionDialog.parse JSON
        Integer :posted_at, null: false
        Integer :answered_at
        String :answered_by
        String :answer, text: true
        index %i[session hash]
      end
    end
  end
end
