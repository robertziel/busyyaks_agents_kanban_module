# frozen_string_literal: true

require "set"
require_relative "errors"

module AgentsKanban
  # One pass of the card notifier: deliver pending pings to owner sessions, then (every `watch_every`, the host's loop
  # decides) run the watch pass. Delivery: sent → done; session gone → failed (the watchdog releases the card);
  # busy/stale → stays pending, failed after `give_up` seconds with the last reason.
  #
  # The watch pass, in order, on the host's live session list (`client.sessions`; unreachable → the pass is skipped and
  # said, nothing is released or ended — the agent-detection snapshot is NOT the liveness source):
  #   1. the session registry is reconciled (Store#sessions_sync): a registered session not in the snapshot is ended
  #      — after `grace` seconds from its registration, so a launch has time to appear;
  #   2. open session-dialog questions whose dialog is no longer on the screen are expired (Store#expire_dialogs):
  #      somebody answered it in the terminal, or the session is gone — the card goes back to work;
  #   3. the owner watchdog (Store#watch_owners): a card whose owner session is gone for `grace` seconds is released;
  #   3a. the flag reminders (config.flags.reminder_hours): a card flagged needs_operator / blocked_external that long
  #       gets ONE reminder comment by the system author (Store#flag_reminders);
  #   3b. the idle watch (config.idle_watch, the host's `ci:` port): CI finished + owner silent → ping, then comment;
  #       a live owner quiet for hours → comment;
  #   3c. the approval prefetch (config.approval.requires_green_ci, the Store's `ci:` port): every card in a gate an
  #       approval step leaves from has its step's checks asked again (Store#approval_prefetch_pass), so the host keeps a
  #       fresh answer and Approve never waits for a CI read; a card the port cannot answer is logged;
  #       The same pass is the gate watch (card #248): a gate card whose CI turned red pings its owner once; one whose
  #       hold cleared logs "ready for your approval" once;
  #   4. owner sessions the collector snapshot shows waiting get their screen read: a dialog becomes ONE ask-gate question
  #      once it has stayed on the screen session_dialogs.settle_seconds (first seen → still there that much later);
  #      a host with no collector (agents Refused) or an unreachable one turns off only this step ("dialog scan off");
  #      a screen that cannot be read skips only that session ("dialog read failed on <session>").
  # Before each delivery the owner's screen is read too: a dialog there becomes the question and the ping waits —
  # never typed into a dialog, never given up on; a clear screen expires that session's open dialog questions.
  #
  # client: the DELIVERY port (see Delivery in errors.rb). log: anything with puts.
  class Notifier
    def initialize(store, client:, clock: -> { Time.now.to_i }, give_up: 30 * 60, grace: 60, spawner: nil, ci: nil,
                   log: $stdout)
      @store = store
      @client = client
      @clock = clock
      @give_up = give_up
      @grace = grace
      @spawner = spawner # -> { Api#spawn_pass }: one new session per ownerless card in a spawns_for column
      @settle = store.config.session_dialogs.settle_seconds
      @first_seen = {} # session => [dialog hash, first read at]: a dialog is asked only once it has settled
      @dialog_scan_off = nil # why the host does not answer the collector snapshot (nil = it does): logged on change
      @dialog_read_failed = {} # session => why its screen could not be read in the last dialog scan: logged on change
      @prefetch_failed = {} # card id => why the approval prefetch could not ask its checks: logged on change
      @log = log
      # the idle watch's port (errors.rb, CiChecks): a board with idle_watch configured and no port is a wiring error
      @ci = ci
      if store.config.idle_watch && ci.nil?
        raise ConfigError, "host config has idle_watch but the Notifier got no ci: port (pr_checks, last_commit_at)"
      end
      if ci && !(ci.respond_to?(:pr_checks) && ci.respond_to?(:last_commit_at))
        raise ConfigError, "the ci: port must answer pr_checks(card) and last_commit_at(card)"
      end
    end

    def deliver
      @store.pending_pings.each do |p|
        d = dialog(p[:session], p[:socket], card_id: p[:card_id])
        if d
          # a dialog on the screen: the ping waits — never typed into it — whether or not it was asked yet
          @store.ping_result(p, "pending", error: d)
          next
        end
        r = @client.notify(session: p[:session], socket: p[:socket], text: p[:text])
        if r["ok"]
          @store.ping_result(p, "sent")
        elsif r["gone"] || r["unsupported"]
          @store.ping_result(p, "failed", error: r["error"])
        elsif @clock.call - p[:created_at] > @give_up
          @store.ping_result(p, "failed", error: "gave up after #{@give_up / 60} min: #{r['error']}")
        else
          @store.ping_result(p, "pending", error: r["error"])
        end
        @log.puts("ping ##{p[:id]} card #{p[:card_id]} → #{p[:session]}: #{r['ok'] ? 'sent' : r['error']}")
      end
    rescue Delivery::Unavailable => e
      @log.puts("deliver skipped: #{e.message}")
    end

    def watch
      # LIVE = the host's real sessions (tmux), NOT the agent-detection snapshot: a session whose engine the collector
      # does not recognise (mid-restart, a plain shell, a different engine) is still alive, and releasing its cards
      # for that would be a false "session is gone" release.
      live = @client.sessions.map { |s| s["name"] }.to_set
      ended = @store.sessions_sync(live, grace: @grace)
      @log.puts("sessions ended (gone): #{ended.join(', ')}") if ended.any?
      expired = @store.expire_dialogs(check: ->(session, socket) { @client.dialog(session: session, socket: socket) })
      @log.puts("dialogs expired on cards #{expired.join(', ')}") if expired.any?
      released = @store.watch_owners(live, grace: @grace)
      # every taken card gets an ALIVE owner and an assignee — on the first pass after the host starts too
      taken = @store.adopt_ownerless(live: live, grace: @grace)
      @log.puts("intake assigned cards #{taken.join(', ')}") if taken.any?
      if @spawner
        spawned = @spawner.call
        @log.puts("spawned a session for cards #{spawned.join(', ')}") if spawned.any?
      end
      @log.puts("watchdog released cards #{released.join(', ')}") if released.any?
      reminded = @store.flag_reminders
      @log.puts("flag reminders on cards #{reminded.join(', ')}") if reminded.any?
      shelved = @store.session_boards_expire_pass
      @log.puts("session boards archived (inactive): #{shelved.join(', ')}") if shelved.any?
      idle_watch(live)
      approval_prefetch
      watch_dialogs
      released
    rescue Delivery::Unavailable, Delivery::Refused => e
      @log.puts("watchdog skipped: #{e.message}")
      []
    end

    # CI finished with nobody acting, and live owners gone quiet (Store#idle_watch_pass). A port that cannot answer
    # skips this step and says so; nothing is guessed.
    def idle_watch(live)
      return unless @store.config.idle_watch

      @store.idle_watch_pass(live: live, ci: @ci).each { |id, what| @log.puts("idle watch: #{what} on card #{id}") }
    rescue Delivery::Unavailable, Delivery::Refused => e
      @log.puts("idle watch skipped: #{e.message}")
    end

    # The gate's PR checks of every card waiting for an approval, asked again (Store#approval_prefetch_pass): the host's
    # answer stays fresh, so Approve answers at once. A card the port could not answer is said, never guessed.
    UNAVAILABLE = "unavailable: " # Store#approval_prefetch_pass's mark of a card the port could not answer

    # Said once per change of reason per card, and once when it answers again.
    def approval_prefetch
      pass = @store.approval_prefetch_pass
      failed = pass.filter_map { |id, what| [id, what.delete_prefix(UNAVAILABLE)] if what.start_with?(UNAVAILABLE) }.to_h
      failed.each { |id, why| @log.puts("approval prefetch: card #{id}: #{why}") unless @prefetch_failed[id] == why }
      recovered = (@prefetch_failed.keys & pass.map(&:first)) - failed.keys # a card that left the gate is not said
      recovered.each { |id| @log.puts("approval prefetch: card #{id} answered again") }
      pass.each do |id, _, event|
        said = { red: "CI failed, owner pinged", red_nobody: "CI failed, no owner session to ping",
ready: "ready for approval", }
        @log.puts("gate watch: card #{id} #{said.fetch(event)}") if event
      end
      @prefetch_failed = failed
    end

    # Owner sessions the collector snapshot shows waiting get their screen read. A stale snapshot skips only this step
    # (liveness never depends on it). A host that cannot or will not answer the snapshot (no collector configured →
    # Refused, launcher down → Unavailable) turns only this step off: said once per change of reason, and once when it
    # answers again — the watchdog steps before it already ran and are not "skipped".
    def watch_dialogs
      snap = collector_snapshot
      return unless snap

      if snap["age_s"].to_f > 3 * snap["interval_s"].to_f
        @log.puts("dialog scan skipped: collector snapshot #{snap['age_s']}s old")
        return
      end
      owners = @store.owner_sessions
      snap["sessions"].each do |s|
        next unless owners.include?(s["name"]) && Array(s["panes"]).any? { |pn| pn["waiting_for"] }

        read_dialog(s["name"], s["socket"] || "default")
      end
    end

    # One owner's screen in the dialog scan: a failed read skips only this session — the others are still read — and is
    # logged when its reason changes, and once when the session's screen answers again.
    def read_dialog(session, socket)
      dialog(session, socket)
      @log.puts("dialog read on #{session}: answers again") if @dialog_read_failed.delete(session)
    rescue Delivery::Unavailable, Delivery::Refused => e
      @log.puts("dialog read failed on #{session}: #{e.message}") unless @dialog_read_failed[session] == e.message
      @dialog_read_failed[session] = e.message
    end

    # The collector snapshot, or nil when the host refuses / cannot answer it (logged on a change of state only).
    def collector_snapshot
      snap = @client.agents
      @log.puts("dialog scan on: collector answers again") if @dialog_scan_off
      @dialog_scan_off = nil
      snap
    rescue Delivery::Unavailable, Delivery::Refused => e
      @log.puts("dialog scan off: #{e.message}") unless @dialog_scan_off == e.message
      @dialog_scan_off = e.message
      nil
    end

    # nil when the session's screen shows no dialog; else why a ping to it waits: the card the dialog is (now or
    # already) asked on, that it is settling (asked once it stays settle_seconds), or that no card can take the question
    # (the session owns none outside the operator's columns / its board has no ask column). A clear screen expires the
    # session's open dialog questions.
    def dialog(session, socket, card_id: nil)
      r = @client.dialog(session: session, socket: socket)
      # open dialog questions of this session that are not the dialog on its screen now are over
      expired = @store.expire_dialogs(check: ->(*) { r }, session: session)
      @log.puts("dialog gone on #{session} → cards #{expired.join(', ')} back to work") if expired.any?
      unless r["ok"] && r["dialog"]
        @first_seen.delete(session) if r["ok"]
        return nil
      end

      h = r["dialog"]["hash"]
      seen = @first_seen[session]
      @first_seen[session] = seen = [h, @clock.call] unless seen && seen[0] == h
      waited = @clock.call - seen[1]
      return "a dialog is on its screen — asked if it is still there in #{@settle - waited}s" if waited < @settle

      posted = @store.dialog_question(session: session, socket: socket, dialog: r["dialog"], card_id: card_id)
      if posted
        @log.puts("dialog on #{session} → question on card ##{posted}")
        return on_card(posted)
      end
      asked = @store.dialog_card(session, h)
      return on_card(asked) if asked

      "a dialog is on its screen — no card to ask it on (the session owns none outside the operator's columns, or its " \
        "board has no ask column)"
    end

    def on_card(id)
      c = @store.card!(id)
      "a dialog is on its screen — asked on card ##{id} (needs_operator, #{c[:column_label]})"
    end
  end
end
