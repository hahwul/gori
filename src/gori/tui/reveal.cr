require "./highlight"
require "./theme"
require "./screen"

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
      spans = [] of Highlight::Span
      run = [] of Char # current run of printable chars; joined once when it flushes
      cols = 0
      line.each_char do |c|
        break if cols >= max_cols
        marker = case c
                 when ' '  then SPACE
                 when '\t' then TAB
                 when '\r' then CR
                 else           c.control? ? control_picture(c) : nil
                 end
        if marker
          # `run.join` materializes the run in one pass; `content += c` per char was
          # O(run²) (reallocating the growing string each time).
          unless run.empty?
            spans << Highlight::Span.new(run.join, fg)
            run.clear
          end
          spans << Highlight::Span.new(marker.to_s, Theme.muted)
        else
          run << c
        end
        cols += 1
      end
      spans << Highlight::Span.new(run.join, fg) unless run.empty?
      spans << Highlight::Span.new(LF.to_s, Theme.muted) if lf
      spans
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
  end
end
