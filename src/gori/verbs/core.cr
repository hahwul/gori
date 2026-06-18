require "../verb"

module Gori
  # Concrete verb definitions for this milestone. Each is registered once and
  # thereby becomes both a keybinding and a palette entry (P1).
  module Verbs
    def self.register_core(r : Verb::Registry) : Nil
      r.register Verb::Definition.new(
        "app.back", "Back to projects", "Close this project and return to the picker", Verb::Scope::Global,
        [Verb::Chord.new("q")]) { |ctx| ctx.leave_project; nil }

      r.register Verb::Definition.new(
        "app.quit", "Quit gori", "Exit gori entirely", Verb::Scope::Global,
        [Verb::Chord.new("c", ctrl: true), Verb::Chord.new("q", shift: true)]) { |ctx| ctx.quit!; nil }

      r.register Verb::Definition.new(
        "app.palette", "Command palette", "Open the command palette", Verb::Scope::Global,
        [Verb::Chord.new("p", ctrl: true)]) { |ctx| ctx.open_palette; nil }

      r.register Verb::Definition.new(
        "capture.toggle", "Toggle capture", "Start/stop capturing traffic", Verb::Scope::Global,
        [Verb::Chord.new("c")]) { |ctx| ctx.toggle_capture; nil }

      r.register Verb::Definition.new(
        "ca.export", "Export CA certificate", "Print the path to gori's root CA for trust setup",
        Verb::Scope::Global) { |ctx| ctx.export_ca; nil }

      r.register Verb::Definition.new(
        "scope.edit", "Scope lens", "Edit the in-scope host patterns", Verb::Scope::Global,
        [Verb::Chord.new("s")]) { |ctx| ctx.scope_open; nil }

      r.register Verb::Definition.new(
        "scope.add-host", "Add host to scope", "Add the selected flow's host to the scope lens",
        Verb::Scope::Body, available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :history && !ctx.selected_flow_id.nil? }) { |ctx| ctx.scope_add_host; nil }

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
        Verb::Scope::Intercept, available: intercept_selected) { |ctx| ctx.intercept_forward; nil }
      r.register Verb::Definition.new(
        "intercept.drop", "Drop held", "Drop the selected held message",
        Verb::Scope::Intercept, available: intercept_selected) { |ctx| ctx.intercept_drop; nil }
      r.register Verb::Definition.new(
        "intercept.forward-all", "Forward all held", "Forward every held message",
        Verb::Scope::Intercept, available: intercept_selected) { |ctx| ctx.intercept_forward_all; nil }

      # Tab/Shift-Tab are the focus ring (handled directly in the Runner); these
      # bracket chords remain a from-anywhere shortcut to cycle tabs.
      r.register Verb::Definition.new(
        "nav.next-tab", "Next tab", "Focus the next tab", Verb::Scope::Global,
        [Verb::Chord.new("]")]) { |ctx| ctx.cycle_tab(1); nil }

      r.register Verb::Definition.new(
        "nav.prev-tab", "Previous tab", "Focus the previous tab", Verb::Scope::Global,
        [Verb::Chord.new("[")]) { |ctx| ctx.cycle_tab(-1); nil }

      # Direct tab focus (mirrors the sidebar).
      {
        "1" => :history, "2" => :intercept, "3" => :sitemap, "4" => :replay,
        "5" => :findings, "6" => :notes, "7" => :agent,
      }.each do |key, tab|
        r.register Verb::Definition.new(
          "tab.#{tab}", "Go to #{tab.to_s.capitalize}", "Focus the #{tab} tab", Verb::Scope::Global,
          [Verb::Chord.new(key)]) { |ctx| ctx.focus_tab(tab); nil }
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
        hidden: true) { |ctx| ctx.focus_pane(:body); nil }

      # Return focus from the content pane up to the top menu.
      r.register Verb::Definition.new(
        "body.to-menu", "Back to menu", "Move focus up to the tab menu", Verb::Scope::Body,
        [Verb::Chord.new("escape")], hidden: true) { |ctx| ctx.focus_pane(:menu); nil }
    end
  end
end
