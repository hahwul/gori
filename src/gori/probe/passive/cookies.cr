require "./rule"

module Gori
  module Probe
    module Passive
      # Set-Cookie flag hygiene (category "cookies"): Secure / HttpOnly / SameSite, the
      # SameSite=None-without-Secure misconfiguration, and the browser-enforced `__Host-`/
      # `__Secure-` cookie-prefix rules. Response-gated. The name is split from the attribute
      # segments so a cookie literally named "samesite"/"secure" can't masquerade as a flag.
      #
      # Expiry attributes suppress hygiene only when they establish a deletion. Invalid dates
      # cannot prove deletion, and a valid Max-Age overrides Expires regardless of order.
      #
      # Also scores the cookie's Domain= SCOPE, which is hygiene of a different kind: not a
      # missing flag but a deliberately widened audience (see `broad_domain`).
      # Partitioned and HTTP-prefix requirements:
      # https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie
      # These report configuration defects; prefix/CHIPS enforcement depends on the browser.
      class Cookies < Rule
        def info : RuleInfo
          RuleInfo.new("cookies", "Cookie flags",
            "Checks Set-Cookie flags, SameSite values, Partitioned, security prefixes (including __Http-), and parent Domain scope.",
            Category::COOKIES)
        end

        # A __Host- cookie is browser-rejected unless it is Secure, Path=/, and has NO Domain;
        # a __Secure- cookie is rejected unless Secure. A violation means the security intent
        # silently fails (the cookie is dropped), so it is a distinct, higher-signal issue.
        HOST_PREFIX   = "__Host-"
        SECURE_PREFIX = "__Secure-"

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless resp = ctx.response
          resp.headers.get_all("Set-Cookie").each do |raw|
            segs = raw.split(';')
            nv = segs[0]
            eq = nv.index('=')
            name = (eq ? nv[0...eq] : nv).strip
            next if eq.nil? || name.empty?
            flags = {} of String => String
            max_age = nil.as(Bool?)
            expires = nil.as(Time?)
            # One pass, no sliced/map arrays. Attribute names are exact and case-insensitive;
            # values retain case (Path is case-sensitive). Last valid expiry attribute wins
            # and Max-Age takes precedence over Expires (RFC 6265 §5.2/§5.3).
            segs.each_with_index do |seg, index|
              next if index == 0
              key, _, val = seg.partition('=')
              key = key.strip.downcase
              val = val.strip
              case key
              when "max-age"
                parsed = max_age_delete?(val)
                max_age = parsed unless parsed.nil?
              when "expires"
                parsed = parse_expires(val)
                expires = parsed unless parsed.nil?
              else
                flags[key] = val
              end
            end
            # A cookie being deleted holds no secret — skip its hygiene (avoids logout/reset FPs).
            next if max_age.nil? ? expires.try { |t| t <= Time.utc } : max_age

            # Scope, not flags: a Domain= naming a PARENT of the request host ships this cookie
            # to every sibling subdomain too. Emitted with Detection.new rather than the
            # `cookie` helper because that helper fixes the evidence at the bare cookie name,
            # and the operator needs to see WHICH domain it was widened to.
            # NOT for a __Host- cookie: that prefix forbids Domain outright, so the browser
            # REJECTS the whole cookie — it is shared with nobody, so the "widened audience"
            # claim would be false here. `check_prefix` already reports that as
            # cookie_prefix_violation; a broad-domain finding on top of it is a pure FP.
            if !name.starts_with?(HOST_PREFIX) && (dom = broad_domain(ctx, flags))
              acc << Detection.new("cookie_broad_domain", Category::COOKIES, ctx.host, ctx.url,
                "Cookie scoped to a parent domain", Store::Severity::Info,
                "#{name} (Domain=#{dom})", ctx.fid)
            end

            has_secure = flags.has_key?("secure")
            prefixed = check_prefix(ctx, name, flags, has_secure, acc)

            # Secure: the generic issue is subsumed by the more specific prefix violation, so a
            # prefixed cookie reports at most one Secure-related issue.
            if ctx.scheme == "https" && !has_secure && !prefixed
              acc << cookie(ctx, "cookie_no_secure", "Cookie without Secure flag", Store::Severity::Medium, name)
            end
            unless flags.has_key?("httponly")
              acc << cookie(ctx, "cookie_no_httponly", "Cookie without HttpOnly flag", Store::Severity::Low, name)
            end
            samesite = flags["samesite"]?.try(&.downcase)
            if samesite.nil?
              acc << cookie(ctx, "cookie_no_samesite", "Cookie without SameSite attribute", Store::Severity::Low, name)
            elsif !{"none", "lax", "strict"}.includes?(samesite)
              acc << cookie(ctx, "cookie_invalid_samesite", "Cookie has an invalid SameSite attribute",
                Store::Severity::Low, name)
            elsif samesite == "none" && !has_secure
              # SameSite=None REQUIRES Secure; browsers reject the cookie otherwise.
              acc << cookie(ctx, "cookie_samesite_none_insecure",
                "Cookie SameSite=None without Secure", Store::Severity::Medium, name)
            end
            if flags.has_key?("partitioned") && !has_secure
              acc << cookie(ctx, "cookie_partitioned_insecure", "Partitioned cookie without Secure",
                Store::Severity::Medium, name)
            end
          end
        end

        # Conservative date recognition: an unrecognized legacy date cannot establish deletion.
        private def parse_expires(expires : String) : Time?
          Time::Format::HTTP_DATE.parse(expires)
        rescue
          nil
        end

        # Max-Age with a non-positive value (0 or negative) — an immediate deletion (RFC 6265).
        # Attribute value is already stripped. A leading plus or embedded junk is invalid.
        private def max_age_delete?(value : String) : Bool?
          digits = value.starts_with?('-') ? value.byte_slice(1) : value
          return nil if digits.empty? || !digits.each_byte.all? { |b| b >= 48 && b <= 57 }
          # No integer conversion: huge positive lifetimes remain live, negatives delete.
          value.starts_with?('-') || digits.each_byte.all? { |b| b == 48 }
        end

        # Validate a __Host-/__Secure- prefixed cookie against its browser-enforced rules;
        # emits one `cookie_prefix_violation` listing every unmet requirement. Returns true when
        # the cookie carries a recognised prefix (so the generic Secure check stands down).
        private def check_prefix(ctx : Context, name : String, flags : Hash(String, String),
                                 has_secure : Bool, acc : Array(Detection)) : Bool
          host_prefix = name.starts_with?(HOST_PREFIX)
          http_prefix = name.starts_with?("__Http-") || name.starts_with?("__Host-Http-")
          return false unless host_prefix || http_prefix || name.starts_with?(SECURE_PREFIX)
          missing = [] of String
          missing << "Secure" unless has_secure
          missing << "HttpOnly" if http_prefix && !flags.has_key?("httponly")
          if host_prefix
            missing << "Path=/" unless flags["path"]? == "/"
            missing << "no Domain" if flags.has_key?("domain")
          end
          emit_prefix(ctx, name, missing, acc) unless missing.empty?
          true
        end

        # The unmet requirements are joined with " + ", NOT ", ": every cookie code accumulates
        # its evidence across a (code, host) group, and that merge splits the stored string on
        # ", " to dedup (Store.merge_evidence). A ", "-joined requirement list would be torn into
        # bogus fragments ("Path=/" as if it were another cookie's evidence), so the separator
        # inside one cookie's label has to be something the merge does not split on.
        private def emit_prefix(ctx : Context, name : String, missing : Array(String), acc : Array(Detection)) : Nil
          acc << cookie(ctx, "cookie_prefix_violation", "Cookie violates its security prefix requirements",
            Store::Severity::Medium, "#{name}: needs #{missing.join(" + ")}")
        end

        # The cookie's Domain= — normalised, leading "." dropped — when it scopes the cookie to a
        # STRICT PARENT of the request host; nil otherwise. `app.example.com` setting
        # `Domain=example.com` also sends the cookie to `anything-else.example.com`, so one
        # attacker-influenced sibling (a subdomain takeover, a vulnerable app next door) can read
        # the session or toss a cookie back. Info, not a finding: a broad Domain is frequently
        # deliberate (SSO shared across subdomains), so this is a hardening note.
        #
        # Only the STRICT widening fires, which is what keeps it quiet:
        #   * host == domain — the apex serving its own cookie — is the common, intended shape,
        #     and flagging it would put an Info on nearly every site.
        #   * a Domain that does not cover the host at all is browser-REJECTED, so the cookie is
        #     never shared with anyone and there is nothing to report.
        #   * no Domain attribute is a host-only cookie: correctly scoped by construction.
        # Domain values and the host are compared case-insensitively.
        private def broad_domain(ctx : Context, flags : Hash(String, String)) : String?
          domain = flags["domain"]?.try(&.downcase)
          return nil if domain.nil? || domain.empty?
          # A single leading dot is the RFC 2965 spelling of the same scope (".example.com"),
          # not a different domain — normalise it away so the evidence reads consistently.
          domain = domain.lchop('.')
          return nil if domain.empty?
          host = ctx.host.downcase
          (host != domain && host.ends_with?(".#{domain}")) ? domain : nil
        end

        private def cookie(ctx : Context, code : String, title : String, sev : Store::Severity, name : String) : Detection
          Detection.new(code, Category::COOKIES, ctx.host, ctx.url, title, sev, name, ctx.fid)
        end
      end
    end
  end
end
