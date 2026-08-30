require "./rule"

module Gori
  module Probe
    module Passive
      # Server-side configuration and diagnostic artifacts served to the client (category
      # "infoleak"). These are not "a secret happened to appear in a page" — the sibling
      # `secret_in_body` rule covers that. This is the whole FILE being readable: a deployed
      # `.env`, a `.git/config`, a `phpinfo()` page, an `.htpasswd`, a Spring `/actuator/env`.
      # One of these is usually the shortest path from recon to credentials, and every one of
      # them is a deployment mistake rather than a code bug, so the finding is actionable on
      # its own.
      #
      # PRECISION over recall, deliberately. Every signature is anchored on the exact structural
      # shape the artifact has — `[core]` immediately followed by `repositoryformatversion`, a
      # `<title>phpinfo()</title>`, an Apache MD5 crypt hash — never on a keyword that a page
      # ABOUT the artifact would also carry. The FP that matters here is a tutorial, a docs
      # site, or a config reference showing the same text, and that is what the two-marker /
      # structural anchoring (the `directory_listing` pattern) is for.
      #
      # Every signature is anchored on a literal PCRE can skip a clean body on, and the scan is
      # bounded to the response's opening SCAN_PREFIX bytes — this rule reads the body of every
      # texty 2xx response.
      class ExposedConfig < Rule
        def info : RuleInfo
          RuleInfo.new("exposed_config", "Exposed configuration files",
            "Detects server configuration and diagnostic artifacts served to clients: .env, " \
            ".git/config, phpinfo(), .htpasswd, wp-config credentials, and Spring actuator env.",
            Category::INFOLEAK)
        end

        # {confirming pattern, evidence label, severity}.
        #
        # There is no separate prefilter, and that is a measured decision rather than an
        # omission. Each of these carried a `String#includes?` literal in front of it, on the
        # theory that a body which cannot match should never enter PCRE. Over the 16 KiB prefix
        # this rule actually scans, the guards cost ~35µs each while the patterns they guarded
        # cost ~7.6µs: five naive byte searches (~180µs on EVERY texty 2xx response) to save
        # ~38µs of PCRE. `String#includes?` is a naive O(n·m) walk; PCRE2 memchr-skips on the
        # literal each of these patterns already opens with or requires. Same finding as the
        # guards removed from `debug_mode_exposed`, `sourcemap`, `serialized_object` and
        # `directory_listing` — the rule is: do not hand-roll a prefilter in front of something
        # that already prefilters itself, and settle it by measurement, not by reasoning about
        # allocations.
        SIGNATURES = [
          # A `.git/config`: the `[core]` section header is immediately followed by the
          # repository format version. A prose mention of "[core]" cannot produce that pair.
          {/\[core\][^\[]{0,80}repositoryformatversion\s*=/,
           ".git/config", Store::Severity::High},
          # phpinfo() output. The <title> is emitted by the function itself and is not something
          # a page merely DISCUSSING phpinfo would carry; the PHP Version table row confirms it.
          {/<title>phpinfo\(\)<\/title>/i,
           "phpinfo() output", Store::Severity::Medium},
          # An Apache/nginx password file: `user:$apr1$…` (or bcrypt / SHA-512 crypt). The hash
          # prefix is the anchor — a bare `user:password` line would match nothing here. This is
          # the one signature whose own first-byte set is just `\n`, so it is the least skippable
          # of the five; it still measured 7.5µs over the 16 KiB prefix, against 35µs for the
          # `:$` byte search that used to guard it.
          {/(?:\A|\n)[\w.\-]{1,64}:\$(?:apr1|2[aby]|5|6)\$[^\s:]{8,}/,
           ".htpasswd credentials", Store::Severity::High},
          # wp-config.php served as source instead of executed: the DB password define().
          {/define\s*\(\s*['"]DB_PASSWORD['"]\s*,/,
           "wp-config.php credentials", Store::Severity::High},
          # Spring Boot Actuator /env (or /configprops): the response envelope is distinctive.
          {/"propertySources"\s*:\s*\[/,
           "Spring actuator env", Store::Severity::Medium},
        ]

        # A `.env` file is the one artifact with no structural envelope — it is just
        # `KEY=value` lines, which is also what a great many ordinary text responses look like.
        # So it is keyed on a SECRET-BEARING key at the start of a line, and gated separately
        # on the response NOT being a document (below): an HTML page listing these key names is
        # a deployment guide, whereas a text/plain body that opens a line with `DB_PASSWORD=`
        # and a non-empty value is the file itself.
        # No literal prefilter here on purpose: every candidate literal (`=`, `_`) is in
        # essentially every response body, so one would cost a full byte scan and reject
        # nothing. The content-type gate below is the real filter, and after it PCRE's own
        # first-byte set (the key initials following a newline) does the skipping.
        DOTENV = /(?:\A|\n)(?:DB_PASSWORD|DB_USERNAME|DATABASE_URL|APP_KEY|APP_SECRET|SECRET_KEY|SECRET_KEY_BASE|AWS_SECRET_ACCESS_KEY|STRIPE_SECRET_KEY|JWT_SECRET|MAIL_PASSWORD|REDIS_PASSWORD)\s*=\s*\S/

        # Every artifact here DECLARES ITSELF in its opening bytes: `[core]` opens a git config,
        # `<title>phpinfo()</title>` is in the document head, an `.htpasswd` record is line one,
        # the actuator envelope keys are the outermost JSON object, and a `.env`'s keys sit at
        # the top. So the scan is bounded to this prefix instead of the full 64 KiB `body_text`.
        #
        # This is a real cost, not a hypothetical one: the rule runs on EVERY texty 2xx response,
        # so scanning the full 64 KiB `body_text` cost ~0.4ms per flow on the shared passive
        # fiber (measured, bench/probe_passive_bench) — for bytes that structurally cannot hold
        # the signal. A body already under the bound is used as-is and copies nothing.
        SCAN_PREFIX = 16 * 1024

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless resp = ctx.response
          # Only a SERVED artifact counts. A 403/404 error page can echo the requested path
          # (".../.git/config") and a redirect body carries nothing — same gate as
          # directory_listing, and for the same reason.
          return unless (200..299).includes?(resp.status)
          full = ctx.body_text
          return if full.nil? || full.empty?
          text = head_of(full)

          SIGNATURES.each do |(pattern, label, severity)|
            acc << det(ctx, label, severity) if pattern.matches?(text)
          end
          check_dotenv(ctx, acc, text)
        end

        # `.env` is checked only for a NON-document response. An HTML page that lists
        # `DB_PASSWORD=…` is documentation (a README render, a deployment guide, a paste site);
        # the file served raw is text/plain, octet-stream, or type-less. Excluding HTML here is
        # what makes the loose `KEY=value` shape safe to match at all.
        private def check_dotenv(ctx : Context, acc : Array(Detection), text : String) : Nil
          return if ctx.html? || ctx.js?
          return unless DOTENV.matches?(text)
          acc << det(ctx, ".env file", Store::Severity::High)
        end

        # The first SCAN_PREFIX bytes, scrubbed. The cut can land mid-codepoint, and PCRE RAISES
        # on invalid UTF-8 — which here would take out the whole flow's detections, not just
        # this rule's — so the slice is scrubbed before any pattern sees it.
        private def head_of(text : String) : String
          return text if text.bytesize <= SCAN_PREFIX
          String.new(text.to_slice[0, SCAN_PREFIX]).scrub
        end

        # One code for the whole family: these are the same finding ("a server-side artifact is
        # readable") and an operator acts on them together, so they group and are dismissed
        # together. The artifact NAME rides in `evidence`, which accumulates per host (see
        # Store::ACCUMULATING_EVIDENCE_CODES), so a host serving both a .env and a phpinfo page
        # names both rather than pinning to whichever was captured first. The title is FIXED so
        # the severity-driven title adoption in upsert_probe_issue has nothing to swap.
        private def det(ctx : Context, label : String, severity : Store::Severity) : Detection
          Detection.new("exposed_config", Category::INFOLEAK, ctx.host, ctx.url,
            "Server configuration or diagnostic file exposed", severity, label, ctx.fid)
        end
      end
    end
  end
end
