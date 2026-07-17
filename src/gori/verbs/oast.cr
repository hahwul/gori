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

      # `g`/`y` are handled directly in the controller for the body; expose them in the
      # space menu too (menu-only, no chord).
      r.register Verb::Definition.new(
        "oast.generate", "Get payload URL", "Get + copy a fresh OAST payload URL from the selected provider",
        Verb::Scope::OastCallbacks, [] of Verb::Chord, mnemonic: 'g') { |ctx| ctx.oast_generate; nil }

      r.register Verb::Definition.new(
        "oast.copy", "Copy payload URL", "Copy the last generated OAST payload URL to the clipboard",
        Verb::Scope::OastCallbacks, [] of Verb::Chord, mnemonic: 'y') { |ctx| ctx.oast_copy; nil }

      r.register Verb::Definition.new(
        "oast.filter", "Filter callbacks", "Filter the callbacks list by protocol/method/source/destination/provider",
        Verb::Scope::OastCallbacks, [Verb::Chord.new("/")], mnemonic: 'f') { |ctx| ctx.oast_filter; nil }

      r.register Verb::Definition.new(
        "oast.callbacks-to-menu", "Back to menu", "Move focus up to the tab menu",
        Verb::Scope::OastCallbacks, [Verb::Chord.new("escape")], hidden: true) { |ctx| ctx.focus_pane(:menu); nil }

      # --- Providers sub-tab (a/e/t/d handled in the controller body; menu-only here) ---
      r.register Verb::Definition.new(
        "oast.add-provider", "Add provider", "Add an OAST provider (interactsh + friends; presets prefilled)",
        Verb::Scope::OastProviders, [] of Verb::Chord, mnemonic: 'a') { |ctx| ctx.oast_add_provider; nil }

      r.register Verb::Definition.new(
        "oast.edit-provider", "Edit provider", "Edit the selected OAST provider",
        Verb::Scope::OastProviders, [] of Verb::Chord, mnemonic: 'e') { |ctx| ctx.oast_edit_provider; nil }

      r.register Verb::Definition.new(
        "oast.toggle-provider", "Enable / disable", "Toggle the selected provider on or off",
        Verb::Scope::OastProviders, [] of Verb::Chord, mnemonic: 't') { |ctx| ctx.oast_toggle_provider; nil }

      r.register Verb::Definition.new(
        "oast.delete-provider", "Delete provider", "Delete the selected provider (keeps its callback history)",
        Verb::Scope::OastProviders, [] of Verb::Chord, mnemonic: 'd') { |ctx| ctx.oast_delete_provider; nil }

      r.register Verb::Definition.new(
        "oast.providers-to-menu", "Back to menu", "Move focus up to the tab menu",
        Verb::Scope::OastProviders, [Verb::Chord.new("escape")], hidden: true) { |ctx| ctx.focus_pane(:menu); nil }

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
