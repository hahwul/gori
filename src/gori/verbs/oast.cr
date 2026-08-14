require "../verb"

module Gori
  module Verbs
    # Verbs for the OAST tab (Callbacks + Providers sub-tabs) and the cross-tab
    # "Insert OAST payload" actions in Repeater/Fuzzer/History.
    def self.register_oast(r : Verb::Registry) : Nil
      # --- Callbacks sub-tab ---
      r.register Verb::Definition.new(
        "oast.listen", "Start listening", "Register the selected provider and poll for callbacks",
        Verb::Scope::OastCallbacks, [Verb::Chord.new("r", ctrl: true)], mnemonic: 'l') { |ctx| ctx.oast_listen; nil }

      r.register Verb::Definition.new(
        "oast.stop", "Stop listening", "Stop polling the selected provider (deregisters)",
        Verb::Scope::OastCallbacks, [Verb::Chord.new("x", ctrl: true)], mnemonic: 's') { |ctx| ctx.oast_stop; nil }

      # `g` carries its chord HERE rather than in the controller's key handler, which is where it
      # used to live: with the provider bar on "All" and two or more providers enabled, getting a
      # payload opens a picker card, and a controller cannot open an overlay (same reason `r` and
      # `a` are verbs). Routing it through the verb also means the chord and the space-menu entry
      # take the identical path. `y` stays controller-side — it only ever copies.
      r.register Verb::Definition.new(
        "oast.generate", "Get payload URL", "Get + copy a fresh OAST payload URL (asks which provider when several are on)",
        Verb::Scope::OastCallbacks, [Verb::Chord.new("g")], mnemonic: 'g') { |ctx| ctx.oast_generate; nil }

      r.register Verb::Definition.new(
        "oast.copy", "Copy payload URL", "Copy the last generated OAST payload URL to the clipboard",
        # `section: :list`, not :common: the callback DETAIL's own `y` copies what came back, and
        # this one copies the payload gori sent — opposite directions of one interaction, and
        # `Registry#validate_menu_keys!` refuses one letter for two meanings inside a view. The
        # verb is also meaningless with a detail open, where there is no payload in front of you.
        Verb::Scope::OastCallbacks, [] of Verb::Chord, mnemonic: 'y',
        section: :list) { |ctx| ctx.oast_copy; nil }

      r.register Verb::Definition.new(
        "oast.filter", "Filter callbacks", "Filter the callbacks list by protocol/method/source/destination/provider",
        Verb::Scope::OastCallbacks, [Verb::Chord.new("/")], mnemonic: 'f') { |ctx| ctx.oast_filter; nil }

      # Resume a persisted session. A plain `r`, not a ^-chord: ^R/^X already carry the pair
      # you drum on, and this is the one you reach for ONCE, at the start of a sitting.
      # OastController#handle_callbacks_key deliberately does not claim the letter — the
      # action opens an overlay, which a controller cannot do — so it falls through to here.
      r.register Verb::Definition.new(
        "oast.sessions", "Resume listener…", "Resume polling a saved session — its planted payloads still resolve",
        Verb::Scope::OastCallbacks, [Verb::Chord.new("r")], mnemonic: 'r') { |ctx| ctx.oast_sessions; nil }

      # Promote a callback to an Issue. ⇧F is History's `issue.create` chord deliberately —
      # "file what I'm looking at" is one gesture across the app, and Keymap#lookup is
      # per-scope so the two never resolve together. The chord is Chord.new("f", shift: true),
      # NOT Chord.new("F"): Keybind.from_event normalises a typed capital to shift+lowercase,
      # so an "F" chord would never fire; menu_key skips shift chords, hence the mnemonic.
      r.register Verb::Definition.new(
        "oast.issue", "Add issue", "File the selected callback as an Issue, with its raw interaction as evidence",
        Verb::Scope::OastCallbacks, [Verb::Chord.new("f", shift: true)],
        available: ->(ctx : Verb::ExecContext) { ctx.oast_callback_selected? },
        mnemonic: 'a', group: :triage) { |ctx| ctx.oast_issue_create; nil }

      # No `escape` verb for either sub-tab. `OastController#handle_callbacks_key` /
      # `#handle_providers_key` claim escape first and return true, so a registration here
      # could never fire — and the two that used to sit here said `focus_pane(:menu)` while
      # the live handler goes to `:subtabs`, which is where the tab's `esc tabs` hint came
      # from. Escape is the controller's, and the hint now says `esc sub-tabs`.

      # --- Providers sub-tab (a/e/t/d handled in the controller body; menu-only here) ---
      r.register Verb::Definition.new(
        "oast.add-provider", "Add provider", "Add an OAST provider (interactsh + friends; presets prefilled)",
        Verb::Scope::OastProviders, [] of Verb::Chord, mnemonic: 'a') { |ctx| ctx.oast_add_provider; nil }

      r.register Verb::Definition.new(
        "oast.edit-provider", "Edit provider", "Edit the selected OAST provider",
        Verb::Scope::OastProviders, [] of Verb::Chord, mnemonic: 'e') { |ctx| ctx.oast_edit_provider; nil }

      r.register Verb::Definition.new(
        "oast.toggle-provider", "Enable / disable", "Toggle the selected provider on or off",
        Verb::Scope::OastProviders, [] of Verb::Chord, mnemonic: 'x') { |ctx| ctx.oast_toggle_provider; nil }

      r.register Verb::Definition.new(
        "oast.delete-provider", "Delete provider", "Delete the selected provider (keeps its callback history)",
        Verb::Scope::OastProviders, [] of Verb::Chord, mnemonic: 'd') { |ctx| ctx.oast_delete_provider; nil }

      # --- cross-tab: insert / copy a fresh OAST payload (gated on an active listener) ---
      insert_avail = ->(tab : Symbol) {
        ->(ctx : Verb::ExecContext) { ctx.current_tab == tab && ctx.oast_payload_available? }
      }

      r.register Verb::Definition.new(
        "repeater.oast-insert", "Insert OAST payload", "Insert a fresh OAST payload URL at the request cursor",
        Verb::Scope::Repeater, available: insert_avail.call(:repeater), mnemonic: 'O') { |ctx| ctx.oast_insert_payload; nil }

      r.register Verb::Definition.new(
        "fuzzer.oast-insert", "Insert OAST payload", "Insert a fresh OAST payload URL at the template cursor",
        Verb::Scope::Fuzzer, available: insert_avail.call(:fuzzer), mnemonic: 'O') { |ctx| ctx.oast_insert_payload; nil }

      r.register Verb::Definition.new(
        "history.oast-copy", "Copy OAST payload", "Copy a fresh OAST payload URL to the clipboard",
        Verb::Scope::Body, available: insert_avail.call(:history), mnemonic: 'O') { |ctx| ctx.oast_copy_payload; nil }
    end
  end
end
