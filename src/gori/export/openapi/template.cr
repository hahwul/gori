require "../../sitemap"
require "../../redact"

module Gori
  module Export
    module OpenApi
      # Captured request path → OpenAPI path template (#1241): `/users/123/orders/9f1c…` →
      # `/users/{userId}/orders/{orderId}`.
      #
      # NOT the Sitemap's folding. That is a DISPLAY choice over a tree of siblings: a numeric id
      # folds only past `SEQUENCE_GROUP_THRESHOLD` siblings, into a `[1, 2, 3 … +N]` row, so a
      # single captured `/users/123` stays literal — right for a tree an operator reads, wrong
      # for a spec, where that path IS `/users/{id}`. So this is a per-path function with its
      # own numeric rule, reusing only the Sitemap's per-SEGMENT classifier
      # (`Sitemap.template_class`: `{uuid}` / `{hex}` / `{date}`, which deliberately leaves
      # numerics alone) and its endpoint key (`Sitemap.node_path`).
      #
      # A pure-numeric segment templates ALWAYS, sibling count or not. The known cost is a
      # numeric segment that is really a route (`/archive/2024`); it comes out as a parameter,
      # which still describes what was captured. The alternative — only when two siblings
      # differ — leaves every singly-captured id literal, which is the case the export exists for.
      #
      # A path is also where credentials hide: a magic-link JWT, a webhook secret, a
      # `;jsessionid=` matrix parameter. The path key is written even without examples, so such a
      # segment is templated as an opaque `Token` and a matrix parameter is cut off — the key
      # says the route, never the bytes that authorised it.
      module Template
        extend self

        # What a templated segment was.
        enum Kind
          Integer # 123
          Uuid    # 3f1c…-…
          Hex     # 9f1c2b7d0a4e (12+ hex digits)
          Date    # 2026-07-19
          Token   # eyJhbGciOi….….… or a long mixed-case random string
        end

        # A segment this long, of URL-safe base64 characters, with upper case, lower case AND a
        # digit, reads as a random token rather than a word or a slug (slugs are lower case).
        TOKEN_MIN = 16

        # One path parameter: its name in the template, the kind of segment it replaced, the
        # captured segment (the example source — see OpenApi for when one is emitted), and the
        # literal segment before it, which says what the value IS (`otp`, `cards`).
        record Param, name : String, kind : Kind, raw : String, prev : String?

        # `path` is the OpenAPI path key; `params` are its `{…}` parameters in path order.
        record Result, path : String, params : Array(Param)

        # Bytes kept verbatim in a literal segment: RFC 3986 `pchar` minus `%` (a `%XX` escape
        # is kept as-is by `literal`, a stray `%` is escaped). Everything else — `{` / `}`
        # above all, which a spec reader takes for a template, plus space, controls, non-ASCII
        # and invalid UTF-8 — is percent-encoded, so the key is always a valid path.
        SAFE = Set(UInt8).new("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@".bytes)

        # Template one endpoint path — the Sitemap's node key with the query cut
        # (`ParamInventory.endpoint_path`), which always starts with `/`.
        def of(endpoint_path : String) : Result
          segments = endpoint_path.split('/')
          segments.shift if segments.first? == ""
          return Result.new("/", [] of Param) if segments.empty? || segments == [""]
          used = Set(String).new
          params = [] of Param
          prev_literal : String? = nil
          path = String.build do |io|
            segments.each do |raw|
              io << '/'
              seg = strip_matrix(raw)
              if kind = kind_of(seg)
                name = unique(param_name(prev_literal), used)
                params << Param.new(name, kind, seg, prev_literal)
                io << '{' << name << '}'
                prev_literal = nil
              else
                safe = literal(seg)
                io << safe
                prev_literal = safe # ASCII by construction: the naming regexes below never see raw bytes
              end
            end
          end
          Result.new(path, params)
        end

        # The kind a segment templates as, or nil for a literal.
        def kind_of(seg : String) : Kind?
          return Kind::Integer if Sitemap.numeric_label?(seg)
          case Sitemap.template_class(seg)
          when "{uuid}" then Kind::Uuid
          when "{hex}"  then Kind::Hex
          when "{date}" then Kind::Date
          else               token?(seg) ? Kind::Token : nil
          end
        end

        # A credential-shaped segment: one of the redaction's built-in shapes (a JWT), or a long
        # mixed-case random string. ASCII-gated before any regex — PCRE2 raises on invalid UTF-8.
        def token?(seg : String) : Bool
          return false unless seg.ascii_only?
          return true if Redact::BUILTIN_PATTERNS.any? { |(rx, _)| rx.matches?(seg) }
          return false if seg.size < TOKEN_MIN
          upper = lower = digit = false
          seg.each_byte do |b|
            case b
            when 0x41_u8..0x5a_u8 then upper = true
            when 0x61_u8..0x7a_u8 then lower = true
            when 0x30_u8..0x39_u8 then digit = true
            when 0x2d_u8, 0x5f_u8 # '-' and '_', base64url
            else return false
            end
          end
          upper && lower && digit
        end

        # `login;jsessionid=AB12…` → `login`. A `;name=value` matrix parameter is not route
        # structure, and the one real clients send is a session id.
        def strip_matrix(seg : String) : String
          semi = seg.index(';') || return seg
          seg.index('=', semi) ? seg[0, semi] : seg
        end

        # A literal segment made safe as part of an OpenAPI path key (see SAFE).
        def literal(seg : String) : String
          bytes = seg.to_slice
          return seg if bytes.all? { |b| SAFE.includes?(b) }
          String.build do |io|
            i = 0
            while i < bytes.size
              b = bytes[i]
              if SAFE.includes?(b)
                io << b.unsafe_chr
              elsif b == 0x25_u8 && i + 2 < bytes.size && hex?(bytes[i + 1]) && hex?(bytes[i + 2])
                io << '%' << bytes[i + 1].unsafe_chr << bytes[i + 2].unsafe_chr # an escape already
                i += 2
              else
                io << '%' << b.to_s(16, upcase: true).rjust(2, '0')
              end
              i += 1
            end
          end
        end

        # `users` → `userId`; `user-groups` → `userGroupId`. The preceding LITERAL segment names
        # the parameter; after another parameter, at the root, or behind a segment with no
        # letters, it is plain `id`.
        #
        # By POSITION only, never by what the segment looked like: `/reports/2026-07-19` and
        # `/reports/123` must be ONE path, because OpenAPI forbids two templated paths that differ
        # only in their parameter names. The kinds seen there go to the parameter's schema.
        def param_name(prev : String?) : String
          suffix = "Id"
          fallback = "id"
          return fallback unless prev
          # A `%XX` escape's hex digits are not letters of the name (`%E4%B8%AD` is not "E4B8AD").
          words = prev.gsub(/%[0-9A-Fa-f]{2}/, " ").split(/[^A-Za-z0-9]+/).reject(&.empty?)
          return fallback if words.empty? || !words[0][0].ascii_letter?
          words[-1] = singular(words[-1])
          base = String.build do |io|
            words.each_with_index do |w, i|
              io << (i == 0 ? w[0].downcase : w[0].upcase) << w[1..]
            end
          end
          # `/ids/1` → `id` + `Id` would read `idId`; the bare suffix-free name says it better.
          return fallback if base.downcase == fallback
          "#{base}#{suffix}"
        end

        # English plural → singular, for the handful of shapes REST paths actually use. A word
        # this does not recognise is kept whole (`status` → `statusId`, not `statuId`).
        private def singular(w : String) : String
          d = w.downcase
          return w if d.size <= 2 || d.ends_with?("ss") || d.ends_with?("us") || d.ends_with?("is")
          return "#{w[0...-3]}y" if d.ends_with?("ies")
          return w[0...-2] if d.ends_with?("sses") || d.ends_with?("xes")
          return w[0...-1] if d.ends_with?('s')
          w
        end

        # A parameter name unique within one path: `id`, `id2`, `id3` …
        private def unique(name : String, used : Set(String)) : String
          candidate = name
          n = 1
          while used.includes?(candidate)
            n += 1
            candidate = "#{name}#{n}"
          end
          used << candidate
          candidate
        end

        private def hex?(b : UInt8) : Bool
          (0x30_u8 <= b <= 0x39_u8) || (0x41_u8 <= b <= 0x46_u8) || (0x61_u8 <= b <= 0x66_u8)
        end
      end
    end
  end
end
