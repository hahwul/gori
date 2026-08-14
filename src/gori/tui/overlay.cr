require "termisu"
require "./screen"
require "./geometry"
require "./text_field"
require "./theme"

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
    TabsMore
    ComparerPick
    RepeaterSubtab
    Links
    LinkPick
    Preferences
    Settings
    Tabs
    Hosts
    Env
    Hotkeys
    Notifications
    Passthrough
    Listeners
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
    CaImport
    Import
    Export
    ScopeRule
    SequenceConfig
    MineConfig
    # The two halves of a named GLOBAL library (settings.json), shared by the Decoder's
    # chain specs and the Rewriter's rule presets: NamePromptOverlay writes, LibraryPicker
    # reads. One pair rather than four kinds — the modal is the same in both tabs, only
    # its rows and its injected on_commit differ.
    NamePrompt
    LibraryPick
    # Prompt-tier pickers. These two name a modal that `@overlay` NEVER holds: copy-as
    # and send-to float over whatever is underneath (a tab body OR the History detail
    # drill-in) without disturbing it, and are claimed before the ^G/^F/^B guards, so the
    # Runner keeps them in their own slots (see Runner#copy_as_shown?). They are members
    # anyway because `Overlay#key` is how a modal names itself, and a picker on the seam
    # must answer it honestly rather than borrow `None`.
    CopyAs
    SendTo

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
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
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
      screen.text(x, py, label, Theme.muted, bg)
      vx = x + label.size + 1
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

    # Two presses in the same cell inside the double-click window. Selects the word under
    # the pointer; return false to fall back to the ordinary single-click behaviour (which,
    # for a modal, includes the click-away dismiss — so a modal that answers true here is
    # also saying "this press was text, not a dismiss").
    def handle_double_click(area : Rect, mx : Int32, my : Int32) : Bool
      text_fields.each { |f| return true if f.select_word_at(mx, my) }
      false
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
end
