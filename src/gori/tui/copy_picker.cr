require "./screen"
require "./theme"
require "./frame"
require "./fmt"
require "./copy_menu"

module Gori::Tui
  # A small centered picker for the "copy as X" action (space → Y): pick which slice
  # of the focused HTTP message to copy — url / headers / body / cookies / curl / raw.
  # Structurally a twin of ChoicePicker (pure state + rendering; the Runner owns
  # open/close and performs the clipboard write), but each row carries the payload
  # `text` outright and shows its byte size rather than a "current" marker — there's
  # no persisted value here, just a one-shot copy. Rows are fronted by a mnemonic key.
  class CopyPicker
    getter selected : Int32
    getter title : String

    def initialize(@title : String, @options : Array(CopyMenu::Option))
      @selected = 0
      @scroll = 0
    end

    def empty? : Bool
      @options.empty?
    end

    def move(delta : Int32) : Nil
      return if @options.empty?
      @selected = (@selected + delta).clamp(0, @options.size - 1)
    end

    def selected_option : CopyMenu::Option?
      @options[@selected]?
    end

    def set_selected(idx : Int32) : Nil
      return if @options.empty?
      @selected = idx.clamp(0, @options.size - 1)
    end

    # The row whose mnemonic matches `c` (case-insensitive), or nil for a miss.
    def index_for(c : Char) : Int32?
      lc = c.downcase
      @options.index { |o| o.key.downcase == lc }
    end

    # Centered card geometry over `area` — inverse of render's offset math. nil when
    # render would draw nothing (mirrors the w/h guard). Width leaves room for the
    # right-aligned size hint.
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, content_w + 10}.min
      h = {@options.size + 2, area.h - 2}.min
      return nil if w < 18 || area.h < 5
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      Rect.new(x, y, w, h)
    end

    # Row index under (mx,my), mirroring render's list loop; nil outside. Bound to
    # the ACTUALLY rendered rows so a click on a height-clamped card's bottom border
    # can't pick a row that was never drawn.
    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      rows = {box.h - 2, @options.size}.min
      i = my - (box.y + 1)
      return nil if i < 0 || i >= rows
      return nil if mx <= box.x || mx >= box.right - 1
      ci = @scroll + i
      ci < @options.size ? ci : nil
    end

    private def ensure_visible(rows : Int32) : Nil
      return if rows <= 0
      @scroll = @selected if @selected < @scroll
      @scroll = @selected - rows + 1 if @selected >= @scroll + rows
      @scroll = @scroll.clamp(0, {@options.size - rows, 0}.max)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "picker needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, @title, border: Theme.border_focus)
      rows = {box.h - 2, @options.size}.min
      ensure_visible(rows)
      (0...rows).each do |i|
        ci = @scroll + i
        break if ci >= @options.size
        o = @options[ci]
        ry = box.y + 1 + i
        active = ci == @selected
        bg = active ? Theme.accent_bg : Theme.panel
        screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
        screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)
        screen.text(box.x + 3, ry, o.key.to_s, Theme.accent, bg, Attribute::Bold)
        screen.text(box.x + 6, ry, o.label, active ? Theme.text_bright : Theme.text, bg, Attribute::Bold)
        size = Fmt.size(o.text.bytesize.to_i64)
        screen.text(box.right - size.size - 2, ry, size, Theme.muted, bg)
      end
    end

    # Widest row (label + size hint), driving the card width.
    private def content_w : Int32
      @options.max_of { |o| o.label.size + Fmt.size(o.text.bytesize.to_i64).size + 4 }
    end
  end
end
