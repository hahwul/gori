require "./rule"

module Gori
  module Probe
    module Passive
      # A wildcard Flash/Silverlight cross-domain policy (category "cors"). `crossdomain.xml`
      # (Flash) and `clientaccesspolicy.xml` (Silverlight) grant OTHER origins read access to this
      # host's authenticated responses. A `domain="*"` / `uri="*"` grant means any site's plugin
      # content can read this origin's data with the user's cookies — the pre-CORS equivalent of
      # `Access-Control-Allow-Origin: *` with credentials.
      #
      # Judged on the RESPONSE BODY, not the URL: the policy is a risk wherever it is served, and a
      # body gate (the policy ROOT element) means a page that merely links to crossdomain.xml is
      # never flagged. Worth reporting though these plugins are near-dead — a live wildcard policy
      # is a standing misconfiguration and a signpost for a forgotten legacy surface.
      class OpenCrossDomainPolicy < Rule
        def info : RuleInfo
          RuleInfo.new("open_cross_domain_policy", "Permissive cross-domain policy",
            "Flags a Flash/Silverlight cross-domain policy that grants access to all origins " \
            "(domain=\"*\").",
            Category::CORS)
        end

        # Prefilter: the policy root element. An ordinary XML/HTML body never carries it, so the
        # wildcard scan is skipped for essentially all traffic.
        ROOT = /<(?:cross-domain-policy|access-policy)\b/i

        # A wildcard grant in either dialect: Flash `<allow-access-from domain="*">` /
        # `<allow-http-request-headers-from domain="*">`, or Silverlight `<domain uri="*">`. The
        # value must be exactly `*` (closing quote right after), so a `domain="*.example.com"`
        # subdomain grant is not read as fully open.
        WILDCARD = /<(?:allow-access-from|allow-http-request-headers-from)\b[^>]*\bdomain\s*=\s*["']\*["']|<domain\b[^>]*\buri\s*=\s*["']\*["']/i

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless ctx.response
          text = ctx.body_text
          return if text.nil? || !ROOT.matches?(text)
          return unless WILDCARD.matches?(text)
          acc << Detection.new("open_cross_domain_policy", Category::CORS, ctx.host, ctx.url,
            "Cross-domain policy allows all origins", Store::Severity::Medium,
            "wildcard domain in cross-domain policy", ctx.fid)
        end
      end
    end
  end
end
