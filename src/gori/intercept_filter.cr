require "./filter_ast"

module Gori
  # An in-memory boolean filter that NARROWS what the Interceptor holds — the
  # "conditional intercept" lens. It shares QL's grammar (FilterAst: AND/OR/NOT,
  # parentheses, `-`negation, quoting, bare free-text) but evaluates against a LIVE
  # in-flight message at the hold gate, BEFORE anything is captured — so QL's SQL
  # compilation can't be reused (there's no row to query yet). Supported fields:
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

    # Completable field names, in the order the suggestion row offers them. This list is
    # deliberately a strict SUBSET of History's QL fields — a hold gate has no row to
    # query, so `body:`/`header:`/`size:`/`dur:` have nothing to match against. It must
    # stay in lockstep with field_symbol below: completing a field this parser doesn't
    # know would silently degrade the whole token to free text (see parse_term).
    FIELDS = %w(host path method scheme status)

    # Static value pools for the low-cardinality fields (mirrors History's). `host:`
    # has no static pool — its candidates are injected by the caller (the TUI passes
    # the store's DISTINCT hosts); `path:` has none at all, since paths are unbounded.
    METHOD_VAL = %w(GET POST PUT PATCH DELETE HEAD OPTIONS QUERY)
    SCHEME_VAL = %w(http https)
    STATUS_VAL = %w(2xx 3xx 4xx 5xx >=400 >=500 200 301 302 401 403 404 500 502 503)

    # Tab-complete candidates for the token under `cx`: field names until a `:` is
    # typed, then that field's values. The grammar's punctuation is carried through by
    # FilterAst::Cursor, so `-ho` → `-host:` and `(ho` → `(host:`. `hosts` is the
    # caller-supplied host pool (already prefix-filtered by the store query). Empty when
    # the caret sits on blank space, or on a token nothing matches (the human is then
    # deliberately free-texting a word).
    def self.suggestions(query : String, cx : Int32, hosts : Array(String) = [] of String) : Array(String)
      cur = FilterAst.token_at(query, cx)
      return [] of String if cur.core.empty?
      if (colon = cur.core.index(':')) && colon > 0
        field = cur.core[0...colon].downcase
        prefix = FilterAst.unquote_prefix(cur.core[(colon + 1)..])
        suggest_values(field, prefix, hosts).map { |v| "#{cur.prefix}#{field}:#{FilterAst.quote(v)}" }
      else
        FIELDS.select(&.starts_with?(cur.core.downcase)).map { |f| "#{cur.prefix}#{f}:" }
      end
    end

    private def self.suggest_values(field : String, prefix : String, hosts : Array(String)) : Array(String)
      p = prefix.downcase
      values = case field
               when "host"   then hosts
               when "method" then METHOD_VAL
               when "scheme" then SCHEME_VAL
               when "status" then STATUS_VAL
               else               return [] of String
               end
      values.select(&.downcase.starts_with?(p))
    end

    getter source : String

    @tree : FilterAst::Tree(Term)?

    def initialize(@source : String)
      # Compiled once here, so matching walks a ready tree — the hold gate evaluates
      # one per in-flight message on the proxy path.
      @tree = FilterAst.build(FilterAst.parse(@source)) { |t| InterceptFilter.parse_term(t) }
    end

    # No effective predicates → matches everything (the default "hold all" behaviour).
    def blank? : Bool
      @tree.nil?
    end

    # An empty filter matches all. Allocates nothing.
    def matches?(s : Subject) : Bool
      tree = @tree
      return true unless tree
      eval(tree, s)
    end

    private def eval(tree : FilterAst::Tree(Term), s : Subject) : Bool
      case tree.op
      in .leaf? then tree.leaf.matches?(s)
      in .not?  then !eval(tree.children.first, s)
      in .and?  then tree.children.all? { |c| eval(c, s) }
      in .or?   then tree.children.any? { |c| eval(c, s) }
      end
    end

    # Compile one grammar term. nil DROPS it (an empty value, e.g. `host:` mid-type),
    # which folds up to match-all — so the queue doesn't blank out while typing.
    protected def self.parse_term(term : FilterAst::Term) : Term?
      text = term.text
      return nil if text.empty?

      colon = text.index(':')
      if colon && colon > 0
        field = field_symbol(text[0...colon].downcase)
        # An unknown field → free-text the WHOLE token (mirrors QL / Issues::Filter), so a
        # typo'd field like `hsot:evil.com` searches literally instead of silently matching "evil.com".
        return Term.new(:text, text, term.negate?) if field == :text
        value = text[(colon + 1)..]
        return nil if value.empty?
        Term.new(field, value, term.negate?)
      else
        Term.new(:text, text, term.negate?)
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
