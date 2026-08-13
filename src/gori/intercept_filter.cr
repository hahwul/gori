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
  #   url:acme/api     substring of scheme://host + target (`Url.request_url`)
  #   method:POST      exact method (case-insensitive)
  #   scheme:https     exact scheme
  #   status:>=500     numeric / class (5xx) comparison — RESPONSES ONLY
  #   proto:ws         the application protocol — and the WebSocket hold's OPT-IN
  #   header:x-trace   substring of the head bytes of the message in hand
  #   body:token       substring of the body bytes in hand — see "what is in hand" below
  #   host~^api\.      `~` is regex, on host / path / url / header / body (QL's REGEX_FIELDS)
  #   token            bare word → substring over method/host/target
  #
  # `status:` only matches a response (a request has no status, so a status term
  # makes a request never match — i.e. it scopes the condition to responses by
  # intent). An empty filter matches everything (hold all in-scope traffic).
  #
  # ## What is in hand, and why that is the whole rule (#665 follow-up)
  #
  # `header:` and `body:` read `Subject#head` / `Subject#payload`, which each caller fills in
  # with whatever it genuinely has at the moment it asks. Nothing here reaches for bytes that
  # do not exist, and a term with no bytes to read answers FALSE rather than pretending:
  #
  #   HTTP request gate   head = the request head. Body: NO — the gate is what DECIDES whether
  #                       to buffer the body, so asking it about the body is circular.
  #   HTTP response gate  head = the response head. Body: NO, for the same reason.
  #   WebSocket message   payload = the message. No head: a WS message has no head of its own.
  #   Extract rules       head AND body of the response — `Bindings#observe_response` is handed
  #                       both, so a condition there can read either.
  #
  # A colour rule is NOT in this list on purpose: it runs against a captured row with no bytes
  # at all, so `Colormarker` compiles those conditions to QL and asks the store instead. See its
  # class header for the tier split.
  #
  # And in every row of that table the bytes are WIRE bytes, which is worth stating because the
  # extract case makes it easy to assume otherwise: `Bindings#observe_response` evaluates the
  # condition BEFORE any decode (deliberately — see `candidates` there, it is what keeps a rule
  # from decoding every response it does not want), and only the extraction that follows
  # decompresses. So `body:secret` does not match a gzipped body ANYWHERE, including on the one
  # surface whose extraction reaches straight through gzip.
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
  struct InterceptFilter
    # The message attributes available at a hold gate. `status` is set only for a held RESPONSE
    # (nil for a request); `head` and `payload` are the bytes the caller has — see "what is in
    # hand" above. Both default to nil, so a caller that adds nothing keeps exactly the behaviour
    # it had, and a `header:`/`body:` term simply does not match it.
    record Subject,
      method : String,
      host : String,
      target : String,
      scheme : String,
      status : Int32? = nil,
      proto : Proto::Kind = Proto::Kind::Http,
      payload : Bytes? = nil,
      head : Bytes? = nil do
      # `url:`'s haystack, built the way `QL::URL_EXPR` builds it in SQL. Not memoised: only a
      # `url:` term asks for it, and a Subject is a struct built fresh per message.
      def url : String
        Url.request_url(scheme, host, target)
      end
    end

    # One parsed predicate. `field` is :host/:path/:url/:method/:scheme/:status/:proto/:header/
    # :body, :text for a bare free-text word, or :never for a `~` whose pattern would not compile.
    # `pattern` is non-nil exactly when the term was written with `~`. Negation flips the result
    # (mirrors QL's `-term`).
    private record Term, field : Symbol, value : String, negate : Bool, pattern : Regex? = nil do
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
        if rx = pattern
          return case field
          when :host   then InterceptFilter.regex_hit?(rx, s.host)
          when :path   then InterceptFilter.regex_hit?(rx, s.target)
          when :url    then InterceptFilter.regex_hit?(rx, s.url)
          when :header then (h = s.head) ? InterceptFilter.regex_hit?(rx, h) : false
          when :body   then (p = s.payload) ? InterceptFilter.regex_hit?(rx, p) : false
          else              false
          end
        end
        case field
        when :host   then s.host.downcase.includes?(value)
        when :path   then s.target.downcase.includes?(value)
        when :url    then s.url.downcase.includes?(value)
        when :method then s.method.compare(value, case_insensitive: true) == 0
        when :scheme then s.scheme.compare(value, case_insensitive: true) == 0
        when :status then (st = s.status) ? InterceptFilter.status_match?(st, value) : false
        when :proto  then InterceptFilter.proto_name(s.proto) == value
        when :header then (h = s.head) ? InterceptFilter.bytes_include?(h, value) : false
        when :body   then (p = s.payload) ? InterceptFilter.bytes_include?(p, value) : false
        when :never  then false # a `~` whose pattern would not compile — see `parse_term`
        else                    # :text — free-text substring over method/host/target
          s.method.downcase.includes?(value) || s.host.downcase.includes?(value) ||
            s.target.downcase.includes?(value)
        end
      end
    end

    EMPTY = new("")

    # Completable field names, in the order the suggestion row offers them. Still a SUBSET of
    # History's QL fields, and now for one reason instead of two: what is missing is what a live
    # message genuinely cannot answer — `size:`/`respsize:`/`dur:` need an exchange that has
    # FINISHED, and `stub:` needs a capture decision that has not been made. `header:` and `url:`
    # are here because the bytes and the parts are both in hand; `body:` joined with #500 step 2.
    # Must stay in lockstep with `field_symbol` below: completing a field this parser doesn't
    # know would silently degrade the whole token to free text (see `parse_term`).
    FIELDS = %w[host path url method scheme status proto header body]

    # Static value pools for the low-cardinality fields (mirrors History's). `host:`
    # has no static pool — its candidates are injected by the caller (the TUI passes
    # the store's DISTINCT hosts); `path:`/`body:` have none at all, since their values
    # are unbounded.
    METHOD_VAL = %w[GET POST PUT PATCH DELETE HEAD OPTIONS QUERY]
    SCHEME_VAL = %w[http https]
    STATUS_VAL = %w[2xx 3xx 4xx 5xx >=400 >=500 200 301 302 401 403 404 500 502 503]
    # `ws`/`http` ONLY — a strict subset of History's `proto:` pool, for the same reason this
    # whole field list is one. A hold gate knows the protocol from the leg it is standing on
    # (`Subject#proto` is `Ws` for a WebSocket message and `Http` for everything else); `grpc`
    # and `sse` are decided from a captured response's Content-Type, which does not exist yet at
    # a gate. Offering them completed a term that can never match — i.e. a `proto:grpc`
    # condition silently holds NOTHING, which reads as intercept being broken.
    PROTO_VAL = %w[ws http]

    # Tab-complete candidates for the token under `cx`: field names until a `:` is
    # typed, then that field's values. The grammar's punctuation is carried through by
    # FilterAst::Cursor, so `-ho` → `-host:` and `(ho` → `(host:`. `hosts` is the
    # caller-supplied host pool (already prefix-filtered by the store query). Empty when
    # the caret sits on blank space, or on a token nothing matches (the human is then
    # deliberately free-texting a word).
    # `fields` is the pool to complete NAMES from, defaulting to what this parser answers. A
    # caller whose backend accepts MORE than a hold gate can — a colour rule, which falls back to
    # QL for the fields a live message cannot answer — passes its own wider list and still gets
    # these value pools, rather than growing a second copy of the completion logic.
    def self.suggestions(query : String, cx : Int32, hosts : Array(String) = [] of String,
                         fields : Array(String) = FIELDS) : Array(String)
      cur = FilterAst.token_at(query, cx)
      return [] of String if cur.core.empty?
      if (colon = cur.core.index(':')) && colon > 0
        field = cur.core[0...colon].downcase
        prefix = FilterAst.unquote_prefix(cur.core[(colon + 1)..])
        suggest_values(field, prefix, hosts).map { |v| "#{cur.prefix}#{field}:#{FilterAst.quote(v)}" }
      else
        fields.select(&.starts_with?(cur.core.downcase)).map { |f| "#{cur.prefix}#{f}:" }
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
    @mentions_body : Bool

    def initialize(@source : String)
      # Compiled once here, so matching walks a ready tree — the hold gate evaluates
      # one per in-flight message on the proxy path.
      tree = FilterAst.build(FilterAst.parse(@source)) { |t| InterceptFilter.parse_term(t) }
      @tree = tree
      # Answered ONCE, at parse: the WS arming gate asks per socket AND per message, and a
      # tree walk per message on a chatty socket is exactly the hot path this filter is
      # compiled to avoid.
      @mentions_ws = tree ? InterceptFilter.mentions_ws?(tree) : false
      @mentions_body = tree ? InterceptFilter.mentions_body?(tree) : false
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

    # Does this condition read a message BODY anywhere in it? Asked by a caller deciding whether
    # to BUFFER one it would otherwise stream past (`Bindings#extracts_body?`), so this is about
    # what the evaluation NEEDS, not about what the operator asked for.
    #
    # Which is why it descends into NOT where `mentions_ws?` refuses to. The two look alike and
    # answer opposite questions: `-body:secret` with no body buffered evaluates `body:secret` to
    # false and negates it to TRUE, so the rule fires on every message — the silent-BROADEN
    # direction. `NOT proto:ws`, by contrast, is precisely the condition that says to leave
    # sockets alone, and reading it as an opt-in would arm the gate it asked to disarm.
    def mentions_body? : Bool
      @mentions_body
    end

    protected def self.mentions_body?(tree : FilterAst::Tree(Term)) : Bool
      case tree.op
      in .leaf? then tree.leaf.field == :body
      in .not?  then mentions_body?(tree.children.first)
      in .and?  then tree.children.any? { |c| mentions_body?(c) }
      in .or?   then tree.children.any? { |c| mentions_body?(c) }
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

      # The first ':' or '~' wins, whichever comes first — QL.split_field's exact rule, so a
      # regex value may itself contain a ':' (`url~https?://x`) and the two backends cut the
      # same token the same way.
      ci = text.index(':')
      ti = text.index('~')
      sep = [ci, ti].compact.min?
      return Term.new(:text, text.downcase, term.negate?) unless sep && sep > 0

      field = field_symbol(text[0...sep].downcase)
      value = text[(sep + 1)..]
      if sep == ti
        # An unknown field, or one QL does not offer `~` on, free-texts the whole token — the
        # same fallback `QL.regex_cond` takes, so `size~1` means the same thing in both.
        return Term.new(:text, text.downcase, term.negate?) unless REGEX_FIELDS.includes?(field)
        return nil if value.empty?
        # Compiled ONCE, here, never per message. A pattern that will not compile becomes a
        # never-match term rather than an exception on the proxy path — mirroring QL, where an
        # invalid `~` compiles to a never-match clause. Both surfaces that let an operator SAVE
        # such a condition (`Colormarker.unusable_reason`, and the intercept bar's own note)
        # refuse it where it is typed, which is the place it can still be fixed.
        pattern = begin
          Regex.new(value)
        rescue
          return Term.new(:never, value, term.negate?)
        end
        return Term.new(field, value, term.negate?, pattern)
      end

      # An unknown field → free-text the WHOLE token (mirrors QL / Issues::Filter), so a
      # typo'd field like `hsot:evil.com` searches literally instead of silently matching "evil.com".
      return Term.new(:text, text.downcase, term.negate?) if field == :text
      return nil if value.empty?
      Term.new(field, fold(field, value), term.negate?)
    end

    # The fields `~` is accepted on, as Term symbols. QL's `REGEX_FIELDS` in this backend's
    # vocabulary — the same five, so a pattern that is a regex in the filter bar is a regex here.
    REGEX_FIELDS = [:host, :path, :url, :header, :body]

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

    # ASCII-case-insensitive substring search over RAW bytes — a payload for `body:`, a head for
    # `header:`. Deliberately not `String.new(bytes).downcase.includes?` — a WebSocket payload is
    # as likely to be protobuf/msgpack as text, and decoding it would both allocate a copy of
    # every message on a chatty socket and mangle non-UTF-8 bytes into U+FFFD before the compare.
    # `needle` arrives already downcased from `parse_term`; a non-ASCII needle therefore matches
    # case-sensitively, which is the same deal `host:`/`path:` strike.
    protected def self.bytes_include?(hay : Bytes, needle : String) : Bool
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

    # A `~` term's match, and the ONLY place this filter runs a regex. Two guards, and neither
    # is optional on this path:
    #
    #   `.scrub` — PCRE2 RAISES `UTF-8 error: illegal byte` on an invalid byte rather than
    #     simply not matching. The haystack here is a request target an operator or a peer put
    #     on the wire, or raw head/payload bytes; a raise from a hold gate takes down the
    #     connection fiber. This is the same hazard `Gori::SafeRegexp` exists to contain on the
    #     SQL side, and `Store::FlowRow.absolute_form?` cites for staying Regex-free.
    #   `rescue` — a residual PCRE2 error (recursion/match limit on a pathological pattern) is a
    #     no-match, never an exception escaping onto the proxy path.
    #
    # `.scrub` allocates a copy of the haystack, so a `~` term costs one string per message it
    # is asked about. Nothing else in this filter allocates per message, and nothing pays this
    # unless the operator wrote a `~`.
    protected def self.regex_hit?(pattern : Regex, hay : String) : Bool
      pattern.matches?(hay.scrub)
    rescue
      false
    end

    protected def self.regex_hit?(pattern : Regex, hay : Bytes) : Bool
      regex_hit?(pattern, String.new(hay))
    end

    # Map a field name to its Term symbol. An unknown field is treated as free text
    # over the WHOLE token (mirrors QL's "unknown field → free text" fallback).
    private def self.field_symbol(field : String) : Symbol
      case field
      when "host"   then :host
      when "path"   then :path
      when "url"    then :url
      when "method" then :method
      when "scheme" then :scheme
      when "status" then :status
      when "proto"  then :proto
      when "header" then :header
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
