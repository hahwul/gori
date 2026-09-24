require "termisu"

module Gori::UnicodeReveal
  C0_NAMES = %w[
    NUL SOH STX ETX EOT ENQ ACK BEL BS TAB LF VT FF CR SO SI
    DLE DC1 DC2 DC3 DC4 NAK SYN ETB CAN EM SUB ESC FS GS RS US
  ]

  SPACE_NAMES = {
    0x00a0 => "NBSP",
    0x1680 => "OGHAM SPACE",
    0x2000 => "EN QUAD",
    0x2001 => "EM QUAD",
    0x2002 => "EN SPACE",
    0x2003 => "EM SPACE",
    0x2004 => "THREE-PER-EM SPACE",
    0x2005 => "FOUR-PER-EM SPACE",
    0x2006 => "SIX-PER-EM SPACE",
    0x2007 => "FIGURE SPACE",
    0x2008 => "PUNCTUATION SPACE",
    0x2009 => "THIN SPACE",
    0x200a => "HAIR SPACE",
    0x202f => "NNBSP",
    0x205f => "MMSP",
    0x3000 => "IDEOGRAPHIC SPACE",
  }

  # A codepoint's visible name. Cf characters and standalone zero-width codepoints are named
  # even when the terminal would otherwise combine them with a neighbour. The caller decides
  # whether to display a badge or keep the codepoint in its wire representation.
  def self.label(codepoint : Int32) : String?
    return nil if codepoint < 0 || codepoint > 0x10ffff
    return C0_NAMES[codepoint]? if codepoint < 0x20
    return "DEL" if codepoint == 0x7f
    return "TAG #{(codepoint - 0xe0000).unsafe_chr}" if (0xe0020..0xe007e).includes?(codepoint)

    format_label(codepoint) || bidi_label(codepoint) || special_label(codepoint) ||
      variation_label(codepoint) || SPACE_NAMES[codepoint]? || fallback_label(codepoint)
  end

  private def self.format_label(codepoint : Int32) : String?
    case codepoint
    when 0x00ad then "SHY"
    when 0x034f then "CGJ"
    when 0x061c then "ALM"
    when 0x180e then "MVS"
    when 0x200b then "ZWSP"
    when 0x200c then "ZWNJ"
    when 0x200d then "ZWJ"
    when 0x200e then "LRM"
    when 0x200f then "RLM"
    end
  end

  private def self.bidi_label(codepoint : Int32) : String?
    case codepoint
    when 0x202a then "LRE"
    when 0x202b then "RLE"
    when 0x202c then "PDF"
    when 0x202d then "LRO"
    when 0x202e then "RLO"
    when 0x2066 then "LRI"
    when 0x2067 then "RLI"
    when 0x2068 then "FSI"
    when 0x2069 then "PDI"
    end
  end

  private def self.special_label(codepoint : Int32) : String?
    case codepoint
    when  0x2060 then "WJ"
    when  0x2061 then "FUNCTION APPLY"
    when  0x2062 then "INVISIBLE TIMES"
    when  0x2063 then "INVISIBLE SEPARATOR"
    when  0x2064 then "INVISIBLE PLUS"
    when  0xfeff then "BOM"
    when 0xe0001 then "LANGUAGE TAG"
    when 0xe007f then "CANCEL TAG"
    end
  end

  private def self.variation_label(codepoint : Int32) : String?
    if (0xfe00..0xfe0f).includes?(codepoint)
      "VS#{codepoint - 0xfe00 + 1}"
    elsif (0xe0100..0xe01ef).includes?(codepoint)
      "VS#{codepoint - 0xe0100 + 17}"
    end
  end

  private def self.fallback_label(codepoint : Int32) : String?
    char = codepoint.unsafe_chr
    return unless char.control? || Termisu::UnicodeWidth.grapheme_width(char.to_s) == 0
    "U+#{codepoint.to_s(16).upcase.rjust(4, '0')}"
  end

  # A display-only replacement for unsafe codepoints in a grapheme. nil is the allocation-free
  # common path. Wire bytes and search text stay untouched; callers that draw it use this result.
  def self.visible(text : String) : String?
    # Most screen cells and terminal strings are printable ASCII. Avoid a builder (and a grapheme
    # walk) for that common case; captured controls still fall through to the classifier below.
    bytes = text.to_slice
    if bytes.all? { |byte| byte >= 0x20_u8 && byte <= 0x7e_u8 }
      return nil
    end

    needs_badge = false
    text.each_grapheme do |grapheme|
      source = grapheme.to_s
      source_width = Termisu::UnicodeWidth.grapheme_width(source)
      source.each_char do |char|
        if name = label(char.ord)
          if !(source_width > 0 && contextual_invisible?(char, source, name))
            needs_badge = true
            break
          end
        end
      end
      break if needs_badge
    end
    return nil unless needs_badge

    out = String::Builder.new
    text.each_grapheme do |grapheme|
      source = grapheme.to_s
      source_width = Termisu::UnicodeWidth.grapheme_width(source)
      source.each_char do |char|
        if name = label(char.ord)
          if source_width > 0 && contextual_invisible?(char, source, name)
            # Keep combining marks and emoji shaping controls attached to visible text;
            # their grapheme still renders, so replacing the control would break the glyph.
            out << char
          else
            out << '⟨' << name << '⟩'
          end
        else
          out << char
        end
      end
    end
    out.to_s
  end

  private def self.contextual_invisible?(char : Char, grapheme : String, name : String) : Bool
    cp = char.ord
    return false if (0xe0020..0xe007f).includes?(cp)
    return emoji_sequence?(grapheme) if cp == 0x200d
    return emoji_base?(grapheme) || keycap_sequence?(grapheme) if variation_selector?(cp)
    # Only unnamed combining/emoji extenders may stay attached to a visible grapheme. Explicitly
    # named format controls such as CGJ must remain visible even when grapheme segmentation
    # attaches them to a printable neighbor.
    return false unless name.starts_with?("U+")
    # A combining mark attached to a visible base is already rendered as part of that
    # grapheme. A standalone one still gets a badge through the zero-width fallback.
    !char.control? && Termisu::UnicodeWidth.codepoint_width(cp) == 0
  end

  private def self.emoji_sequence?(grapheme : String) : Bool
    count = 0
    grapheme.each_char { |char| count += 1 if emoji_base?(char.ord) }
    count >= 2
  end

  private def self.emoji_base?(grapheme : String) : Bool
    grapheme.each_char.any? { |char| emoji_base?(char.ord) }
  end

  private def self.keycap_sequence?(grapheme : String) : Bool
    keycap = false
    base = false
    grapheme.each_char do |char|
      cp = char.ord
      keycap = true if cp == 0x20e3
      base = true if (char >= '0' && char <= '9') || char == '#' || char == '*'
    end
    keycap && base
  end

  private def self.emoji_base?(codepoint : Int32) : Bool
    (0x2300..0x23ff).includes?(codepoint) || (0x2600..0x27ff).includes?(codepoint) ||
      (0x1f000..0x1faff).includes?(codepoint)
  end

  private def self.variation_selector?(codepoint : Int32) : Bool
    (0xfe00..0xfe0f).includes?(codepoint) || (0xe0100..0xe01ef).includes?(codepoint)
  end
end
