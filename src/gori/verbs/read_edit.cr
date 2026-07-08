require "../verb"

module Gori
  module Verbs
    # READ-mode editor affordances: select the current line (x), clear a selection (v),
    # and copy verbs whose menu title flips to "Copy selected" when a selection is active
    # (see ExecContext#space_menu_title). Registered per scope so the space menu stays
    # strictly local to the focused pane.
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

      in_replay_read = ->(ctx : Verb::ExecContext) { ctx.current_tab == :replay && ctx.replay_read_mode? }
      r.register Verb::Definition.new(
        "replay.select-line", "Select line", "Select the entire current line",
        Verb::Scope::Replay, [Verb::Chord.new("x")],
        available: in_replay_read, mnemonic: 'l') { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "replay.clear-selection", "Clear selection", "Clear the text selection",
        Verb::Scope::Replay, available: in_sel, mnemonic: 'v') { |ctx| ctx.read_clear_selection; nil }

      in_convert_read = ->(ctx : Verb::ExecContext) { ctx.current_tab == :convert && ctx.convert_read_mode? }
      r.register Verb::Definition.new(
        "convert.select-line", "Select line", "Select the entire current line",
        Verb::Scope::Convert, [Verb::Chord.new("x")],
        available: in_convert_read, mnemonic: 'x') { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "convert.clear-selection", "Clear selection", "Clear the text selection",
        Verb::Scope::Convert, available: in_sel, mnemonic: 'v') { |ctx| ctx.read_clear_selection; nil }

      in_fuzzer_read = ->(ctx : Verb::ExecContext) { ctx.current_tab == :fuzzer && ctx.fuzzer_read_mode? }
      r.register Verb::Definition.new(
        "fuzzer.select-line", "Select line", "Select the entire current line",
        Verb::Scope::Fuzzer, [Verb::Chord.new("x")],
        available: in_fuzzer_read, mnemonic: 'S') { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "fuzzer.clear-selection", "Clear selection", "Clear the text selection",
        Verb::Scope::Fuzzer, available: in_sel, mnemonic: 'v') { |ctx| ctx.read_clear_selection; nil }

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