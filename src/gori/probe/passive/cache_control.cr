require "../../proxy/codec/message"

module Gori
  module Probe
    module Passive
      # `Cache-Control` field parsing, in one place. Two rules read the same header for different
      # questions — `CacheableApi` asks "may anything store this JSON?", `SharedCache` asks "may a
      # SHARED cache store it, and is what it stores keyed on the Origin?" — and both need the same
      # token-exact directive lookup. Splitting the field once and answering off the token list
      # keeps them from drifting on what `public` or `max-age=0` means, and keeps the substring
      # trap out of both: a naive `includes?("public")` also fires on `no-transform, public-ish`,
      # and `includes?("max-age")` cannot tell `max-age=0` from `s-maxage=60`.
      module CacheControl
        extend self

        # One field value split into downcased, stripped directive tokens
        # (`["public", "max-age=60"]`). A comma inside a quoted extension argument is DATA, not a
        # separator: treating `note="private, no-store"` as three directives can suppress a real
        # finding, while `note="public"` can invent one. Ordinary unquoted values keep Crystal's
        # fast native split path; only the rare quoted form pays for the byte-aware tokenizer.
        #
        # nil / empty header ⇒ an empty list, so every predicate below answers false on it and no
        # caller needs a nil branch.
        def parse(value : String?) : Array(String)
          return [] of String if value.nil?
          v = value.strip
          return [] of String if v.empty?
          return v.downcase.split(',').map!(&.strip).reject!(&.empty?) unless v.includes?('"')
          parts = [] of String
          append_quoted(parts, v)
          parts
        end

        # RFC 9110 list fields may arrive as several physical header lines and are equivalent to
        # one comma-joined value. `HeaderList#get?` deliberately returns only the last field, so
        # using it here made the answer depend on wire order: a trailing `public` could hide an
        # earlier `private`, and a trailing extension could hide an earlier `s-maxage`. Walk the
        # parsed projection once and feed every Cache-Control value to the same tokenizer.
        def parse(headers : Proxy::Codec::HeaderList) : Array(String)
          parts = nil.as(Array(String)?)
          headers.each do |header|
            next unless header.name.compare("Cache-Control", case_insensitive: true) == 0
            parsed = parse(header.value)
            next if parsed.empty?
            if acc = parts
              acc.concat(parsed)
            else
              parts = parsed # reuse the first field's array; the common one-field path copies none
            end
          end
          parts || [] of String
        end

        # Token present as a WHOLE directive — `parts` are already stripped and downcased, so the
        # name is whatever precedes the first `=`.
        def directive?(parts : Array(String), name : String) : Bool
          parts.any? { |part| directive_named?(part, name) }
        end

        # The integer argument of `name=…`, or nil when the directive is absent or unparsable.
        # A quoted argument (`max-age="60"`, which RFC 9111 §5.2 permits) is accepted.
        def int(parts : Array(String), name : String) : Int64?
          parts.each do |p|
            next unless directive_named?(p, name)
            eq = p.index('=')
            next unless eq
            raw = p[(eq + 1)..].strip.lstrip('"').rstrip('"')
            if n = raw.to_i64?
              return n
            end
          end
          nil
        end

        # A SHARED (proxy/CDN) cache is explicitly told it may store this response: `public`, or a
        # positive `s-maxage`. Deliberately NOT the heuristic "no directives at all, so a cache may
        # guess" case — that guess is what makes a bare-Cache-Control finding fire on half the web,
        # and the rules that use this are the ones that must only speak when the server said so.
        #
        # `private` overrides: it is the server telling shared caches to keep out, so a
        # contradictory `public, private` is read the safe way rather than reported.
        def shared_storeable?(parts : Array(String)) : Bool
          return false if directive?(parts, "no-store") || directive?(parts, "private")
          return true if directive?(parts, "public")
          !!int(parts, "s-maxage").try { |n| n > 0 }
        end

        # Storeable by SOME cache — the shared directives above, plus a positive `max-age`, which
        # a private browser cache honours. `private` is NOT a veto here (it only bars a shared
        # cache), so `private, max-age=60` is storeable by this question and not by the one above.
        def storeable?(parts : Array(String)) : Bool
          return false if directive?(parts, "no-store")
          return true if directive?(parts, "public")
          return true if !!int(parts, "s-maxage").try { |n| n > 0 }
          !!int(parts, "max-age").try { |n| n > 0 }
        end

        # Append the comma-separated tokens in one field value, respecting quoted-string and its
        # backslash escape. Cache-Control syntax is ASCII; `scrub` contains a hostile non-UTF-8
        # header to this projection without touching the captured wire bytes (P7).
        private def append_quoted(parts : Array(String), value : String) : Nil
          bytes = value.to_slice
          start = 0
          quoted = false
          escaped = false
          i = 0
          while i < bytes.size
            byte = bytes.unsafe_fetch(i)
            if escaped
              escaped = false
            elsif quoted && byte == 0x5c_u8
              escaped = true
            elsif byte == 0x22_u8
              quoted = !quoted
            elsif byte == 0x2c_u8 && !quoted
              append_token(parts, bytes, start, i)
              start = i + 1
            end
            i += 1
          end
          append_token(parts, bytes, start, bytes.size)
        end

        private def append_token(parts : Array(String), bytes : Bytes, start : Int32, finish : Int32) : Nil
          token = String.new(bytes[start, finish - start]).scrub.strip
          parts << token.downcase unless token.empty?
        end

        # Exact directive-name comparison without `split('=')`, which allocated an Array and a
        # substring on every predicate call. On the six lookups CacheableApi makes, the combined
        # parse+query path is ~4x faster and 4.5x lighter (bench/probe_bench). OWS before `=` is
        # tolerated; a prefix such as `public-ish` or `x-no-store` is not a directive hit.
        private def directive_named?(part : String, name : String) : Bool
          return false unless part.starts_with?(name)
          bytes = part.to_slice
          i = name.bytesize
          while i < bytes.size && (bytes.unsafe_fetch(i) == 0x20_u8 || bytes.unsafe_fetch(i) == 0x09_u8)
            i += 1
          end
          i == bytes.size || bytes.unsafe_fetch(i) == 0x3d_u8
        end
      end
    end
  end
end
