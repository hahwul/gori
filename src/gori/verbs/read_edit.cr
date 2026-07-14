require "../verb"

module Gori
  module Verbs
    # READ-mode editor affordances: select the current line (x), clear a selection (v),
    # and copy verbs whose menu title flips to "Copy selected" when a selection is active
    # (see ExecContext#space_menu_title). Registered per scope so the space menu stays
    # strictly local to the focused pane.
    #
    # Round 5: these are low-frequency next to Send/Copy/New/etc., so on the
    # multi-section tabs (Replay/Fuzzer/Decoder) they're tagged into the single most
    # relevant focus-area section instead of :common — available? still gates them by
    # read-mode across ALL of that tab's read-mode panes, so the keybinding (mostly
    # plain 'x'/'v') keeps working everywhere; only the SPACE-MENU listing is scoped to
    # one section. Single-region tabs (Notes/Findings/Project/HistoryDetail) have
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

      # Tagged :response (not :common): select/clear are equally available in the
      # REQUEST/TARGET panes (in_replay_read covers all three), but :response is
      # where reading-then-copying a snippet is the natural flow, and :request is
      # already the busiest section (9 marker/view-toggle actions) — keeping these
      # out of it (and out of COMMON) keeps both lean. The plain 'x' keybinding still
      # works in every read-mode pane regardless of where the menu lists it.
      in_replay_read = ->(ctx : Verb::ExecContext) { ctx.current_tab == :replay && ctx.replay_read_mode? }
      r.register Verb::Definition.new(
        "replay.select-line", "Select line", "Select the entire current line",
        Verb::Scope::Replay, [Verb::Chord.new("x")],
        available: in_replay_read, mnemonic: 'l', section: :response) { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "replay.clear-selection", "Clear selection", "Clear the text selection",
        Verb::Scope::Replay, available: in_sel, mnemonic: 'v', section: :response) { |ctx| ctx.read_clear_selection; nil }

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

      # Tagged :template (Fuzzer's only section named for this in Round 5's spec —
      # :target/:results/:detail are also read-mode-gated, but :template is the one
      # focus area the user singled out; 'x'/'v' keep working by keybinding elsewhere).
      in_fuzzer_read = ->(ctx : Verb::ExecContext) { ctx.current_tab == :fuzzer && ctx.fuzzer_read_mode? }
      r.register Verb::Definition.new(
        "fuzzer.select-line", "Select line", "Select the entire current line",
        Verb::Scope::Fuzzer, [Verb::Chord.new("x")],
        available: in_fuzzer_read, mnemonic: 'S', section: :template) { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "fuzzer.clear-selection", "Clear selection", "Clear the text selection",
        Verb::Scope::Fuzzer, available: in_sel, mnemonic: 'v', section: :template) { |ctx| ctx.read_clear_selection; nil }

      in_findings_notes = ->(ctx : Verb::ExecContext) { ctx.findings_notes_read_mode? }
      r.register Verb::Definition.new(
        "finding.select-line", "Select line", "Select the entire current notes line",
        Verb::Scope::FindingsDetail, [Verb::Chord.new("x")],
        available: in_findings_notes, mnemonic: 'x') { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "finding.clear-selection", "Clear selection", "Clear the notes text selection",
        Verb::Scope::FindingsDetail, available: in_sel, mnemonic: 'v') { |ctx| ctx.read_clear_selection; nil }

      in_project_desc = ->(ctx : Verb::ExecContext) { ctx.project_desc_read_mode? }
      r.register Verb::Definition.new(
        "project.select-line", "Select line", "Select the entire current line",
        Verb::Scope::Body, [Verb::Chord.new("x")],
        available: in_project_desc, mnemonic: 'x') { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "project.clear-selection", "Clear selection", "Clear the text selection",
        Verb::Scope::Body, available: in_sel, mnemonic: 'v') { |ctx| ctx.read_clear_selection; nil }

      in_detail_nav = ->(ctx : Verb::ExecContext) { ctx.detail_navigable? }
      r.register Verb::Definition.new(
        "detail.select-line", "Select line", "Select the entire current line",
        Verb::Scope::HistoryDetail,
        available: in_detail_nav, mnemonic: 'L') { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "detail.clear-selection", "Clear selection", "Clear the text selection",
        Verb::Scope::HistoryDetail, available: in_sel, mnemonic: 'v') { |ctx| ctx.read_clear_selection; nil }
    end
  end
end
