# frozen_string_literal: true

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
    # the card's gate: "ready" | the hold, so a change is said once)
    VERSION = 10
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
    def migrate!(db, prefix: "", to: VERSION)
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
      t
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
