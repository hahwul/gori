require "./rule"

module Gori
  module Prism
    module Passive
      # GraphQL introspection exposure (category "infoleak"): an endpoint that answers an
      # introspection query hands back its ENTIRE schema — every type, field, argument, and
      # deprecation — a complete map of the API surface that greatly eases attacking it and is
      # usually meant to be disabled in production. Detected passively from a captured response
      # that already carries an introspection result; zero-request, response-gated.
      class GraphqlIntrospection < Rule
        # The introspection RESULT envelope is `{"data":{"__schema":{…}}}`, i.e. `__schema` as a
        # quoted JSON KEY opening an object. Anchoring on `"__schema":{`:
        #   * rejects a response that merely ECHOES an introspection QUERY string (there `__schema`
        #     appears unquoted as ` __schema {`), the common false positive, and a stray
        #     "__schema" doc mention;
        #   * sits at the very START of the body, so it survives the 64 KiB body-prefix cap no
        #     matter how large the `types` array is — no longer needs `queryType` to also fit.
        INTROSPECTION_RESULT = /"__schema"\s*:\s*\{/

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless ctx.response
          # An introspection result is JSON (some servers label it application/graphql-response
          # +json); gate on a JSON-ish content type to skip HTML/text bodies. Unknown → allow.
          ct = ctx.content_type.try(&.downcase)
          return unless ct.nil? || ct.includes?("json") || ct.includes?("graphql")
          text = ctx.body_text
          return if text.nil? || text.empty?
          return unless INTROSPECTION_RESULT.matches?(text)
          acc << Detection.new("graphql_introspection", Category::INFOLEAK, ctx.host, ctx.url,
            "GraphQL introspection enabled (full schema exposed)", Store::Severity::Medium,
            "introspection response", ctx.fid)
        end
      end
    end
  end
end
