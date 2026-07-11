module Gori::Tui
  # Parses one line of terminal output containing ANSI/SGR escape sequences into
  # styled Segments the Screen can draw. Only SGR (colour/attribute) sequences are
  # interpreted; every other escape (cursor moves, erases, OSC title sets, …) is
  # consumed and dropped so it can't corrupt the cell grid. The parser NEVER raises:
  # a malformed or truncated sequence degrades to the plain text with escapes stripped.
  #
  # `fg`/`bg` are nil when the sequence selects the terminal default (SGR 39/49, or
  # a reset) — the renderer substitutes the theme's own colours, keeping this parser
  # theme-agnostic. Used by the statusline to colour a user script's stdout.
  module Ansi
    record Segment, text : String, fg : Color?, bg : Color?, attr : Attribute

    ESC = '\e'

    # Split `line` into styled runs. `line` is expected to be a single row already
    # (the statusline keeps only the first line of a command's output).
    def self.parse(line : String) : Array(Segment)
      segments = [] of Segment
      return segments if line.empty?
      begin
        chars = line.chars
        n = chars.size
        buf = String::Builder.new
        has_text = false
        fg = nil.as(Color?)
        bg = nil.as(Color?)
        attr = Attribute::None
        i = 0
        while i < n
          c = chars[i]
          if c == ESC && i + 1 < n
            nxt = chars[i + 1]
            if nxt == '['
              # CSI: parameter bytes (0x30-0x3F), then intermediates (0x20-0x2F),
              # then a final byte (0x40-0x7E). Only a final 'm' is SGR; anything else
              # (cursor moves, erases, …) is consumed and dropped.
              j = i + 2
              ps = j
              while j < n && 0x30 <= chars[j].ord <= 0x3F
                j += 1
              end
              pe = j
              while j < n && 0x20 <= chars[j].ord <= 0x2F
                j += 1
              end
              if j < n
                if chars[j] == 'm'
                  if has_text
                    segments << Segment.new(buf.to_s, fg, bg, attr)
                    buf = String::Builder.new
                    has_text = false
                  end
                  params = String.build { |sb| (ps...pe).each { |k| sb << chars[k] } }
                  fg, bg, attr = apply_sgr(params, fg, bg, attr)
                end
                i = j + 1
              else
                # unterminated CSI → drop the remainder
                i = n
              end
              next
            elsif nxt == ']'
              # OSC: consume until BEL (0x07) or ST (ESC \), then drop it.
              j = i + 2
              while j < n
                if chars[j].ord == 0x07
                  j += 1
                  break
                elsif chars[j] == ESC && j + 1 < n && chars[j + 1] == '\\'
                  j += 2
                  break
                end
                j += 1
              end
              i = j
              next
            else
              # bare / two-char escape → drop the ESC and the following byte
              i += 2
              next
            end
          elsif c == ESC
            # lone trailing ESC
            i += 1
            next
          else
            buf << c
            has_text = true
            i += 1
          end
        end
        segments << Segment.new(buf.to_s, fg, bg, attr) if has_text
        segments
      rescue
        # Paranoia backstop: never let a render frame crash on odd input.
        [Segment.new(strip(line), nil, nil, Attribute::None)]
      end
    end

    # Apply one SGR sequence's parameters to the running style, returning the updated
    # {fg, bg, attr}. Unknown codes are ignored; a malformed extended-colour tail stops
    # consuming further params rather than reading past the end.
    private def self.apply_sgr(params : String, fg : Color?, bg : Color?,
                               attr : Attribute) : {Color?, Color?, Attribute}
      # An empty parameter list (bare ESC[m) means reset.
      codes = params.empty? ? [0] : params.split(';').map { |p| p.empty? ? 0 : (p.to_i? || 0) }
      i = 0
      while i < codes.size
        code = codes[i]
        case code
        when 0        then fg = nil; bg = nil; attr = Attribute::None
        when 1        then attr |= Attribute::Bold
        when 2        then attr |= Attribute::Dim
        when 3        then attr |= Attribute::Cursive
        when 4        then attr |= Attribute::Underline
        when 5        then attr |= Attribute::Blink
        when 7        then attr |= Attribute::Reverse
        when 8        then attr |= Attribute::Hidden
        when 9        then attr |= Attribute::Strikethrough
        when 22       then attr &= ~(Attribute::Bold | Attribute::Dim)
        when 23       then attr &= ~Attribute::Cursive
        when 24       then attr &= ~Attribute::Underline
        when 25       then attr &= ~Attribute::Blink
        when 27       then attr &= ~Attribute::Reverse
        when 28       then attr &= ~Attribute::Hidden
        when 29       then attr &= ~Attribute::Strikethrough
        when 30..37   then fg = Color.ansi8(code - 30)
        when 39       then fg = nil
        when 40..47   then bg = Color.ansi8(code - 40)
        when 49       then bg = nil
        when 90..97   then fg = Color.ansi256(code - 90 + 8)
        when 100..107 then bg = Color.ansi256(code - 100 + 8)
        when 38, 48
          # Extended colour: 38;5;n (256) or 38;2;r;g;b (truecolor); 48 = background.
          is_fg = code == 38
          break unless i + 1 < codes.size
          mode = codes[i + 1]
          if mode == 5 && i + 2 < codes.size
            col = Color.ansi256(clamp255(codes[i + 2]))
            is_fg ? (fg = col) : (bg = col)
            i += 2
          elsif mode == 2 && i + 4 < codes.size
            col = Color.rgb(clamp255(codes[i + 2]), clamp255(codes[i + 3]), clamp255(codes[i + 4]))
            is_fg ? (fg = col) : (bg = col)
            i += 4
          else
            # malformed / short tail — stop so we never read past the params
            break
          end
        else
          # unsupported SGR code — ignore
        end
        i += 1
      end
      {fg, bg, attr}
    end

    private def self.clamp255(v : Int32) : Int32
      v < 0 ? 0 : (v > 255 ? 255 : v)
    end

    # Crude escape-stripper used only by the rescue backstop: drop ESC and everything
    # up to and including the next ASCII letter.
    private def self.strip(line : String) : String
      String.build do |sb|
        chars = line.chars
        i = 0
        while i < chars.size
          if chars[i] == ESC
            i += 1
            while i < chars.size && !chars[i].ascii_letter?
              i += 1
            end
            i += 1 if i < chars.size
          else
            sb << chars[i]
            i += 1
          end
        end
      end
    end
  end
end
