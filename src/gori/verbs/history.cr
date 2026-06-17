require "../verb"

module Gori
  module Verbs
    def self.register_history(r : Verb::Registry) : Nil
      in_history = ->(ctx : Verb::ExecContext) { ctx.current_tab == :history }
      history_selected = ->(ctx : Verb::ExecContext) { ctx.current_tab == :history && !ctx.selected_flow_id.nil? }

      # --- content pane (Body) navigation: arrow keys / hjkl ---
      r.register Verb::Definition.new(
        "body.down", "Select next flow", "Move selection down", Verb::Scope::Body,
        [Verb::Chord.new("down"), Verb::Chord.new("j")], hidden: true) { |ctx| ctx.move_selection(1); nil }

      r.register Verb::Definition.new(
        "body.up", "Select previous flow", "Move selection up", Verb::Scope::Body,
        [Verb::Chord.new("up"), Verb::Chord.new("k")], hidden: true) { |ctx| ctx.move_selection(-1); nil }

      r.register Verb::Definition.new(
        "body.leave", "Back to sidebar", "Return focus to the sidebar", Verb::Scope::Body,
        [Verb::Chord.new("left"), Verb::Chord.new("h")], hidden: true) { |ctx| ctx.focus_pane(:sidebar); nil }

      r.register Verb::Definition.new(
        "body.open", "Open flow detail", "View the selected request/response", Verb::Scope::Body,
        [Verb::Chord.new("enter"), Verb::Chord.new("right"), Verb::Chord.new("l")],
        available: history_selected) { |ctx| ctx.open_detail; nil }

      r.register Verb::Definition.new(
        "history.query", "Filter (QL)", "Filter the list with a query (host: status:>=500 …)",
        Verb::Scope::Body, [Verb::Chord.new("/")], available: in_history) { |ctx| ctx.history_query; nil }

      r.register Verb::Definition.new(
        "history.toggle-follow", "Toggle follow", "Follow newest flows (tail) on/off",
        Verb::Scope::Body, [Verb::Chord.new("f")], available: in_history) { |ctx| ctx.toggle_follow; nil }

      r.register Verb::Definition.new(
        "history.copy", "Copy flow", "Copy the selected flow to the clipboard",
        Verb::Scope::Body, [Verb::Chord.new("y")],
        available: history_selected) { |ctx| ctx.copy_selection; nil }

      r.register Verb::Definition.new(
        "history.replay", "Replay flow", "Open the selected flow in the Replay tab",
        Verb::Scope::Body, [Verb::Chord.new("r")],
        available: history_selected) { |ctx| ctx.replay_selected; nil }

      # --- replay workbench (request editing is inline; these power the palette
      # and show their key hints — actual keys are handled directly by the TUI) ---
      in_replay = ->(ctx : Verb::ExecContext) { ctx.current_tab == :replay }

      r.register Verb::Definition.new(
        "replay.send", "Send replay", "Resend the request byte-exact and diff the response",
        Verb::Scope::Replay, [Verb::Chord.new("r", ctrl: true)],
        available: in_replay) { |ctx| ctx.replay_send; nil }

      # --- detail view ---
      r.register Verb::Definition.new(
        "detail.close", "Close detail", "Return to the History list", Verb::Scope::HistoryDetail,
        [Verb::Chord.new("escape"), Verb::Chord.new("q"), Verb::Chord.new("left"), Verb::Chord.new("h")],
        hidden: true) { |ctx| ctx.close_detail; nil }

      r.register Verb::Definition.new(
        "detail.down", "Scroll detail down", "Scroll the detail view down", Verb::Scope::HistoryDetail,
        [Verb::Chord.new("j"), Verb::Chord.new("down")], hidden: true) { |ctx| ctx.scroll_detail(1); nil }

      r.register Verb::Definition.new(
        "detail.up", "Scroll detail up", "Scroll the detail view up", Verb::Scope::HistoryDetail,
        [Verb::Chord.new("k"), Verb::Chord.new("up")], hidden: true) { |ctx| ctx.scroll_detail(-1); nil }

      r.register Verb::Definition.new(
        "detail.toggle-pane", "Switch request/response", "Toggle between request and response",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("tab")], hidden: true) { |ctx| ctx.toggle_detail_pane; nil }
    end

    # Builds a registry with every built-in verb registered.
    def self.registry : Verb::Registry
      r = Verb::Registry.new
      register_core(r)
      register_history(r)
      register_sitemap(r)
      register_findings(r)
      r
    end
  end
end
