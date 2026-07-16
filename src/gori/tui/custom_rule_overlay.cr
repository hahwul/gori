require "./screen"
require "./theme"
require "./frame"
require "./text_field"
require "../store"
require "../store/safe_regexp"
require "../probe/custom_rule"

module Gori::Tui
  # Popup form to add or edit ONE custom Probe match rule (the Rules sub-tab). Same interaction
  # model as ScopeRuleOverlay / FuzzSetOverlay:
  #   ↑/↓ or ↹  move between fields
  #   ←/→        cycle the selected option row (scope/side/region/match/severity)
  #   type       edit the focused text row (title / description / pattern)
  #   ↵          advance a text row (↵ on pattern or Save commits) · esc cancels
  # The runner validates + persists on :commit (global → settings.json, project → project DB).
  class CustomRuleOverlay
    ROW_TITLE   = 0
    ROW_DESC    = 1
    ROW_SCOPE   = 2
    ROW_SIDE    = 3
    ROW_REGION  = 4
    ROW_KIND    = 5
    ROW_SEV     = 6
    ROW_PATTERN = 7
    ROW_SAVE    = 8
    ROW_COUNT   = 9

    SCOPES  = %w[project global]
    SIDES   = %w[request response]
    REGIONS = %w[whole header body]
    KINDS   = %w[string regex]
    SEVS    = %w[info low medium high critical]

    getter edit_id : String?
    getter edit_scope : String?

    @scope_i : Int32
    @side_i : Int32
    @region_i : Int32
    @kind_i : Int32
    @sev_i : Int32
    @sel : Int32

    def initialize(*, title : String = "", description : String = "", scope : String = "project",
                   side : String = "response", region : String = "body", kind : String = "string",
                   severity : String = "info", pattern : String = "",
                   @edit_id : String? = nil, @edit_scope : String? = nil)
      @fields = {
        title:   TextField.new(title),
        desc:    TextField.new(description),
        pattern: TextField.new(pattern),
      }
      @scope_i = idx(SCOPES, scope)
      @side_i = idx(SIDES, side)
      @region_i = idx(REGIONS, region)
      @kind_i = idx(KINDS, kind)
      @sev_i = idx(SEVS, severity)
      @sel = 0
    end

    def self.adding : CustomRuleOverlay
      new
    end

    def self.editing(rule : Probe::CustomRule) : CustomRuleOverlay
      new(title: rule.title, description: rule.description, scope: rule.scope, side: rule.side,
        region: rule.region, kind: rule.kind, severity: rule.severity.label, pattern: rule.pattern,
        edit_id: rule.id, edit_scope: rule.scope)
    end

    private def idx(list : Array(String), v : String) : Int32
      list.index(v) || 0
    end

    def title : String
      @fields[:title].value.strip
    end

    def description : String
      @fields[:desc].value.strip
    end

    def pattern : String
      @fields[:pattern].value.strip
    end

    def scope : String
      SCOPES[@scope_i]
    end

    def side : String
      SIDES[@side_i]
    end

    def region : String
      REGIONS[@region_i]
    end

    def kind : String
      KINDS[@kind_i]
    end

    def severity : Store::Severity
      Store::Severity.parse?(SEVS[@sev_i]) || Store::Severity::Info
    end

    def editing? : Bool
      !@edit_id.nil?
    end

    def on_save_row? : Bool
      @sel == ROW_SAVE
    end

    # Every required field is present and, for a regex rule, the pattern compiles.
    def valid? : Bool
      return false if title.empty? || description.empty? || pattern.empty?
      return true unless kind == "regex"
      SafeRegexp.compile(pattern)
      true
    rescue
      false
    end

    def move(d : Int32) : Nil
      @sel = (@sel + d).clamp(0, ROW_COUNT - 1)
    end

    def set_selected(idx : Int32) : Nil
      @sel = idx.clamp(0, ROW_COUNT - 1)
    end

    private def cycler_row?(row : Int32) : Bool
      ROW_SCOPE <= row <= ROW_SEV
    end

    private def text_field_for(row : Int32) : TextField?
      case row
      when ROW_TITLE   then @fields[:title]
      when ROW_DESC    then @fields[:desc]
      when ROW_PATTERN then @fields[:pattern]
      end
    end

    def adjust(d : Int32) : Nil
      case @sel
      when ROW_SCOPE  then @scope_i = (@scope_i + d) % SCOPES.size
      when ROW_SIDE   then @side_i = (@side_i + d) % SIDES.size
      when ROW_REGION then @region_i = (@region_i + d) % REGIONS.size
      when ROW_KIND   then @kind_i = (@kind_i + d) % KINDS.size
      when ROW_SEV    then @sev_i = (@sev_i + d) % SEVS.size
      end
    end

    # :stay | :commit | :cancel
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      return :cancel if key.escape?
      if key.up? || key.back_tab?
        move(-1)
        return :stay
      elsif key.down? || key.tab?
        move(1)
        return :stay
      end

      if cycler_row?(@sel)
        case
        when key.left?              then adjust(-1)
        when key.right?             then adjust(1)
        when key.enter?, key.space? then move(1)
        end
        :stay
      elsif @sel == ROW_SAVE
        (key.enter? || key.space?) ? :commit : :stay
      else # text row: title / description / pattern
        field = text_field_for(@sel)
        if key.enter?
          return :commit if @sel == ROW_PATTERN
          move(1)
        elsif field
          field.handle_edit_key(ev)
        end
        :stay
      end
    end

    def set_preedit(text : String) : Nil
      text_field_for(@sel).try(&.set_preedit(text))
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 62}.min
      h = {area.h - 2, ROW_COUNT + 4}.min # title + rows + footer + padding
      return nil if w < 34 || h < 11
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "custom-rule form needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      title = editing? ? "EDIT CUSTOM RULE" : "ADD CUSTOM RULE"
      Frame.card(screen, box, title, border: Theme.border_focus)
      first = box.y + 2
      ROW_COUNT.times do |i|
        py = first + i
        break if py >= box.bottom - 1
        draw_row(screen, box, i, py)
      end
      hint_y = box.bottom - 1
      screen.text(box.x + 2, hint_y, "↑/↓ field · ←/→ options · ↵ save · esc cancel",
        Theme.muted, Theme.panel, width: box.w - 4) if hint_y > first
    end

    private def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil
      sel = i == @sel
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)
      x = box.x + 3
      fg = sel ? Theme.text_bright : Theme.text
      case i
      when ROW_TITLE   then draw_field(screen, box, py, bg, fg, sel, "title:", @fields[:title])
      when ROW_DESC    then draw_field(screen, box, py, bg, fg, sel, "desc:", @fields[:desc])
      when ROW_PATTERN then draw_field(screen, box, py, bg, fg, sel, "pattern:", @fields[:pattern])
      when ROW_SCOPE   then draw_cycle(screen, x, py, bg, fg, "scope:", SCOPES, @scope_i, sel)
      when ROW_SIDE    then draw_cycle(screen, x, py, bg, fg, "side:", SIDES, @side_i, sel)
      when ROW_REGION  then draw_cycle(screen, x, py, bg, fg, "region:", REGIONS, @region_i, sel)
      when ROW_KIND    then draw_cycle(screen, x, py, bg, fg, "match:", KINDS, @kind_i, sel)
      when ROW_SEV     then draw_cycle(screen, x, py, bg, fg, "severity:", SEVS, @sev_i, sel)
      else
        ok = valid?
        label = ok ? "[ Save rule ]" : "[ complete title, description & pattern ]"
        screen.text(x, py, label, ok ? Theme.accent : Theme.muted, bg, Attribute::Bold)
      end
    end

    private def draw_cycle(screen : Screen, x : Int32, py : Int32, bg : Color, fg : Color,
                           label : String, opts : Array(String), sel_i : Int32, row_sel : Bool) : Nil
      screen.text(x, py, label, Theme.muted, bg)
      tx = x + label.size + 1
      opts.each_with_index do |opt, oi|
        lit = oi == sel_i
        col = lit ? (row_sel ? Theme.text_bright : Theme.accent) : Theme.muted
        tx = screen.text(tx, py, " #{opt} ", col, bg, lit ? Attribute::Bold : Attribute::None)
      end
      screen.text(tx, py, " ‹/›", Theme.muted, bg) if row_sel
    end

    private def draw_field(screen : Screen, box : Rect, py : Int32, bg : Color, fg : Color,
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
        px = vx + Screen.column_width(val[0, cx])
        if px < box.right - 2
          ch = cx < val.size ? val[cx] : ' '
          screen.cell(px, py, ch, Theme.bg, Theme.accent_bg)
          screen.cursor(px, py)
        end
      end
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      i = my - (box.y + 2)
      (0 <= i < ROW_COUNT) ? i : nil
    end
  end
end
