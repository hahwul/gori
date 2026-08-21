require "./spec_helper"

private alias FS = Gori::FlowSource

describe Gori::FlowSource do
  describe "Kind" do
    it "gives every member a token and a label, with no member left to a fallback" do
      # The point of the exhaustive `case` in `#label`: a member added without a tag must be a
      # compile error rather than a row that renders as an existing source. This asserts the
      # OTHER half — that nothing is blank or duplicated — which a `case` cannot.
      tokens = FS::Kind.values.map(&.token)
      labels = FS::Kind.values.map(&.label)
      tokens.none?(&.empty?).should be_true
      labels.none?(&.empty?).should be_true
      tokens.uniq.size.should eq(tokens.size)
      labels.uniq.size.should eq(labels.size)
    end

    it "keeps every label inside the History SRC column's five cells" do
      # The column is fixed-width and `screen.text(..., width: 5)` would TRUNCATE a longer tag
      # into something that reads like a different source. Five is the width the cluster grants.
      FS::Kind.values.each(&.label.size.should(be <= 5))
    end

    it "parses a value by its token AND by the label the column prints" do
      # Both, because `Proto` gets this for free (its label IS its filter value) and this module
      # does not: someone who reads `RPTR` off the screen must be able to type `src:rptr`.
      FS::Kind.parse?("repeater").should eq(FS::Kind::Repeater)
      FS::Kind.parse?("rptr").should eq(FS::Kind::Repeater)
      FS::Kind.parse?("RPTR").should eq(FS::Kind::Repeater)
      FS::Kind.parse?("Discover").should eq(FS::Kind::Discover)
      FS::Kind.parse?("crawl").should eq(FS::Kind::Discover)
      FS::Kind.values.each do |k|
        FS::Kind.parse?(k.token).should eq(k)
        FS::Kind.parse?(k.label).should eq(k)
      end
    end

    it "answers nil for a spelling it does not know" do
      FS::Kind.parse?("browser").should be_nil
      FS::Kind.parse?("").should be_nil
      # `gori` is the QL UNION spelling, resolved by `QL.src_cond` before it ever gets here —
      # it is not a Kind, and answering one would make `src:gori` match a single source.
      FS::Kind.parse?("gori").should be_nil
    end

    it "splits provenance three ways, not two" do
      # Proxy is the client's traffic and Import is somebody else's capture; only what gori put
      # on a wire is `sent_by_gori?`. Folding Import into either answers "is this evidence about
      # the target?" wrongly, and `src:gori` compiles straight off this predicate.
      FS::Kind::Proxy.sent_by_gori?.should be_false
      FS::Kind::Import.sent_by_gori?.should be_false
      [FS::Kind::Repeater, FS::Kind::Fuzzer, FS::Kind::Miner, FS::Kind::Sequencer,
       FS::Kind::Discover, FS::Kind::Authorize, FS::Kind::Probe].each do |k|
        k.sent_by_gori?.should be_true
      end
    end

    it "lists its tokens in declaration order for the completion pool" do
      FS::Kind.tokens.should eq(FS::Kind.values.map(&.token))
      FS::Kind.tokens.first.should eq("proxy")
    end
  end

  describe "Surface" do
    it "round-trips every member through its token" do
      FS::Surface.values.each { |s| FS::Surface.parse?(s.token).should eq(s) }
      FS::Surface.parse?("MCP").should eq(FS::Surface::Mcp)
      FS::Surface.parse?("browser").should be_nil
    end
  end
end
