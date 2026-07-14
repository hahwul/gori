module Gori
  # An in-memory boolean filter that NARROWS what the Interceptor holds — the
  # "conditional intercept" lens. It mirrors the QL surface (`field:value`, `OR`
  # groups, `-`negation, bare free-text) but evaluates against a LIVE in-flight
  # message at the hold gate, BEFORE anything is captured — so QL's SQL compilation
  # can't be reused (there's no row to query yet). Supported fields:
  #
  #   host:acme        substring of the host
  #   path:/api        substring of the request target (path+query)
  #   method:POST      exact method (case-insensitive)
  #   scheme:https     exact scheme
  #   status:>=500     numeric / class (5xx) comparison — RESPONSES ONLY
  #   token            bare word → substring over method/host/target
  #
  # `status:` only matches a response (a request has no status, so a status term
  # makes a request never match — i.e. it scopes the condition to responses by
  # intent). An empty filter matches everything (hold all in-scope traffic).
  struct InterceptFilter
    # The message attributes available at a hold gate. `status` is set only for a
    # held RESPONSE (nil for a request).
    record Subject,
      method : String,
      host : String,
      target : String,
      scheme : String,
      status : Int32? = nil

    # One parsed predicate. `field` is :host/:path/:method/:scheme/:status, or :text
    # for a bare free-text word. Negation flips the result (mirrors QL's `-term`).
    private record Term, field : Symbol, value : String, negate : Bool do
      def matches?(s : Subject) : Bool
        hit = raw_match?(s)
        negate ? !hit : hit
      end

      private def raw_match?(s : Subject) : Bool
        case field
        when :host   then s.host.downcase.includes?(value.downcase)
        when :path   then s.target.downcase.includes?(value.downcase)
        when :method then s.method.upcase == value.upcase
        when :scheme then s.scheme.downcase == value.downcase
        when :status then (st = s.status) ? InterceptFilter.status_match?(st, value) : false
        else # :text — free-text substring over method/host/target
          v = value.downcase
          s.method.downcase.includes?(v) || s.host.downcase.includes?(v) || s.target.downcase.includes?(v)
        end
      end
    end

    EMPTY = new("")

    getter source : String

    def initialize(@source : String)
      @groups = InterceptFilter.compile(@source) # OR of AND-groups (Array(Array(Term)))
    end

    # No effective predicates → matches everything (the default "hold all" behaviour).
    def blank? : Bool
      @groups.empty?
    end

    # Match: OR across groups, AND within a group (mirrors QL.parse's grouping). An
    # empty filter matches all. Called on the proxy hot path, so it allocates nothing.
    def matches?(s : Subject) : Bool
      groups = @groups
      return true if groups.empty?
      groups.any? { |group| group.all?(&.matches?(s)) }
    end

    # Parse a query into OR-separated AND-groups of Terms (the same shape QL.parse
    # builds before it emits SQL). Empty-valued / unparsable terms are dropped; a
    # group with no surviving terms is dropped; no groups → match-all.
    protected def self.compile(query : String) : Array(Array(Term))
      tokens = query.split
      return [] of Array(Term) if tokens.empty?

      groups = [[] of String]
      tokens.each { |tok| tok == "OR" ? (groups << [] of String) : groups.last << tok }

      compiled = [] of Array(Term)
      groups.each do |group|
        terms = [] of Term
        group.each do |tok|
          if term = parse_term(tok)
            terms << term
          end
        end
        compiled << terms unless terms.empty?
      end
      compiled
    end

    private def self.parse_term(token : String) : Term?
      negate = token.starts_with?('-')
      token = token[1..] if negate
      return nil if token.empty?

      colon = token.index(':')
      if colon && colon > 0
        field = field_symbol(token[0...colon].downcase)
        # An unknown field → free-text the WHOLE token (mirrors QL / Issues::Filter), so a
        # typo'd field like `hsot:evil.com` searches literally instead of silently matching "evil.com".
        return Term.new(:text, token, negate) if field == :text
        value = token[(colon + 1)..]
        return nil if value.empty?
        Term.new(field, value, negate)
      else
        Term.new(:text, token, negate)
      end
    end

    # Map a field name to its Term symbol. An unknown field is treated as free text
    # over the WHOLE token (mirrors QL's "unknown field → free text" fallback).
    private def self.field_symbol(field : String) : Symbol
      case field
      when "host"   then :host
      when "path"   then :path
      when "method" then :method
      when "scheme" then :scheme
      when "status" then :status
      else               :text
      end
    end

    # Numeric / status-class comparison, mirroring QL.status_cond's semantics so the
    # live gate and the History `status:` query agree. Supports <,<=,>,>=,= and an
    # `Nxx` class (e.g. `5xx` → 500..599; `>=4xx` → >=400). Unparsable → no match.
    def self.status_match?(actual : Int32, value : String) : Bool
      op = "="
      rest = value
      {"<=", ">=", "<", ">", "="}.each do |o|
        if value.starts_with?(o)
          op = o
          rest = value[o.size..]
          break
        end
      end

      if rest.size == 3 && rest[1] == 'x' && rest[2] == 'x' && rest[0].ascii_number?
        base = rest[0].to_i * 100
        case op
        when ">=" then return actual >= base
        when ">"  then return actual >= base + 100
        when "<=" then return actual < base + 100
        when "<"  then return actual < base
        else           return actual >= base && actual < base + 100
        end
      end

      n = rest.to_i?
      return false unless n
      case op
      when ">=" then actual >= n
      when ">"  then actual > n
      when "<=" then actual <= n
      when "<"  then actual < n
      else           actual == n
      end
    end
  end
end
