require "db"

module Gori
  # The query language (DESIGN.md §4): a Lucene/KQL-style boolean filter over the
  # captured flows, compiled to a SQL WHERE fragment + bound params (values are
  # always parameterised — never interpolated — so the projection columns stay
  # injection-safe). The analysis surface; QL is how you find things (P8: pull).
  #
  #   host:acme status:>=500            # AND of terms
  #   method:post path:/api OR flag:x   # OR of AND-groups
  #   -host:cdn  status:5xx  login      # negation, status class, free text
  #   body:token                        # scan request/response body bytes
  module QL
    # Fields: host path method scheme status flag body (+ bare words = free text).
    struct Filter
      getter sql : String # safe to splice into "WHERE ..."; values are in `args`
      getter args : Array(DB::Any)

      def initialize(@sql : String, @args : Array(DB::Any))
      end
    end

    EMPTY = Filter.new("1", [] of DB::Any)

    # Combines two filters with AND (used to layer the Scope lens over a query).
    def self.and(a : Filter, b : Filter) : Filter
      return b if a.sql == "1"
      return a if b.sql == "1"
      Filter.new("(#{a.sql}) AND (#{b.sql})", a.args + b.args)
    end

    def self.parse(query : String) : Filter
      tokens = query.split
      return EMPTY if tokens.empty?

      groups = [[] of String]
      tokens.each do |tok|
        tok == "OR" ? (groups << [] of String) : groups.last << tok
      end

      args = [] of DB::Any
      clauses = [] of String
      groups.each do |group|
        conds = [] of String
        group.each do |term|
          if result = term_to_sql(term)
            cond, cargs = result
            conds << cond
            args.concat(cargs)
          end
        end
        clauses << "(#{conds.join(" AND ")})" unless conds.empty?
      end

      clauses.empty? ? EMPTY : Filter.new(clauses.join(" OR "), args)
    end

    private def self.term_to_sql(term : String) : {String, Array(DB::Any)}?
      negate = term.starts_with?('-')
      term = term[1..] if negate
      return nil if term.empty?

      colon = term.index(':')
      result = (colon && colon > 0) ? field_cond(term[0...colon].downcase, term[(colon + 1)..]) : free_text(term)
      return nil unless result

      cond, args = result
      {negate ? "NOT (#{cond})" : cond, args}
    end

    private def self.field_cond(field : String, value : String) : {String, Array(DB::Any)}?
      return nil if value.empty?
      case field
      when "host"   then {"lower(host) LIKE ?", [like(value)] of DB::Any}
      when "path"   then {"lower(target) LIKE ?", [like(value)] of DB::Any}
      when "method" then {"upper(method) = ?", [value.upcase] of DB::Any}
      when "scheme" then {"scheme = ?", [value.downcase] of DB::Any}
      when "status" then status_cond(value)
      when "body"   then body_cond(value)
      when "flag"   then {"0", [] of DB::Any} # tags not implemented yet → matches nothing
      else               free_text(value)     # unknown field: treat the value as free text
      end
    end

    # Body search scans the raw request/response BLOBs (the truth, P7) as text.
    # A simple LIKE scan (no FTS index) — adequate for a single-user proxy's flow
    # counts and avoids a migration/backfill (P0). CAST(blob AS TEXT) reinterprets
    # the octets. The `IS NOT NULL` guards make a bodyless flow evaluate to FALSE
    # (not NULL), so `-body:x` correctly KEEPS bodyless flows instead of dropping
    # every one of them to NULL-logic.
    private def self.body_cond(value : String) : {String, Array(DB::Any)}
      p = like(value)
      {"((request_body IS NOT NULL AND lower(CAST(request_body AS TEXT)) LIKE ?) OR " \
       "(response_body IS NOT NULL AND lower(CAST(response_body AS TEXT)) LIKE ?))",
       [p, p] of DB::Any}
    end

    private def self.status_cond(value : String) : {String, Array(DB::Any)}?
      op = "="
      rest = value
      {"<=", ">=", "<", ">", "="}.each do |o|
        if value.starts_with?(o)
          op = o
          rest = value[o.size..]
          break
        end
      end

      # status class: 2xx / 4xx / 5xx → range
      if rest.size == 3 && rest[1] == 'x' && rest[2] == 'x' && rest[0].ascii_number?
        base = rest[0].to_i * 100
        return {"(status >= ? AND status < ?)", [base, base + 100] of DB::Any}
      end

      n = rest.to_i?
      return nil unless n
      {"status #{op} ?", [n] of DB::Any}
    end

    private def self.free_text(word : String) : {String, Array(DB::Any)}
      pattern = like(word)
      {"(lower(method) LIKE ? OR lower(host) LIKE ? OR lower(target) LIKE ?)",
       [pattern, pattern, pattern] of DB::Any}
    end

    private def self.like(value : String) : DB::Any
      "%#{value.downcase}%"
    end
  end
end
