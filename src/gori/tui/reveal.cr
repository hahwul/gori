require "./highlight"
require "./theme"
require "./screen"

module Gori::Tui
  # Renders text with whitespace / control characters made VISIBLE — space ·, tab →,
  # CR ␍, LF ␊, other control ·. For inspecting exact wire framing (CRLF vs LF,
  # trailing spaces, tabs) in request-smuggling tests. Content stays readable in the
  # normal colour; the markers are dimmed. Toggle in the req/res views.
  module Reveal
    SPACE = '·'
    TAB   = '→'
    CR    = '␍'
    LF    = '␊'
    CTRL  = '·'

    # Raw bytes → display lines, split on LF but KEEPING any CR so it shows as ␍.
    # (Decoded as UTF-8, lossy on invalid bytes — use the hex view for byte-exact.)
    def self.lines(bytes : Bytes) : Array(String)
      String.new(bytes).split('\n')
    end

    # One revealed, styled line: content runs in `fg`, whitespace markers dimmed.
    # `lf` appends the ␊ newline marker. Stops at `max_cols` columns so a huge
    # minified line never builds spans past the pane width.
    def self.styled(line : String, lf : Bool, max_cols : Int32, fg : Color = Theme::TEXT) : Highlight::Line
      spans = [] of Highlight::Span
      content = "" # current run of printable chars (bounded by max_cols, so + is cheap)
      cols = 0
      line.each_char do |c|
        break if cols >= max_cols
        marker = case c
                 when ' '  then SPACE
                 when '\t' then TAB
                 when '\r' then CR
                 else           c.control? ? CTRL : nil
                 end
        if marker
          unless content.empty?
            spans << Highlight::Span.new(content, fg)
            content = ""
          end
          spans << Highlight::Span.new(marker.to_s, Theme::MUTED)
        else
          content += c
        end
        cols += 1
      end
      spans << Highlight::Span.new(content, fg) unless content.empty?
      spans << Highlight::Span.new(LF.to_s, Theme::MUTED) if lf
      spans
    end
  end
end
