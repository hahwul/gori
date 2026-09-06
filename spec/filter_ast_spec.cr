require "./spec_helper"

# Compact s-expression of a parsed tree, so a test reads as the shape it asserts.
private def sexp(node : Gori::FilterAst::Node?) : String
  case node
  when Gori::FilterAst::TermNode
    t = node.term
    "#{t.negate? ? "-" : ""}#{t.text}"
  when Gori::FilterAst::AndNode then "(and #{node.children.map { |c| sexp(c) }.join(" ")})"
  when Gori::FilterAst::OrNode  then "(or #{node.children.map { |c| sexp(c) }.join(" ")})"
  when Gori::FilterAst::NotNode then "(not #{sexp(node.child)})"
  else                               "nil"
  end
end

private def parse(query : String) : String
  sexp(Gori::FilterAst.parse(query))
end

# How many NOT-wrapped groups a tree holds (a negated TERM carries its flag instead).
private def not_nodes(node : Gori::FilterAst::Node?) : Int32
  case node
  when Gori::FilterAst::NotNode then 1 + not_nodes(node.child)
  when Gori::FilterAst::AndNode then node.children.sum { |c| not_nodes(c) }
  when Gori::FilterAst::OrNode  then node.children.sum { |c| not_nodes(c) }
  else                               0
  end
end

describe Gori::FilterAst do
  it "ANDs adjacent terms and accepts the AND keyword for the same thing" do
    parse("host:acme status:>=500").should eq(%((and host:acme status:>=500)))
    parse("host:a AND host:b").should eq("(and host:a host:b)")
  end

  it "binds AND tighter than OR" do
    parse("a b OR c d").should eq("(or (and a b) (and c d))")
    parse("a OR b AND c").should eq("(or a (and b c))")
  end

  it "groups with parentheses" do
    parse("(host:a OR host:b) -method:GET").should eq("(and (or host:a host:b) -method:GET)")
    parse("((a OR b) c) OR d").should eq("(or (and (or a b) c) d)")
  end

  # `seps` already stops a bar painting an OPERATOR it does not run; `known` is the same idea one
  # level down for the field NAME. Without it `hsot:acme` renders in the same confident colour as
  # `host:acme`, while the backend free-texts the whole token and matches nothing real — the one
  # visible signal saying the opposite of the truth.
  describe ".spans with a known-field predicate" do
    private_known = ->(f : String, _op : Char) { f == "host" }

    it "marks a field the backend does not implement, and its value with it" do
      kinds = Gori::FilterAst.spans("hsot:acme", ":~", private_known).map { |s| {s.size, s.kind} }
      kinds.should eq([{5, Gori::FilterAst::SpanKind::UnknownField},
                       {4, Gori::FilterAst::SpanKind::Plain}])

      # The VALUE goes plain too: the backend free-texts `hsot:acme` whole, so painting `acme`
      # as a field's value would claim a match nobody performs.
      real = Gori::FilterAst.spans("host:acme", ":~", private_known).map { |s| {s.size, s.kind} }
      real.should eq([{5, Gori::FilterAst::SpanKind::Field},
                      {4, Gori::FilterAst::SpanKind::Value}])
    end

    it "matches the name case-insensitively, the way the compilers do" do
      # `split_field` downcases before dispatching, so `HOST:x` compiles and must not be a typo.
      Gori::FilterAst.spans("HOST:x", ":~", private_known).first.kind
        .should eq(Gori::FilterAst::SpanKind::Field)
    end

    it "keeps the negation and the grouping painted as operators regardless" do
      kinds = Gori::FilterAst.spans("-hsot:x", ":~", private_known).map(&.kind)
      kinds.first.should eq(Gori::FilterAst::SpanKind::Operator) # the `-`
      kinds[1].should eq(Gori::FilterAst::SpanKind::UnknownField)
    end

    it "leaves every existing caller alone when no predicate is given" do
      # Opt-in: a backend states its vocabulary, it is never assumed for it.
      Gori::FilterAst.spans("hsot:acme").map(&.kind)
        .should eq([Gori::FilterAst::SpanKind::Field, Gori::FilterAst::SpanKind::Value])
    end

    it "asks the predicate per separator, so a field with no `~` form is unknown under `~`" do
      # QL has `status:` and no `status~`; the term is DROPPED, and painting it as a field
      # claimed a regex match nobody performs.
      by_op = ->(f : String, op : Char) { f == "status" ? op == ':' : f == "host" }
      Gori::FilterAst.spans("status:5xx", ":~", by_op).first.kind.should eq(Gori::FilterAst::SpanKind::Field)
      Gori::FilterAst.spans("status~5..", ":~", by_op).map(&.kind)
        .should eq([Gori::FilterAst::SpanKind::UnknownField, Gori::FilterAst::SpanKind::Plain])
      Gori::FilterAst.spans("host~^api", ":~", by_op).first.kind.should eq(Gori::FilterAst::SpanKind::Field)
    end

    it "paints a fully-quoted field token as the field the parser runs it as" do
      # The grammar strips quotes BEFORE any backend splits a token, so `"host:a"` compiles
      # exactly as `host:a` (QL's spec pins that quoting is not an escape). The highlighter used
      # to read the leading quote as "this is a phrase" and paint the one token plain — the
      # colour said free text while the parser ran a field.
      q = %("host:a")
      Gori::FilterAst.spans(q, ":~", private_known).map { |s| {s.kind, q[s.start, s.size]} }.should eq([
        {Gori::FilterAst::SpanKind::Quote, "\""}, {Gori::FilterAst::SpanKind::Field, "host:"},
        {Gori::FilterAst::SpanKind::Value, "a"}, {Gori::FilterAst::SpanKind::Quote, "\""},
      ])
      # ...and it is the same reading the parser gives.
      Gori::FilterAst.terms(Gori::FilterAst.parse(q)).map(&.text).should eq(["host:a"])
      # An unknown name inside quotes paints unknown, as it does unquoted.
      Gori::FilterAst.spans(%("hsot:a"), ":~", private_known).map(&.kind)
        .should eq([Gori::FilterAst::SpanKind::Quote, Gori::FilterAst::SpanKind::UnknownField,
                    Gori::FilterAst::SpanKind::Plain, Gori::FilterAst::SpanKind::Quote])
      # A quoted phrase with no separator is still plain text.
      Gori::FilterAst.spans(%("two words"), ":~", private_known).map(&.kind)
        .should eq([Gori::FilterAst::SpanKind::Quote, Gori::FilterAst::SpanKind::Plain, Gori::FilterAst::SpanKind::Quote])
    end
  end

  it "treats NOT on a single term as identical to the - prefix" do
    parse("NOT host:cdn").should eq("-host:cdn")
    parse("-host:cdn").should eq("-host:cdn")
    parse("NOT NOT host:cdn").should eq("host:cdn")
  end

  it "wraps NOT around a group" do
    parse("NOT (host:cdn OR host:static)").should eq("(not (or host:cdn host:static))")
  end

  it "reads a negation marker FUSED to the opening paren — `-(` and `NOT(` — as NOT (" do
    # Both are the natural spellings for anyone who has written a boolean expression, and
    # `-term` == `NOT term` everywhere else made `-(` look supported. It was not: the `(` was not
    # at the start of its chunk, so `-(host:a OR host:b)` lexed as the negated free-text word
    # `(host:a` OR'd with the field `host:b)` — plausible-looking on the list, and the opposite of
    # what was typed.
    parse("-(host:cdn OR host:static)").should eq("(not (or host:cdn host:static))")
    parse("NOT(host:cdn OR host:static)").should eq("(not (or host:cdn host:static))")
    parse("x -(a b)").should eq("(and x (not (and a b)))")
    parse("-((a))").should eq("-a") # a lone term inside still flips its own flag
    parse("NOT(a) b").should eq("(and -a b)")
    parse("(NOT(a))").should eq("-a")
    # Forgiving about the half-typed forms, like every other structure.
    parse("-(").should eq("nil")
    parse("-()").should eq("nil")
    parse("NOT()").should eq("nil")
    parse("-(ho").should eq("-ho") # a lone term inside flips its own flag
    # The marker must be UNQUOTED, exactly like `-x` and the `NOT` keyword.
    parse("\"-(a\"").should eq("-(a")
    parse("-\"(a\"").should eq("-(a")
    parse("\"NOT(a\"").should eq("NOT(a")
    # Lowercase is not the keyword, here as anywhere.
    parse("not(a)").should eq("not(a)")
  end

  it "paints the fused marker as an operator and its paren as a paren" do
    kinds = Gori::FilterAst.spans("-(a OR b)").map { |s| {s.kind, "-(a OR b)"[s.start, s.size]} }
    kinds.should eq([
      {Gori::FilterAst::SpanKind::Operator, "-"}, {Gori::FilterAst::SpanKind::Paren, "("},
      {Gori::FilterAst::SpanKind::Plain, "a"}, {Gori::FilterAst::SpanKind::Operator, "OR"},
      {Gori::FilterAst::SpanKind::Plain, "b"}, {Gori::FilterAst::SpanKind::Paren, ")"},
    ])
    Gori::FilterAst.spans("NOT(a)").first.should eq(Gori::FilterAst::Span.new(0, 3, Gori::FilterAst::SpanKind::Operator))
  end

  it "carries the fused marker in the completion prefix, so `-(ho` completes to `-(host:`" do
    Gori::FilterAst.token_at("-(ho", 4).should eq(Gori::FilterAst::Cursor.new("-(", "ho", 0, 4))
    Gori::FilterAst.token_at("NOT(ho", 6).should eq(Gori::FilterAst::Cursor.new("NOT(", "ho", 0, 6))
    Gori::FilterAst.token_at("(-(ho", 5).should eq(Gori::FilterAst::Cursor.new("(-(", "ho", 0, 5))
    # A lone `-` is still a word, and `-x` still peels only the dash.
    Gori::FilterAst.token_at("-", 1).should eq(Gori::FilterAst::Cursor.new("", "-", 0, 1))
    Gori::FilterAst.token_at("-ho", 3).should eq(Gori::FilterAst::Cursor.new("-", "ho", 0, 3))
  end

  it "keeps parentheses inside a value literal, so URL paths still parse" do
    # The whole point of the boundary rule: `(` only opens at the start of a chunk and
    # `)` only closes at the end AND only while a group is open. Regression guard for
    # every `path:/a(b)`-shaped query that worked before the grammar grew parens.
    parse("path:/a(b)").should eq("path:/a(b)")
    parse("path:/a(b) OR host:x").should eq("(or path:/a(b) host:x)")
    parse("(path:/a(b))").should eq("path:/a(b)")  # groups, inner parens survive
    parse("host:a)").should eq("host:a)")          # stray close at depth 0
    parse(%(path:"/a(b)")).should eq("path:/a(b)") # quoting always forces literal
  end

  it "recognises keywords only UPPERCASE and unquoted" do
    parse("a or b and c").should eq("(and a or b and c)") # lowercase = free text
    parse(%("OR")).should eq("OR")
    parse(%(host:"AND")).should eq("host:AND")
  end

  it "keeps spaces inside a quoted value" do
    parse(%(host:"my host")).should eq("host:my host")
    parse(%("two words")).should eq("two words")
    parse(%(a "b c" d)).should eq("(and a b c d)")
  end

  it "stays forgiving about half-typed structure (it re-parses per keystroke)" do
    parse("(host:a").should eq("host:a") # unclosed group closes at end of input
    parse("a OR").should eq("a")         # dangling operator
    parse("a AND").should eq("a")
    parse("").should eq("nil")
    parse("   ").should eq("nil")
    parse("()").should eq("nil")
  end

  it "steps over an empty group instead of dropping the rest of the chain" do
    # An empty group contributes nothing, but it must not swallow its neighbours:
    # everything after it used to vanish, and because the lexemes never reached a
    # term the diagnostics reported the query as clean while it matched far more.
    parse("host:a () status:200").should eq("(and host:a status:200)")
    parse("a (AND) b").should eq("(and a b)")
    parse(%(a ("") b)).should eq("(and a b)")
    parse("host:a NOT () status:200").should eq("(and host:a status:200)")
    parse("a () () b").should eq("(and a b)")
  end

  it "negates only with something after the dash" do
    parse("-host:a").should eq("-host:a")
    parse("-").should eq("-")   # a lone dash is a word, not a negation
    parse(%(-")).should eq("-") # ...and a dash followed only by a quote mark is too
  end

  it "treats a QUOTED leading dash as literal text, like a quoted keyword" do
    # Quoting forces a literal, and that has to hold for `-` exactly as it does for
    # AND/OR/NOT — otherwise there is no way to search for a token that starts with a
    # dash. `sexp` renders both of these as "-a", so assert the parts.
    quoted = Gori::FilterAst.terms(Gori::FilterAst.parse(%("-a"))).first
    {quoted.text, quoted.negate?}.should eq({"-a", false})

    # The test is the quoting of the DASH, not of the chunk — a quoted VALUE on a
    # negated field still negates.
    bare = Gori::FilterAst.terms(Gori::FilterAst.parse(%(-"a"))).first
    {bare.text, bare.negate?}.should eq({"a", true})

    field = Gori::FilterAst.terms(Gori::FilterAst.parse(%(-host:"my host"))).first
    {field.text, field.negate?}.should eq({"host:my host", true})
  end

  describe "Term" do
    it "carries the source as typed alongside the normalised text" do
      # `text` keeps the field prefix — only the `-` and the quote marks come off; the
      # backends do their own field/value split.
      terms = Gori::FilterAst.terms(Gori::FilterAst.parse(%(-host:"my host" plain)))
      terms.map(&.text).should eq(["host:my host", "plain"])
      terms.map(&.source).should eq([%(-host:"my host"), "plain"])
      terms.map(&.negate?).should eq([true, false])
    end

    it "collects leaves left to right through every combinator" do
      node = Gori::FilterAst.parse("(a OR b) NOT (c AND d)")
      Gori::FilterAst.terms(node).map(&.text).should eq(["a", "b", "c", "d"])
    end
  end

  describe ".build" do
    it "folds into a backend tree, dropping the leaves the backend rejects" do
      # `leaf` returning nil DROPS a term; a combinator with no survivors drops too.
      node = Gori::FilterAst.parse("keep drop OR drop")
      tree = Gori::FilterAst.build(node) { |t| t.text == "keep" ? t.text : nil }
      tree.should_not be_nil
      tree.not_nil!.op.should eq(Gori::FilterAst::Op::Leaf)
      tree.not_nil!.leaf.should eq("keep")
    end

    it "folds to nil when every leaf is dropped" do
      node = Gori::FilterAst.parse("a b OR c")
      Gori::FilterAst.build(node) { |_| nil }.should be_nil
    end

    it "preserves the combinator shape for surviving leaves" do
      node = Gori::FilterAst.parse("a b OR c")
      tree = Gori::FilterAst.build(node) { |t| t.text }.not_nil!
      tree.op.should eq(Gori::FilterAst::Op::Or)
      tree.children.map(&.op).should eq([Gori::FilterAst::Op::And, Gori::FilterAst::Op::Leaf])
      tree.children[0].children.map(&.leaf).should eq(["a", "b"])
    end
  end

  describe ".partition" do
    # For a surface owning a field the shared backend knows nothing about (Sitemap's
    # `tag:`, which filters the built tree, not the rows). Cutting from the same lexer is
    # what gives that hand-rolled field the grammar's quoting and negation.
    it "cuts matching terms out and hands back the residual" do
      taken, residual = Gori::FilterAst.partition("host:a tag:x status:200") { |t| t.text.starts_with?("tag:") }
      taken.map(&.text).should eq(["tag:x"])
      residual.should eq("host:a status:200")
    end

    it "keeps a quoted value whole" do
      taken, residual = Gori::FilterAst.partition(%(tag:"my flow" host:a)) { |t| t.text.starts_with?("tag:") }
      taken.map(&.text).should eq(["tag:my flow"]) # not torn at the space
      residual.should eq("host:a")
    end

    it "carries a NOT keyword onto the term it negates, leaving no dangling operator" do
      # NOT desugars at PARSE time, so a lexeme-level scan would miss it and strand the
      # bare `NOT` in the residual — where it means the opposite of what was asked.
      taken, residual = Gori::FilterAst.partition("NOT tag:done") { |t| t.text.starts_with?("tag:") }
      taken.map(&.negate?).should eq([true])
      residual.should eq("")
    end

    it "treats -tag:x and NOT tag:x identically" do
      dash, _ = Gori::FilterAst.partition("-tag:x") { |t| t.text.starts_with?("tag:") }
      word, _ = Gori::FilterAst.partition("NOT tag:x") { |t| t.text.starts_with?("tag:") }
      dash.map { |t| {t.text, t.negate?} }.should eq(word.map { |t| {t.text, t.negate?} })
    end

    it "leaves a NOT that does not precede a taken term alone" do
      taken, residual = Gori::FilterAst.partition("NOT host:a tag:x") { |t| t.text.starts_with?("tag:") }
      taken.map(&.negate?).should eq([false])
      residual.should eq("NOT host:a")
    end

    it "carries a NOT before a parenthesised group onto every taken term inside" do
      # LParen has term==nil, so the bare-term NOT branch used to miss and take tag:a
      # unnegated while residual `NOT ( )` folded away — Sitemap `NOT (tag:done)` then
      # showed ONLY the tagged nodes. Polarity must ride into the group.
      taken, residual = Gori::FilterAst.partition("NOT (tag:a) b") { |t| t.text.starts_with?("tag:") }
      taken.map { |t| {t.text, t.negate?} }.should eq([{"tag:a", true}])
      # Group shells and non-matching words stay; empty-group residue is fine (QL folds it).
      residual.should contain("(")
      residual.should contain(")")
      residual.should contain("b")
      residual.includes?("tag:a").should be_false

      both, _ = Gori::FilterAst.partition("NOT (tag:a OR tag:b)") { |t| t.text.starts_with?("tag:") }
      both.map { |t| {t.text, t.negate?} }.should eq([{"tag:a", true}, {"tag:b", true}])

      # Even run cancels; dash inside XORs with the outer run.
      even, _ = Gori::FilterAst.partition("NOT NOT (tag:x)") { |t| t.text.starts_with?("tag:") }
      even.map(&.negate?).should eq([false])
      dash, _ = Gori::FilterAst.partition("NOT (-tag:x)") { |t| t.text.starts_with?("tag:") }
      dash.map(&.negate?).should eq([false])
    end

    it "keeps the NOT for a group made ENTIRELY of the other backend's terms" do
      # A NOT-group with no OWNED (tag:) term used to be decomposed anyway: the inner terms
      # went to the residual and the leading NOT was DROPPED, so Sitemap's residual for
      # `NOT (host:evil)` came back as `( host:evil )` and QL then SHOWED only evil — the
      # negation silently inverted. A term-less group can't feed `taken`, so keep it verbatim.
      taken, residual = Gori::FilterAst.partition("NOT (host:evil)") { |t| t.text.starts_with?("tag:") }
      taken.should be_empty
      residual.should eq("NOT (host:evil)")

      # The module's own documented example, all-residual for a tag: backend.
      _, res2 = Gori::FilterAst.partition("NOT (host:cdn OR host:static)") { |t| t.text.starts_with?("tag:") }
      res2.should eq("NOT (host:cdn OR host:static)")

      # A tag term alongside still splits out; the residual NOT-group keeps its negation.
      tk, res3 = Gori::FilterAst.partition("tag:done NOT (host:evil)") { |t| t.text.starts_with?("tag:") }
      tk.map(&.text).should eq(["tag:done"])
      res3.should eq("NOT (host:evil)")
    end

    it "makes NOT tag:x and -tag:x identical INSIDE a group (the grammar's core equivalence)" do
      # An inner NOT keyword before an owned term used to fall into the residual, so the term
      # took only the OUTER run's polarity: `NOT (NOT tag:a)` excluded what `NOT (-tag:a)`
      # included. Inner and dash negation must compose the same way.
      %w(a b).each do |x|
        {"NOT (NOT tag:#{x})", "NOT (-tag:#{x})"}.tap do |kw, dash|
          kwp = Gori::FilterAst.partition(kw) { |t| t.text.starts_with?("tag:") }[0].map(&.negate?)
          dp = Gori::FilterAst.partition(dash) { |t| t.text.starts_with?("tag:") }[0].map(&.negate?)
          kwp.should eq(dp)
        end
      end
      # NOT (NOT tag:a) is a double negation → positive.
      Gori::FilterAst.partition("NOT (NOT tag:a)") { |t| t.text.starts_with?("tag:") }[0]
        .map(&.negate?).should eq([false])
      # NOT (tag:a NOT tag:b): outer negates a, inner+outer cancel on b.
      Gori::FilterAst.partition("NOT (tag:a NOT tag:b)") { |t| t.text.starts_with?("tag:") }[0]
        .map { |t| {t.text, t.negate?} }.should eq([{"tag:a", true}, {"tag:b", false}])
    end
  end

  describe ".spans" do
    it "only treats `~` as a field separator for backends that implement it" do
      # QL has a regex operator; Issues/Probe/Intercept/Subtab do not and free-text the
      # whole token. Painting `title~admin` as field+value there would promise a match
      # that never happens.
      regex_ok = Gori::FilterAst.spans("title~admin", Gori::FilterAst::SEPS_FIELD_REGEX)
      regex_ok.map(&.kind).should eq([Gori::FilterAst::SpanKind::Field, Gori::FilterAst::SpanKind::Value])

      colon_only = Gori::FilterAst.spans("title~admin", Gori::FilterAst::SEPS_FIELD)
      colon_only.map(&.kind).should eq([Gori::FilterAst::SpanKind::Plain])

      # `:` still splits for everyone.
      both = Gori::FilterAst.spans("title:admin", Gori::FilterAst::SEPS_FIELD)
      both.map(&.kind).should eq([Gori::FilterAst::SpanKind::Field, Gori::FilterAst::SpanKind::Value])
    end

    # The promise of the highlighter is that colour is a truthful preview of the parse.
    # Negation is the one place both sides could compute the answer separately, so pin
    # the agreement rather than a hand-written span list per query. (The `NOT` KEYWORD
    # is excluded: it is its own lexeme, painted straight off `Tok::Not`, so it has no
    # second derivation to drift from — only the `-` prefix ever did.)
    it "paints a dash operator exactly when the parser negated that term (or that group)" do
      [
        "-host:a", "-", %(-"), %(-""), %("-a"), %(-"a"), %(-host:"my host"),
        "a -b", "-(a OR b)", "(-a OR -b)", "--", "a-b", "path:/a-b", "-((a))", "-(a) -(b c)", "\"-(a\"",
      ].each do |query|
        dashes = Gori::FilterAst.spans(query).count do |span|
          span.kind.operator? && query[span.start, span.size] == "-"
        end
        tree = Gori::FilterAst.parse(query)
        # A `-(` fused to a group becomes a NotNode (or flips the lone term inside), so count both.
        negated = Gori::FilterAst.terms(tree).count(&.negate?) + not_nodes(tree)
        dashes.should eq(negated), "#{query.inspect}: #{dashes} dash spans vs #{negated} negations"
      end
    end
  end

  # Regression for the recursive-descent depth guard (FilterAst::MAX_PARSE_DEPTH). Filter
  # parsing is reached from History QL, Probe, Sitemap, Issues, the TUI filter bar and MCP;
  # the parse_or→parse_and→parse_unary→parse_primary descent had no nesting cap, so a fuzzed
  # or hostile `((((…))))` / `NOT NOT NOT …` thousands deep recursed one native stack frame
  # per level and SIGSEGV'd the process. The guard must not change any normal parse.
  describe "deep nesting (recursion depth guard)" do
    it "does not overflow the stack on thousands of nested parentheses" do
      q = "#{"(" * 8000}host:evil#{")" * 8000}"
      # The crash was here (unbounded recursion). Past the cap the descent degrades like the
      # existing empty-`()` handling and still recovers the real term rather than crashing.
      Gori::FilterAst.terms(Gori::FilterAst.parse(q)).map(&.text).should contain("host:evil")
    end

    it "does not overflow the stack on a very long NOT chain" do
      Gori::FilterAst.parse("#{"NOT " * 8000}host:x").should_not be_nil
    end

    # The cap's contract is that an over-deep parse degrades FORGIVINGLY. It did for parens,
    # but a NOT chain was cut in its MIDDLE: `parse_unary` recursed once per keyword, returned
    # nil at the cap having consumed one `NOT` per level, `parse_and` re-descended on the rest,
    # and the count that happened to SURVIVE decided polarity. So one keyword past the cap
    # returned the exact COMPLEMENT of the query — silently, exit 0, "no flows match". On a
    # filter that is worse than an error: it hides the rows the operator was looking for.
    it "keeps NOT-chain polarity on both sides of the depth cap" do
      cap = Gori::FilterAst::MAX_PARSE_DEPTH
      {2, 4, cap, cap + 1, cap + 2, 400, 401, 8000, 8001}.each do |n|
        got = parse("#{"NOT " * n}host:x")
        want = n.even? ? "host:x" : "-host:x"
        got.should eq(want), "NOT x#{n} parsed as #{got}, expected #{want}"
      end
    end

    it "keeps NOT-chain polarity over a GROUP past the cap too" do
      cap = Gori::FilterAst::MAX_PARSE_DEPTH
      parse("#{"NOT " * (cap + 1)}(host:a OR host:b)").should eq("(not (or host:a host:b))")
      parse("#{"NOT " * (cap + 2)}(host:a OR host:b)").should eq("(or host:a host:b)")
    end

    it "parses normal shallow nesting exactly as before the guard" do
      # A handful of levels is far under the cap, so these stay byte-for-byte unchanged.
      parse("((a OR b) c) OR d").should eq("(or (and (or a b) c) d)")
      parse("NOT (host:cdn OR host:static)").should eq("(not (or host:cdn host:static))")
      parse("(host:a OR host:b) -method:GET").should eq("(and (or host:a host:b) -method:GET)")
    end
  end
end
