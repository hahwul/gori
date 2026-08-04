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

      # Verb::Scope::ProjectDesc, not Body — see project.copy in verbs/core.cr for why the
      # description pane stopped borrowing the History list's scope. The read-mode flag itself
      # is tab-blind (ProjectView's pane defaults to :desc, so it reads true from boot), so the
      # gate carries the current_tab half the way in_notes_read / in_repeater_read do.
      # No chord on select-line: ProjectController raw-dispatches 'x' in the desc pane and
      # handle_body_key returns true there, so the Keymap never sees it (same reasoning as
      # project.copy's dropped 'y') — a chord would only ever be dead weight in the rebind editor.
      in_project_desc = ->(ctx : Verb::ExecContext) { ctx.current_tab == :project && ctx.project_desc_read_mode? }
      r.register Verb::Definition.new(
        "project.select-line", "Select line", "Select the entire current line",
        Verb::Scope::ProjectDesc,
        available: in_project_desc, mnemonic: 'x') { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "project.clear-selection", "Clear selection", "Clear the text selection",
        Verb::Scope::ProjectDesc, available: in_sel, mnemonic: 'v') { |ctx| ctx.read_clear_selection; nil }
      r.register Verb::Definition.new(
        "project.send-to", "Send selection to…", "Send the selected text to another tool (Decoder, …)",
        Verb::Scope::ProjectDesc, available: in_sel, mnemonic: 'S') { |ctx| ctx.send_to_open; nil }

      # The Rewriter's PREVIEW OUTPUT, tagged `:preview` — the tab is multi-pane, and its rule
      # list already spends `x` on "Enable/disable" (see verbs/rewriter.cr for why every list
      # verb moved into a `:rules` section at the same time). Two sections never render together,
      # so `x` keeps meaning "select line" here and "toggle" there.
      in_rewriter_out = ->(ctx : Verb::ExecContext) { ctx.current_tab == :rewriter && ctx.rewriter_preview_out? }
      r.register Verb::Definition.new(
        "rewriter.select-line", "Select line", "Select the entire current preview line",
        Verb::Scope::Rewriter, [Verb::Chord.new("x")],
        available: in_rewriter_out, mnemonic: 'x', section: :preview) { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "rewriter.clear-selection", "Clear selection", "Clear the preview text selection",
        Verb::Scope::Rewriter, available: in_sel, mnemonic: 'v', section: :preview) { |ctx| ctx.read_clear_selection; nil }
      r.register Verb::Definition.new(
        "rewriter.send-to", "Send selection to…", "Send the selected text to another tool (Decoder, …)",
        Verb::Scope::Rewriter, available: in_sel, mnemonic: 'S', section: :preview) { |ctx| ctx.send_to_open; nil }
      r.register Verb::Definition.new(
        "rewriter.copy", "Copy", "Copy the selected preview text, or the whole transformed sample if nothing is selected",
        Verb::Scope::Rewriter, [Verb::Chord.new("y")],
        available: in_rewriter_out, mnemonic: 'y', section: :preview) { |ctx| ctx.read_copy; nil }

      # The Comparer's diff. Whole ROWS, never a char span: a screen row is two columns of the
      # same diff, so `ReadPane(line_select_only: true)` is what the cursor is — see
      # `ComparerView#unified_line` for the text a copy produces. `:common` is right here: the
      # tab's other groups are `:subtab` / `:tab` chrome, and the diff IS its body.
      in_comparer_diff = ->(ctx : Verb::ExecContext) { ctx.current_tab == :comparer && ctx.comparer_diff_shown? }
      r.register Verb::Definition.new(
        "comparer.select-line", "Select row", "Select the whole diff row under the cursor",
        Verb::Scope::Comparer, [Verb::Chord.new("x")],
        available: in_comparer_diff, mnemonic: 'x') { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "comparer.clear-selection", "Clear selection", "Clear the diff row selection",
        Verb::Scope::Comparer, available: in_sel, mnemonic: 'v') { |ctx| ctx.read_clear_selection; nil }
      r.register Verb::Definition.new(
        "comparer.send-to", "Send selection to…", "Send the selected diff rows to another tool (Decoder, …)",
        Verb::Scope::Comparer, available: in_sel, mnemonic: 'S') { |ctx| ctx.send_to_open; nil }
      r.register Verb::Definition.new(
        "comparer.copy", "Copy", "Copy the selected diff rows as unified text, or the whole diff if nothing is selected",
        Verb::Scope::Comparer, [Verb::Chord.new("y")],
        available: in_comparer_diff, mnemonic: 'y') { |ctx| ctx.read_copy; nil }

      # The Intercept's read-only held-message preview. Mouse-placed caret (see
      # `InterceptController#handle_click`), so `x`/`y` act on wherever the pointer left it.
      # No chords: the queue already spends nearly every letter, and `x`/`y` there would collide
      # with a live queue action — the menu is the discoverable route, as it is for the Project
      # description.
      in_icept_preview = ->(ctx : Verb::ExecContext) { ctx.current_tab == :intercept && ctx.intercept_preview_readable? }
      r.register Verb::Definition.new(
        "intercept.select-line", "Select line", "Select the entire current preview line",
        Verb::Scope::Intercept, available: in_icept_preview, mnemonic: 'x') { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "intercept.clear-selection", "Clear selection", "Clear the preview text selection",
        Verb::Scope::Intercept, available: in_sel, mnemonic: 'v') { |ctx| ctx.read_clear_selection; nil }
      r.register Verb::Definition.new(
        "intercept.send-to", "Send selection to…", "Send the selected text to another tool (Decoder, …)",
        Verb::Scope::Intercept, available: in_sel, mnemonic: 'S') { |ctx| ctx.send_to_open; nil }
      r.register Verb::Definition.new(
        "intercept.copy", "Copy", "Copy the selected preview text, or the whole held message if nothing is selected",
        Verb::Scope::Intercept, available: in_icept_preview, mnemonic: 'y') { |ctx| ctx.read_copy; nil }

      # An OAST callback's detail. `section: :detail` (OastController#command_section answers to
      # match): the callbacks LIST spends `y` on "copy the generated payload", and this pane's `y`
      # copies what came back — opposite directions of one interaction, so the two views must not
      # render together.
      in_oast_detail = ->(ctx : Verb::ExecContext) { ctx.oast_detail_readable? }
      r.register Verb::Definition.new(
        "oast.select-line", "Select line", "Select the entire current callback line",
        Verb::Scope::OastCallbacks, [Verb::Chord.new("x")],
        available: in_oast_detail, mnemonic: 'x', section: :detail) { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "oast.clear-selection", "Clear selection", "Clear the callback text selection",
        Verb::Scope::OastCallbacks, available: in_sel, mnemonic: 'v', section: :detail) { |ctx| ctx.read_clear_selection; nil }
      r.register Verb::Definition.new(
        "oast.send-to", "Send selection to…", "Send the selected text to another tool (Decoder, …)",
        Verb::Scope::OastCallbacks, available: in_sel, mnemonic: 'S', section: :detail) { |ctx| ctx.send_to_open; nil }
      r.register Verb::Definition.new(
        "oast.copy-callback", "Copy callback", "Copy the selected callback text, or the whole callback if nothing is selected",
        Verb::Scope::OastCallbacks,
        available: in_oast_detail, mnemonic: 'y', section: :detail) { |ctx| ctx.read_copy; nil }

      # A Probe issue's AFFECTED URLS. `Verb::Scope::ProbeDetail` carries no mnemonics of its own,
      # so `x`/`v`/`S`/`y` land in `:common` with nothing to collide with.
      in_probe_detail = ->(ctx : Verb::ExecContext) { ctx.probe_detail_readable? }
      r.register Verb::Definition.new(
        "probe.select-line", "Select URL", "Select the affected URL under the cursor",
        Verb::Scope::ProbeDetail, [Verb::Chord.new("x")],
        available: in_probe_detail, mnemonic: 'x') { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "probe.clear-selection", "Clear selection", "Clear the affected-URL selection",
        Verb::Scope::ProbeDetail, available: in_sel, mnemonic: 'v') { |ctx| ctx.read_clear_selection; nil }
      r.register Verb::Definition.new(
        "probe.send-to", "Send selection to…", "Send the selected URLs to another tool (Decoder, …)",
        Verb::Scope::ProbeDetail, available: in_sel, mnemonic: 'S') { |ctx| ctx.send_to_open; nil }
      r.register Verb::Definition.new(
        "probe.copy", "Copy", "Copy the selected affected URLs, or every affected URL if nothing is selected",
        Verb::Scope::ProbeDetail, [Verb::Chord.new("y")],
        available: in_probe_detail, mnemonic: 'y') { |ctx| ctx.read_copy; nil }

      # The Sequencer's ANALYSIS report. Whole ROWS (label + value in two columns — see
      # `SequencerView#analysis_plain` for the projection a copy produces). `x`/`v`/`S`/`y` are all
      # free in this scope; `r`/`s`/`c` are the run/stop/configure trio.
      in_seq_analysis = ->(ctx : Verb::ExecContext) { ctx.current_tab == :sequencer && ctx.sequencer_analysis_readable? }
      r.register Verb::Definition.new(
        "sequence.select-line", "Select row", "Select the analysis row under the cursor",
        Verb::Scope::Sequencer, [Verb::Chord.new("x")],
        available: in_seq_analysis, mnemonic: 'x') { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "sequence.clear-selection", "Clear selection", "Clear the analysis row selection",
        Verb::Scope::Sequencer, available: in_sel, mnemonic: 'v') { |ctx| ctx.read_clear_selection; nil }
      r.register Verb::Definition.new(
        "sequence.send-to", "Send selection to…", "Send the selected rows to another tool (Decoder, …)",
        Verb::Scope::Sequencer, available: in_sel, mnemonic: 'S') { |ctx| ctx.send_to_open; nil }
      r.register Verb::Definition.new(
        "sequence.copy", "Copy", "Copy the selected analysis rows, or the whole entropy report if nothing is selected",
        Verb::Scope::Sequencer, [Verb::Chord.new("y")],
        available: in_seq_analysis, mnemonic: 'y') { |ctx| ctx.read_copy; nil }

      # The Miner's FINDING pane. Whole ROWS (label + value in two columns — see
      # `MinerView#detail_plain`). `x`/`v`/`S`/`y` are free in this scope; `r`/`s`/`p` are run,
      # stop and send-to-repeater.
      in_miner_detail = ->(ctx : Verb::ExecContext) { ctx.current_tab == :miner && ctx.miner_detail_readable? }
      r.register Verb::Definition.new(
        "mine.select-line", "Select row", "Select the finding row under the cursor",
        Verb::Scope::Miner, [Verb::Chord.new("x")],
        available: in_miner_detail, mnemonic: 'x') { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "mine.clear-selection", "Clear selection", "Clear the finding row selection",
        Verb::Scope::Miner, available: in_sel, mnemonic: 'v') { |ctx| ctx.read_clear_selection; nil }
      r.register Verb::Definition.new(
        "mine.send-to", "Send selection to…", "Send the selected rows to another tool (Decoder, …)",
        Verb::Scope::Miner, available: in_sel, mnemonic: 'S') { |ctx| ctx.send_to_open; nil }
      r.register Verb::Definition.new(
        "mine.copy", "Copy", "Copy the selected finding rows, or the whole finding if nothing is selected",
        Verb::Scope::Miner, [Verb::Chord.new("y")],
        available: in_miner_detail, mnemonic: 'y') { |ctx| ctx.read_copy; nil }

      in_detail_nav = ->(ctx : Verb::ExecContext) { ctx.detail_navigable? }
      r.register Verb::Definition.new(
        "detail.select-line", "Select line", "Select the entire current line",
        Verb::Scope::HistoryDetail, [Verb::Chord.new("x")],
        available: in_detail_nav, mnemonic: 'x', group: :view) { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "detail.clear-selection", "Clear selection", "Clear the text selection",
        Verb::Scope::HistoryDetail, available: in_sel, mnemonic: 'v') { |ctx| ctx.read_clear_selection; nil }
      r.register Verb::Definition.new(
        "detail.send-to", "Send selection to…", "Send the selected text to another tool (Decoder, …)",
        Verb::Scope::HistoryDetail, available: in_sel, mnemonic: 'S') { |ctx| ctx.send_to_open; nil }
    end
  end
end
