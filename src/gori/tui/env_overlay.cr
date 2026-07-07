require "./screen"
require "./theme"
require "./frame"
require "./highlight"
require "../settings"
require "../env"

module Gori::Tui
  # Global environment-variable editor (settings:env). Edits a working copy of the
  # prefix sigil + {key, value} pairs; the Runner persists to Settings on every
  # mutation. Entry form: "KEY VALUE" or "KEY=value".
  class EnvOverlay
    def initialize
      @items = [] of {String, String}
      @prefix = Settings.env_prefix
      @selected = 0
      @adding = false
      @prefix_editing = false
      @edit_index = nil.as(Int32?)
      @input = ""
      @icx = 0
      @preedit = ""
      reset
    end

    def reset : Nil
      @items = Settings.env_vars.dup
      @prefix = Settings.env_prefix
      @selected = 0
      cancel_add
      cancel_prefix_edit
    end

    def to_config : {String, Array({String, String})}
      {@prefix, @items}
    end

    def adding? : Bool
      @adding
    end

    def prefix_editing? : Bool
      @prefix_editing
    end

    def select_move(d : Int32) : Nil
      return if @prefix_editing || @adding
      @selected = (@selected + d).clamp(0, {@items.size - 1, 0}.max)
    end

    def set_selected(idx : Int32) : Nil
      @selected = idx.clamp(0, {@items.size - 1, 0}.max)
    end

    def prefix_edit_start : Nil
      cancel_add
      @prefix_editing = true
      @input = @prefix
      @icx = @input.size
      @preedit = ""
    end

    def cancel_prefix_edit : Nil
      @prefix_editing = false
      @input = ""
      @icx = 0
      @preedit = ""
    end

    def add_start : Nil
      cancel_prefix_edit
      @adding = true
      @edit_index = nil
      @input = ""
      @icx = 0
      @preedit = ""
    end

    def edit_start : Nil
      return if @items.empty?
      key, val = @items[@selected]
      cancel_prefix_edit
      @adding = true
      @edit_index = @selected
      @input = "#{key} #{val}"
      @icx = @input.size
      @preedit = ""
    end

    def cancel_add : Nil
      @adding = false
      @edit_index = nil
      @input = ""
      @icx = 0
      @preedit = ""
    end

    def input(ch : Char) : Nil
      @input = "#{@input[0, @icx]}#{ch}#{@input[@icx..]}"
      @icx += 1
      @preedit = ""
    end

    def backspace : Bool
      return false if @icx == 0
      @input = "#{@input[0, @icx - 1]}#{@input[@icx..]}"
      @icx -= 1
      true
    end

    def move_cursor(d : Int32) : Nil
      @icx = (@icx + d).clamp(0, @input.size)
    end

    def set_preedit(text : String) : Nil
      @preedit = text
    end

    def commit_prefix : Symbol
      text = @input.strip
      return :empty if text.empty?
      @prefix = text
      cancel_prefix_edit
      :ok
    end

    def commit : Symbol
      text = @input.strip
      return :empty if text.empty?
      parsed = Env.parse_line(text)
      return :invalid unless parsed
      key, val = parsed
      idx = @edit_index
      return :dup if @items.each_with_index.any? { |(k, _), i| k == key && i != idx }
      if idx
        @items[idx] = {key, val}
        @selected = idx
      else
        @items << {key, val}
        @selected = @items.size - 1
      end
      cancel_add
      :ok
    end

    def delete_selected : String?
      return nil if @items.empty?
      key, _ = @items[@selected]
      @items.delete_at(@selected)
      @selected = @selected.clamp(0, {@items.size - 1, 0}.max)
      key
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 56}.min
      rows = {@items.size + (@adding ? 1 : 0) + (@prefix_editing ? 1 : 0), 6}.max
      h = {area.h - 2, rows + 4}.min
      return nil if w < 28 || h < 8
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    private def list_capacity(box : Rect) : Int32
      {box.bottom - 1 - (box.y + 3), 0}.max
    end

    private def list_window(cap : Int32) : Int32
      return 0 if cap <= 0 || @items.size <= cap
      { {@selected - cap + 1, 0}.max, @items.size - cap }.min
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "env editor needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, "ENVIRONMENT", border: Theme.border_focus)
      meta = "#{@items.size} var#{@items.size == 1 ? "" : "s"}"
      screen.text({box.right - meta.size - 2, box.x + 16}.max, box.y, meta, Theme.muted, Theme.panel)
      draw_prefix_row(screen, box, box.y + 1)
      screen.text(box.x + 3, box.y + 2, "KEY VALUE · e.g. HOST api.example.com", Theme.muted, Theme.panel, width: {box.w - 5, 1}.max)

      cap = list_capacity(box)
      y = box.y + 3
      rows = cap
      if @adding
        draw_add_row(screen, box, y)
        y += 1
        rows -= 1
      end
      return if rows <= 0
      if @items.empty?
        screen.text(box.x + 3, y, "(no vars — a to add)", Theme.muted) unless @adding
        return
      end
      start = list_window(rows)
      rows.times do |row|
        i = start + row
        break if i >= @items.size
        draw_row(screen, box, i, y + row)
      end
    end

    private def draw_prefix_row(screen : Screen, box : Rect, py : Int32) : Nil
      bg = @prefix_editing ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      x = box.x + 3
      if @prefix_editing
        x = screen.text(x, py, "prefix ", Theme.accent, bg)
        w = {box.right - 1 - x, 3}.max
        screen.input_line(x, py, @input, @icx, @preedit, Theme.text_bright, bg, width: w)
      else
        screen.text(x, py, "prefix ", Theme.muted, bg)
        screen.text(x + 7, py, @prefix, Theme.text_bright, bg, width: {box.right - x - 8, 1}.max)
        hint = "p edit"
        screen.text({box.right - hint.size - 3, x + 8}.max, py, hint, Theme.muted, bg)
      end
    end

    private def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil
      key, val = @items[i]
      sel = i == @selected && !@adding && !@prefix_editing
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)
      kw = {box.w * 2 // 5, 8}.max
      screen.text(box.x + 3, py, key, Theme.syn_header, bg, width: kw)
      ax = box.x + 3 + kw
      screen.text(ax, py, "→ ", Theme.muted, bg) if box.right - 1 > ax
      vx = ax + 2
      draw_env_value(screen, vx, py, val, sel, bg, {box.right - 1 - vx, 1}.max)
    end

    private def draw_env_value(screen : Screen, x : Int32, y : Int32, val : String, sel : Bool, bg : Color, width : Int32) : Nil
      return if width <= 0
      line = Highlight.env_line(val, Theme.text)
      Highlight.draw(screen, x, y, line, width: width)
    end

    private def draw_add_row(screen : Screen, box : Rect, py : Int32) : Nil
      bg = Theme.accent_bg
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      x = box.x + 3
      x = screen.text(x, py, @edit_index ? "edit " : "add ", Theme.accent, bg)
      w = {box.right - 1 - x, 3}.max
      screen.input_line(x, py, @input, @icx, @preedit, Theme.text_bright, bg, width: w)
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      cap = list_capacity(box)
      row = my - (box.y + 3)
      return nil if row < 0 || row >= cap
      row -= 1 if @adding
      return nil if row < 0
      i = list_window({cap - (@adding ? 1 : 0), 0}.max) + row
      i < @items.size ? i : nil
    end
  end
end
