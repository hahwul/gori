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
        # The bracket form requires a QUOTED string key (`['login']`) — a numeric/variable
        # index (`[0]`, `[i]`) cannot be shadowed by an id/name element, so matching bare `[`
        # fired on ubiquitous benign iteration like `document.images[0]`. Runs over stripped
        # client_code, which blanks a string's contents but KEEPS its opening quote, so the
        # quoted form still matches post-strip (`document.forms['x']` → `document.forms['']`).
        NAMED_COLLECTION = /\bdocument\.(?:forms|images|embeds|links|anchors|scripts|applets|all)\s*(?:\[\s*["'`]|\.namedItem\b)/
        # `window.foo = window.foo || "…"` — reads a global back before defining it; a clobbering
        # element with that id/name can have already set it. Backreference pins both sides.
        #
        # The trailing `["'`]` is what makes this a finding rather than a description of every
        # bundle on the web. What a clobbering element puts in a global is an ELEMENT (or an
        # HTMLCollection), so the idiom is only a gadget when the code goes on to use the value
        # AS A STRING — a CDN base, an API URL, a template path — because that is where an
        # `<a id=cdnBase href="//evil">` stringifies into the slot. The namespace-initialising
        # forms (`|| {}`, `|| []`, `|| require(…)`, `|| someIdentifier`) are the UMD / polyfill /
        # analytics preamble: `window.dataLayer = window.dataLayer || []` is Google Tag Manager's
        # documented snippet, and `window.X = window.X || {}` opens essentially every UMD bundle.
        # Matching those made this rule fire on every script on the internet — against the
        # "two high-precision code patterns" this file's header promises — while clobbering one
        # of them with an element breaks the page loudly instead of exploiting it. Runs over
        # stripped client_code, which blanks a string's CONTENTS but keeps its opening quote,
        # so the string-literal form still matches post-strip.
        CLOBBER_GUARD = /\bwindow\.([A-Za-z_$][\w$]*)\s*=\s*window\.\1\s*\|\|\s*["'`]/

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
