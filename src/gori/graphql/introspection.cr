require "json"
require "uri"

module Gori
  module Graphql
    # The introspection request an operator puts in a Repeater tab to ask a GraphQL endpoint for
    # its schema. Burp's Repeater offers the same two queries; the operator sends one and reads
    # the answer, which `Schema.parse` turns into the operations `Operations.generate` writes.
    #
    # This module builds the request and never sends it: the operator sends it from the tab, where
    # the scope gate and the session they are already testing with apply as for any other send.
    module Introspection
      extend self

      # graphql-js `getIntrospectionQuery()` with its defaults, which is what GraphiQL and most
      # clients send, so it is also the query a server that allows introspection is most likely
      # to answer. `TypeRef` nests `ofType` seven levels, the depth graphql-js asks for, which
      # covers `[[T!]!]!` and anything short of a pathological wrapper chain.
      QUERY = <<-GRAPHQL
        query IntrospectionQuery {
          __schema {
            queryType { name }
            mutationType { name }
            subscriptionType { name }
            types {
              ...FullType
            }
            directives {
              name
              description
              locations
              args {
                ...InputValue
              }
            }
          }
        }

        #{FRAGMENTS}
        GRAPHQL

      # For a server that rejects the standard query. `subscriptionType` and `directives.locations`
      # arrived in later revisions of the spec, and an older server fails the WHOLE query on the
      # first field it does not know. Neither is needed to list operations, so the fallback drops
      # the subscription root and the directives block rather than guessing an older spelling.
      LEGACY_QUERY = <<-GRAPHQL
        query IntrospectionQuery {
          __schema {
            queryType { name }
            mutationType { name }
            types {
              ...FullType
            }
          }
        }

        #{FRAGMENTS}
        GRAPHQL

      FRAGMENTS = <<-GRAPHQL
        fragment FullType on __Type {
          kind
          name
          description
          fields(includeDeprecated: true) {
            name
            description
            args {
              ...InputValue
            }
            type {
              ...TypeRef
            }
            isDeprecated
            deprecationReason
          }
          inputFields {
            ...InputValue
          }
          interfaces {
            ...TypeRef
          }
          enumValues(includeDeprecated: true) {
            name
            description
            isDeprecated
            deprecationReason
          }
          possibleTypes {
            ...TypeRef
          }
        }

        fragment InputValue on __InputValue {
          name
          description
          type {
            ...TypeRef
          }
          defaultValue
        }

        fragment TypeRef on __Type {
          kind
          name
          ofType {
            kind
            name
            ofType {
              kind
              name
              ofType {
                kind
                name
                ofType {
                  kind
                  name
                  ofType {
                    kind
                    name
                    ofType {
                      kind
                      name
                      ofType {
                        kind
                        name
                      }
                    }
                  }
                }
              }
            }
          }
        }
        GRAPHQL

      # Parameters of a GET GraphQL binding. They are dropped from the target when the request is
      # turned into a POST, because a server that reads both would otherwise see two operations.
      # Every other parameter (an API key, a tenant id) stays where the operator put it.
      BINDING_PARAMS = {"query", "operationName", "variables", "extensions"}

      # Headers the new body makes wrong. Each is written again (Content-Type, Content-Length) or
      # dropped (the body is sent as plain, unchunked JSON).
      FRAMING_HEADERS = {"content-type", "content-length", "transfer-encoding", "content-encoding"}

      # The JSON body: the query under the `IntrospectionQuery` name it declares.
      def body(legacy : Bool = false) : String
        {"operationName" => "IntrospectionQuery", "query" => (legacy ? LEGACY_QUERY : QUERY)}.to_json
      end

      # `text` (a Repeater request: LF line breaks, head, a blank line, body) rewritten into the
      # introspection request for the same endpoint: `POST` to the same path, the operator's other
      # headers (the session under test) kept in order, a JSON body, and Content-Length set to it.
      # Raises `Gori::Error` when there is no request line to rewrite.
      def rewrite_request(text : String, legacy : Bool = false) : String
        sep = text.index("\n\n")
        head = sep ? text[0, sep] : text.rstrip('\n')
        lines = head.split('\n')
        parts = lines.first?.try(&.split(' ')) || [] of String
        if parts.size != 3 || parts[1].empty?
          raise Gori::Error.new("the request line is not METHOD TARGET VERSION — fix it and try again")
        end
        payload = body(legacy)
        acc = ["POST #{post_target(parts[1])} #{parts[2]}"]
        placed = false
        lines[1..].each do |line|
          name = line.partition(':')[0].strip.downcase
          if FRAMING_HEADERS.includes?(name)
            # The new pair goes where the first framing header stood, so a request whose headers
            # are in a deliberate order keeps it.
            unless placed
              acc << "Content-Type: application/json" << "Content-Length: #{payload.bytesize}"
              placed = true
            end
            next
          end
          acc << line
        end
        acc << "Content-Type: application/json" << "Content-Length: #{payload.bytesize}" unless placed
        "#{acc.join('\n')}\n\n#{payload}"
      end

      # The target with the GET binding's parameters removed, in origin or absolute form alike.
      def post_target(target : String) : String
        path, sep, query = target.partition('?')
        return target if sep.empty?
        fragment = ""
        if hash = query.index('#')
          fragment = query[hash..]
          query = query[0, hash]
        end
        kept = query.split('&').reject do |pair|
          key = pair.partition('=')[0]
          pair.empty? || BINDING_PARAMS.includes?((URI.decode_www_form(key) rescue key))
        end
        kept.empty? ? "#{path}#{fragment}" : "#{path}?#{kept.join('&')}#{fragment}"
      end
    end
  end
end
