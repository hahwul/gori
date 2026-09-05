require "termisu"
require "../verb"
require "../session"
require "../hotkeys"
require "./keybind"
require "../repeater/subtab_filter"
require "./subtab_marks"
require "./controllers/tab_close"
require "./screen"
require "./geometry"
require "./frame"
require "./chrome"
require "./theme"
require "./jobs"
require "./notifications"

module Gori::Tui
  # The narrow facade a TabController is given to drive the shell's cross-cutting
  # state (P5 — state changes are mediated). A controller never touches the
  # Runner's ivars directly; it asks the Host. Runner implements this. Keeping it
  # thin is deliberate: a controller can only nudge the shell through these, so two
  # controllers can never re-couple via shared private state.
  module Host
    abstract def status(message : String) : Nil       # set the transient status/toast line
    abstract def request_overlay(kind : Symbol) : Nil # set @overlay (controllers can't write it directly)
    abstract def request_focus(pane : Symbol) : Nil   # drive the focus model via focus_pane (:menu | :subtabs | :body)
    abstract def focus_body : Nil                     # raw: focus the body WITHOUT resetting the pane (for clicks)
    # Re-resolve focus after sub-tabs CLOSED — the strip may have dropped below its
    # threshold or vanished. Called from inside the close (the confirm's action, when there
    # is one), because a caller that ran it beside `request_close` would be reading the
    # pre-close strip: `Runner#confirm` defers its action to `on_close`.
    abstract def resolve_subtab_focus : Nil
    abstract def switch_tab(tab : Symbol) : Nil # change the active tab (with save-on-leave + on_enter)
    abstract def goto_tab(tab : Symbol) : Nil   # raw: set active tab + body focus, no on_enter/view_focus_first (e.g. ^R → Repeater)
    abstract def open_palette : Nil             # open the command palette overlay
    abstract def open_space_menu : Nil          # open the space action menu (bottom-right)
    # The QL reference popup. Reached from a filter bar (see `ql_help_key?`), where the
    # question "what fields are there?" actually occurs — a controller cannot open an
    # overlay itself, so it asks here.
    abstract def open_help_query(surface : Symbol) : Nil
    # Open the Fuzzer's payload-set editor overlay (nil = add a new set, else edit that
    # index) / the advanced-settings overlay. The Runner builds them from the current view.
    abstract def open_fuzz_set_editor(edit_index : Int32?) : Nil
    abstract def open_fuzz_advanced_editor : Nil
    # The Authorize tab's identity LIST. Only the list is opened from outside: the per-identity
    # form is reached from it, and an overlay cannot open another overlay, so the Runner keeps
    # that hand-off to itself (Runner#open_authorize_identities).
    abstract def open_authorize_identities : Nil

    # The History VIEW picker (#776) — the `v` chord's own overlay, reached from the filter
    # bar's `v:` chip as well, and an overlay is not a controller's to open.
    #
    # CONCRETE and a no-op, for the reason `subtab_find_focused?` below is concrete: twenty
    # spec files `include Host` to drive a controller, none of them can open an overlay, and
    # "do nothing" is the body every one of them already writes for `request_overlay` and its
    # neighbours. The Runner's own `open_history_view_picker` (runner/views.cr) overrides it.
    def open_history_view_picker : Nil
    end

    # The History column editor (#819). Same seam, and same reason, as the view picker above:
    # the Runner's own `open_history_columns` (runner/columns.cr) overrides it.
    def open_history_columns : Nil
    end

    # Reconfigure the current Sequencer session's token descriptor/goal (the `c` chord).
    abstract def reconfigure_sequence : Nil
    # Open the Project SCOPE rule popup (nil edit_id = add; else edit that rule id).
    # Kind/type/pattern seed the form when editing (or defaults for add).
    abstract def open_scope_rule_editor(edit_id : Int64?, kind : String, match_type : String, pattern : String) : Nil
    # Open the Probe custom-rule popup (nil = add a new rule; else edit the given rule).
    abstract def open_custom_rule_editor(rule : Probe::CustomRule?) : Nil
    # Open the Rewriter (Match & Replace) rule popup (nil = add; else edit the given rule).
    abstract def open_rewriter_rule_editor(rule : Store::MatchRule?) : Nil
    abstract def open_rewriter_preset_picker : Nil
    # Open the Colormarker (History row-colour) rule popup (nil = add; else edit).
    abstract def open_colormarker_rule_editor(rule : Store::ColorRule?) : Nil
    # Open the custom-colour editor popup (nil = add; else edit the given colour).
    abstract def open_colormarker_color_editor(color : Settings::ColormarkerColor?) : Nil
    abstract def open_extract_rule_editor(rule : Store::ExtractRule?) : Nil
    # The Decoder's named-chain library (global settings.json): the "save under a name"
    # prompt and the picker over what is already saved. Here rather than driven from the
    # verbs alone because the Decoder body also binds them directly (^S / ^O), and a
    # controller cannot open an overlay itself.
    abstract def open_chain_save : Nil
    abstract def open_chain_load : Nil
    # The Rewriter has no library pair here: its rules ARE global or project (RuleScope), a
    # property of the rule itself that `s` flips in place, so there is nothing to save into or
    # pick out of and no overlay for the Host to open.
    # Open the OAST provider add/edit popup (nil = add a new provider; else edit the given
    # provider — global or project scope, per Oast::ProviderConfig#scope).
    abstract def open_oast_provider_editor(provider : Oast::ProviderConfig?) : Nil
    # Destructive-action confirmation modal; `action` runs on confirm. `return_to` is the
    # overlay restored on cancel/accept (default :none) — pass the launching overlay (e.g.
    # :detail) when raising the confirm from inside another overlay so cancel returns there.
    abstract def confirm(title : String, message : String, *, confirm_label : String, danger : Bool, return_to : Symbol = :none, &action : -> Nil) : Nil
    abstract def session : Session   # store / scope / proxy / registry / interceptor
    abstract def overlay : Symbol    # read the overlay state (e.g. History reads :detail)
    abstract def active_tab : Symbol # read the active tab (Repeater reconcile gates on it)
    abstract def focus : Symbol      # read the focus model (:menu | :subtabs | :body)

    # A toast WITH a status-strip glyph: `:busy` (spinner), `:done` (✓) or `:error` (✗) — see
    # `Runner#format_status_message` for why the glyph is a kind on the call and not a prefix
    # of the text. CONCRETE with a plain-toast fallback for the same reason `subtab_find_focused?`
    # below is: the spec doubles that `include Host` should not each have to restate it.
    # Runner overrides it.
    def status(message : String, kind : Symbol) : Nil
      status(message)
    end

    # The strip's ⌕ affordance is the current stop — one step LEFT of the first chip, inside
    # `:subtabs` focus. CONCRETE, not abstract: nine spec files `include Host` to drive a
    # controller, and `false` is the right answer for every one of them. Runner overrides.
    def subtab_find_focused? : Bool
      false
    end

    abstract def reveal? : Bool                # global whitespace-reveal pref, pushed into views
    abstract def toggle_reveal : Nil           # flip the whitespace-reveal pref (^B from any view)
    abstract def pretty? : Bool                # global pretty-print-bodies pref, pushed into views
    abstract def toggle_pretty : Nil           # flip the pretty-print pref (`p` from History/Repeater)
    abstract def jobs : Jobs                   # shared background-job registry (bottom-bar activity)
    abstract def notifications : Notifications # shared notification store (center + badge)
    abstract def toggle_scope_lens : Nil       # flip the scope display lens (Project settings pane row/click)
    abstract def toggle_sandbox : Nil          # flip the scope sandbox — hard block gate (Project NETWORK pane row/click)
    # Persist + apply the Project settings pane's per-project network config; returns a toast.
    abstract def apply_project_network(bind_host : String, bind_port : Int32, upstream : String,
                                       connect_secs : Int32, io_secs : Int32, capture_mib : Int32) : String

    # Secret-bearing extension used by the real Runner. The positional overload stays as the
    # compatibility contract for the small controller Host doubles; their tests do not own a
    # project DB and deliberately exercise controller routing rather than persistence.
    def apply_project_network(config : Settings::ProjectNetworkConfig) : String
      apply_project_network(config.bind_host, config.bind_port, config.upstream,
        config.connect_secs, config.io_secs, config.capture_mib)
    end

    # Persist + load this project's gRPC `.proto` descriptor set path (#823); returns a toast
    # naming what loaded (or why nothing did). Blank = the `~/.gori/protos` convention dir.
    abstract def apply_project_protos(spec : String) : String
  end

  # Shared, state-free body chrome used by BOTH Runner and the per-tab
  # controllers, so the framed-card outline and the Repeater/Notes sub-tab strip are
  # drawn identically wherever they appear. Extracted from Runner so a controller
  # can frame its own body without reaching back into the shell.
  module BodyChrome
    extend self

    # Frame a single body pane and yield the inset interior. Gold outline when the
    # body holds focus, hairline at rest. Outline-only on the canvas (bg = BG),
    # distinct from the lifted PANEL-filled modal overlays.
    def framed(screen : Screen, rect : Rect, focused : Bool, & : Rect ->) : Nil
      Frame.card(screen, rect, bg: Theme.bg, border: focused ? Theme.focus_gold : Theme.border)
      yield frame_inner(rect)
    end

    # One cell inside a body frame — shared by render and click hit-tests.
    def frame_inner(rect : Rect) : Rect
      rect.inset(1, 1)
    end

    # True when the outer body shell should gild its border — single-pane tabs only.
    # Multi-pane views (Repeater, Fuzzer, …) highlight the focused pane themselves.
    def shell_focused(focus : Symbol, *, multi_pane : Bool) : Bool
      focus == :body && !multi_pane
    end

    # Frame the tab body, carve the sub-tab strip from the interior top when
    # `labels` is given, then yield the remaining content rect.
    # `strip_divider: false` carves chips only (height 1), leaving a sibling row to own
    # the hairline underneath instead of splitting chips from that row. All current tabs
    # pass `true` (see subtab_strip_divider?); the false path is kept for flexibility.
    def framed_body(screen : Screen, rect : Rect, shell_focused : Bool,
                    subtabs_focused : Bool, labels : Array(String)?, active : Int32,
                    prev_start : Int32 = 0, hidden : Set(Int32)? = nil, *,
                    strip_divider : Bool = true, find : Bool = false,
                    find_lit : Bool = false, marked : Set(Int32)? = nil, & : Rect ->) : Int32
      new_start = prev_start
      framed(screen, rect, shell_focused) do |inner|
        if labels
          sub_rect, content = carve_subtab_row(inner, divider: strip_divider)
          new_start = render_subtab_strip(screen, sub_rect, labels, active, subtabs_focused,
            prev_start, hidden, find: find, find_lit: find_lit, marked: marked)
          yield content
        else
          yield inner
        end
      end
      new_start
    end

    # Content rect inside a framed body after optional sub-tab carving — keeps
    # render and click geometry aligned.
    def content_rect(rect : Rect, *, strip : Bool, strip_divider : Bool = true) : Rect
      inner = frame_inner(rect)
      strip ? carve_subtab_row(inner, divider: strip_divider)[1] : inner
    end

    # The sub-tab strip inside a framed body (nil when hidden).
    def strip_rect(rect : Rect, *, strip : Bool, strip_divider : Bool = true) : Rect?
      return nil unless strip
      carve_subtab_row(frame_inner(rect), divider: strip_divider)[0]
    end

    # Height of the sub-tab chrome carved off a body rect: chips only, or chips + the
    # hairline that anchors the strip to the body card below.
    CHIPS_H = 1
    STRIP_H = 2

    # Carve the top of a body rect for the sub-tab strip, returning {strip, body_below}.
    # Degenerate heights keep the body on `rect`. `divider: false` → chips row only.
    def carve_subtab_row(rect : Rect, *, divider : Bool = true) : {Rect, Rect}
      h = {(divider ? STRIP_H : CHIPS_H), rect.h}.min
      sub = Rect.new(rect.x, rect.y, rect.w, h)
      body = rect.h > h ? Rect.new(rect.x, rect.y + h, rect.w, rect.h - h) : rect
      {sub, body}
    end

    # The clickable 1-row chip band within a carved strip (hit-tests ignore the divider).
    def tab_row(strip : Rect) : Rect
      Rect.new(strip.x, strip.y, strip.w, 1)
    end

    # ===== the ⌕ "find sub-tab" affordance ===================================
    # A pill at the LEFT edge of the chip row that opens the sub-tab picker. It lives here
    # rather than in `Chrome` on purpose: `Chrome.render_tab_strip` is also the Project tab's
    # self-drawn strip (project_view.cr) and the Preferences group strip (preferences_view.cr),
    # neither of which is a sub-tab strip. Carving the row one layer up excludes them
    # STRUCTURALLY instead of by a flag those two would have to keep passing as false.

    # `▎ ⌕` — the glyph alone, no session count beside it. The strip's own chips already
    # say how many there are, and the filter bar one row below prints `visible/total`; a
    # number on the pill was a third telling of the same fact, in the one spot on the row
    # that has to stay quiet.
    #
    # Three columns, no breathing room spent on a glyph this small:
    #
    #     col 0    │ col 1 │ col 2
    #     MARKER   │ ICON  │ spare
    #
    # `⌕` (U+2315) and `▎` (U+258E) are both East-Asian AMBIGUOUS: termisu measures each as
    # 1 column, a terminal set to paint ambiguous glyphs double gives them 2. This layout
    # does NOT try to stay correct under that setting, and neither does anything else here —
    # box drawing (U+2500..257F) is ambiguous too, so a terminal in that mode has already
    # doubled every border gori draws. Widening the pill to survive alone would buy nothing
    # and cost the two columns that made a one-glyph control look like an empty chip.
    #
    # The one column kept is `spare`, and it earns its place in the measure we DO ship:
    # `Chrome` writes its `‹` overflow marker at the chips rect's x (chrome.cr:507), and a
    # glyph that ended on that column would be orphaned and blanked by it (the terminal
    # clears a wide glyph's lead when something lands on its continuation cell). The spare
    # is what keeps `⌕` on screen when the strip scrolls.
    ICON_W = 3
    ICON   = "⌕"
    # The cursor bar that marks the pill as the strip's current stop. Same glyph the ~45
    # `focused ? '▎' : ' '` sites across the app use for "this is the current item".
    MARKER = '▎'

    # {icon rect, chips rect} for one chip row — the SINGLE source of both. Returned as a
    # pair so no caller can narrow one without the other; `Chrome.more_button_rect` +
    # `tabs_area` are the same pair one level up. `show: false` (a fixed or self-drawn strip)
    # gives {nil, row}, which is byte-for-byte the layout from before the affordance existed.
    #
    # The icon is dropped when it would not leave room for the FIRST VISIBLE chip plus the
    # two `‹`/`›` overflow columns: an affordance for finding sub-tabs must never be the
    # reason no sub-tab is on screen. When dropped, the chips get every column back — they must not
    # pay for a pill that was not drawn.
    def find_icon_split(row : Rect, labels : Array(String), hidden : Set(Int32)?,
                        *, show : Bool) : {Rect?, Rect}
      return {nil, row} if !show || row.empty? || labels.empty?
      first = (0...labels.size).find { |i| hidden.nil? || !hidden.includes?(i) }
      return {nil, row} unless first
      need = Screen.display_width(labels[first]) + 2 + 2 # chip + the ‹ / › columns
      return {nil, row} if row.w - ICON_W < need
      {Rect.new(row.x, row.y, ICON_W, 1),
       Rect.new(row.x + ICON_W, row.y, row.w - ICON_W, 1)}
    end

    # The pill itself: a `▎` cursor and gold ink when it is the strip's current stop, a
    # muted glyph at rest. The cursor sits flush against the glyph — `▎⌕` is one mark, the
    # way the project picker draws `│▎ + New project` against its own card edge.
    # Deliberately NOT the solid gold block the active chip and
    # `Chrome.render_more_button` wear — this is one glyph, not a labelled chip, and a
    # filled 5-column band around it reads as a chip that lost its label. The state change
    # is a SHAPE (a mark that was not there) rather than colour alone, which is what makes
    # it catchable at the edge of vision on a wide strip.
    #
    # Gold, not the `Theme.accent` every other `▎` in the app uses: accent marks the current
    # row INSIDE a focused list, while this row already spends gold on "which stop has the
    # keys" (the active chip, the hairline below). A third colour here would say the pill is
    # a third kind of thing. `focus_gold` is defined as an outline/ink colour in all 30
    # palettes, light ones included, so it carries its own contrast.
    #
    # The ink is bound to `seg` so a double-width `⌕` cannot paint into the first chip.
    private def render_find_icon(screen : Screen, seg : Rect, lit : Bool) : Nil
      fg = lit ? Theme.focus_gold : Theme.muted
      # A space at rest, like every other cursor column in the app: the cell is claimed
      # either way, so a stale mark can never survive a frame where the pill lost focus.
      screen.cell(seg.x, seg.y, lit ? MARKER : ' ', fg, Theme.bg)
      gx = seg.x + 1
      screen.text(gx, seg.y, ICON, fg, Theme.bg,
        lit ? Attribute::Bold : Attribute::None, width: seg.right - gx)
    end

    # The frame-less segmented control shared by Repeater, Notes, Fuzzer, … `focused` =
    # the strip itself holds focus (←/→ switch) → active chip lights FOCUS_GOLD and the
    # divider hairline matches (when the strip owns that hairline, i.e. rect.h ≥ 2).
    # `find` = this strip gets the ⌕ affordance, `find_lit` whether it is the strip's
    # current stop. `marked` = the chips wearing a multi-select mark (#683); nil both when
    # the strip does not mark at all and when nothing on it is marked.
    # Keyword-only: the positional tail here is already `prev_start, hidden`
    # at a dozen call sites, and a new positional would bind silently to the wrong one.
    def render_subtab_strip(screen : Screen, rect : Rect, labels : Array(String),
                            active : Int32, focused : Bool, prev_start : Int32 = 0,
                            hidden : Set(Int32)? = nil, *,
                            find : Bool = false, find_lit : Bool = false,
                            marked : Set(Int32)? = nil) : Int32
      return prev_start if rect.empty?
      icon, chips = find_icon_split(tab_row(rect), labels, hidden, show: find)
      # `lit` is false whenever the pill was dropped for width, so a narrow terminal leaves
      # the bright pill on the active chip rather than on nothing at all.
      lit = focused && find_lit && !icon.nil?
      render_find_icon(screen, icon, lit) if icon
      new_start = Chrome.render_tab_strip(screen, chips, labels, active, focused && !lit, prev_start, hidden, marked: marked)
      return prev_start if rect.h < 2
      # The hairline reads the UNMODIFIED focus: the affordance is a stop on the strip, so
      # the strip still owns the row even while the active chip is dimmed.
      border = focused ? Theme.focus_gold : Theme.border
      screen.hline(rect.x, rect.y + 1, rect.w, fg: border, bg: Theme.bg)
      new_start
    end
  end

  # The shell controller for ONE top-level tab. It owns its view object and all the
  # per-tab input/render/focus logic that used to live in Runner's `case @active_tab`
  # ladders. Concrete defaults make most hooks optional, so a simple read-only tab
  # (Help) overrides only `tab`/`render_body`/`command_scope`, while a rich tab
  # (Repeater) overrides the input/focus/lifecycle hooks too.
  abstract class TabController
    property subtab_start : Int32 = 0

    # --- sub-tab filter (issue #121; shared across the multi-session workbench tabs) ---
    # A live in-memory query (tag:/name:/host:/method: + free text) that narrows which
    # chips the strip shows. Opt-in per tab via subtab_filter_enabled? + filter_subjects;
    # non-participating tabs (History, Help, …) leave these at their inert defaults.
    @subtab_filter = ""            # the live query string ("" = no filter, all shown)
    @subtab_filter_editing = false # the `/` bar is capturing keystrokes
    @filter_cx = 0                 # caret index within @subtab_filter
    @filter_preedit = ""           # live IME composition in the bar

    # --- sub-tab multi-select (issue #683; the #442 mark model on the strip) ---
    # Keyed on the sub-tab's view object, never its chip index — see SubtabMarks. A tab
    # opts in by overriding `subtab_ref`; everything else here is derived, so a strip that
    # cannot name its sub-tabs' identity simply has no marks.
    @subtab_marks = SubtabMarks.new

    def initialize(@host : Host)
    end

    # --- identity ---
    abstract def tab : Symbol                # the registry key (== Chrome::TABS symbol)
    abstract def command_scope : Verb::Scope # the space-menu scope when this tab + body has focus

    # The space menu's CONTEXT section when this tab's body holds focus — the current
    # focus-area within the tab (e.g. Repeater :request/:response/:target). Default
    # :common: single-region tabs (History, Sitemap, …) have no sub-area to single
    # out, so their menu is just the one COMMON group, identical to today.
    def command_section : Symbol
      :common
    end

    # --- rendering --- (`focus` is the shell's @focus: :menu | :subtabs | :body)
    abstract def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil

    # --- input (return true = handled; false = fall through to the verb keymap) ---
    # Called only when this tab is active, no overlay is open, and @focus == :body.
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      false
    end

    # Called when a left-click lands in the body rect (after the strip is handled).
    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      false
    end

    # ⌥/⌃ + ←/→/Home/End/⌫ are EDITOR MOTION — word step, buffer jump, word delete — not
    # command chords. A controller that defers modified chords to the central keymap (so they
    # stay rebindable) has to let these through FIRST, or the editor loses word motion.
    #
    # Safe against the keymap by construction: `Verb::Chord` parses only letters, digits and
    # punctuation, so none of these can ever BE a binding. Repeater and Fuzzer each carried a
    # byte-identical private copy of this and its `word_delete?` half; the Decoder and JWT
    # needed it too, and a fourth copy is how the first three drifted apart in every other
    # part of this sweep.
    def editing_motion?(ev : Termisu::Event::Key) : Bool
      return false unless ev.ctrl? || ev.alt?
      key = ev.key
      return true if key.left? || key.right? || key.home? || key.end?
      return true if key.backspace?
      c = ev.char
      !!c && (c == '\u{7F}' || c == '\b')
    end

    # An arrow OR its vim twin — and the twin only when the press carries NO command
    # modifier. That second half is the whole point of these living here.
    #
    # A `key.lower_k?` arm looks modifier-free and is not: the parser decodes 0x01..0x1A as
    # `(LowerA..LowerZ, Modifier::Ctrl)`, so `^K` IS `Key::LowerK`, and an ⌥ event carries the
    # letter the same way. `^K`, `^L` and every ⌥+letter are chords the hotkey editor offers
    # (neither `Hotkeys.claimed?` nor `Verb::Reserved.reserved?`), so a pane matching the bare
    # key alone silently ate whatever the operator had bound there — the `Event::Key#key` half
    # of the trap `ctrl_letter_guard_spec` pins for `Event::Key#char`.
    #
    # Most panes are already safe because their ladder opens with a
    # `return false if ev.ctrl? || ev.alt?` defer; these exist for the arms that run BEFORE
    # such a defer or in a pane that has none — the four empty-state handlers and the
    # Comparer. `h`/`j` are covered for symmetry, though only `k`/`l` were reachable in the
    # Ctrl form: `^H`/`^I`/`^J`/`^M` arrive as Backspace/Tab/Enter and never as Ctrl+letter,
    # which is exactly why `Verb::Reserved` refuses to bind them. The ⌥ forms of all four are
    # reachable. Contract: `spec/tui/contract_body_key_spec.cr`.
    def nav_up?(ev : Termisu::Event::Key) : Bool
      ev.key.up? || (ev.key.lower_k? && bare_chord?(ev))
    end

    def nav_down?(ev : Termisu::Event::Key) : Bool
      ev.key.down? || (ev.key.lower_j? && bare_chord?(ev))
    end

    def nav_left?(ev : Termisu::Event::Key) : Bool
      ev.key.left? || (ev.key.lower_h? && bare_chord?(ev))
    end

    def nav_right?(ev : Termisu::Event::Key) : Bool
      ev.key.right? || (ev.key.lower_l? && bare_chord?(ev))
    end

    # No command modifier — the shape a pane-local letter must be matched in, since anything
    # carrying ⌃/⌥ belongs to the central keymap.
    def bare_chord?(ev : Termisu::Event::Key) : Bool
      !ev.ctrl? && !ev.alt?
    end

    # Say so when a keystroke just destroyed a MULTI-character selection (replace-on-type:
    # `TextArea#insert` cuts the selection before splicing). The loss is one undo step, but
    # nothing told the operator that — and this is the exact keystroke people mean when they
    # report "I pressed a key and my text vanished", because in INS the copy reflex `y` is a
    # literal character. Every INS printable arm calls this right after `insert`, reading the
    # count the editor exposes (`TextArea#last_replaced`).
    #
    # `> 1` on purpose: replacing a single selected character is ordinary typing and a toast
    # for it would fire constantly.
    def report_replaced(n : Int32) : Nil
      return unless n > 1
      @host.status("replaced #{n} chars — ^Z to undo")
    end

    # Whether a press in this tab's body can start a DRAG — pointer motion with the button
    # held, which extends a selection from where the press landed. False by default: a tab
    # opts in only for a pane that has a text selection to extend.
    def supports_drag? : Bool
      false
    end

    # Pointer moved with the button held. Extends the selection to (mx, my).
    def handle_drag(rect : Rect, mx : Int32, my : Int32) : Nil
    end

    # Two presses in the same cell inside the double-click window. Selects the word under the
    # pointer; return false to fall back to the ordinary single-click behaviour.
    def handle_double_click(rect : Rect, mx : Int32, my : Int32) : Bool
      false
    end

    # Whether a bracketed paste should be collected and delivered to this tab as ONE bulk
    # insert (`paste_text`) instead of as N keystrokes. False by default: a tab opts in only
    # for a focused MULTI-LINE text editor, since that is the only surface where the two
    # paths produce the same buffer — and the only one where the per-keystroke cost matters.
    # See `Runner#begin_bulk_paste?`.
    def accepts_bulk_paste? : Bool
      false
    end

    # Insert a whole pasted string at the caret as one undoable edit. Line breaks arrive as
    # `\n` (the CRLF filter already collapsed the wire's pairs). Returns false when the tab
    # could not take it after all, so the Runner can report the paste as dropped rather than
    # silently swallowing it.
    def paste_text(text : String) : Bool
      false
    end

    # A scroll-wheel notch over the body (already ±3-scaled).
    def handle_wheel(step : Int32) : Bool
      false
    end

    # Page/jump keyboard nav (PageUp/PageDown → ±one screenful; Home/End → top/bottom).
    # `delta` is a signed row count; Home/End pass a large magnitude and rely on the
    # view's own clamping (so the exact value only needs to exceed the list length).
    # Return true if this tab has a navigable body that consumed it. Default: not
    # navigable — editors leave this false so the physical keys fall through untouched.
    def body_scroll(delta : Int32) : Bool
      false
    end

    # The PgUp/PgDn step for the pane `body_scroll` will move: the rows that pane drew LAST
    # FRAME minus two of overlap (the `HistoryView#list_page_rows` convention), or nil to
    # take the Runner's whole-body fallback. A body-height page skipped the rows a frame,
    # a header and a preview split had taken off the list — four to ten a press, never
    # seen. Read after a render; a pane that has not drawn yet answers 1.
    def page_rows : Int32?
      nil
    end

    # Same notch, but with the pointer position + body rect — lets a multi-pane tab
    # (Project) scroll the pane UNDER the cursor instead of the focused one. Defaults
    # to the coordinate-free handle_wheel, so single-target tabs need no change.
    def handle_wheel_at(step : Int32, mx : Int32, my : Int32, rect : Rect) : Bool
      handle_wheel(step)
    end

    # Live IME composition text for the focused body field. Return true if consumed.
    def set_preedit(text : String) : Bool
      false
    end

    # --- sub-tab strip (Repeater/Notes); nil = no strip ---
    def subtab_labels : Array(String)?
      nil
    end

    def subtab_index : Int32
      0
    end

    # Whether the sub-tab strip is drawn AND `:subtabs` is a focusable pane. Default:
    # only with ≥2 chips — a lone chip has nowhere to switch to, so the row is better
    # spent on the body. Repeater/Fuzzer override to show a single chip too, so the active
    # session is always labelled and the strip's space-menu is reachable with one open
    # tab. The Runner reads this (not a raw count) so render + focus + click stay in sync.
    def subtab_strip_shown? : Bool
      (subtab_labels.try(&.size) || 0) >= 2
    end

    # The controller draws its own chip strip somewhere other than the body's top edge, so the
    # shell's strip geometry does not describe it and must not hit-test with it — the
    # controller's handle_click owns chip clicks instead. Project sets this: its strip rides
    # UNDER the OVERVIEW band, and the shell's strip rect would land on OVERVIEW rows.
    # Whether this strip gets the ⌕ affordance. ONE predicate: the render (framed_body) and
    # the shell's click hit-test both read it, so the pill and its click zone cannot drift
    # apart.
    #
    # A FIXED strip (Help / Probe / Target / OAST) has nothing to find — its two or three
    # chips ARE the tab's structure, and they never pile up. A self-drawn strip (Project)
    # is not at the geometry the shell would hit-test. Every `framed_body` call site passes
    # this, so the decision lives here rather than in twelve callers, and a new tab cannot
    # forget to make it.
    #
    # Shown from ONE session up, matching the picker's own threshold: a lone session still
    # answers "what is open here", and the affordance must not appear and vanish as sessions
    # come and go.
    def subtab_find_shown? : Bool
      return false if subtabs_fixed? || subtab_strip_self_drawn?
      subtab_count >= 1
    end

    def subtab_strip_self_drawn? : Bool
      false
    end

    # Move the active sub-tab by ±1 (strip ←/→), or jump to an absolute index (^1-9).
    def move_subtab(dir : Int32) : Nil
    end

    def jump_subtab(idx : Int32) : Nil
    end

    # A searchable row's detail column is capped here. `NotesController#filter_subjects`
    # puts the WHOLE note body in `summary` — deliberately, so a note is findable by any
    # word it holds — and `SubtabPicker` precomputes one lowercased haystack per row.
    SEARCH_DETAIL_MAX = 200

    # Cap for `subtab_search_extras` text: the request line + headers + the start of a
    # body, and small enough that a multi-MiB capture can't make N sessions × its size
    # the picker's per-open cost.
    SEARCH_EXTRA_MAX = 2048

    # Rows for the "find sub-tab" search picker (the strip's ⌕ affordance, or space → search).
    #
    # The detail column is the SAME projection the `/` filter bar matches on: every session
    # tab already builds `filter_subjects`, so one description of a session serves both, and
    # the two cannot drift into disagreeing about what a session is called. Before this,
    # only Repeater filled the column — on the other seven tabs the picker could be searched
    # by chip label alone, which is exactly the thing an operator does not remember when
    # twenty sessions have piled up. Fixed strips return an empty array and fall back to a
    # bare label, as they did before.
    #
    # Built once per open (SubtabPicker caches the haystacks), so nothing here is per-keystroke.
    def subtab_search_rows : Array(SubtabPicker::Row)
      subjects = filter_subjects
      extras = subtab_search_extras
      (subtab_labels || [] of String).map_with_index do |label, i|
        # Drop the leading "N:" — the picker draws the index in a column of its own, so the
        # label would otherwise read "3   3:login".
        num_end, _ = Chrome.chip_zones(label)
        detail = (s = subjects[i]?) ? search_detail(s) : ""
        SubtabPicker::Row.new(i, label[num_end..], detail, extras[i]? || "")
      end
    end

    # Per-session text the picker SEARCHES but never draws — request/template content
    # (Repeater wire text, Fuzzer templates), parallel to subtab_labels by index. Kept out
    # of `detail` because that column is drawn: 200 columns of header soup would bury the
    # request line it exists to show. Default empty — most tabs have nothing beyond their
    # filter_subjects projection. Overrides cap each entry with `search_extra`.
    def subtab_search_extras : Array(String)
      [] of String
    end

    protected def search_extra(text : String) : String
      text[0, SEARCH_EXTRA_MAX]
    end

    # Bytes variant (captured requests: Miner/Sequencer). Cap the SLICE before building the
    # String so a multi-MiB capture never allocates in full just to be truncated — and so an
    # invalid-UTF-8 body (a real capture holds them) is scrubbed over 2KB, not megabytes.
    protected def search_extra(bytes : Bytes) : String
      String.new(bytes[0, {bytes.size, SEARCH_EXTRA_MAX}.min])
    end

    # One searchable line for a session: what it does, where it goes, and how it is tagged.
    protected def search_detail(subject : Repeater::SubtabFilter::Subject) : String
      tags = subject.tags.map { |t| "##{t}" }.join(' ')
      "#{subject.summary} #{subject.target} #{tags}".squeeze(' ').strip[0, SEARCH_DETAIL_MAX]
    end

    # Open sub-tab count — gates the search entry. Derived from the strip labels.
    def subtab_count : Int32
      subtab_labels.try(&.size) || 0
    end

    # Absolute chip indices hidden by the active sub-tab filter; nil = show all (also nil
    # for tabs that don't opt into filtering). Rendering + click hit-tests skip these, but
    # the indices stay absolute so jump/rename/^N keep working unchanged.
    def subtab_hidden : Set(Int32)?
      return nil unless subtab_filter_enabled?
      return nil if @subtab_filter.blank?
      f = Repeater::SubtabFilter.parse(@subtab_filter)
      subjects = filter_subjects
      hidden = Set(Int32).new
      subjects.each_with_index { |s, i| hidden << i unless f.matches?(s) }
      hidden
    end

    # Absolute indices of the sub-tabs the filter keeps visible (all when unfiltered).
    def visible_indices : Array(Int32)
      h = subtab_hidden
      return (0...subtab_count).to_a unless h
      (0...subtab_count).reject { |i| h.includes?(i) }
    end

    # ===== sub-tab multi-select (issue #683) ==================================
    # The one opt-in: the object that IS sub-tab `idx`. nil (the default) means this strip
    # has no marks. Eight session tabs answer it with their existing `view_at`; Notes with
    # `NotesView#note_at`. Fixed strips (Help/Probe/Target/OAST) and the self-drawn Project
    # strip never override it, so they are excluded STRUCTURALLY rather than by a flag they
    # would each have to remember to set false — the same shape `subtab_find_shown?` uses.
    def subtab_ref(idx : Int32) : SubtabRef?
      nil
    end

    # Whether this strip marks at all. Derived from the opt-in above (plus the two strip
    # kinds that must never mark), so there is no second predicate to keep in sync.
    def subtab_marks_enabled? : Bool
      return false if subtabs_fixed? || subtab_strip_self_drawn?
      subtab_count > 0 && !subtab_ref(0).nil?
    end

    # Every open sub-tab's ref, in chip order (the live set the marks are measured against).
    private def subtab_refs : Array(SubtabRef)
      collect_subtab_refs(0...subtab_count)
    end

    # `compact_map` would infer the CONCRETE view type here (Array(RepeaterView)), which no
    # longer satisfies the declared Array(SubtabRef); build the array at the declared type.
    private def collect_subtab_refs(idxs : Enumerable(Int32)) : Array(SubtabRef)
      refs = [] of SubtabRef
      idxs.each do |i|
        if r = subtab_ref(i)
          refs << r
        end
      end
      refs
    end

    # Marked chips, as ABSOLUTE indices in chip order. Everything user-facing is derived
    # from this rather than from the mark set's own size: a session another instance closed
    # is gone from the strip the same frame, and a count that still included it would put a
    # number in the space menu that no chip on screen backs up.
    def marked_subtab_indices : Array(Int32)
      return [] of Int32 if @subtab_marks.empty?
      @subtab_marks.retain(subtab_refs) # housekeeping: drop closed sessions, release their pins
      (0...subtab_count).select { |i| (r = subtab_ref(i)) && @subtab_marks.marked?(r) }
    end

    def subtab_mark_count : Int32
      marked_subtab_indices.size
    end

    # Marked chips as a set, for the strip renderer's per-chip test. nil = none marked,
    # matching `subtab_hidden` beside it — the render path is per-frame, and the common
    # case (no marks) should not allocate a set to say so.
    def marked_chip_set : Set(Int32)?
      idxs = marked_subtab_indices
      idxs.empty? ? nil : idxs.to_set
    end

    # Marks the `/` filter is currently hiding. A batch confirm has to say this out loud:
    # "close 5 sub-tabs" over a filtered strip can reach two chips that are not on screen,
    # which is exactly the split ProjectPicker's delete confirm spells out for its own marks.
    def hidden_marked_count : Int32
      return 0 if @subtab_marks.empty?
      marked = marked_subtab_indices
      return 0 if marked.empty?
      vis = visible_indices.to_set
      marked.count { |i| !vis.includes?(i) }
    end

    # THE target rule, and the only one: the marks if any are set, else the active chip.
    # Every sub-tab-level action reads this — close, send, duplicate, tag — so marks widen
    # what the existing verbs TARGET instead of growing a second set of batch verbs beside
    # them (the shape spec/verbs/registry_sweep_spec.cr pins). A handler that opens a
    # confirm takes `batch_subtab_refs` below instead — the same marks, as objects.
    def target_subtab_indices : Array(Int32)
      marked = marked_subtab_indices
      marked.empty? ? [subtab_index] : marked
    end

    # `t` on the strip — flip the chip's mark. No-op on a strip without identity.
    def toggle_subtab_mark(idx : Int32) : Nil
      return unless ref = subtab_ref(idx)
      @subtab_marks.toggle(ref)
    end

    # `⇧T` — mark every chip the filter leaves on screen (see SubtabMarks#mark_all for why
    # this accumulates across two different queries rather than replacing).
    def mark_all_subtabs : Nil
      return unless subtab_marks_enabled?
      @subtab_marks.mark_all(collect_subtab_refs(visible_indices))
    end

    def clear_subtab_marks : Nil
      @subtab_marks.clear
    end

    # Hand back the marks a batch just acted on. Called with the refs the handler captured
    # BEFORE it ran, because some closes keep their view object alive (Comparer resets its
    # last session in place), and `retain` cannot tell that apart from a session still open.
    def unmark_subtab_refs(refs : Enumerable(SubtabRef)) : Nil
      @subtab_marks.unmark(refs)
    end

    # The chips a BATCH arm acts on, as view objects captured NOW — or nil when nothing is
    # marked and the gesture takes its single-target path on the active chip. Every close /
    # send / duplicate handler branches on this and nothing else.
    #
    # Refs and not indices, because a handler holds them across a confirm: `Runner#confirm`
    # runs the action from `on_close`, one event-loop turn later at the earliest, and the
    # data_version poll has no modal guard — a peer (MCP, `gori run`, a second TUI) can
    # reorder or delete a session behind the dialog, and `reconcile` re-sorts the strip. An
    # index captured before the dialog then names a different session after it; a view object
    # cannot. `close_marked_subtabs` resolves them back to indices at the moment it closes.
    #
    # ONE mark is a batch too. Testing `targets.size > 1` (the old shape) fell through to the
    # active chip whenever exactly one chip was marked, and that is the default state after a
    # single `t`: it marks the chip and steps RIGHT, so the mark and the cursor sit on
    # different chips. `^W` then confirmed "Close repeater 4", the unmarked one, while the
    # strip said `1 marked` and the space menu said `Close 1 sub-tab` — and `space ▸ d`, which
    # read `target_views`, duplicated the marked chip. Same tab, same marks, two targets.
    def batch_subtab_refs : Array(SubtabRef)?
      idxs = marked_subtab_indices
      idxs.empty? ? nil : collect_subtab_refs(idxs)
    end

    # The chip `ref` sits on RIGHT NOW, or nil when a peer closed it. Identity, never `==`:
    # the mark set keys on `object_id` for the reason `SubtabMarks` states.
    def subtab_index_of(ref : SubtabRef) : Int32?
      (0...subtab_count).find { |i| (r = subtab_ref(i)) && r.same?(ref) }
    end

    # The refs still on the strip, as the indices they hold now (chip order).
    private def resolve_subtab_refs(refs : Enumerable(SubtabRef)) : Array(Int32)
      idxs = [] of Int32
      refs.each do |ref|
        if i = subtab_index_of(ref)
          idxs << i
        end
      end
      idxs.sort!
    end

    # The count phrase a bulk sub-tab confirm uses. The filter split is not decoration: `⇧T`
    # marks what the `/` query shows, then narrowing the query again leaves those marks in
    # place, so "close 5 sub-tabs" can reach two chips that are not on screen. The project
    # picker's delete confirm spells the same split out for the same reason.
    protected def marked_subtab_phrase(n : Int32) : String
      base = "#{n} sub-tab#{n == 1 ? "" : "s"}"
      hidden = hidden_marked_count
      hidden > 0 ? "#{base} (#{hidden} not on screen — the filter is hiding them)" : base
    end

    # The batch half of a DUPLICATE gesture: clone every marked chip and say one thing.
    # Capped (it opens a sub-tab per item, which is what `BATCH_SUBTAB_CAP` exists for) but
    # deliberately not confirm-gated — the confirms on these strips guard what is destructive
    # or outbound, and a duplicate only opens tabs the same `^W` closes again. Ascending, so
    # the clones land in the order their originals sit in.
    #
    # Returns the sentence, or nil when the batch was refused (the caller says why).
    protected def duplicate_marked_subtabs(refs : Array(SubtabRef), noun : String, & : Int32 -> Nil) : String?
      idxs = resolve_subtab_refs(refs)
      return nil if idxs.size > Tui::Runner::BATCH_SUBTAB_CAP
      idxs.each { |i| yield i }
      "duplicated #{idxs.size} #{noun}#{idxs.size == 1 ? "" : "s"}"
    end

    # Why sub-tab `idx` cannot be closed right now, or nil. Only the Fuzzer has one today (a
    # run or a result spool still writing); every other strip always closes.
    def close_subtab_refusal(idx : Int32) : String?
      nil
    end

    # Close sub-tab `idx` and say NOTHING — the batch driver below owns the sentence, and a
    # loop of per-tab toasts would leave only the last one on screen anyway. Returns true
    # when the store rolled the DELETE back and the saved session will reappear.
    protected def close_subtab_at(idx : Int32) : Bool
      false
    end

    # The batch half of a close gesture (#683). Three rules, each one a defect if dropped:
    #
    #   * HIGH index → low, so a `delete_at` can never shift a target not yet reached.
    #   * a refusal is reported and the loop CONTINUES (#442 Q4: a partial failure reports,
    #     it never aborts the rest) — and a refused sub-tab keeps its mark, so the retry is
    #     still assembled.
    #   * the marks that DID close are handed back explicitly. `SubtabMarks#retain` cannot
    #     do it: `ComparerController#comparer_close` resets its last session in place rather
    #     than deleting it, so that view — and its mark — outlives the close the operator
    #     just watched.
    #
    # Takes the refs the handler captured before its confirm (`batch_subtab_refs`) and maps
    # them to indices HERE, after the dialog: a chip a peer closed in the meantime simply
    # resolves to nothing, and a reordered one to where it is now.
    protected def close_marked_subtabs(refs : Array(SubtabRef)) : String
      gone = [] of SubtabRef
      orphaned = 0
      refusal = nil.as(String?)
      refused = 0
      resolve_subtab_refs(refs).reverse_each do |i|
        if reason = close_subtab_refusal(i)
          refusal ||= reason
          refused += 1
          next
        end
        ref = subtab_ref(i)
        orphaned += 1 if close_subtab_at(i)
        gone << ref if ref
      end
      unmark_subtab_refs(gone)
      msg = "closed #{gone.size} sub-tab#{gone.size == 1 ? "" : "s"}"
      msg += " · #{refused} kept (#{refusal})" if refusal
      TabClose.message(msg, orphaned > 0)
    end

    # ===== end sub-tab multi-select ==========================================

    # The sub-tab strip always carves its own hairline under the chip row. When a filter
    # bar is also shown it draws a SECOND hairline below itself, so the chrome reads
    # chips › ─── › filter › ─── › body (matching Target/Sitemap) instead of gluing the
    # chips straight onto the filter. Render (framed_body), body geometry
    # (body_rect_below_filter), and the Runner's strip hit-tests all read this one flag,
    # so they stay in sync.
    def subtab_strip_divider? : Bool
      true
    end

    # ===== sub-tab filter subsystem (issue #121) =============================
    # Opt-in switch: this tab supports the `/` sub-tab filter bar. Default off — History,
    # Help, … never show it. The five workbench tabs + Repeater override to true.
    def subtab_filter_enabled? : Bool
      false
    end

    # The searchable projection of each sub-tab, in chip order (one Subject per label).
    # The matcher + Tab suggestions run over these. Default empty (nothing to filter).
    def filter_subjects : Array(Repeater::SubtabFilter::Subject)
      [] of Repeater::SubtabFilter::Subject
    end

    # The field names this tab advertises in the filter bar guidance/hint rows (and the
    # only fields Tab-completes). HTTP tabs override to name/host/method; Repeater adds tag.
    def filter_fields : Array(String)
      %w[name]
    end

    # The filter bar occupies a body row whenever there are ≥2 sub-tabs to filter (below
    # that there is nothing to narrow). Repeater overrides to show it from the first
    # session (its own History-style discoverability row).
    def subtab_filter_shown? : Bool
      subtab_filter_enabled? && subtab_count >= 2
    end

    # The `/` bar is currently capturing keystrokes (the shell routes keys here).
    def subtab_filter_editing? : Bool
      @subtab_filter_editing
    end

    # True at a cold start (nothing typed, or the caret sits just after a space) — decides
    # whether the suggestion row shows the standing field hint.
    private def filter_token_empty? : Bool
      FilterAst.token_at(@subtab_filter, @filter_cx).core.empty?
    end

    # Open the `/` filter bar (from the strip or the space menu), seeding the caret.
    def start_subtab_filter : Nil
      return unless subtab_filter_enabled?
      @subtab_filter_editing = true
      @filter_cx = @subtab_filter.size
      @filter_preedit = ""
    end

    # Enter: keep the (possibly blank) filter and leave edit mode; re-anchor the current
    # session onto a still-visible chip so the body matches the narrowed strip.
    def commit_subtab_filter : Nil
      @subtab_filter_editing = false
      @filter_preedit = ""
      reanchor_current
    end

    # Esc: drop the filter entirely and leave edit mode (every chip returns).
    def clear_subtab_filter : Nil
      @subtab_filter = ""
      @subtab_filter_editing = false
      @filter_cx = 0
      @filter_preedit = ""
    end

    def set_subtab_filter_preedit(text : String) : Nil
      @filter_preedit = text
    end

    def handle_subtab_filter_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if key.escape?
        clear_subtab_filter
      elsif key.enter?
        commit_subtab_filter
      elsif key.tab?
        complete_subtab_filter # History-style Tab: first suggestion for the token
      elsif key.backspace?
        if @filter_cx > 0
          @subtab_filter = @subtab_filter[0, @filter_cx - 1] + @subtab_filter[@filter_cx..]
          @filter_cx -= 1
        end
        @filter_preedit = ""
      elsif key.left?
        @filter_cx = {@filter_cx - 1, 0}.max
      elsif key.right?
        @filter_cx = {@filter_cx + 1, @subtab_filter.size}.min
      elsif c && !ev.ctrl? && !ev.alt? && !c.control?
        @subtab_filter = @subtab_filter[0, @filter_cx] + c + @subtab_filter[@filter_cx..]
        @filter_cx += 1
        @filter_preedit = ""
      end
    end

    def filter_suggestions : Array(String)
      return [] of String unless @subtab_filter_editing
      Repeater::SubtabFilter.suggestions(@subtab_filter, @filter_cx, filter_subjects, filter_fields)
    end

    # Replace the token under the caret with the first suggestion (History query_complete).
    def complete_subtab_filter : Bool
      sugg = filter_suggestions
      return false if sugg.empty?
      cur = FilterAst.token_at(@subtab_filter, @filter_cx)
      first = sugg.first
      @subtab_filter = "#{@subtab_filter[0, cur.start]}#{first}#{@subtab_filter[cur.stop..]}"
      @filter_cx = cur.start + first.size
      @filter_preedit = ""
      true
    end

    # Keep the current session on a visible chip: if the filter hid it, jump to the first
    # still-visible session (jump_subtab saves the outgoing session as each tab requires).
    private def reanchor_current : Nil
      return unless subtab_filter_enabled?
      vis = visible_indices
      return if vis.empty? || vis.includes?(subtab_index)
      jump_subtab(vis.first)
    end

    # The next VISIBLE absolute index stepping `dir` from `current` (filter-aware strip
    # nav), or nil when there is nowhere to move. Controllers use this in move_subtab so
    # ←/→ skip hidden chips. A current index that was filtered out steps onto an edge.
    protected def step_visible(current : Int32, dir : Int32) : Int32?
      vis = visible_indices
      return nil if vis.size < 2
      cur = vis.index(current)
      target = cur ? vis[(cur + dir).clamp(0, vis.size - 1)] : (dir < 0 ? vis.first : vis.last)
      target == current ? nil : target
    end

    # --- QL filter bar: the "show me the reference" key -----------------------
    # `?` on an EMPTY query bar opens the QL reference popup instead of typing a `?`.
    #
    # `?` and not a Ctrl chord, for three reasons. It is ALREADY the app's help key
    # (`tab.help`), and every text sub-mode — these three bars included — swallowed it, so
    # this makes an existing gesture stop being dead in the one place people go looking for
    # QL syntax. It costs no `Hotkeys::CLAIMED_CTRL_LETTERS` entry and cannot shadow a
    # rebind. And the alternatives lose: there is no free Ctrl+letter to take — every a–z is
    # claimed between the verb chords, `Hotkeys::CLAIMED_CTRL_LETTERS` and `verb/reserved.cr`
    # — `Ctrl+Space` collides with the Hangul/IME toggle this bar has preedit handling for,
    # and F1 is inexpressible as a `Verb::Chord` (`NAMED_KEYS` has no function keys), so it
    # could never be advertised or rebound.
    #
    # EMPTY buffer only, not "after whitespace": `?id=` is a plausible free-text search on a
    # proxy, and a key whose trigger state the operator cannot see is worse than one that
    # only fires from a visibly empty bar. The single query this displaces is a bare leading
    # `?`, which compiles to free text (`LIKE '%?%'` over method/host/target) — "every flow
    # with a query string", which nobody types deliberately. `path:?` and `url:?` are
    # untouched.
    #
    # Shared here rather than written into the three `handle_query_key`s, which are otherwise
    # byte-for-byte parallel: a predicate in one place is a class that cannot be half-fixed.
    # A CLASS method so a spec can drive it without a Host — controllers need the Runner, which
    # needs a live tty, so an instance-level predicate would be reachable only through the TUI.
    def self.ql_help_key?(ev : Termisu::Event::Key, query : String) : Bool
      return false unless query.empty?
      return false if ev.ctrl? || ev.alt?
      (ev.char || ev.key.to_char) == '?'
    end

    # --- filter bar rendering (shared by every opt-in tab's render_body) ---
    # Base height: guidance/input row + hairline (the bar owns the strip divider). While
    # editing, an optional suggestion row sits between the input and the hairline.
    FILTER_BAR_H = 2

    # Cold-start hint (nothing typed) — spells out the tab's advertised fields + that bare
    # words are a free-text search, so the language is discoverable the moment `/` opens.
    private def filter_edit_hint : String
      "fields:  #{filter_fields.map { |f| "#{f}:" }.join("  ")}    ·    or type words to search"
    end

    # Opt-in tabs call this inside their framed_body block: carve the filter bar off the
    # content top, draw it, and yield the body rect below (unchanged content when no bar).
    protected def render_with_filter(screen : Screen, content : Rect, subtabs_focused : Bool, & : Rect ->) : Nil
      bar, body = carve_filter_bar(content)
      render_subtab_filter_bar(screen, bar, subtabs_focused: subtabs_focused) if bar
      yield body
    end

    # The body rect below the sub-tab strip AND the filter bar — shared by render + click
    # hit-tests so body clicks land where the body is actually drawn.
    protected def body_rect_below_filter(rect : Rect) : Rect
      content = BodyChrome.content_rect(rect, strip: subtab_strip_shown?, strip_divider: subtab_strip_divider?)
      carve_filter_bar(content)[1]
    end

    # Filter (+ optional suggestion row) + hairline carved off the body top. Height is
    # FILTER_BAR_H idle/active, +1 while editing when there are Tab suggestions/a hint.
    private def carve_filter_bar(content : Rect) : {Rect?, Rect}
      return {nil, content} unless subtab_filter_shown? && content.h > 0
      h = filter_bar_height
      h = {h, content.h}.min
      bar = Rect.new(content.x, content.y, content.w, h)
      body = content.h > h ? Rect.new(content.x, content.y + h, content.w, content.h - h) : Rect.new(content.x, content.y + h, content.w, 0)
      {bar, body}
    end

    private def filter_bar_height : Int32
      base = FILTER_BAR_H
      return base unless @subtab_filter_editing
      # Reserve the extra row for the suggestion/hint line: live ↹ completions, OR the
      # cold-start field hint shown while the token is empty. A non-empty token with no
      # completions keeps the compact height (nothing to show there).
      (!filter_suggestions.empty? || filter_token_empty?) ? base + 1 : base
    end

    # History-style 3-state bar, sitting under the chips + their own hairline, with its
    # own hairline drawn BELOW it (chips ─── filter ─── body, matching Target/Sitemap):
    #   editing  → `filter › <input>` [+ `↹ name:…` suggestions]
    #   active   → `: <query>`
    #   idle     → `/ filter  ·  name:  host:  method:` (this tab's advertised fields)
    # Right side always shows visible/total chip counts.
    private def render_subtab_filter_bar(screen : Screen, rect : Rect, *, subtabs_focused : Bool) : Nil
      return if rect.w < 8 || rect.h < 1
      row_y = rect.y
      screen.fill(Rect.new(rect.x, row_y, rect.w, 1), Theme.panel)
      vis = visible_indices.size
      count = "#{vis}/#{subtab_count}"
      count_x = rect.right - count.size
      left_w = {count_x - 1 - rect.x, 1}.max
      if @subtab_filter_editing
        px = screen.text(rect.x, row_y, "filter › ", Theme.accent, Theme.panel)
        field_w = {count_x - 1 - px, 1}.max
        screen.input_line(px, row_y, @subtab_filter, @filter_cx, @filter_preedit,
          Theme.text_bright, Theme.panel, width: field_w,
          colors: Highlight.filter_query(@subtab_filter, Theme.text_bright, FilterAst::SEPS_FIELD))
      elsif !@subtab_filter.blank?
        px = screen.text(rect.x, row_y, ": ", Theme.muted, Theme.panel, width: left_w)
        screen.styled_text(px, row_y, @subtab_filter,
          Highlight.filter_query(@subtab_filter, Theme.text, FilterAst::SEPS_FIELD),
          Theme.text, Theme.panel, width: {count_x - 1 - px, 0}.max)
      else
        screen.text(rect.x, row_y, "/ filter  ·  #{filter_fields.map { |f| "#{f}:" }.join("  ")}", Theme.muted, Theme.panel, width: left_w)
      end
      screen.text(count_x, row_y, count, vis == 0 ? Theme.red : Theme.muted, Theme.panel)

      div_y = row_y + 1
      if @subtab_filter_editing && rect.h >= 3
        sugg = filter_suggestions
        # Live completions to Tab through, else (at a cold start) the standing hint so the
        # row isn't blank the instant `/` opens; a non-empty no-match token stays quiet.
        hint = !sugg.empty? ? "↹ #{sugg.first(8).join("  ")}" : (filter_edit_hint if filter_token_empty?)
        if hint
          screen.fill(Rect.new(rect.x, row_y + 1, rect.w, 1), Theme.panel)
          screen.text(rect.x, row_y + 1, hint, Theme.muted, Theme.panel, width: rect.w)
          div_y = row_y + 2
        end
      end
      return if div_y >= rect.y + rect.h
      border = subtabs_focused ? Theme.focus_gold : Theme.border
      screen.hline(rect.x, div_y, rect.w, fg: border, bg: Theme.bg)
    end

    # ===== end sub-tab filter subsystem =====================================

    # A FIXED strip (Help): the chip set is constant — no ^N/^W create/close and the
    # body is read-only. The shell drops "new/close/edit" from the strip hint for it.
    def subtabs_fixed? : Bool
      false
    end

    # --- status bar ---
    def body_badge : Symbol # :editor (captures text) | :body (navigable/read-only)
      :body
    end

    def body_hint(focus : Symbol) : String
      ""
    end

    # A hint with its chords spelled as `{verb.id}` tokens, resolved through the effective
    # keymap (Hotkeys.expand) — the strip names the verb and the keymap says which key, so a
    # rebind reaches every strip written this way. Keys that are NOT verbs (↑/↓, esc, the
    # claimed ^P/^N/^W family, a pane-local `x`) stay literal.
    protected def keys(template : String) : String
      Hotkeys.expand(@host.session.registry, template)
    end

    # Whether `ev` is a chord the effective keymap binds to verb `id` — for a pane that
    # dispatches a key ITSELF, with no verb of its own, while its hint strip names another
    # verb's chord for it. The Rewriter's extract sub-tab says `{rewriter.add} add` and the
    # Colormarker's colours pane says `{colormarker.add} add`: both strips followed a rebind
    # the moment `keys` did, and both handlers kept matching the literal `'a'`, so after
    # binding "Add rule" to `n` the strip said `n add` and `n` did nothing there while `a`,
    # which the strip no longer named, still did.
    #
    # Resolved the way `Hotkeys.expand` resolves the token the strip prints: the user's
    # override, else the OS profile, else the verb's declared chords — and, for an id the
    # operator has UNBOUND, the declared default, because that is what the strip falls back
    # to naming. The event goes through `Keybind.from_event`, the same encoding the keymap
    # dispatch uses, so a typed uppercase letter and ⇧+letter agree here as they do there.
    protected def chord_of?(ev : Termisu::Event::Key, id : String) : Bool
      return false unless chord = Keybind.from_event(ev)
      registry = @host.session.registry
      return false unless verb = registry[id]?
      os = Verb::OsProfile.resolve(Settings.keymap_os)
      chords = Verb::Keymap.effective_chords(verb, os, Hotkeys.rebindable_overrides(registry))
      chords = Verb::Keymap.effective_chords(verb, os) if chords.empty?
      chords.includes?(chord)
    end

    # --- orthogonal ^G/^F prompts: the symbol naming the currently-focused
    # searchable pane (e.g. :repeater_request, :notes), or nil if none. The shell's
    # goto/search prompt dispatches on this symbol. A future cleanup could return a
    # richer Searchable object to also fold the shell's per-symbol jump/search
    # dispatch into the controller. ---
    def goto_symbol : Symbol?
      nil
    end

    # --- editor autocomplete + tab-as-text (opt-in; default off) -------------
    # An `$ENV` completion popup is open in the focused editor → it owns Tab/↵/↑/↓/Esc,
    # claimed BEFORE the global focus ring so Tab accepts the suggestion instead of moving
    # focus. Return true from handle_editor_complete_key when the key was consumed; false
    # falls through so normal editing continues and the popup refilters.
    def editor_completing? : Bool
      false
    end

    def handle_editor_complete_key(ev : Termisu::Event::Key) : Bool
      false
    end

    # The focused pane is an actively-editing text editor → forward Tab types a tab (real
    # editor feel) rather than advancing the focus ring. Shift-Tab still steps focus back,
    # so there is always a keyboard way out of the pane.
    def editor_captures_tab? : Bool
      false
    end

    def handle_editor_tab(ev : Termisu::Event::Key) : Bool
      false
    end

    # --- focus ring (Tab/Shift-Tab across panes); false = no further pane ---
    def pane_advance(dir : Int32) : Bool
      false
    end

    def focus_first : Nil
    end

    def focus_last : Nil
    end

    # The body is re-entered from OUTSIDE the focus ring — ↓/↵ off the tab bar, a "Go to …"
    # jump, a [ ] cycle while already in the body, the sub-tab strip's ↓. Keep the pane the
    # view already holds: `focus_first`/`focus_last` stay the Tab-ring entries (they name an
    # END of the ring), and this is the "come back to where I was" entry. The default is a
    # no-op because every multi-pane view initialises its pane to the first one, so a first
    # visit lands there with no help. Override only for a side effect that must ALSO run on
    # a resume — a popup to close, a sub-field to exit — never to move the pane.
    def focus_resume : Nil
    end

    # --- lifecycle ---
    def on_enter : Nil # tab became active — refresh derived data
    end

    def on_external_change : Nil # another connection committed to the project DB
    end

    def commit : Nil # flush any in-progress edit before leave/quit
    end

    def locked? : Bool # a destructive op is gated (e.g. last note can't close)
      false
    end

    # Focus a specific session/sub-tab by its persisted id (notification "jump to
    # result"). Default no-op; Repeater/Fuzzer/Miner controllers override to reveal the row.
    def reveal_session(id : Int64) : Nil
    end
  end
end
