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

        # The header split into downcased, stripped directive tokens (`["public", "max-age=60"]`).
        # nil / empty header ⇒ an empty list, so every predicate below answers false on it and no
        # caller needs a nil branch.
        def parse(value : String?) : Array(String)
          return [] of String if value.nil?
          v = value.strip
          return [] of String if v.empty?
          v.downcase.split(',').map!(&.strip).reject!(&.empty?)
        end

        # Token present as a WHOLE directive — `parts` are already stripped and downcased, so the
        # name is whatever precedes the first `=`.
        def directive?(parts : Array(String), name : String) : Bool
          parts.any? { |part| part.split('=').first?.try(&.strip) == name }
        end

        # The integer argument of `name=…`, or nil when the directive is absent or unparsable.
        # A quoted argument (`max-age="60"`, which RFC 9111 §5.2 permits) is accepted.
        def int(parts : Array(String), name : String) : Int64?
          parts.each do |p|
            next unless p.starts_with?("#{name}=") || p.starts_with?("#{name} =")
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
      end
    end
  end
end
