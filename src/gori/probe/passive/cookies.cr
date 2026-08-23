require "./rule"

module Gori
  module Probe
    module Passive
      # Set-Cookie flag hygiene (category "cookies"): Secure / HttpOnly / SameSite, the
      # SameSite=None-without-Secure misconfiguration, and the browser-enforced `__Host-`/
      # `__Secure-` cookie-prefix rules. Response-gated. The name is split from the attribute
      # segments so a cookie literally named "samesite"/"secure" can't masquerade as a flag.
      #
      # A cookie that is being CLEARED (empty value + Max-Age=0 or an Expires attribute — the
      # logout/reset pattern) carries no secret, so its missing flags are suppressed as noise;
      # only live cookies are scored.
      #
      # Also scores the cookie's Domain= SCOPE, which is hygiene of a different kind: not a
      # missing flag but a deliberately widened audience (see `broad_domain`).
      class Cookies < Rule
        def info : RuleInfo
          RuleInfo.new("cookies", "Cookie flags",
            "Checks Set-Cookie hygiene: Secure, HttpOnly, SameSite, __Host-/__Secure- prefix rules, and an over-broad Domain scope.",
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
            value = (eq ? nv[(eq + 1)..] : "").strip
            flags = segs[1..].map(&.strip.downcase)
            # Keep the ORIGINAL-case Expires value for date parsing (flags are lowercased above,
            # which would break HTTP_DATE's month/day names).
            expires_val = segs[1..].map(&.strip).find(&.downcase.starts_with?("expires=")).try(&.partition('=').[2].strip)
            # A cookie being deleted holds no secret — skip its hygiene (avoids logout/reset FPs).
            next if deletion?(value, flags, expires_val)

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

            has_secure = flags.includes?("secure")
            prefixed = check_prefix(ctx, name, flags, has_secure, acc)

            # Secure: the generic issue is subsumed by the more specific prefix violation, so a
            # prefixed cookie reports at most one Secure-related issue.
            if ctx.scheme == "https" && !has_secure && !prefixed
              acc << cookie(ctx, "cookie_no_secure", "Cookie without Secure flag", Store::Severity::Medium, name)
            end
            unless flags.includes?("httponly")
              acc << cookie(ctx, "cookie_no_httponly", "Cookie without HttpOnly flag", Store::Severity::Low, name)
            end
            samesite = flags.find(&.starts_with?("samesite"))
            if samesite.nil?
              acc << cookie(ctx, "cookie_no_samesite", "Cookie without SameSite attribute", Store::Severity::Low, name)
            elsif samesite == "samesite=none" && !has_secure
              # SameSite=None REQUIRES Secure; browsers reject the cookie otherwise.
              acc << cookie(ctx, "cookie_samesite_none_insecure",
                "Cookie SameSite=None without Secure", Store::Severity::Medium, name)
            end
          end
        end

        # True for a cookie being cleared (no secret to protect, so its missing flags are noise):
        #   * Max-Age <= 0 is an UNCONDITIONAL delete regardless of value — a live cookie never
        #     sets it, and frameworks clear with a sentinel value (PHP emits `sid=deleted;
        #     Max-Age=0`), so requiring an empty value would miss the common logout pattern.
        #   * A past Expires deletes the cookie regardless of value too — a logout that uses a
        #     sentinel value (`auth=deleted; Expires=<past>`, no Max-Age) is still a clear, so
        #     the value need not be empty (a live cookie never sets an already-expired date).
        private def deletion?(value : String, flags : Array(String), expires : String?) : Bool
          return true if flags.any? { |f| max_age_delete?(f) }
          return false unless expires
          expires_past?(expires)
        end

        # An Expires already at/before now is a real clear. An UNparsable/odd date is treated as a
        # deletion too, so a framework clearing a cookie with a sentinel date isn't spammed with
        # hygiene issues — only a genuinely FUTURE-dated empty cookie keeps its hygiene checks.
        private def expires_past?(expires : String) : Bool
          Time::Format::HTTP_DATE.parse(expires) <= Time.utc
        rescue
          true
        end

        # Max-Age with a non-positive value (0 or negative) — an immediate deletion (RFC 6265).
        # `flag` is already stripped + lowercased.
        private def max_age_delete?(flag : String) : Bool
          return false unless flag.starts_with?("max-age")
          eq = flag.index('=') || return false
          n = flag[(eq + 1)..].strip.to_i64?
          !n.nil? && n <= 0
        end

        # Validate a __Host-/__Secure- prefixed cookie against its browser-enforced rules;
        # emits one `cookie_prefix_violation` listing every unmet requirement. Returns true when
        # the cookie carries a recognised prefix (so the generic Secure check stands down).
        private def check_prefix(ctx : Context, name : String, flags : Array(String),
                                 has_secure : Bool, acc : Array(Detection)) : Bool
          if name.starts_with?(HOST_PREFIX)
            missing = [] of String
            missing << "Secure" unless has_secure
            missing << "Path=/" unless flags.includes?("path=/")
            missing << "no Domain" if flags.any?(&.starts_with?("domain="))
            emit_prefix(ctx, name, missing, acc) unless missing.empty?
            true
          elsif name.starts_with?(SECURE_PREFIX)
            emit_prefix(ctx, name, ["Secure"], acc) unless has_secure
            true
          else
            false
          end
        end

        # The unmet requirements are joined with " + ", NOT ", ": every cookie code accumulates
        # its evidence across a (code, host) group, and that merge splits the stored string on
        # ", " to dedup (Store.merge_evidence). A ", "-joined requirement list would be torn into
        # bogus fragments ("Path=/" as if it were another cookie's evidence), so the separator
        # inside one cookie's label has to be something the merge does not split on.
        private def emit_prefix(ctx : Context, name : String, missing : Array(String), acc : Array(Detection)) : Nil
          acc << cookie(ctx, "cookie_prefix_violation", "Cookie violates its #{name.starts_with?(HOST_PREFIX) ? "__Host-" : "__Secure-"} prefix rules",
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
        # `flags` arrives already stripped + lowercased, so the comparison needs only the host
        # downcased to match it.
        private def broad_domain(ctx : Context, flags : Array(String)) : String?
          domain = flags.find(&.starts_with?("domain=")).try { |f| f.split('=', 2)[1]?.try(&.strip) }
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
