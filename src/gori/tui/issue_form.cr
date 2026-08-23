require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "../store"

module Gori::Tui
  # The NEW / EDIT ISSUE modal: one title line plus a severity cycler. A dumb form —
  # the store write rides in as the `on_commit` closure the open-site injects
  # (Runner#open_issue_form → create_issue_from_form), so the same card serves the
  # standalone create, the create-and-link from a workbench picker, and the re-title of
  # an already-open issue.
  #
  # `link_ref` is the workbench item the create should also link to. It is captured HERE
  # rather than read off the shell at commit time so that dropping the form drops the
  # pending link with it: a cancelled create-and-link can no longer leave a stale ref
  # behind for a later standalone create to silently attach.
  class IssueForm < Overlay
    # Card geometry + the two labels the draw lays down, in one place because `render` and the
    # click hit-tests below both measure off them. A second copy of `"severity ‹ "` next to the
    # inverse is this repo's standing hazard: the moment the two drift, the click lands on a
    # cell the card never drew there.
    TITLE_PREFIX = "title › "
    SEV_PREFIX   = "severity ‹ "
    SEV_SUFFIX   = " ›  (←/→ to change)"
    # The same row unfocused: the chevrons still mark it as a cycler, but the keys that step
    # it belong to the OTHER row right now, so the hint names the way back instead.
    SEV_SUFFIX_BLUR = " ›  (⇥ to focus)"
    TITLE_ROW       = 1
    SEV_ROW         = 3
    CARD_H          = 6

    # Row cursor. Two rows, so ⇥/⇧⇥ and ↑/↓ simply wrap between them — the same row model
    # every other form in the tree runs (CustomRuleOverlay, FuzzSetOverlay, the rule cards):
    # ⇥ picks the field, ←/→ adjust the field it picked.
    ROW_TITLE = 0
    ROW_SEV   = 1
    ROW_COUNT = 2

    getter issue_title : String
    getter host : String?
    getter flow_id : Int64?
    getter severity : Store::Severity
    getter edit_id : Int64?
    getter link_ref : {Store::LinkRefKind, Int64}?
    # Which row the arrows act on — ROW_TITLE (caret) or ROW_SEV (the cycler).
    getter sel : Int32
    # Additional flows to attach as evidence beyond `flow_id` — History's multi-select
    # (#442): mark 5 flows, ⇧F, and the ONE issue you create carries all five. Captured here
    # for the same reason as `link_ref`: cancelling the form drops the pending attachments
    # with it instead of leaving them for a later create to pick up.
    getter extra_flow_ids : Array(Int64)
    # Notes to write into the issue on CREATE. The evidence an open-site already holds and the
    # form cannot ask for: an OAST callback's raw interaction has no flow to link, so without
    # this the finding would be filed as a bare title and the proof left behind on another tab.
    # Ignored on an edit (`edit_id`) — that path re-titles an issue whose notes the operator
    # owns, and overwriting them from a form that never showed them would be a silent loss.
    getter notes : String

    def initialize(@issue_title : String = "", @host : String? = nil, @flow_id : Int64? = nil,
                   @severity : Store::Severity = Store::Severity::Medium,
                   @edit_id : Int64? = nil, @heading : String = "NEW ISSUE",
                   @link_ref : {Store::LinkRefKind, Int64}? = nil,
                   @extra_flow_ids : Array(Int64) = [] of Int64,
                   @notes : String = "")
      @cx = @issue_title.size
      @preedit = ""
      # Opens on the title: it is the field the form exists to fill, and the one every
      # open-site pre-seeds a draft into.
      @sel = ROW_TITLE
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::IssueNew
    end

    # The focus badge, NOT the card's `@heading` — that reads NEW/EDIT ISSUE, while the
    # badge stayed the plain "ISSUE" for both.
    def title : String
      "ISSUE"
    end

    # Row-aware, because the arrows do different work on each row and the strip is the only
    # place that says so. Re-read every frame (Runner#key_hints), so it tracks ⇥.
    def hint : String
      if @sel == ROW_SEV
        "←/→ severity · ⇥ title · ↵ create · esc cancel"
      else
        "type title · ←/→ caret · ⇥ severity · ↵ create · esc cancel"
      end
    end

    # ↵ commits, esc cancels, ⇥/⇧⇥ and ↑/↓ pick the row, ←/→ act on it (title caret or
    # severity step), and every other printable is inserted.
    #
    # Severity used to be bound to ⇥ ALONE, which made this the one cycler in the tree the
    # arrows did not drive — an operator who learned ←/→ on the rule cards, the fuzz-set
    # form or the preferences rows found it dead here, with only the row's own hint to say
    # so. ⇥ now means what it means everywhere else: move to the next field.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      # Not `ev.char || key.to_char`, which the pre-seam handler wrote: Termisu's
      # `Event::Key#char` IS `@char || key.to_char`, so the second half could never run.
      c = ev.char
      case
      when key.escape?            then return :cancel
      when key.enter?             then return :commit
      when key.tab?, key.down?    then move_row(1)
      when key.back_tab?, key.up? then move_row(-1)
      when key.left?              then step(-1)
      when key.right?             then step(1)
      when key.backspace?         then focus_title; backspace
      else
        if c && !ev.ctrl? && !ev.alt?
          # Text belongs to the title wherever the row cursor happens to sit: typing on the
          # severity row would otherwise be swallowed by a cycler that has no use for it, and
          # this card is opened to be TYPED INTO. Pulling focus with the character keeps what
          # is drawn (the caret) and where the character lands the same cell. FuzzSetOverlay's
          # Type row does the same thing for the same reason.
          focus_title
          insert(c)
          set_preedit("") # commit any preedit
        end
      end
      :stay
    end

    # Inert on purpose, carrying the pre-seam shell's lack of a click arm forward and
    # naming caret placement as the follow-up. It is the follow-up. Inert made this the ONE
    # modal in the tree a click-away could not dismiss — the base `Overlay#handle_click` gives
    # every other one that, and `PickerOverlay` repeats it for the seven pickers — so an
    # operator who opened NEW ISSUE by mistake had to find esc, with no visible hint that a
    # click outside would not do.
    #
    # Inside the card, the two rows the draw makes look interactive now are:
    #   · the title row → place the caret at the pointer (the same inverse `TextField` uses)
    #   · the DRAWN span of the severity row → step the cycler, `‹` back and the rest forward,
    #     which is what the chevrons and the row's own hint already promise
    # Either one also takes the row cursor with it, so the arrows land on the row just clicked.
    # Anything else inside — including the empty tail of the severity row past its label — is
    # swallowed, so it neither leaks to the pane underneath nor makes dead cells do something.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      if my == box.y + TITLE_ROW
        focus_title
        @cx = Screen.column_for_click(@issue_title, mx - title_base(box)) # already clamped to the string
        @preedit = ""                                                     # a caret move ends any in-progress composition, as `insert` does
      elsif my == box.y + SEV_ROW && (lo = sev_back_x(box)) && mx >= lo && mx <= sev_forward_end(box)
        @sel = ROW_SEV
        severity_cycle(mx == lo ? -1 : 1)
      end
      :stay
    end

    # Inert on purpose. The base default routes a wheel notch to `move`, which here walks
    # the TITLE CARET — a scroll must not silently re-aim where the next character lands.
    # The pre-seam shell had no wheel arm for this modal either.
    def handle_wheel(step : Int32) : Nil
    end

    # ←/→ on the row the cursor sits on: the cycler, or the title caret.
    def step(delta : Int32) : Nil
      @sel == ROW_SEV ? severity_cycle(delta) : move(delta)
    end

    # ⇥/⇧⇥/↑/↓. Wraps, since there are only the two rows and a cursor that stuck at either
    # end would need the OTHER key to come back from a form this small.
    def move_row(delta : Int32) : Nil
      @sel = (@sel + delta) % ROW_COUNT
      # A composition in flight is aimed at the title; leaving the row drops it rather than
      # letting it hang underlined on a field the keys no longer feed.
      @preedit = "" unless @sel == ROW_TITLE
    end

    # Clamped, not wrapped — the same step the Issues list's hidden `[`/`]` chords take
    # (IssuesView#severity_delta), so a held → parks on CRITICAL instead of rolling over to INFO.
    def severity_cycle(delta : Int32) : Nil
      @severity = Store::Severity.new((@severity.value + delta).clamp(0, 4))
    end

    def insert(ch : Char) : Nil
      @issue_title = "#{@issue_title[0, @cx]}#{ch}#{@issue_title[@cx..]}"
      @cx += 1
      @preedit = ""
    end

    def backspace : Nil
      return if @cx == 0
      @issue_title = "#{@issue_title[0, @cx - 1]}#{@issue_title[@cx..]}"
      @cx -= 1
    end

    def move(d : Int32) : Nil
      @cx = (@cx + d).clamp(0, @issue_title.size)
    end

    # IME composing text, drawn (underlined) at the caret without touching the
    # committed title — same model as TextArea. Cleared when a char commits. A composition
    # is text, so it takes the row cursor to the title for the same reason a printable does.
    def set_preedit(text : String) : Nil
      focus_title unless text.empty?
      @preedit = text
    end

    private def focus_title : Nil
      @sel = ROW_TITLE
    end

    # The card `render` draws — extracted from it so the click-away hit test and the draw are
    # one geometry. `nil` = no room, which is also the `Overlay#overlay_box` contract for
    # "treat any click as a dismiss".
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 56}.min
      return nil if w < 12 || area.h < CARD_H
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - CARD_H) // 2, w, CARD_H)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      return unless box
      w = box.w
      on_title = @sel == ROW_TITLE
      Frame.card(screen, box, @heading, border: Theme.border_focus)
      # The `▎` gutter mark every other row-form in the tree draws on its selected row. Here it
      # carries the whole cue on the severity row, which has no caret of its own to show focus.
      screen.cell(box.x + 1, box.y + (on_title ? TITLE_ROW : SEV_ROW), '▎', Theme.accent, Theme.panel)

      screen.text(box.x + 2, box.y + TITLE_ROW, TITLE_PREFIX, on_title ? Theme.accent : Theme.muted, Theme.panel)
      tw = w - TITLE_PREFIX.size - 4
      if on_title
        screen.input_line(title_base(box), box.y + TITLE_ROW, @issue_title, @cx, @preedit,
          Theme.text_bright, Theme.panel, width: tw)
      else
        # No caret while the arrows belong to the other row: a block caret that no keypress
        # moves is the same lie as a dead chevron, pointed the other way.
        screen.text(title_base(box), box.y + TITLE_ROW, @issue_title, Theme.text, Theme.panel, width: {tw, 0}.max)
      end

      sx = screen.text(box.x + 2, box.y + SEV_ROW, SEV_PREFIX, on_title ? Theme.muted : Theme.accent, Theme.panel)
      sx = screen.text(sx, box.y + SEV_ROW, @severity.label.upcase, sev_color(@severity), Theme.panel, Attribute::Bold)
      # Width-clipped, unlike the two draws above it: this is the row's longest run and the
      # card narrows with the terminal, so an unclipped write would spill past the border.
      screen.text(sx, box.y + SEV_ROW, on_title ? SEV_SUFFIX_BLUR : SEV_SUFFIX, Theme.muted, Theme.panel,
        width: {box.right - 1 - sx, 0}.max)
    end

    # Content column the title text starts at — `screen.text`'s own advance over the prefix,
    # so the caret inverse uses the same measure the draw did.
    private def title_base(box : Rect) : Int32
      box.x + 2 + Screen.draw_width(TITLE_PREFIX)
    end

    # The `‹` cell on the severity row, measured off SEV_PREFIX itself rather than re-typed —
    # the only cell that steps BACKWARD, everything from there to `sev_forward_end` reads as the
    # forward step the row's own hint names.
    private def sev_back_x(box : Rect) : Int32
      i = SEV_PREFIX.index('‹') || 0
      box.x + 2 + Screen.draw_width(SEV_PREFIX[0, i])
    end

    # Last cell of the interactive span: the closing `›`, one column past the label, which is
    # where `render`'s third `screen.text` puts it (both suffixes open with a space). The cells
    # after it hold the row's key hint and then nothing — a click there must be inert.
    private def sev_forward_end(box : Rect) : Int32
      box.x + 2 + Screen.draw_width(SEV_PREFIX) + Screen.draw_width(@severity.label.upcase) + 1
    end

    private def sev_color(s : Store::Severity) : Color
      case s
      when .critical? then Theme.red
      when .high?     then Theme.orange
      when .medium?   then Theme.yellow
      when .low?      then Theme.accent
      else                 Theme.muted
      end
    end
  end
end
