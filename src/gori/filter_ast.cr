module Gori
  # The boolean grammar shared by every filter surface — History QL, Intercept catch
  # rules, Repeater sub-tabs, Issues and Probe. It owns ONLY the shape of a query
  # (how tokens are cut, grouped and combined); what a single token MEANS stays with
  # each backend, because they legitimately differ (QL compiles to SQL and drops a bad
  # numeric term, Probe keeps a half-typed `-host:` matching everything so the list
  # doesn't blank out mid-keystroke). Backends fold a parsed tree into their own
  # representation with `build`.
  #
  #   host:acme status:>=500          AND is implicit (whitespace)
  #   host:a AND host:b               ...and also spellable, since typing AND and
  #                                   having it silently free-text was a trap
  #   host:a OR host:b                OR
  #   (host:a OR host:b) -method:GET  parentheses group; `-` negates one term
  #   NOT (host:cdn OR host:static)   NOT negates a term OR a whole group
  #   host:"my host"  "two words"     quotes keep spaces inside one token
  #
  # `AND`/`OR`/`NOT` are recognised UPPERCASE-only and unquoted, so the far more
  # common case of searching for the words "and"/"or"/"not" still works; quote them
  # ("AND") to force a literal even in caps. Precedence is NOT > AND > OR.
  module FilterAst
    # One `field:value` / `field~value` / bare-word predicate — the leaf every backend
    # parses for itself. `text` is normalised for matching (quotes and the leading `-`
    # removed); `source` is the chunk exactly as typed, which diagnostics echo back
    # (QL's `analyze`) and Tab-completion splices over.
    #
    # `negate` rides on the LEAF rather than becoming a NotNode because the backends
    # disagree about negating an EMPTY value — `-host:` filters nothing in Probe but
    # matches nothing in Issues — and that difference is deliberate and spec-pinned in
    # both. A NotNode wrapper would silently unify them. `NOT term` desugars onto this
    # same flag, so the keyword and the `-` prefix stay exactly equivalent.
    struct Term
      getter text : String
      getter source : String
      getter? negate : Bool

      def initialize(@text : String, @source : String, @negate : Bool = false)
      end

      # `NOT` applied to a single term: flip the flag rather than nest, so
      # `NOT host:a` and `-host:a` compile to the identical leaf.
      def negated : Term
        Term.new(@text, @source, !@negate)
      end
    end

    abstract class Node
    end

    class TermNode < Node
      getter term : Term

      def initialize(@term : Term)
      end
    end

    # AND / OR over two or more children (the parser never builds a 1-child group).
    class AndNode < Node
      getter children : Array(Node)

      def initialize(@children : Array(Node))
      end
    end

    class OrNode < Node
      getter children : Array(Node)

      def initialize(@children : Array(Node))
      end
    end

    # `NOT (group)` only — `NOT term` desugars onto Term#negate above.
    class NotNode < Node
      getter child : Node

      def initialize(@child : Node)
      end
    end

    # --- lexing --------------------------------------------------------------

    private enum Tok
      Word
      And
      Or
      Not
      LParen
      RParen
    end

    # `start`/`size` are the lexeme's character span in the ORIGINAL query (quotes
    # included), which is what syntax highlighting paints over.
    private record Lexeme, tok : Tok, term : Term?, start : Int32, size : Int32

    # Cut the query into lexemes. Whitespace separates chunks unless it sits inside
    # double quotes; a quote is a grouping device only (it never survives into `text`).
    #
    # PARENTHESES are position-sensitive on purpose. A URL path is full of them
    # (`path:/a(b)`), and treating every paren as syntax would break queries that work
    # today. So `(` opens a group only at the START of a chunk, and `)` closes one only
    # at the END of a chunk AND only while a group is actually open. `path:/a(b)` is
    # therefore one literal word, while `(host:a OR host:b)` groups as written. Quote
    # the value (`path:"/a(b)"`) to force a literal in any position.
    private def self.lex(query : String) : Array(Lexeme)
      acc = [] of Lexeme
      depth = 0
      each_chunk(query) do |raw, chars, quoted_any, at|
        lead = 0
        while lead < chars.size && chars[lead][0] == '(' && !chars[lead][1]
          lead += 1
        end
        trail = 0
        # `depth + lead` — a chunk may open and close its own group (`(a)`).
        while trail < chars.size - lead &&
              chars[chars.size - 1 - trail][0] == ')' && !chars[chars.size - 1 - trail][1] &&
              depth + lead - trail > 0
          trail += 1
        end

        # `raw` is contiguous in the source (quoted whitespace is kept, unquoted
        # whitespace ended the chunk), so a source position is just `at + index`.
        lead.times { |k| acc << Lexeme.new(Tok::LParen, nil, at + k, 1) }
        depth += lead

        word_len = raw.size - lead - trail
        text = String.build { |io| chars[lead, chars.size - lead - trail].each { |c| io << c[0] } }
        unless text.empty?
          acc << Lexeme.new(word_tok(text, quoted_any),
            word_term(text, raw[lead, word_len], chars[lead][1]),
            at + lead, word_len)
        end

        trail.times { |k| acc << Lexeme.new(Tok::RParen, nil, at + lead + word_len + k, 1) }
        depth -= trail
      end
      acc
    end

    # Keywords are UPPERCASE and unquoted; anything else is a searchable word.
    private def self.word_tok(text : String, quoted_any : Bool) : Tok
      return Tok::Word if quoted_any
      case text
      when "AND" then Tok::And
      when "OR"  then Tok::Or
      when "NOT" then Tok::Not
      else            Tok::Word
      end
    end

    # A leading `-` negates, but only with something after it — a lone `-` is a word
    # (the backends that free-text it have always done so) — and only when the `-`
    # itself was typed OUTSIDE quotes, so `"-a"` searches for the literal text `-a`
    # exactly as `"AND"` searches for the literal word. The test is the QUOTED FLAG OF
    # THAT ONE CHARACTER, not `quoted_any`: `-host:"my host"` quotes only the value and
    # must still negate. This is the single place negation is decided — `word_spans`
    # paints from the Term it produces rather than re-deriving the rule, so the colour
    # cannot drift from the parse.
    private def self.word_term(text : String, source : String, lead_quoted : Bool) : Term
      if !lead_quoted && text.starts_with?('-') && text.size > 1
        Term.new(text[1..], source, true)
      else
        Term.new(text, source, false)
      end
    end

    # Split on unquoted whitespace, yielding the chunk as typed (`raw`), its chars with
    # the quote marks removed and each flagged as quoted-or-not, whether the chunk
    # carried any quoting at all (which suppresses keyword recognition), and the chunk's
    # starting character offset in `query`.
    private def self.each_chunk(query : String, & : String, Array({Char, Bool}), Bool, Int32 ->) : Nil
      raw = String::Builder.new
      chars = [] of {Char, Bool}
      quoted_any = false
      in_quote = false
      start = 0
      pending = false

      query.each_char_with_index do |ch, i|
        if ch == '"'
          start = i unless pending
          in_quote = !in_quote
          quoted_any = true
          raw << ch
          pending = true
        elsif ch.whitespace? && !in_quote
          if pending
            yield raw.to_s, chars, quoted_any, start
            raw = String::Builder.new
            chars = [] of {Char, Bool}
            quoted_any = false
            pending = false
          end
        else
          start = i unless pending
          raw << ch
          chars << {ch, in_quote}
          pending = true
        end
      end
      yield raw.to_s, chars, quoted_any, start if pending
    end

    # --- parsing -------------------------------------------------------------

    # Parse a query into a tree, or nil when it holds nothing to match on. Deliberately
    # FORGIVING about structure: these queries are re-parsed on every keystroke, so an
    # unclosed `(` simply closes at end-of-input and a dangling operator is ignored,
    # rather than blanking the list while the user is still typing.
    def self.parse(query : String) : Node?
      lexemes = lex(query)
      return nil if lexemes.empty?
      pos = 0
      node, _ = parse_or(lexemes, pos)
      node
    end

    private def self.parse_or(lx : Array(Lexeme), pos : Int32) : {Node?, Int32}
      node, pos = parse_and(lx, pos)
      children = node ? [node] : [] of Node
      while pos < lx.size && lx[pos].tok.or?
        pos += 1
        rhs, pos = parse_and(lx, pos)
        children << rhs if rhs
      end
      return {nil, pos} if children.empty?
      {children.size == 1 ? children.first : OrNode.new(children), pos}
    end

    # AND binds tighter than OR. The operator is optional: adjacent terms combine with
    # AND, which is what whitespace has always meant here.
    private def self.parse_and(lx : Array(Lexeme), pos : Int32) : {Node?, Int32}
      children = [] of Node
      loop do
        while pos < lx.size && lx[pos].tok.and? # explicit AND, or a stray one
          pos += 1
        end
        break if pos >= lx.size || lx[pos].tok.or? || lx[pos].tok.r_paren?
        before = pos
        node, pos = parse_unary(lx, pos)
        if node
          children << node
        elsif pos == before
          # No node AND no progress: the dangling-`)` case parse_primary leaves for the
          # enclosing group. Anything else would spin here.
          break
        end
        # A nil node that DID consume input is an empty group (`()`, `("")`, `(AND)`) or
        # a `NOT` over one. Skip just that group and keep going — breaking here would
        # silently discard every remaining term in the chain, turning `host:a () x:1`
        # into a bare `host:a` that no diagnostic could see (the dropped lexemes never
        # reach `analyze`, so it still reported `clean?`). On a security proxy a filter
        # that quietly BROADENS is the dangerous direction.
      end
      return {nil, pos} if children.empty?
      {children.size == 1 ? children.first : AndNode.new(children), pos}
    end

    private def self.parse_unary(lx : Array(Lexeme), pos : Int32) : {Node?, Int32}
      if pos < lx.size && lx[pos].tok.not?
        node, pos = parse_unary(lx, pos + 1)
        return {nil, pos} unless node
        # A lone term flips its own flag; only a group needs a wrapper.
        return {node.is_a?(TermNode) ? TermNode.new(node.term.negated) : NotNode.new(node), pos}
      end
      parse_primary(lx, pos)
    end

    private def self.parse_primary(lx : Array(Lexeme), pos : Int32) : {Node?, Int32}
      return {nil, pos} if pos >= lx.size
      lexeme = lx[pos]
      if lexeme.tok.l_paren?
        node, pos = parse_or(lx, pos + 1)
        pos += 1 if pos < lx.size && lx[pos].tok.r_paren? # tolerate the unclosed group
        return {node, pos}
      end
      if term = lexeme.term
        return {TermNode.new(term), pos + 1}
      end
      # A `)` reached here only via a dangling `NOT )` — leave it for the enclosing
      # group to consume, so the paren depth stays balanced.
      {nil, pos}
    end

    # Every leaf, left to right, for callers that report on terms rather than match
    # with them (QL's `analyze` / `invalid_regex_terms`).
    def self.terms(node : Node?) : Array(Term)
      acc = [] of Term
      collect(node, acc)
      acc
    end

    # NOTE: `out` is a Crystal keyword and cannot be passed as an argument — hence `acc`.
    private def self.collect(node : Node?, acc : Array(Term)) : Nil
      case node
      when TermNode then acc << node.term
      when NotNode  then collect(node.child, acc)
      when AndNode  then node.children.each { |c| collect(c, acc) }
      when OrNode   then node.children.each { |c| collect(c, acc) }
      end
    end

    # Pull the terms a backend handles ITSELF out of a query, returning them plus the
    # residual for the normal parser. For a surface that owns a field the shared backend
    # knows nothing about — Sitemap's `tag:`, which has no SQL column and filters the
    # built TREE rather than the rows — the alternative is re-tokenising with
    # `String#split`, which sees no quotes, no parens and no `-`/`NOT`, so `tag:"my tag"`
    # tore in half and `NOT tag:done` INCLUDED what it was asked to exclude.
    #
    # Cutting from the same lexer means a hand-rolled field gets the grammar's quoting
    # and negation for free. It does NOT get the boolean structure: the residual is
    # rejoined with spaces, so extracted terms end up ANDed with whatever is left.
    # Callers that care must say so (see SitemapView's tag note).
    #
    # NOTE: iterated by index rather than `each` — `yield` inside a block is what the
    # Crystal compiler refuses here.
    def self.partition(query : String, & : Term -> Bool) : {Array(Term), String}
      taken = [] of Term
      kept = [] of String
      lexemes = lex(query)
      i = 0
      while i < lexemes.size
        # A run of NOT keywords sitting directly before a term desugars ONTO that term —
        # `parse_unary` does exactly this — and the desugaring happens at parse time, not
        # in the lexer, so a lexeme-level scan would hand back `tag:done` unnegated and
        # leave a bare `NOT` dangling in the residual. Take the run with the term.
        run = 0
        while i + run < lexemes.size && lexemes[i + run].tok.not?
          run += 1
        end
        nxt = lexemes[i + run]?
        if run > 0 && nxt && (nt = nxt.term) && yield nt
          taken << (run.odd? ? nt.negated : nt)
          i += run + 1
          next
        end
        lx = lexemes[i]
        t = lx.term
        if t && yield t
          taken << t
        else
          kept << query[lx.start, lx.size]
        end
        i += 1
      end
      {taken, kept.join(' ')}
    end

    # --- syntax highlighting -------------------------------------------------

    enum SpanKind
      Operator # AND / OR / NOT, and the `-` prefix (which means the same thing)
      Paren    # a `(`/`)` that actually groups
      Field    # the `host:` / `body~` prefix, separator included
      Value    # what follows a field separator
      Quote    # the `"` marks themselves
      Plain    # a bare free-text word
    end

    record Span, start : Int32, size : Int32, kind : SpanKind

    # Classify a query for highlighting, driven by the SAME lexer the parser runs. That
    # equivalence is the point: whatever is painted as an operator is exactly what ACTS
    # as one, so a lowercase `or`, a quoted "AND", and a `(` inside a value all stay
    # plain — the colour tells you how the query will really be read.
    #
    # Spans are ordered and non-overlapping, but need not cover every character
    # (whitespace between terms is skipped); callers fill gaps with their base colour.
    #
    # `seps` is which characters this BACKEND accepts as a field separator, and it is
    # not decoration: only QL implements the `~` regex operator, so painting `title~x`
    # as a field in the Issues bar would advertise a match that backend will never
    # perform (it free-texts the whole token instead). Structure is shared; the operator
    # set is not, so the caller states it. See `SEPS_FIELD` / `SEPS_FIELD_REGEX`.
    SEPS_FIELD       = ":"
    SEPS_FIELD_REGEX = ":~"

    def self.spans(query : String, seps : String = SEPS_FIELD_REGEX) : Array(Span)
      acc = [] of Span
      lex(query).each do |lexeme|
        case lexeme.tok
        when .l_paren?, .r_paren?
          acc << Span.new(lexeme.start, lexeme.size, SpanKind::Paren)
        when .and?, .or?, .not?
          acc << Span.new(lexeme.start, lexeme.size, SpanKind::Operator)
        else
          word_spans(query, lexeme, acc, seps)
        end
      end
      acc
    end

    # Index of the separator that makes `[from, to)` a field term, or nil for free text.
    # Needs at least one character of field name before it, and a quote appearing first
    # means the whole thing is a quoted phrase rather than a `field:value`.
    private def self.field_sep(query : String, from : Int32, to : Int32, seps : String) : Int32?
      j = from
      while j < to
        ch = query[j]
        return nil if ch == '"'
        return j if seps.includes?(ch) && j > from
        j += 1
      end
      nil
    end

    # Sub-classify one word: an optional `-`, an optional `field:`/`field~` prefix, then
    # the remainder with any quote marks called out.
    private def self.word_spans(query : String, lexeme : Lexeme, acc : Array(Span), seps : String) : Nil
      s = lexeme.start
      e = s + lexeme.size
      i = s
      # Ask the lexeme whether it negated rather than re-reading the `-` off the source:
      # re-deriving is how the colour drifts from the parse (`-"` looks negated but is a
      # literal dash; `"-a"` looks literal but used to negate).
      if lexeme.term.try(&.negate?)
        acc << Span.new(i, 1, SpanKind::Operator) # `-x` is `NOT x`; colour them alike
        i += 1
      end

      sep = field_sep(query, i, e, seps)
      if sep
        acc << Span.new(i, sep - i + 1, SpanKind::Field)
        i = sep + 1
      end

      kind = sep ? SpanKind::Value : SpanKind::Plain
      run = i
      while i < e
        if query[i] == '"'
          acc << Span.new(run, i - run, kind) if i > run
          acc << Span.new(i, 1, SpanKind::Quote)
          run = i + 1
        end
        i += 1
      end
      acc << Span.new(run, e - run, kind) if e > run
    end

    # --- Tab-completion support ----------------------------------------------

    # The token under the caret, split so a completion can splice in place. `prefix` is
    # the punctuation a candidate must carry over untouched — an opening `(`, then a `-`
    # negation — and `core` is what actually gets matched and replaced. `start`/`stop`
    # bound the whole token in the query. Shared by every filter bar so a leading paren
    # or a negation behaves the same wherever you type it.
    record Cursor, prefix : String, core : String, start : Int32, stop : Int32

    def self.token_at(query : String, cx : Int32) : Cursor
      cx = cx.clamp(0, query.size)
      s = cx
      while s > 0 && !query[s - 1].whitespace?
        s -= 1
      end
      e = cx
      while e < query.size && !query[e].whitespace?
        e += 1
      end
      token = query[s...e]
      i = 0
      while i < token.size && token[i] == '('
        i += 1
      end
      i += 1 if i < token.size - 1 && token[i] == '-' # `-` negates only with more after it
      Cursor.new(token[0...i], token[i..], s, e)
    end

    # Strip a half-typed opening quote off a value prefix, so `host:"exa` still
    # completes against `example.com`.
    def self.unquote_prefix(value : String) : String
      value.starts_with?('"') ? value[1..] : value
    end

    # Quote a completed value only when it needs it — an unquoted space would split the
    # token in two the next time the query is parsed.
    def self.quote(value : String) : String
      value.each_char.any?(&.whitespace?) ? %("#{value}") : value
    end

    # --- folding into a backend tree -----------------------------------------

    # Named for the operators rather than All/Any, both because it reads closer to the
    # query and because `op.any?` would collide with Enumerable#any? for every reader
    # (human and linter) of a `tree.children.any?` line right beside it.
    enum Op
      Leaf
      And
      Or
      Not
    end

    # A parsed query compiled to one backend's leaves — a SQL fragment + bound args
    # for QL, a pre-parsed predicate record for the in-memory filters. Building it once
    # at parse time keeps matching allocation-free, which the Intercept hold gate needs
    # (it evaluates one per in-flight message on the proxy path).
    class Tree(T)
      getter op : Op
      getter children : Array(Tree(T))

      def initialize(@op : Op, @leaf : T? = nil, @children : Array(Tree(T)) = [] of Tree(T))
      end

      # Only meaningful for Op::Leaf.
      def leaf : T
        @leaf.as(T)
      end

      # Every compiled leaf, left to right — for callers that INSPECT a query rather
      # than match with it (e.g. Probe asking whether status is constrained at all).
      def leaves : Array(T)
        acc = [] of T
        collect_leaves(acc)
        acc
      end

      protected def collect_leaves(acc : Array(T)) : Nil
        @op.leaf? ? (acc << leaf) : @children.each(&.collect_leaves(acc))
      end
    end

    # Fold a parsed tree into a backend tree. `leaf` compiles one Term and may return
    # nil to DROP it (a bad numeric, an empty value); a combinator left with no
    # surviving children drops in turn, so a query whose every term was dropped folds
    # to nil — which every backend already reads as "no constraint".
    def self.build(node : Node?, &leaf : Term -> T?) : Tree(T)? forall T
      node ? build_node(node, leaf) : nil
    end

    private def self.build_node(node : Node, leaf : Proc(Term, T?)) : Tree(T)? forall T
      case node
      when TermNode
        (v = leaf.call(node.term)) ? Tree(T).new(Op::Leaf, v) : nil
      when NotNode
        (c = build_node(node.child, leaf)) ? Tree(T).new(Op::Not, nil, [c]) : nil
      when AndNode, OrNode
        kids = [] of Tree(T)
        node.children.each { |child| (k = build_node(child, leaf)) && kids << k }
        return nil if kids.empty?
        return kids.first if kids.size == 1
        Tree(T).new(node.is_a?(AndNode) ? Op::And : Op::Or, nil, kids)
      end
    end
  end
end
