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
        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless ctx.response
          # An introspection result is JSON (some servers label it application/graphql-response
          # +json); gate on a JSON-ish content type to skip HTML/text bodies. Unknown → allow.
          ct = ctx.content_type.try(&.downcase)
          return unless ct.nil? || ct.includes?("json") || ct.includes?("graphql")
          text = ctx.body_text
          return if text.nil? || text.empty?
          # The reserved introspection fields `__schema` AND `queryType` together are conclusive.
          # Requiring both keeps a stray "__schema" mention (docs, a schema-registry blob) out —
          # the introspection envelope is `{"data":{"__schema":{"queryType":…,"types":[…]}}}`, so
          # both markers sit at the very start and survive the body-prefix cap.
          return unless text.includes?("__schema") && text.includes?("queryType")
          acc << Detection.new("graphql_introspection", Category::INFOLEAK, ctx.host, ctx.url,
            "GraphQL introspection enabled (full schema exposed)", Store::Severity::Medium,
            "introspection response", ctx.fid)
        end
      end
    end
  end
end
