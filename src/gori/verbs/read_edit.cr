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
      in_notes_read = ->(ctx : Verb::ExecContext) { ctx.current_tab == :notes && ctx.notes_read_mode? }
      read_trio r, "notes", Verb::Scope::Notes, in_notes_read

      # Plain 'x' = select-line in every Repeater read-mode pane (request/target/response),
      # now that hex is ^X everywhere (the old x=resp-hex collision is gone). Tagged
      # :response (not :common) so the busy :request section and lean COMMON stay
      # uncluttered — and so 'x' never surfaces in the tab-bar/:subtab menus; the 'x'
      # keybinding still works in all three read panes regardless of where it's listed.
      in_repeater_read = ->(ctx : Verb::ExecContext) { ctx.current_tab == :repeater && ctx.repeater_read_mode? }
      # send-to stays in COMMON (not :response like clear-selection): it's menu-only
      # (no keybinding fallback), so it must be listed in EVERY read pane's space menu.
      # command_section is the focused pane (:request/:response/:target), and the menu
      # shows only COMMON ∪ that one section — a :response tag would hide send-to while
      # selecting in the request pane, leaving no way to invoke it.
      read_trio r, "repeater", Verb::Scope::Repeater, in_repeater_read, section: :response

      # Tagged :input (Decoder's read-mode panes are INPUT-read and OUTPUT; :input is
      # the more relevant "editing" pane — OUTPUT keeps 'x' reachable by keybinding).
      in_decoder_read = ->(ctx : Verb::ExecContext) { ctx.current_tab == :decoder && ctx.decoder_read_mode? }
      # COMMON, not :input — menu-only verb must show in both the INPUT and OUTPUT read
      # panes (command_section is cur.pane); see the repeater.send-to note above.
      read_trio r, "decoder", Verb::Scope::Decoder, in_decoder_read, section: :input

      # Tagged :template (Fuzzer's only section named for this in Round 5's spec —
      # :target/:results/:detail are also read-mode-gated, but :template is the one
      # focus area the user singled out; 'x'/'v' keep working by keybinding elsewhere).
      in_fuzzer_read = ->(ctx : Verb::ExecContext) { ctx.current_tab == :fuzzer && ctx.fuzzer_read_mode? }
      # COMMON, not :template — menu-only verb must show in every Fuzzer read pane
      # (command_section follows the focused pane); see the repeater.send-to note above.
      read_trio r, "fuzzer", Verb::Scope::Fuzzer, in_fuzzer_read, section: :template

      # JWT workbench read-mode panes (INPUT-read, DECODED, OUTPUT, ATTACKS). Tagged
      # :input for select-line (the token pane is the one with a fine selection); send-to
      # stays COMMON (menu-only, must show in every read pane — see repeater.send-to note).
      in_jwt_read = ->(ctx : Verb::ExecContext) { ctx.current_tab == :jwt && ctx.jwt_read_mode? }
      read_trio r, "jwt", Verb::Scope::Jwt, in_jwt_read, section: :input, send_desc: "Send the selected text to another tool (Decoder, JWT, …)"

      in_issues_notes = ->(ctx : Verb::ExecContext) { ctx.issues_notes_read_mode? }
      read_trio r, "issue", Verb::Scope::IssuesDetail, in_issues_notes, select_desc: "Select the entire current notes line", clear_desc: "Clear the notes text selection"

      # Verb::Scope::ProjectDesc, not Body — see project.copy in verbs/core.cr for why the
      # description pane stopped borrowing the History list's scope. The read-mode flag itself
      # is tab-blind (ProjectView's pane defaults to :desc, so it reads true from boot), so the
      # gate carries the current_tab half the way in_notes_read / in_repeater_read do.
      #
      # `x` is a real chord again. It was dropped because `ProjectController` raw-dispatched
      # the letter in the desc pane and `handle_body_key` returned true there, so the Keymap
      # never saw it — the verb was listed in the rebind editor and a rebind moved nothing.
      # That arm is gone (KEY_AUDIT §2e), and so is the same-shaped one behind `project.copy`'s
      # `y` in verbs/core.cr.
      in_project_desc = ->(ctx : Verb::ExecContext) { ctx.current_tab == :project && ctx.project_desc_read_mode? }
      read_trio r, "project", Verb::Scope::ProjectDesc, in_project_desc

      # The Rewriter's PREVIEW OUTPUT, tagged `:preview` — the tab is multi-pane, and its rule
      # list already spends `x` on "Enable/disable" (see verbs/rewriter.cr for why every list
      # verb moved into a `:rules` section at the same time). Two sections never render together,
      # so `x` keeps meaning "select line" here and "toggle" there.
      in_rewriter_out = ->(ctx : Verb::ExecContext) { ctx.current_tab == :rewriter && ctx.rewriter_preview_out? }
      in_rewriter_copy = ->(ctx : Verb::ExecContext) do
        ctx.current_tab == :rewriter && (ctx.rewriter_preview_out? || ctx.editor_focused?)
      end
      read_trio r, "rewriter", Verb::Scope::Rewriter, in_rewriter_out, section: :preview, send_section: :preview, select_desc: "Select the entire current preview line", clear_desc: "Clear the preview text selection"
      r.register Verb::Definition.new(
        # `^Y` and the wider gate: the INPUT pane is an EDITOR, where a bare `y` is a literal
        # character that replaces the selection, so Copy has to be reachable by chord there too.
        "rewriter.copy", "Copy", "Copy the selected preview text, or the whole pane if nothing is selected",
        Verb::Scope::Rewriter, [Verb::Chord.new("y"), Verb::Chord.new("y", ctrl: true)],
        available: in_rewriter_copy, intent: :copy, section: :preview) { |ctx| ctx.read_copy; nil }

      # The Comparer's diff. Whole ROWS, never a char span: a screen row is two columns of the
      # same diff, so `ReadPane(line_select_only: true)` is what the cursor is — see
      # `ComparerView#unified_line` for the text a copy produces. `:common` is right here: the
      # tab's other groups are `:subtab` / `:tab` chrome, and the diff IS its body.
      in_comparer_diff = ->(ctx : Verb::ExecContext) { ctx.current_tab == :comparer && ctx.comparer_diff_shown? }
      read_trio r, "comparer", Verb::Scope::Comparer, in_comparer_diff, select_title: "Select row", select_desc: "Select the whole diff row under the cursor", clear_desc: "Clear the diff row selection", send_desc: "Send the selected diff rows to another tool (Decoder, …)"
      r.register Verb::Definition.new(
        "comparer.copy", "Copy", "Copy the selected diff rows as unified text, or the whole diff if nothing is selected",
        Verb::Scope::Comparer, [Verb::Chord.new("y")],
        available: in_comparer_diff, intent: :copy) { |ctx| ctx.read_copy; nil }

      # The Intercept's read-only held-message preview. Mouse-placed caret (see
      # `InterceptController#handle_click`), so `x`/`y` act on wherever the pointer left it.
      # `x` stays chordless (the queue spends its letters on a live action apiece and select-line
      # is the menu's job here, as it is on the Project description); `y` does NOT — see below.
      in_icept_preview = ->(ctx : Verb::ExecContext) { ctx.current_tab == :intercept && ctx.intercept_preview_readable? }
      in_icept_copy = ->(ctx : Verb::ExecContext) { ctx.current_tab == :intercept && ctx.intercept_copyable? }
      read_trio r, "intercept", Verb::Scope::Intercept, in_icept_preview, select_chords: [] of Verb::Chord, select_desc: "Select the entire current preview line", clear_desc: "Clear the preview text selection"
      r.register Verb::Definition.new(
        # `y` in READ and `^Y` in INS too — the copy pair every other text pane ships, and the
        # queue is not the exception it was written as: `y` is free across Scope::Intercept
        # (f/d/⇧F/t/⇧T/c/`/` are its claims), so the letter collides with nothing and the one
        # tab that answered the copy reflex with silence now answers it.
        #
        # The gate is the WIDER `intercept_copyable?`, shared by both chords: the held-bytes
        # editor can build a ⇧arrow selection in INS, where a bare `y` is a literal character
        # that REPLACES it. `Runner#text_input_active?` is what keeps the bare chord out of
        # that editor (Intercept answers `body_takes_text?` while editing), so `^Y` is still
        # the only copy there is while typing — which is what makes it the pinned half.
        "intercept.copy", "Copy", "Copy the selected preview text, or the whole held message if nothing is selected",
        Verb::Scope::Intercept, [Verb::Chord.new("y"), Verb::Chord.new("y", ctrl: true)],
        available: in_icept_copy, intent: :copy) { |ctx| ctx.read_copy; nil }

      # An OAST callback's detail. `section: :detail` (OastController#command_section answers to
      # match): the callbacks LIST spends `y` on "copy the generated payload", and this pane's `y`
      # copies what came back — opposite directions of one interaction, so the two views must not
      # render together.
      in_oast_detail = ->(ctx : Verb::ExecContext) { ctx.oast_detail_readable? }
      read_trio r, "oast", Verb::Scope::OastCallbacks, in_oast_detail, section: :detail, send_section: :detail, select_desc: "Select the entire current callback line", clear_desc: "Clear the callback text selection"
      # The detail's `y` is a REAL chord now, so the Hotkeys editor can see and move it — it
      # used to be a raw `c == 'y'` arm in `OastController#handle_body_key`, which meant the
      # verb showed as unbound and a rebind moved nothing. It pairs with `oast.select-line`'s
      # `x`, one line above, the way `y`/`x` pair in every other READ pane.
      #
      # Only ONE of this scope's two copies can hold the letter: `validate_chords!` is a static
      # per-scope sweep and the keymap has no focus dimension, so `oast.copy` (the LIST's "copy
      # the payload URL I just generated") keeps its controller arm and its 'y' menu letter.
      # The arm runs before the keymap, so the list is unchanged; this chord is only ever
      # reached with the detail open, which is what `in_oast_detail` already says.
      r.register Verb::Definition.new(
        "oast.copy-callback", "Copy callback", "Copy the selected callback text, or the whole callback if nothing is selected",
        Verb::Scope::OastCallbacks, [Verb::Chord.new("y")],
        available: in_oast_detail, intent: :copy, section: :detail) { |ctx| ctx.read_copy; nil }

      # A Probe issue's detail, which is TWO read panes — AFFECTED URLS and DESCRIPTION — and
      # these verbs act on whichever holds focus. `ProbeView` routes them through one `pane`
      # accessor for exactly that reason, so the wording here has to stay pane-neutral: `y` on
      # the remediation text is the point of giving that pane focus at all.
      #
      # `Verb::Scope::ProbeDetail` carries one mnemonic of its own — `u` on
      # `probe.open-affected`, the ↵ that opens the highlighted URL's flow — so `x`/`v`/`S`/`y`
      # still land in `:common` with nothing to collide with, but a new key here does have to be
      # checked against it (and against the scope's plain chords o/r/p/c/d, which `menu_key`
      # derives menu entries from).
      in_probe_detail = ->(ctx : Verb::ExecContext) { ctx.probe_detail_readable? }
      read_trio r, "probe", Verb::Scope::ProbeDetail, in_probe_detail, select_desc: "Select the line under the cursor in the focused pane", clear_desc: "Clear the selection in the focused pane"
      r.register Verb::Definition.new(
        "probe.copy", "Copy", "Copy the selection, or the whole focused pane if nothing is selected",
        Verb::Scope::ProbeDetail, [Verb::Chord.new("y")],
        available: in_probe_detail, intent: :copy) { |ctx| ctx.read_copy; nil }

      # The Sequencer's ANALYSIS report. Whole ROWS (label + value in two columns — see
      # `SequencerView#analysis_plain` for the projection a copy produces). `x`/`v`/`S`/`y` are all
      # free in this scope; `r`/`s`/`c` are the run/stop/configure trio.
      in_seq_analysis = ->(ctx : Verb::ExecContext) { ctx.current_tab == :sequencer && ctx.sequencer_analysis_readable? }
      # `y` reaches the SAMPLES list too (#964's shape): the sample's token, where the report
      # panes copy their rows.
      in_seq_copy = ->(ctx : Verb::ExecContext) { ctx.current_tab == :sequencer && (ctx.sequencer_analysis_readable? || ctx.sequencer_samples_readable?) }
      read_trio r, "sequence", Verb::Scope::Sequencer, in_seq_analysis, select_title: "Select row", select_desc: "Select the analysis row under the cursor", clear_desc: "Clear the analysis row selection", send_desc: "Send the selected rows to another tool (Decoder, …)"
      r.register Verb::Definition.new(
        "sequence.copy", "Copy", "Copy the selected analysis rows, or the whole entropy report if nothing is selected",
        Verb::Scope::Sequencer, [Verb::Chord.new("y")],
        available: in_seq_copy, intent: :copy) { |ctx| ctx.read_copy; nil }

      # The Miner's FINDING pane. Whole ROWS (label + value in two columns — see
      # `MinerView#detail_plain`). `x`/`v`/`S`/`y` are free in this scope; `r`/`s`/`p` are run,
      # stop and send-to-repeater.
      in_miner_detail = ->(ctx : Verb::ExecContext) { ctx.current_tab == :miner && ctx.miner_detail_readable? }
      # `y` reaches the FINDINGS list too (#964's shape): the finding as one line.
      in_miner_copy = ->(ctx : Verb::ExecContext) { ctx.current_tab == :miner && (ctx.miner_detail_readable? || ctx.miner_results_readable?) }
      read_trio r, "mine", Verb::Scope::Miner, in_miner_detail, select_title: "Select row", select_desc: "Select the finding row under the cursor", clear_desc: "Clear the finding row selection", send_desc: "Send the selected rows to another tool (Decoder, …)"
      r.register Verb::Definition.new(
        "mine.copy", "Copy", "Copy the selected finding rows, or the whole finding if nothing is selected",
        Verb::Scope::Miner, [Verb::Chord.new("y")],
        available: in_miner_copy, intent: :copy) { |ctx| ctx.read_copy; nil }

      in_detail_nav = ->(ctx : Verb::ExecContext) { ctx.detail_navigable? }
      read_trio r, "detail", Verb::Scope::HistoryDetail, in_detail_nav, group: :view
    end

    # One pane's select-line (`x`) / clear-selection / send-to trio. Ids, titles, chords and
    # sections are spelled by the caller; only the shapes every pane shares live here.
    private def self.read_trio(r : Verb::Registry, prefix : String, scope : Verb::Scope,
                               gate : Verb::ExecContext -> Bool, *,
                               section : Symbol = :common, send_section : Symbol = :common,
                               group : Symbol = :none,
                               select_chords : Array(Verb::Chord) = [Verb::Chord.new("x")],
                               select_title : String = "Select line",
                               select_desc : String = "Select the entire current line",
                               clear_desc : String = "Clear the text selection",
                               send_desc : String = "Send the selected text to another tool (Decoder, …)") : Nil
      r.register Verb::Definition.new(
        "#{prefix}.select-line", select_title, select_desc, scope, select_chords,
        available: gate, intent: :select_line, section: section, group: group) { |ctx| ctx.read_select_line; nil }
      r.register Verb::Definition.new(
        "#{prefix}.clear-selection", "Clear selection", clear_desc, scope,
        available: ->(ctx : Verb::ExecContext) { ctx.read_selection_active? },
        intent: :clear_selection, section: section) { |ctx| ctx.read_clear_selection; nil }
      # `S Send selection to…` is LISTED without a selection too, and acts on the line under
      # the cursor when there is none — every `*_selection_text` already falls back to it, the
      # same fallback `y` takes. Gated on the selection alone it was invisible until a selection
      # existed, and nothing anywhere advertised the `x` that makes one: the only route from a
      # response to the Decoder / JWT / Cookie / Sequencer was a verb you had to already know
      # about to discover. The menu title says which of the two it is about to send
      # (`Runner#space_menu_title`).
      r.register Verb::Definition.new(
        "#{prefix}.send-to", "Send selection to…", send_desc, scope,
        available: ->(ctx : Verb::ExecContext) { ctx.read_selection_active? || gate.call(ctx) },
        intent: :send_selection, section: send_section) { |ctx| ctx.send_to_open; nil }
    end
  end
end
