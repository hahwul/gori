require "../serialized"

module Gori::Decoder::Serialized
  # PHP `serialize()` — the typed structure `unserialize()` reads back (#1011).
  #
  # A PHP object graph round-tripping through a cookie or a parameter is the POP-chain surface:
  # `unserialize()` on attacker bytes runs `__wakeup`/`__destruct` on whatever classes the
  # application can autoload, so the class NAMES and the property values are the finding. Both
  # are what this projects.
  #
  # ## What the projection names rather than folds away
  #
  # * An **object** is `{"$class": "Name", …properties…}`. PHP mangles a non-public property's
  #   name on the wire — `\0Class\0prop` for private, `\0*\0prop` for protected — and a NUL in
  #   the middle of a JSON member name is both unreadable and easy to miss, so the name is
  #   demangled and the visibility comes back beside it in `$private` / `$protected`.
  # * A **PHP array** is an ordered map with integer OR string keys, which JSON has no room
  #   for: integer keys render as their decimal text and `"$keys": "non-string"` sits beside
  #   them, the same marker and the same accepted ambiguity as the `Msgpack` reader's.
  # * `r:` and `R:` are **back-references**, and they come back as `{"$ref": n}` rather than
  #   being expanded — see the note on `Serialized`.
  # * `C:` (a `Serializable`'s own `serialize()` output) is bytes this format does not describe.
  #   They go out as `$bin`, because that is what `unserialize` hands the class.
  module Php
    extend self

    def render(data : Bytes, *, indent : String? = nil) : BinaryDocument::Rendering
      Serialized.build(data, indent) { |sink| Reader.new(data, sink) }
    end

    # :ditto: — the two-element form, for a caller that only wants the text and whether it is
    # whole (every spec, and the Decoder converter).
    def to_json(data : Bytes) : {String, Bool}
      r = render(data)
      {r.json, r.complete}
    end

    # A class name, a property name and a `C:` payload are all length-prefixed, and the length
    # is read before anything is allocated. A name past this is not a name.
    MAX_NAME = 64 * 1024

    class Reader < Serialized::Reader
      def document(j : JSON::Builder) : Nil
        value(j, 0)
      end

      private def value(j : JSON::Builder, depth : Int32) : Nil
        return unless step?(j, depth)
        t = byte || return bail(j, "truncated")
        case t
        when 'N'.ord then null_value(j)
        when 'a'.ord then array(j, depth)
        when 'O'.ord then object(j, depth)
        when 'r'.ord then reference(j, false)
        when 'R'.ord then reference(j, true)
        when 'C'.ord then custom(j)
        when 'E'.ord then enum_case(j)
        else              scalar(j, t)
        end
      end

      private def null_value(j : JSON::Builder) : Nil
        return unless expect(j, ';')
        got!
        j.null
      end

      # The four leaf types, split off `value` so neither table has to be read past what it
      # decides.
      private def scalar(j : JSON::Builder, t : UInt8) : Nil
        case t
        when 'b'.ord then boolean(j)
        when 'i'.ord then integer(j)
        when 'd'.ord then double(j)
        when 's'.ord then string(j, false)
        when 'S'.ord then string(j, true)
        else              bail(j, "malformed")
        end
      end

      private def boolean(j : JSON::Builder) : Nil
        return unless expect(j, ':')
        raw = field(j, ';') || return
        s = String.new(raw)
        return bail(j, "malformed") unless s == "0" || s == "1"
        got!
        j.bool(s == "1")
      end

      private def integer(j : JSON::Builder) : Nil
        return unless expect(j, ':')
        raw = field(j, ';') || return
        s = String.new(raw)
        v = s.to_i64?
        return bail(j, "malformed") unless v
        got!
        j.number(v)
      end

      # PHP spells the three values JSON has no literal for as `INF`, `-INF` and `NAN`, and
      # `number` names them rather than dropping them.
      private def double(j : JSON::Builder) : Nil
        return unless expect(j, ':')
        raw = field(j, ';') || return
        s = String.new(raw)
        f = case s
            when "INF"  then Float64::INFINITY
            when "-INF" then -Float64::INFINITY
            when "NAN"  then Float64::NAN
            else             s.to_f64?
            end
        return bail(j, "malformed") unless f
        got!
        number(j, f)
      end

      # `s:<bytes>:"…";` — the length counts BYTES, so the payload may hold a quote or a
      # semicolon and is read by length, never scanned for a terminator. `S:` is the same with
      # `\HH` escapes, where the length counts the DECODED bytes.
      private def string(j : JSON::Builder, escaped : Bool) : Nil
        raw = string_bytes(j, escaped) || return
        got!
        text(j, raw)
      end

      # :ditto: — the bytes themselves, for the callers that need them (a key, a class name).
      private def string_bytes(j : JSON::Builder, escaped : Bool = false) : Bytes?
        return nil unless expect(j, ':')
        n = count(j, ':') || return nil
        return nil unless expect(j, '"')
        raw = escaped ? unescape(n) : take(n)
        if raw.nil?
          # `unescape` stops without writing (`halt`), so the ONE marker for this position is
          # written here — with the reason it remembered, not a second guess at it.
          bail(j, @stop || "truncated")
          return nil
        end
        return nil unless expect(j, '"') && expect(j, ';')
        raw
      end

      # `\HH` hex escapes, decoded to `n` bytes. The length is the DECODED count, so the
      # encoded run is between one and three times as long — which is what makes the guard
      # possible: an escaped run costs AT LEAST one byte per decoded byte, so a length past
      # what is left cannot be truthful, and `Bytes.new(n)` on it would allocate the 2 GB that
      # `S:2000000000:"` asks for in fifteen bytes.
      #
      # Writes nothing on any path: the caller owns the single marker for this position.
      private def unescape(n : Int32) : Bytes?
        if n > remaining
          @pos = @data.size
          halt("truncated")
          return nil
        end
        out = Bytes.new(n)
        i = 0
        while i < n
          b = byte
          unless b
            halt("truncated")
            return nil
          end
          if b == '\\'.ord
            hi = byte
            lo = byte
            v = hi ? hex(hi) : nil
            w = lo ? hex(lo) : nil
            if v.nil? || w.nil?
              halt(hi && lo ? "malformed" : "truncated")
              return nil
            end
            out[i] = ((v << 4) | w).to_u8
          else
            out[i] = b
          end
          i += 1
        end
        out
      end

      private def hex(b : UInt8) : UInt8?
        case b
        when '0'.ord..'9'.ord then (b - '0'.ord).to_u8
        when 'a'.ord..'f'.ord then (b - 'a'.ord + 10).to_u8
        when 'A'.ord..'F'.ord then (b - 'A'.ord + 10).to_u8
        end
      end

      # `a:<count>:{ key value … }`.
      private def array(j : JSON::Builder, depth : Int32) : Nil
        return unless expect(j, ':')
        n = count(j, ':') || return
        return unless expect(j, '{')
        got!
        j.object { members(j, n, depth, demangle: false) }
        consume('}') if @ok
      end

      # `O:<len>:"Class":<count>:{ … }`.
      private def object(j : JSON::Builder, depth : Int32) : Nil
        name = name_bytes(j) || return
        n = count(j, ':') || return
        return unless expect(j, '{')
        got!
        j.object do
          j.field("$class") { text(j, name) }
          members(j, n, depth, demangle: true)
        end
        consume('}') if @ok
      end

      # `C:<len>:"Class":<datalen>:{…}` — a `Serializable`, whose payload is whatever the class
      # itself wrote. This format does not describe those bytes, so they go out as bytes.
      private def custom(j : JSON::Builder) : Nil
        name = name_bytes(j) || return
        n = count(j, ':') || return
        return unless expect(j, '{')
        raw = take(n)
        if raw.nil?
          bail(j, "truncated")
          return
        end
        got!
        j.object do
          j.field("$class") { text(j, name) }
          j.field("$custom") { blob(j, raw) }
        end
        consume('}') if @ok
      end

      # `E:<len>:"Enum:CASE";` — PHP 8.1 enums.
      private def enum_case(j : JSON::Builder) : Nil
        return unless expect(j, ':')
        n = count(j, ':') || return
        return unless expect(j, '"')
        raw = take(n)
        if raw.nil?
          bail(j, "truncated")
          return
        end
        return unless expect(j, '"') && expect(j, ';')
        got!
        j.object { j.field("$enum") { text(j, raw) } }
      end

      # `r:<n>;` / `R:<n>;` — a value already in the stream, EMITTED rather than expanded. See
      # the note on `Serialized`: inlining a shared reference grows the output exponentially,
      # and the sharing is itself a fact about the graph.
      private def reference(j : JSON::Builder, byref : Bool) : Nil
        return unless expect(j, ':')
        raw = field(j, ';') || return
        v = String.new(raw).to_i64?
        return bail(j, "malformed") unless v
        got!
        j.object do
          j.field "$ref", v
          j.field "byref", true if byref
        end
      end

      # `:<len>:"Name":` — the class-name prefix `O:` and `C:` share.
      private def name_bytes(j : JSON::Builder) : Bytes?
        return nil unless expect(j, ':')
        n = count(j, ':') || return nil
        if n > MAX_NAME
          bail(j, "malformed")
          return nil
        end
        return nil unless expect(j, '"')
        raw = take(n)
        if raw.nil?
          bail(j, "truncated")
          return nil
        end
        return nil unless expect(j, '"') && expect(j, ':')
        raw
      end

      # `count` key/value pairs into an object that is already open. A PHP key is an integer or
      # a string and JSON allows only the second, so a non-string key is rendered as its own
      # JSON and used verbatim — with `"$keys": "non-string"` beside it so the reader is not
      # left guessing whether `"1"` was a string on the wire. Same shape, same marker, as
      # `Msgpack::Parser#map`.
      private def members(j : JSON::Builder, n : Int32, depth : Int32, demangle : Bool) : Nil
        plain = true
        private_names = [] of String
        protected_names = [] of String
        n.times do
          break unless @ok
          str_key = string_token?(peek)
          k = scratch { |kj| value(kj, depth + 1) }
          unless @ok
            # The KEY ran out, so its marker went into the scratch builder and nothing has been
            # written here — leaving the object to close as a bare `{}`, which says "empty"
            # rather than "this stopped". The `Msgpack` sibling carries the same sentence in
            # the same place, for the same reason.
            j.field("$partial", @stop || "stopped")
            break
          end
          if str_key && k.starts_with?('"')
            name = JSON.parse(k).as_s
            name = demangle ? unmangle(name, private_names, protected_names) : name
            j.field(name) { value(j, depth + 1) }
          else
            plain = false
            j.field(k) { value(j, depth + 1) }
          end
        end
        j.field("$keys", "non-string") unless plain
        visibility(j, "$private", private_names)
        visibility(j, "$protected", protected_names)
      end

      # STRUCTURALLY, off the key's own type byte — not off whether its rendering came back
      # quoted. BOTH string forms count: `S:` is the hex-escaped spelling, and it is not an
      # academic one, it is how a payload is written to get past a filter looking for `s:`.
      # Missing it put the key's whole JSON rendering — surrounding quotes included — in the
      # member-name position. The ViewState sibling enumerates its string tokens the same way.
      private def string_token?(t : UInt8?) : Bool
        t == 's'.ord.to_u8 || t == 'S'.ord.to_u8
      end

      private def visibility(j : JSON::Builder, field : String, names : Array(String)) : Nil
        return if names.empty?
        j.field(field) { j.array { names.each { |n| j.string(n) } } }
      end

      # `\0Class\0prop` (private) and `\0*\0prop` (protected) back to `prop`, with the property
      # recorded so the visibility is not lost with the mangling.
      private def unmangle(name : String, priv : Array(String), prot : Array(String)) : String
        return name unless name.starts_with?('\0')
        rest = name[1..]
        sep = rest.index('\0') || return name
        owner = rest[0...sep]
        bare = rest[(sep + 1)..]
        return name if bare.empty?
        (owner == "*" ? prot : priv) << bare
        bare
      end

      # A non-negative count or length, terminated by `term`.
      private def count(j : JSON::Builder, term : Char) : Int32?
        raw = field(j, term) || return nil
        v = String.new(raw).to_i64?
        if v.nil? || v < 0 || v > Int32::MAX
          bail(j, "malformed")
          return nil
        end
        v.to_i32
      end

      # Bytes up to `term`, consumed with it. Bounded: a run this long is not a field of this
      # grammar, and scanning to the end of a 32 MiB body for a `;` that is not there is work
      # nobody asked for.
      private def field(j : JSON::Builder, term : Char) : Bytes?
        limit = Math.min(@data.size, @pos + 64)
        stop = @pos
        while stop < limit && @data.unsafe_fetch(stop) != term.ord.to_u8
          stop += 1
        end
        if stop >= limit
          if stop >= @data.size
            # A short read consumed everything that WAS there; see `Reader#take`.
            @pos = @data.size
            bail(j, "truncated")
          else
            bail(j, "malformed")
          end
          return nil
        end
        raw = @data[@pos, stop - @pos]
        @pos = stop + 1
        raw
      end

      # One literal byte of the grammar, with NO output — for the positions where a value has
      # already been written (a closing brace).
      private def consume(ch : Char) : Bool
        b = byte
        unless b
          halt("truncated")
          return false
        end
        return true if b == ch.ord.to_u8
        @pos -= 1
        halt("malformed")
        false
      end

      # :ditto: — in a value position, so the marker naming why is written where the value
      # would have gone.
      private def expect(j : JSON::Builder, ch : Char) : Bool
        return true if consume(ch)
        bail(j, @stop || "malformed")
        false
      end
    end
  end
end
