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

  it "treats NOT on a single term as identical to the - prefix" do
    parse("NOT host:cdn").should eq("-host:cdn")
    parse("-host:cdn").should eq("-host:cdn")
    parse("NOT NOT host:cdn").should eq("host:cdn")
  end

  it "wraps NOT around a group (which - cannot express)" do
    parse("NOT (host:cdn OR host:static)").should eq("(not (or host:cdn host:static))")
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

  it "negates only with something after the dash" do
    parse("-host:a").should eq("-host:a")
    parse("-").should eq("-") # a lone dash is a word, not a negation
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
end
