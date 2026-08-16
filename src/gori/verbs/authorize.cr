require "../verb"

module Gori
  module Verbs
    def self.register_authorize(r : Verb::Registry) : Nil
      queued = ->(ctx : Verb::ExecContext) { ctx.current_tab == :authorize && ctx.authorize_has_target? }
      # The run verbs go quiet while a run is in flight — one batch at a time, and the menu
      # should not offer a second one that would only be refused.
      idle = ->(ctx : Verb::ExecContext) {
        ctx.current_tab == :authorize && ctx.authorize_has_target? && !ctx.authorize_running?
      }
      busy = ->(ctx : Verb::ExecContext) { ctx.current_tab == :authorize && ctx.authorize_running? }

      # ^R / ^X are what every other workbench binds run / stop to (fuzz, mine, sequence,
      # discover), and they are free here because each is gated to its own tab.
      r.register Verb::Definition.new(
        "authorize.run", "Run pending",
        "Replay every queued request that has no result yet (never run, or the send failed)",
        Verb::Scope::Authorize, [Verb::Chord.new("r", ctrl: true)],
        available: idle, mnemonic: 'r') { |ctx| ctx.authorize_run; nil }

      # ⇧R against ^R mirrors Intercept's `f` / `⇧F` pair: the working set vs everything.
      # `Chord.new("r", shift: true)`, never `Chord.new("R")` — the latter never fires.
      r.register Verb::Definition.new(
        "authorize.run-all", "Run all",
        "Replay every queued request, re-sending the ones that already have a result",
        Verb::Scope::Authorize, [Verb::Chord.new("r", shift: true)],
        available: idle, mnemonic: 'a') { |ctx| ctx.authorize_run_all; nil }

      # `t` for "this", NOT Enter: `Verb::Reserved` holds Enter for activate/open across the
      # whole app, and a run is not an open. (Enter would also be exempt from the reserved
      # check only by carrying a second chord, which is not a reason to add one.)
      r.register Verb::Definition.new(
        "authorize.run-one", "Run this request",
        "Replay only the selected request under each identity",
        Verb::Scope::Authorize, [Verb::Chord.new("t")],
        available: idle, mnemonic: 't') { |ctx| ctx.authorize_run_one; nil }

      r.register Verb::Definition.new(
        "authorize.stop", "Stop",
        "Stop the run — no further identity is sent once the current one returns",
        Verb::Scope::Authorize, [Verb::Chord.new("x", ctrl: true)],
        available: busy, mnemonic: 's') { |ctx| ctx.authorize_stop; nil }

      # Available even with an empty queue: configuring who you are is what you do BEFORE
      # sending anything here. Only a live run locks it.
      r.register Verb::Definition.new(
        "authorize.identities", "Identities",
        "Edit the identities every request is replayed under (saved with the project)",
        Verb::Scope::Authorize, [Verb::Chord.new("i")],
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :authorize && !ctx.authorize_running? },
        mnemonic: 'i') { |ctx| ctx.authorize_identities; nil }

      # OFF by default and reachable only here. Passive replay is the one control in this tab
      # that sends without a keypress per request, so it gets an explicit switch rather than
      # riding on some other action.
      r.register Verb::Definition.new(
        "authorize.passive", "Passive replay",
        "Replay authenticated GETs under each identity as they are captured (off by default)",
        Verb::Scope::Authorize, [Verb::Chord.new("p")],
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :authorize },
        mnemonic: 'p') { |ctx| ctx.authorize_toggle_passive; nil }

      r.register Verb::Definition.new(
        "authorize.remove", "Remove request", "Drop the selected request from the queue",
        Verb::Scope::Authorize, [Verb::Chord.new("d")],
        available: queued, mnemonic: 'd', group: :danger) { |ctx| ctx.authorize_remove; nil }

      # Menu-only + 'X', the house shape for "wipe this tab" (history.clear, probe.clear).
      r.register Verb::Definition.new(
        "authorize.clear", "Clear", "Empty the request queue and its results",
        Verb::Scope::Authorize,
        available: queued, mnemonic: 'X', group: :danger) { |ctx| ctx.authorize_clear; nil }

      register_send_to_authorize(r)
    end

    # The "Send to Authorize" verbs, registered here (in the TARGET tab's file) rather than
    # scattered across each source — the same rule `register_send_to_comparer` follows.
    def self.register_send_to_authorize(r : Verb::Registry) : Nil
      r.register Verb::Definition.new(
        "history.authorize", "Send to Authorize",
        "Queue the selected flows in the Authorize (access-control) tab",
        Verb::Scope::Body,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :history && !ctx.selected_flow_ids.empty? },
        mnemonic: 'u', group: :send) { |ctx| ctx.authorize_seed_selected; nil }

      r.register Verb::Definition.new(
        "sitemap.authorize", "Send to Authorize",
        "Queue the selected endpoint's captured flow in the Authorize tab",
        Verb::Scope::Sitemap, mnemonic: 'u', group: :send) { |ctx| ctx.authorize_seed_sitemap; nil }
    end
  end
end
