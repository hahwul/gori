require "../verb"

module Gori
  # Concrete verb definitions for this milestone. Each is registered once and
  # thereby becomes both a keybinding and a palette entry (P1).
  module Verbs
    def self.register_core(r : Verb::Registry) : Nil
      # Discoverable from anywhere via the palette (Global). The 'q' KEY, though, only
      # fires on the tab bar (Sidebar) — where "q projects" is actually hinted —
      # because as a Global chord it also dumped you to the picker from the
      # verb-driven Sitemap/Findings bodies (a surprising one-key dead-end mid-browse).
      r.register Verb::Definition.new(
        "app.back", "Back to projects", "Close this project and return to the picker", Verb::Scope::Global,
        [] of Verb::Chord, category: Verb::Category::Navigation) { |ctx| ctx.leave_project; nil }
      r.register Verb::Definition.new(
        "app.back-key", "Back to projects", "Close this project (q on the tab bar)", Verb::Scope::Sidebar,
        [Verb::Chord.new("q")], hidden: true) { |ctx| ctx.leave_project; nil }

      # Quit is palette-only here; the keyboard path is a deliberate double ^D/^C
      # handled in the Runner (single Q quitting was too easy to hit by accident).
      r.register Verb::Definition.new(
        "app.quit", "Quit gori", "Exit gori entirely", Verb::Scope::Global,
        [] of Verb::Chord, category: Verb::Category::System) { |ctx| ctx.quit!; nil }

      r.register Verb::Definition.new(
        "app.palette", "Command palette", "Open the command palette", Verb::Scope::Global,
        [Verb::Chord.new("p", ctrl: true)], category: Verb::Category::System) { |ctx| ctx.open_palette; nil }

      r.register Verb::Definition.new(
        "capture.toggle", "Toggle capture", "Start/stop capturing traffic", Verb::Scope::Global,
        [Verb::Chord.new("c")]) { |ctx| ctx.toggle_capture; nil }

      r.register Verb::Definition.new(
        "view.reveal-ws", "Reveal whitespace", "Show whitespace/CR/LF as glyphs (·→␍␊) in req/res — for smuggling tests",
        Verb::Scope::Global, [Verb::Chord.new("b", ctrl: true)]) { |ctx| ctx.toggle_reveal; nil }

      r.register Verb::Definition.new(
        "ca.export", "Export CA certificate", "Print the path to gori's root CA for trust setup",
        Verb::Scope::Global) { |ctx| ctx.export_ca; nil }

      # Palette-only (destructive — gated behind a confirm in the Runner): mint a
      # fresh root CA, replacing the old one. Invalidates any prior trust.
      r.register Verb::Definition.new(
        "ca.regenerate", "Regenerate CA certificate", "Replace gori's root CA with a fresh one (old trust is invalidated)",
        Verb::Scope::Global) { |ctx| ctx.regenerate_ca; nil }

      # Palette-only (no chord — used rarely): open a system browser pre-trusting
      # gori's CA and routed through the proxy, like Burp/Caido's embedded browser.
      r.register Verb::Definition.new(
        "browser.open", "Open browser", "Launch a browser pre-trusting gori's CA, routed via the proxy",
        Verb::Scope::Global) { |ctx| ctx.open_browser_picker; nil }

      # Settings (config control) — palette-only. network/editor/theme are
      # implemented; hotkeys is registered for discoverability (shown "soon") + a TODO toast.
      r.register Verb::Definition.new(
        "settings.network", "settings:network", "Edit the proxy bind address + upstream proxy",
        Verb::Scope::Global, category: Verb::Category::Settings) { |ctx| ctx.open_settings(:network); nil }
      r.register Verb::Definition.new(
        "settings.editor", "settings:editor", "Set the external editor opened by ^E in editable fields",
        Verb::Scope::Global, category: Verb::Category::Settings) { |ctx| ctx.open_settings(:editor); nil }
      r.register Verb::Definition.new(
        "settings.theme", "settings:theme", "Switch the TUI colour theme (built-ins + your own from ~/.gori/themes/*.json)",
        Verb::Scope::Global, category: Verb::Category::Settings) { |ctx| ctx.open_settings(:theme); nil }
      r.register Verb::Definition.new(
        "settings.tabs", "settings:tabs", "Customize the top tab bar — show/hide tabs and reorder them",
        Verb::Scope::Global, category: Verb::Category::Settings) { |ctx| ctx.open_settings(:tabs); nil }
      r.register Verb::Definition.new(
        "settings.hotkeys", "settings:hotkeys", "Rebind keyboard shortcuts (press a key) + pick an OS default profile",
        Verb::Scope::Global, category: Verb::Category::Settings) { |ctx| ctx.open_settings(:hotkeys); nil }

      r.register Verb::Definition.new(
        "scope.edit", "Scope lens", "Edit the in-scope host patterns", Verb::Scope::Global,
        [Verb::Chord.new("s")]) { |ctx| ctx.scope_open; nil }

      r.register Verb::Definition.new(
        "scope.add-host", "Add host to scope", "Add the selected flow's host to the scope lens",
        Verb::Scope::Body, available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :history && !ctx.selected_flow_id.nil? }, mnemonic: 'h') { |ctx| ctx.scope_add_host; nil }

      r.register Verb::Definition.new(
        "scope.toggle", "Toggle scope lens", "Filter History/Sitemap to in-scope flows on/off",
        Verb::Scope::Body, [Verb::Chord.new("s", shift: true)],
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :history }, mnemonic: 's') { |ctx| ctx.scope_toggle_lens; nil }

      r.register Verb::Definition.new(
        "rules.edit", "Match & Replace", "Edit in-flight request/response head rewrite rules", Verb::Scope::Global,
        [Verb::Chord.new("m")]) { |ctx| ctx.rules_open; nil }

      # --- intercept (hold-and-decide; P4) ---
      r.register Verb::Definition.new(
        "intercept.toggle", "Toggle intercept", "Hold requests/responses for a human decision", Verb::Scope::Global,
        [Verb::Chord.new("i")]) { |ctx| ctx.intercept_toggle; nil }

      # forward/drop are also handled directly on the Intercept tab; registered
      # here (no chord) for palette discoverability (P1).
      intercept_selected = ->(ctx : Verb::ExecContext) { !ctx.selected_intercept_id.nil? }
      r.register Verb::Definition.new(
        "intercept.forward", "Forward held", "Forward the selected held message (with edits)",
        Verb::Scope::Intercept, available: intercept_selected, mnemonic: 'f') { |ctx| ctx.intercept_forward; nil }
      r.register Verb::Definition.new(
        "intercept.drop", "Drop held", "Drop the selected held message",
        Verb::Scope::Intercept, available: intercept_selected, mnemonic: 'd') { |ctx| ctx.intercept_drop; nil }
      r.register Verb::Definition.new(
        "intercept.forward-all", "Forward all held", "Forward every held message",
        Verb::Scope::Intercept, available: intercept_selected, mnemonic: 'a') { |ctx| ctx.intercept_forward_all; nil }

      # Catch controls — what to hold (direction) + a condition that narrows it. Keymap-
      # driven (Intercept scope) so they're rebindable; the queue defers `c`/`/` to here,
      # while the held-bytes editor + condition bar still swallow them as literal text.
      r.register Verb::Definition.new(
        "intercept.direction", "Catch direction", "Cycle which to hold: all / requests only / responses only",
        Verb::Scope::Intercept, [Verb::Chord.new("c")]) { |ctx| ctx.intercept_cycle_direction; nil }
      r.register Verb::Definition.new(
        "intercept.filter", "Catch condition", "Only hold messages matching a query (host: method: path: status: scheme:)",
        Verb::Scope::Intercept, [Verb::Chord.new("/")]) { |ctx| ctx.intercept_query; nil }

      # Tab/Shift-Tab are the focus ring (handled directly in the Runner); these
      # bracket chords remain a from-anywhere shortcut to cycle tabs.
      r.register Verb::Definition.new(
        "nav.next-tab", "Next tab", "Focus the next tab", Verb::Scope::Global,
        [Verb::Chord.new("]")], category: Verb::Category::Navigation) { |ctx| ctx.cycle_tab(1); nil }

      r.register Verb::Definition.new(
        "nav.prev-tab", "Previous tab", "Focus the previous tab", Verb::Scope::Global,
        [Verb::Chord.new("[")], category: Verb::Category::Navigation) { |ctx| ctx.cycle_tab(-1); nil }

      # Positional tab jump: digit N focuses the Nth VISIBLE tab (the order on the bar) —
      # so the numbers follow the user's settings:tabs order/visibility. Hidden (default:
      # Agent), so the keys exist but don't clutter the palette; the named "Go to …" verbs
      # below are the discoverable entries (and the way to reach a hidden tab by command).
      (1..9).each do |n|
        r.register Verb::Definition.new(
          "nav.pos#{n}", "Go to tab #{n}", "Focus the #{n}th visible tab", Verb::Scope::Global,
          [Verb::Chord.new(n.to_s)], hidden: true) { |ctx| ctx.focus_visible_tab(n); nil }
      end

      # Named tab jumps (no chord) — palette discoverability + the only by-command way to
      # reach a tab hidden in settings:tabs (focus_tab force-shows it while active).
      {
        :project => "Project", :history => "History", :intercept => "Intercept", :sitemap => "Sitemap",
        :replay => "Replay", :comparer => "Comparer", :findings => "Findings", :notes => "Notes",
        :convert => "Convert", :agent => "Agent", :help => "Help",
      }.each do |tab, label|
        r.register Verb::Definition.new(
          "tab.#{tab}", "Go to #{label}", "Focus the #{label} tab", Verb::Scope::Global,
          category: Verb::Category::Navigation) { |ctx| ctx.focus_tab(tab); nil }
      end

      # Close the command palette overlay.
      r.register Verb::Definition.new(
        "palette.close", "Close palette", "Dismiss the command palette", Verb::Scope::PaletteOpen,
        [Verb::Chord.new("escape")], hidden: true) { |ctx| ctx.close_overlay; nil }

      # --- top menu focus navigation (horizontal) ---
      r.register Verb::Definition.new(
        "sidebar.prev", "Previous tab", "Select the tab to the left", Verb::Scope::Sidebar,
        [Verb::Chord.new("left"), Verb::Chord.new("h")], hidden: true) { |ctx| ctx.cycle_tab(-1); nil }

      r.register Verb::Definition.new(
        "sidebar.next", "Next tab", "Select the tab to the right", Verb::Scope::Sidebar,
        [Verb::Chord.new("right"), Verb::Chord.new("l")], hidden: true) { |ctx| ctx.cycle_tab(1); nil }

      r.register Verb::Definition.new(
        "sidebar.enter", "Enter tab", "Move focus into the content pane", Verb::Scope::Sidebar,
        [Verb::Chord.new("down"), Verb::Chord.new("j"), Verb::Chord.new("enter")],
        hidden: true) { |ctx| ctx.enter_content; nil }

      # Return focus from the content pane up to the top menu.
      r.register Verb::Definition.new(
        "body.to-menu", "Back to menu", "Move focus up to the tab menu", Verb::Scope::Body,
        [Verb::Chord.new("escape")], hidden: true) { |ctx| ctx.focus_pane(:menu); nil }
    end
  end
end
