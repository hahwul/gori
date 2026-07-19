require "../verb"
require "../tui/settings_catalog"

module Gori
  # Concrete verb definitions. Each registration is a keybinding + palette entry (P1).
  # Key budget (docs/guide/hotkeys): L0 structural · L1 loop · L2 Global breath
  # (bare c/i/s only) · L3 space mnemonic · L4 palette. New pane actions default L3.
  # Ctrl is for INS-safe or destructive work — not a general upgrade from bare.
  module Verbs
    def self.register_core(r : Verb::Registry) : Nil
      # Discoverable from anywhere via the palette (Global). The 'q' KEY, though, only
      # fires on the tab bar (Sidebar) — where "q projects" is actually hinted —
      # because as a Global chord it also dumped you to the picker from the
      # verb-driven Sitemap/Issues bodies (a surprising one-key dead-end mid-browse).
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

      # Notification center (background-job results, alerts). Palette + top-bar
      # `notify:N` badge only by default — a Global bare letter is reserved for
      # L2 session breath (c/i/s). Rebind via settings:hotkeys if you want a chord.
      r.register Verb::Definition.new(
        "app.notifications", "Notifications", "Open the notification center (background-job results)",
        Verb::Scope::Global, category: Verb::Category::System) { |ctx| ctx.open_notifications; nil }

      r.register Verb::Definition.new(
        "capture.toggle", "Toggle capture", "Start/stop capturing traffic", Verb::Scope::Global,
        [Verb::Chord.new("c")]) { |ctx| ctx.toggle_capture; nil }

      r.register Verb::Definition.new(
        "view.reveal-ws", "Reveal whitespace", "Show whitespace/CR/LF as glyphs (·→␍␊) in req/res — for smuggling tests",
        Verb::Scope::Global, [Verb::Chord.new("b", ctrl: true)]) { |ctx| ctx.toggle_reveal; nil }

      # Emergency full repaint (palette-only, no chord — a rare recovery action). Redraws
      # every cell (a full sync, not a diff), wiping stray glyphs the diff-renderer can't
      # reach (e.g. after a binary response body desynced the terminal's cursor tracking).
      r.register Verb::Definition.new(
        "view.refresh", "Refresh screen", "Force a full repaint — recover from terminal corruption / stray glyphs",
        Verb::Scope::Global, category: Verb::Category::System) { |ctx| ctx.refresh_screen; nil }

      r.register Verb::Definition.new(
        "ca.export", "Copy CA certificate path", "Copy the path to gori's root CA (same as `gori ca`) for trust setup",
        Verb::Scope::Global) { |ctx| ctx.export_ca; nil }

      # Palette-only (destructive — gated behind a confirm in the Runner): mint a
      # fresh root CA, replacing the old one. Invalidates any prior trust.
      r.register Verb::Definition.new(
        "ca.regenerate", "Regenerate CA certificate", "Replace gori's root CA with a fresh one (old trust is invalidated)",
        Verb::Scope::Global) { |ctx| ctx.regenerate_ca; nil }

      # Palette-only (destructive — gated behind a confirm in the Runner): adopt an
      # externally-created root CA (cert + key PEM) instead of gori's own.
      r.register Verb::Definition.new(
        "ca.import", "Import CA certificate", "Use an externally-created root CA (cert + key) instead of gori's own",
        Verb::Scope::Global) { |ctx| ctx.import_ca; nil }

      # Palette-only (no chord — used rarely): open a system browser pre-trusting
      # gori's CA and routed through the proxy, like Burp/Caido's embedded browser.
      r.register Verb::Definition.new(
        "browser.open", "Open browser", "Launch a browser pre-trusting gori's CA, routed via the proxy",
        Verb::Scope::Global) { |ctx| ctx.open_browser_picker; nil }

      # Settings (config control) — one palette verb per catalog section. The SAME
      # Tui::SettingsCatalog drives the Settings tab's grouped sub-tabs, so the palette
      # and the tab can't list different sections. Each verb opens its section editor
      # via open_settings(sym) — behaviour is unchanged from the old hand-written block.
      Tui::SettingsCatalog.all.each do |s|
        r.register Verb::Definition.new(
          s.id, "Settings: #{s.title}", s.desc,
          Verb::Scope::Global, category: Verb::Category::Settings) { |ctx| ctx.open_settings(s.sym); nil }
      end

      # `s` toggles the scope lens from anywhere (its original behavior — this used to jump to
      # the Project scope editor). Jumping there is now the palette-only `scope.edit` below.
      r.register Verb::Definition.new(
        "scope.toggle-lens", "Toggle scope lens", "Filter History/Sitemap to in-scope flows on/off",
        Verb::Scope::Global, [Verb::Chord.new("s")]) { |ctx| ctx.scope_toggle_lens; nil }
      r.register Verb::Definition.new(
        "scope.edit", "Edit scope rules", "Jump to the Project tab's scope rule editor",
        Verb::Scope::Global) { |ctx| ctx.scope_open; nil }

      r.register Verb::Definition.new(
        "scope.add-host", "Add host to scope", "Add the selected flow's host to the scope lens",
        Verb::Scope::Body, available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :history && !ctx.selected_flow_id.nil? }, mnemonic: 'h') { |ctx| ctx.scope_add_host; nil }

      r.register Verb::Definition.new(
        "scope.toggle", "Toggle scope lens", "Filter History/Sitemap to in-scope flows on/off",
        Verb::Scope::Body, [Verb::Chord.new("s", shift: true)],
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :history }, mnemonic: 's') { |ctx| ctx.scope_toggle_lens; nil }

      # --- Project tab SCOPE pane: the rule-list action menu (space) + its a/e/d keys.
      # Project scope is unique to that pane, so no current_tab gate is needed. The lens
      # toggle is menu-only (mnemonic 's') — it REPLACED the old direct space=toggle, which
      # now opens this menu instead; add/edit/delete keep their a/e/d direct chords.
      scope_rule = ->(ctx : Verb::ExecContext) { ctx.scope_rule_selected? }
      r.register Verb::Definition.new(
        "scope.lens-toggle", "Toggle scope lens", "Filter History/Sitemap to in-scope flows on/off",
        Verb::Scope::Project, mnemonic: 's') { |ctx| ctx.scope_toggle_lens; nil }
      r.register Verb::Definition.new(
        "scope.add-rule", "Add scope rule", "Open the popup to add an include/exclude rule",
        Verb::Scope::Project, [Verb::Chord.new("a")]) { |ctx| ctx.scope_add_rule; nil }
      r.register Verb::Definition.new(
        "scope.edit-rule", "Edit scope rule", "Open the popup to edit the selected scope rule",
        Verb::Scope::Project, [Verb::Chord.new("e")], available: scope_rule) { |ctx| ctx.scope_edit_rule; nil }
      r.register Verb::Definition.new(
        "scope.delete-rule", "Delete scope rule", "Remove the selected scope rule",
        Verb::Scope::Project, [Verb::Chord.new("d")], available: scope_rule) { |ctx| ctx.scope_delete_rule; nil }

      # The single smart Copy (see repeater.copy in verbs/history.cr) — copy-all is gone.
      # Was `hidden: true` (the menu only ever showed "Copy description"); now that
      # this IS the one Copy action, it needs to be visible. Project shares
      # Verb::Scope::Body with the History list (Body is the generic "content pane
      # focus" scope), so plain 'y' would collide with history.copy — both in the
      # SAME (scope, :common) space-menu view (validate_menu_keys! doesn't know the
      # two are gated to different tabs at runtime) AND as a raw Chord in the SAME
      # scope (keymap_spec's rebindable-conflict guard: two verbs can't default-bind
      # the same chord in one scope). Dropping the chord resolves both — the direct
      # 'y' keypress in the Project description pane is already raw-dispatched by
      # ProjectController (`when c == 'y' then project_copy`, never touching the
      # shared Keymap), so the chord here was vestigial. Capital 'Y' keeps a
      # "copy"-flavored mnemonic for the space menu while staying distinct from
      # history.copy's 'y' (mirrors fuzzer.select-line's 'S' dodging lowercase 's').
      in_project_desc_read = ->(ctx : Verb::ExecContext) { ctx.project_desc_read_mode? }
      r.register Verb::Definition.new(
        "project.copy", "Copy", "Copy the selected description text, or the whole description if nothing is selected, to the clipboard",
        Verb::Scope::Body,
        available: in_project_desc_read, mnemonic: 'Y') { |ctx| ctx.read_copy; nil }

      # Match & Replace now lives in the Rewriter tab; this palette entry jumps there
      # (kept under the familiar "Match & Replace" name so a search still finds it).
      r.register Verb::Definition.new(
        "rules.edit", "Match & Replace", "Open the Rewriter tab (in-flight request/response rewrite rules)", Verb::Scope::Global,
        category: Verb::Category::Navigation) { |ctx| ctx.focus_tab(:rewriter); nil }

      # --- intercept (hold-and-decide; P4) ---
      r.register Verb::Definition.new(
        "intercept.toggle", "Toggle intercept", "Hold requests/responses for a human decision", Verb::Scope::Global,
        [Verb::Chord.new("i")]) { |ctx| ctx.intercept_toggle; nil }

      # Forward / drop / forward-all are Intercept-scope keymap verbs (rebindable).
      # The queue defers bare f/d/⇧F to the keymap; space-menu mnemonics stay f/d/a.
      intercept_selected = ->(ctx : Verb::ExecContext) { !ctx.selected_intercept_id.nil? }
      r.register Verb::Definition.new(
        "intercept.forward", "Forward held", "Forward the selected held message (with edits)",
        Verb::Scope::Intercept, [Verb::Chord.new("f")],
        available: intercept_selected, mnemonic: 'f') { |ctx| ctx.intercept_forward; nil }
      r.register Verb::Definition.new(
        "intercept.drop", "Drop held", "Drop the selected held message",
        Verb::Scope::Intercept, [Verb::Chord.new("d")],
        available: intercept_selected, mnemonic: 'd') { |ctx| ctx.intercept_drop; nil }
      r.register Verb::Definition.new(
        "intercept.forward-all", "Forward all held", "Forward every held message",
        Verb::Scope::Intercept, [Verb::Chord.new("f", shift: true)],
        available: intercept_selected, mnemonic: 'a') { |ctx| ctx.intercept_forward_all; nil }

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
      # so the numbers follow the user's settings:tabs order/visibility. Hidden, so the
      # keys exist but don't clutter the palette; the named "Go to …" verbs below are the
      # discoverable entries (and the way to reach a hidden tab by command).
      (1..9).each do |n|
        r.register Verb::Definition.new(
          "nav.pos#{n}", "Go to tab #{n}", "Focus the #{n}th visible tab", Verb::Scope::Global,
          [Verb::Chord.new(n.to_s)], hidden: true) { |ctx| ctx.focus_visible_tab(n); nil }
      end

      # Named tab jumps (no chord) — palette discoverability + the only by-command way to
      # reach a tab hidden in settings:tabs (focus_tab force-shows it while active). Keep
      # this list in sync with Tui::Chrome::TABS so every catalog tab — including the
      # default-hidden ones (Miner, Sequencer) — stays reachable from the command palette.
      {
        :project => "Project", :target => "Target", :history => "History", :intercept => "Intercept",
        :repeater => "Repeater", :fuzzer => "Fuzzer", :miner => "Miner", :oast => "OAST",
        :sequencer => "Sequencer", :decoder => "Decoder", :jwt => "JWT", :comparer => "Comparer",
        :probe => "Probe", :issues => "Issues", :notes => "Notes",
        :rewriter => "Rewriter",
      }.each do |tab, label|
        r.register Verb::Definition.new(
          "tab.#{tab}", "Go to #{label}", "Focus the #{label} tab", Verb::Scope::Global,
          category: Verb::Category::Navigation) { |ctx| ctx.focus_tab(tab); nil }
      end
      # Help is special: bare `?` (mitmproxy-style) jumps to the cheat-sheet from any
      # navigable context. Palette still lists it as "Go to Help".
      r.register Verb::Definition.new(
        "tab.help", "Go to Help", "Focus the Help tab (keyboard cheat-sheet)", Verb::Scope::Global,
        [Verb::Chord.new("?")], category: Verb::Category::Navigation) { |ctx| ctx.focus_tab(:help); nil }

      # Discover is a sub-tab under Target, so it gets its own "Go to" (Target's own jump
      # lands on the last-active sub-tab).
      r.register Verb::Definition.new(
        "tab.discover", "Go to Discover", "Focus the Target tab's Discover sub-tab", Verb::Scope::Global,
        category: Verb::Category::Navigation) { |ctx| ctx.goto_discover; nil }

      # Close the command palette overlay.
      r.register Verb::Definition.new(
        "palette.close", "Close palette", "Dismiss the command palette", Verb::Scope::PaletteOpen,
        [Verb::Chord.new("escape")], hidden: true) { |ctx| ctx.close_overlay; nil }

      # --- top menu focus navigation (horizontal) ---
      r.register Verb::Definition.new(
        "sidebar.prev", "Previous tab", "Select the tab to the left", Verb::Scope::Sidebar,
        [Verb::Chord.new("left"), Verb::Chord.new("h")], hidden: true) { |ctx| ctx.menu_left; nil }

      r.register Verb::Definition.new(
        "sidebar.next", "Next tab", "Select the tab to the right", Verb::Scope::Sidebar,
        [Verb::Chord.new("right"), Verb::Chord.new("l")], hidden: true) { |ctx| ctx.menu_right; nil }

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
