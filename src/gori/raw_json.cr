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
