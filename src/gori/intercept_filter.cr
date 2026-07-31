require "./filter_ast"
require "./proto"

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
  #   proto:ws         the application protocol — and the WebSocket hold's OPT-IN
  #   body:token       substring of a WebSocket message payload — WS MESSAGES ONLY
  #   token            bare word → substring over method/host/target
  #
  # `status:` only matches a response (a request has no status, so a status term
  # makes a request never match — i.e. it scopes the condition to responses by
  # intent). An empty filter matches everything (hold all in-scope traffic).
  #
  # ## `proto:ws` is not just another term (#500 step 2)
  #
  # A WebSocket message is held ONLY when the condition carries an explicit,
  # un-negated `proto:ws` — see `mentions_ws?`. That inverts the HTTP default on
  # purpose: a blank filter holds every in-scope HTTP message, and holds no WS
  # message at all. A browser tolerates one stalled request; a socket carrying tens
  # of messages a second, frozen whole by an unqualified `host:acme`, is not a state
  # an operator can drain their way out of.
  #
  # `body:` was excluded here for years because "a hold gate has no row to query".
  # For a WebSocket message the payload IS the message and is in hand at the gate, so
  # the reason does not apply — but only there: at an HTTP gate the raw bytes do not
  # exist yet, so `body:` never matches one.
  struct InterceptFilter
    # The message attributes available at a hold gate. `status` is set only for a
    # held RESPONSE (nil for a request); `payload` only for a held WebSocket message.
    record Subject,
      method : String,
      host : String,
      target : String,
      scheme : String,
      status : Int32? = nil,
      proto : Proto::Kind = Proto::Kind::Http,
      payload : Bytes? = nil

    # One parsed predicate. `field` is :host/:path/:method/:scheme/:status/:proto/:body,
    # or :text for a bare free-text word. Negation flips the result (mirrors QL's `-term`).
    private record Term, field : Symbol, value : String, negate : Bool do
      # Is this leaf the WebSocket hold's opt-in? A NEGATED `proto:ws` is not: it says
      # "everything but WebSocket", which is the opposite of asking for it.
      def ws_opt_in? : Bool
        !negate && field == :proto && value == "ws"
      end

      def matches?(s : Subject) : Bool
        hit = raw_match?(s)
        negate ? !hit : hit
      end

      # `value` arrives already case-folded from `parse_term` (downcased, or UPCASED for
      # :method), so nothing here re-folds the pattern. It used to `.downcase` it on every
      # call — allocating a fresh String per in-flight message on the proxy hold path, for
      # a pattern that cannot change after parse. The two equality fields compare
      # case-insensitively so the SUBJECT need not be folded either; the substring fields
      # still fold their subject, which is why `matches?` no longer claims zero allocation.
      private def raw_match?(s : Subject) : Bool
        case field
        when :host   then s.host.downcase.includes?(value)
        when :path   then s.target.downcase.includes?(value)
        when :method then s.method.compare(value, case_insensitive: true) == 0
        when :scheme then s.scheme.compare(value, case_insensitive: true) == 0
        when :status then (st = s.status) ? InterceptFilter.status_match?(st, value) : false
        when :proto  then InterceptFilter.proto_name(s.proto) == value
        when :body   then (p = s.payload) ? InterceptFilter.body_includes?(p, value) : false
        else # :text — free-text substring over method/host/target
          s.method.downcase.includes?(value) || s.host.downcase.includes?(value) ||
            s.target.downcase.includes?(value)
        end
      end
    end

    EMPTY = new("")

    # Completable field names, in the order the suggestion row offers them. Still a strict
    # SUBSET of History's QL fields — `header:`/`size:`/`dur:` have no row to query at a hold
    # gate — but `body:` joined it with #500 step 2, because a held WebSocket message carries
    # its payload to the gate. It must stay in lockstep with field_symbol below: completing a
    # field this parser doesn't know would silently degrade the whole token to free text (see
    # parse_term).
    FIELDS = %w(host path method scheme status proto body)

    # Static value pools for the low-cardinality fields (mirrors History's). `host:`
    # has no static pool — its candidates are injected by the caller (the TUI passes
    # the store's DISTINCT hosts); `path:`/`body:` have none at all, since their values
    # are unbounded.
    METHOD_VAL = %w(GET POST PUT PATCH DELETE HEAD OPTIONS QUERY)
    SCHEME_VAL = %w(http https)
    STATUS_VAL = %w(2xx 3xx 4xx 5xx >=400 >=500 200 301 302 401 403 404 500 502 503)
    PROTO_VAL  = %w(ws http grpc sse)

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
               when "proto"  then PROTO_VAL
               else               return [] of String
               end
      values.select(&.downcase.starts_with?(p))
    end

    getter source : String

    @tree : FilterAst::Tree(Term)?
    @mentions_ws : Bool

    def initialize(@source : String)
      # Compiled once here, so matching walks a ready tree — the hold gate evaluates
      # one per in-flight message on the proxy path.
      tree = FilterAst.build(FilterAst.parse(@source)) { |t| InterceptFilter.parse_term(t) }
      @tree = tree
      # Answered ONCE, at parse: the WS arming gate asks per socket AND per message, and a
      # tree walk per message on a chatty socket is exactly the hot path this filter is
      # compiled to avoid.
      @mentions_ws = tree ? InterceptFilter.mentions_ws?(tree) : false
    end

    # No effective predicates → matches everything (the default "hold all" behaviour).
    def blank? : Bool
      @tree.nil?
    end

    # Does this condition explicitly ask for WebSocket messages? THE opt-in for the WS
    # hold (#500 step 2, design D1) — and the whole gate, not a narrowing of one: no
    # `proto:ws` term means no WS message is ever held, whatever else the condition says.
    #
    # An OR reaching a `proto:ws` leaf arms it, which is deliberately generous: the
    # operator typed the term, and the per-message `matches?` below still decides. A leaf
    # under a NOT does not, and neither does `-proto:ws` — see `Term#ws_opt_in?`.
    def mentions_ws? : Bool
      @mentions_ws
    end

    # A NOT subtree is not descended into: `NOT (proto:ws)` selects everything that is not
    # a WebSocket message, so reading the term inside it as an opt-in would arm the gate on
    # the one condition that says to leave WS alone.
    protected def self.mentions_ws?(tree : FilterAst::Tree(Term)) : Bool
      case tree.op
      in .leaf? then tree.leaf.ws_opt_in?
      in .not?  then false
      in .and?  then tree.children.any? { |c| mentions_ws?(c) }
      in .or?   then tree.children.any? { |c| mentions_ws?(c) }
      end
    end

    # An empty filter matches all. Patterns are pre-folded at parse time, so matching a
    # host/path/free-text term costs one `downcase` of the subject and nothing else.
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
        return Term.new(:text, text.downcase, term.negate?) if field == :text
        value = text[(colon + 1)..]
        return nil if value.empty?
        Term.new(field, fold(field, value), term.negate?)
      else
        Term.new(:text, text.downcase, term.negate?)
      end
    end

    # Case-fold a term's value ONCE, at parse time, into the form `raw_match?` compares
    # against. `:status` is folded too — `status_match?` tests a literal lowercase 'x',
    # so `status:5XX` matched nothing at all before this. `:proto` is CANONICALIZED
    # through the same parser QL uses, so `proto:WebSocket` and `proto:ws` are one term
    # (and `mentions_ws?` has a single spelling to test).
    private def self.fold(field : Symbol, value : String) : String
      return value.upcase if field == :method
      folded = value.downcase
      return folded unless field == :proto
      Proto::Kind.parse?(folded).try { |k| proto_name(k) } || folded
    end

    # The wire spelling of a `proto:` value, as constants rather than `Kind#to_s.downcase`
    # — this is compared once per in-flight message and must not allocate to do it.
    protected def self.proto_name(kind : Proto::Kind) : String
      case kind
      in .http? then "http"
      in .ws?   then "ws"
      in .grpc? then "grpc"
      in .sse?  then "sse"
      end
    end

    # ASCII-case-insensitive substring search over RAW payload bytes. Deliberately not
    # `String.new(payload).downcase.includes?` — a WebSocket payload is as likely to be
    # protobuf/msgpack as text, and decoding it would both allocate a copy of every message
    # on a chatty socket and mangle non-UTF-8 bytes into U+FFFD before the compare. `needle`
    # arrives already downcased from `parse_term`; a non-ASCII needle therefore matches
    # case-sensitively, which is the same deal `host:`/`path:` strike.
    protected def self.body_includes?(hay : Bytes, needle : String) : Bool
      pat = needle.to_slice
      return true if pat.empty?
      return false if pat.size > hay.size
      i = 0
      limit = hay.size - pat.size
      while i <= limit
        j = 0
        while j < pat.size && ascii_fold(hay[i + j]) == pat[j]
          j += 1
        end
        return true if j == pat.size
        i += 1
      end
      false
    end

    private def self.ascii_fold(b : UInt8) : UInt8
      b >= 0x41_u8 && b <= 0x5A_u8 ? b + 0x20_u8 : b
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
      when "proto"  then :proto
      when "body"   then :body
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
