require "./rule"

module Gori
  module Probe
    module Passive
      # Cross-origin messaging weaknesses (category "client") — the "other client-side sink
      # points" family, centred on window.postMessage. Three signals, over the comment-stripped
      # fragments (Context#client_scripts_nocomment): string literals ("message", "*") stay
      # visible for the string-key form, but commented-out example code no longer false-matches:
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

        # A window message handler whose body we can actually SEE: the listener must be followed
        # by an inline function literal (`function (e) {` or `(e) => {`). A handler passed by NAME
        # (`addEventListener("message", onMsg)`) is deliberately not matched — its body is defined
        # elsewhere, so no window around this call site can tell whether it checks the origin, and
        # guessing would be a false positive.
        LISTENER = /(?:addEventListener\s*\(\s*["'`]message["'`]\s*,|\bonmessage\s*=(?!=))\s*(?:async\s+)?(?:function\b[^(]*\(|\()[^)]*\)\s*(?:=>\s*)?\{/
        # Any origin consultation. Searched in a WINDOW after the handler opens, not across the
        # whole fragment: `.origin` is ubiquitous in a bundled SPA, so a whole-fragment test meant
        # one unrelated occurrence anywhere in a 256 KiB bundle suppressed every finding in it —
        # the rule detected nothing at all on exactly the targets it matters most for. Scoping the
        # test to the handler body restores that, and pairing it with the inline-function gate
        # above keeps the conservative bias: we only judge handlers we can read.
        ORIGIN_CHECK = /\.origin\b/
        # How far past the handler's opening brace to look. Generous — a real message handler with
        # its dispatch table still fits, and over-reaching only makes the rule quieter.
        HANDLER_WINDOW = 2000
        # postMessage(<data>, "*") — the wildcard target origin as the (last) argument.
        WILDCARD_POST = /\.postMessage\s*\([^;\n]*,\s*["'`]\*["'`]\s*\)/
        # document.domain = … (assignment, not the === comparison).
        DOMAIN_SET = /\bdocument\.domain\s*=(?!=)/

        def check(ctx : Context, acc : Array(Detection)) : Nil
          scripts = ctx.client_scripts_nocomment # keep string literals, drop comments (no commented-out-code FPs)
          return if scripts.empty?
          emitted = Set(String).new
          scripts.each do |code|
            if unchecked_handler?(code) && emitted.add?("no_origin")
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

        # True when `code` registers an INLINE message handler whose body does not consult
        # `.origin` within HANDLER_WINDOW characters of its opening brace. Scans every handler in
        # the fragment: a bundle can register several, and one that checks its sender must not
        # vouch for one that does not.
        private def unchecked_handler?(code : String) : Bool
          code.scan(LISTENER) do |m|
            body = code[m.end(0), HANDLER_WINDOW]?
            return true if body.nil? || !ORIGIN_CHECK.matches?(body)
          end
          false
        end

        private def pm(ctx : Context, code : String, title : String, sev : Store::Severity, evidence : String) : Detection
          Detection.new(code, Category::CLIENT, ctx.host, ctx.url, title, sev, evidence, ctx.fid)
        end
      end
    end
  end
end
