require "./rule"

module Gori
  module Probe
    module Passive
      # Cross-origin messaging weaknesses (category "client") — the "other client-side sink
      # points" family, centred on window.postMessage. Three signals, over the RAW fragments
      # (Context#client_scripts) because two of them key on string literals ("message", "*"):
      #   * a message handler that never consults an origin (no `.origin` anywhere in the
      #     script) — the classic missing sender check that lets any frame drive the handler;
      #   * postMessage(data, "*") — a wildcard target origin, leaking the message to any
      #     document that happens to occupy the target window; and
      #   * document.domain = … — a same-origin relaxation that widens the trust boundary.
      class PostMessage < Rule
        def info : RuleInfo
          RuleInfo.new("post_message", "Cross-origin messaging (postMessage)",
            "Flags message handlers with no origin check, postMessage(...) to a wildcard target origin, and document.domain relaxation.",
            Category::CLIENT)
        end

        # A window message handler (addEventListener('message', …) or an onmessage= assignment).
        LISTENER = /addEventListener\s*\(\s*["'`]message["'`]|\bonmessage\s*=(?!=)/
        # Any origin consultation; its mere presence in the script suppresses the no-origin
        # finding (conservative — we would rather miss than cry wolf).
        ORIGIN_CHECK = /\.origin\b/
        # postMessage(<data>, "*") — the wildcard target origin as the (last) argument.
        WILDCARD_POST = /\.postMessage\s*\([^;\n]*,\s*["'`]\*["'`]\s*\)/
        # document.domain = … (assignment, not the === comparison).
        DOMAIN_SET = /\bdocument\.domain\s*=(?!=)/

        def check(ctx : Context, acc : Array(Detection)) : Nil
          scripts = ctx.client_scripts
          return if scripts.empty?
          emitted = Set(String).new
          scripts.each do |code|
            if LISTENER.matches?(code) && !ORIGIN_CHECK.matches?(code) && emitted.add?("no_origin")
              acc << pm(ctx, "postmessage_no_origin", "postMessage handler without origin check",
                Store::Severity::Medium, "message listener, no .origin check")
            end
            if WILDCARD_POST.matches?(code) && emitted.add?("wildcard")
              acc << pm(ctx, "postmessage_wildcard", "postMessage to a wildcard target origin",
                Store::Severity::Low, %(postMessage(..., "*")))
            end
            if DOMAIN_SET.matches?(code) && emitted.add?("domain")
              acc << pm(ctx, "document_domain_set", "document.domain assignment relaxes same-origin",
                Store::Severity::Low, "document.domain =")
            end
          end
        end

        private def pm(ctx : Context, code : String, title : String, sev : Store::Severity, evidence : String) : Detection
          Detection.new(code, Category::CLIENT, ctx.host, ctx.url, title, sev, evidence, ctx.fid)
        end
      end
    end
  end
end
