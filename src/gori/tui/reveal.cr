require "./highlight"
require "./theme"
require "./screen"
require "../unicode_reveal"

module Gori::Tui
  # Renders text with whitespace / control characters made VISIBLE — space ·, tab →,
  # CR ␍, LF ␊, and every other control byte as its own Unicode "control picture"
  # (ESC ␛, BEL ␇, NUL ␀, DEL ␡, …). For inspecting exact wire framing (CRLF vs LF,
  # trailing spaces, tabs) AND spotting injected control bytes in request-smuggling
  # tests — a space and an ESC must NOT look alike here. Content stays readable in the
  # normal colour; the markers are dimmed. Toggle in the req/res views.
  module Reveal
    SPACE = '·'
    TAB   = '→'
    CR    = '␍'
    LF    = '␊'
    CTRL  = '␦' # generic fallback (C1 / unmapped control); distinct from SPACE's '·'

    # Raw bytes → display lines, split on LF but KEEPING any CR so it shows as ␍.
    # (Decoded as UTF-8, lossy on invalid bytes — use the hex view for byte-exact.)
    # `.scrub` maps invalid UTF-8 to U+FFFD so stray bytes never reach width/search math,
    # matching the same seam in Highlight.to_lines (control bytes are glyph-marked below).
    def self.lines(bytes : Bytes) : Array(String)
      String.new(bytes).scrub.split('\n')
    end

    # One revealed, styled line: content runs in `fg`, whitespace markers dimmed.
    # `lf` appends the ␊ newline marker. Stops at `max_cols` columns so a huge
    # minified line never builds spans past the pane width.
    def self.styled(line : String, lf : Bool, max_cols : Int32, fg : Color = Theme.text) : Highlight::Line
      # Printable ASCII is already the reveal representation (spaces are handled below),
      # and can be clipped with one slice rather than grapheme-walked.
      if Screen.printable_ascii?(line) && !line.includes?(' ')
        return styled_ascii(line, lf, max_cols, fg)
      end
      return [] of Highlight::Span if max_cols <= 0
      styled_graphemes(line, lf, max_cols, fg)
    end

    private def self.styled_ascii(line : String, lf : Bool, max_cols : Int32,
                                  fg : Color) : Highlight::Line
      spans = [] of Highlight::Span
      return spans if max_cols <= 0
      draw = {line.size, max_cols}.min
      spans << Highlight::Span.new(line[0, draw], fg) if draw > 0
      spans << Highlight::Span.new(LF.to_s, Theme.muted) if lf && draw < max_cols
      spans
    end

    private def self.styled_graphemes(line : String, lf : Bool, max_cols : Int32,
                                      fg : Color) : Highlight::Line
      spans = [] of Highlight::Span
      run = [] of String # printable graphemes; joined once when a marker flushes it
      cols = 0
      line.each_grapheme do |grapheme|
        source = grapheme.to_s
        marker = visible_grapheme(source)
        shown = marker || source
        width = Screen.draw_width(shown)
        break if cols + width > max_cols
        if marker
          unless run.empty?
            spans << Highlight::Span.new(run.join, fg)
            run.clear
          end
          spans << Highlight::Span.new(marker, Theme.muted)
        else
          run << source
        end
        cols += width
      end
      spans << Highlight::Span.new(run.join, fg) unless run.empty?
      spans << Highlight::Span.new(LF.to_s, Theme.muted) if lf && cols < max_cols
      spans
    end

    # Drawn width of a source grapheme in reveal mode. Wrap, caret and search use this same
    # representation measure when whitespace is expanded to one-cell markers.
    def self.grapheme_cols(grapheme : String) : Int32
      Screen.draw_width(visible_grapheme(grapheme) || grapheme)
    end

    def self.draw_width(text : String) : Int32
      return text.size if Screen.printable_ascii?(text)
      width = 0
      text.each_grapheme { |grapheme| width += grapheme_cols(grapheme.to_s) }
      width
    end

    def self.draw_width_upto(text : String, limit : Int32) : Int32
      return 0 if text.empty? || limit <= 0
      return {text.size, limit}.min if Screen.printable_ascii?(text)
      width = 0
      text.each_grapheme do |grapheme|
        width += grapheme_cols(grapheme.to_s)
        return width if width >= limit
      end
      width
    end

    def self.rendered_text(text : String) : String
      String.build do |io|
        text.each_grapheme do |grapheme|
          source = grapheme.to_s
          io << (visible_grapheme(source) || source)
        end
      end
    end

    def self.slice_left_text(text : String, start_col : Int32) : String
      return text if start_col <= 0
      acc = 0
      cutting = true
      String.build do |io|
        text.each_grapheme do |grapheme|
          source = grapheme.to_s
          shown = visible_grapheme(source) || source
          width = Screen.draw_width(shown)
          if cutting
            if acc + width <= start_col
              acc += width
              next
            end
            io << " " * (acc + width - start_col) if acc < start_col
            io << shown if acc >= start_col
            acc += width
            cutting = false
          else
            io << shown
          end
        end
      end
    end

    # The visible marker for one control byte. C0 controls (0x00..0x1F) map to their
    # Unicode "Control Pictures" (U+2400..U+241F: ␀…␟), DEL (0x7F) to ␡ (U+2421) — the
    # same block CR/LF already draw from — so ESC, BEL, NUL, etc. each read distinctly
    # instead of collapsing to one glyph (and never to SPACE's '·'). A C1 or otherwise
    # unmapped control byte falls back to the generic CTRL marker.
    def self.control_picture(c : Char) : Char
      o = c.ord
      if 0x00 <= o <= 0x1f
        (0x2400 + o).chr
      elsif o == 0x7f
        '␡'
      else
        CTRL
      end
    end

    def self.visible_grapheme(grapheme : String) : String?
      case grapheme
      when " "  then SPACE.to_s
      when "\t" then TAB.to_s
      when "\r" then CR.to_s
      else
        if grapheme.size == 1
          char = grapheme[0]
          return control_picture(char).to_s if char.ord < 0x20 || char.ord == 0x7f
        end
        UnicodeReveal.visible(grapheme)
      end
    end
  end
end
