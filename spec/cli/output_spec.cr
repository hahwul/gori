require "../spec_helper"

# Column padding in the `gori run` listings, measured in TERMINAL CELLS.
#
# `String#ljust` counts CODEPOINTS, so every listing that padded an operator-typed name with
# it under-padded a CJK or emoji cell by one column per wide character and stepped every
# column right of it out of line — on exactly the rows a Korean or Japanese engagement reads
# all day. The TUI's own History list has never had the defect (it draws through
# `Screen.display_width`), so this was a surface divergence rather than a missing feature:
# `spec/cli/settings_import_spec.cr` pins the same property for `gori settings import`, which
# is where the measure was first corrected.
#
# The examples below assert the DRAWN column of the field after the padded one, never the
# character index — a character index is equal in both rows even when the bug is present.
private def cells(s : String) : Int32
  Gori::Tui::Screen.display_width(s)
end

# The drawn column `needle` starts at in `row`.
private def column_of(row : String, needle : String) : Int32
  idx = row.index(needle)
  idx.should_not be_nil
  cells(row[0, idx.not_nil!])
end

describe "CLI::Output.pad" do
  it "pads to a TERMINAL-CELL width, not a codepoint count" do
    Gori::CLI::Output.cell_width("한글").should eq(4)
    Gori::CLI::Output.pad("한글", 6).should eq("한글  ")
    Gori::CLI::Output.pad("abcd", 6).should eq("abcd  ")
  end

  it "never pads past the column when the value already fills it" do
    Gori::CLI::Output.pad("한글 호스트", 4).should eq("한글 호스트")
  end
end

describe "CLI::Output.pad_cell" do
  it "keeps the one-space separator for a value already AT the column width" do
    # The existing guarantee: an `OPTIONS` in a 7-column method cell still gets its gap.
    Gori::CLI::Output.pad_cell("OPTIONS", 7).should eq("OPTIONS ")
  end

  it "measures the value in cells, so a wide one is not padded as if it were narrow" do
    # "주문" is 2 codepoints and 4 cells: the codepoint measure saw 2 < 4 and padded to a
    # 6-cell run inside a 4-cell column.
    cells(Gori::CLI::Output.pad_cell("주문", 4)).should eq(5)
  end
end

describe "gori run views — the name column" do
  it "lines the query column up when a view name carries wide characters" do
    wide = Gori::SavedViews::View.new("1", "한글 호스트", "host:a", "project")
    plain = Gori::SavedViews::View.new("2", "webdav", "host:b", "project")
    w = Gori::CLI::Run.view_name_width([wide, plain])
    w.should eq(11) # 한글(4) + space + 호스트(6)
    column_of(Gori::CLI::Run.view_row(wide, nil, w), "host:a")
      .should eq(column_of(Gori::CLI::Run.view_row(plain, nil, w), "host:b"))
  end
end

describe "gori run session — the slot column" do
  it "lines the summary up when a slot name carries wide characters" do
    wide = Gori::SessionSlot.new("관리자", set_headers: [{"X-A", "1"}])
    plain = Gori::SessionSlot.new("admin", set_headers: [{"X-A", "1"}])
    column_of(Gori::CLI::Run.session_slot_row(wide, false), "sets")
      .should eq(column_of(Gori::CLI::Run.session_slot_row(plain, false), "sets"))
  end
end

describe "gori run colormarker — the colour column" do
  it "measures a custom colour name in cells" do
    rules = [color_rule(color: "형광"), color_rule(color: "red")]
    Gori::CLI::Run.colormarker_color_width(rules).should eq(6)
  end

  it "lines the condition up when a custom colour name carries wide characters" do
    wide = color_rule(color: "형광", filter: "host:a")
    plain = color_rule(color: "red", filter: "host:b")
    w = Gori::CLI::Run.colormarker_color_width([wide, plain])
    column_of(Gori::CLI::Run.colormarker_rule_row(wide, w), "host:a")
      .should eq(column_of(Gori::CLI::Run.colormarker_rule_row(plain, w), "host:b"))
  end
end

private def color_rule(color : String, filter : String = "host:x") : Gori::Store::ColorRule
  Gori::Store::ColorRule.new(1_i64, true, filter, color)
end
