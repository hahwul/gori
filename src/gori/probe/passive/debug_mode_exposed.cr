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

        # {literal prefilter, confirming pattern, evidence label, severity}. The prefilter is a
        # NECESSARY substring of the pattern, matched case-sensitively where the marker's casing
        # is fixed, so a body that cannot match never enters PCRE.
        SIGNATURES = [
          # Werkzeug/Flask interactive debugger — a live Python console (RCE if the PIN is off or
          # brute-forced). The title string is emitted only by the debugger page.
          {"Werkzeug Debugger",
           /Werkzeug Debugger/,
           "Werkzeug interactive debugger", Store::Severity::High},
          # Rails web-console — an in-browser IRB on the error page (RCE). The mount marker and
          # its session id are rendered only when the console gem is active.
          {"console-",
           /<[^>]+\bid\s*=\s*["']console-|data-console-session/i,
           "Rails web-console", Store::Severity::High},
          # Django DEBUG=True technical error / 404 page. `Django Version:` is rendered by that
          # page (and the technical-404 page) — never by an ordinary response.
          {"Django Version:",
           /Django Version:/,
           "Django debug page (DEBUG=True)", Store::Severity::Medium},
          # Laravel Ignition (the modern debug page). Its client bundle / config marker.
          {"ignition",
           /laravel-ignition|"ignitionConfig"|flare-client/i,
           "Laravel Ignition debug page", Store::Severity::Medium},
          # Whoops (older Laravel / generic PHP). The namespaced handler class is printed in the
          # page frames — a prose "whoops" cannot produce `Whoops\Something`.
          {"Whoops\\",
           /Whoops\\[A-Z]\w+/,
           "PHP Whoops error page", Store::Severity::Medium},
          # Rails development exception page (`config.consider_all_requests_local = true`). The
          # source-extract heading is dev-only; the production page says "something went wrong".
          {"Extracted source",
           /Extracted source \(around line/,
           "Rails development error page", Store::Severity::Medium},
        ]

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless ctx.response

          check_symfony_header(ctx, acc)

          # Body markers only make sense in a rendered document; an API/JSON body or a script
          # bundle never carries a debug UI, and gating to HTML keeps the scan off large bundles.
          return unless ctx.html?
          text = ctx.body_text
          return if text.nil? || text.empty?

          SIGNATURES.each do |(needle, pattern, label, severity)|
            next unless text.includes?(needle)
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
        private def check_aspnet(ctx : Context, acc : Array(Detection), text : String) : Nil
          return unless text.includes?("Server Error in")
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
