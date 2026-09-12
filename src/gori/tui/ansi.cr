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
      return {nil, nil, Attribute::None} if params.empty?
      # ITU T.416 spells extended colour with `:` sub-parameters — `38:2::r:g:b`, `38:5:n`,
      # and `4:3` for a curly underline — where one `;`-parameter carries its own arguments.
      # Splitting on `;` alone leaves that whole group as a single non-numeric string, and
      # `to_i? || 0` then read it as code 0: a truecolor sequence written the ITU way
      # SILENTLY RESET the style instead of setting a colour. Handled before the loop, so
      # the `;` reader below stays the plain-integer reader it has always been.
      return apply_sgr_subparams(params, fg, bg, attr) if params.includes?(':')
      # A parameter that is not an integer at all is malformed, and ignoring one is always
      # safer than obeying it: `0` here is the RESET code, so a typo would wipe the style.
      codes = params.split(';').compact_map { |p| p.empty? ? 0 : p.to_i? }
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

    # One SGR sequence whose parameters carry `:` sub-parameters (ITU T.416), where a single
    # `;`-parameter carries its own arguments — `38:2::r:g:b`, `38:5:n`, `4:3` (curly
    # underline). Each colon group is read as a unit; the plain groups around it are gathered
    # into RUNS and handed back to the `;` reader intact, because a sequence may mix the two
    # (`4:3;38;5;196`) and `38;5;196` only means a colour while its three parameters are read
    # together — split apart, the `5` would be Blink.
    private def self.apply_sgr_subparams(params : String, fg : Color?, bg : Color?,
                                         attr : Attribute) : {Color?, Color?, Attribute}
      run = [] of String
      params.split(';').each do |group|
        unless group.includes?(':')
          run << group
          next
        end
        unless run.empty?
          fg, bg, attr = apply_sgr(run.join(';'), fg, bg, attr)
          run.clear
        end
        fg, bg, attr = apply_subparam_group(group, fg, bg, attr)
      end
      run.empty? ? {fg, bg, attr} : apply_sgr(run.join(';'), fg, bg, attr)
    end

    # One `:`-joined parameter group. An extended-colour group sets the colour from its own
    # arguments; anything else applies its LEADING code (so `4:3` still underlines) and drops
    # the styling detail gori has no cell for.
    private def self.apply_subparam_group(group : String, fg : Color?, bg : Color?,
                                          attr : Attribute) : {Color?, Color?, Attribute}
      sub = group.split(':')
      code = sub[0].empty? ? 0 : (sub[0].to_i? || -1)
      if code == 38 || code == 48
        # nil ⇒ the group carried no readable colour; leave the running style ALONE rather
        # than guess, which is the whole point of handling this form separately.
        if col = subparam_color(sub)
          code == 38 ? (fg = col) : (bg = col)
        end
        {fg, bg, attr}
      elsif code >= 0
        apply_sgr(code.to_s, fg, bg, attr)
      else
        {fg, bg, attr}
      end
    end

    # The colour a `38:…` / `48:…` sub-parameter group carries, or nil when it carries none.
    private def self.subparam_color(sub : Array(String)) : Color?
      args = sub[1..]
      case args[0]?.try(&.to_i?)
      when 5 then (n = args[1]?.try(&.to_i?)) ? Color.ansi256(clamp255(n)) : nil
      when 2 then truecolor_subparam(args)
      end
    end

    # `38:2` in its two live spellings. T.416 writes [2, colour-space, r, g, b] and may append
    # tolerance parameters after the blue; several emitters drop the colour-space slot entirely
    # and write [2, r, g, b]. Counted FROM THE LEFT on an explicit arity switch, because the
    # obvious shortcut — take the last three — reads `38:2::255:0:0:1` (red, plus a tolerance)
    # as rgb(0, 0, 1), a confident black. Fewer than four arguments carries no colour at all:
    # `38:2:1:2` would otherwise read its own mode digit as red.
    private def self.truecolor_subparam(args : Array(String)) : Color?
      rgb = case args.size
            when 0, 1, 2, 3 then return nil
            when 4          then args[1..3] # [2, r, g, b] — colour-space slot omitted
            else                 args[2..4] # [2, cs, r, g, b, (tolerance…)]
            end.map(&.to_i?)
      return nil unless rgb.all? { |v| v }
      Color.rgb(clamp255(rgb[0].as(Int32)), clamp255(rgb[1].as(Int32)), clamp255(rgb[2].as(Int32)))
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
