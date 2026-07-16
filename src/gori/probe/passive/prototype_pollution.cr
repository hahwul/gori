require "./rule"

module Gori
  module Probe
    module Passive
      # Prototype-pollution suspicion (category "client"). Two independent signals:
      #   * client script writing to a prototype key (`obj.__proto__ =`, `x["__proto__"] =`,
      #     `constructor.prototype[…]`, `Object.prototype[…]`) or calling a merge/assign API
      #     that is classically pollution-prone ($.extend(true,…), lodash merge/set); and
      #   * a request whose query/body carries a `__proto__` / `constructor[prototype]` key — a
      #     real pollution surface, or an in-flight probe against a nested-param parser.
      # Scans the RAW fragments (Context#client_scripts) because the string-key form keeps the
      # "__proto__" inside a string literal. Kept Low: the JS shapes appear in benign library
      # code too, so these are leads, not confirmations.
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

        def check(ctx : Context, acc : Array(Detection)) : Nil
          check_request(ctx, acc)
          seen = Set(String).new
          ctx.client_scripts.each do |code|
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
          unless hit
            body = ctx.request_body_text
            hit = !body.nil? && REQ_BODY_PROTO.matches?(body)
          end
          return unless hit
          acc << Detection.new("prototype_pollution_param", Category::CLIENT, ctx.host, ctx.url,
            "Prototype-pollution parameter in request", Store::Severity::Low,
            "__proto__/constructor.prototype in request", ctx.fid)
        end
      end
    end
  end
end
