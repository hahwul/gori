module Gori::JsonUnicode
  alias DecodedRange = {Int32, Int32, Int32} # line, first character, one-past-last character

  record Result, text : String, ranges : Array(DecodedRange), count : Int32,
    protected_linefeeds : Array(Int32) = [] of Int32

  # Count valid Unicode escape tokens without changing the input or building decoded output.
  # Callers validate the surrounding JSON first when they need document semantics.
  def self.escape_count(json : String) : Int32
    source = json.to_slice
    count = 0
    in_string = false
    i = 0
    while i < source.size
      byte = source[i]
      if in_string && byte == 0x5c_u8 && i + 1 < source.size
        consumed, escapes = counted_escape(source, i)
        count += escapes
        i += consumed
      else
        in_string = !in_string if byte == 0x22_u8
        i += 1
      end
    end
    count
  end

  # Decode valid \uXXXX escapes only inside JSON strings. A surrogate pair becomes one Unicode
  # scalar; an unpaired surrogate stays spelled as it arrived. Ranges identify decoded
  # codepoints in the output so the TUI can style them while Screen renders unsafe glyphs as
  # badges; search and copy continue to operate on the decoded text, not the badge spelling.
  def self.decode(json : String) : Result
    chars = json.scrub.chars
    builder = String::Builder.new
    line = 0
    line_offset = 0
    output_byte_offset = 0
    ranges = [] of DecodedRange
    protected_linefeeds = [] of Int32
    count = 0
    in_string = false
    i = 0

    while i < chars.size
      char = chars[i]
      if in_string && char == '\\' && i + 1 < chars.size
        if escape = decoded_escape(chars, i)
          cp, consumed, escapes = escape
          ranges << {line, line_offset, line_offset + 1}
          protected_linefeeds << output_byte_offset if cp == '\n'.ord
          builder << cp.unsafe_chr
          output_byte_offset += utf8_bytesize(cp)
          line_offset += 1
          count += escapes
          i += consumed
          next
        end

        append_chars(builder, chars, i, 2)
        output_byte_offset += 2
        line_offset += 2
        i += 2
        next
      end

      builder << char
      output_byte_offset += utf8_bytesize(char.ord)
      if char == '\n'
        line += 1
        line_offset = 0
      else
        line_offset += 1
      end
      in_string = !in_string if char == '"'
      i += 1
    end

    Result.new(builder.to_s, ranges, count, protected_linefeeds)
  end

  private def self.append_chars(builder : String::Builder, chars : Array(Char), start : Int32,
                                consumed : Int32) : Nil
    consumed.times { |offset| builder << chars[start + offset] }
  end

  private def self.counted_escape(source : Bytes, start : Int32) : {Int32, Int32}
    return {2, 0} unless source[start + 1] == 0x75_u8
    codepoint = escaped_byte_codepoint(source, start + 2) || return {2, 0}
    return {6, 0} if codepoint >= 0xdc00 && codepoint <= 0xdfff
    return {6, 1} unless codepoint >= 0xd800 && codepoint <= 0xdbff
    paired_low_surrogate?(source, start + 6) ? {12, 2} : {6, 0}
  end

  private def self.decoded_escape(chars : Array(Char), start : Int32) : {Int32, Int32, Int32}?
    return nil unless chars[start + 1] == 'u'
    codepoint = escaped_codepoint(chars, start + 2) || return nil
    if codepoint >= 0xd800 && codepoint <= 0xdbff
      return decoded_surrogate_pair(chars, start + 6, codepoint)
    end
    return nil if codepoint >= 0xdc00 && codepoint <= 0xdfff
    {codepoint, 6, 1}
  end

  private def self.paired_low_surrogate?(source : Bytes, start : Int32) : Bool
    return false unless start + 6 <= source.size
    return false unless source[start] == 0x5c_u8 && source[start + 1] == 0x75_u8
    low = escaped_byte_codepoint(source, start + 2)
    !low.nil? && low >= 0xdc00 && low <= 0xdfff
  end

  private def self.decoded_surrogate_pair(chars : Array(Char), start : Int32,
                                          high : Int32) : {Int32, Int32, Int32}?
    return nil unless start + 6 <= chars.size
    return nil unless chars[start] == '\\' && chars[start + 1] == 'u'
    low = escaped_codepoint(chars, start + 2)
    return nil unless low && low >= 0xdc00 && low <= 0xdfff
    combined = 0x10000 + ((high - 0xd800) << 10) + (low - 0xdc00)
    {combined, 12, 2}
  end

  private def self.utf8_bytesize(codepoint : Int32) : Int32
    if codepoint <= 0x7f
      1
    elsif codepoint <= 0x7ff
      2
    elsif codepoint <= 0xffff
      3
    else
      4
    end
  end

  private def self.escaped_codepoint(chars : Array(Char), start : Int32) : Int32?
    return nil if start + 4 > chars.size
    value = 0
    4.times do |offset|
      digit = hex_value(chars[start + offset].ord)
      return nil unless digit
      value = (value << 4) | digit
    end
    value
  end

  private def self.escaped_byte_codepoint(source : Bytes, start : Int32) : Int32?
    return nil if start + 4 > source.size
    value = 0
    4.times do |offset|
      digit = hex_value_byte(source[start + offset])
      return nil unless digit
      value = (value << 4) | digit
    end
    value
  end

  private def self.hex_value_byte(byte : UInt8) : Int32?
    case byte
    when 0x30_u8..0x39_u8 then byte.to_i32 - 0x30
    when 0x61_u8..0x66_u8 then byte.to_i32 - 0x61 + 10
    when 0x41_u8..0x46_u8 then byte.to_i32 - 0x41 + 10
    end
  end

  private def self.hex_value(codepoint : Int32) : Int32?
    case codepoint
    when '0'.ord..'9'.ord then codepoint - '0'.ord
    when 'a'.ord..'f'.ord then codepoint - 'a'.ord + 10
    when 'A'.ord..'F'.ord then codepoint - 'A'.ord + 10
    end
  end
end
