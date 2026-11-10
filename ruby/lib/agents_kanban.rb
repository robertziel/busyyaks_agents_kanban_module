# frozen_string_literal: true

# agents_kanban — the kanban engine shared by busyyaks (Hanami + SQLite) and a Rails + Postgres host app:
# a store over an injected Sequel connection, a board per project kept in the database (its columns typed, its
# workflow), a host config, the operator's JSON API and the agents' MCP tools, attachments, the session-dialog parser
# and the ping notifier. SPEC.md at the repo root is the contract; every port (db, config, markdown, clock, delivery,
# attachment root, projects) is a constructor argument.
require_relative "agents_kanban/version"
require_relative "agents_kanban/errors"
require_relative "agents_kanban/column_types"
require_relative "agents_kanban/workflow"
require_relative "agents_kanban/board"
require_relative "agents_kanban/host_config"
require_relative "agents_kanban/board_repo"
require_relative "agents_kanban/schema"
require_relative "agents_kanban/store"
require_relative "agents_kanban/markdown"
require_relative "agents_kanban/attachment_policy"
require_relative "agents_kanban/attachments"
require_relative "agents_kanban/session_dialog"
require_relative "agents_kanban/card_links"
require_relative "agents_kanban/backlog_md"
require_relative "agents_kanban/notifier"
require_relative "agents_kanban/tools"
require_relative "agents_kanban/api"
require_relative "agents_kanban/rev"
require_relative "agents_kanban/launch"
