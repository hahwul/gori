require "../verb"

module Gori
  module Verbs
    # READ-mode editor affordances: select the current line (x), clear a selection (v),
    # and copy verbs whose menu title flips to "Copy selected" when a selection is active
    # (see ExecContext#space_menu_title). Registered per scope so the space menu stays
    # strictly local to the focused pane.
    #
    # Round 5: these are low-frequency next to Send/Copy/New/etc., so on the
    # multi-section tabs (Repeater/Fuzzer/Decoder) they're tagged into the single most
    # relevant focus-area section instead of :common — available? still gates them by
    # read-mode across ALL of that tab's read-mode panes, so the keybinding (mostly
    # plain 'x'/'v') keeps working everywhere; only the SPACE-MENU listing is scoped to
    # one section. Single-region tabs (Notes/Issues/Project/HistoryDetail) have
    # nowhere else to put them, so they stay :common (their one and only group) —
    # unchanged, no clutter concern since there's only ever one group to show.
    def self.register_read_edit(r : Verb::Registry) : Nil
      in_sel = ->(ctx : Verb::ExecContext) { ctx.read_selection_active? }

      in_notes_read = ->(ctx : Verb::ExecContext) { ctx.current_tab == :notes && ctx.notes_read_mode? }
      r.register Verb::Definition.new(
        "notes.select-line", "Select line", "Select the entire current line",
        Verb::Scope::Notes, [Verb::Chord.new("x")],
        available: in_notes_read, mnemonic: 'x') { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "notes.clear-selection", "Clear selection", "Clear the text selection",
        Verb::Scope::Notes, available: in_sel, mnemonic: 'v') { |ctx| ctx.read_clear_selection; nil }
      r.register Verb::Definition.new(
        "notes.send-to", "Send selection to…", "Send the selected text to another tool (Decoder, …)",
        Verb::Scope::Notes, available: in_sel, mnemonic: 'S') { |ctx| ctx.send_to_open; nil }

      # Plain 'x' = select-line in every Repeater read-mode pane (request/target/response),
      # now that hex is ^X everywhere (the old x=resp-hex collision is gone). Tagged
      # :response (not :common) so the busy :request section and lean COMMON stay
      # uncluttered — and so 'x' never surfaces in the tab-bar/:subtab menus; the 'x'
      # keybinding still works in all three read panes regardless of where it's listed.
      in_repeater_read = ->(ctx : Verb::ExecContext) { ctx.current_tab == :repeater && ctx.repeater_read_mode? }
      r.register Verb::Definition.new(
        "repeater.select-line", "Select line", "Select the entire current line",
        Verb::Scope::Repeater, [Verb::Chord.new("x")],
        available: in_repeater_read, mnemonic: 'x', section: :response) { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "repeater.clear-selection", "Clear selection", "Clear the text selection",
        Verb::Scope::Repeater, available: in_sel, mnemonic: 'v', section: :response) { |ctx| ctx.read_clear_selection; nil }
      # send-to stays in COMMON (not :response like clear-selection): it's menu-only
      # (no keybinding fallback), so it must be listed in EVERY read pane's space menu.
      # command_section is the focused pane (:request/:response/:target), and the menu
      # shows only COMMON ∪ that one section — a :response tag would hide send-to while
      # selecting in the request pane, leaving no way to invoke it. in_sel keeps COMMON
      # uncluttered when nothing is selected.
      r.register Verb::Definition.new(
        "repeater.send-to", "Send selection to…", "Send the selected text to another tool (Decoder, …)",
        Verb::Scope::Repeater, available: in_sel, mnemonic: 'S') { |ctx| ctx.send_to_open; nil }

      # Tagged :input (Decoder's read-mode panes are INPUT-read and OUTPUT; :input is
      # the more relevant "editing" pane — OUTPUT keeps 'x' reachable by keybinding).
      in_decoder_read = ->(ctx : Verb::ExecContext) { ctx.current_tab == :decoder && ctx.decoder_read_mode? }
      r.register Verb::Definition.new(
        "decoder.select-line", "Select line", "Select the entire current line",
        Verb::Scope::Decoder, [Verb::Chord.new("x")],
        available: in_decoder_read, mnemonic: 'x', section: :input) { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "decoder.clear-selection", "Clear selection", "Clear the text selection",
        Verb::Scope::Decoder, available: in_sel, mnemonic: 'v', section: :input) { |ctx| ctx.read_clear_selection; nil }
      # COMMON, not :input — menu-only verb must show in both the INPUT and OUTPUT read
      # panes (command_section is cur.pane); see the repeater.send-to note above.
      r.register Verb::Definition.new(
        "decoder.send-to", "Send selection to…", "Send the selected text to another tool (Decoder, …)",
        Verb::Scope::Decoder, available: in_sel, mnemonic: 'S') { |ctx| ctx.send_to_open; nil }

      # Tagged :template (Fuzzer's only section named for this in Round 5's spec —
      # :target/:results/:detail are also read-mode-gated, but :template is the one
      # focus area the user singled out; 'x'/'v' keep working by keybinding elsewhere).
      in_fuzzer_read = ->(ctx : Verb::ExecContext) { ctx.current_tab == :fuzzer && ctx.fuzzer_read_mode? }
      r.register Verb::Definition.new(
        "fuzzer.select-line", "Select line", "Select the entire current line",
        Verb::Scope::Fuzzer, [Verb::Chord.new("x")],
        available: in_fuzzer_read, mnemonic: 'x', section: :template) { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "fuzzer.clear-selection", "Clear selection", "Clear the text selection",
        Verb::Scope::Fuzzer, available: in_sel, mnemonic: 'v', section: :template) { |ctx| ctx.read_clear_selection; nil }
      # COMMON, not :template — menu-only verb must show in every Fuzzer read pane
      # (command_section follows the focused pane); see the repeater.send-to note above.
      r.register Verb::Definition.new(
        "fuzzer.send-to", "Send selection to…", "Send the selected text to another tool (Decoder, …)",
        Verb::Scope::Fuzzer, available: in_sel, mnemonic: 'S') { |ctx| ctx.send_to_open; nil }

      # JWT workbench read-mode panes (INPUT-read, DECODED, OUTPUT, ATTACKS). Tagged
      # :input for select-line (the token pane is the one with a fine selection); send-to
      # stays COMMON (menu-only, must show in every read pane — see repeater.send-to note).
      in_jwt_read = ->(ctx : Verb::ExecContext) { ctx.current_tab == :jwt && ctx.jwt_read_mode? }
      r.register Verb::Definition.new(
        "jwt.select-line", "Select line", "Select the entire current line",
        Verb::Scope::Jwt, [Verb::Chord.new("x")],
        available: in_jwt_read, mnemonic: 'x', section: :input) { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "jwt.clear-selection", "Clear selection", "Clear the text selection",
        Verb::Scope::Jwt, available: in_sel, mnemonic: 'v', section: :input) { |ctx| ctx.read_clear_selection; nil }
      r.register Verb::Definition.new(
        "jwt.send-to", "Send selection to…", "Send the selected text to another tool (Decoder, JWT, …)",
        Verb::Scope::Jwt, available: in_sel, mnemonic: 'S') { |ctx| ctx.send_to_open; nil }

      in_issues_notes = ->(ctx : Verb::ExecContext) { ctx.issues_notes_read_mode? }
      r.register Verb::Definition.new(
        "issue.select-line", "Select line", "Select the entire current notes line",
        Verb::Scope::IssuesDetail, [Verb::Chord.new("x")],
        available: in_issues_notes, mnemonic: 'x') { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "issue.clear-selection", "Clear selection", "Clear the notes text selection",
        Verb::Scope::IssuesDetail, available: in_sel, mnemonic: 'v') { |ctx| ctx.read_clear_selection; nil }
      r.register Verb::Definition.new(
        "issue.send-to", "Send selection to…", "Send the selected text to another tool (Decoder, …)",
        Verb::Scope::IssuesDetail, available: in_sel, mnemonic: 'S') { |ctx| ctx.send_to_open; nil }

      in_project_desc = ->(ctx : Verb::ExecContext) { ctx.project_desc_read_mode? }
      r.register Verb::Definition.new(
        "project.select-line", "Select line", "Select the entire current line",
        Verb::Scope::Body, [Verb::Chord.new("x")],
        available: in_project_desc, mnemonic: 'x') { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "project.clear-selection", "Clear selection", "Clear the text selection",
        Verb::Scope::Body, available: in_sel, mnemonic: 'v') { |ctx| ctx.read_clear_selection; nil }
      r.register Verb::Definition.new(
        "project.send-to", "Send selection to…", "Send the selected text to another tool (Decoder, …)",
        Verb::Scope::Body, available: in_sel, mnemonic: 'S') { |ctx| ctx.send_to_open; nil }

      in_detail_nav = ->(ctx : Verb::ExecContext) { ctx.detail_navigable? }
      r.register Verb::Definition.new(
        "detail.select-line", "Select line", "Select the entire current line",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("x")],
        available: in_detail_nav, mnemonic: 'x') { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "detail.clear-selection", "Clear selection", "Clear the text selection",
        Verb::Scope::HistoryDetail, available: in_sel, mnemonic: 'v') { |ctx| ctx.read_clear_selection; nil }
      r.register Verb::Definition.new(
        "detail.send-to", "Send selection to…", "Send the selected text to another tool (Decoder, …)",
        Verb::Scope::HistoryDetail, available: in_sel, mnemonic: 'S') { |ctx| ctx.send_to_open; nil }
    end
  end
end
