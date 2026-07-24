require "./screen"
require "./theme"
require "./frame"
require "./text_field"
require "./overlay"
require "../scope"

module Gori::Tui
  # Popup form for adding or editing ONE Project SCOPE rule — same interaction
  # model as MineConfigOverlay / FuzzSetOverlay:
  #   ↑/↓  field (kind → type → pattern → Save)
  #   ←/→  cycle kind or type when that row is selected
  #   type into Pattern when focused; ↵ on Save (or last field) commits
  #   esc cancels
  #
  # First modal migrated onto the polymorphic Overlay seam (see overlay.cr): the Runner
  # dispatches key/click/wheel/preedit/render/title/hint to it generically, and the SCOPE
  # apply is injected as `on_commit` at the open-site (Runner#open_scope_rule_editor).
  class ScopeRuleOverlay < Overlay
    getter edit_id : Int64?

    def initialize(*, kind : String = "include", match_type : String = "host",
                   pattern : String = "", @edit_id : Int64? = nil)
      @kind_idx = Scope::KINDS.index(kind) || 0
      @type_idx = Scope::TYPES.index(match_type) || 0
      @pattern = TextField.new(pattern)
      @sel = 0 # 0 kind · 1 type · 2 pattern · 3 save
    end

    def self.adding : ScopeRuleOverlay
      new
    end

    def self.editing(id : Int64, kind : String, match_type : String, pattern : String) : ScopeRuleOverlay
      new(kind: kind, match_type: match_type, pattern: pattern, edit_id: id)
    end

    def kind : String
      Scope::KINDS[@kind_idx]
    end

    def match_type : String
      Scope::TYPES[@type_idx]
    end

    def pattern : String
      @pattern.value.strip
    end

    def editing? : Bool
      !@edit_id.nil?
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : Symbol
      :scope_rule
    end

    def title : String
      "SCOPE RULE"
    end

    def hint : String
      "↑/↓ field · ←/→ kind·type · type pattern · ↵ save · esc cancel"
    end

    # Click a field row to select it; a click on Save commits; a click outside the card
    # cancels. Mirrors the ↑/↓ + ↵ keyboard model.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      if idx = row_at(box, mx, my)
        set_selected(idx)
        return :commit if on_save_row?
      end
      :stay
    end

    private def row_count : Int32
      4
    end

    def on_save_row? : Bool
      @sel == 3
    end

    private def on_pattern_row? : Bool
      @sel == 2
    end

    def move(d : Int32) : Nil
      @sel = (@sel + d).clamp(0, row_count - 1)
    end

    def set_selected(idx : Int32) : Nil
      @sel = idx.clamp(0, row_count - 1)
    end

    def adjust(d : Int32) : Nil
      case @sel
      when 0 then @kind_idx = (@kind_idx + d) % Scope::KINDS.size
      when 1 then @type_idx = (@type_idx + d) % Scope::TYPES.size
      end
    end

    # :stay | :commit | :cancel
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      return :cancel if key.escape?
      if key.up?
        move(-1)
        return :stay
      elsif key.down?
        move(1)
        return :stay
      elsif key.tab?
        move(1)
        return :stay
      elsif key.back_tab?
        move(-1)
        return :stay
      end

      case @sel
      when 0, 1 # kind / type cyclers
        if key.left?
          adjust(-1)
        elsif key.right?
          adjust(1)
        elsif key.enter? || key.space?
          move(1)
        end
        :stay
      when 2 # pattern text field
        if key.enter?
          return :commit
        elsif key.up?
          move(-1)
        elsif key.down?
          move(1)
        else
          @pattern.handle_edit_key(ev)
        end
        :stay
      else # save row
        if key.enter? || key.space?
          :commit
        else
          :stay
        end
      end
    end

    def set_preedit(text : String) : Nil
      @pattern.set_preedit(text) if on_pattern_row?
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 52}.min
      h = {area.h - 2, 11}.min # title + 4 rows + padding
      return nil if w < 28 || h < 8
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "scope form needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      title = editing? ? "EDIT SCOPE RULE" : "ADD SCOPE RULE"
      Frame.card(screen, box, title, border: Theme.border_focus)
      first = box.y + 2
      row_count.times do |i|
        py = first + i
        break if py >= box.bottom - 1
        draw_row(screen, box, i, py)
      end
      # Footer hint
      hint_y = box.bottom - 1
      if hint_y > first
        screen.text(box.x + 2, hint_y, "↑/↓ field · ←/→ kind·type · ↵ save · esc cancel",
          Theme.muted, Theme.panel, width: box.w - 4)
      end
    end

    private def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil
      sel = i == @sel
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)
      x = box.x + 3
      fg = sel ? Theme.text_bright : Theme.text
      case i
      when 0
        screen.text(x, py, "kind:", Theme.muted, bg)
        screen.text(x + 6, py, "#{kind}  ‹/›", fg, bg)
      when 1
        screen.text(x, py, "type:", Theme.muted, bg)
        # Show all types; the current one is bold (and bright when the row is selected)
        tx = x + 6
        Scope::TYPES.each_with_index do |t, ti|
          lit = ti == @type_idx
          col = lit ? (sel ? Theme.text_bright : Theme.accent) : Theme.muted
          tx = screen.text(tx, py, " #{t} ", col, bg, lit ? Attribute::Bold : Attribute::None)
        end
        screen.text(tx, py, " ‹/›", Theme.muted, bg)
      when 2
        screen.text(x, py, "pattern:", Theme.muted, bg)
        vx = x + 9
        vw = {box.right - 2 - vx, 3}.max
        val = @pattern.value
        pre = @pattern.preedit
        shown = pre.empty? ? val : "#{val[0, @pattern.caret]}#{pre}#{val[@pattern.caret..]}"
        screen.text(vx, py, shown, fg, bg, width: vw)
        if sel
          # block caret
          cx = @pattern.caret.clamp(0, val.size)
          px = vx + Screen.draw_width(val[0, cx])
          if px < box.right - 2
            ch = cx < val.size ? val[cx] : ' '
            screen.cell(px, py, ch, Theme.bg, Theme.accent_bg)
            screen.cursor(px, py)
          end
        end
      else
        ok = !pattern.empty? && Scope.valid?(match_type, pattern)
        label = ok ? "[ Save rule ]" : "[ enter a valid pattern ]"
        screen.text(x, py, label, ok ? Theme.accent : Theme.muted, bg, Attribute::Bold)
      end
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      i = my - (box.y + 2)
      (0 <= i < row_count) ? i : nil
    end
  end
end
