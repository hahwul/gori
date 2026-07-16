require "./rule"

module Gori
  module Probe
    module Passive
      # DOM clobbering suspicion (category "client"). Passive detection of clobbering is
      # inherently heuristic — you cannot see, without executing the page, whether an
      # attacker-influenced id/name element exists — so this stays Info and keys on two
      # high-precision code patterns that indicate reliance on a clobberable global:
      #   * named access into a live HTMLCollection (document.forms[…], document.all[…], …),
      #     which an injected `<… name=x>` / `<… id=x>` can shadow; and
      #   * the `window.X = window.X || …` fallback idiom, which trusts a global that a
      #     clobbering element could pre-populate.
      # Scans the STRIPPED code (Context#client_code) so a mention inside a string/comment
      # doesn't false-match.
      class DomClobbering < Rule
        def info : RuleInfo
          RuleInfo.new("dom_clobbering", "DOM clobbering (suspected)",
            "Flags client code that trusts a clobberable global: named HTMLCollection access (document.forms[…], document.all[…]) or the window.X = window.X || … fallback idiom.",
            Category::CLIENT)
        end

        # Named member access into a live collection that HTML id/name attributes populate.
        NAMED_COLLECTION = /\bdocument\.(?:forms|images|embeds|links|anchors|scripts|applets|all)\s*(?:\[|\.namedItem\b)/
        # `window.foo = window.foo || …` — reads a global back before defining it; a clobbering
        # element with that id/name can have already set it. Backreference pins both sides.
        CLOBBER_GUARD = /\bwindow\.([A-Za-z_$][\w$]*)\s*=\s*window\.\1\s*\|\|/

        def check(ctx : Context, acc : Array(Detection)) : Nil
          scripts = ctx.client_code
          return if scripts.empty?
          named = false
          guard = false
          scripts.each do |code|
            named ||= NAMED_COLLECTION.matches?(code)
            guard ||= CLOBBER_GUARD.matches?(code)
          end
          if named
            acc << clob(ctx, "named DOM collection access")
          end
          if guard
            acc << clob(ctx, "window global fallback (clobberable)")
          end
        end

        private def clob(ctx : Context, evidence : String) : Detection
          Detection.new("dom_clobbering", Category::CLIENT, ctx.host, ctx.url,
            "Possible DOM clobbering surface", Store::Severity::Info, evidence, ctx.fid)
        end
      end
    end
  end
end
