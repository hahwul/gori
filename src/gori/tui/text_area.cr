require "./screen"
require "./theme"
require "./highlight"

module Gori::Tui
  # A minimal multi-line text editor for inline editing (e.g. the Replay
  # request). Holds lines + a cursor; no modes — typing edits directly. Converts
  # back to bytes with CRLF line endings (HTTP wire form).
  class TextArea
    def initialize(text : String = "")
      @lines = [""]
      @cy = 0
      @cx = 0
      @scroll = 0
      set_text(text)
    end

    def set_text(text : String) : Nil
      @lines = text.split('\n').map(&.rstrip('\r'))
      @lines = [""] if @lines.empty?
      @cy = 0
      @cx = 0
      @scroll = 0
    end

    def to_bytes : Bytes
      @lines.join("\r\n").to_slice
    end

    # Plain text (LF-joined) for non-wire uses (e.g. the Notes document).
    def text : String
      @lines.join("\n")
    end

    def insert(ch : Char) : Nil
      line = @lines[@cy]
      cx = @cx.clamp(0, line.size)
      @lines[@cy] = "#{line[0, cx]}#{ch}#{line[cx..]}"
      @cx = cx + 1
    end

    def insert_newline : Nil
      line = @lines[@cy]
      cx = @cx.clamp(0, line.size)
      @lines[@cy] = line[0, cx]
      @lines.insert(@cy + 1, line[cx..])
      @cy += 1
      @cx = 0
    end

    def backspace : Nil
      if @cx > 0
        line = @lines[@cy]
        cx = @cx.clamp(0, line.size)
        @lines[@cy] = "#{line[0, cx - 1]}#{line[cx..]}"
        @cx = cx - 1
      elsif @cy > 0
        prev = @lines[@cy - 1]
        @cx = prev.size
        @lines[@cy - 1] = prev + @lines[@cy]
        @lines.delete_at(@cy)
        @cy -= 1
      end
    end

    def move(dr : Int32, dc : Int32) : Nil
      if dr != 0
        @cy = (@cy + dr).clamp(0, @lines.size - 1)
        @cx = @cx.clamp(0, @lines[@cy].size)
      end
      return if dc == 0
      @cx += dc
      if @cx < 0
        if @cy > 0
          @cy -= 1
          @cx = @lines[@cy].size
        else
          @cx = 0
        end
      elsif @cx > @lines[@cy].size
        if @cy < @lines.size - 1
          @cy += 1
          @cx = 0
        else
          @cx = @lines[@cy].size
        end
      end
    end

    # `highlight` overlays request/response syntax colours on the buffer while
    # keeping it fully editable: pass `:request` or `:response` for the held
    # HTTP message editors (Replay, Intercept), nil for plain prose (Notes,
    # Finding notes). The styled lines are 1:1 with `@lines`, so the cursor —
    # drawn last, on top — still lands on the right column.
    def render(screen : Screen, rect : Rect, cursor : Bool, highlight : Symbol? = nil) : Nil
      return if rect.empty?
      ensure_visible(rect.h)
      styled = highlight ? Highlight.from_lines(@lines, highlight == :request) : nil
      (0...rect.h).each do |i|
        li = @scroll + i
        break if li >= @lines.size
        line = @lines[li]
        if styled && (sl = styled[li]?)
          Highlight.draw(screen, rect.x, rect.y + i, sl, width: rect.w)
        else
          screen.text(rect.x, rect.y + i, line, Theme::TEXT, width: rect.w)
        end
        next unless cursor && li == @cy
        cxs = rect.x + @cx
        if cxs < rect.x + rect.w
          ch = @cx < line.size ? line[@cx] : ' '
          screen.cell(cxs, rect.y + i, ch, Theme::BG, Theme::ACCENT) # inverse-video cursor
        end
      end
    end

    private def ensure_visible(h : Int32) : Nil
      return if h <= 0
      @scroll = @cy if @cy < @scroll
      @scroll = @cy - h + 1 if @cy >= @scroll + h
      @scroll = 0 if @scroll < 0
    end
  end
end
