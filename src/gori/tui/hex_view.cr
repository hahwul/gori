require "./screen"
require "./theme"
require "./frame"

module Gori::Tui
  # Read-only canonical hex dump: `offset  hh hh … hh  |ascii|`, 16 bytes/row.
  # Windowed — only the visible rows are formatted, so dumping a multi-MiB body is
  # cheap (no precompute, just per-visible-row string building).
  module HexView
    COLS = 16

    def self.rows(size : Int32) : Int32
      size <= 0 ? 0 : (size - 1) // COLS + 1
    end

    # Draw rows [scroll, scroll + rect.h) of `data` into `rect`.
    def self.render(screen : Screen, rect : Rect, data : Bytes, scroll : Int32) : Nil
      return if rect.w < 1 || rect.h < 1
      if data.empty?
        screen.text(rect.x, rect.y, "(no body)", Theme.muted)
        return
      end
      total = rows(data.size)
      (0...rect.h).each do |i|
        row = scroll + i
        break if row >= total
        draw_row(screen, rect.x, rect.y + i, data, row, rect.w)
      end
    end

    private def self.draw_row(screen : Screen, x : Int32, y : Int32, data : Bytes, row : Int32, width : Int32) : Nil
      off = row * COLS
      hex = String.build do |s|
        (0...COLS).each do |j|
          idx = off + j
          s << (idx < data.size ? "%02x " % data[idx] : "   ") # pad trailing gap in the last row
          s << ' ' if j == 7                                   # split into two 8-byte groups
        end
      end
      ascii = String.build do |s|
        (0...COLS).each do |j|
          idx = off + j
          break if idx >= data.size
          b = data[idx]
          s << (b >= 0x20_u8 && b <= 0x7e_u8 ? b.unsafe_chr : '.')
        end
      end
      screen.text(x, y, "%08x" % off, Theme.muted, width: width) # offset column
      hx = x + 10
      screen.text(hx, y, hex, Theme.text, width: {width - 10, 0}.max) if width > 10
      ax = hx + hex.size + 1
      screen.text(ax, y, "|#{ascii}|", Theme.muted, width: {x + width - ax, 0}.max) if ax < x + width
    end
  end
end
