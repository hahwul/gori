require "../verb"

module Gori
  module Verbs
    # The Params sub-tab's verbs (the parameter inventory under Target, #1231). Gated by
    # SCOPE alone, like Diff's — `Verb::Scope::Params` is only consulted while that sub-tab
    # is active — plus `params_rows_shown?` on the verbs that act on the cursor row.
    def self.register_params(r : Verb::Registry) : Nil
      r.register Verb::Definition.new(
        "params.down", "Select next parameter", "Move down the parameter list", Verb::Scope::Params,
        [Verb::Chord.new("down"), Verb::Chord.new("j")], hidden: true) { |ctx| ctx.params_move(1); nil }

      r.register Verb::Definition.new(
        "params.up", "Select previous parameter", "Move up the parameter list", Verb::Scope::Params,
        [Verb::Chord.new("up"), Verb::Chord.new("k")], hidden: true) { |ctx| ctx.params_move(-1); nil }

      # `^R`, the Run chord of Diff, Discover and every other on-demand read in the app — a
      # bare `r` is "send to Repeater" everywhere it is bound.
      r.register Verb::Definition.new(
        "params.run", "Rescan", "Re-read the captured requests and rebuild the inventory",
        Verb::Scope::Params, [Verb::Chord.new("r", ctrl: true)], mnemonic: 'r') { |ctx| ctx.params_run; nil }

      r.register Verb::Definition.new(
        "params.all-headers", "Toggle standard headers",
        "Include or leave out the headers every browser sends (User-Agent, Accept*, Sec-*, …)",
        Verb::Scope::Params, [Verb::Chord.new("a")], group: :view) { |ctx| ctx.params_toggle_headers; nil }

      # No chord of its own: bare `x` is select-line app-wide (Keyset), and `esc` already does
      # this while a filter is set (`params.to-menu`) — the menu entry is for discovery.
      targeted = ->(ctx : Verb::ExecContext) { ctx.params_targeted? }
      r.register Verb::Definition.new(
        "params.clear-target", "All endpoints", "Drop the Sitemap-node filter and list every endpoint (esc does the same)",
        Verb::Scope::Params, [] of Verb::Chord, available: targeted, mnemonic: 'e', group: :view) { |ctx| ctx.params_clear_target; nil }

      rows_shown = ->(ctx : Verb::ExecContext) { ctx.params_rows_shown? }
      r.register Verb::Definition.new(
        "params.copy", "Copy name", "Copy the selected parameter's name",
        Verb::Scope::Params, [Verb::Chord.new("y")], available: rows_shown, mnemonic: 'y') { |ctx| ctx.read_copy; nil }

      # ⇧Y, spelled `Chord.new("y", shift: true)`: `Keybind.from_event` normalises a typed
      # capital to shift+lowercase, and `menu_key` skips shift chords — hence the mnemonic.
      r.register Verb::Definition.new(
        "params.copy-names", "Copy all names", "Copy every listed parameter name, one per line",
        Verb::Scope::Params, [Verb::Chord.new("y", shift: true)], available: rows_shown,
        mnemonic: 'Y', group: :copy) { |ctx| ctx.params_copy_names; nil }

      r.register Verb::Definition.new(
        "params.export", "Export wordlist", "Write the listed names to a wordlist file (for Miner / Fuzzer)",
        Verb::Scope::Params, [Verb::Chord.new("w")], available: rows_shown, group: :copy) { |ctx| ctx.params_export; nil }

      # `↵`/`→`, the alias pair every "open what the cursor is on" verb uses (see
      # diff.to-comparer for why a lone `enter` cannot be the only chord).
      r.register Verb::Definition.new(
        "params.open-flow", "Open flow", "Open the newest captured request that carried this parameter in History",
        Verb::Scope::Params, [Verb::Chord.new("enter"), Verb::Chord.new("right")],
        available: rows_shown, mnemonic: 'o', group: :view) { |ctx| ctx.params_open_flow; nil }

      r.register Verb::Definition.new(
        "params.mine", "Mine parameters",
        "Mine this endpoint, testing the names seen on the host's other endpoints first",
        Verb::Scope::Params, [Verb::Chord.new("m")], available: rows_shown, group: :send) { |ctx| ctx.params_mine; nil }

      # `esc` peels one layer: a Sitemap-node filter first, then focus up to the strip — the
      # Sitemap's marks work the same way.
      r.register(Verb::Definition.new(
        "params.to-menu", "Back to sub-tabs", "Clear the node filter, else move focus up to the sub-tab strip",
        Verb::Scope::Params, [Verb::Chord.new("escape")], hidden: true) do |ctx|
        ctx.params_targeted? ? ctx.params_clear_target : ctx.focus_pane(:subtabs)
        nil
      end)
    end
  end
end
