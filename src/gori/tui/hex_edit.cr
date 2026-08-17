require "./screen"
require "./theme"
require "./hex_view"
require "./viewport"

module Gori::Tui
  # Editable byte buffer rendered as a hex dump (the writable counterpart of the
  # read-only HexView). Holds the bytes as a mutable Array(UInt8) and a nibble
  # cursor; supports overtype (hex digits), insert/delete bytes, and navigation.
  # Byte-faithful — bytes never round-trip through a String here (only at the
  # RepeaterView boundary on enter/exit/persist, which is documented as lossy).
  class HexEdit
    COLS = HexView::COLS # 16 bytes/row
    HEXD = "0123456789abcdef"

    getter bytes : Array(UInt8)
    getter nib : Int32     # nibble cursor: 0..len*2 (len*2 = the append slot)
    getter? mutated : Bool # true once any edit changed the bytes (a pure peek stays false)
    # How many edits have landed — the monotonic counter `TextArea#edits` provides, and for the
    # same job: a cache keyed on the buffer's identity (the Intercept detail preview) needs to
    # know that the SAME buffer changed. `mutated?` cannot answer that; it latches once.
    getter edits : Int32

    def initialize(src : Bytes)
      @bytes = src.to_a
      @nib = 0
      @mutated = false
      @edits = 0
    end

    def len : Int32
      @bytes.size
    end

    def to_bytes : Bytes
      Bytes.new(@bytes.size) { |i| @bytes[i] }
    end

    def at_top? : Bool
      @nib < COLS * 2 # cursor is in the first row
    end

    # --- navigation (all clamp to 0..len*2) ---
    def move_left : Nil
      @nib = (@nib - 1).clamp(0, len * 2)
    end

    def move_right : Nil
      @nib = (@nib + 1).clamp(0, len * 2)
    end

    def move_rows(dr : Int32) : Nil
      @nib = (@nib + dr * COLS * 2).clamp(0, len * 2)
    end

    def home : Nil
      @nib = (@nib // 2 // COLS) * COLS * 2 # start of the current row
    end

    def end_of_row : Nil
      row = @nib // 2 // COLS
      @nib = {(row * COLS + COLS) * 2 - 1, len * 2}.min
    end

    # Mouse: move the nibble cursor to a click, inverting draw_row's layout. `rect`
    # and `scroll` are what render() received. A click on a hex digit lands on that
    # nibble; on an ASCII char, that byte's high nibble; on a gap/offset, a no-op.
    # Coords are 0-based.
    def click_to_nibble(rect : Rect, mx : Int32, my : Int32, scroll : Int32) : Nil
      return if rect.empty? || my < rect.y
      row = scroll + (my - rect.y)
      return if row < 0
      base = row * COLS # first byte index on the clicked row
      if no = hex_nibble_col(rect.x, mx)
        @nib = (base * 2 + no).clamp(0, len * 2)
      elsif col = ascii_col(rect.x, mx)
        @nib = ((base + col) * 2).clamp(0, len * 2)
      end
    end

    # The within-row nibble offset (col*2 + low?) for a hex-cell click at column `mx`,
    # else nil. Mirrors draw_row's hx advance: high nibble at x+10+col*3 (+1 after the
    # byte-7 mid-row gap), low nibble one cell right.
    private def hex_nibble_col(x : Int32, mx : Int32) : Int32?
      COLS.times do |col|
        hi = x + 10 + col * 3 + (col >= 8 ? 1 : 0)
        return col * 2 if mx == hi
        return col * 2 + 1 if mx == hi + 1
      end
      nil
    end

    # The byte column for an ASCII-gutter click, else nil. The ASCII chars start two
    # columns past the hex block (the closing space + the '|' bar): x + 10 + COLS*3 + 1 + 2.
    private def ascii_col(x : Int32, mx : Int32) : Int32?
      col = mx - (x + 10 + COLS * 3 + 1 + 2)
      (0 <= col < COLS) ? col : nil
    end

    # --- edits (return true iff they mutated, so the caller marks dirty) ---

    # Overtype the nibble under the cursor with `v` (0..15) and advance one nibble.
    # At the append slot (or on an empty buffer) it grows the buffer by one byte.
    def set_nibble(v : Int32) : Bool
      b = @nib // 2
      @bytes << 0_u8 if b >= @bytes.size
      cur = @bytes[b]
      @bytes[b] = @nib.even? ? (cur & 0x0f_u8) | (v.to_u8 << 4) : (cur & 0xf0_u8) | v.to_u8
      @nib = (@nib + 1).clamp(0, len * 2)
      mutate!
    end

    # Insert a 0x00 byte at the cursor byte; cursor lands on its high nibble.
    def insert_byte : Bool
      b = @nib // 2
      @bytes.insert(b, 0_u8)
      @nib = b * 2
      mutate!
    end

    # Delete the byte BEFORE the cursor (like text backspace).
    def backspace : Bool
      b = @nib // 2
      return false if b == 0
      @bytes.delete_at(b - 1)
      @nib = (@nib - 2).clamp(0, len * 2)
      mutate!
    end

    # Delete the byte UNDER the cursor.
    def delete : Bool
      b = @nib // 2
      return false if b >= @bytes.size
      @bytes.delete_at(b)
      @nib = {@nib, len * 2}.min
      mutate!
    end

    # Every mutator's tail: latch `mutated?` and advance `edits`, returning true so the caller
    # can mark itself dirty in one expression. One place, so a new edit cannot bump one and
    # forget the other.
    private def mutate! : Bool
      @edits += 1
      @mutated = true
    end

    # Draw rows [scroll, scroll + rect.h) with the cursor highlighted; returns the
    # (possibly adjusted) scroll so the caller persists scroll-to-cursor.
    def render(screen : Screen, rect : Rect, focused : Bool, scroll : Int32) : Int32
      return scroll if rect.w < 1 || rect.h < 1
      cur_row = @nib // 2 // COLS
      total = {HexView.rows(len), cur_row + 1}.max
      # `scroll` is a PARAMETER the caller persists (`@scroll_req = h.render(…, @scroll_req)`),
      # so this is the shared derivation at its plainest — no ivar on either side, the pure
      # signature the module was written for. `total` is what the loop below breaks against.
      scroll = Viewport.scroll_to_show(cur_row, scroll, rect.h, total)
      right = rect.x + rect.w # clip every column to the pane (cells otherwise bleed into the next pane)
      (0...rect.h).each do |i|
        row = scroll + i
        break if row >= total
        draw_row(screen, rect.x, rect.y + i, row, right, focused)
      end
      scroll
    end

    private def draw_row(screen : Screen, x : Int32, y : Int32, row : Int32, right : Int32, focused : Bool) : Nil
      off = row * COLS
      cur_b = @nib // 2
      cur_hi = @nib.even?
      screen.text(x, y, "%08x" % off, Theme.muted, width: {right - x, 0}.max)
      hx = x + 10
      cursor_x = nil.as(Int32?)
      (0...COLS).each do |col|
        idx = off + col
        cur = focused && idx == cur_b
        if hx + 1 < right # don't draw past the pane edge
          if idx < @bytes.size
            b = @bytes[idx]
            draw_nibble(screen, hx, y, HEXD[b >> 4], cur && cur_hi)
            draw_nibble(screen, hx + 1, y, HEXD[b & 0x0f_u8], cur && !cur_hi)
          elsif cur && idx == @bytes.size
            screen.cell(hx, y, '_', Theme.bg, Theme.accent) # append slot caret
            screen.cell(hx + 1, y, '_', Theme.muted, Theme.bg)
          end
          cursor_x = (cur_hi ? hx : hx + 1) if cur
        end
        hx += 3
        hx += 1 if col == 7
      end
      # ASCII gutter: |....|, cursor byte inverted; clipped to the pane edge.
      ax = hx + 1
      n = {len - off, 0}.max.clamp(0, COLS) # bytes shown on this row (0 on an empty/append row)
      screen.cell(ax, y, '|', Theme.muted) if ax < right
      (0...n).each do |col|
        cx = ax + 1 + col
        break if cx >= right
        b = @bytes[off + col]
        ch = (b >= 0x20_u8 && b <= 0x7e_u8) ? b.unsafe_chr : '.'
        cur = focused && (off + col) == cur_b
        screen.cell(cx, y, ch, cur ? Theme.bg : Theme.muted, cur ? Theme.accent : Theme.bg)
      end
      cbar = ax + 1 + n
      screen.cell(cbar, y, '|', Theme.muted) if cbar < right # closing bar always (even on empty/append rows)
      screen.cursor(cursor_x, y) if cursor_x && focused
    end

    private def draw_nibble(screen : Screen, x : Int32, y : Int32, ch : Char, cursor : Bool) : Nil
      screen.cell(x, y, ch, cursor ? Theme.bg : Theme.text, cursor ? Theme.accent : Theme.bg)
    end
  end
end
