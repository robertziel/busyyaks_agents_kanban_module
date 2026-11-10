# frozen_string_literal: true

module AgentsKanban
  # Every refusal the engine makes is one of these, with the reason in the message. Nothing is coerced into a
  # default column, priority, label or date: a bad input raises, the host answers 422 (or an MCP isError result).
  class Invalid < ArgumentError; end
  # A rule refusal (who may do what): a subclass so a host can tell "bad input" from "not allowed" when it wants to.
  class Denied < Invalid; end
  # The board configuration itself is wrong (a missing key, an unknown column) — raised at boot, never at a request.
  class ConfigError < StandardError; end

  # The DELIVERY port: how a ping reaches an owner session. The host hands the Notifier (and the Tools' live-session
  # check) a client that answers
  #   notify(session:, socket:, text:) → {"ok"=>true}
  #                                     | {"ok"=>false, "gone"=>true|"retry"=>true|"unsupported"=>true, "error"=>..}
  #   sessions                        → [{"name"=>..}] every live session of the host (tmux) — the watchdog's
  #                                     liveness; NOT agent detection
  #   agents                          → {"age_s"=>, "interval_s"=>,
  #                                      "sessions"=>[{"name"=>, "socket"=>, "panes"=>[{"waiting_for"=>..}]}]}
  #   dialog(session:, socket:)       → {"ok"=>true, "dialog"=>SessionDialog.parse(screen) | nil} | {"ok"=>false, ..}
  # and raises these when it cannot reach its transport (Unavailable) or the transport refuses (Refused). The engine
  # never swallows either: a notifier pass is skipped and said so, a claim is refused with the reason.
  # The CI port (Notifier ci:, only when the board config has idle_watch): what the host knows of a card's PR checks.
  #   pr_checks(card)    → nil (the card has no PR)
  #                        | {number:, state: "success"|"failure"|"pending"|<anything else = not finished>,
  #                           finished_at: epoch|nil}
  #                        the PR is the card's pr_url, else the open PR on the owner's branch (the host decides how
  #                        it finds it)
  #   last_commit_at(card) → epoch of the newest commit on the owner's branch | nil when there is none
  # The approval gate (Store ci:, only when the host config has approval.requires_green_ci):
  #   approval_checks(card, step) → the same answer as pr_checks for the PR this approval step is about (step =
  #                        {from:, to:, then:, name:, final:}); approved only on state "success". Any other answer
  #                        may carry reason: — the host's own words for the refusal (e.g. "the local PR #12 is not
  #                        merged"), shown in place of the state's. Also asked AHEAD, its answer discarded: at a
  #                        handoff into the step's gate and on every notifier watch pass for each card waiting there
  #                        (Store#approval_prefetch_pass), so a host answering asynchronously keeps the answer fresh.
  #                        A green answer may carry head: (the PR head sha): the handoff records it and the card waits
  #                        for the operator only while later answers carry the same head (Store#gate_hold)
  # Both raise Delivery::Unavailable when they cannot answer (token rejected, rate limited, unreachable).
  module CiChecks; end

  module Delivery
    class Unavailable < StandardError; end
    class Refused < StandardError; end
  end
end
