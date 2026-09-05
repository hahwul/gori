require "json"
require "../../ql"
require "../../scope"

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
        # The project's scope, so a `scope:in`/`scope:out` term compiles instead of being
        # dropped. Read per call rather than cached: an agent (or a peer process) can add a
        # scope rule between two list_history calls, and a cached lens would answer the first
        # rule set forever. `strict:` reads the same lens, or it would report a term the query
        # in fact applied.
        # Before the lens, which is a store read: a call that is going to be refused for the way
        # it is SPELLED must not go to the database on its way to the refusal (the same rule the
        # FTS drain in `list_history` states for its own write).
        if unknown = ql_unknown_field_error(h, query)
          return unknown
        end
        lens = Scope.ql_lens(store)
        filter = QL.parse(query, scope: lens)
        return ql_error(query) if QL.reject_empty?(query, filter)
        bad = QL.invalid_regex_terms(query)
        return ql_invalid_regex_error(query, bad) unless bad.empty?
        if bool_arg(h, "strict", false)
          analysis = QL.analyze(query, scope: lens)
          return ql_strict_error(analysis) unless analysis.clean?
        end
        filter
      end

      # Refuse a query naming a `field:`/`field~` QL does not implement, instead of running the
      # free-text search `ql.cr`'s `field_cond` else-branch turns it into. `methd:GET` compiles to
      # a literal substring search over method/host/target, so it came back `[]` with no error on
      # it — "this project has no such traffic" and "you spelled `method` wrong" were the same
      # answer, and this transport's caller is a model that has no screen to notice on.
      #
      # `gori run history/sitemap/probe` has refused this since #884 (`--lenient` opts out), and
      # so do the two MCP tools that SAVE a query — `create_view` (SavedViews.unknown_fields) and
      # `create_color_rule` (Colormarker.unknown_fields). MCP's READ tools were the hole, and
      # `run.cr`'s comment exempted them on the grounds that `strict:` already offered this. It
      # did not, and could not: an unknown field free-texts, so it COMPILES, so `QL.analyze` puts
      # it in `applied` and `strict:` (which reports `ignored` + `invalid_regex`) never sees it.
      #
      # Refusal is the DEFAULT, and the escape hatch is `lenient`, for the reason `gori run`
      # spells out: an opt-in leaves the silent answer as what a caller who has not read this
      # gets. `QL.field_shaped?` keeps a pasted URL (`http://acme.test/x`) and an authority
      # (`acme.test:8443`) out of it — they name no field and are searched as text as before.
      private def ql_unknown_field_error(h, query : String) : Result?
        return nil if bool_arg(h, "lenient", false)
        use = QL.fields_used(query).find { |f| !QL.known_field?(f.name) }
        return nil unless use
        # Echoed with the operator it was WRITTEN with, so `body~` does not come back as `body:`.
        op = use.regex ? '~' : ':'
        near = QL.suggest_field(use.name)
        tail = "pass lenient:true to search it as literal text instead"
        msg =
          if near
            "unknown query field `#{use.name}#{op}` — did you mean `#{near}#{op}`? (#{tail})"
          else
            "unknown query field `#{use.name}#{op}` — QL has no such field. " \
            "Fields: #{QL::FIELDS.join(' ')} (call ql_reference; #{tail})"
          end
        err(msg, "QUERY_SYNTAX", field: "query",
          details: JSON.parse({"unknown_field" => use.name, "suggestion" => near}.to_json))
      end

      # A `~` term with an uncompilable regex degrades to a never-match clause —
      # narrows the result to zero rather than dropping the term (which would
      # broaden, like a bad numeric term does). Unlike that broaden case, this is
      # ALWAYS an error, not gated behind strict: a silently-empty result set
      # looks identical to "no matching flows" to an automated caller.
      private def ql_invalid_regex_error(query : String, bad : Array(String)) : Result
        err("invalid query #{query.inspect}: regex term(s) failed to compile and would " \
            "silently match nothing: #{bad.join(", ")} (call ql_reference; fix the pattern or drop the term)",
          "QUERY_SYNTAX", field: "query",
          details: JSON.parse({"invalid_regex_terms" => bad}.to_json))
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
      @[Tool("ql_explain", unbound: true)]
      private def ql_explain(h) : Result
        query = str(h, "query")
        return err("missing required 'query'", "INVALID_ARGUMENT", field: "query") if query.nil? || query.strip.empty?
        # `ql_explain` is in `Tools::UNBOUND_SAFE` — it is a GRAMMAR tool, callable with no
        # project selected (an agent checking a query before it switches). `store` raises there,
        # so the lens is read only when there is one, and shape-only otherwise: a `scope:` term
        # still compiles (it is not reported as dropped), and the answer below says the project
        # question could not be asked instead of asserting it has no rules.
        bound = !unbound?
        lens = bound ? Scope.ql_lens(store) : QL::SCOPE_SHAPE_ONLY
        a = QL.analyze(query, scope: lens)
        filter = QL.parse(query, scope: lens)
        scope_unconfigured = bound && QL.uses_scope?(query) && !lens.configured?
        scope_unbound = !bound && QL.uses_scope?(query)
        # `QL.reject_empty?` is true when EVERY term was dropped, so the filter is `EMPTY` and
        # the compiled SQL is the literal `1` — it matches the WHOLE capture. This was reported
        # as `matches_nothing`, the exact opposite, in the same object that carried `"sql":"1"`:
        # `ql_explain{query:"host:"}` said the query matched nothing, so the reading an agent
        # takes from it is "loosen the filter" when the fix is the reverse. The other half of
        # the inversion was the never-match case — an uncompilable `~` pattern degrades to `(0)`
        # — which came back `matches_nothing:false` under a warning that said it matched nothing.
        # `saved_views` and `colormarker` have always worded this condition correctly ("matches
        # every flow — it would narrow nothing"); this is the same fact, named the same way.
        matches_all = QL.reject_empty?(query, filter)
        # A field QL does not implement free-texts its WHOLE token, so it compiles to a real
        # clause and `QL.analyze` files it under `applied` — this tool affirmed `methd:GET` as an
        # applied term while the query it described could only ever return nothing. Reported by
        # name, and counted into `refused_by_query_tools` now that the read tools refuse it.
        unknown = QL.fields_used(query).map(&.name).uniq!.reject! { |n| QL.known_field?(n) }
        # …and all three conditions are what `ql_filter_or_error` turns into a QUERY_SYNTAX
        # refusal, which is the one prediction this tool exists to make and never stated: a
        # caller that explained first was told the query would run.
        refused = matches_all || !a.invalid_regex.empty? || !unknown.empty?
        Result.new(JSON.build do |j|
          j.object do
            j.field "query", query
            j.field("applied_terms") { j.array { a.applied.each { |t| j.string t } } }
            j.field("ignored_terms") { j.array { a.ignored.each { |t| j.string t } } }
            j.field("invalid_regex_terms") { j.array { a.invalid_regex.each { |t| j.string t } } }
            j.field("unknown_fields") do
              j.array do
                unknown.each do |n|
                  j.object do
                    j.field "name", n
                    j.field "did_you_mean", QL.suggest_field(n)
                  end
                end
              end
            end
            j.field "matches_everything", matches_all
            j.field "refused_by_query_tools", refused
            j.field "sql", filter.sql
            # Named, not inferred from an empty result: a `scope:` term on a project with no
            # scope rules compiles to a never-match clause, so the query runs clean and returns
            # nothing — and an agent has no way to tell that from "no flow matched". The
            # negation half is stated too, because it is the one direction that BROADENS.
            # nil, not false, with no project bound: "this project has no scope rules" and "there
            # is no project to ask" are different answers and the recovery differs.
            j.field "scope_rules_configured", bound ? lens.configured? : nil
            j.field("warnings") do
              j.array do
                # First, because it OVERRIDES the "dropped (broadens results)" line below: when
                # every term is dropped there are no results to broaden — the query becomes
                # match-all and is refused outright.
                if matches_all
                  j.string "every term was dropped, so this compiles to match-ALL (sql `1`) and " \
                           "list_history / list_sitemap / probe_scan REFUSE it (QUERY_SYNTAX) rather " \
                           "than return the whole capture — fix or drop the term(s), or pass an " \
                           "empty query to get the most recent rows"
                end
                unless unknown.empty?
                  named = unknown.map { |n| (near = QL.suggest_field(n)) ? "`#{n}:` (did you mean `#{near}:`?)" : "`#{n}:`" }
                  j.string "QL has no such field: #{named.join(", ")} — the whole token is " \
                           "searched as literal TEXT, which is why it matches nothing; " \
                           "list_history / list_sitemap / probe_scan REFUSE it (QUERY_SYNTAX) " \
                           "unless you pass lenient:true"
                end
                j.string "dropped (broadens results): #{a.ignored.join(", ")}" unless a.ignored.empty?
                unless a.invalid_regex.empty?
                  j.string "invalid regex, matches nothing: #{a.invalid_regex.join(", ")} — " \
                           "list_history / list_sitemap / probe_scan REFUSE it (QUERY_SYNTAX); " \
                           "fix the pattern or drop the term"
                end
                if scope_unconfigured
                  j.string "no scope rules are configured, so nothing is in scope: `scope:in` and " \
                           "`scope:out` both match NOTHING here (and a negated `-scope:in` matches " \
                           "every flow) — add scope rules with add_scope_rule, or drop the term"
                end
                if scope_unbound
                  j.string "no project is selected, so the `scope:` term was compiled without one: " \
                           "call switch_project (or list_projects) and explain again to learn whether " \
                           "that project has scope rules at all"
                end
              end
            end
          end
        end)
      end

      @[Tool("ql_reference", unbound: true)]
      private def ql_reference : Result
        Result.new(JSON.build { |j| j.object { j.field "reference", QL::REFERENCE } })
      end

      private def ql_error(query : String) : Result
        err(
          "invalid query #{query.inspect}: did not match any field " \
          "(call ql_reference; e.g. host:example.com status:>=500 method:POST)",
          "QUERY_SYNTAX", field: "query")
      end

      # The tools/list schemas for the QL reference tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_ql_tools(j : JSON::Builder) : Nil
        tool j, "ql_reference",
          "Return the gori QL (query language) syntax reference for filtering flows " \
          "(list_history, list_sitemap). Call this before writing complex queries." { }

        tool j, "ql_explain",
          "Diagnose a gori QL query WITHOUT running it: which terms were applied, which " \
          "were silently dropped (broadening results), which regex terms are invalid " \
          "(match nothing), the compiled SQL, and warnings. Use to debug a query that " \
          "returns too many or zero rows. `matches_everything` means every term was dropped " \
          "and the query narrows nothing; `unknown_fields` names a `field:` QL does not " \
          "implement (its whole token is searched as text, so it matches nothing); " \
          "`refused_by_query_tools` means list_history / " \
          "list_sitemap / probe_scan will answer QUERY_SYNTAX rather than run it." do |s|
          s.field "query", strprop("the gori QL query to analyze"), required: true
        end
      end
    end
  end
end
