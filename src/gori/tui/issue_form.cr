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
  #
  # The `cvss` row is a LAUNCHER, not a third text field: it shows what the issue will carry
  # and `↵` opens the calculator (CvssCalculatorOverlay), which is where a vector is both
  # typed and built. It began as a text field with a `^C` chord next to it, and both halves
  # of that were wrong. `^C` is the quit chord everywhere else in gori — the modal seam is
  # the ONE place it is free, so binding it here taught the reflex "^C leaves" a silent
  # exception. And a form whose ↵ means "create" cannot also mean "open the thing", so the
  # typing row and the builder were two editable copies of one value a row apart. One value,
  # one place to edit it, and `↵` keeps meaning "go on" rather than a chord you have to know.
  class IssueForm < Overlay
    # Card geometry + the two labels the draw lays down, in one place because `render` and the
    # click hit-tests below both measure off them. A second copy of `"severity ‹ "` next to the
    # inverse is this repo's standing hazard: the moment the two drift, the click lands on a
    # cell the card never drew there.
    TITLE_PREFIX    = "title › "
    CVSS_PREFIX     = "cvss (opt) › "
    CVSS_EMPTY      = "none"
    CVSS_HINT       = "(↵ calc)"
    SEV_PREFIX      = "severity ‹ "
    SEV_SUFFIX      = " ›  (←/→ to change)"
    SEV_SUFFIX_BLUR = " ›  (⇥ to focus)"
    TITLE_ROW       = 1
    CVSS_ROW        = 2
    SEV_ROW         = 4
    CARD_H          = 7

    # 72 is the width every rule form in gori settled on (Overlay::RULE_FORM_W, and the
    # argument for it is written there). This card was 66 for no recorded reason, and the six
    # columns are exactly what a full `CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H` needs to
    # sit on its row without an ellipsis.
    CARD_W = Overlay::RULE_FORM_W

    # Row cursor. Three rows: Title, CVSS, and Severity.
    ROW_TITLE = 0
    ROW_CVSS  = 1
    ROW_SEV   = 2
    ROW_COUNT = 3

    getter issue_title : String
    getter cvss : String
    getter host : String?
    getter flow_id : Int64?
    getter severity : Store::Severity
    getter edit_id : Int64?
    getter link_ref : {Store::LinkRefKind, Int64}?
    getter sel : Int32
    getter preedit : String
    getter extra_flow_ids : Array(Int64)
    getter notes : String

    # Whether the severity showing was DERIVED from the cvss rather than picked. Only the
    # label reads it — an operator who cycles severity by hand after scoring one has made a
    # deliberate override, and the row says which of the two it is looking at.
    getter? severity_from_cvss : Bool = false
    property on_open_calc : Proc(Nil)?

    def initialize(@issue_title : String = "", @host : String? = nil, @flow_id : Int64? = nil,
                   @severity : Store::Severity = Store::Severity::Medium,
                   @edit_id : Int64? = nil, @heading : String = "NEW ISSUE",
                   @link_ref : {Store::LinkRefKind, Int64}? = nil,
                   @extra_flow_ids : Array(Int64) = [] of Int64,
                   @notes : String = "",
                   @cvss : String = "")
      @cx = @issue_title.size
      @preedit = ""
      @sel = ROW_TITLE
      # An EDIT opens on the stored pair. The severity the store holds wins — an operator who
      # overrode it once must not have that overridden back by the mere act of re-opening the
      # form — so this only decides which of the two labels the severity row wears.
      @severity_from_cvss = !@cvss.empty? && Gori::Cvss.severity_for(@cvss) == @severity
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::IssueNew
    end

    def title : String
      "ISSUE"
    end

    def hint : String
      case @sel
      when ROW_SEV
        "←/→ severity · ⇥ title · ↵ create · esc cancel"
      when ROW_CVSS
        "↵ calculator · ⌫ clear · ⇥ severity · esc cancel"
      else
        "type title · ←/→ caret · ⇥ cvss · ↵ create · esc cancel"
      end
    end

    # What the calculator applies (and what ⌫ clears, with ""). Deriving severity here rather
    # than on every keystroke is the whole reason the row stopped being a text field: a
    # half-typed vector scores as nothing, so the old per-character derive only ever fired on
    # the last character anyway — and it could never LOWER a severity back once a cleared
    # field stopped parsing. Clearing now clears the derivation with it.
    def set_cvss_value(val : String) : Nil
      @cvss = val.strip
      if s = Gori::Cvss.severity_for(@cvss)
        @severity = s
        @severity_from_cvss = true
      else
        @severity_from_cvss = false
      end
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      c = ev.char
      case
      when key.escape?            then return :cancel
      when key.enter?             then return enter
      when key.tab?, key.down?    then move_row(1)
      when key.back_tab?, key.up? then move_row(-1)
      when key.left?              then step(-1)
      when key.right?             then step(1)
      when key.backspace?
        if @sel == ROW_CVSS
          set_cvss_value("")
        else
          focus_title
          backspace_title
        end
      else
        # A printable on the cvss row is deliberately inert: the row holds no caret, and
        # jumping focus to the title (what the severity row does) would throw a vector
        # someone started typing into the title of their issue. The row's own `(↵ calc)`
        # label and this form's `hint` both name the key that does work here.
        if c && !ev.ctrl? && !ev.alt? && @sel != ROW_CVSS
          focus_title
          insert_title(c)
          set_preedit("")
        end
      end
      :stay
    end

    # ↵ still means "go on" — on the cvss row the next step is the calculator, not the create.
    # That row is the only launcher on the card, so this is the only place the form's ↵
    # resolves to anything but commit.
    private def enter : Symbol
      return :commit unless @sel == ROW_CVSS
      @on_open_calc.try(&.call)
      :stay
    end

    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      if my == box.y + TITLE_ROW
        focus_title
        @cx = Screen.column_for_click(@issue_title, mx - title_base(box))
        @preedit = ""
      elsif my == box.y + CVSS_ROW
        # The whole row is the button — there is nothing else on it to hit, and a hit box
        # narrower than what was drawn is this file's standing hazard (see the note above
        # the constants).
        focus_cvss
        @on_open_calc.try(&.call)
      elsif my == box.y + SEV_ROW && (lo = sev_back_x(box)) && mx >= lo && mx <= sev_forward_end(box)
        @sel = ROW_SEV
        severity_cycle(mx == lo ? -1 : 1)
      end
      :stay
    end

    def handle_wheel(step : Int32) : Nil
    end

    def step(delta : Int32) : Nil
      case @sel
      when ROW_TITLE then move_title(delta)
      when ROW_CVSS  then nil # no caret on a launcher row
      else                severity_cycle(delta)
      end
    end

    def move_row(delta : Int32) : Nil
      @sel = (@sel + delta) % ROW_COUNT
      @preedit = "" unless @sel == ROW_TITLE
    end

    def severity_cycle(delta : Int32) : Nil
      @severity = Store::Severity.new((@severity.value + delta).clamp(0, 4))
      @severity_from_cvss = false
    end

    def insert(ch : Char) : Nil
      insert_title(ch)
    end

    def backspace : Nil
      backspace_title
    end

    def move(d : Int32) : Nil
      move_title(d)
    end

    def insert_title(ch : Char) : Nil
      @issue_title = "#{@issue_title[0, @cx]}#{ch}#{@issue_title[@cx..]}"
      @cx += 1
      @preedit = ""
    end

    def backspace_title : Nil
      return if @cx == 0
      @issue_title = "#{@issue_title[0, @cx - 1]}#{@issue_title[@cx..]}"
      @cx -= 1
    end

    def move_title(d : Int32) : Nil
      @cx = (@cx + d).clamp(0, @issue_title.size)
    end

    def set_preedit(text : String) : Nil
      return if @sel == ROW_CVSS # nothing to compose into on a launcher row
      focus_title unless text.empty?
      @preedit = text
    end

    def focus_title : Nil
      @sel = ROW_TITLE
    end

    def focus_cvss : Nil
      @sel = ROW_CVSS
    end

    def focus_severity : Nil
      @sel = ROW_SEV
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, CARD_W}.min
      return nil if w < 12 || area.h < CARD_H
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - CARD_H) // 2, w, CARD_H)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      return unless box
      w = box.w
      on_title = @sel == ROW_TITLE
      on_cvss = @sel == ROW_CVSS
      on_sev = @sel == ROW_SEV

      Frame.card(screen, box, @heading, border: Theme.border_focus)
      indicator_y = case @sel
                    when ROW_TITLE then TITLE_ROW
                    when ROW_CVSS  then CVSS_ROW
                    else                SEV_ROW
                    end
      screen.cell(box.x + 1, box.y + indicator_y, '▎', Theme.accent, Theme.panel)

      # Title row
      screen.text(box.x + 2, box.y + TITLE_ROW, TITLE_PREFIX, on_title ? Theme.accent : Theme.muted, Theme.panel)
      tw = w - TITLE_PREFIX.size - 4
      if on_title
        screen.input_line(title_base(box), box.y + TITLE_ROW, @issue_title, @cx, @preedit,
          Theme.text_bright, Theme.panel, width: tw)
      else
        screen.text(title_base(box), box.y + TITLE_ROW, @issue_title, Theme.text, Theme.panel, width: {tw, 0}.max)
      end

      # CVSS row. Right-anchored key affordance first, so what is left of it is the width
      # the value may use — every `text` here is width-clipped to that, because Screen#text
      # clips to the SCREEN and an unbounded draw would land on the card's own border.
      cy = box.y + CVSS_ROW
      # EVERY draw on this row is width-clipped, the label and the affordance included. The
      # card is admitted down to w = 12 while `CVSS_PREFIX` alone is 13 columns, so an
      # unbounded label runs through the right border — and `Screen#text` clips to the SCREEN,
      # so it lands outside the card entirely rather than being cut at it.
      screen.text(box.x + 2, cy, CVSS_PREFIX, on_cvss ? Theme.accent : Theme.muted, Theme.panel,
        width: {box.right - 1 - (box.x + 2), 0}.max)
      aff_x = box.right - Screen.draw_width(CVSS_HINT) - 2
      if aff_x > box.x + 2
        screen.text(aff_x, cy, CVSS_HINT, on_cvss ? Theme.accent : Theme.muted, Theme.panel,
          width: {box.right - 1 - aff_x, 0}.max)
      end

      vx = cvss_base(box)
      vw = {aff_x - vx - 1, 0}.max
      if @cvss.empty?
        screen.text(vx, cy, CVSS_EMPTY, Theme.muted, Theme.panel, width: vw)
      else
        screen.text(vx, cy, @cvss, sev_color(@severity), Theme.panel, width: vw)
      end

      # Severity row
      sx = screen.text(box.x + 2, box.y + SEV_ROW, SEV_PREFIX, on_sev ? Theme.accent : Theme.muted, Theme.panel)
      sx = screen.text(sx, box.y + SEV_ROW, @severity.label.upcase, sev_color(@severity), Theme.panel, Attribute::Bold)
      # The severity row is where the qualitative reading lives, so the SCORE that produced it
      # is named here rather than crowding the vector off its own row one line up.
      suffix = if on_sev
                 SEV_SUFFIX
               elsif severity_from_cvss? && (score = Gori::Cvss.score_for(@cvss))
                 " ›  (cvss #{sprintf("%.1f", score)})"
               else
                 SEV_SUFFIX_BLUR
               end
      screen.text(sx, box.y + SEV_ROW, suffix, Theme.muted, Theme.panel,
        width: {box.right - 1 - sx, 0}.max)
    end

    private def title_base(box : Rect) : Int32
      box.x + 2 + Screen.draw_width(TITLE_PREFIX)
    end

    private def cvss_base(box : Rect) : Int32
      box.x + 2 + Screen.draw_width(CVSS_PREFIX)
    end

    private def sev_back_x(box : Rect) : Int32
      i = SEV_PREFIX.index('‹') || 0
      box.x + 2 + Screen.draw_width(SEV_PREFIX[0, i])
    end

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
