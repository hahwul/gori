require "termisu"
require "./screen"
require "./geometry"
require "./text_field"
require "./theme"
require "./frame"

module Gori::Tui
  # Every modal state the shell's `@overlay` can hold. This was a bare `Symbol` with 33
  # values compared ~96 times across runner.cr, where one mistyped `:probe_rules` was a
  # silent no-op — an overlay that never opened, never rendered and never captured a key,
  # with no compiler help. As an enum the same typo is a compile error.
  #
  # Members keep the names the symbols had, so the mapping stays obvious: `ProbeRule` is the
  # Probe custom-rule editor and `Tabs` the tab-bar customizer. `None` is "no modal"; `Detail`
  # is the History drill-in, which is NOT a capturing modal (see Runner#modal_overlay?).
  #
  # `to_sym`/`from_sym` bridge the still-`Symbol` Host facade (TabController's
  # `request_overlay` / `overlay` / `confirm(return_to:)`). Both are TOTAL: `to_sym` is an
  # exhaustive `case … in`, so adding a member here fails to compile until it is mapped, and
  # `from_sym` raises rather than silently landing on `None` — a bad symbol at that seam must
  # be loud, since silence is the exact failure mode the enum exists to kill.
  enum OverlayKind
    None
    Detail
    Palette
    IssueNew
    Confirm
    Browser
    Choice
    # The `0` key's Go-to picker (TabGotoPicker) — the type-to-filter list over the whole tab
    # catalog that replaced the ⋯ dropdown's `TabsMore`.
    TabGoto
    ComparerPick
    RepeaterSubtab
    Links
    LinkPick
    Preferences
    Settings
    Tabs
    Hosts
    Env
    UserAgents
    Hotkeys
    # Help's cheat-sheet / QL reference as a popup over the current pane (HelpPopupOverlay).
    # ONE member for both pages: they never coexist, and an overlay's `title` is per instance.
    Help
    Notifications
    # One notification's long form (#1090), opened with ↵ on a ring row that carries a detail.
    NoteDetail
    Passthrough
    Listeners
    # The MCP clients bound to this project (#815), opened from the `mcp:` top-bar chip or the
    # app.agents palette entry. Read-only, like Listeners — the rows are gori mcp processes,
    # not anything the TUI edits.
    Agents
    ProbeActive
    DiscoverConfig
    DiscoverHeaders
    FuzzSet
    FuzzAdvanced
    OastProvider
    OastProviderPick
    OastSession
    ProbeRule
    RewriterRule
    ColormarkerRule
    ColormarkerColor
    ExtractRule
    RewriterStub
    # The answer options of a short-circuit rule (#1237) — a sub-editor of the rule form, like
    # RewriterStub.
    RewriterRespond
    # The Authorize tab's identities: a LIST card (pick / reorder the baseline / delete) and
    # the per-identity FORM it hands off to. Two members, because the list stays the thing the
    # form returns to — see Runner#open_authorize_identities.
    AuthorizeIdentities
    AuthorizeIdentity
    CaImport
    Import
    # The curl paste box (#1244) — one member for both of its destinations (a Repeater sub-tab,
    # History), for the reason `Help` gives: they never coexist, and the title is per instance.
    CurlPaste
    Export
    ScopeRule
    SequenceConfig
    MineConfig
    # The two halves of a named GLOBAL library (settings.json), shared by the Decoder's
    # chain specs and the Rewriter's rule presets: NamePromptOverlay writes, LibraryPicker
    # reads. One pair rather than four kinds — the modal is the same in both tabs, only
    # its rows and its injected on_commit differ.
    NamePrompt
    # The History tab's user-defined columns (#819): a LIST card (pick / reorder / delete) and
    # the per-column FORM it hands off to. Two members, for the reason AuthorizeIdentities gives
    # — the list stays the thing the form returns to.
    Columns
    Column
    LibraryPick
    CvssCalculator
    # Prompt-tier pickers. These two name a modal that `@overlay` NEVER holds: copy-as
    # and send-to float over whatever is underneath (a tab body OR the History detail
    # drill-in) without disturbing it, and are claimed before the ^G/^F/^B guards, so the
    # Runner keeps them in their own slots (see Runner#copy_as_shown?). They are members
    # anyway because `Overlay#key` is how a modal names itself, and a picker on the seam
    # must answer it honestly rather than borrow `None`.
    CopyAs
    SendTo
    # The read-only viewer for one frozen issue-evidence row (#1038): the request and
    # response as they were copied, over the Issues detail they were opened from. A modal
    # rather than the History drill-in, because the drill-in's verbs act on a LIVE flow id
    # (delete, link, probe) and a snapshot has none — and because closing a modal lands the
    # operator back on the RELATED row they came from, tab and cursor intact.
    Evidence
    # An Issue's retest (#1036): the ordered Repeater steps and the last run's result table,
    # in one card over the Issues detail. A modal for the reason `RetestOverlay` gives — the
    # detail's row budget is already clamped, and a retest is a thing you open, not a pane
    # every issue pays for.
    Retest
    # The one expected result a retest step carries. Its own card rather than
    # `NamePromptOverlay` because the accepted forms have to be readable WHILE it is typed —
    # see `RetestAssertOverlay`.
    RetestAssert
    # The differential-timing verdict card (#1246), opened when the repeater.timing-analysis
    # fiber finishes: a read-only report over marked Repeater sub-tabs.
    TimingReport
    # An agent's `ask_operator` question (#1324): its choices on digit keys, opened by the
    # operator from the ring, the `ask:` chip or app.answer-agent — never by the question.
    AgentQuestion
    # Preferences → Keys → Keyset playground: the practice pad plus each keyset's key
    # list, born on the seam.
    KeysetPlayground

    def to_sym : Symbol
      {% begin %}
        case self
        {% for c in @type.constants %}
        in OverlayKind::{{ c }} then :{{ c.stringify.underscore.id }}
        {% end %}
        end
      {% end %}
    end

    # `Enum.parse?` already matches on the underscored member name and already answers nil
    # on an unknown one, so this is just its raising wrapper — no second hand-rolled name
    # table to drift out of step with the member list. Only `to_sym` needs a macro, because
    # Symbol literals cannot be built at runtime.
    def self.from_sym(sym : Symbol) : OverlayKind
      parse?(sym.to_s) || raise ArgumentError.new("unknown overlay kind: #{sym}")
    end
  end

  # A centered modal overlay the shell floats above the tab body. The Runner owns ONE
  # active overlay (`@active_overlay`) and dispatches to it polymorphically — the same
  # move TabController made for tab bodies, now extended to modals.
  #
  # Before this seam, every modal scattered ~13 `case @overlay` entries through the
  # Runner (key / click / wheel / preedit / render / title / hint routing + open/close/
  # commit glue). That central fan-out was the merge-conflict surface: touching any one
  # modal meant editing a dozen shared methods 5,000 lines apart. An `Overlay` collapses
  # all of that into the hooks below, so ADDING or editing a modal touches only its own
  # file plus one open-site — never the Runner's central dispatch. Two overlays never
  # share an edit surface in runner.cr. That is the parallel-work win.
  #
  # Concrete overlays stay dumb form objects (their own field/caret state). Behaviour
  # that couples to a domain controller is injected as the `on_commit` closure at the
  # open-site — mirroring ConfirmDialog's action proc. A modal opened from two sites with
  # different apply semantics (e.g. Sequencer new-vs-reconfigure) therefore needs no
  # shell-side flag: each site supplies its own closure.
  #
  # Outcome vocabulary (returned by handle_key / handle_click), the contract the Runner's
  # generic dispatch switches on:
  #   :stay   → stay open, redraw
  #   :commit → run `commit`; the shell closes the overlay iff `commit` returns true
  #   :cancel → close without committing
  abstract class Overlay
    # The card geometry every ADD/EDIT-one-policy-rule form shares: Rewriter, Colormarker,
    # Probe custom, extract, Scope, OAST provider. They are the same kind of thing reached from
    # adjacent tabs, so opening two in a row must not resize the card under the operator — and
    # it did: the six had settled on 72, 72, 62, 72, 52 and 56, with floors ranging from 28×8
    # to 40×13, none of it derived from anything.
    #
    # 72 is the widest of them and the one three already used; it is what the Rewriter form
    # needed once a fifth op pushed its option row past the old 66. The narrower cards were not
    # narrower for a reason — a `pattern:` row holding a host glob or a regex wants the width
    # as much as any of them.
    #
    # HEIGHT is not a constant, because it depends on how many rows a form has: each computes
    # `rows + 4`, or `rows + 5` when it carries a preview band under the rows. That formula is
    # the thing to keep, not a number — two forms had drifted off it (one hard-coded 11 for
    # four rows, one asked for `+ 6`) and simply drew dead space above their own bottom edge.
    RULE_FORM_W     = 72
    RULE_FORM_MIN_W = 40
    RULE_FORM_MIN_H = 10

    # The card rect for one of those forms, centered in `area`. `rows` is the form's row count;
    # `preview` adds the band some of them draw under the rows.
    #
    # The floor is `min(RULE_FORM_MIN_H, natural)`, not the constant — a card is never refused
    # for being SHORTER than the form needs. Writing the constant straight into the guard is a
    # mistake worth naming, because it fails silently in exactly one direction: the Scope form
    # is four rows, so its natural height is 8, and a flat floor of 10 meant `overlay_box`
    # returned nil at every terminal size and the form could not be opened at all.
    def self.rule_form_box(area : Rect, rows : Int32, preview : Bool = false) : Rect?
      natural = rows + (preview ? 5 : 4)
      w = {area.w - 4, RULE_FORM_W}.min
      h = {area.h - 2, natural}.min
      return nil if w < RULE_FORM_MIN_W || h < {RULE_FORM_MIN_H, natural}.min
      area.center(w, h)
    end

    # One `label: value` row of such a form: the label in muted, the field's text (or its
    # live IME composition spliced in at the caret) clipped to the card, and — when the row
    # is selected and nothing is composing — the block caret plus the terminal cursor.
    #
    # It lives on the base class for the same reason `rule_form_box` does. The six forms had
    # each carried a byte-identical private copy of this, caret arithmetic and all: five
    # matched to the byte and OastProvider's differed only in parameter order. Six copies of
    # one caret calculation is six chances for the forms to disagree about where the cursor
    # sits, and the drift is invisible until an operator opens two of them in a row.
    #
    # `vw`'s floor of 3 and the `px < box.right - 2` guard are what keep a long label or a
    # narrow card from drawing the value — or the cursor — past the card's right border.
    def draw_field(screen : Screen, box : Rect, py : Int32, bg : Color, fg : Color,
                   sel : Bool, label : String, field : TextField) : Nil
      x = box.x + 3
      vx = screen.text(x, py, label, Theme.muted, bg) + 1
      vw = {box.right - 2 - vx, 3}.max
      val = field.value
      pre = field.preedit
      shown = pre.empty? ? val : "#{val[0, field.caret]}#{pre}#{val[field.caret..]}"
      screen.text(vx, py, shown, fg, bg, width: vw)
      if sel && pre.empty?
        cx = field.caret.clamp(0, val.size)
        px = vx + Screen.draw_width(val[0, cx])
        if px < box.right - 2
          ch = cx < val.size ? val[cx] : ' '
          screen.cell(px, py, ch, Theme.bg, Theme.accent_bg)
          screen.cursor(px, py)
        end
      end
    end

    # Whether a keystroke that arrived INSIDE A BRACKETED PASTE may reach `handle_key`.
    #
    # A paste over a modal is delivered key by key (the bulk path is body-only), and every
    # pasted line break arrives as ↵. On a one-line form ↵ is COMMIT, so pasting
    # `/tmp/a.har⏎` submitted the import and typed whatever followed into the pane the shell
    # restored; on a confirm card a pasted `y` was an answer. The default lets text through
    # and holds back ↵: a one-line field takes the first line and the operator sees the rest
    # refused rather than acted on. A multi-line editor overrides to take ↵ as the newline
    # it is; the confirm card overrides to take nothing — a clipboard is not a decision.
    def takes_pasted?(ev : Termisu::Event::Key) : Bool
      !ev.key.enter?
    end

    # Whether a bracketed paste over this modal is collected and handed over whole
    # (`paste_text`) instead of arriving key by key — the tab tier's `accepts_bulk_paste?`,
    # one tier up. False by default: only a card whose body IS a multi-line editor opts in,
    # because only there do the two paths build the same buffer, and only there does the
    # per-keystroke cost (quadratic in the paste, `runner/paste.cr`) matter.
    def accepts_bulk_paste? : Bool
      false
    end

    # The whole paste, line breaks as `\n`. False hands it back to the Runner, which replays
    # it keystroke by keystroke.
    def paste_text(text : String) : Bool
      false
    end

    # Runs on a :commit outcome; returns true when the overlay should close (false keeps
    # it open — e.g. a validation error keeps the form up). Supplied at the open-site.
    property on_commit : Proc(Bool)?

    # What the shell runs AFTER this overlay closes, whether it committed or cancelled.
    #
    # This is the NESTED-MODAL seam. A modal opened FROM another supplies
    # `-> { open_overlay(parent) }` here, so closing pops back into the parent instead of
    # dropping the user on the bare tab body: ↵-ing into the Theme editor from Preferences
    # and pressing esc must land back in Preferences, not on the tab underneath. The shell
    # used to express exactly ONE such relationship, with a `@prefs_return` flag plus a
    # `settle_sub_editor` call at each dispatch chokepoint; as a per-overlay closure it
    # composes, so a modal can nest inside a modal that is itself nested.
    #
    # A proc rather than a parent reference, because the restore is not always just
    # "re-open the parent". Returning from the Hostnames editor has to re-pull the
    # Preferences modal's Network section first, whose "N entries" row that editor just
    # moved. A `return_to : Overlay?` cannot say that; a closure can.
    #
    # ORDERING, which is load-bearing: the shell drops the modal FIRST and runs this
    # after (see `Runner#close_active_overlay`), so a closure that calls `open_overlay` is
    # the last write and the shell really is holding the parent when it returns. An exit
    # that goes somewhere else entirely — ^P to the command palette — deliberately uses
    # `Runner#leave_overlay`, which skips this, so the pop-back can't re-open on top of
    # where the user asked to go.
    property on_close : Proc(Nil)?

    # Whether this modal was opened over the History drill-in, written by
    # `Runner#open_overlay`. The drill-in is an `@overlay` state too, so the modal replaces
    # it there; this is what keeps the flow drawn behind the card and puts the drill-in back
    # when the card closes, instead of both falling to the bare list (`Runner.detail_beneath?`).
    property? over_detail : Bool = false

    # The `@overlay` state this modal sets, written by `Runner#open_overlay`.
    #
    # It is NOT what makes the modal capture input: a migrated modal's member is deleted
    # from `Runner::MODAL_OVERLAYS`, and `modal_overlay?` answers for it through
    # `active_overlay` instead. `key`'s real job is the liveness token in that method's
    # `@overlay == ov.key` gate — ~40 sites reset `@overlay` directly without clearing
    # `@active_overlay`, and comparing against `key` is what makes such a reset render the
    # overlay inert rather than leaving a zombie that keeps drawing and capturing.
    abstract def key : OverlayKind

    # Shell chrome: the focus-badge title (top bar) and the bottom-row key hint. These
    # used to be `case @overlay` entries in the Runner; they now live with the overlay so
    # the ladders don't grow per modal.
    abstract def title : String
    abstract def hint : String

    # Draw the modal card within `area` (the body rect).
    abstract def render(screen : Screen, area : Rect) : Nil

    # Handle one key. Return an outcome from the vocabulary above.
    abstract def handle_key(ev : Termisu::Event::Key) : Symbol

    # Handle a left-click at (mx, my) within `area`. Same outcome vocabulary. The default
    # implements the shared "click-away (outside the modal box) cancels, anything inside
    # stays" behaviour; overlays with clickable rows override to also commit on a hit.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      click_text_field(mx, my) # a press inside a drawn field is a caret, not a no-op
      :stay
    end

    # Whether a press inside this modal can start a DRAG — pointer motion with the button
    # held, which extends a selection from where the press landed. False by default: an
    # overlay opts in only when its card holds text with a selection to extend.
    #
    # The shell dragged NOTHING over an overlay before this: `Runner#dispatch_drag` reached
    # only the active tab, so the three modals that embed a real multi-line editor (the
    # Rewriter stub, the Discover headers, the Fuzzer SET value list) were text an operator
    # could type into and could not select with the pointer. The tab-side contract this
    # mirrors is `TabController#supports_drag?` / `#handle_drag` / `#handle_double_click`,
    # deliberately spelled the same way so the shell's two tiers read alike.
    #
    # All three take the SAME `area` the shell hands `handle_click` (the body rect), because
    # an overlay hit-tests its own card: the shell owns no geometry inside it.
    def supports_drag? : Bool
      !text_fields.empty?
    end

    # The single-line fields this modal draws. Default empty; an overlay that lists them
    # here gets drag-select and double-click word-select for FREE, because a `TextField`
    # remembers the x/y/width it was last drawn at and inverts its own clicks (`hit?`).
    #
    # That indirection is the point: the geometry of a "label value" row lives in the
    # overlay's `render` and nowhere else, so the alternative was thirteen hand-written row
    # rects for the pointer to invert — thirteen chances to land the caret a column off what
    # was drawn. The field is the only thing that already knows.
    #
    # The PRESS is still each overlay's own business (it also picks the focused row), which
    # is why `handle_click` is not defaulted here.
    def text_fields : Array(TextField)
      [] of TextField
    end

    # Pointer moved with the button held. Extends the selection to (mx, my).
    def handle_drag(area : Rect, mx : Int32, my : Int32) : Nil
      text_fields.each { |f| break if f.click_to_cursor(mx, my, selecting: true) }
    end

    # Two presses in the same cell inside the double-click window. An OUTCOME, like
    # `handle_key` / `handle_click`, plus one more value:
    #
    #   :pass   — not mine; the shell delivers the second press as an ordinary click (which,
    #             for a modal, includes the click-away dismiss — so any other answer is also
    #             saying "this press was text or a row, not a dismiss")
    #   :stay   — taken, card stays up (a word selected, an inline row opened)
    #   :cancel / :commit — taken, and the card closes the way the key outcomes close it
    #
    # The default selects the word under the pointer in whichever listed field was drawn
    # there. A LIST card overrides to run what ↵ runs on the row — and a list whose ↵ hands
    # off to a form (`AuthorizeIdentitiesOverlay`, `ColumnsOverlay`) needs `:cancel` to do
    # that, which is why this is a Symbol and not the Bool the tab tier answers with.
    def handle_double_click(area : Rect, mx : Int32, my : Int32) : Symbol
      text_fields.each { |f| return :stay if f.select_word_at(mx, my) }
      :pass
    end

    # Place the caret in whichever listed field was drawn under the pointer, collapsing any
    # standing selection. Overlays call this from their own `handle_click` — one line, after
    # they have picked the focused row — so a press inside a field is a caret rather than a
    # no-op. Returns whether a field took it.
    def click_text_field(mx : Int32, my : Int32) : Bool
      text_fields.each { |f| return true if f.click_to_cursor(mx, my) }
      false
    end

    # The modal's box within `area` — the click-away hit-test. `nil` means the card has
    # no room to draw; the default handle_click then treats any click as a dismiss (the
    # prior shell behaviour: `close if box.nil? || click-outside`). Overlays that center a
    # card override this (most already do, for render).
    def overlay_box(area : Rect) : Rect?
      nil
    end

    # Move the selected field by a signed step (↑/↓ and the scroll wheel share this).
    # Default no-op; form overlays override it. Button-only modals leave it inert.
    def move(step : Int32) : Nil
    end

    # --- the list-card contract: PgUp/PgDn/Home/End over whatever rows a card draws --------
    #
    # `PickerOverlay` had this for the five pickers (#958); the nine list CARDS — notifications,
    # agents, listeners, passthrough, tabs, columns, hosts, env, hotkeys — each hand-rolled
    # ↑/↓ and walked a 100-entry ring one row at a time. A card takes part by answering
    # `entry_count`, keeping `set_selected`, recording the rows its last frame drew in
    # `@list_last_h`, and taking `page_key(ev)` as one arm of its key ladder.

    @list_last_h = 0 # rows the last frame drew — the PgUp/PgDn step

    # Navigable rows. Zero (the default) leaves `page_key` inert.
    def entry_count : Int32
      0
    end

    # PgUp/PgDn/Home/End over the list, one page being the rows the last frame drew. True
    # when `ev` was one of the four, so a key ladder can take it as one arm.
    def page_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      case
      when key.page_up?   then move(-{@list_last_h, 1}.max)
      when key.page_down? then move({@list_last_h, 1}.max)
      when key.home?      then set_selected(0)
      when key.end?       then set_selected(entry_count - 1)
      else                     return false
      end
      true
    end

    # The one line a card draws when `area` cannot hold it: "<what> · esc to close" (or the
    # `closing` a card with unsaved edits prefers, e.g. "esc saves & closes"). Forty-odd cards
    # each spelled this out; the wording stays theirs, the paint and the empty-area guard are
    # here. Class-level so a card that is not an `Overlay` (the confirm dialog, the settings
    # view) draws the same line.
    def self.too_small(screen : Screen, area : Rect, what : String, closing : String = "esc to close") : Nil
      return if area.empty?
      screen.text(area.x + 1, area.y, "#{what} · #{closing}", Theme.muted, Theme.bg, width: {area.w - 1, 0}.max)
    end

    def render_too_small(screen : Screen, area : Rect, what : String, closing : String = "esc to close") : Nil
      Overlay.too_small(screen, area, what, closing)
    end

    # A scroll-wheel notch over the modal (already ±3-scaled). Defaults to a field move, so
    # form overlays get wheel scrolling for free by overriding `move`.
    def handle_wheel(step : Int32) : Nil
      move(step)
    end

    # Live IME composition text for the focused field. Default: no-op.
    def set_preedit(text : String) : Nil
    end

    # True while the overlay is recording a RAW chord (the hotkey rebinder's capture
    # mode). The shell then hands it every key BEFORE its own pre-filter, so ^C/^D reach
    # the overlay as bindable chords instead of arming the global quit. Default false —
    # no other modal wants the shell's chords, and the pre-filter must keep claiming them.
    def raw_key_capture? : Bool
      false
    end

    # Run the injected commit closure. Returns true when the shell should close the
    # overlay (default true when no closure was supplied).
    def commit : Bool
      (c = on_commit) ? c.call : true
    end
  end

  # The row form: a card of `label: value` rows, one selected, each drawn as a band with a `▎`
  # marker, the LAST row the button that commits (Save / Run / Start). Ten forms — Rewriter,
  # Colormarker, Probe custom, extract, column, Scope, OAST provider, custom colour, Sequencer,
  # active scan — had each hand-rolled the selection, the click, the render loop and the row
  # prelude. A subclass answers `row_count`, `card_title`, `too_small_what` and
  # `draw_row_body`, and keeps its own key cases.
  abstract class FormOverlay < Overlay
    @sel = 0

    abstract def row_count : Int32

    # The card's border title (`title` is the shell's focus badge).
    abstract def card_title : String

    # The "<what>" of the line drawn when the card does not fit (`Overlay.too_small`).
    abstract def too_small_what : String

    # One row's content, drawn over the band and the `▎` marker; `x` is the label column.
    abstract def draw_row_body(screen : Screen, box : Rect, i : Int32, py : Int32,
                               x : Int32, bg : Color, fg : Color, sel : Bool) : Nil

    # Whether `row` is one ↑/↓ walks past: a row the form's current kind or op ignores.
    def skip_row?(row : Int32) : Bool
      false
    end

    # Whether the card draws a preview band under the rows (`Overlay.rule_form_box`).
    def preview? : Bool
      false
    end

    def on_save_row? : Bool
      @sel == row_count - 1
    end

    # One row per step whatever `d`'s size, walking PAST rows `skip_row?` names instead of
    # landing on them, and stopping at the ends rather than wrapping. A form whose wheel notch
    # moves the full `d` overrides with a clamp.
    def move(d : Int32) : Nil
      step = d < 0 ? -1 : 1
      nxt = @sel
      loop do
        probe = nxt + step
        break if probe < 0 || probe > row_count - 1
        nxt = probe
        break unless skip_row?(nxt)
      end
      @sel = nxt unless skip_row?(nxt)
    end

    def set_selected(idx : Int32) : Nil
      idx = idx.clamp(0, row_count - 1)
      @sel = idx unless skip_row?(idx)
    end

    # ↑/⇤ and ↓/↹ step between rows. True when `ev` was one of the four, so a key ladder can
    # take it as one arm.
    private def field_nav?(ev : Termisu::Event::Key) : Bool
      key = ev.key
      if key.up? || key.back_tab?
        move(-1)
      elsif key.down? || key.tab?
        move(1)
      else
        return false
      end
      true
    end

    # Click a row to select it; a click on the commit row commits; a click outside the card
    # cancels. Mirrors the ↑/↓ + ↵ keyboard model.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      if idx = row_at(box, mx, my)
        set_selected(idx)
        return :commit if on_save_row?
        row_clicked(idx)
      end
      # …then the caret, if the press landed inside a drawn field. The row pick above is
      # what focuses; this is what puts the caret where the operator pointed instead of
      # leaving it wherever the last keystroke did (Overlay#click_text_field).
      click_text_field(mx, my)
      :stay
    end

    # A press on a row that is not the commit row, after it was selected.
    private def row_clicked(idx : Int32) : Nil
    end

    def overlay_box(area : Rect) : Rect?
      Overlay.rule_form_box(area, row_count, preview: preview?)
    end

    private def first_row_y(box : Rect) : Int32
      box.y + 2
    end

    # The first y a row may not be drawn on: the bottom border, or the preview band above it.
    private def rows_bottom(box : Rect) : Int32
      box.bottom - (preview? ? 2 : 1)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        Overlay.too_small(screen, area, too_small_what)
        return
      end
      Frame.card(screen, box, card_title, border: Theme.border_focus)
      draw_head(screen, box)
      first = first_row_y(box)
      row_count.times do |i|
        py = first + i
        break if py >= rows_bottom(box)
        draw_row(screen, box, i, py)
      end
      draw_tail(screen, box, first)
      # No key hint on the bottom border: the shell already draws `hint` in the status strip
      # for whichever modal is open (Runner#key_hints), so a second copy here was the same
      # advice twice — and the copies had drifted apart. Per-row affordances stay where the
      # key applies (the `‹/›` a cycler draws when it has focus).
    end

    # What a card draws between its title and its rows.
    private def draw_head(screen : Screen, box : Rect) : Nil
    end

    # What a card draws under its rows (the preview band); `first` is the first row's y.
    private def draw_tail(screen : Screen, box : Rect, first : Int32) : Nil
    end

    private def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil
      sel = i == @sel
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)
      draw_row_body(screen, box, i, py, box.x + 3, bg, sel ? Theme.text_bright : Theme.text, sel)
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      return nil if my >= rows_bottom(box) # render stops there: the preview band, not a row
      i = my - first_row_y(box)
      (0 <= i < row_count) ? i : nil
    end
  end

  # A read-only inventory card reached from a top-bar chip: the additional listeners, the TLS
  # passthrough hosts, the attached MCP clients. Nothing on it is edited — ↑/↓ scroll, `r`
  # re-snapshots, a click selects, esc closes — and the last row inside the card is a footer
  # saying what the list itself cannot. A subclass holds its rows (a COPY, so they cannot shift
  # under a click hit-tested against the previous frame) and draws them.
  abstract class ListCard < Overlay
    # ^P leaves for the command palette, like every other list overlay. Injected because
    # raising another modal is the shell's job.
    property on_palette : Proc(Nil)?

    @selected = 0

    # Re-snapshot the rows, keeping the selection in range.
    abstract def reload : Nil

    private abstract def card_w : Int32
    private abstract def meta : String
    private abstract def empty_text : String
    private abstract def too_small_what : String
    private abstract def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil
    private abstract def draw_footer(screen : Screen, box : Rect) : Nil

    # A card's own key, ahead of the list keys. True when it took `ev`.
    private def card_key(ev : Termisu::Event::Key) : Bool
      false
    end

    # What bare `r` does.
    private def refresh : Nil
      reload
    end

    # Read-only: no ↵ commit, nothing to apply.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      k = ev.key
      if ev.ctrl? && k.lower_p?
        on_palette.try(&.call)
      elsif k.escape?
        return :cancel
      elsif !card_key(ev)
        handle_nav(ev)
      end
      :stay
    end

    # ↑/↓ and their bare-letter twins, plus the bare `r`. Split out of `handle_key` for the same
    # reason `HotkeysOverlay#bare_char` is a method — to keep the dispatcher under the ameba
    # complexity bar — and the guard in the middle is the whole point of the split.
    #
    # BOTH halves of every letter arm need it, which is why guarding the `ev.char` arm alone was
    # not enough. `Event::Key#char` is `@char || key.to_char`, so ^R folds back to 'r'; and the
    # termisu parser emits ^K as `Key::LowerK + Ctrl` (parser.cr maps 0x01..0x1A through
    # `Key.from_char`), so `k.lower_k?` is TRUE on a chord too — no `ev.char` involved. The
    # shell pre-filters only ^C/^D/^G/^F/^B (`Runner#handle_key`), so every other chord lands
    # here. ARROWS stay outside the guard deliberately: ⌃↑/⌃↓ are a scroll gesture elsewhere in
    # gori and nothing folds them into a letter, so there is no bug to fix on that arm.
    private def handle_nav(ev : Termisu::Event::Key) : Nil
      k = ev.key
      if k.up?
        move(-1)
      elsif k.down?
        move(1)
      elsif page_key(ev)
        # PgUp/PgDn/Home/End — the list contract, `Overlay#page_key`
      elsif ev.ctrl? || ev.alt?
        # A chord is not a mnemonic. Claimed and dropped rather than fallen through: this
        # overlay returns :stay for everything, so the chord was consumed either way — the
        # only question was whether it also DID something, and it should not.
      elsif k.lower_k?
        move(-1)
      elsif k.lower_j?
        move(1)
      elsif (ev.char || k.to_char) == 'r'
        refresh
      end
    end

    # A click inside the card selects a row (there is nothing to open); outside dismisses.
    # Never :commit — a read-only list that closed itself on a row click would look like it
    # had done something.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      # The gauge on the card's right hairline, before `row_at` — which has no `mx` bound and
      # would otherwise read a click there as a plain pick of whatever row shares its `my`.
      if row = gauge_row_at(box, mx, my)
        set_selected(row)
      elsif idx = row_at(box, mx, my)
        set_selected(idx)
      end
      :stay
    end

    def move(d : Int32) : Nil
      @selected = (@selected + d).clamp(0, {entry_count - 1, 0}.max)
    end

    def set_selected(idx : Int32) : Nil
      @selected = idx.clamp(0, {entry_count - 1, 0}.max)
    end

    # Centered box, sized to the content (min 6 rows), `card_w` wide at most.
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, card_w}.min
      rows = {entry_count, 6}.max
      h = {area.h - 2, rows + 4}.min # title gap + list + footer + bottom border
      return nil if w < 32 || h < 7
      area.center(w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        Overlay.too_small(screen, area, too_small_what)
        return
      end
      Frame.card(screen, box, title, border: Theme.border_focus)
      Frame.border_meta(screen, box, title, meta, bg: Theme.panel)

      cap = list_capacity(box)
      @list_last_h = cap
      return if cap <= 0
      start = list_window(cap)
      if entry_count == 0
        screen.text(box.x + 3, box.y + 2, empty_text, Theme.muted, Theme.panel)
      else
        cap.times do |row|
          i = start + row
          break if i >= entry_count
          draw_row(screen, box, i, box.y + 2 + row)
        end
      end
      # A windowed list with no gauge gave an operator scrolling past row `cap` nothing that
      # said there was more. `true` for focused: an open modal IS the focus.
      Frame.scroll_gauge(screen, Rect.new(box.x + 1, box.y + 2, box.w - 2, cap),
        entry_count, start, true, Theme.panel)
      draw_footer(screen, box)
    end

    # The row a click on the list's scroll gauge asks for. The gauge rides the card's right
    # hairline; the window is derived from the selection, so this answers with a selection.
    def gauge_row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      Frame.scroll_gauge_row(Rect.new(box.x + 1, box.y + 2, box.w - 2, list_capacity(box)),
        entry_count, mx, my)
    end

    # Row index under (mx,my) — inverts render's windowed layout so a click maps to the same
    # row that was drawn.
    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      cap = list_capacity(box)
      row = my - (box.y + 2)
      return nil if row < 0 || row >= cap
      i = list_window(cap) + row
      i < entry_count ? i : nil
    end

    # One row above the border is reserved for the footer (see draw_footer).
    private def list_capacity(box : Rect) : Int32
      {box.bottom - 2 - (box.y + 2), 0}.max
    end

    private def list_window(cap : Int32) : Int32
      return 0 if cap <= 0 || entry_count <= cap
      { {@selected - cap + 1, 0}.max, entry_count - cap }.min
    end
  end
end
