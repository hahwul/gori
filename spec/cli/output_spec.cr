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

# The compact size / latency cells, against the ONE rounding convention this repo states.
#
# `Tui::Fmt` documents it for the History column — "the unit is picked from the ROUNDED
# magnitude so a value just under a boundary rolls up to the next unit instead of the
# misleading '1024KB'" — and the CLI's copies picked theirs from the RAW quotient, so the
# headless listing of the same flow printed a quantity outside its own unit: 1,048,570 bytes
# as `1024.0kB` where the TUI says `1.0MB`, and 999,960 µs as `1000.0ms` against `1.0s`.
# `human_us` also stopped at seconds, so a 3.5-hour long poll read `12600.0s` in
# `gori run history` and `3.5h` one surface over.
describe "CLI::Output.human_size" do
  it "rolls up rather than naming a quantity outside its own unit" do
    Gori::CLI::Output.human_size(1_048_570_i64).should eq("1.0MB")
    Gori::CLI::Output.human_size(1_073_741_300_i64).should eq("1.0GB")
    # The two share the RULE, not the spelling: `Fmt` writes a whole number at and above 10,
    # so a size in the last half-cell of a unit is `1023.5kB` here and `1.0MB` there. This is
    # one input where they land on the same string, not a promise that they always do.
    Gori::CLI::Output.human_size(1_048_570_i64).should eq(Gori::Tui::Fmt.size(1_048_570_i64))
  end

  it "leaves everything below the boundary exactly as it was" do
    Gori::CLI::Output.human_size(0_i64).should eq("0B")
    Gori::CLI::Output.human_size(1023_i64).should eq("1023B")
    Gori::CLI::Output.human_size(1536_i64).should eq("1.5kB")
    Gori::CLI::Output.human_size(1_048_576_i64).should eq("1.0MB")
  end
end

describe "CLI::Output.human_us" do
  it "rolls up rather than naming a quantity outside its own unit" do
    Gori::CLI::Output.human_us(999_960_i64).should eq("1.0s")
  end

  it "carries the minute and hour tiers the History column has" do
    # A 3.5-hour long poll is a real captured row (scripts/seed_demo.cr's Act five).
    Gori::CLI::Output.human_us(12_600_000_000_i64).should eq("3.5h")
    Gori::CLI::Output.human_us(214_000_000_i64).should eq("3.6m")
    Gori::CLI::Output.human_us(90_000_000_i64).should eq("1.5m")
  end

  it "leaves everything below the boundary exactly as it was" do
    Gori::CLI::Output.human_us(999_i64).should eq("999µs")
    Gori::CLI::Output.human_us(43_000_i64).should eq("43.0ms")
    Gori::CLI::Output.human_us(1_200_000_i64).should eq("1.2s")
  end
end

describe Gori::CLI::Output do
  describe ".write_line" do
    it "terminates textual values with a newline when piped" do
      output = IO::Memory.new
      Gori::CLI::Output.write_line(output, "encoded token")
      output.to_s.should eq("encoded token\n")
    end
  end

  describe ".write_value" do
    it "does not add a line feed to a piped string value" do
      output = IO::Memory.new
      Gori::CLI::Output.write_value(output, "decoded text", false)
      output.to_slice.should eq("decoded text".to_slice)
    end

    it "keeps a terminal line break for string values" do
      output = IO::Memory.new
      Gori::CLI::Output.write_value(output, "decoded text", true)
      output.to_s.should eq("decoded text\n")
    end

    it "does not add a line feed to piped raw bytes" do
      bytes = Bytes[0x00_u8, 0xff_u8, 0x41_u8]
      output = IO::Memory.new
      Gori::CLI::Output.write_value(output, bytes, false)
      output.to_slice.should eq(bytes)
    end

    it "adds a terminal line break after raw bytes only when needed" do
      bytes = Bytes[0x41_u8]
      output = IO::Memory.new
      Gori::CLI::Output.write_value(output, bytes, true)
      output.to_slice.should eq(Bytes[0x41_u8, 0x0a_u8])

      terminated = Bytes[0x41_u8, 0x0a_u8]
      output = IO::Memory.new
      Gori::CLI::Output.write_value(output, terminated, true)
      output.to_slice.should eq(terminated)
    end
  end
end

# `--format json` is for scripts, and a JSON string carries NBSP / ZWSP / bidi controls
# safely — so these fields hold the captured value, not `term_safe`'s terminal badges. Only
# invalid UTF-8 is scrubbed, the one thing that would break the whole document.
describe "CLI::Output JSON emitters — no display projection" do
  it "keeps hidden Unicode in History `columns` keys and values" do
    row = Gori::Store::FlowRow.new(
      id: 1_i64, created_at: 0_i64, scheme: "https", method: "GET", host: "h", port: 443,
      target: "/", status: 200, size: 0_i64, state: Gori::Store::FlowState::Complete)
    columns = [{"a\u{a0}b", "/a\u{a0}b/\u{200b}"}, {"dup", "\u{202e}x"}, {"dup", "y\ez"}]
    json = JSON.parse(Gori::CLI::Output.flow_row_json(row, columns: columns))
    json["columns"]["a\u{a0}b"].as_s.should eq("/a\u{a0}b/\u{200b}")
    json["columns"]["dup"].as_a.map(&.as_s).should eq(["\u{202e}x", "y\ez"])
  end

  it "still scrubs invalid UTF-8 in a History column so the document parses" do
    row = Gori::Store::FlowRow.new(
      id: 1_i64, created_at: 0_i64, scheme: "https", method: "GET", host: "h", port: 443,
      target: "/", status: 200, size: 0_i64, state: Gori::Store::FlowState::Complete)
    bad = String.new(Bytes[0x68, 0xff, 0x69])
    doc = Gori::CLI::Output.flow_row_json(row, columns: [{bad, bad}])
    doc.valid_encoding?.should be_true
    JSON.parse(doc)["columns"]["h\u{fffd}i"].as_s.should eq("h\u{fffd}i")
  end

  it "keeps hidden Unicode in a flow's advisory lines" do
    row = Gori::Store::FlowRow.new(
      id: 1_i64, created_at: 0_i64, scheme: "https", method: "GET", host: "h", port: 443,
      target: "/", status: 200, size: 0_i64, state: Gori::Store::FlowState::Complete,
      advisory: "rule\u{a0}x skipped\tbody")
    json = JSON.parse(Gori::CLI::Output.flow_row_json(row))
    json["advisory"].as_a.map(&.as_s).should eq(["rule\u{a0}x skipped\tbody"])
  end

  it "keeps hidden Unicode in sitemap host, label, path and tag" do
    hosts = Gori::Sitemap.build([{"a\u{a0}.test", "GET", "/a\u{a0}b/\u{200b}"}])
    Gori::Sitemap.stamp_tags!(hosts, { {"a\u{a0}.test", "/a\u{a0}b"} => "memo\u{202e}" })
    hosts.each { |h| h.endpoints = Gori::Sitemap.endpoint_count(h) }
    doc = Gori::CLI::Output.sitemap_json(hosts)
    doc.should_not contain("⟨")
    host = JSON.parse(doc).as_a[0]
    host["host"].as_s.should eq("a\u{a0}.test")
    node = host["children"].as_a[0]
    node["label"].as_s.should eq("a\u{a0}b")
    node["path"].as_s.should eq("/a\u{a0}b")
    node["tag"].as_s.should eq("memo\u{202e}")
    node["children"].as_a[0]["path"].as_s.should eq("/a\u{a0}b/\u{200b}")
  end

  it "still scrubs invalid UTF-8 in the sitemap JSON" do
    bad = String.new(Bytes[0x2f, 0x78, 0xff])
    doc = Gori::CLI::Output.sitemap_json(Gori::Sitemap.build([{"h", "GET", bad}]))
    doc.valid_encoding?.should be_true
    JSON.parse(doc)
  end
end
