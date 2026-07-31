require "./screen"
require "./theme"
require "./frame"
require "./text_field"
require "./overlay"
require "../store"
require "../token_extract"

module Gori::Tui
  # Popup form to add or edit ONE extract rule — the READ half of a session binding (#501).
  # Same interaction model as RewriterRuleOverlay, deliberately: the two live one sub-tab
  # apart on the Rewriter body, and an operator who learned one form should not have to
  # learn the other.
  #
  #   ↑/↓ or ↹   move between fields
  #   ←/→         cycle the descriptor kind
  #   type        edit the focused text row (name / when / selector / range / host)
  #   ↵           advance a text row (↵ on the last one or Save commits) · esc cancels
  #
  # Two sections, and the split is the whole model: MATCH says which messages this rule
  # reads (`when:` — an `InterceptFilter` source, the same boolean grammar the conditional
  # intercept bar uses, plus a `host:` glob in `match_rules`' dialect), and EXTRACT says
  # where in one of them the value lives (`Gori::TokenLoc`, the Sequencer's five descriptors).
  #
  # Store-free like its sibling: the duplicate-name / bad-regex refusal is INJECTED at the
  # open-site (`on_validate`), because "is `$SESSION` already written by another rule" is a
  # question only the live binding table can answer.
  class ExtractRuleOverlay < Overlay
    ROW_NAME     = 0
    ROW_WHEN     = 1
    ROW_HOST     = 2
    ROW_KIND     = 3
    ROW_SELECTOR = 4
    # `position` only: the half-open byte range over the decoded body, as `start:end`.
    ROW_RANGE = 5
    ROW_SAVE  = 6
    ROW_COUNT = 7

    KINDS = Gori::ExtractKind.values

    getter edit_id : Int64?

    # Returns the refusal for the rule as currently edited, or nil when it may be saved.
    # Injected because it needs the binding table (one name, one writer).
    property on_validate : Proc(ExtractRuleOverlay, String?)?

    @kind_i : Int32
    @sel : Int32

    def initialize(*, name : String = "", match_filter : String = "", host : String = "",
                   kind : Gori::ExtractKind = Gori::ExtractKind::Cookie, selector : String = "",
                   pos_start : Int32 = 0, pos_end : Int32 = 0, @edit_id : Int64? = nil)
      @fields = {
        name:     TextField.new(name),
        filter:   TextField.new(match_filter),
        host:     TextField.new(host),
        selector: TextField.new(selector),
        range:    TextField.new(pos_end > 0 ? "#{pos_start}:#{pos_end}" : ""),
      }
      @kind_i = KINDS.index(kind) || 0
      @sel = 0
    end

    def self.adding : ExtractRuleOverlay
      new
    end

    def self.editing(rule : Store::ExtractRule) : ExtractRuleOverlay
      new(name: rule.name, match_filter: rule.match_filter, host: rule.host,
        kind: rule.kind, selector: rule.selector,
        pos_start: rule.pos_start, pos_end: rule.pos_end, edit_id: rule.id)
    end

    def editing? : Bool
      !@edit_id.nil?
    end

    # The `$` is stripped so an operator can type the token the way they read it. Nothing
    # else about the name is repaired here — `Bindings#validate` names what is wrong.
    def name : String
      raw = @fields[:name].value.strip
      raw.starts_with?('$') ? raw[1..] : raw
    end

    def match_filter : String
      @fields[:filter].value.strip
    end

    def host : String
      @fields[:host].value.strip
    end

    def selector : String
      @fields[:selector].value.strip
    end

    def kind : Gori::ExtractKind
      KINDS[@kind_i]
    end

    def position? : Bool
      kind.position?
    end

    def pos_start : Int32
      parse_range[0]
    end

    def pos_end : Int32
      parse_range[1]
    end

    private def parse_range : {Int32, Int32}
      raw = @fields[:range].value.strip
      a, _, b = raw.partition(':')
      {a.to_i32? || 0, b.to_i32? || 0}
    end

    # A descriptor row the CURRENT kind has no meaning for is skipped by ↑/↓, so the caret
    # never parks on a field that does nothing — same rule RewriterRuleOverlay applies to
    # its two body-source rows.
    private def skip_row?(row : Int32) : Bool
      position? ? row == ROW_SELECTOR : row == ROW_RANGE
    end

    def on_save_row? : Bool
      @sel == ROW_SAVE
    end

    def valid? : Bool
      invalid_reason.nil?
    end

    # What is missing, for the Save row's label. Local shape checks first (they need no
    # injection), then the table's own refusal.
    def invalid_reason : String?
      return "enter a binding name" if name.empty?
      if position?
        a, b = parse_range
        return "enter a byte range like 0:32" if b <= a
      elsif selector.empty?
        return "enter a #{kind.label} selector"
      end
      @on_validate.try(&.call(self))
    end

    def move(d : Int32) : Nil
      step = d < 0 ? -1 : 1
      nxt = @sel
      loop do
        probe = nxt + step
        break if probe < 0 || probe > ROW_COUNT - 1
        nxt = probe
        break unless skip_row?(nxt)
      end
      @sel = nxt unless skip_row?(nxt)
    end

    def set_selected(idx : Int32) : Nil
      idx = idx.clamp(0, ROW_COUNT - 1)
      @sel = idx unless skip_row?(idx)
    end

    def adjust(d : Int32) : Nil
      return unless @sel == ROW_KIND
      @kind_i = (@kind_i + d) % KINDS.size
      # The kind decides which of selector/range is live; if the caret is now on the dead
      # one, walk it forward rather than leaving it parked there.
      move(1) if skip_row?(@sel)
    end

    private def text_field_for(row : Int32) : TextField?
      case row
      when ROW_NAME     then @fields[:name]
      when ROW_WHEN     then @fields[:filter]
      when ROW_HOST     then @fields[:host]
      when ROW_SELECTOR then @fields[:selector]
      when ROW_RANGE    then @fields[:range]
      end
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::ExtractRule
    end

    def title : String
      "EXTRACT RULE"
    end

    def hint : String
      "↑/↓ field · ←/→ kind · type when/selector · ↵ save · esc cancel"
    end

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

      if @sel == ROW_KIND
        case
        when key.left?              then adjust(-1)
        when key.right?             then adjust(1)
        when key.enter?, key.space? then move(1)
        end
        :stay
      elsif @sel == ROW_SAVE
        (key.enter? || key.space?) ? :commit : :stay
      else
        field = text_field_for(@sel)
        if key.enter?
          return :commit if @sel == ROW_SELECTOR || @sel == ROW_RANGE
          move(1)
        elsif field
          field.handle_edit_key(ev)
        end
        :stay
      end
    end

    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      if idx = row_at(box, mx, my)
        set_selected(idx)
        return :commit if on_save_row?
      end
      :stay
    end

    def set_preedit(text : String) : Nil
      text_field_for(@sel).try(&.set_preedit(text))
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 72}.min
      h = {area.h - 2, ROW_COUNT + 4}.min # title + rows + hint + padding
      return nil if w < 40 || h < 10
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "extract-rule form needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, editing? ? "EDIT EXTRACT RULE" : "ADD EXTRACT RULE", border: Theme.border_focus)
      first = box.y + 2
      ROW_COUNT.times do |i|
        py = first + i
        break if py >= box.bottom - 1
        draw_row(screen, box, i, py)
      end
      hint_y = box.bottom - 1
      screen.text(box.x + 2, hint_y, hint, Theme.muted, Theme.panel, width: box.w - 4) if hint_y > first
    end

    private def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil
      sel = i == @sel
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)
      x = box.x + 3
      fg = sel ? Theme.text_bright : Theme.text
      case i
      when ROW_NAME then draw_field(screen, box, py, bg, fg, sel, "name: $", @fields[:name])
      when ROW_WHEN then draw_field(screen, box, py, bg, fg, sel, "when:", @fields[:filter])
      when ROW_HOST then draw_field(screen, box, py, bg, fg, sel, "host:", @fields[:host])
      when ROW_KIND then draw_cycle(screen, x, py, bg, fg, "from:", KINDS.map(&.label), @kind_i, sel)
      when ROW_SELECTOR
        draw_field(screen, box, py, bg, fg, sel, selector_label, @fields[:selector]) unless position?
      when ROW_RANGE
        draw_field(screen, box, py, bg, fg, sel, "range:", @fields[:range]) if position?
      else
        reason = invalid_reason
        label = reason ? "[ #{reason} ]" : "[ Save rule ]"
        screen.text(x, py, label, reason ? Theme.muted : Theme.accent, bg, Attribute::Bold)
      end
    end

    private def selector_label : String
      case kind
      in Gori::ExtractKind::Cookie   then "cookie:"
      in Gori::ExtractKind::Header   then "header:"
      in Gori::ExtractKind::Regex    then "regex:"
      in Gori::ExtractKind::JsonPath then "path:"
      in Gori::ExtractKind::Position then "range:"
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
        px = vx + Screen.draw_width(val[0, cx])
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
