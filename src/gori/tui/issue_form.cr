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
    getter issue_title : String
    getter host : String?
    getter flow_id : Int64?
    getter severity : Store::Severity
    getter edit_id : Int64?
    getter link_ref : {Store::LinkRefKind, Int64}?

    def initialize(@issue_title : String = "", @host : String? = nil, @flow_id : Int64? = nil,
                   @severity : Store::Severity = Store::Severity::Medium,
                   @edit_id : Int64? = nil, @heading : String = "NEW ISSUE",
                   @link_ref : {Store::LinkRefKind, Int64}? = nil)
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

    # Inert on purpose: the pre-seam shell had no click arm for this modal, so neither a
    # click-away nor a click on the card did anything. Caret placement by click is the
    # follow-up that will give this a real body.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
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

    def render(screen : Screen, area : Rect) : Nil
      w = {area.w - 4, 56}.min
      h = 6
      return if w < 12 || area.h < h
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      box = Rect.new(x, y, w, h)
      Frame.card(screen, box, @heading, border: Theme.border_focus)
      prefix = "title › "
      screen.text(box.x + 2, box.y + 1, prefix, Theme.accent, Theme.panel)
      base = box.x + 2 + prefix.size
      screen.input_line(base, box.y + 1, @issue_title, @cx, @preedit, Theme.text_bright, Theme.panel, width: w - prefix.size - 4)
      sx = screen.text(box.x + 2, box.y + 3, "severity ‹ ", Theme.accent, Theme.panel)
      sx = screen.text(sx, box.y + 3, @severity.label.upcase, sev_color(@severity), Theme.panel, Attribute::Bold)
      screen.text(sx, box.y + 3, " ›  (tab to change)", Theme.muted, Theme.panel)
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
