# frozen_string_literal: true

require_relative "errors"
require_relative "store"
require_relative "launch"

module AgentsKanban
  # THE way the engine starts an agent session (lead-first boards) — Api#launch (the operator's Launch bar)
  # and kanban_spawn (a lead starting a worker for a card) both come here, and nothing else in the library calls the
  # host's launcher `start` (test/no_leadless_spawn_test.rb holds that). In order:
  #   1. the caps, on a fresh live list (Store#launch_check!: Denied with who runs);
  #   2. a type `under` a lead: the board's RUNNING lead (Store#running_lead!: none → Denied "launch the lead first";
  #      a spawn names its lead, which must be that one) and its launcher (another asked for → Denied);
  #   3. a free session name from the host, the REGISTRATION (Store#register_session: lead_id required for a type under a
  #      lead, the DB's CHECK too; a lead mints its key), the plan (Launch.plan);
  #   4. the host's start — with `lead_key` (a lead: its key, which the host's launcher keeps in its own state and gives
  #      back only through the port's `lead_key(session:)`; never into the session, a JSON answer or a log; nil for any
  #      other session) and `lead` (the lead's tmux session a session under a lead runs under: the host refuses the
  #      start unless it started that lead itself, for that project, and it runs). A failed start ends the registration
  #      (Store::START_FAILED) and releases what it took.
  # The engine never starts a session on its own: no pass, no notifier, no watchdog calls this.
  class Team
    # store: Store · launcher: the host's LAUNCH port (`name(project:, base:)`, `start(session:, project:, type:,
    # launcher:, argv:, prompt_template:, vars:, lead_key:, lead:)`, `lead_key(session:)` → the key the host keeps for
    # a lead it started; raises Delivery::Unavailable / Refused) · sessions:
    # -> live tmux session names · grace: seconds a registration counts as running before it is live.
    def initialize(store:, launcher:, sessions:, grace:)
      raise ArgumentError, "Team needs a launcher: and a sessions: port" unless launcher && sessions

      @store = store
      @config = store.config
      @launcher = launcher
      @sessions = sessions
      @grace = grace
    end

    # → {reg (the registration, no key), plan, result (the host's)}. project: the host's project Hash. lead: the lead
    # registration row a spawn is asked by (kanban_spawn) — it must be the board's running lead. for_cards + from_owner:
    # a spawn's card, taken from its owner (the lead) or from nobody.
    def start(project:, type:, by:, asked_launcher: nil, lead: nil, for_cards: nil, from_owner: nil)
      t = @config.agent_type(type)
      slug = project[:slug]
      live = @sessions.call
      @store.launch_check!(type: t.key, project: slug, live: live, grace: @grace)
      running = t.under ? @store.running_lead!(type: t.key, project: slug, live: live, grace: @grace) : nil
      if lead && running && lead[:id] != running[:id]
        raise Denied, "#{lead[:session]} is not the running #{t.under} of #{slug} (#{running[:session]} is)"
      end
      raise Invalid, "agent type #{t.key} runs under no lead — it is not spawned by one" if lead && !running

      lk = @store.launcher_for!(type: t.key, asked: asked_launcher, lead: running)
      session = @launcher.name(project: project, base: @config.session_name(t, slug: slug)).to_s
      key = nil # a lead's key, handed only to the host's start below (never part of reg)
      reg = @store.register_session(session: session, project: slug, type: t.key, launcher: lk, by: by,
                                    for_cards: for_cards, from_owner: from_owner, lead_id: running&.dig(:id),
                                    key_to: ->(k) { key = k })
      if for_cards && reg[:adopted].empty?
        @store.end_session(session, reason: "card #{Array(for_cards).join(', ')} was taken before its spawn", by: by)
        raise Invalid, "card #{Array(for_cards).join(', ')} is no longer #{from_owner ? "owned by #{from_owner}" : 'ownerless'}"
      end
      plan = Launch.plan(@config, type: t.key, launcher: lk, session: session, slug: slug, cards: reg[:adopted])
      result = begin
        @launcher.start(session: session, project: project, type: t.key, launcher: lk, argv: plan[:argv],
                        prompt_template: plan[:prompt_template], vars: plan[:vars],
                        lead_key: key, lead: running&.dig(:session))
      rescue Delivery::Unavailable, Delivery::Refused => e
        @store.end_session(session, reason: "#{Store::START_FAILED}#{e.message}", by: by)
        @store.release_session_cards(session, reason: "its start failed: #{e.message}", by: by)
        raise
      end
      { reg: reg, plan: plan, result: result, live: live }
    end
  end
end
