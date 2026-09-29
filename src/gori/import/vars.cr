require "json"

module Gori
  module Import
    # `{{variable}}` substitution shared by the Postman and Insomnia parsers — the two
    # request-collection formats that store templated URLs rather than concrete ones.
    #
    # Postman writes `{{baseUrl}}`; Insomnia v4 (nunjucks) writes `{{ _.baseUrl }}` and the
    # older `{{ baseUrl }}`. One pattern covers all three: optional inner whitespace and an
    # optional `_.` prefix.
    module Vars
      # `[^{}\s]+?` (non-greedy, no braces/space) keeps a stray `{{` in a JSON body from
      # swallowing the rest of the string looking for a closing `}}`.
      PLACEHOLDER = /\{\{\s*(?:_\.)?([^{}\s]+?)\s*\}\}/

      alias Table = Hash(String, String)

      # A variable's VALUE may itself hold placeholders — `baseUrl = "https://{{host}}/api"`
      # is routine in real collections. One pass would leave `{{host}}` behind and the entry
      # would be skipped as "references variables not defined in the collection", naming a
      # variable that IS defined. So expand to a fixpoint, capped so a self-referential
      # `a = "{{a}}"` terminates instead of spinning.
      MAX_PASSES = 5

      # Replace every placeholder `table` defines; leave the rest VERBATIM rather than
      # blanking it. A leftover `{{token}}` in a header or body is a visible, greppable
      # placeholder (the same stance `oas.cr` takes with its `PLACEHOLDER` header values);
      # only the URL is checked for leftovers, by the callers, because there a leftover
      # would become a literal stored host (see `unresolved`).
      #
      # Growth is budgeted, and the budget is checked inside the pass, as each placeholder is
      # replaced: a collection defining `a = "{{a}}{{a}}…"` (k copies) and a URL of `{{a}}` is a
      # few hundred bytes of JSON that expands to k^5 copies over the five passes — 10^10 for
      # k = 100 — and one pass alone multiplies by k. Past the budget the entry is refused
      # (the callers' per-entry rescue skips it) rather than built.
      def self.expand(text : String, table : Table) : String
        out = text
        budget = MAX_GROWTH
        MAX_PASSES.times do
          break unless out.includes?("{{")
          pass = out.gsub(PLACEHOLDER) do |full, m|
            value = table[m[1]]?
            next full unless value
            budget -= value.bytesize - full.bytesize
            raise Gori::Error.new("variables expand past #{MAX_GROWTH} bytes (a self-multiplying {{#{m[1]}}}?)") if budget < 0
            value
          end
          break if pass == out # nothing left this table can resolve
          out = pass
        end
        out
      end

      # How many bytes `expand` may add to one value, over all of its passes. Far past any real
      # collection's variables, and well short of what a self-multiplying one reaches.
      MAX_GROWTH = 16 * 1024 * 1024

      # The placeholder NAMES still present after `expand`. Callers use this both to reject
      # an entry and to report which variables were missing when a whole file resolves to
      # nothing. `Builder::HOST_VALID` would now reject a `{{baseUrl}}` host too, but only as
      # "invalid URL (bad host)" — this names the variable that was not set, which is the
      # thing the operator has to act on.
      def self.unresolved(text : String) : Array(String)
        return [] of String unless text.includes?("{{")
        text.scan(PLACEHOLDER).map(&.[1])
      end

      # A brace left in the URL's AUTHORITY after expansion, from something `unresolved`
      # cannot see: a variable whose value is a JSON object/array (`{"k":"v"}`), or a
      # single-brace template form this parser does not speak. `Builder::HOST_VALID` is the
      # backstop for that shape and refuses it too, but generically; this one says a
      # variable was left unexpanded, which is the actionable statement. Only the authority
      # is checked — a brace in the path, query or fragment is the operator's own data and
      # stays verbatim.
      def self.braced_authority?(url : String) : Bool
        s = url
        if i = s.index("://")
          s = s[(i + 3)..]
        end
        cut = [s.index('/'), s.index('?'), s.index('#'), s.size].compact.min
        authority = s[0, cut]
        authority.includes?('{') || authority.includes?('}')
      end

      # Collect `[{key/name: …, value: …}]` — the shape Postman's `variable` array and
      # Insomnia's environment `data` both reduce to — into a table, skipping disabled rows.
      def self.merge!(table : Table, node : JSON::Any?) : Table
        arr = node.try(&.as_a?)
        return table unless arr
        arr.each do |v|
          h = v.as_h?
          next unless h
          next if h["disabled"]?.try(&.as_bool?) == true
          key = (h["key"]? || h["name"]?).to_s
          next if key.empty?
          table[key] = value_to_s(h["value"]?)
        end
        table
      end

      # A variable value is usually a string but may be a number/bool (Postman does not
      # enforce a type). `JSON::Any#to_s` on a string returns it unquoted, which is what a
      # URL/header substitution wants; on a scalar it renders the literal.
      def self.value_to_s(node : JSON::Any?) : String
        return "" unless node
        return "" if node.raw.nil?
        node.as_s? || node.to_s
      end
    end
  end
end
