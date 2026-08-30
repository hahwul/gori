require "./rule"

module Gori
  module Probe
    module Passive
      # A web framework's DEBUG mode / interactive debugger / profiler reachable in production
      # (category "infoleak"). This is deliberately DISTINCT from the sibling `error_stack_leak`,
      # which flags any stack trace in a body: here the signal is a framework's own debug UI —
      # Symfony's profiler, Werkzeug's / Rails' interactive console, Laravel's Whoops/Ignition,
      # the Django technical-error page, ASP.NET detailed errors. Two things follow that a generic
      # trace does not carry: the remediation is specific and singular ("turn debug off"), and
      # some of these pages are live REMOTE-CODE-EXECUTION consoles, not merely disclosure — so
      # they earn High while a profiler/error page is Medium.
      #
      # PRECISION over recall: every marker is a string the debug UI emits about ITSELF (a
      # console title, a profiler header, a framework version banner that only the debug page
      # renders), never a word a page ABOUT the framework would carry. Body markers are gated to
      # HTML responses; the header marker is content-type-agnostic (it rides every response while
      # the profiler is on).
      class DebugModeExposed < Rule
        def info : RuleInfo
          RuleInfo.new("debug_mode_exposed", "Debug mode exposed",
            "Detects framework debug mode, interactive debuggers, and profilers reachable in " \
            "production (Symfony, Werkzeug/Flask, Django, Laravel, Rails, ASP.NET).",
            Category::INFOLEAK)
        end

        # {optional cheap prefilter, confirming pattern, evidence label, severity}.
        #
        # The prefilters here used to be `String` needles tested with `String#includes?`, and on
        # this rule that was a straight PESSIMISATION: `String#includes?` is a naive byte search,
        # while PCRE2 skips a non-matching subject with its own start optimization. Over a 64 KiB
        # HTML body one `includes?` cost ~85µs and the pattern it guarded cost ~19µs, so every
        # HTML flow paid ~600µs to save nothing — the rule was the second most expensive on a
        # large document. Same finding, same file-level shape, as the `includes?`-before-regex
        # guards removed elsewhere in this tree: never hand-roll a prefilter in front of
        # something that already prefilters itself, and settle it by measurement.
        #
        # So the guard is nil for every pattern PCRE already anchors on a literal, and a cheap
        # LITERAL REGEX (~19µs, not an `includes?`) only where the confirming pattern genuinely
        # cannot anchor itself — today just the Rails web-console alternation, which opens on
        # `<[^>]+` and costs ~178µs unguarded.
        SIGNATURES = [
          # Werkzeug/Flask interactive debugger — a live Python console (RCE if the PIN is off or
          # brute-forced). The title string is emitted only by the debugger page.
          {nil,
           /Werkzeug Debugger/,
           "Werkzeug interactive debugger", Store::Severity::High},
          # Rails web-console — an in-browser IRB on the error page (RCE). The mount marker and
          # its session id are rendered only when the console gem is active. `console-` is a
          # necessary substring of BOTH alternatives (`id="console-`, `data-console-session`).
          #
          # Case-INSENSITIVE, and that is load-bearing: the pattern it guards is /i, so a
          # case-sensitive gate would drop `DATA-CONSOLE-SESSION` / `<div ID="CONSOLE-abc">`
          # — uppercased markup out of a template, a minifier or a proxy — and silently lose a
          # HIGH (RCE) finding. That is exactly the bug `reverse_tabnabbing` shipped once: an /i
          # regex paired with a case-SENSITIVE membership test. `/i` on a literal costs the same
          # as a case-sensitive one (see the measurements in body_leaks), so there is nothing to
          # trade here.
          {/console-/i,
           /<[^>]+\bid\s*=\s*["']console-|data-console-session/i,
           "Rails web-console", Store::Severity::High},
          # Django DEBUG=True technical error / 404 page. `Django Version:` is rendered by that
          # page (and the technical-404 page) — never by an ordinary response.
          {nil,
           /Django Version:/,
           "Django debug page (DEBUG=True)", Store::Severity::Medium},
          # Laravel Ignition (the modern debug page). Its client bundle / config marker.
          {nil,
           /laravel-ignition|"ignitionConfig"|flare-client/i,
           "Laravel Ignition debug page", Store::Severity::Medium},
          # Whoops (older Laravel / generic PHP). The namespaced handler class is printed in the
          # page frames — a prose "whoops" cannot produce `Whoops\Something`.
          {nil,
           /Whoops\\[A-Z]\w+/,
           "PHP Whoops error page", Store::Severity::Medium},
          # Rails development exception page (`config.consider_all_requests_local = true`). The
          # source-extract heading is dev-only; the production page says "something went wrong".
          {nil,
           /Extracted source \(around line/,
           "Rails development error page", Store::Severity::Medium},
        ] of {Regex?, Regex, String, Store::Severity}

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless ctx.response

          check_symfony_header(ctx, acc)

          # Body markers only make sense in a rendered document; an API/JSON body or a script
          # bundle never carries a debug UI, and gating to HTML keeps the scan off large bundles.
          return unless ctx.html?
          text = ctx.body_text
          return if text.nil? || text.empty?

          SIGNATURES.each do |(prefilter, pattern, label, severity)|
            next if prefilter && !prefilter.matches?(text)
            next unless pattern.matches?(text)
            acc << det(ctx, label, severity)
          end

          check_aspnet(ctx, acc, text)
        end

        # Symfony's web profiler stamps X-Debug-Token(-Link) on EVERY response while it is on, so
        # it is a header check independent of status/content-type. The `-Link` variant even hands
        # over the absolute profiler URL. Presence means the profiler toolbar is reachable in this
        # environment — an internal-state disclosure surface (routes, queries, sessions, config).
        private def check_symfony_header(ctx : Context, acc : Array(Detection)) : Nil
          return unless resp = ctx.response
          return unless resp.headers.get?("X-Debug-Token") || resp.headers.get?("X-Debug-Token-Link")
          acc << det(ctx, "Symfony profiler (X-Debug-Token header)", Store::Severity::Medium)
        end

        # ASP.NET detailed error page. The "Server Error in '/' Application" banner ALSO appears
        # on the SAFE remote page (customErrors on), which is the opposite of a finding — that
        # page says the details are hidden. So the detailed page is confirmed by a real detail
        # section (`Stack Trace:`) AND the ABSENCE of the "settings … prevent … viewed remotely"
        # sentence the safe page carries.
        # The banner regex is run directly — its `Server Error in '` literal prefix is what PCRE
        # anchors on, so the `includes?("Server Error in")` that used to guard it only added a
        # naive scan (~85µs) in front of a ~22µs one. The two `includes?` below it stay: they are
        # reached only once the banner has ALREADY matched, i.e. on an actual ASP.NET error page,
        # so they cost nothing on the ordinary responses this rule spends its time on.
        private def check_aspnet(ctx : Context, acc : Array(Detection), text : String) : Nil
          return unless /Server Error in '[^']*' Application/.matches?(text)
          return unless text.includes?("Stack Trace:")
          return if text.includes?("prevent the details of the application error from being viewed")
          acc << det(ctx, "ASP.NET detailed error page", Store::Severity::Medium)
        end

        # One code for the family (same finding class — "a debug surface is reachable" — acted on
        # together). The framework NAME rides in `evidence`; the title is FIXED so upsert's
        # severity-driven title adoption has nothing to swap when a High and a Medium share a host.
        private def det(ctx : Context, label : String, severity : Store::Severity) : Detection
          Detection.new("debug_mode_exposed", Category::INFOLEAK, ctx.host, ctx.url,
            "Framework debug mode or debugger exposed", severity, label, ctx.fid)
        end
      end
    end
  end
end
