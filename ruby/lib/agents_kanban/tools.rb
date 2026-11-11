# frozen_string_literal: true

require "json"
require_relative "errors"
require_relative "store"
require_relative "attachments"
require_relative "backlog_md"

module AgentsKanban
  # The MCP kanban_* tools: their definitions (worded from the host config and the TEMPLATE board, so every description
  # names this host's columns and gates; a project's own board may differ — kanban_board / kanban_workflow show it) and
  # their dispatcher. MCP callers are agents: the Store applies the agent rules (an isError
  # result with the reason). The host's MCP server lists `definitions` and routes `handles?(name)` to `call`.
  #
  # Ports: store (Store), attachments (Attachments), projects (->(slug) { {slug:, path:, …} | nil } — the host's
  # boards), sessions (-> [live session names]; raises Delivery::Unavailable / Refused when it cannot tell), backlog
  # (->(project, board) { BacklogMd.read result | nil } — optional; nil = the board JSON carries backlog_md: null).
  class Tools
    AUTHOR = { type: "string", description: "who is acting: your agent name or tmux session name" }.freeze
    DUE = {
      type: "string",
      description: "ISO 8601 YYYY-MM-DDTHH:MM[:SS][offset] (no offset = server TZ); empty string clears",
    }.freeze
    LABELS = {
      type: "array", items: { type: "string" },
      description: "names from the board's label set (kanban_labels); unknown names are refused",
    }.freeze
    REFS = "References: write \"PR #N\" for a GitHub pull request, \"card #N\" for a kanban card, " \
           "\"comment #N\" for a comment or event on this card. A bare #N is linked only when it is an activity id " \
           "on this card or a card id on this board; otherwise it stays plain text."
    INT = { type: "integer" }.freeze
    MD = {
      type: "string",
      description: "markdown (rendered server-side like the operator's; @name mentions highlighted)",
    }.freeze
    METADATA = {
      type: "object",
      description: "host data on the card, a JSON object (e.g. {\"draft_id\": 12}); replaces the whole object; null clears",
    }.freeze
    PARENT = { type: "integer", description: "a card on the same board this one waits for (null clears)" }.freeze
    SESSION_ARG = {
      type: "string",
      description: "your tmux session name (tmux display -p '#S'; the lead's, when you are a subagent)",
    }.freeze
    NAMES = %w[kanban_board kanban_workflow kanban_card kanban_create kanban_move kanban_update kanban_comment
               kanban_comment_edit kanban_comment_delete kanban_handoff kanban_claim kanban_register kanban_ask
               kanban_block kanban_unblock kanban_labels kanban_label_save kanban_label_delete kanban_labels_set kanban_due_set
               kanban_checklist_add kanban_checklist_rename kanban_checklist_delete kanban_checklist_item_add
               kanban_checklist_item_edit
               kanban_checklist_toggle kanban_checklist_item_delete kanban_attach kanban_attachments kanban_attachment_get
               kanban_checklist_item_convert].freeze

    def self.handles?(name) = NAMES.include?(name)

    attr_reader :store, :config

    # grace: seconds a registered session counts as running before it shows in `sessions` (a launch starting).
    # card_url: ->(slug, id) { the absolute URL that opens that card on the host's board } — every card a tool returns
    # carries it as `url`, so an agent links a card from data (instructions: Links).
    def initialize(store:, attachments:, projects:, sessions:, card_url:, backlog: nil, grace: 60)
      @store = store
      @card_url = card_url
      @config = store.config
      @attachments = attachments
      @projects = projects
      @sessions = sessions
      @backlog = backlog
      @grace = grace
    end

    # How an agent links what it names (the MCP instructions' last rule): per reference, from data, never one source.
    LINKS = "Links: for every reference, decide what it IS, then link to where that thing lives, read from data — " \
            "never from a default, never one source for everything. A card → its board card: the card's `url` " \
            "(kanban_card, kanban_board). A comment on a card → the card's `url` + \"comment N\". A PR → that PR on " \
            "ITS repo (a private mirror, its public repo and a vendored engine reuse the same numbers): the card's " \
            "pr_url, its Links, `gh pr view`. A GitHub issue → that issue on its repo: `gh issue view`. A commit → " \
            "the repo that holds it (its remote) + the sha. A CI build → the card's ci_url. A report, note or file " \
            "→ its page from the tool's output, or `path:line`. Cannot tell which repo or what kind of thing it is: " \
            "look it up — never guess, never fall back to one source. In chat, link text never puts `#` before a " \
            "number (\"card 236\", \"<repo> PR 99\", \"issue 12 on <repo>\"): chat clients re-link a bare #N to an " \
            "issue of some GitHub repo, even inside a link's text. On the board write `card #N`, `PR #N`, " \
            "`comment #N` as they are: the board resolves those itself."

    # The MCP server's `instructions` for THIS host — the rules an agent session must follow, worded from the template
    # board so every host says the same thing. A host prefixes its own sentence.
    def instructions
      cfg = @store.board_template
      l = ->(k) { cfg.label(k) }
      parts = ["Kanban: a board per project (kanban_board), columns #{cfg.labels.values.join(' → ')} " \
               "(a project's board may differ: kanban_board lists its columns)."]
      parts << "Your tmux session (tmux display -p '#S') is your identity on the board: a session started for a " \
               "project is registered (kanban_register when you were not launched through the board) and owns the " \
               "cards it adopts; every card you create on your project's board is owned by your session " \
               "(kanban_create takes tmux_session, or your registered agent name as author) — one you create on ANOTHER " \
               "project's board is left to that project's sessions, and you cannot claim it; a card you start working " \
               "on that you do not own: kanban_claim first. Comments, the operator's moves and answers are typed into " \
               "the owner session."
      parts << "A question, a choice or a go-ahead you need from the operator about a card goes through " \
               "kanban_ask(id, question, author, options) on that card, then end your turn — the card keeps its " \
               "column, is flagged needs_operator (no agent moves it) and the answer is typed into your session. " \
               "Never ask it only in chat: a question in the terminal reaches nobody and the board shows nothing " \
               "waiting. A question about no card: create the card, then ask on it. Waiting for CI, an API or " \
               "somebody outside the board: kanban_block(id, reason, url), kanban_unblock when it clears."
      if cfg.handoff
        screenshots = cfg.handoff.ui_change_needs_screenshots ? ", screenshots for a UI change" : ""
        gates = cfg.handoff.columns.map(&l).join(" / ")
        green = if @config.green_ci_gate?
                  " Hand off only once the PR's CI is green: a handoff into a gate the operator approves is refused " \
                    "while its checks are unread, pending or red — wait for CI (your Monitor), then hand off again."
                else
                  ""
                end
        parts << "Work done: kanban_handoff (how to check it, PR, CI#{screenshots}) — the only way into a gate " \
                 "(#{gates}); you leave a gate only along a named transition once the operator approved.#{green}"
      end
      final = cfg.approvals.find(&:final)
      parts << "Never merge before the operator's approval moves the card to #{l.(final.to)}." if final
      parts << "Never poll the board or a card (no sleep / re-read loops): comments and moves on your cards arrive in " \
               "your session as pings — end your turn and wait."
      parts << LINKS
      parts.join(" ")
    end

    # The tool list for tools/list, worded from the template board (a project's columns: kanban_board).
    def definitions
      host = @config
      cfg = @store.board_template
      template_keys = cfg.labels.map { |k, v| "#{k}=#{v}" }.join(", ")
      column = {
        type: "string",
        description: "a column key of the project's board (kanban_board lists them; the template's: #{template_keys})",
      }
      color = { type: "string", enum: host.label_colors }
      card_fields = { description: { type: "string", description: "markdown. #{REFS}" }, labels: LABELS,
                      priority: { type: "string", enum: host.priorities + [""] },
                      due: DUE, parent: PARENT, metadata: METADATA, }
      l = ->(k) { cfg.label(k) }
      hg = cfg.handoff
      final = cfg.approvals.find(&:final)
      move_desc = "Move a card to a column at a position (0 = top; omitted = bottom)."
      if hg
        move_desc += " Agents enter a gate (#{hg.columns.map(&l).join(' / ')}) only through kanban_handoff and leave " \
                     "one only along a named agent transition once the operator approved; only the operator moves a " \
                     "card out of #{cfg.operator_only.map(&l).join(' / ')}."
      elsif cfg.operator_only.any?
        move_desc += " Only the operator moves a card out of #{cfg.operator_only.map(&l).join(' / ')}."
      end
      move_desc += " A card flagged needs_operator (kanban_ask) or blocked_external (kanban_block) is not moved by " \
                   "agents until the operator answers / kanban_unblock."
      if final
        move_desc += " The operator's approval moves it to #{l.(final.to)} (#{final.to}); from there its agent merges the " \
                     "work and moves it #{final.to} → #{final.then} itself."
      end
      move_desc += " The board runs named workflow transitions: pass transition (the name) or column; a move with no " \
                   "transition from the card's column is refused with the ones there are."
      create_desc = "Create a card (appended to the column, #{l.(cfg.default_column)} when column is omitted)."
      nc = cfg.no_create_for_agents
      create_desc += " Agents cannot create in #{nc.map(&l).join(' or ')}." if nc.any?
      create_desc += " The card is OWNED by your session from the start (assignee = author, owner = tmux_session): " \
                     "give tmux_session, or use your registered agent name as author (kanban_register) — an agent-made " \
                     "card is never ownerless on its own project's board; on ANOTHER project's board it is left unowned " \
                     "for that project's sessions (you are only created_by). No assignee field. A parent makes the card " \
                     "wait for it."
      comment_ask = "A question or decision the operator must take goes through kanban_ask instead " \
                    "(it flags the card needs_operator; the card keeps its column). "
      register_cap = if host.concurrency.max_sessions
                       "the host's concurrency cap (#{host.concurrency.max_sessions} sessions) or "
                     else
                       ""
                     end
      register_takes = host.agent_types
                           .map { |t| "#{t.key}: #{t.takes.empty? ? 'none' : t.takes.join(' / ')}" }
                           .join("; ")
      defs = [
        { name: "kanban_board",
          description: "A project's kanban board: its columns (the template's: #{cfg.labels.values.join(' → ')}) with " \
                       "their cards in order, and `board` = the columns with their types + the workflow + the derived " \
                       "rules. Repos with a Backlog.md backlog/ also return its tasks (read-only; edit them with the " \
                       "backlog CLI).",
          inputSchema: { type: "object",
                         properties: { project: { type: "string", description: "project slug" }, column: column,
                                       archived: { type: "boolean", description: "also list archived cards" }, },
                         required: ["project"], }, },
        { name: "kanban_workflow",
          description: "A project's board shape: its columns ({key, label, type, x, y}; the type decides the column's " \
                       "rules — #{ColumnTypes.keys.join(', ')}), its workflow (transitions {name, from, to, by}; " \
                       "from/to a column or \"*\"; by operator | agent | any) and the rules derived from the types " \
                       "(waiting, listened, operator_only, the gates). Read-only: only the operator edits it on the " \
                       "board. Pick a transition with kanban_move(transition: <name>); a card's JSON lists the " \
                       "transitions out of its column.",
          inputSchema: { type: "object", properties: { project: { type: "string", description: "project slug" } },
                         required: ["project"], }, },
        { name: "kanban_card",
          description: "One card as markdown: description, checklists (items with done/who), labels, due, parent / " \
                       "children, metadata, and the full activity " \
                       "(comments with their ids and edited mark, moves, edits, who did each).",
          inputSchema: { type: "object", properties: { id: INT }, required: ["id"] }, },
        { name: "kanban_create", description: create_desc,
          inputSchema: { type: "object",
                         properties: { project: { type: "string" }, title: { type: "string" }, author: AUTHOR,
                                       tmux_session: SESSION_ARG, column: column, **card_fields, },
                         required: %w[project title author], }, },
        { name: "kanban_move", description: move_desc,
          inputSchema: { type: "object",
                         properties: { id: INT, column: column, position: INT, author: AUTHOR,
                                       transition: {
                                         type: "string",
                                         description: "a workflow transition NAME out of the card's column " \
                                                      "(e.g. \"Start work\") instead of a column; the card JSON lists them",
                                       }, },
                         required: %w[id author], }, },
        { name: "kanban_update",
          description: "Change a card's title, description, labels, priority, due date, due done, cover colour, parent " \
                       "or metadata (only the fields given). Not the assignee: an agent becomes a card's assignee only " \
                       "with kanban_claim(id, assignee, tmux_session), so a session listens.",
          inputSchema: { type: "object",
                         properties: { id: INT, author: AUTHOR, title: { type: "string" }, **card_fields,
                                       due_done: { type: "boolean", description: "mark the due date complete" },
                                       cover: { type: "string", enum: host.label_colors + [""] }, },
                         required: %w[id author], }, },
        { name: "kanban_comment",
          description: "Add a comment (markdown) to a card's activity: progress, findings. #{comment_ask}" \
                       "Returns {id, delivered} (the comment id; who it pings). #{REFS}",
          inputSchema: { type: "object", properties: { id: INT, body: MD, author: AUTHOR }, required: %w[id body author] }, },
        { name: "kanban_comment_edit",
          description: "Edit one of your own comments (author must match the comment's author). Marked as edited.",
          inputSchema: { type: "object", properties: { comment_id: INT, body: MD, author: AUTHOR },
                         required: %w[comment_id body author], }, },
        { name: "kanban_comment_delete",
          description: "Delete one of your own comments (author must match). The deletion stays in the card's history.",
          inputSchema: { type: "object", properties: { comment_id: INT, author: AUTHOR }, required: %w[comment_id author] }, },
        { name: "kanban_claim",
          description: "Claim a card: set its assignee to you AND its owner session to your tmux session — the only " \
                       "way an agent becomes a card's assignee (kanban_update/kanban_create refuse assignee). " \
                       "tmux_session is required (run `tmux display -p '#S'`) and must be a live tmux session, else " \
                       "refused: new comments, the operator's moves and answers are typed into that session, and a " \
                       "watchdog releases the card if the session ends. The owner is the tmux session — the LEAD: when " \
                       "you hand the work to a subagent, keep the claim (do not claim as the subagent); subagents " \
                       "comment with their own author name and the operator's replies still route to the lead's " \
                       "session. Becoming the owner delivers, in one " \
                       "ping, the operator's comments that reached nobody while the card had no owner. A card whose " \
                       "parent is not done cannot be claimed. Never poll the board or card (no sleep/re-read loops): " \
                       "replies and moves arrive as a ping in your session — end your turn and wait.",
          inputSchema: { type: "object",
                         properties: { id: INT, assignee: AUTHOR,
                                       tmux_session: {
                                         type: "string",
                                         description: "your (the lead's) tmux session name: tmux display -p '#S'",
                                       }, },
                         required: %w[id assignee tmux_session], }, },
        { name: "kanban_register",
          description: "Register the tmux session you run in as an agent session of this board: type (one of " \
                       "#{host.agent_type_keys.join(', ')}), project, tmux_session. Refused beyond #{register_cap}the " \
                       "type's own caps — then stop and say so. " \
                       "On success your session ADOPTS the project's ownerless cards in the columns of the type's " \
                       "column types (#{register_takes}) and you act as the returned " \
                       "agent name (use it as author: cards you create are then owned by your session without " \
                       "tmux_session). A session launched from the board is " \
                       "registered already — calling this again is refused. launcher: the launcher key your session " \
                       "was started with (#{host.launcher_keys.join(', ')}) — required when the type runs several.",
          inputSchema: { type: "object",
                         properties: { project: { type: "string" }, type: { type: "string", enum: host.agent_type_keys },
                                       launcher: { type: "string", enum: host.launcher_keys },
                                       tmux_session: SESSION_ARG, author: AUTHOR, },
                         required: %w[project type tmux_session author], }, },
        { name: "kanban_labels",
          description: "A board's label set: [{id, name, color}]. Card labels must be names from this set.",
          inputSchema: { type: "object", properties: { project: { type: "string" } }, required: ["project"] }, },
        { name: "kanban_label_save",
          description: "Create a board label, or (when it exists) recolour it and/or rename it with new_name — a rename " \
                       "rewrites every card carrying it.",
          inputSchema: { type: "object",
                         properties: { project: { type: "string" }, name: { type: "string" }, color: color,
                                       new_name: { type: "string" }, author: AUTHOR, },
                         required: %w[project name author], }, },
        { name: "kanban_label_delete", description: "Remove a label from the board's set and from every card.",
          inputSchema: { type: "object", properties: { project: { type: "string" }, name: { type: "string" }, author: AUTHOR },
                         required: %w[project name author], }, },
        { name: "kanban_labels_set", description: "Set a card's labels (replaces them; [] clears). Names from kanban_labels.",
          inputSchema: { type: "object", properties: { id: INT, labels: LABELS, author: AUTHOR },
                         required: %w[id labels author], }, },
        { name: "kanban_due_set", description: "Set or clear a card's due date, and optionally mark it done.",
          inputSchema: { type: "object", properties: { id: INT, due: DUE, done: { type: "boolean" }, author: AUTHOR },
                         required: %w[id due author], }, },
        { name: "kanban_checklist_add",
          description: "Add a checklist to a card, optionally with items (markdown, rendered inline). Returns the card " \
                       "with checklists.",
          inputSchema: { type: "object",
                         properties: { id: INT, title: { type: "string" }, items: { type: "array", items: { type: "string" } },
                                       author: AUTHOR, },
                         required: %w[id title author], }, },
        { name: "kanban_checklist_rename", description: "Rename a checklist.",
          inputSchema: { type: "object", properties: { checklist_id: INT, title: { type: "string" }, author: AUTHOR },
                         required: %w[checklist_id title author], }, },
        { name: "kanban_checklist_delete", description: "Delete a checklist and its items.",
          inputSchema: { type: "object", properties: { checklist_id: INT, author: AUTHOR },
                         required: %w[checklist_id author], }, },
        { name: "kanban_checklist_item_add", description: "Append an item (markdown) to a checklist.",
          inputSchema: { type: "object", properties: { checklist_id: INT, body: MD, author: AUTHOR },
                         required: %w[checklist_id body author], }, },
        { name: "kanban_checklist_item_edit", description: "Change a checklist item's text (markdown).",
          inputSchema: { type: "object", properties: { item_id: INT, body: MD, author: AUTHOR },
                         required: %w[item_id body author], }, },
        { name: "kanban_checklist_toggle",
          description: "Check or uncheck a checklist item (done true/false). Recorded with who did it.",
          inputSchema: { type: "object", properties: { item_id: INT, done: { type: "boolean" }, author: AUTHOR },
                         required: %w[item_id done author], }, },
        { name: "kanban_checklist_item_delete", description: "Delete a checklist item.",
          inputSchema: { type: "object", properties: { item_id: INT, author: AUTHOR }, required: %w[item_id author] }, },
        { name: "kanban_attach",
          description: "Attach a file to a card — a screenshot, a log, a report from your repo. Give exactly one of " \
                       "content_base64 (the bytes, at most the server's size cap decoded) or project_path (a file " \
                       "inside THIS card's repo, relative to the repo root; read from the read-only projects mount, " \
                       "symlinks resolved, refused outside the repo). The type is detected from the bytes and must " \
                       "match filename's extension and the server's allowlist. With comment, posts that comment " \
                       "(markdown) with the attachment's snippet appended — it pings the owner like any comment. " \
                       "Returns the attachment (url, markdown snippet: ![name](#{host.attachment_url_prefix}/ID) for " \
                       "pictures, " \
                       "[name](#{host.attachment_url_prefix}/ID/download) for files) and the comment id.",
          inputSchema: { type: "object",
                         properties: {
                           id: INT, author: AUTHOR,
                           filename: {
                             type: "string",
                             description: "display name with the extension, e.g. login-bug.png, build.log",
                           },
                           comment: MD, content_base64: { type: "string", description: "the file's bytes, base64" },
                           project_path: {
                             type: "string",
                             description: "path of a file inside this card's repo, relative to the repo root",
                           },
                         },
                         required: %w[id author filename], }, },
        { name: "kanban_attachments",
          description: "A card's attachments: id, filename, content_type, size, sha256, uploaded_by, created, " \
                       "comment_id, url, download_url, markdown snippet.",
          inputSchema: { type: "object", properties: { id: INT }, required: ["id"] }, },
        { name: "kanban_attachment_get",
          description: "One attachment. Text types (txt/log/md/csv/json/yaml/diff) return their text (first " \
                       "#{Attachments::MAX_TEXT} characters, " \
                       "truncated: true when cut); pictures and other files return metadata and the URL.",
          inputSchema: { type: "object", properties: { attachment_id: INT }, required: ["attachment_id"] }, },
        { name: "kanban_checklist_item_convert",
          description: "Turn a checklist item into its own card at the bottom of the parent card's list; the item is " \
                       "removed. Returns the new card.",
          inputSchema: { type: "object", properties: { item_id: INT, author: AUTHOR }, required: %w[item_id author] }, },
      ]
      if hg
        parts = ["qa (how a human checks it — steps, preview/prod URLs, what to look for, accounts)"]
        parts << "pr_url (GitHub PR#{hg.requires_pr_url ? '' : ', optional'})"
        parts << "ci_url (CI build#{hg.requires_ci_url ? '' : ', optional'})"
        parts << "ui_change (true when it changes anything visible)"
        screenshots = if hg.ui_change_needs_screenshots
                        "For a UI change, attach screenshots FIRST with kanban_attach (before/after, mobile + desktop) " \
                          "or it is refused. "
                      else
                        ""
                      end
        no_merge = final ? " Never merge the PR yourself before the card is in #{l.(final.to)} (operator approval)." : ""
        loop_note = if host.review_loop
                      " At the review loop's round limit (#{host.review_loop.max_rounds}) a handoff out of a review " \
                        "column must give review_summary (the reviewer's SUMMARY counts); it carries the label " \
                        "#{host.review_loop.unresolved_label.inspect} only when needs_human + open is above 0."
                    else
                      ""
                    end
        required = %w[id qa ui_change author]
        required += ["pr_url"] if hg.requires_pr_url
        required += ["ci_url"] if hg.requires_ci_url
        green_note = if host.green_ci_gate?
                       "Into a gate the operator approves: refused until that step's PR checks are read and green " \
                         "(unread / pending / red → refused with the state: wait for CI, then hand off again). "
                     else
                       ""
                     end
        defs.insert(8, { name: "kanban_handoff",
                         description: "The ONLY way an agent moves a card into a gate (#{hg.columns.map(&l).join(' / ')}): " \
                                      "the gate your column has a named agent transition into (several: give transition " \
                                      "or column). Give: #{parts.join(', ')}. #{screenshots}#{green_note}" \
                                      "Then end your turn: the operator's comment or approval is typed into your session " \
                                      "— do not poll for it.#{no_merge}#{loop_note}",
                         inputSchema: { type: "object",
                                        properties: { id: INT, qa: { type: "string", description: "markdown: how to QA it" },
                                                      pr_url: { type: "string" }, ci_url: { type: "string" },
                                                      ui_change: { type: "boolean" }, author: AUTHOR,
                                                      review_summary: {
                                                        type: "object",
                                                        description: "the reviewer's SUMMARY counts (required at the " \
                                                                     "review round limit)",
                                                        properties: %w[fixed resolved_by_argument needs_human open]
                                                          .to_h { |k| [k, { type: "integer", minimum: 0 }] },
                                                        required: %w[fixed resolved_by_argument needs_human open],
                                                      },
                                                      transition: {
                                                        type: "string",
                                                        description: "the transition NAME into the gate (when your " \
                                                                     "column leads to more than one)",
                                                      },
                                                      column: column, },
                                        required: required, }, })
      end
      defs.insert(hg ? 11 : 10, { name: "kanban_ask",
                                 description: "Ask the operator a question or for a decision: the card is FLAGGED " \
                                              "needs_operator and keeps its column (a question in review keeps its " \
                                              "place in review) — agents cannot move it until the operator's comment " \
                                              "answers it. Use it whenever you are blocked on the operator; never stop " \
                                              "silently with 'waiting for go' in a comment. The question (markdown) is " \
                                              "shown highlighted on the card; options (optional, ≤ #{Store::MAX_OPTIONS}) " \
                                              "become buttons the operator clicks. Requires an owner session: give " \
                                              "tmux_session to claim and ask in one step. The operator's answer is typed " \
                                              "into your session and clears the flag; end your turn and wait. Asking " \
                                              "again replaces the open question. After #{host.flags.reminder_hours} h " \
                                              "unanswered the board posts one reminder. #{REFS}",
                                 inputSchema: { type: "object",
                                                properties: {
                                                  id: INT, question: MD, author: AUTHOR, tmux_session: SESSION_ARG,
                                                  options: {
                                                    type: "array", items: { type: "string" },
                                                    description: "short answer choices, " \
                                                                 "e.g. [\"Ship A\", \"Ship B\", \"Hold\"]",
                                                  },
                                                },
                                                required: %w[id question author], }, },
                  { name: "kanban_block",
                    description: "Flag a card blocked_external: it waits for another card, CI, a third-party API or " \
                                 "somebody outside the board. The card keeps its column; agents cannot move it until " \
                                 "kanban_unblock. reason (what it waits for) and url (where the blocker is seen: the " \
                                 "CI build, the issue, the status page) are required. Not counted as waiting for the " \
                                 "operator (the board lists it as blocked externally) — a decision the operator must " \
                                 "take goes through kanban_ask; one reminder after #{host.flags.reminder_hours} h.",
                    inputSchema: { type: "object",
                                   properties: { id: INT, reason: { type: "string" }, url: { type: "string" },
                                                 author: AUTHOR, },
                                   required: %w[id reason url author], }, },
                  { name: "kanban_unblock",
                    description: "Clear a card's blocked_external flag (the blocker is gone); note = what cleared it.",
                    inputSchema: { type: "object", properties: { id: INT, note: { type: "string" }, author: AUTHOR },
                                   required: %w[id author], }, })
      defs
    end

    # kanban_handoff exists on every host (a project's board may add a gate column at any time); a call on a board
    # without one is refused with the reason.
    def handles?(name) = Tools.handles?(name) || name == "kanban_handoff"

    # A project's board as JSON (kanban_board and the API's board endpoint): columns in order with their cards,
    # archived cards when asked, the board's shape + rules, the host config, and the repo's Backlog.md tasks (null without one).
    def board_json(project, column: nil, archived: false)
      b = @store.board_of(project[:slug])
      col = column
      raise Invalid, "column must be one of #{b.keys.join(', ')}" if col && !b.column?(col)

      cols = @store.board(project[:slug], board: b)
      cols = cols.slice(col) if col
      out = { project: project[:slug], labels: @store.labels(project[:slug]).map { |l| @store.label_json(l) },
              columns: cols.map do |k, cs|
                { column: k, label: b.label(k), type: b.type_of(k).key, operator_only: b.operator_only.include?(k),
                  cards: cs.map { |c| row(c) }, }
              end, config: @config.to_h, board: @store.board_json(project[:slug], board: b), }
      out[:archived] = @store.archived(project[:slug]).map { |c| row(c) } if archived
      out[:backlog_md] = BacklogMd.json(@backlog&.call(project, b), column: col)
      out
    end

    def call(name, a)
      case name
      when "kanban_board" then dump(board_json(project!(a), column: a["column"], archived: a["archived"] == true))
      when "kanban_workflow" then dump(@store.board_json(project!(a)[:slug]))
      when "kanban_card" then dump(markdown_only(card_body(@store.card!(int!(a, "id")))))
      when "kanban_create"
        no_assignee!(a)
        project!(a)
        id = @store.create(slug: a["project"], title: str!(a, "title"), by: str!(a, "author"), agent: true,
                           owner_session: owner_session!(a),
                           column: a["column"], notes: a["description"].to_s, labels: a["labels"] || [],
                           priority: a["priority"], due: a["due"], parent: a["parent"], metadata: a["metadata"])
        dump(row(@store.card(id)))
      when "kanban_register"
        p = project!(a)
        session = live_session!(a)
        @store.not_registered!(session)
        live = live_sessions!
        @store.launch_check!(type: str!(a, "type"), project: p[:slug], live: live, grace: @grace)
        reg = @store.register_session(session: session, project: p[:slug], type: a["type"], launcher: a["launcher"],
                                      by: str!(a, "author"))
        dump(reg.merge(adopted: reg[:adopted].map { |cid| row(@store.card(cid)).slice(:id, :title, :column, :column_label) },
                       concurrency: @store.concurrency(live, grace: @grace).slice(:max_sessions, :running, :free)))
      when "kanban_move"
        dump(row(@store.move(int!(a, "id"), column: a["column"], transition: a["transition"], position: a["position"],
                                            by: str!(a, "author"), agent: true)))
      when "kanban_update"
        no_assignee!(a)
        attrs = a.slice("title", "labels", "priority", "due", "due_done", "cover", "parent", "metadata")
        attrs["notes"] = a["description"] if a.key?("description")
        dump(row(@store.update(int!(a, "id"), attrs, by: str!(a, "author"))))
      when "kanban_comment"
        c = @store.card!(int!(a, "id"))
        dump(id: @store.comment(c[:id], body: str!(a, "body"), author: str!(a, "author")),
             delivered: @store.delivery(c, a["author"]))
      when "kanban_ask"
        session = a["tmux_session"].to_s.strip.empty? ? nil : live_session!(a)
        dump(row(@store.ask(int!(a, "id"), question: str!(a, "question"), options: a["options"], by: str!(a, "author"),
                                           session: session)))
      when "kanban_comment_edit"
        e = @store.comment_edit(int!(a, "comment_id"), body: str!(a, "body"), by: str!(a, "author"))
        dump(@store.activity_json(e).except(:body_html))
      when "kanban_comment_delete"
        dump(deleted: int!(a, "comment_id"), card: @store.comment_delete(int!(a, "comment_id"), by: str!(a, "author")))
      when "kanban_handoff"
        raise Invalid, "ui_change must be true or false" unless [true, false].include?(a["ui_change"])

        dump(row(@store.handoff(int!(a, "id"), qa: str!(a, "qa"), pr_url: a["pr_url"].to_s, ci_url: a["ci_url"].to_s,
                                               ui_change: a["ui_change"], by: str!(a, "author"),
                                               transition: a["transition"], column: a["column"],
                                               review_summary: a["review_summary"])))
      when "kanban_block"
        dump(row(@store.block(int!(a, "id"), reason: str!(a, "reason"), url: str!(a, "url"), by: str!(a, "author"))))
      when "kanban_unblock"
        dump(row(@store.unblock(int!(a, "id"), note: a["note"], by: str!(a, "author"))))
      when "kanban_claim"
        who = str!(a, "assignee")
        id = @store.card!(int!(a, "id"))[:id]
        session = live_session!(a)
        dump(row(@store.claim(id, assignee: who, session: session)))
      when "kanban_attach" then attach(a)
      when "kanban_attachments" then dump(@attachments.list_json(@store.card!(int!(a, "id"))[:id]))
      when "kanban_attachment_get" then dump(@attachments.read_for_agent(int!(a, "attachment_id")))
      else labels_and_checklists(name, a)
      end
    end

    # {card (+ the attachment list), activity} for an agent (markdown only: see markdown_only).
    def card_body(c)
      body = @store.card_body(c)
      body[:card] = body[:card].merge(url: url(c), attachments: @attachments.list_json(c[:id]))
      body
    end

    private

    # The attachment, then (with comment) the comment carrying its snippet — Store#comment links the file to it and
    # pings the owner.
    def attach(a)
      id = int!(a, "id")
      by = str!(a, "author")
      name = str!(a, "filename")
      has_b64 = !a["content_base64"].nil?
      has_path = !a["project_path"].nil?
      raise Invalid, "give exactly one of content_base64 or project_path" unless has_b64 ^ has_path
      if a.key?("comment") && !(a["comment"].is_a?(String) && !a["comment"].strip.empty?)
        raise Invalid, "comment must be non-empty markdown when given"
      end

      card = @store.card!(id)
      row = if has_b64
              @attachments.add_base64(card[:id], filename: name, data: a["content_base64"], by: by)
            else
              @attachments.add_project_file(card[:id], project: @projects.call(card[:project_slug]),
                                                       project_path: a["project_path"], filename: name, by: by)
            end
      comment_id = nil
      if a["comment"]
        comment_id = @store.comment(card[:id], body: "#{a['comment'].rstrip}\n\n#{@attachments.snippet(row)}", author: by)
        row = @attachments.find(row[:id])
      end
      dump(attachment: @attachments.json(row), comment_id: comment_id)
    end

    def labels_and_checklists(name, a)
      case name
      when "kanban_labels" then dump(labels(project!(a)[:slug]))
      when "kanban_label_save"
        slug = project!(a)[:slug]
        str!(a, "author")
        l = @store.labels(slug).find { |x| x[:name] == a["name"].to_s.strip }
        if l
          unless a["color"] || a["new_name"]
            raise Invalid, "label #{l[:name].inspect} exists: give color and/or new_name to change it"
          end

          @store.label_update(l[:id], name: a["new_name"], color: a["color"])
        else
          raise Invalid, "color is required for a new label (one of #{@config.label_colors.join(', ')})" unless a["color"]

          @store.label_create(slug, name: str!(a, "name"), color: a["color"])
        end
        dump(labels(slug))
      when "kanban_label_delete"
        slug = project!(a)[:slug]
        str!(a, "author")
        @store.label_delete(@store.label_by_name!(slug, str!(a, "name"))[:id])
        dump(labels(slug))
      when "kanban_labels_set"
        raise Invalid, "labels is required (an array; [] clears)" unless a["labels"].is_a?(Array)

        dump(row(@store.update(int!(a, "id"), { "labels" => a["labels"] }, by: str!(a, "author"))))
      when "kanban_due_set"
        raise Invalid, "due is required (empty string clears)" unless a.key?("due")

        attrs = { "due" => a["due"] }
        attrs["due_done"] = a["done"] if a.key?("done")
        dump(row(@store.update(int!(a, "id"), attrs, by: str!(a, "author"))))
      when "kanban_checklist_add"
        id = int!(a, "id")
        @store.checklist_add(id, title: str!(a, "title"), items: a["items"] || [], by: str!(a, "author"))
        card_md(id)
      when "kanban_checklist_rename"
        cl = @store.checklist_rename(int!(a, "checklist_id"), title: str!(a, "title"), by: str!(a, "author"))
        card_md(cl[:card_id])
      when "kanban_checklist_delete"
        card_md(@store.checklist_delete(int!(a, "checklist_id"), by: str!(a, "author"))[:card_id])
      when "kanban_checklist_item_add"
        cl = @store.checklist!(int!(a, "checklist_id"))
        @store.item_add(cl[:id], body: str!(a, "body"), by: str!(a, "author"))
        card_md(cl[:card_id])
      when "kanban_checklist_item_edit"
        item_md(@store.item_update(int!(a, "item_id"), body: str!(a, "body"), by: str!(a, "author")))
      when "kanban_checklist_toggle"
        raise Invalid, "done must be true or false" unless [true, false].include?(a["done"])

        item_md(@store.item_update(int!(a, "item_id"), done: a["done"], by: str!(a, "author")))
      when "kanban_checklist_item_delete" then item_md(@store.item_delete(int!(a, "item_id"), by: str!(a, "author")))
      when "kanban_checklist_item_convert"
        dump(row(@store.card(@store.item_convert(int!(a, "item_id"), by: str!(a, "author"), agent: true))))
      else
        raise Invalid, "unknown tool: #{name}"
      end
    end

    # Agents never set an assignee directly: a card's assignee must come with a session that listens.
    def no_assignee!(a)
      return unless a.key?("assignee")

      raise Denied, "agents do not set assignee here — use kanban_claim(id, assignee, tmux_session) so your tmux session " \
                    "receives the operator's comments (an assignee without a listening session is how comments vanished)"
    end

    # tmux_session must name a live tmux session (the host's `sessions` port); the port down → refused, never assumed.
    def live_session!(a)
      s = a["tmux_session"].to_s.strip
      if s.empty?
        raise Invalid, "tmux_session is required: your tmux session name (tmux display -p '#S') — it receives the " \
                       "card's comments"
      end
      raise Invalid, "tmux_session must match #{Store::SESSION.source}" unless s.match?(Store::SESSION)

      live = live_sessions!
      return s if live.include?(s)

      raise Invalid, "no tmux session #{s.inspect} is running (run `tmux display -p '#S'` inside your session); " \
                     "live: #{live.first(20).join(', ')}"
    end

    def live_sessions!
      @sessions.call
    rescue Delivery::Unavailable, Delivery::Refused => e
      raise Invalid, "cannot verify tmux sessions: #{e.message} — try again when the launcher is up"
    end

    # The session a created card is owned by: tmux_session (verified live), else the open registration whose agent
    # name (or session name) is the author. Neither → refused: an agent-made card is never ownerless.
    def owner_session!(a)
      return live_session!(a) unless a["tmux_session"].to_s.strip.empty?

      reg = @store.session_for_author(a["author"])
      return reg[:session] if reg

      raise Denied, "a card an agent creates is owned by its session: pass tmux_session (tmux display -p '#S'), " \
                    "or author as the agent name of a registered session (kanban_register returns it) — " \
                    "#{a['author'].inspect} is neither"
    end

    # (parenthesised: in an endless def `x = a or raise` parses as `(x = a) or raise`, and the raise is lost)
    def project!(a) = (@projects.call(str!(a, "project")) || raise(Invalid, "no project #{a['project']}"))
    def labels(slug) = @store.labels(slug).map { |l| @store.label_json(l) }
    def card_md(card_id)
      card = markdown_only(card_body(@store.card!(card_id)))[:card]
      dump(card.slice(:id, :title, :checklist_done, :checklist_total, :checklists))
    end

    def item_md(item) = card_md(@store.checklist!(item[:checklist_id])[:card_id])

    # Agents read markdown: drop the server-rendered *_html copies.
    def markdown_only(obj)
      case obj
      when Hash then obj.reject { |k, _| k.to_s.end_with?("_html") }.transform_values { |v| markdown_only(v) }
      when Array then obj.map { |v| markdown_only(v) }
      else obj
      end
    end

    def row(c) = @store.card_json(c).merge(url: url(c))
    def url(c) = @card_url.call(c[:project_slug], c[:id])
    def dump(obj) = JSON.pretty_generate(obj)

    def str!(a, key)
      v = a[key]
      raise Invalid, "#{key} is required" unless v.is_a?(String) && !v.strip.empty?

      v
    end

    def int!(a, key)
      raise Invalid, "#{key} is required" unless a.key?(key)

      Integer(a[key])
    end
  end
end
