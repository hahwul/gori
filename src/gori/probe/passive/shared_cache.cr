require "./rule"
require "./cache_control"

module Gori
  module Probe
    module Passive
      # What a shared cache is allowed to keep, and what it keys that copy on. Both findings are the
      # same failure seen from two sides: a proxy/CDN storing one client's response and handing it
      # to the next.
      #
      #   * `cacheable_set_cookie` (headers) — the response both SETS a cookie and tells a shared
      #     cache it may store it. Whoever the cache serves that copy to is issued the same
      #     `Set-Cookie`: a session shared between strangers if it is a session cookie, and a CSRF
      #     token everyone holds if it is that. This is the CDN-in-front-of-a-logged-in-page bug.
      #   * `cors_no_vary_origin` (cors) — the response ECHOES the request `Origin` into
      #     `Access-Control-Allow-Origin` while being cacheable and NOT varying on `Origin`. The
      #     cached copy carries one requester's origin in a header the next requester's browser will
      #     read, so the allowlist a cache serves has nothing to do with who is asking.
      #
      # Both gate on the server having said so EXPLICITLY, never on the heuristic "no directives,
      # so a cache may guess". That guess is true of most of the web and would make this rule fire
      # everywhere. `cacheable_set_cookie` requires `public` / `s-maxage` (a shared cache was
      # invited); `cors_no_vary_origin` also fires on a positive `max-age` (RFC 9111 lets a shared
      # cache honour that) but not on `private`, which is the server telling shared caches to keep
      # out — a `private, max-age=60` API response is a browser cache, not a CDN.
      #
      # `CacheableApi` is the neighbour, not the overlap: it asks whether a JSON BODY may be stored
      # at all (and gates on the response being authenticated), where this asks what a SHARED cache
      # does with the response's headers. A JSON login response can legitimately be both.
      class SharedCache < Rule
        def info : RuleInfo
          RuleInfo.new("shared_cache", "Shared-cache exposure",
            "Flags a Set-Cookie on a publicly cacheable response, and a reflected CORS origin cached without Vary: Origin.",
            Category::HEADERS)
        end

        # Cookie names whose being shared between clients is a session compromise rather than a
        # hygiene note. Matched as a substring of the downcased name, so `__Host-session_id`,
        # `XSRF-TOKEN` and `remember_me` all land here.
        SESSION_ISH = /session|sess_|sessid|auth|token|jwt|login|remember|csrf|xsrf|sid\b/i

        MAX_COOKIE_NAMES = 3

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless resp = ctx.response
          parts = CacheControl.parse(resp.headers.get?("Cache-Control"))
          check_set_cookie(ctx, resp, parts, acc)
          check_cors_vary(ctx, resp, parts, acc)
        end

        private def check_set_cookie(ctx : Context, resp : Proxy::Codec::RawResponse,
                                     parts : Array(String), acc : Array(Detection)) : Nil
          cookies = resp.headers.get_all("Set-Cookie")
          return if cookies.empty?
          return unless CacheControl.shared_storeable?(parts)
          names = cookies.compact_map { |c| cookie_name(c) }
          return if names.empty?
          session = names.any? { |n| SESSION_ISH.matches?(n) }
          shown = names.first(MAX_COOKIE_NAMES).join(" ")
          shown = "#{shown} …" if names.size > MAX_COOKIE_NAMES
          acc << Detection.new("cacheable_set_cookie", Category::HEADERS, ctx.host, ctx.url,
            "Set-Cookie on a response a shared cache may store",
            session ? Store::Severity::High : Store::Severity::Medium,
            "#{shown} (#{directive_evidence(parts)})", ctx.fid)
        end

        private def check_cors_vary(ctx : Context, resp : Proxy::Codec::RawResponse,
                                    parts : Array(String), acc : Array(Detection)) : Nil
          # Exactly one ACAO, for the reason `Cors` documents: with zero or several the browser
          # fails the check outright, so there is no cached policy to get wrong.
          acao_all = resp.headers.get_all("Access-Control-Allow-Origin")
          return unless acao_all.size == 1
          acao = acao_all.first.strip
          # `*` and `null` are CONSTANTS — the same bytes whoever asks — so a cache serving them to
          # the next requester serves exactly what the server would have. Only a value that varies
          # with the request can be mis-served, and the one way to know passively that it varies is
          # to catch it echoing THIS request's Origin.
          return if acao.empty? || acao == "*" || acao.downcase == "null"
          origin = ctx.request_origin.try(&.strip)
          return unless origin && !origin.empty? && acao == origin
          # `private` bars shared caches even when `max-age` is set; a per-user browser copy of
          # one origin's ACAO cannot be served to another origin.
          return unless CacheControl.storeable?(parts)
          return if CacheControl.directive?(parts, "private")
          return if varies_on_origin?(resp)
          acc << Detection.new("cors_no_vary_origin", Category::CORS, ctx.host, ctx.url,
            "Reflected CORS origin on a cacheable response without Vary: Origin",
            Store::Severity::Low, "#{acao[0, 80]} (#{directive_evidence(parts)})", ctx.fid)
        end

        # `Vary` may be split across several headers (RFC 9110 §5.3 field-value combination), so
        # read them all. `Vary: *` means the response is never reused for another request, which is
        # a stricter answer than naming Origin and is equally safe.
        private def varies_on_origin?(resp : Proxy::Codec::RawResponse) : Bool
          resp.headers.get_all("Vary").any? do |v|
            v.scrub.downcase.split(',').any? do |tok|
              t = tok.strip
              t == "origin" || t == "*"
            end
          end
        end

        # `name` from a `Set-Cookie: name=value; …` line; nil for the attribute-only garbage a
        # malformed header can be. Only the NAME is ever read — the value is the secret.
        private def cookie_name(header : String) : String?
          first = header.split(';', 2)[0]
          eq = first.index('=') || return nil
          name = first[0...eq].strip.scrub.gsub(/[^\x20-\x7e]/, "")
          name = name[0, 48] if name.size > 48
          name.empty? ? nil : name
        end

        # The directive that made this storeable, for the evidence string. Reported rather than the
        # whole header so a long `Cache-Control` cannot bloat the issue row.
        private def directive_evidence(parts : Array(String)) : String
          return "Cache-Control: public" if CacheControl.directive?(parts, "public")
          if n = CacheControl.int(parts, "s-maxage")
            return "s-maxage=#{n}" if n > 0
          end
          if n = CacheControl.int(parts, "max-age")
            return "max-age=#{n}" if n > 0
          end
          "cacheable"
        end
      end
    end
  end
end
