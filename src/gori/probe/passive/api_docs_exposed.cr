require "./rule"

module Gori
  module Probe
    module Passive
      # API documentation / schema UIs and specs reachable in production (category "infoleak").
      # A live Swagger UI, an OpenAPI/Swagger JSON spec, or an interactive GraphQL IDE hands a
      # tester the whole endpoint inventory — every route, parameter, and auth scheme — that they
      # would otherwise have to enumerate. The interactive IDEs (GraphiQL, GraphQL Playground) are
      # worse: they let anyone run queries against the live API straight from the browser.
      #
      # Two body shapes are read, each matched on a STRUCTURAL marker (a bootstrap global, an asset
      # filename, a DOM id / custom element), never a bare product name, so a page that merely
      # mentions these tools in prose is not flagged:
      #   * HTML documents (ctx.html?) carrying a UI/IDE bootstrap marker;
      #   * JSON documents (content-type gated) whose top carries the version key next to "paths".
      class ApiDocsExposed < Rule
        def info : RuleInfo
          RuleInfo.new("api_docs_exposed", "API documentation exposed",
            "Detects Swagger UI, OpenAPI/Swagger specs, and interactive GraphQL IDEs (GraphiQL, " \
            "Playground, ReDoc) reachable in production.",
            Category::INFOLEAK)
        end

        # {confirming pattern, evidence label, severity}. Each pattern is a STRUCTURAL marker — a JS
        # global/init call, an asset filename, or a DOM id / custom element — not the bare product
        # name, so prose that names the tool ("we disabled GraphiQL in prod") does not match.
        # Interactive IDEs are Medium (they run live queries from the browser); a static UI is Low.
        HTML_SIGNATURES = [
          {/GraphQLPlayground|react-graphql-playground|graphql-playground-react/i,
           "GraphQL Playground (interactive)", Store::Severity::Medium},
          {/graphiql(?:\.min)?\.(?:js|css)|renderGraphiQL|GraphiQL\.createFetcher/i,
           "GraphiQL (interactive)", Store::Severity::Medium},
          {/SwaggerUIBundle|swagger-ui(?:-bundle)?(?:\.min)?\.(?:js|css)|id\s*=\s*["']swagger-ui/i,
           "Swagger UI", Store::Severity::Low},
          {/<redoc[\s>]|redoc(?:\.standalone)?(?:\.min)?\.js|Redoc\.init/i,
           "ReDoc API reference", Store::Severity::Low},
        ] of {Regex, String, Store::Severity}

        # OpenAPI 3 (`"openapi": "3…"`) or Swagger 2 (`"swagger": "2…"`) next to a top-level
        # "paths" object. Requiring "paths" keeps a JSON response that merely carries an "openapi"
        # field out. (A spec larger than Context::BODY_CAP whose "paths" sits past the 64 KiB cap
        # is a known miss — requiring "paths" is the deliberate low-FP trade.)
        SPEC_VERSION = /"openapi"\s*:\s*"3|"swagger"\s*:\s*"2/
        SPEC_PATHS   = /"paths"\s*:/

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless ctx.response
          json = ctx.ct_low.try(&.includes?("json")) || false
          # Only an HTML document (a UI page) or a JSON body (a spec) can carry these markers.
          # Gating here keeps body_text off images/binaries and keeps the spec regex off every
          # HTML page and JS bundle (where an embedded example spec would otherwise false-fire).
          return unless ctx.html? || json
          text = ctx.body_text
          return if text.nil? || text.empty?

          if ctx.html?
            HTML_SIGNATURES.each do |(pattern, label, severity)|
              next unless pattern.matches?(text)
              return emit(acc, ctx, label, severity)
            end
          elsif json && SPEC_VERSION.matches?(text) && SPEC_PATHS.matches?(text)
            emit(acc, ctx, "OpenAPI/Swagger specification", Store::Severity::Low)
          end
        end

        private def emit(acc : Array(Detection), ctx : Context, label : String, sev : Store::Severity) : Nil
          acc << Detection.new("api_docs_exposed", Category::INFOLEAK, ctx.host, ctx.url,
            "API documentation or schema exposed", sev, label, ctx.fid)
        end
      end
    end
  end
end
