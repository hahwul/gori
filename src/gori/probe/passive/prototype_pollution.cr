require "./rule"
require "../../ascii_bytes"
require "../../proxy/codec/content_decode"

module Gori
  module Probe
    module Passive
      # Prototype-pollution suspicion (category "client"). Two independent signals:
      #   * client script writing to a prototype key (`obj.__proto__ =`, `x["__proto__"] =`,
      #     `constructor.prototype[…]`, `Object.prototype[…]`) or calling a merge/assign API
      #     that is classically pollution-prone ($.extend(true,…), lodash merge/set); and
      #   * a request whose query/body carries a `__proto__` / `constructor[prototype]` key — a
      #     real pollution surface, or an in-flight probe against a nested-param parser.
      # Scans the comment-stripped fragments (Context#client_scripts_nocomment): string literals
      # stay visible so the "__proto__" string-key form is kept, but a commented-out example
      # no longer false-matches. Kept Low: the JS shapes appear in benign library code too, so
      # these are leads, not confirmations.
      class PrototypePollution < Rule
        def info : RuleInfo
          RuleInfo.new("prototype_pollution", "Prototype pollution (suspected)",
            "Flags client code writing to __proto__/constructor.prototype or using pollution-prone deep-merge APIs, and requests carrying __proto__/constructor[prototype] parameters.",
            Category::CLIENT)
        end

        # Assignment into a prototype key, dot or (possibly quoted) bracket form, plus the
        # deep-merge/assign APIs most commonly behind real CVEs.
        SINK_PATTERNS = [
          {/\.__proto__\s*=(?!=)/, "__proto__ assignment"},
          {/\[\s*["'`]__proto__["'`]\s*\]\s*=(?!=)/, "__proto__ key assignment"},
          {/\bconstructor\s*\.\s*prototype\s*\[/, "constructor.prototype[] write"},
          {/\bObject\s*\.\s*prototype\s*\[/, "Object.prototype[] write"},
          {/\$\s*\.\s*extend\s*\(\s*true\b/, "$.extend(true) deep merge"},
          {/\b_\s*\.\s*(?:merge|mergeWith|defaultsDeep|set|setWith)\s*\(/, "lodash deep merge/set"},
        ] of {Regex, String}

        # A prototype key inside a request body region (urlencoded / JSON / bracketed).
        REQ_BODY_PROTO = /(?:["'\[]\s*__proto__|__proto__\s*[\]"':=]|constructor(?:\[|%5[Bb]).{0,12}prototype)/i

        # Every alternative of REQ_BODY_PROTO needs one of these two literals, so their absence
        # from the body is proof the pattern cannot match. Lowercase because the pattern is /i and
        # `AsciiBytes.contains_ci?` wants an already-lowercase needle. Held as constants so the
        # slices are built once for the process, not per flow.
        private PROTO_NEEDLE       = "__proto__".to_slice
        private CONSTRUCTOR_NEEDLE = "constructor".to_slice

        def check(ctx : Context, acc : Array(Detection)) : Nil
          check_request(ctx, acc)
          seen = Set(String).new
          ctx.client_scripts_nocomment.each do |code| # keep string keys, drop comments (no commented-out-code FPs)
            SINK_PATTERNS.each do |(re, label)|
              next unless re.matches?(code)
              next unless seen.add?(label)
              acc << Detection.new("prototype_pollution", Category::CLIENT, ctx.host, ctx.url,
                "Prototype-pollution sink in client script", Store::Severity::Low, label, ctx.fid)
            end
          end
        end

        private def check_request(ctx : Context, acc : Array(Detection)) : Nil
          # target.includes? is byte-safe on a possibly non-UTF-8 target (no PCRE); the body
          # text is already scrubbed, so the regex there is safe.
          target = ctx.req.target
          hit = target.includes?("__proto__") ||
                (target.includes?("constructor") && target.includes?("prototype"))
          hit ||= body_has_proto_key?(ctx)
          return unless hit
          acc << Detection.new("prototype_pollution_param", Category::CLIENT, ctx.host, ctx.url,
            "Prototype-pollution parameter in request", Store::Severity::Low,
            "__proto__/constructor.prototype in request", ctx.fid)
        end

        # Does the request body carry a prototype key?
        #
        # `Context#request_body_text` is what actually answers this, but materialising it means
        # content-decoding, capping, copying and UTF-8-scrubbing up to 64 KiB — and this rule is
        # not response-gated, so an ordinary JSON API POST paid that full copy on EVERY captured
        # flow just to be told "no". (No other built-in rule asks for the request body; only a
        # user's custom rule does, and it has its own memoised getter.)
        #
        # So the RAW bytes are scanned first for a necessary literal. That is exact whenever the
        # body is not compressed: `decode` returns the same bytes and `scrub` only ever maps an
        # invalid sequence to U+FFFD, which can neither create nor destroy an ASCII `__proto__`.
        # A body that IS compressed skips the prefilter and takes the old path — the plaintext
        # literal is not in the compressed bytes, so gating on it there would be a false negative.
        # `content_encoded?` is the codebase's fail-closed predicate for that question, so an
        # obs-folded or otherwise unreadable head lands on the safe side by construction.
        #
        # The prefilter scans the WHOLE body while the regex sees only the first 64 KiB, so it is
        # a strict superset of what can match — it can wave through a body the regex then rejects
        # (exactly as before), never the reverse.
        private def body_has_proto_key?(ctx : Context) : Bool
          body = ctx.detail.request_body
          return false if body.nil? || body.empty?
          unless Proxy::Codec::ContentDecode.content_encoded?(ctx.detail.request_head)
            return false unless AsciiBytes.contains_ci?(body, PROTO_NEEDLE) ||
                                AsciiBytes.contains_ci?(body, CONSTRUCTOR_NEEDLE)
          end
          text = ctx.request_body_text
          !text.nil? && REQ_BODY_PROTO.matches?(text)
        end
      end
    end
  end
end
