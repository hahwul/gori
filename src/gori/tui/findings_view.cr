require "./screen"
require "./theme"
require "./frame"
require "./text_area"
require "../store"

module Gori::Tui
  # The Findings tab (DESIGN.md: the final output — human-confirmed vulns). A
  # severity-sorted list + a detail with inline-editable notes and a severity
  # control. Created from a flow (History `F`) or blank (`n`).
  class FindingsView
    def initialize
      @findings = [] of Store::Finding
      @selected = 0
      @scroll = 0
      @detail = nil.as(Store::Finding?)
      @detail_flow = nil.as(Store::FlowRow?)
      @detail_scroll = 0
      @editing_notes = false
      @notes = TextArea.new
      @loaded = false
    end

    def reload(store : Store) : Nil
      @findings = store.findings
      @selected = @selected.clamp(0, {@findings.size - 1, 0}.max)
      @loaded = true
    end

    def move(delta : Int32) : Nil
      return if @findings.empty?
      @selected = (@selected + delta).clamp(0, @findings.size - 1)
    end

    def detail_open? : Bool
      !@detail.nil?
    end

    def editing_notes? : Bool
      @editing_notes
    end

    def open_detail(store : Store) : Bool
      finding = @findings[@selected]?
      return false unless finding
      @detail = finding
      @detail_flow = finding.flow_id.try { |fid| store.flow_row(fid) }
      @detail_scroll = 0
      @editing_notes = false
      true
    end

    def close_detail : Nil
      @detail = nil
      @editing_notes = false
    end

    def severity_delta(delta : Int32, store : Store) : Nil
      finding = @detail
      return unless finding
      level = (finding.severity.value + delta).clamp(0, 4)
      store.update_finding(finding.id, severity: Store::Severity.new(level))
      refresh_detail(store)
    end

    def delete(store : Store) : Nil
      if finding = @detail
        store.delete_finding(finding.id)
        close_detail
      elsif finding = @findings[@selected]?
        store.delete_finding(finding.id)
      end
      reload(store)
    end

    # --- notes inline editing ---
    def start_notes_edit : Nil
      return unless finding = @detail
      @notes.set_text(finding.notes)
      @editing_notes = true
    end

    def notes_insert(ch : Char) : Nil
      @notes.insert(ch) if @editing_notes
    end

    def notes_newline : Nil
      @notes.insert_newline if @editing_notes
    end

    def notes_backspace : Nil
      @notes.backspace if @editing_notes
    end

    def notes_move(dr : Int32, dc : Int32) : Nil
      @notes.move(dr, dc) if @editing_notes
    end

    def save_notes(store : Store) : Nil
      return unless finding = @detail
      store.update_finding(finding.id, notes: String.new(@notes.to_bytes))
      @editing_notes = false
      refresh_detail(store)
    end

    # --- rendering -----------------------------------------------------------

    def render(screen : Screen, rect : Rect, focused : Bool = true) : Nil
      return if rect.empty?
      @detail ? render_detail(screen, rect, focused) : render_list(screen, rect, focused)
    end

    private def render_list(screen : Screen, rect : Rect, focused : Bool) : Nil
      screen.text(rect.x + 1, rect.y, "SEVERITY", Theme::MUTED)
      screen.text(rect.x + 11, rect.y, "TITLE", Theme::MUTED)
      Frame.inner_divider(screen, rect, rect.y + 1, border: Frame.pane_border(focused))
      top = rect.y + 2
      list_h = {rect.bottom - top, 0}.max

      if @findings.empty?
        screen.text(rect.x + 1, top, "no findings yet · select a flow and press F to add one", Theme::MUTED)
        return
      end

      ensure_visible(list_h)
      (0...list_h).each do |i|
        idx = @scroll + i
        break if idx >= @findings.size
        f = @findings[idx]
        y = top + i
        selected = idx == @selected
        bg = selected ? (focused ? Theme::ACCENT_BG : Theme::SELECTION_DIM) : Theme::BG
        if selected
          screen.fill(Rect.new(rect.x, y, rect.w, 1), bg)
          screen.cell(rect.x, y, '▎', Theme::ACCENT, bg)
        end
        screen.text(rect.x + 1, y, severity_badge(f.severity), severity_color(f.severity), bg, Attribute::Bold)
        title_fg = selected ? Theme::TEXT_BRIGHT : Theme::TEXT
        screen.text(rect.x + 11, y, f.title, title_fg, bg, width: rect.w - 24)
        screen.text(rect.right - (f.host || "").size - 1, y, f.host || "", Theme::MUTED, bg) if f.host
      end
    end

    private def render_detail(screen : Screen, rect : Rect, focused : Bool) : Nil
      finding = @detail.not_nil!
      screen.text(rect.x + 1, rect.y, severity_badge(finding.severity), severity_color(finding.severity), attr: Attribute::Bold)
      screen.text(rect.x + 11, rect.y, finding.title, Theme::TEXT_BRIGHT, width: rect.w - 12)
      hint = @editing_notes ? "esc: stop editing notes" : "[ ] severity · e notes · d delete · ←/esc back"
      screen.text(rect.x + 1, rect.y + 1, hint, Theme::MUTED)
      if flow = @detail_flow
        screen.text(rect.x + 1, rect.y + 2, "flow: #{flow.method} #{flow.host}#{flow.target} → #{flow.status || "-"}", Theme::MUTED)
      end
      Frame.inner_divider(screen, rect, rect.y + 3, border: Frame.pane_border(focused))
      screen.text(rect.x + 1, rect.y + 4, "NOTES", Theme::ACCENT, attr: Attribute::Bold)
      notes_rect = Rect.new(rect.x + 1, rect.y + 5, {rect.w - 2, 0}.max, {rect.bottom - (rect.y + 5), 0}.max)
      if @editing_notes
        @notes.render(screen, notes_rect, cursor: focused)
      else
        finding.notes.split('\n').each_with_index do |line, i|
          break if rect.y + 5 + i >= rect.bottom
          screen.text(notes_rect.x, notes_rect.y + i, line, Theme::TEXT, width: notes_rect.w)
        end
      end
    end

    private def refresh_detail(store : Store) : Nil
      if finding = @detail
        @detail = store.get_finding(finding.id)
      end
      reload(store)
    end

    private def severity_badge(s : Store::Severity) : String
      case s
      when .critical? then "CRIT"
      when .high?     then "HIGH"
      when .medium?   then "MED"
      when .low?      then "LOW"
      else                 "INFO"
      end
    end

    private def severity_color(s : Store::Severity) : Color
      case s
      when .critical? then Theme::RED
      when .high?     then Theme::ORANGE
      when .medium?   then Theme::YELLOW
      when .low?      then Theme::ACCENT
      else                 Theme::MUTED
      end
    end

    private def ensure_visible(h : Int32) : Nil
      return if h <= 0
      @scroll = @selected if @selected < @scroll
      @scroll = @selected - h + 1 if @selected >= @scroll + h
      @scroll = 0 if @scroll < 0
    end
  end

  # A one-field overlay to create a finding (title); severity defaults to Medium
  # and is refined in the detail. Carries the linking flow's host/id when opened
  # from History.
  class FindingForm
    getter title : String
    getter host : String?
    getter flow_id : Int64?

    def initialize(@title : String = "", @host : String? = nil, @flow_id : Int64? = nil)
      @cx = @title.size
    end

    def insert(ch : Char) : Nil
      @title = "#{@title[0, @cx]}#{ch}#{@title[@cx..]}"
      @cx += 1
    end

    def backspace : Nil
      return if @cx == 0
      @title = "#{@title[0, @cx - 1]}#{@title[@cx..]}"
      @cx -= 1
    end

    def move(d : Int32) : Nil
      @cx = (@cx + d).clamp(0, @title.size)
    end

    def set_preedit(text : String) : Nil
      @title = text
      @cx = text.size
    end


    def render(screen : Screen, area : Rect) : Nil
      w = {area.w - 4, 56}.min
      h = 5
      return if w < 12 || area.h < h
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      box = Rect.new(x, y, w, h)
      Frame.card(screen, box, "NEW FINDING", border: Theme::BORDER_FOCUS)
      prefix = "title › "
      screen.text(box.x + 2, box.y + 2, prefix, Theme::ACCENT, Theme::PANEL)
      base = box.x + 2 + prefix.size
      screen.text(base, box.y + 2, @title, Theme::TEXT_BRIGHT, Theme::PANEL, width: w - prefix.size - 4)
      ch = @cx < @title.size ? @title[@cx] : ' '
      cursor_x = base + Screen.display_width(@title[0, @cx])
      screen.cell(cursor_x, box.y + 2, ch, Theme::BG, Theme::ACCENT)

    end
  end
end
