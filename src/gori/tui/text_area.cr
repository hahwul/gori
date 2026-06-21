require "./screen"
require "./theme"
require "./highlight"
require "./gutter"
require "./search_hi"
require "./reveal"

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
      @preedit = ""
      # Cached syntax-highlight overlay (1:1 with @lines), rebuilt only when the
      # buffer content changes — not on every render frame. @styled_kind tracks
      # which highlight symbol it was built for.
      @styled = nil.as(Array(Highlight::Line)?)
      @styled_kind = nil.as(Symbol?)
      @gutter = false # left line-number gutter (on for the Replay request body)
      @search_hl = "" # active ^F query → matches highlighted in render
      @reveal = false # show whitespace (space ·, tab →) instead of syntax colours
      set_text(text)
    end

    setter gutter : Bool
    setter search_hl : String
    setter reveal : Bool

    def set_text(text : String) : Nil
      @lines = text.split('\n').map(&.rstrip('\r'))
      @lines = [""] if @lines.empty?
      @cy = 0
      @cx = 0
      @scroll = 0
      @preedit = ""
      @styled = nil
    end

    # Preedit/composing text from IME (e.g. current Hangul syllable while typing jamo).
    # Rendered after the current line's text at cursor, with composing style (underline).
    # Cleared by the input handler when composition commits (final char arrives as normal insert).
    def set_preedit(text : String) : Nil
      @preedit = text
    end

    def preedit : String
      @preedit
    end

    def to_bytes : Bytes
      @lines.join("\r\n").to_slice
    end

    # Plain text (LF-joined) for non-wire uses (e.g. the Notes document).
    def text : String
      @lines.join("\n")
    end

    # First line with non-whitespace content — used to derive a label/preview
    # (e.g. a Notes sub-tab title) without joining the whole buffer. nil when the
    # document is entirely blank.
    def first_nonblank_line : String?
      @lines.find { |l| !l.blank? }
    end

    def insert(ch : Char) : Nil
      line = @lines[@cy]
      cx = @cx.clamp(0, line.size)
      @lines[@cy] = "#{line[0, cx]}#{ch}#{line[cx..]}"
      @cx = cx + 1
      @styled = nil
    end

    def insert_newline : Nil
      line = @lines[@cy]
      cx = @cx.clamp(0, line.size)
      @lines[@cy] = line[0, cx]
      @lines.insert(@cy + 1, line[cx..])
      @cy += 1
      @cx = 0
      @styled = nil
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
      @styled = nil
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

    # Cursor is on the first line — the Runner pops focus to the tab bar when ↑
    # is pressed here (natural upward flow, matching the body lists).
    def at_top? : Bool
      @cy == 0
    end

    # Jump the cursor to 1-based line `n`, column 0 (out-of-range clamps to the
    # first/last line). render's ensure_visible scrolls it into view next frame.
    def goto_line(n : Int32) : Nil
      @cy = (n - 1).clamp(0, @lines.size - 1)
      @cx = 0
    end

    def line_count : Int32
      @lines.size
    end

    # ^F search: 0-based indices of lines containing `query` (case-insensitive).
    def search_lines(query : String) : Array(Int32)
      hits = [] of Int32
      return hits if query.empty?
      q = query.downcase
      @lines.each_with_index { |l, i| hits << i if l.downcase.includes?(q) }
      hits
    end

    # `highlight` overlays request/response syntax colours on the buffer while
    # keeping it fully editable: pass `:request` or `:response` for the held
    # HTTP message editors (Replay, Intercept), nil for plain prose (Notes,
    # Finding notes). The styled lines are 1:1 with `@lines`, so the cursor —
    # drawn last, on top — still lands on the right column.
    def render(screen : Screen, rect : Rect, cursor : Bool, highlight : Symbol? = nil) : Nil
      return if rect.empty?
      ensure_visible(rect.h)
      gw = @gutter ? {Gutter.width(@lines.size), rect.w}.min : 0 # never exceed the pane
      cx0 = rect.x + gw                                          # content start x (after the optional gutter)
      cw = {rect.w - gw, 0}.max                                  # content width
      styled = highlight ? highlighted(highlight) : nil
      (0...rect.h).each do |i|
        li = @scroll + i
        break if li >= @lines.size
        Gutter.draw(screen, rect.x, rect.y + i, li, gw, current: li == @cy) if @gutter
        line = @lines[li]
        if @reveal
          Highlight.draw(screen, cx0, rect.y + i, Reveal.styled(line, false, cw), width: cw)
        elsif styled && (sl = styled[li]?)
          Highlight.draw(screen, cx0, rect.y + i, sl, width: cw)
        else
          if li == @cy && !@preedit.empty?
            prefix = line[0, @cx]
            suffix = line[@cx..]
            px = cx0
            if !prefix.empty?
              screen.text(px, rect.y + i, prefix, Theme::TEXT, width: cw)
              px += Screen.display_width(prefix)
            end
            if !@preedit.empty?
              screen.text(px, rect.y + i, @preedit, Theme::TEXT, attr: Attribute::Underline, width: cw - (px - cx0))
              px += Screen.display_width(@preedit)
            end
            if !suffix.empty?
              screen.text(px, rect.y + i, suffix, Theme::TEXT, width: cw - (px - cx0))
            end
          else
            screen.text(cx0, rect.y + i, line, Theme::TEXT, width: cw)
          end
        end
        SearchHi.mark(screen, cx0, rect.y + i, line, @search_hl, cx0 + cw) unless @search_hl.empty?
        next unless cursor && li == @cy
        prefix_w = Screen.display_width(line[0, @cx])
        preedit_w = Screen.display_width(@preedit)
        cxs = cx0 + prefix_w + preedit_w
        screen.cursor(cxs, rect.y + i) if cxs < cx0 + cw
        if cxs < cx0 + cw
          cgw = [Screen.display_width((@preedit.empty? ? (@cx < line.size ? line[@cx] : ' ') : @preedit[0]).to_s), 1].max
          ch = @preedit.empty? ? (@cx < line.size ? line[@cx] : ' ') : @preedit[0]
          (0...cgw).each do |off|
            cch = (off == 0 ? ch : ' ')
            screen.cell(cxs + off, rect.y + i, cch, Theme::BG, Theme::ACCENT)
          end
        end
      end
    end

    # The highlight overlay for `kind` (:request/:response), cached until the
    # buffer content changes — so a held editor isn't re-tokenised 20×/sec.
    private def highlighted(kind : Symbol) : Array(Highlight::Line)
      cached = @styled
      return cached if cached && @styled_kind == kind
      @styled_kind = kind
      @styled = kind == :markdown ? Highlight.markdown(@lines) : Highlight.from_lines(@lines, kind == :request)
    end

    private def ensure_visible(h : Int32) : Nil
      return if h <= 0
      @scroll = @cy if @cy < @scroll
      @scroll = @cy - h + 1 if @cy >= @scroll + h
      @scroll = 0 if @scroll < 0
    end
  end
end
