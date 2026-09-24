require "json"

module Gori
  # JSON read WITHOUT converting its numbers. `JSON.parse` turns every number into an Int64 or
  # a Float64 and raises on one that fits neither — an unsigned 64-bit id
  # (`18446744073709551615`), an exponent past Float64 (`1.5e400`) — so a single such number
  # anywhere made the whole document unreadable: a JWT segment lost every claim and a re-sign
  # that started over from `{}` dropped them (#1169), and a captured response body read as "not
  # JSON" to every tool asking it for one unrelated field (#1200). The pull parser keeps a
  # number as the digits it arrived as, and walks an object member by member, so this also
  # keeps a duplicated key (`{"sub":"a","sub":"admin"}`, a parser-differential probe) instead of
  # folding it away.
  #
  # Two kinds of reader: `reformat`/`members`/`object` hand back JSON TEXT, numbers verbatim,
  # and are safe to re-emit; `parse`/`claims`/`member` hand back `JSON::Any` for READING, where
  # a number `JSON::Any` cannot hold is carried as its literal text, a String. Never serialize
  # the second kind back out — that turns such a number into a string.
  module RawJson
    extend self

    # The whole document as `JSON.parse` would give it, except that a number past
    # Int64/Float64 is carried as its literal text (a String) instead of failing the document,
    # so every OTHER value stays readable. The last occurrence of a duplicated key wins, as with
    # `JSON.parse`. Raises JSON::ParseException when `json` is not exactly one JSON value. For
    # reading only — see the module comment.
    def parse(json : String) : JSON::Any
      pull = JSON::PullParser.new(json)
      value = read_any(pull)
      finish(pull)
      value
    end

    # Whether `json` is exactly one JSON value, numbers of any magnitude included — the
    # question `JSON.parse` answers "no" to for `{"id":18446744073709551615}`. Checks syntax with
    # the lexer and builds nothing.
    def valid?(json : String) : Bool
      pull = JSON::PullParser.new(json)
      pull.skip
      finish(pull)
      true
    rescue JSON::ParseException
      false
    end

    # `json` re-emitted — pretty when `indent` is given, compact otherwise — with every number
    # as its literal text and every member in order. Raises JSON::ParseException when `json`
    # is not exactly one JSON value.
    def reformat(json : String, indent : String? = nil) : String
      pull = JSON::PullParser.new(json)
      text = JSON.build(indent) { |j| pull.read_raw(j) }
      finish(pull)
      text
    end

    # Re-indent a JSON document by changing whitespace only. Strings (including their escape
    # spellings), numbers, duplicate members and invalid UTF-8 bytes inside strings are copied
    # directly from the source. Invalid JSON and output past `max_output_bytes` return nil.
    # Unlike `reformat`, this is safe for a request editor's write-back path (P7).
    def reindent(json : String, indent : String = "  ", max_output_bytes : Int32? = nil) : String?
      Reindenter.new(json, indent, max_output_bytes).run
    end

    # A streaming JSON lexer/parser that also writes the pretty whitespace. It does not build a
    # value tree or decode strings/numbers, so parser differentials stay available to the user.
    private class Reindenter
      OBJECT = 0_u8
      ARRAY  = 1_u8

      OBJECT_KEY_OR_END = 0_u8
      OBJECT_KEY        = 1_u8
      OBJECT_COLON      = 2_u8
      OBJECT_VALUE      = 3_u8
      OBJECT_END        = 4_u8

      ARRAY_VALUE_OR_END = 0_u8
      ARRAY_VALUE        = 1_u8
      ARRAY_END          = 2_u8
      MAX_DEPTH          =  256

      @source : Bytes
      @json : String
      @indent : Bytes
      @out : IO::Memory
      @max_output_bytes : Int32?
      @kinds : Array(UInt8)
      @states : Array(UInt8)
      @index : Int32
      @root_done : Bool
      @overflow : Bool

      def initialize(@json : String, indent : String, @max_output_bytes : Int32?)
        @source = @json.to_slice
        @indent = indent.to_slice
        @out = IO::Memory.new
        @kinds = [] of UInt8
        @states = [] of UInt8
        @index = 0
        @root_done = false
        @overflow = false
      end

      def run : String?
        first = skip_space(0)
        return nil if first >= @source.size
        return nil unless append_slice(0, first)
        @index = first

        loop do
          return finish_document if @kinds.empty? && @root_done
          return nil unless step
          return nil if @overflow
        end
      end

      private def step : Bool
        @index = skip_space(@index)
        return false if @index >= @source.size
        return value if @kinds.empty?

        case @kinds[-1]
        when OBJECT then object_step
        when ARRAY  then array_step
        else             false
        end
      end

      private def finish_document : String?
        tail = skip_space(@index)
        return nil unless tail == @source.size
        return nil unless append_slice(@index, @source.size)
        return nil if @overflow
        String.new(@out.to_slice)
      end

      private def object_step : Bool
        depth = @kinds.size
        case @states[-1]
        when OBJECT_KEY_OR_END then object_key_or_end(depth)
        when OBJECT_KEY
          return false unless byte?('"')
          object_key
        when OBJECT_COLON
          return false unless byte?(':')
          append_byte(0x3a_u8)
          append_byte(0x20_u8)
          @index += 1
          @states[-1] = OBJECT_VALUE
          true
        when OBJECT_VALUE
          value
        when OBJECT_END then object_end(depth)
        else
          false
        end
      end

      private def object_key_or_end(depth : Int32) : Bool
        if byte?('}')
          append_byte(0x7d_u8)
          @index += 1
          close_container
        elsif byte?('"')
          return false unless newline_indent(depth)
          object_key
        else
          false
        end
      end

      private def object_end(depth : Int32) : Bool
        if byte?(',')
          append_byte(0x2c_u8)
          @index += 1
          return false unless newline_indent(depth)
          @states[-1] = OBJECT_KEY
          true
        elsif byte?('}')
          return false unless newline_indent(depth - 1)
          append_byte(0x7d_u8)
          @index += 1
          close_container
        else
          false
        end
      end

      private def object_key : Bool
        ending = string_end(@index) || return false
        append_slice(@index, ending)
        @index = ending
        @states[-1] = OBJECT_COLON
        !@overflow
      end

      private def array_step : Bool
        depth = @kinds.size
        case @states[-1]
        when ARRAY_VALUE_OR_END
          if byte?(']')
            append_byte(0x5d_u8)
            @index += 1
            close_container
          else
            return false unless newline_indent(depth)
            value
          end
        when ARRAY_VALUE
          value
        when ARRAY_END
          if byte?(',')
            append_byte(0x2c_u8)
            @index += 1
            return false unless newline_indent(depth)
            @states[-1] = ARRAY_VALUE
            true
          elsif byte?(']')
            return false unless newline_indent(depth - 1)
            append_byte(0x5d_u8)
            @index += 1
            close_container
          else
            false
          end
        else
          false
        end
      end

      # Emit one value and mark its parent complete before pushing a nested container. The
      # parent's end/comma state then remains parked underneath the child until it closes.
      private def value : Bool
        return false if @index >= @source.size
        case @source[@index]
        when 0x7b_u8 then container_value(OBJECT, OBJECT_KEY_OR_END, 0x7d_u8)
        when 0x5b_u8 then container_value(ARRAY, ARRAY_VALUE_OR_END, 0x5d_u8)
        when 0x22_u8 then string_value
        when 0x74_u8 then literal_value("true")
        when 0x66_u8 then literal_value("false")
        when 0x6e_u8 then literal_value("null")
        else              number_value
        end
      end

      private def container_value(kind : UInt8, initial_state : UInt8, closing : UInt8) : Bool
        append_byte(@source[@index])
        @index += 1
        @index = skip_space(@index)
        if @index < @source.size && @source[@index] == closing
          append_byte(closing)
          @index += 1
          complete_parent
          return !@overflow
        end
        return false if @kinds.size >= MAX_DEPTH
        complete_parent
        @kinds << kind
        @states << initial_state
        !@overflow
      end

      private def string_value : Bool
        ending = string_end(@index) || return false
        return false unless append_slice(@index, ending)
        @index = ending
        complete_parent
        !@overflow
      end

      private def literal_value(word : String) : Bool
        return false unless literal(word)
        complete_parent
        !@overflow
      end

      private def number_value : Bool
        ending = number_end(@index) || return false
        return false unless append_slice(@index, ending)
        @index = ending
        complete_parent
        !@overflow
      end

      private def complete_parent : Nil
        if @kinds.empty?
          @root_done = true
        elsif @kinds[-1] == OBJECT
          @states[-1] = OBJECT_END
        else
          @states[-1] = ARRAY_END
        end
      end

      private def close_container : Bool
        @kinds.pop
        @states.pop
        !@overflow
      end

      private def literal(word : String) : Bool
        bytes = word.to_slice
        return false if @index + bytes.size > @source.size
        bytes.each_with_index do |b, i|
          return false unless @source[@index + i] == b
        end
        append_slice(@index, @index + bytes.size)
        @index += bytes.size
        !@overflow
      end

      # Returns the end of a JSON string token. Raw bytes >= 0x20 are deliberately not decoded
      # or UTF-8 validated; the captured bytes inside the string are the operator's payload.
      private def string_end(start : Int32) : Int32?
        return nil unless start < @source.size && @source[start] == 0x22_u8
        i = start + 1
        while i < @source.size
          b = @source[i]
          if b == 0x22_u8
            return i + 1
          elsif b == 0x5c_u8
            i += 1
            return nil if i >= @source.size
            escaped = @source[i]
            case escaped
            when 0x22_u8, 0x5c_u8, 0x2f_u8, 0x62_u8, 0x66_u8, 0x6e_u8, 0x72_u8, 0x74_u8
              i += 1
            when 0x75_u8 # \uXXXX; retain even an unpaired surrogate exactly as typed
              return nil if i + 4 >= @source.size
              4.times do |n|
                return nil unless hex?(@source[i + 1 + n])
              end
              i += 5
            else
              return nil
            end
          elsif b < 0x20_u8
            return nil
          else
            i += 1
          end
        end
        nil
      end

      # JSON number grammar, kept as source digits. A suffix such as `01` or `1x` is left for
      # the enclosing state to reject rather than being folded into this token.
      private def number_end(start : Int32) : Int32?
        integer_end = integer_end(start) || return nil
        fraction_end = fraction_end(integer_end) || return nil
        exponent_end(fraction_end)
      end

      private def integer_end(start : Int32) : Int32?
        i = start
        i += 1 if @source[i] == 0x2d_u8 # -
        return nil if i >= @source.size
        if @source[i] == 0x30_u8
          i += 1
        elsif digit_nonzero?(@source[i])
          while i < @source.size && digit?(@source[i])
            i += 1
          end
        else
          return nil
        end
        i
      end

      private def fraction_end(at : Int32) : Int32?
        return at if at >= @source.size || @source[at] != 0x2e_u8 # .
        i = at + 1
        return nil if i >= @source.size || !digit?(@source[i])
        while i < @source.size && digit?(@source[i])
          i += 1
        end
        i
      end

      private def exponent_end(at : Int32) : Int32?
        return at if at >= @source.size || (@source[at] != 0x65_u8 && @source[at] != 0x45_u8)
        i = at + 1
        i += 1 if i < @source.size && (@source[i] == 0x2b_u8 || @source[i] == 0x2d_u8)
        return nil if i >= @source.size || !digit?(@source[i])
        while i < @source.size && digit?(@source[i])
          i += 1
        end
        i
      end

      private def skip_space(at : Int32) : Int32
        while at < @source.size && whitespace?(@source[at])
          at += 1
        end
        at
      end

      private def newline_indent(depth : Int32) : Bool
        return false unless ensure_capacity(1 + depth * @indent.size)
        append_byte(0x0a_u8)
        depth.times { @out.write(@indent) }
        !@overflow
      end

      private def append_slice(start : Int32, stop : Int32) : Bool
        return false unless ensure_capacity(stop - start)
        @out.write(@source[start, stop - start]) if stop > start
        !@overflow
      end

      private def append_byte(byte : UInt8) : Nil
        return unless ensure_capacity(1)
        @out.write_byte(byte)
      end

      private def ensure_capacity(additional : Int32) : Bool
        if limit = @max_output_bytes
          if @out.size + additional > limit
            @overflow = true
            return false
          end
        end
        true
      end

      private def byte?(char : Char) : Bool
        @index < @source.size && @source[@index] == char.ord.to_u8
      end

      private def whitespace?(byte : UInt8) : Bool
        byte == 0x20_u8 || byte == 0x09_u8 || byte == 0x0a_u8 || byte == 0x0d_u8
      end

      private def digit?(byte : UInt8) : Bool
        byte >= 0x30_u8 && byte <= 0x39_u8
      end

      private def digit_nonzero?(byte : UInt8) : Bool
        byte >= 0x31_u8 && byte <= 0x39_u8
      end

      private def hex?(byte : UInt8) : Bool
        digit?(byte) || (byte >= 0x41_u8 && byte <= 0x46_u8) || (byte >= 0x61_u8 && byte <= 0x66_u8)
      end
    end

    # A JSON object's members as {key, compact value}, in order and with duplicates kept; nil
    # when `json` is valid JSON that is not an object. Raises JSON::ParseException on bad
    # syntax.
    def members(json : String) : Array({String, String})?
      pull = JSON::PullParser.new(json)
      unless pull.kind.begin_object?
        pull.read_raw
        finish(pull)
        return nil
      end
      acc = [] of {String, String}
      pull.read_object { |key| acc << {key, pull.read_raw} }
      finish(pull)
      acc
    end

    # The compact object for `members`, values spliced in as the raw JSON they already are.
    def object(members : Array({String, String})) : String
      JSON.build { |j| j.object { members.each { |(k, v)| j.field(k) { j.raw(v) } } } }
    end

    # One member's value, parsed — the LAST occurrence, which is what `JSON.parse` reports
    # for a duplicated key. nil when absent or when that one value is itself unrepresentable,
    # so an oversized `uid` no longer hides the `exp` beside it.
    def member(json : String, key : String) : JSON::Any?
      pair = members(json).try(&.reverse_each.find { |(k, _)| k == key })
      return nil unless pair
      JSON.parse(pair[1])
    rescue JSON::ParseException
      nil
    end

    # A JSON object as a Hash for READING claims: `parse`, narrowed to an object. So a key whose
    # value is an oversized number stays present (`has_key?("exp")`) and every OTHER claim is
    # readable. nil when `json` is not a JSON object or not JSON at all.
    def claims(json : String) : Hash(String, JSON::Any)?
      parse(json).as_h?
    rescue JSON::ParseException
      nil
    end

    # `JSON::Any.new(pull)` with the number arms swapped: the lexer has already vetted the
    # number's syntax, so a failed conversion can only mean it is out of range.
    private def read_any(pull : JSON::PullParser) : JSON::Any
      case pull.kind
      when .int?
        raw = pull.raw_value
        pull.read_next
        JSON::Any.new(raw.to_i64? || raw)
      when .float?
        raw = pull.raw_value
        pull.read_next
        f = raw.to_f64?
        JSON::Any.new(f && f.finite? ? f : raw)
      when .begin_array?
        ary = [] of JSON::Any
        pull.read_array { ary << read_any(pull) }
        JSON::Any.new(ary)
      when .begin_object?
        hash = {} of String => JSON::Any
        pull.read_object { |key| hash[key] = read_any(pull) }
        JSON::Any.new(hash)
      when .null?, .bool?, .string?
        JSON::Any.new(pull)
      else
        raise JSON::ParseException.new("unexpected #{pull.kind}", pull.line_number, pull.column_number)
      end
    end

    # A value followed by anything but end-of-input is not one JSON document.
    private def finish(pull : JSON::PullParser) : Nil
      return if pull.kind.eof?
      raise JSON::ParseException.new("unexpected trailing data", pull.line_number, pull.column_number)
    end
  end
end
