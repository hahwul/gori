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
    SEV_SUFFIX   = " ›  (tab to change)"
    TITLE_ROW    = 1
    SEV_ROW      = 3
    CARD_H       = 6

    getter issue_title : String
    getter host : String?
    getter flow_id : Int64?
    getter severity : Store::Severity
    getter edit_id : Int64?
    getter link_ref : {Store::LinkRefKind, Int64}?
    # Additional flows to attach as evidence beyond `flow_id` — History's multi-select
    # (#442): mark 5 flows, ⇧F, and the ONE issue you create carries all five. Captured here
    # for the same reason as `link_ref`: cancelling the form drops the pending attachments
    # with it instead of leaving them for a later create to pick up.
    getter extra_flow_ids : Array(Int64)

    def initialize(@issue_title : String = "", @host : String? = nil, @flow_id : Int64? = nil,
                   @severity : Store::Severity = Store::Severity::Medium,
                   @edit_id : Int64? = nil, @heading : String = "NEW ISSUE",
                   @link_ref : {Store::LinkRefKind, Int64}? = nil,
                   @extra_flow_ids : Array(Int64) = [] of Int64)
      @cx = @issue_title.size
      @preedit = ""
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

    def hint : String
      "type title · ↵ create · esc cancel"
    end

    # ↵ commits, esc cancels, Tab/Shift-Tab cycle severity, ←/→ move the title caret, and
    # every other printable is inserted.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      # Not `ev.char || key.to_char`, which the pre-seam handler wrote: Termisu's
      # `Event::Key#char` IS `@char || key.to_char`, so the second half could never run.
      c = ev.char
      case
      when key.escape?    then return :cancel
      when key.enter?     then return :commit
      when key.tab?       then severity_cycle(1)
      when key.back_tab?  then severity_cycle(-1)
      when key.left?      then move(-1)
      when key.right?     then move(1)
      when key.backspace? then backspace
      else
        if c && !ev.ctrl? && !ev.alt?
          insert(c)
          set_preedit("") # commit any preedit
        end
      end
      :stay
    end

    # This was inert on purpose, carrying the pre-seam shell's lack of a click arm forward and
    # naming caret placement as the follow-up. It is the follow-up. Inert made this the ONE
    # modal in the tree a click-away could not dismiss — the base `Overlay#handle_click` gives
    # every other one that, and `PickerOverlay` repeats it for the seven pickers — so an
    # operator who opened NEW ISSUE by mistake had to find esc, with no visible hint that a
    # click outside would not do.
    #
    # Inside the card, the two rows the draw makes look interactive now are:
    #   · the title row → place the caret at the pointer (the same inverse `TextField` uses)
    #   · the DRAWN span of the severity row → step the cycler, `‹` back and the rest forward,
    #     which is what the chevrons and the row's own "(tab to change)" already promise
    # Anything else inside — including the empty tail of the severity row past its label — is
    # swallowed, so it neither leaks to the pane underneath nor makes dead cells do something.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      if my == box.y + TITLE_ROW
        @cx = Screen.column_for(@issue_title, mx - title_base(box)) # already clamped to the string
        @preedit = ""                                               # a caret move ends any in-progress composition, as `insert` does
      elsif my == box.y + SEV_ROW && (lo = sev_back_x(box)) && mx >= lo && mx <= sev_forward_end(box)
        severity_cycle(mx == lo ? -1 : 1)
      end
      :stay
    end

    # Inert on purpose. The base default routes a wheel notch to `move`, which here walks
    # the TITLE CARET — a scroll must not silently re-aim where the next character lands.
    # The pre-seam shell had no wheel arm for this modal either.
    def handle_wheel(step : Int32) : Nil
    end

    # Tab / Shift-Tab cycle severity (left/right stay title-cursor moves).
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
    # committed title — same model as TextArea. Cleared when a char commits.
    def set_preedit(text : String) : Nil
      @preedit = text
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
      Frame.card(screen, box, @heading, border: Theme.border_focus)
      screen.text(box.x + 2, box.y + TITLE_ROW, TITLE_PREFIX, Theme.accent, Theme.panel)
      screen.input_line(title_base(box), box.y + TITLE_ROW, @issue_title, @cx, @preedit,
        Theme.text_bright, Theme.panel, width: w - TITLE_PREFIX.size - 4)
      sx = screen.text(box.x + 2, box.y + SEV_ROW, SEV_PREFIX, Theme.accent, Theme.panel)
      sx = screen.text(sx, box.y + SEV_ROW, @severity.label.upcase, sev_color(@severity), Theme.panel, Attribute::Bold)
      screen.text(sx, box.y + SEV_ROW, SEV_SUFFIX, Theme.muted, Theme.panel)
    end

    # Content column the title text starts at — `screen.text`'s own advance over the prefix,
    # so the caret inverse uses the same measure the draw did.
    private def title_base(box : Rect) : Int32
      box.x + 2 + Screen.draw_width(TITLE_PREFIX)
    end

    # The `‹` cell on the severity row, measured off SEV_PREFIX itself rather than re-typed —
    # the only cell that steps BACKWARD, everything from there to `sev_forward_end` reads as the
    # forward step the label's own "(tab to change)" names.
    private def sev_back_x(box : Rect) : Int32
      i = SEV_PREFIX.index('‹') || 0
      box.x + 2 + Screen.draw_width(SEV_PREFIX[0, i])
    end

    # Last cell of the interactive span: the closing `›`, one column past the label, which is
    # where `render`'s third `screen.text` puts it (SEV_SUFFIX opens with a space). The cells
    # after it hold the "(tab to change)" hint and then nothing — a click there must be inert.
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
