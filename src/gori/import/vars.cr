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
      # (the callers' per-entry rescue skips it) rather than built. Inside `per_entry` the
      # budget is the ENTRY's, shared by its URL, every header and the body: a variable that
      # expands to just under a per-value budget, used in 200 headers, is gigabytes too.
      def self.expand(text : String, table : Table) : String
        out = text
        budget = @@entry_budgets[Fiber.current]? || Budget.new
        MAX_PASSES.times do
          break unless out.includes?("{{")
          pass = out.gsub(PLACEHOLDER) do |full, m|
            value = table[m[1]]?
            next full unless value
            budget.left -= value.bytesize - full.bytesize
            raise Gori::Error.new("variables expand past #{MAX_GROWTH} bytes (a self-multiplying {{#{m[1]}}}?)") if budget.left < 0
            value
          end
          break if pass == out # nothing left this table can resolve
          out = pass
        end
        out
      end

      # How many bytes expansion may add to one request, over all of its fields and passes.
      # Far past any real collection's variables, and well short of what a self-multiplying
      # one reaches.
      MAX_GROWTH = 16 * 1024 * 1024

      private class Budget
        property left : Int64 = MAX_GROWTH.to_i64
      end

      # Keyed by fiber: two imports can run at once (a TUI import beside an MCP one), and
      # each entry's scope belongs to the fiber walking it.
      @@entry_budgets = {} of Fiber => Budget

      # Run one import entry with a single growth budget for every `expand` inside it.
      def self.per_entry(&)
        fiber = Fiber.current
        outer = @@entry_budgets[fiber]?
        @@entry_budgets[fiber] = Budget.new
        begin
          yield
        ensure
          outer ? (@@entry_budgets[fiber] = outer) : @@entry_budgets.delete(fiber)
        end
      end

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
        # Only a LEADING scheme: a scheme-less `{{host}}/login?next=https://x` would otherwise
        # be cut at the query's `://` and read `x` as the authority.
        s = url.sub(Builder::LEADING_SCHEME, "")
        cut = [s.index('/'), s.index('?'), s.index('#'), s.size].compact.min
        authority = s[0, cut]
        authority.includes?('{') || authority.includes?('}')
      end

      # The expanded URL, or a skip naming why it cannot be stored: a variable left
      # unexpanded in the host (recorded in `missing`, so a file that resolves to nothing can
      # say which), a braced host, or nothing at all. A leftover in the path or query stays
      # verbatim, like one in a header: `/users/{{userId}}` or `?t={{$timestamp}}` (Postman's
      # dynamic variables) is routine, and refusing it dropped the whole request. It is kept
      # as the bare `{{name}}`: Insomnia's `{{ _.name }}` spacing would put a space in the
      # request line.
      def self.checked_url(url : String, missing : Set(String)) : String
        if braced_authority?(url)
          left = unresolved(url)
          raise Gori::Error.new("templated host in URL: #{url}") if left.empty?
          left.each { |n| missing << n }
          raise Gori::Error.new("unresolved variable in URL: #{url}")
        end
        raise Gori::Error.new("request has an empty url") if url.empty?
        url.includes?("{{") ? url.gsub(PLACEHOLDER) { |_, m| "{{#{m[1]}}}" } : url
      end

      # A fixed boundary (not a random one): imports must be reproducible, and two runs over
      # the same collection should produce byte-identical flows.
      FORM_BOUNDARY = "----GoriImportFormBoundary"

      # A multipart body of a form editor's enabled text rows; the block reads each format's
      # own `{name, value}` pairs out of them. A `type: "file"` part references a path on
      # the exporter's machine, so dropping it keeps the other fields rather than discarding
      # the whole request.
      def self.form_data(node : JSON::Any?, & : JSON::Any -> Array({String, String})) : {Bytes?, String?}
        arr = node.try(&.as_a?)
        return {nil, nil} unless arr
        text_parts = arr.select do |item|
          h = item.as_h?
          !!h && h["disabled"]?.try(&.as_bool?) != true && h["type"]?.to_s != "file"
        end
        pairs = yield JSON::Any.new(text_parts)
        return {nil, nil} if pairs.empty?
        body = String.build do |b|
          pairs.each do |(k, v)|
            b << "--" << FORM_BOUNDARY << "\r\n"
            b << %(Content-Disposition: form-data; name="#{k}") << "\r\n\r\n"
            b << v << "\r\n"
          end
          b << "--" << FORM_BOUNDARY << "--\r\n"
        end
        {body.to_slice, "multipart/form-data; boundary=#{FORM_BOUNDARY}"}
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
