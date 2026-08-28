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
    TITLE_PREFIX    = "title › "
    CVSS_PREFIX     = "cvss (opt) › "
    CVSS_CALC_BTN   = "[ ⚡ Calc ]"
    SEV_PREFIX      = "severity ‹ "
    SEV_SUFFIX      = " ›  (←/→ to change)"
    SEV_SUFFIX_BLUR = " ›  (⇥ to focus)"
    TITLE_ROW       = 1
    CVSS_ROW        = 2
    SEV_ROW         = 4
    CARD_H          = 7

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
    getter cvss_preedit : String
    getter extra_flow_ids : Array(Int64)
    getter notes : String
    property on_open_calc : Proc(Nil)?

    def initialize(@issue_title : String = "", @host : String? = nil, @flow_id : Int64? = nil,
                   @severity : Store::Severity = Store::Severity::Medium,
                   @edit_id : Int64? = nil, @heading : String = "NEW ISSUE",
                   @link_ref : {Store::LinkRefKind, Int64}? = nil,
                   @extra_flow_ids : Array(Int64) = [] of Int64,
                   @notes : String = "",
                   @cvss : String = "")
      @cx = @issue_title.size
      @cvss_cx = @cvss.size
      @preedit = ""
      @cvss_preedit = ""
      @sel = ROW_TITLE
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
        "^C calc · type cvss · ←/→ caret · ⇥ severity · ↵ create · esc cancel"
      else
        "type title · ←/→ caret · ⇥ cvss · ↵ create · esc cancel"
      end
    end

    def set_cvss_value(val : String) : Nil
      @cvss = val
      @cvss_cx = val.size
      @cvss_preedit = ""
      update_severity_from_cvss
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      c = ev.char
      case
      when key.escape?            then return :cancel
      when key.enter?             then return :commit
      when key.tab?, key.down?    then move_row(1)
      when key.back_tab?, key.up? then move_row(-1)
      when key.left?              then step(-1)
      when key.right?             then step(1)
      when @sel == ROW_CVSS && ev.ctrl? && (key.lower_c? || key.lower_b?)
        @on_open_calc.try(&.call)
        return :stay
      when key.backspace?
        case @sel
        when ROW_TITLE
          backspace_title
        when ROW_CVSS
          backspace_cvss
        else
          focus_title
          backspace_title
        end
      else
        if c && !ev.ctrl? && !ev.alt?
          case @sel
          when ROW_CVSS
            insert_cvss(c)
            set_preedit("")
          else
            focus_title
            insert_title(c)
            set_preedit("")
          end
        end
      end
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
        btn_w = Screen.draw_width(CVSS_CALC_BTN)
        btn_x = box.right - btn_w - 2
        if mx >= btn_x && mx < btn_x + btn_w
          @on_open_calc.try(&.call)
          return :stay
        end
        focus_cvss
        @cvss_cx = Screen.column_for_click(@cvss, mx - cvss_base(box))
        @cvss_preedit = ""
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
      when ROW_CVSS  then move_cvss(delta)
      else                severity_cycle(delta)
      end
    end

    def move_row(delta : Int32) : Nil
      @sel = (@sel + delta) % ROW_COUNT
      @preedit = "" unless @sel == ROW_TITLE
      @cvss_preedit = "" unless @sel == ROW_CVSS
    end

    def severity_cycle(delta : Int32) : Nil
      @severity = Store::Severity.new((@severity.value + delta).clamp(0, 4))
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

    def insert_cvss(ch : Char) : Nil
      @cvss = "#{@cvss[0, @cvss_cx]}#{ch}#{@cvss[@cvss_cx..]}"
      @cvss_cx += 1
      @cvss_preedit = ""
      update_severity_from_cvss
    end

    def backspace_cvss : Nil
      return if @cvss_cx == 0
      @cvss = "#{@cvss[0, @cvss_cx - 1]}#{@cvss[@cvss_cx..]}"
      @cvss_cx -= 1
      update_severity_from_cvss
    end

    def move_cvss(d : Int32) : Nil
      @cvss_cx = (@cvss_cx + d).clamp(0, @cvss.size)
    end

    private def update_severity_from_cvss : Nil
      if s = Gori::Cvss.severity_for(@cvss)
        @severity = s
      end
    end

    def set_preedit(text : String) : Nil
      if @sel == ROW_CVSS
        @cvss_preedit = text
      else
        focus_title unless text.empty?
        @preedit = text
      end
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
      w = {area.w - 4, 66}.min
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

      # CVSS row
      screen.text(box.x + 2, box.y + CVSS_ROW, CVSS_PREFIX, on_cvss ? Theme.accent : Theme.muted, Theme.panel)
      btn_w = Screen.draw_width(CVSS_CALC_BTN)
      btn_x = box.right - btn_w - 2
      screen.text(btn_x, box.y + CVSS_ROW, CVSS_CALC_BTN, on_cvss ? Theme.accent : Theme.muted, Theme.panel)

      cw = btn_x - cvss_base(box) - 1
      if on_cvss
        if @cvss.empty? && @cvss_preedit.empty?
          screen.text(cvss_base(box), box.y + CVSS_ROW, "optional (or ^C)", Theme.muted, Theme.panel)
        end
        screen.input_line(cvss_base(box), box.y + CVSS_ROW, @cvss, @cvss_cx, @cvss_preedit,
          Theme.text_bright, Theme.panel, width: cw)
      else
        if @cvss.empty?
          screen.text(cvss_base(box), box.y + CVSS_ROW, "(optional)", Theme.muted, Theme.panel)
        else
          screen.text(cvss_base(box), box.y + CVSS_ROW, @cvss, Theme.text, Theme.panel, width: {cw, 0}.max)
        end
      end
      if !@cvss.empty? && (score = Gori::Cvss.score_for(@cvss))
        tag = "(#{score} #{@severity.label.capitalize})"
        tag_x = btn_x - tag.size - 2
        if tag_x > cvss_base(box) + @cvss.size + 1
          screen.text(tag_x, box.y + CVSS_ROW, tag, sev_color(@severity), Theme.panel)
        end
      end

      # Severity row
      sx = screen.text(box.x + 2, box.y + SEV_ROW, SEV_PREFIX, on_sev ? Theme.accent : Theme.muted, Theme.panel)
      sx = screen.text(sx, box.y + SEV_ROW, @severity.label.upcase, sev_color(@severity), Theme.panel, Attribute::Bold)
      screen.text(sx, box.y + SEV_ROW, on_sev ? SEV_SUFFIX : SEV_SUFFIX_BLUR, Theme.muted, Theme.panel,
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
