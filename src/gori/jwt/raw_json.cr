require "json"

module Gori
  module Jwt
    # JSON read WITHOUT converting its numbers. `JSON.parse` turns every number into an Int64
    # or a Float64 and raises on one that fits neither — an unsigned 64-bit id
    # (`18446744073709551615`), an exponent past Float64 (`1.5e400`) — so a single such claim
    # made the whole segment unreadable, and a re-sign that started over from `{}` dropped every
    # other claim the token carried (#1169). The pull parser keeps a number as the digits it
    # arrived as, and walks an object member by member, so this also keeps a duplicated key
    # (`{"sub":"a","sub":"admin"}`, a parser-differential probe) instead of folding it away.
    module RawJson
      extend self

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

      # A JSON object as a Hash for READING claims, the way `JSON.parse(..).as_h?` would give it
      # — the last occurrence of a key wins — except that a value `JSON.parse` cannot hold (a
      # number past Int64/Float64) is carried as its literal text, a String, instead of failing
      # the whole object. So the key stays present (`has_key?("exp")`) and every OTHER claim is
      # readable. nil when `json` is not a JSON object. For reading only: never re-serialize
      # it, since that turns such a number into a string.
      def claims(json : String) : Hash(String, JSON::Any)?
        pairs = members(json)
        return nil unless pairs
        h = {} of String => JSON::Any
        pairs.each do |(k, v)|
          h[k] = begin
            JSON.parse(v)
          rescue JSON::ParseException
            JSON::Any.new(v)
          end
        end
        h
      rescue JSON::ParseException
        nil
      end

      # A value followed by anything but end-of-input is not one JSON document.
      private def finish(pull : JSON::PullParser) : Nil
        return if pull.kind.eof?
        raise JSON::ParseException.new("unexpected trailing data", pull.line_number, pull.column_number)
      end
    end
  end
end
