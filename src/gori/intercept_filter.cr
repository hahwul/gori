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
  #   host~^api\.      `~` is regex, on host / path / url / method / scheme / header / body
  #                    (QL's REGEX_FIELDS, less the sides this backend has no columns for)
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
  # The same rule decides `scope:`, one level up: what is in hand here is a MESSAGE, and a
  # project's scope rules are not part of one. Two of this filter's three callers hold no Scope
  # at all, so the field is refused by name rather than answered at one surface and silently
  # false at the others — `UNSUPPORTED_FIELDS` has the whole argument, including what a NEGATED
  # refusal does to a hold gate.
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
    # :body, :text for a bare free-text word, or :never for a `~` whose pattern would not compile
    # — or for a field QL implements and this backend refuses (`UNSUPPORTED_FIELDS`).
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
          when :method then InterceptFilter.regex_hit?(rx, s.method)
          when :scheme then InterceptFilter.regex_hit?(rx, s.scheme)
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
        when :never  then false # an uncompilable `~`, or a refused field — see `parse_term`
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

    # Fields QL implements that this backend REFUSES BY NAME, and the whole of that list.
    #
    # `scope:` is one because a hold gate has no project scope to consult and cannot be given one
    # honestly: the interceptor could compute it (it already evaluates `Scope#in_scope_url?` per
    # message), but the other two callers of this filter cannot — `Bindings#observe_response`
    # (extract-rule conditions) holds no Scope at all, and neither does the repeater's sender. A
    # field that answers correctly at one of three surfaces and silently FALSE at the other two is
    # the failure this backend's "what is in hand" table exists to prevent, so the term is refused
    # everywhere instead. History, colour rules and MCP answer it via `QL::ScopeLens`.
    #
    # Refused means `:never`, NOT free text. An unknown field free-texts the whole token, which
    # for `scope:in` would search method/host/target for the literal string, match nothing, and
    # read as "no traffic is in scope" — the silent answer this file refuses to give. `:never` is
    # the same clause an uncompilable `~` gets, and it carries the same caveat: NEGATED
    # (`-scope:in`) it holds EVERYTHING, which on a hold gate is the proxy path and not a display
    # list. That is why the surfaces where such a condition can be TYPED or SAVED name it —
    # `ExtractRuleOverlay#invalid_reason` refuses it outright (an extract rule persists), and the
    # intercept bar paints the field muted (`GATE_KNOWN`) and notes it beside the condition.
    # DERIVED, not typed out, because it was typed out and drifted: `scope` was the only member
    # while ELEVEN more QL fields fell through `field_symbol`'s else to free text — the exact
    # degradation the paragraph above refuses for `scope`. `FIELDS`' own comment already names
    # them ("`size:`/`respsize:`/`dur:` need an exchange that has FINISHED, and `stub:` needs a
    # capture decision that has not been made"), so the list QL implements minus the list this
    # backend implements IS the answer, and the two can no longer disagree: adding a field to
    # `FIELDS` retires its refusal in the same edit. Aliases resolve first, so `res.body:` is
    # refused for the reason `resp.body:` is rather than free-texting past the check.
    UNSUPPORTED_FIELDS = begin
      names = QL::FIELDS.reject { |f| FIELDS.includes?(f) }
      QL::FIELD_ALIASES.each do |from, to|
        names << from unless FIELDS.includes?(to)
      end
      names
    end

    # Does `source` name a field this backend refuses? For a surface that has to SAY so; reads
    # `QL.fields_used`, the tokenizer both backends compile through, so it reports exactly the
    # tokens that would act as fields — a quoted `"scope:in"` included, since the grammar strips
    # quotes before either backend splits a token and `parse_term` refuses it just the same.
    def self.unsupported_fields(source : String) : Array(String)
      QL.fields_used(source).map(&.name).uniq!.select! { |n| UNSUPPORTED_FIELDS.includes?(n) }
    end

    # The refusal a condition naming one of those fields earns, or nil. ONE sentence, here rather
    # than at each surface, because five of them refuse it: `Bindings#validate` (so MCP
    # `create_extract_rule` and `gori run rewriter extract add` refuse an extract rule's `when:`),
    # the TUI form that says the same thing a keystroke earlier without a store, and the two doors
    # that submit a COMPLETE intercept condition (MCP `intercept_set_filter`, `gori run intercept
    # filter`). Naming what the condition IS rather than which row it was typed in — the same
    # sentence has to read correctly as an extract rule's `when:` and as a catch condition.
    def self.unsupported_field_reason(source : String) : String?
      bad = unsupported_fields(source).first?
      return nil unless bad
      "`#{bad}:` is not available in a live-message condition (an intercept catch condition or " \
      "an extract rule's when:) — #{unanswerable_because(bad)}. " \
      "History, colour rules and MCP `query` answer it."
    end

    # WHY the field in hand cannot be answered here, as the middle clause of that one sentence.
    # Each arm reads off the same "what is in hand" table the class header lays out: a gate holds
    # ONE message, mid-flight, before any capture decision — so what it lacks is the finished
    # exchange, the stored row, and the project around it, in that order.
    private def self.unanswerable_because(field : String) : String
      case QL::FIELD_ALIASES[field]? || field
      when "scope"
        "the project's scope rules are not part of a message"
      when "size", "reqsize", "respsize", "dur"
        "an exchange that has not finished has no size or duration yet"
      when "stub"
        "whether a body was stored is a CAPTURE decision, made after this gate"
      when "src"
        "a flow's source is recorded when it is captured, not while it is in flight"
      when .includes?('.')
        # The `req.`/`resp.` half. A gate stands on one leg and already knows which, so the
        # side prefix is not narrowing anything — it is naming bytes that are not in hand.
        "a gate holds ONE leg, so `#{field.split('.').last}:` already means the message in hand"
      else
        # A field QL grows that this backend has not implemented. Generic on purpose: a wrong
        # reason reads worse than no reason, and the arms above are what a new field earns once
        # somebody decides which of them it belongs to.
        "a message in flight carries no such value"
      end
    end

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

    # What each field means AT A HOLD GATE — deliberately NOT `QL::FIELD_HELP`, even though the
    # names and the grammar are shared. Three of these mean something materially different here,
    # and a completion row that borrowed QL's wording would state the difference backwards:
    #
    #   status:  scopes the condition to RESPONSES (a request has no status, so the term makes
    #            every request fail rather than comparing anything).
    #   header:  the head of the message IN HAND — request head at the request gate, response head
    #            at the response gate. There is no `req.`/`resp.` here because a gate only ever
    #            stands on one leg; the leg IS the direction.
    #   body:    the payload in hand, which per the class header is a WS message or an Extract
    #            rule's response body — never an HTTP hold, where the gate is what decides whether
    #            to buffer a body at all.
    # MERGED over QL's rather than copied from it: five of the nine entries were byte-identical,
    # so editing QL's `path` line would have updated History, Sitemap and the colour-rule band and
    # silently left this bar saying the old thing — the exact drift the generated hints were built
    # to end. What is written out is precisely the DELTA, which is also the documentation.
    # `reject` first: `QL::FIELD_HELP` now carries a line for `scope:`, and a help table that
    # describes a field the parser refuses is how a completion row teaches a term that can never
    # match. The refusal and the help stay derived from the one list.
    FIELD_HELP = QL::FIELD_HELP.reject { |name, _| UNSUPPORTED_FIELDS.includes?(name) }.merge({
      "status" => "code/class — and scopes to RESPONSES only",
      "proto"  => "http, or ws to opt WebSocket messages IN",
      "header" => "head of the message in hand (this leg only)",
      "body"   => "payload in hand — WS messages, extract rules",
    })

    # As a proc, built once: the bar draws this every frame while the condition is being edited,
    # and an inline closure at the call site allocates one per frame.
    FIELD_HELP_PROC = ->(f : String) { FIELD_HELP[f]? }

    def self.field_help(name : String) : String?
      FIELD_HELP[name]?
    end

    # The subset a one-row hint samples (see `QL::HINT_FIELDS` for why a hint samples at all).
    # NOT `FIELDS.first(6)`, which would spend the row on `url:`/`scheme:` and cut exactly the two
    # this gate is interesting for: `header:` is the only way to condition on a header, and `body:`
    # arrived with the WebSocket hold.
    HINT_FIELDS = %w[host path method status header body]

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
        suggest_values(field, prefix, hosts, fields).map { |v| "#{cur.prefix}#{field}:#{FilterAst.quote(v)}" }
      else
        fields.select(&.starts_with?(cur.core.downcase)).map { |f| "#{cur.prefix}#{f}:" }
      end
    end

    # `fields` is the CALLER's name pool, and it decides one thing here: whether a field THIS
    # backend refuses may still be completed. A colour rule answers `scope:` and passes QL's
    # wider list (`Colormarker::USEFUL_FIELDS`); a hold gate refuses the field, and completing
    # its values there would teach a term that compiles to a never-match — the trap `FIELDS`'s
    # own comment names, arriving from the value side instead of the name side. Derived from
    # `UNSUPPORTED_FIELDS` rather than written as an arm per field, so the next refused field
    # needs no second copy of the rule.
    private def self.suggest_values(field : String, prefix : String, hosts : Array(String),
                                    fields : Array(String)) : Array(String)
      return [] of String if UNSUPPORTED_FIELDS.includes?(field) && !fields.includes?(field)
      values = value_pool(field, hosts, row_backed?(fields))
      return [] of String unless values
      p = prefix.downcase
      values.select(&.downcase.starts_with?(p))
    end

    # The pool for one field, or nil when this field has no closed vocabulary to offer.
    #
    # `rows` says the CALLER's backend evaluates captured rows rather than a live message (see
    # `row_backed?`), and two fields answer differently for the two:
    #
    #   proto:  a hold gate gets the narrow `PROTO_VAL`, for the reason written there. A colour
    #           rule is matched against a captured response and so answers `proto:grpc` /
    #           `proto:wss` perfectly — offering it only `ws`/`http` made that bar under-report
    #           a vocabulary its own backend accepts.
    #   stub:   row-backed ONLY. `stub` is not in this parser's `FIELDS`, so a hold-gate bar never
    #           completes the name and can never reach these values; the colour-rule overlay does
    #           (`Colormarker::USEFUL_FIELDS` is `QL::FIELDS`), and there it had the shape a closed
    #           field must not have — the name completes, the value list is empty, and the field
    #           reads as one that takes free text.
    #
    # Split from `suggest_values` because the two caller-dependent arms put that method over
    # ameba's cyclomatic ceiling, and "which pool" is a different question from "may this caller
    # complete this field at all".
    private def self.value_pool(field : String, hosts : Array(String), rows : Bool) : Array(String)?
      case field
      when "host"   then hosts
      when "method" then METHOD_VAL
      when "scheme" then SCHEME_VAL
      when "status" then STATUS_VAL
      when "scope"  then QL::SCOPE_VALUES
      when "src"    then QL::SOURCE_VALUES
      when "proto"  then rows ? QL::PROTO_VALUES : PROTO_VAL
      when "stub"   then rows ? QL::STUB_VALUES : nil
      end
    end

    # Whether the CALLER's field pool is QL's whole vocabulary rather than a hold gate's subset —
    # equivalently, whether its backend evaluates against CAPTURED ROWS. `UNSUPPORTED_FIELDS` is
    # exactly the difference between the two lists, so this is the question `suggest_values`
    # already asks per field, asked once for the pool as a whole. Derived rather than a flag,
    # so a third caller cannot arrive without answering it.
    private def self.row_backed?(fields : Array(String)) : Bool
      UNSUPPORTED_FIELDS.any? { |f| fields.includes?(f) }
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
      # A field QL implements and this backend refuses (`UNSUPPORTED_FIELDS`) — a never-match
      # term, and BEFORE the operator split so `scope~in` cannot free-text where `scope:in` does
      # not. Whether a name was meant as a field is not an operator's business.
      #
      # An EMPTY value still DROPS, like every other field's: this method's header promises a
      # mid-typed `host:` folds to match-all so the queue does not blank out, and the intercept
      # bar applies the condition on EVERY keystroke (`InterceptController`). Without this guard
      # the `:` in `scope:` stopped the gate holding anything — or, under `-`, made it hold every
      # in-flight message — before the value that makes the term refusable had been typed.
      if field == :never
        return nil if value.empty?
        return Term.new(:never, text.downcase, term.negate?)
      end
      return regex_term(field, value, text, term.negate?) if sep == ti

      # An unknown field → free-text the WHOLE token (mirrors QL / Issues::Filter), so a
      # typo'd field like `hsot:evil.com` searches literally instead of silently matching "evil.com".
      return Term.new(:text, text.downcase, term.negate?) if field == :text
      return nil if value.empty?
      Term.new(field, fold(field, value), term.negate?)
    end

    # The `~` half of `parse_term`. An unknown field free-texts the whole token; a field this
    # backend HAS but offers no `~` on (`status~5..`) is DROPPED — the two roads `QL.regex_cond`
    # takes, so a term means the same thing in both bars. Free-texting the known one searched the
    # target for the literal `status~5..`, which matches nothing and looks like a regex that
    # found nothing.
    private def self.regex_term(field : Symbol, value : String, text : String, negate : Bool) : Term?
      unless REGEX_FIELDS.includes?(field)
        return field == :text ? Term.new(:text, text.downcase, negate) : nil
      end
      return nil if value.empty?
      # Compiled ONCE, here, never per message. A pattern that will not compile becomes a
      # never-match term rather than an exception on the proxy path — mirroring QL, where an
      # invalid `~` compiles to a never-match clause. Both surfaces that let an operator SAVE
      # such a condition (`Colormarker.unusable_reason`, and the intercept bar's own note)
      # refuse it where it is typed, which is the place it can still be fixed.
      pattern = begin
        Regex.new(value)
      rescue
        return Term.new(:never, value, negate)
      end
      Term.new(field, value, negate, pattern)
    end

    # The fields `~` is accepted on, as Term symbols. QL's `REGEX_FIELDS` in this backend's
    # vocabulary — the same names (less the `req.`/`resp.` sides, which a single message has no
    # two of), so a pattern that is a regex in the filter bar is a regex here.
    REGEX_FIELDS = [:host, :path, :url, :method, :scheme, :header, :body]

    # Does this backend implement `name` — and, with `regex: true`, under the `~` operator? The
    # highlighter's predicate (`InterceptView::GATE_KNOWN`), shaped like `QL.known_field?` so the
    # two bars ask their backends the same question.
    def self.known_field?(name : String, regex : Bool = false) : Bool
      return false unless FIELDS.includes?(name)
      !regex || REGEX_FIELDS.includes?(field_symbol(name))
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
      else
        # A refused name is NOT an unknown one: it must not degrade to free text (see
        # `UNSUPPORTED_FIELDS`). Everything else still does.
        UNSUPPORTED_FIELDS.includes?(field) ? :never : :text
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
