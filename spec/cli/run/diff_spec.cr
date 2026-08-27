require "../../spec_helper"
require "json"

# `gori run diff` — the CLI glue over `Gori::Diff`. The comparison itself is covered in
# spec/diff_spec.cr; what is pinned here is the argument surface an operator scripts
# against: which verdicts `--verdict` accepts, and that the three formats emit what a
# retest report / a pipeline actually consumes.

# Private CLI glue — reopen the module for bare-call wrappers (the whitebox trick the
# other CLI specs use).
module Gori::CLI::Run
  def self.parse_diff_verdicts_for_spec(spec : String) : Array(Gori::Diff::Verdict)
    parse_diff_verdicts(spec)
  end

  def self.diff_filter_for_spec(query : String?) : QL::Filter
    diff_filter(query)
  end
end

describe "gori run diff — --verdict" do
  it "accepts the five verdict names, in the order given, deduped" do
    Gori::CLI::Run.parse_diff_verdicts_for_spec("changed, added,changed").should eq(
      [Gori::Diff::Verdict::Changed, Gori::Diff::Verdict::Added])
  end

  it "accepts every name the report can emit" do
    # A verdict the report produces but the flag refuses would be a bucket no script could
    # ask for — so the two lists are pinned against each other rather than typed twice.
    all = Gori::Diff::Render::ORDER.map(&.label).join(",")
    Gori::CLI::Run.parse_diff_verdicts_for_spec(all).should eq(Gori::Diff::Render::ORDER)
  end
end

describe "gori run diff — --query" do
  it "passes a blank query through as no filter" do
    Gori::CLI::Run.diff_filter_for_spec(nil).should eq(Gori::QL::EMPTY)
    Gori::CLI::Run.diff_filter_for_spec("  ").should eq(Gori::QL::EMPTY)
  end

  it "compiles a real query to a real filter" do
    Gori::CLI::Run.diff_filter_for_spec("host:acme.test").should_not eq(Gori::QL::EMPTY)
  end
end

describe "gori run diff — --verdict reaches every format" do
  it "narrows json exactly as it narrows text and md" do
    # The flag says "only list these verdicts" and MCP's `verdicts` narrows the identical
    # payload; a machine surface that quietly ignored it would disagree with its own help.
    report = Gori::Diff::Report.new(
      Gori::Diff::Coverage.new("A", "a.db", 0_i64, 0, 0, nil, nil, false, [] of String, false),
      Gori::Diff::Coverage.new("B", "b.db", 0_i64, 0, 0, nil, nil, false, [] of String, false),
      [Gori::Diff::Row.new(Gori::Diff::Key.new("h", "GET", "/a"), Gori::Diff::Verdict::Added,
        nil, nil, [] of Gori::Diff::Change),
       Gori::Diff::Row.new(Gori::Diff::Key.new("h", "GET", "/b"), Gori::Diff::Verdict::Removed,
         nil, nil, [] of Gori::Diff::Change)],
      [] of Gori::Diff::IssueRetest)
    only_added = [Gori::Diff::Verdict::Added]
    j = JSON.parse(Gori::Diff::Render.json(report, verdicts: only_added))
    j["endpoints"].as_a.map(&.["path"].as_s).should eq(["/a"])
    # ...while the counts still cover every bucket, so a narrowing cannot read as "none".
    j["counts"]["removed"].as_i.should eq(1)
  end
end

describe "gori run diff — default listing" do
  it "lists every verdict but unchanged, matching the flagless default" do
    # `--unchanged` opts INTO the noisiest bucket; without it the listing is the findings.
    Gori::Diff::Render::LISTED.should_not contain(Gori::Diff::Verdict::Unchanged)
    Gori::Diff::Render::LISTED.size.should eq(Gori::Diff::Render::ORDER.size - 1)
  end
end
