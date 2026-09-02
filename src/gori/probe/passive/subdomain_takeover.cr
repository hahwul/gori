require "./rule"

module Gori
  module Probe
    module Passive
      # Subdomain-takeover suspicion (category "infoleak"): a host whose error page is the hosting
      # provider's own "nothing is claimed here" page. That is the dangling-CNAME shape — DNS for
      # `assets.example.com` still points at S3 / GitHub Pages / Heroku, but the bucket, site or app
      # behind it is gone, so anyone who can create a resource with that name inherits the hostname,
      # its TLS-terminated origin, and every cookie scoped to the parent domain.
      #
      # Passive by construction: the evidence is the captured error page, which already proves both
      # halves — the name RESOLVED to this provider (we reached it), and the provider says the
      # backing resource does not exist. What it cannot prove is that the DNS record is a CNAME the
      # operator still controls (rather than, say, a wildcard someone else owns), so the finding is
      # "possible" and confirming it is a DNS lookup away.
      #
      # Two screens keep it quiet, and both are necessary:
      #   * the response must be an ERROR (status >= 400). Every one of these pages is served as a
      #     4xx/5xx by its provider, while a docs page, a status-page write-up or a Stack Overflow
      #     answer QUOTING the same sentence is a 200 — that single gate removes the whole "someone
      #     wrote about it" false-positive class.
      #   * the request host must not be the provider's OWN domain. Browsing `foo.s3.amazonaws.com`
      #     or a bare `*.herokuapp.com` directly and getting "no such bucket/app" means the name is
      #     the provider's to hand out, not a customer subdomain dangling at it — there is nothing
      #     to take over, and without this screen every direct hit on a deleted bucket is a finding.
      class SubdomainTakeover < Rule
        def info : RuleInfo
          RuleInfo.new("subdomain_takeover", "Subdomain takeover (suspected)",
            "Flags an error page in which the hosting provider says the backing resource is unclaimed " \
            "(S3/GCS bucket, GitHub Pages, Heroku, Pantheon, Shopify, Fastly, Azure, Zendesk, Vercel, Tumblr) — " \
            "the dangling-DNS shape an attacker can claim.",
            Category::INFOLEAK)
        end

        # {marker, service label, the provider's own domains, severity}.
        #
        # Each marker is a sentence or an error code the provider emits and nobody else does, so the
        # match itself needs no corroborating structure (contrast `directory_listing`, whose "Index
        # of /" is ordinary prose and needs a second marker). Apostrophes are written as a class so
        # the typographic form a provider's HTML actually ships (’) matches alongside the ASCII one.
        #
        # High is reserved for the four whose page means "this name is unregistered on this
        # platform, create it and it is yours" — the takeover is one signup away. The rest are
        # Medium: the resource is unclaimed, but claiming the HOSTNAME on those platforms takes an
        # account-level step (a verified domain, a paid plan) that this response does not evidence.
        SIGNATURES = [
          # S3 and GCS both answer a missing bucket with this XML error code.
          {/<Code>NoSuchBucket<\/Code>/, "unclaimed S3/GCS bucket",
           ["amazonaws.com", "googleapis.com"], Store::Severity::High},
          {/There isn[’']t a GitHub Pages site here\./, "unclaimed GitHub Pages site",
           ["github.io", "github.com"], Store::Severity::High},
          # Heroku's 404 for an app that does not exist is served from its CDN error page.
          {/herokucdn\.com\/error-pages\/no-such-app\.html/, "unclaimed Heroku app",
           ["herokuapp.com", "herokudns.com"], Store::Severity::High},
          {/The gods are wise, but do not know of the site which you seek/, "unclaimed Pantheon site",
           ["pantheonsite.io"], Store::Severity::High},
          {/Sorry, this shop is currently unavailable/, "unclaimed Shopify store",
           ["myshopify.com"], Store::Severity::Medium},
          {/Fastly error: unknown domain/, "domain not configured on Fastly",
           ["fastly.net", "fastlylb.net"], Store::Severity::Medium},
          {/404 Web Site not found|Error 404 - Web app not found/, "unclaimed Azure app service",
           ["azurewebsites.net", "cloudapp.net", "trafficmanager.net", "azureedge.net"], Store::Severity::Medium},
          {/Help Center Closed/, "unclaimed Zendesk help centre",
           ["zendesk.com"], Store::Severity::Medium},
          {/DEPLOYMENT_NOT_FOUND/, "unclaimed Vercel deployment",
           ["vercel.app", "vercel.com", "now.sh"], Store::Severity::Medium},
          {/Whatever you were looking for doesn[’']t currently exist at this address/, "unclaimed Tumblr blog",
           ["tumblr.com"], Store::Severity::Medium},
        ]

        # One alternation pass instead of ten on the miss — and the miss is every ordinary 404,
        # which is the volume this rule actually sees. Each branch is the shortest literal that
        # still belongs to exactly one signature above, so a gate hit is very nearly a real hit and
        # the second stage runs on almost nothing. Same two-stage shape as `sourcemap`/`exposed_config`;
        # the gate is a REGEX rather than a chain of `String#includes?` for the reason spelled out
        # there — PCRE2 memchr-skips a literal where `includes?` walks every offset.
        NEEDLE = /NoSuchBucket|GitHub Pages site here|no-such-app\.html|know of the site which you seek|shop is currently unavailable|Fastly error: unknown domain|Web [Ss]ite not found|Web app not found|Help Center Closed|DEPLOYMENT_NOT_FOUND|currently exist at this address/

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless resp = ctx.response
          return unless resp.status >= 400
          text = ctx.body_text
          return if text.nil? || !NEEDLE.matches?(text)
          host = ctx.host.downcase
          SIGNATURES.each do |(marker, service, own, sev)|
            next unless marker.matches?(text)
            next if provider_host?(host, own)
            acc << Detection.new("subdomain_takeover", Category::INFOLEAK, ctx.host, ctx.url,
              "Possible subdomain takeover (#{service})", sev, service, ctx.fid)
            return # one provider per response; a page cannot be two providers' error pages
          end
        end

        # The request host IS the provider (or a name under it), so there is no customer record
        # dangling at the provider — we simply asked the provider for something it does not host.
        private def provider_host?(host : String, own : Array(String)) : Bool
          own.any? { |d| host == d || host.ends_with?(".#{d}") }
        end
      end
    end
  end
end
