require "../spec_helper"

include Gori::Tui

private def md(s : String) : Array(Highlight::Line)
  Highlight.markdown(s.split('\n'))
end

private def joined(line : Highlight::Line) : String
  line.map(&.text).join
end

describe "Highlight.markdown" do
  it "is strictly 1:1 — line count + each line's exact text preserved (editable/cursor-safe)" do
    src = [
      "# Title", "",
      "- item **bold** and `code`",
      "> a quote",
      "```", "**not parsed** in here", "```",
      "see [link](http://x) end",
      "snake_case_var stays plain",
      "1. ordered ~~strike~~",
    ]
    res = Highlight.markdown(src)
    res.size.should eq(src.size)
    src.each_with_index { |line, i| joined(res[i]).should eq(line) }
  end

  it "styles headings, bold, code, links — markers stay visible" do
    md("# H")[0].any?(&.attr.bold?).should be_true
    md("a **b** c")[0].any? { |sp| sp.text == "**b**" && sp.attr.bold? }.should be_true
    md("a `x` b")[0].any? { |sp| sp.text == "`x`" }.should be_true
    md("[t](u)")[0].any? { |sp| sp.text == "[t](u)" }.should be_true
  end

  it "keeps fenced code blocks as a single unparsed span across lines" do
    res = md("```\n**not bold**\n```")
    joined(res[1]).should eq("**not bold**")
    res[1].size.should eq(1) # not split into bold spans inside the fence
  end

  it "does NOT treat snake_case underscores as emphasis" do
    md("foo_bar_baz here")[0].size.should eq(1)
  end
end
