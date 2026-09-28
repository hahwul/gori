require "json"

module Gori
  module Graphql
    # The introspection request an operator puts in a Repeater tab to ask a GraphQL endpoint for
    # its schema. Burp's Repeater offers the same two queries; the operator sends one and reads
    # the answer. `Schema.parse` and `Operations.generate` can read that answer into requests, but
    # no surface calls them yet.
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
      # turned into a POST, because a server that reads both would otherwise see two operations
      # (or a persisted-query hash that no longer matches the document). Every other parameter
      # (an API key, a tenant id) stays where the operator put it. Keys match VERBATIM, as
      # `Graphql.from_query` reads them: `%71uery` is not the binding there, so it is not here.
      BINDING_PARAMS = {"query", "operationName", "variables", "extensions"}

      # Headers the new body makes wrong. Each is written again (Content-Type, Content-Length) or
      # dropped (the body is sent as plain, unchunked JSON).
      FRAMING_HEADERS = {"content-type", "content-length", "transfer-encoding", "content-encoding"}

      # The JSON body: the query under the `IntrospectionQuery` name it declares.
      def body(legacy : Bool = false) : String
        {"operationName" => "IntrospectionQuery", "query" => (legacy ? LEGACY_QUERY : QUERY)}.to_json
      end

      # `text` (a Repeater request in its editor's wire form: head, a blank line, body) rewritten
      # into the introspection request for the same endpoint: `POST` to the same path, the
      # operator's other headers (the session under test) kept in order, a JSON body, and
      # Content-Length set to it. Raises `Gori::Error` when there is no request line to rewrite.
      #
      # A kept line keeps its own terminator, so an `X-A: v\r\r\n` the operator wrote goes out
      # as written (P7); a line gori writes takes the request line's. An obs-fold continuation
      # (a line opening with SP/HTAB) belongs to the header above it and goes wherever that
      # header goes, so a folded Content-Type cannot leave its tail on the new Content-Length.
      def rewrite_request(text : String, legacy : Bool = false) : String
        head, blank_eol = split_head(text)
        first = head.first?
        parts = first.try(&.[0].split(' ')) || [] of String
        if first.nil? || parts.size != 3 || parts[1].empty?
          raise Gori::Error.new("the request line is not METHOD TARGET VERSION — fix it and try again")
        end
        eol = first[1].empty? ? "\n" : first[1] # not `presence`: "\r\n" is blank to it
        payload = body(legacy)
        framing = [{"Content-Type: application/json", eol}, {"Content-Length: #{payload.bytesize}", eol}]
        acc = [{"POST #{post_target(parts[1])} #{parts[2]}", eol}]
        acc.concat(rewrite_headers(head, framing, eol))
        String.build do |io|
          acc.each { |(line, line_eol)| io << line << line_eol }
          io << (blank_eol || eol) << payload
        end
      end

      # The header lines after the request line, with every framing header (and its folded
      # continuations) dropped and `framing` put where the first of them stood — or appended
      # when there was none — so a request whose headers are in a deliberate order keeps it.
      private def rewrite_headers(head : Array({String, String}), framing : Array({String, String}),
                                  eol : String) : Array({String, String})
        acc = [] of {String, String}
        placed = false
        dropping = false
        head.each(within: 1..) do |(line, line_eol)|
          kept = {line, line_eol.empty? ? eol : line_eol}
          if line.starts_with?(' ') || line.starts_with?('\t')
            acc << kept unless dropping
            next
          end
          dropping = FRAMING_HEADERS.includes?(line.partition(':')[0].strip.downcase)
          if !dropping
            acc << kept
          elsif !placed
            acc.concat(framing)
            placed = true
          end
        end
        acc.concat(framing) unless placed
        acc
      end

      # The head of `text` as {line, terminator} pairs, and the blank line's own terminator (nil
      # when the text has no body separator). A terminator is `\r\n` or `\n`; a CR before it
      # that is not part of it stays in the line, as the Repeater editor keeps it.
      private def split_head(text : String) : {Array({String, String}), String?}
        lines = [] of {String, String}
        pos = 0
        while pos < text.size
          nl = text.index('\n', pos)
          raw = nl ? text[pos...nl] : text[pos..]
          pos = nl ? nl + 1 : text.size
          line, line_eol = nl && raw.ends_with?('\r') ? {raw.rchop, "\r\n"} : {raw, nl ? "\n" : ""}
          return {lines, line_eol} if line.empty? && nl
          lines << {line, line_eol}
        end
        {lines, nil}
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
        kept = query.split('&').reject { |pair| pair.empty? || BINDING_PARAMS.includes?(pair.partition('=')[0]) }
        kept.empty? ? "#{path}#{fragment}" : "#{path}?#{kept.join('&')}#{fragment}"
      end
    end
  end
end
