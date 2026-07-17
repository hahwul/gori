require "./screen"
require "./theme"
require "./frame"
require "./text_field"
require "../store"
require "../store/safe_regexp"

module Gori::Tui
  # Popup form to add or edit ONE Rewriter (Match & Replace) rule. Same interaction model
  # as CustomRuleOverlay / ScopeRuleOverlay:
  #   ↑/↓ or ↹   move between fields
  #   ←/→         cycle the selected option row (target / op / match / part)
  #   type        edit the focused text row (name / host / find / value)
  #   ↵           advance a text row (↵ on value or Save commits) · esc cancels
  # The runner refreshes a live match PREVIEW after each key and persists on :commit
  # through the shared Rules engine (which the proxy reads live).
  class RewriterRuleOverlay
    ROW_NAME   = 0
    ROW_TARGET = 1
    ROW_OP     = 2
    ROW_MATCH  = 3
    ROW_PART   = 4
    ROW_HOST   = 5
    ROW_FIND   = 6
    ROW_VALUE  = 7
    ROW_SAVE   = 8
    ROW_COUNT  = 9

    TARGETS   = %w[request response]
    OPS       = %w[replace add_header set_header remove_header]
    OP_LABELS = ["replace", "add header", "set header", "remove header"]
    MATCHES   = %w[literal regex]
    PARTS     = %w[head body]

    getter edit_id : Int64?

    @target_i : Int32
    @op_i : Int32
    @match_i : Int32
    @part_i : Int32
    @sel : Int32
    @preview : String = ""

    def initialize(*, name : String = "", target : String = "request", op : String = "replace",
                   match : String = "literal", part : String = "head", host : String = "",
                   pattern : String = "", replacement : String = "", @edit_id : Int64? = nil)
      @fields = {
        name:    TextField.new(name),
        host:    TextField.new(host),
        pattern: TextField.new(pattern),
        value:   TextField.new(replacement),
      }
      @target_i = idx(TARGETS, target)
      @op_i = idx(OPS, op)
      @match_i = idx(MATCHES, match)
      @part_i = idx(PARTS, part)
      @sel = 0
    end

    def self.adding : RewriterRuleOverlay
      new
    end

    def self.editing(rule : Store::MatchRule) : RewriterRuleOverlay
      new(name: rule.name, target: rule.target.label, op: rule.op.label,
        match: rule.match_kind.label, part: rule.part.label, host: rule.host,
        pattern: rule.pattern, replacement: rule.replacement, edit_id: rule.id)
    end

    private def idx(list : Array(String), v : String) : Int32
      list.index(v) || 0
    end

    def editing? : Bool
      !@edit_id.nil?
    end

    def name : String
      @fields[:name].value.strip
    end

    def host : String
      @fields[:host].value.strip
    end

    def pattern : String
      @fields[:pattern].value.strip
    end

    # The replacement / header value keeps interior + trailing spaces (a header value or
    # a replacement may legitimately contain them).
    def replacement : String
      @fields[:value].value
    end

    def target : Store::RuleTarget
      Store::RuleTarget.from_label(TARGETS[@target_i])
    end

    def op : Store::RuleOp
      Store::RuleOp.from_label(OPS[@op_i])
    end

    def match_kind : Store::MatchKind
      Store::MatchKind.from_label(MATCHES[@match_i])
    end

    def part : Store::RulePart
      Store::RulePart.from_label(PARTS[@part_i])
    end

    def header_op? : Bool
      op.header?
    end

    def on_save_row? : Bool
      @sel == ROW_SAVE
    end

    # A pattern is required; a regex replace must additionally compile.
    def valid? : Bool
      return false if pattern.empty?
      return true unless op.replace? && match_kind.regex?
      SafeRegexp.compile(pattern)
      true
    rescue
      false
    end

    def set_preview(text : String) : Nil
      @preview = text
    end

    # The fields a match preview depends on — the runner only rescans when this changes.
    def preview_signature : String
      "#{@target_i}|#{@op_i}|#{@match_i}|#{@part_i}|#{host}|#{pattern}|#{replacement}"
    end

    # The rule as currently edited (id 0 when adding) — used for the live preview.
    def candidate_rule : Store::MatchRule
      Store::MatchRule.new(@edit_id || 0_i64, true, target,
        header_op? ? Store::RulePart::Head : part,
        pattern, replacement, op, match_kind, name, host)
    end

    def move(d : Int32) : Nil
      @sel = (@sel + d).clamp(0, ROW_COUNT - 1)
    end

    def set_selected(idx : Int32) : Nil
      @sel = idx.clamp(0, ROW_COUNT - 1)
    end

    private def cycler_row?(row : Int32) : Bool
      ROW_TARGET <= row <= ROW_PART
    end

    private def text_field_for(row : Int32) : TextField?
      case row
      when ROW_NAME  then @fields[:name]
      when ROW_HOST  then @fields[:host]
      when ROW_FIND  then @fields[:pattern]
      when ROW_VALUE then @fields[:value]
      end
    end

    def adjust(d : Int32) : Nil
      case @sel
      when ROW_TARGET then @target_i = (@target_i + d) % TARGETS.size
      when ROW_OP     then @op_i = (@op_i + d) % OPS.size
      when ROW_MATCH  then @match_i = (@match_i + d) % MATCHES.size
      when ROW_PART   then @part_i = (@part_i + d) % PARTS.size
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
      else # text row
        field = text_field_for(@sel)
        if key.enter?
          return :commit if @sel == ROW_VALUE
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
      w = {area.w - 4, 66}.min
      h = {area.h - 2, ROW_COUNT + 5}.min # title + rows + preview + hint + padding
      return nil if w < 40 || h < 12
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "rewriter-rule form needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      title = editing? ? "EDIT REWRITER RULE" : "ADD REWRITER RULE"
      Frame.card(screen, box, title, border: Theme.border_focus)
      first = box.y + 2
      ROW_COUNT.times do |i|
        py = first + i
        break if py >= box.bottom - 2
        draw_row(screen, box, i, py)
      end
      pv_y = box.bottom - 2
      if pv_y > first && !@preview.empty?
        screen.fill(Rect.new(box.x + 1, pv_y, box.w - 2, 1), Theme.panel)
        screen.text(box.x + 2, pv_y, "▶ #{@preview}", Theme.muted, Theme.panel, width: box.w - 4)
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
      hop = header_op?
      case i
      when ROW_NAME   then draw_field(screen, box, py, bg, fg, sel, "name:", @fields[:name])
      when ROW_TARGET then draw_cycle(screen, x, py, bg, fg, "target:", TARGETS, @target_i, sel)
      when ROW_OP     then draw_cycle(screen, x, py, bg, fg, "op:", OP_LABELS, @op_i, sel)
      when ROW_MATCH  then hop ? draw_na(screen, x, py, bg, "match:") : draw_cycle(screen, x, py, bg, fg, "match:", MATCHES, @match_i, sel)
      when ROW_PART   then hop ? draw_na(screen, x, py, bg, "part:") : draw_cycle(screen, x, py, bg, fg, "part:", PARTS, @part_i, sel)
      when ROW_HOST   then draw_field(screen, box, py, bg, fg, sel, "host:", @fields[:host])
      when ROW_FIND   then draw_field(screen, box, py, bg, fg, sel, hop ? "header:" : "find:", @fields[:pattern])
      when ROW_VALUE  then draw_field(screen, box, py, bg, fg, sel, value_label, @fields[:value])
      else
        ok = valid?
        label = ok ? "[ Save rule ]" : "[ enter a #{header_op? ? "header name" : "pattern"} ]"
        screen.text(x, py, label, ok ? Theme.accent : Theme.muted, bg, Attribute::Bold)
      end
    end

    private def value_label : String
      case op
      when .add_header?, .set_header? then "value:"
      when .remove_header?            then "value: (n/a)"
      else                                 "replace:"
      end
    end

    private def draw_na(screen : Screen, x : Int32, py : Int32, bg : Color, label : String) : Nil
      screen.text(x, py, label, Theme.muted, bg)
      screen.text(x + label.size + 1, py, "n/a (header op)", Theme.muted, bg)
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
