require "./rule"
require "./secrets"

module Gori
  module Probe
    module Passive
      # Response-body disclosures (category "infoleak", except mixed-content under "headers"):
      # private IPs, server error/stack traces, leaked credentials, and active mixed content.
      # Response-gated; scans the shared, decoded `ctx.body_text`.
      class BodyLeaks < Rule
        def info : RuleInfo
          RuleInfo.new("body_leaks", "Response body leaks",
            "Scans response bodies for private IPs, stack traces, secrets, mixed content, and insecure form actions.",
            Category::INFOLEAK)
        end

        # RFC 1918 private-IP ranges with valid 0-255 octets, required to stand alone (not
        # embedded in a longer dotted/word token). The leading/trailing guards keep multi-segment
        # version strings such as "10.1.2.3.4" or "v10.1.2.3" out of the match. Loopback
        # (127.0.0.1) is DELIBERATELY excluded: it is not an internal-network address, aids no
        # reconnaissance (everyone knows localhost), and is ubiquitous in JS bundles, source maps,
        # dev configs, and CSP report URIs — flagging it was almost pure false positive.
        PRIVATE_IP = /(?<![\w.])(?:10(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}|172\.(?:1[6-9]|2\d|3[01])(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){2}|192\.168(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){2})(?![\w.])/

        # Server-side error / stack-trace signatures, each tightened to a specific frame or
        # exception shape so a mere SYMBOL MENTION in documentation / tutorials / package
        # registries (e.g. "config/routes.rb:15", "ActiveRecord::Base", "org.springframework
        # .boot", "System.ArgumentException") does NOT match — only an actual backtrace frame
        # or a `Type: message` / newline-`at` disclosure does. {pattern, evidence label}.
        #
        # The three line-anchored frames use `^` under `/m`, NOT the `(?:\n|\A)` spelling they
        # were written with. The two mean the same thing — `^` under PCRE2_MULTILINE matches at
        # the subject start and just after every `\n`, which is exactly where `\A` or a consumed
        # `\n` leaves the cursor — but the alternation DEFEATS PCRE2's start optimization: with
        # it the engine has no usable first-code-unit set and walks every offset, while `^` lets
        # it memchr from newline to newline. Measured over a 64 KiB minified bundle (which has
        # almost no newlines, i.e. the case the optimization should win biggest on): Node.js
        # frame 239.9µs → 30.4µs, Spring trace 183.6µs → 24.5µs. Same shape as this file's
        # per-pattern-literal note below: give PCRE something to skip on.
        #
        # Crystal's `m` sets PCRE2_DOTALL as well as PCRE2_MULTILINE, so it also makes `.` match
        # a newline. Harmless for exactly these three: none of them contains a bare `.` — every
        # dot is either escaped (`\.`) or inside a character class — and a negated class such as
        # `[^)]*` has always crossed newlines regardless of the flag. Check that before adding
        # `/m` to a fourth.
        ERROR_SIGNATURES = [
          {/Traceback \(most recent call last\)/, "Python traceback"},
          # A real CPython frame (`File "x.py", line N`) — the exact shape, so a bare
          # "app.py:42" path reference (the old colon form's false positive) stays out.
          {/File "[^"]*\.py", line \d+/, "Python stack frame"},
          # Ruby backtrace frame: the `:in ` distinguishes a real frame from a config path.
          {/\.rb:\d+:in /, "Ruby backtrace frame"},
          {/\bat [\w.$]+\([\w]+\.java:\d+\)/, "Java stack frame"},
          {/^\s+at [\w.$<>]+ \([^)]*:\d+:\d+\)/m, "Node.js stack frame"},
          {/\bORA-\d{5}\b/, "Oracle error"},
          {/\bSQLSTATE\[/, "SQL error"},
          # A Java/.NET exception only counts as a disclosure when error-shaped: followed by a
          # `: message` or a newline-`at` frame — not when merely named in prose.
          {/\bjava\.lang\.[A-Z]\w+(?:Error|Exception)(?::|\r?\n\s*at )/, "Java exception"},
          # Require a real stack-frame shape (start-of-line `at …(` call site) like the sibling
          # Java/Node frames — a bare "…at org.springframework.Foo…" in prose must NOT match.
          {/^\s*at org\.springframework\.[\w.$]{4,}\(/m, "Spring framework trace"},
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
          {/^Stack trace:\s*(?:\n|#\d)/m, "stack trace"},
        ]

        # Alias for callers/tests that still reference BodyLeaks::SECRET_PATTERNS.
        SECRET_PATTERNS = Secrets::PATTERNS

        # An active sub-resource (script/iframe) loaded over plain http on an https page —
        # genuine active mixed content (browsers block it; it signals an insecure dependency).
        # The (?<![-\w]) guard requires a real attribute boundary before `src`, so a hyphenated
        # data attribute (`data-src="http://…"`, a lazy-loading placeholder) doesn't false-match
        # — `\b` alone treated the hyphen as a boundary.
        MIXED_ACTIVE = /<(?:script|iframe|embed)\b[^>]*(?<![-\w])src\s*=\s*["']?http:\/\//i
        # A stylesheet or <object> is also ACTIVE mixed content (browsers block it). Attribute
        # order varies, so two lookaheads assert both attrs are present in the same <link> tag.
        MIXED_ACTIVE_LINK   = /<link\b(?=[^>]*(?<![-\w])rel\s*=\s*["']?stylesheet)(?=[^>]*(?<![-\w])href\s*=\s*["']?http:\/\/)[^>]*>/i
        MIXED_ACTIVE_OBJECT = /<object\b[^>]*(?<![-\w])data\s*=\s*["']?http:\/\//i
        # PASSIVE mixed content: an http:// image/media on an HTTPS page. Lower impact (not
        # blocked, but tamperable + downgrades the lock icon).
        MIXED_PASSIVE = /<(?:img|audio|video|source)\b[^>]*(?<![-\w])src\s*=\s*["']?http:\/\//i

        # A form on an HTTPS page that SUBMITS to a plain-http action: everything the user types
        # (credentials included) is sent in cleartext. Browsers flag this for password fields;
        # it's a distinct, higher-impact case than a passively-loaded sub-resource.
        INSECURE_FORM = /<form\b[^>]*(?<![-\w])action\s*=\s*["']?http:\/\//i

        # A javascript: URL in an executable attribute — a client-side script sink. The negative
        # lookahead drops the ubiquitous no-op forms (javascript:void(0), javascript:;).
        INLINE_JS_URI = /(?<![-\w])(?:href|src|action|formaction)\s*=\s*["']?javascript:(?!\s*(?:void|;|"|'))/i
        # An <a target="_blank"> tag; reverse-tabnabbing risk unless it carries rel=noopener.
        ANCHOR_BLANK = /<a\b[^>]*(?<![-\w])target\s*=\s*["']?_blank\b[^>]*>/i
        # The rel token that defuses it. Matched case-INSENSITIVELY: ANCHOR_BLANK is /i, so it
        # happily matched `<a TARGET="_blank" REL="NOOPENER">`, and the suppression test was a
        # case-SENSITIVE `includes?` that then failed to recognise the very rel that made the tag
        # safe — a guaranteed false positive on any uppercase markup.
        REL_NOOPENER = /\bno(?:opener|referrer)\b/i

        # Cheap gates for the HTML sink checks, each a NECESSARY condition of the regex(es) it
        # guards: the five mixed-content/insecure-form patterns all contain `http://`, and
        # ANCHOR_BLANK contains `_blank`. Both are /i, so these are too.
        #
        # These are REGEXES. They were `AsciiBytes.contains_ci?` byte scans, chosen over
        # `String#includes?` because that one is case-SENSITIVE — but the interesting property
        # was never allocation, it was scan speed, and `contains_ci?` is a naive O(hay·needle)
        # walk just like `includes?`. Over the 200 KiB `client_body_text` these read, a clean
        # page measured: `http://` 123.0µs → 56.9µs as a regex, `_blank` 91.3µs → 50.1µs. PCRE2
        # memchr-skips a plain literal and an `/i` literal costs the same as a case-sensitive one,
        # so the regex is both faster AND keeps the case-insensitivity that ruled `includes?` out.
        #
        # This is specific to a BODY-SIZED, already-scrubbed subject. `AsciiBytes` is still the
        # right tool where the sibling rules use it — a Content-Type or a request target, where
        # the input is short (so the naive scan never gets going) or possibly INVALID UTF-8, on
        # which PCRE2 raises outright.
        private HTTP_GATE  = /http:\/\//i
        private BLANK_GATE = /_blank/i

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless ctx.response
          return unless texty?(ctx.content_type)
          text = ctx.body_text
          return if text.nil? || text.empty?
          # Private-IP scan skips script/style payloads, where dotted version strings dominate
          # and produce the bulk of the false positives. A 4-part software/assembly version
          # (e.g. "File version 10.0.1.2", {"version":"10.0.0.0"}) also collides with 10.0.0.0/8,
          # so skip a candidate immediately preceded by a version-context word and report the
          # first genuine (non-version) private IP instead.
          if !scripty?(ctx.content_type)
            text.scan(PRIVATE_IP) do |m|
              # Only the few chars BEFORE the match decide version-context; slice a bounded window
              # off the match index rather than m.pre_match (which allocates the whole prefix — over
              # a body full of version-shaped candidates that is O(n²) transient memory).
              start = m.begin(0) || 0
              next if version_context?(text[{start - 24, 0}.max...start])
              acc << leak(ctx, "private_ip_leak", "Private IP address disclosed", Store::Severity::Low, m[0])
              break
            end
          end
          # Report EVERY distinct error-signature / secret TYPE present, not just the
          # first: a body leaking both a Java exception and a Go panic (or an AWS key
          # AND a GitHub token) previously surfaced only the earliest array entry, so
          # every other distinct disclosure in the same body was silently missed.
          # NOTE: each pattern is scanned individually on purpose — every one carries a
          # distinctive literal anchor (AKIA / -----BEGIN / Traceback / ORA- / goroutine …)
          # that PCRE's first-byte optimization uses to skip a clean body in ~memchr time.
          # A single `Regex.union` alternation is ~5× SLOWER (measured, bench/probe_bench):
          # it defeats that per-pattern prefilter, so the loop stays.
          ERROR_SIGNATURES.each do |(pat, label)|
            acc << leak(ctx, "error_stack_leak", "Error/stack trace disclosed", Store::Severity::Medium, label) if pat.matches?(text)
          end
          Secrets::PATTERNS.each do |(pat, label)|
            acc << leak(ctx, "secret_in_body", "Credential/secret disclosed in response body", Store::Severity::High, label) if pat.matches?(text)
          end
          # A JWT is reported separately at Info, NOT as a High `secret_in_body`: shipping the
          # client its own token is the normal design, not a disclosure (see Secrets::JWT).
          acc << leak(ctx, "jwt_in_body", "JSON Web Token in a response body",
            Store::Severity::Info, nil) if Secrets::JWT[0].matches?(text)
          # The tag-shaped checks read the LARGER prefix (client_body_text, CLIENT_BODY_CAP) —
          # see check_html_sinks. It is nil only when the body is empty, which `text` above has
          # already ruled out for this branch, so the fallback is belt-and-braces.
          check_html_sinks(ctx, acc, ctx.client_body_text || text) if ctx.html?
        end

        # HTML-only client-side sink checks: mixed content (active/passive), insecure form
        # actions, javascript: URLs, and reverse-tabnabbing links. Split out of check so each
        # method stays under the complexity budget.
        #
        # These read `client_body_text` (CLIENT_BODY_CAP, 256 KiB), NOT the 64 KiB `body_text`
        # the leak scans above use. A tag is a tag wherever it sits in the document, and the
        # sibling rule that walks the very same tags — Sri — has always read the larger prefix:
        # on a 120 KiB page that split reported the unhashed third-party <script> and stayed
        # silent about the plain-http one beside it. The larger text costs no extra decode (it
        # is one slice of the same shared buffer, already materialised for every HTML flow by
        # the client-side rules), so only the SCAN grows — and the checks whose own pattern
        # cannot anchor gate on a cheap literal regex first, which pays that back on a clean page.
        #
        # The leak scans (private IP / error / secret) deliberately stay on the 64 KiB prefix:
        # that is the shared BODY_CAP every non-client rule works from, and widening a content
        # scan is a different, measurable trade from widening a tag scan.
        private def check_html_sinks(ctx : Context, acc : Array(Detection), text : String) : Nil
          check_mixed_content(ctx, acc, text) if ctx.scheme == "https" && HTTP_GATE.matches?(text)
          # INLINE_JS_URI runs UNGUARDED: it already opens on an attribute-name alternation that
          # PCRE anchors well (55.4µs on the 200 KiB page), so the `javascript:` gate in front of
          # it (105.4µs) was pure overhead — a prefilter in front of something that prefilters
          # itself, which is the trap the gates above are sized against. ANCHOR_BLANK is the
          # opposite case and keeps its gate: it opens on `<a`, so unguarded it costs 121.1µs.
          if INLINE_JS_URI.matches?(text)
            acc << Detection.new("inline_js_uri", Category::CLIENT, ctx.host, ctx.url,
              "javascript: URL in an HTML attribute", Store::Severity::Low, nil, ctx.fid)
          end
          flag_reverse_tabnabbing(ctx, acc, text) if BLANK_GATE.matches?(text)
        end

        # The three cleartext-subresource findings on an HTTPS page. Reached only once HTTP_GATE
        # has passed, so a page with no cleartext URL at all pays one literal PCRE pass (56.9µs
        # on a 200 KiB page) instead of five structural ones.
        private def check_mixed_content(ctx : Context, acc : Array(Detection), text : String) : Nil
          if MIXED_ACTIVE.matches?(text) || MIXED_ACTIVE_LINK.matches?(text) || MIXED_ACTIVE_OBJECT.matches?(text)
            acc << Detection.new("mixed_content", Category::HEADERS, ctx.host, ctx.url,
              "Active mixed content (http:// sub-resource on an HTTPS page)", Store::Severity::Low, nil, ctx.fid)
          end
          if MIXED_PASSIVE.matches?(text)
            acc << Detection.new("mixed_passive", Category::HEADERS, ctx.host, ctx.url,
              "Passive mixed content (http:// image/media on an HTTPS page)", Store::Severity::Info, nil, ctx.fid)
          end
          if INSECURE_FORM.matches?(text)
            acc << Detection.new("insecure_form_action", Category::HEADERS, ctx.host, ctx.url,
              "Form on an HTTPS page submits over cleartext http://", Store::Severity::Medium, nil, ctx.fid)
          end
        end

        # A target="_blank" anchor with no rel=noopener/noreferrer lets the opened page repoint
        # this tab via window.opener. Report once (grouped by code+host anyway).
        #
        # Info, not Low, and deliberately: every current browser has applied `noopener` implicitly
        # to `target="_blank"` for years (Chrome 88, Firefox 79, Safari 12.1), so the attack this
        # describes does not reproduce on anything a real user is running. What is left is a
        # markup-hygiene note that matters only for legacy embedded webviews — and an external
        # link is on nearly every page, so scoring it as a vulnerability buried the findings that
        # are one. Kept rather than deleted because the note is still true, and Info is the tier
        # this codebase already uses for it (mixed_passive, missing_referrer_policy).
        private def flag_reverse_tabnabbing(ctx : Context, acc : Array(Detection), text : String) : Nil
          text.scan(ANCHOR_BLANK) do |m|
            tag = m[0]
            next if REL_NOOPENER.matches?(tag)
            acc << Detection.new("reverse_tabnabbing", Category::HEADERS, ctx.host, ctx.url,
              "target=\"_blank\" link without rel=noopener", Store::Severity::Info, nil, ctx.fid)
            break
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

        # True when a private-IP candidate is really a software/assembly VERSION: a version word
        # sits immediately before it (within a short window of the text preceding the match), e.g.
        # `File version 10.0.1.2` or `{"version":"10.0.0.0"}`. Keeps a genuine leak (`backend at
        # 10.0.0.5`) flagged while dropping the ubiquitous 4-part-version false positive.
        # The keyword must be the last token before the number (allowing quotes/`:`/`=`/space
        # separators, as in `version: 10.0.1.2` or `{"version":"10.0.0.0"}`) — an incidental
        # earlier mention ("Our firmware serves 10.0.0.5") must NOT suppress a genuine IP leak.
        VERSION_CONTEXT = /(?:version|build|assembly|revision|firmware)["'\s:=]*\z/i

        private def version_context?(pre : String) : Bool
          tail = pre.size > 24 ? pre[(pre.size - 24)..] : pre
          VERSION_CONTEXT.matches?(tail)
        end
      end
    end
  end
end
