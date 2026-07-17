require "./screen"
require "./theme"
require "./frame"
require "./fmt"
require "./send_menu"

module Gori::Tui
  # A small centered picker for the "send selection to X" action (space → S): pick a
  # string-handling destination for the current text selection. Structurally a twin
  # of CopyPicker (pure state + rendering; the Runner owns open/close and performs
  # the send), but every row shares ONE `@payload` (the selection) and differs only
  # by destination — so rows show the target's `hint` (not a per-row byte size), and
  # the card title carries the payload size once. Rows are fronted by a mnemonic key.
  class SendPicker
    getter selected : Int32
    getter title : String
    getter payload : String

    def initialize(@title : String, @payload : String, @destinations : Array(SendMenu::Destination))
      @selected = 0
      @scroll = 0
    end

    def empty? : Bool
      @destinations.empty?
    end

    def move(delta : Int32) : Nil
      return if @destinations.empty?
      @selected = (@selected + delta).clamp(0, @destinations.size - 1)
    end

    def selected_destination : SendMenu::Destination?
      @destinations[@selected]?
    end

    def set_selected(idx : Int32) : Nil
      return if @destinations.empty?
      @selected = idx.clamp(0, @destinations.size - 1)
    end

    # The row whose mnemonic matches `c` (case-insensitive), or nil for a miss.
    def index_for(c : Char) : Int32?
      lc = c.downcase
      @destinations.index { |d| d.key.downcase == lc }
    end

    # Centered card geometry over `area` — inverse of render's offset math. nil when
    # render would draw nothing (mirrors the w/h guard). Width fits the widest of the
    # rows (label + hint) and the sized title.
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, content_w + 10}.min
      h = {@destinations.size + 2, area.h - 2}.min
      return nil if w < 18 || area.h < 5
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      Rect.new(x, y, w, h)
    end

    # Row index under (mx,my), mirroring render's list loop; nil outside. Bound to the
    # ACTUALLY rendered rows so a click on a height-clamped card's bottom border can't
    # pick a row that was never drawn.
    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      rows = {box.h - 2, @destinations.size}.min
      i = my - (box.y + 1)
      return nil if i < 0 || i >= rows
      return nil if mx <= box.x || mx >= box.right - 1
      ci = @scroll + i
      ci < @destinations.size ? ci : nil
    end

    private def ensure_visible(rows : Int32) : Nil
      return if rows <= 0
      @scroll = @selected if @selected < @scroll
      @scroll = @selected - rows + 1 if @selected >= @scroll + rows
      @scroll = @scroll.clamp(0, {@destinations.size - rows, 0}.max)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "picker needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, card_title, border: Theme.border_focus)
      rows = {box.h - 2, @destinations.size}.min
      ensure_visible(rows)
      (0...rows).each do |i|
        ci = @scroll + i
        break if ci >= @destinations.size
        d = @destinations[ci]
        ry = box.y + 1 + i
        active = ci == @selected
        bg = active ? Theme.accent_bg : Theme.panel
        screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
        screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)
        screen.text(box.x + 3, ry, d.key.to_s, Theme.accent, bg, Attribute::Bold)
        screen.text(box.x + 6, ry, d.label, active ? Theme.text_bright : Theme.text, bg, Attribute::Bold)
        screen.text(box.right - d.hint.size - 2, ry, d.hint, Theme.muted, bg)
      end
    end

    # The title with the shared payload's size appended once (e.g. "Send selection to · 128 B").
    private def card_title : String
      "#{@title} · #{Fmt.size(@payload.bytesize.to_i64)}"
    end

    # Widest row (label + hint) and the sized title, driving the card width.
    private def content_w : Int32
      rows = @destinations.max_of { |d| d.label.size + d.hint.size + 4 }
      {rows, card_title.size}.max
    end
  end
end
