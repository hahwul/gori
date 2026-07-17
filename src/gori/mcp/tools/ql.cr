require "json"
require "../../ql"

module Gori
  module MCP
    class Tools
      # Parse + validate a QL query for a list tool. Returns the compiled Filter, or
      # an error Result to return as-is: an empty-match query is always rejected;
      # strict:true additionally rejects any query with dropped/invalid terms
      # (default lenient — matching the historical bare-array behavior). A blank
      # query yields EMPTY (match all).
      private def ql_filter_or_error(h, query : String?) : QL::Filter | Result
        return QL::EMPTY if query.nil? || query.strip.empty?
        filter = QL.parse(query)
        return ql_error(query) if QL.reject_empty?(query, filter)
        if bool(h, "strict") || false
          analysis = QL.analyze(query)
          return ql_strict_error(analysis) unless analysis.clean?
        end
        filter
      end

      private def ql_strict_error(a : QL::TermAnalysis) : Result
        bad = (a.ignored + a.invalid_regex).uniq
        err("strict query rejected — unrecognized/invalid term(s): #{bad.join(", ")} " \
            "(call ql_reference; omit strict to run leniently and drop them)",
          "QUERY_SYNTAX", field: "query",
          details: JSON.parse({"ignored" => a.ignored, "invalid_regex" => a.invalid_regex, "applied" => a.applied}.to_json))
      end

      # Diagnose a QL query WITHOUT running it: applied vs ignored (dropped) vs
      # invalid-regex terms, the compiled SQL, and warnings — so a caller can catch
      # a silently-broadening typo or a never-matching regex before relying on results.
      private def ql_explain(h) : Result
        query = str(h, "query")
        return err("missing required 'query'", "INVALID_ARGUMENT", field: "query") if query.nil? || query.strip.empty?
        a = QL.analyze(query)
        filter = QL.parse(query)
        Result.new(JSON.build do |j|
          j.object do
            j.field "query", query
            j.field("applied_terms") { j.array { a.applied.each { |t| j.string t } } }
            j.field("ignored_terms") { j.array { a.ignored.each { |t| j.string t } } }
            j.field("invalid_regex_terms") { j.array { a.invalid_regex.each { |t| j.string t } } }
            j.field "matches_nothing", QL.reject_empty?(query, filter)
            j.field "sql", filter.sql
            j.field("warnings") do
              j.array do
                j.string "dropped (broadens results): #{a.ignored.join(", ")}" unless a.ignored.empty?
                j.string "invalid regex, matches nothing: #{a.invalid_regex.join(", ")}" unless a.invalid_regex.empty?
              end
            end
          end
        end)
      end

      private def ql_reference : Result
        Result.new(JSON.build { |j| j.object { j.field "reference", QL::REFERENCE } })
      end

      private def ql_error(query : String) : Result
        err(
          "invalid query #{query.inspect}: did not match any field " \
          "(call ql_reference; e.g. host:example.com status:>=500 method:POST)",
          "QUERY_SYNTAX", field: "query")
      end
    end
  end
end
