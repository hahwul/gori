require "./rule"

module Gori
  module Prism
    module Passive
      # Response-body disclosures (category "infoleak", except mixed-content under "headers"):
      # private IPs, server error/stack traces, leaked credentials, and active mixed content.
      # Response-gated; scans the shared, decoded `ctx.body_text`.
      class BodyLeaks < Rule
        # Private-IP ranges with valid 0-255 octets, required to stand alone (not embedded in a
        # longer dotted/word token). The leading/trailing guards keep multi-segment version
        # strings such as "10.1.2.3.4" or "v10.1.2.3" out of the match.
        PRIVATE_IP = /(?<![\w.])(?:10(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}|172\.(?:1[6-9]|2\d|3[01])(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){2}|192\.168(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){2}|127\.0\.0\.1)(?![\w.])/

        # Server-side error / stack-trace signatures, each tightened to a specific frame or
        # exception shape so a mere SYMBOL MENTION in documentation / tutorials / package
        # registries (e.g. "config/routes.rb:15", "ActiveRecord::Base", "org.springframework
        # .boot", "System.ArgumentException") does NOT match — only an actual backtrace frame
        # or a `Type: message` / newline-`at` disclosure does. {pattern, evidence label}.
        ERROR_SIGNATURES = [
          {/Traceback \(most recent call last\)/, "Python traceback"},
          # A real CPython frame (`File "x.py", line N`) — the exact shape, so a bare
          # "app.py:42" path reference (the old colon form's false positive) stays out.
          {/File "[^"]*\.py", line \d+/, "Python stack frame"},
          # Ruby backtrace frame: the `:in ` distinguishes a real frame from a config path.
          {/\.rb:\d+:in /, "Ruby backtrace frame"},
          {/\bat [\w.$]+\([\w]+\.java:\d+\)/, "Java stack frame"},
          {/(?:\n|\A)\s+at [\w.$<>]+ \([^)]*:\d+:\d+\)/, "Node.js stack frame"},
          {/\bORA-\d{5}\b/, "Oracle error"},
          {/\bSQLSTATE\[/, "SQL error"},
          # A Java/.NET exception only counts as a disclosure when error-shaped: followed by a
          # `: message` or a newline-`at` frame — not when merely named in prose.
          {/\bjava\.lang\.[A-Z]\w+(?:Error|Exception)(?::|\r?\n\s*at )/, "Java exception"},
          {/\bat org\.springframework\.[\w.]{4,}/, "Spring framework trace"},
          {/\bSystem\.[A-Z]\w+Exception(?::|\r?\n\s*at )/, ".NET exception"},
          # Rails: any ActiveRecord class, but only when error-shaped (`: message` / newline-
          # `at`), so a real error (RecordNotFound, Rollback, StatementInvalid, …) is caught
          # while the ubiquitous doc mention "ActiveRecord::Base guide" is not.
          {/\bActiveRecord::[A-Z]\w+(?::|\r?\n\s*at )/, "Rails error"},
          {/\b(?:NoMethodError|NameError|NoMatchingPatternError)(?::| \()/, "Ruby error"},
          {/PHP (?:Fatal error|Parse error|Warning|Notice):/, "PHP error"},
          # A real PHP stack/trace frame ("… /var/www/app.php(42): …") — the paren+line form
          # a path reference lacks; keeps the FP-prone bare "app.php:42" colon form out.
          {/\.php\(\d+\)/, "PHP stack frame"},
          # A Go panic dump: the `goroutine N [state]:` header is the runtime's exact shape,
          # so a prose mention of "goroutine" does not match.
          {/\bgoroutine \d+ \[[\w ]+\]:/, "Go stack trace"},
          {/(?:\n|\A)Stack trace:\s*(?:\n|#\d)/, "stack trace"},
        ]

        # High-confidence credential shapes leaked in a response body (anchored to keep FP low).
        # The evidence is the credential TYPE — NEVER the matched value. {pattern, label}.
        SECRET_PATTERNS = [
          {/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/, "AWS access key id"},
          {/\bAIza[0-9A-Za-z_\-]{35}\b/, "Google API key"},
          {/\bgh[pousr]_[0-9A-Za-z]{36}\b/, "GitHub token"},
          {/\bglpat-[0-9A-Za-z_\-]{20}\b/, "GitLab token"},
          {/\bxox[baprs]-[0-9A-Za-z\-]{10,}/, "Slack token"},
          # Stripe LIVE keys only (test keys aren't sensitive); the prefix is distinctive.
          {/\b(?:sk|rk)_live_[0-9A-Za-z]{20,}\b/, "Stripe secret key"},
          {/\bSG\.[\w\-]{16,}\.[\w\-]{16,}\b/, "SendGrid API key"},
          {/\bnpm_[0-9A-Za-z]{36}\b/, "npm access token"},
          {/-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----/, "private key block"},
        ]

        # An active sub-resource (script/iframe) loaded over plain http on an https page —
        # genuine active mixed content (browsers block it; it signals an insecure dependency).
        MIXED_ACTIVE = /<(?:script|iframe)\b[^>]*\bsrc\s*=\s*["']?http:\/\//i

        # A form on an HTTPS page that SUBMITS to a plain-http action: everything the user types
        # (credentials included) is sent in cleartext. Browsers flag this for password fields;
        # it's a distinct, higher-impact case than a passively-loaded sub-resource.
        INSECURE_FORM = /<form\b[^>]*\baction\s*=\s*["']?http:\/\//i

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless ctx.response
          return unless texty?(ctx.content_type)
          text = ctx.body_text
          return if text.nil? || text.empty?
          # Private-IP scan skips script/style payloads, where dotted version strings dominate
          # and produce the bulk of the false positives.
          if !scripty?(ctx.content_type) && (m = PRIVATE_IP.match(text))
            acc << leak(ctx, "private_ip_leak", "Private IP address disclosed", Store::Severity::Low, m[0])
          end
          if hit = ERROR_SIGNATURES.find { |(pat, _)| pat.matches?(text) }
            acc << leak(ctx, "error_stack_leak", "Error/stack trace disclosed", Store::Severity::Medium, hit[1])
          end
          if hit = SECRET_PATTERNS.find { |(pat, _)| pat.matches?(text) }
            acc << leak(ctx, "secret_in_body", "Credential/secret disclosed in response body", Store::Severity::High, hit[1])
          end
          if ctx.html? && ctx.scheme == "https"
            if MIXED_ACTIVE.matches?(text)
              acc << Detection.new("mixed_content", Category::HEADERS, ctx.host, ctx.url,
                "Active mixed content (http:// sub-resource on an HTTPS page)", Store::Severity::Low, nil, ctx.fid)
            end
            if INSECURE_FORM.matches?(text)
              acc << Detection.new("insecure_form_action", Category::HEADERS, ctx.host, ctx.url,
                "Form on an HTTPS page submits over cleartext http://", Store::Severity::Medium, nil, ctx.fid)
            end
          end
        end

        private def leak(ctx : Context, code : String, title : String, sev : Store::Severity, evidence : String?) : Detection
          Detection.new(code, Category::INFOLEAK, ctx.host, ctx.url, title, sev, evidence, ctx.fid)
        end

        private def texty?(ctype : String?) : Bool
          return true if ctype.nil? # unknown — be permissive (the scan is cheap)
          low = ctype.downcase
          low.includes?("text/") || low.includes?("json") || low.includes?("xml") ||
            low.includes?("javascript") || low.includes?("html") || low.includes?("urlencoded")
        end

        private def scripty?(ctype : String?) : Bool
          return false if ctype.nil?
          low = ctype.downcase
          low.includes?("javascript") || low.includes?("ecmascript") || low.includes?("css")
        end
      end
    end
  end
end
