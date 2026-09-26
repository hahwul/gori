require "../../spec_helper"
require "json"

# `gori run sitemap params` — the CLI glue over `Gori::ParamInventory` (the inventory itself
# is spec/param_inventory_spec.cr). Pinned here: what the text/json builders print, and that
# a credential never reaches STDOUT unless the operator asked for it.

private alias SPI = Gori::ParamInventory

private def spi_row(name : String, *, location = Gori::Miner::Location::Query, samples = ["v"],
                    sensitive = false, reflected = false, truncated = false, host = "h.test",
                    path = "/a", count = 1) : SPI::Row
  SPI::Row.new(host, "GET", path, location, name, count, samples, truncated, 1_i64, 2_i64,
    reflected, reflected ? 2_i64 : nil, sensitive)
end

describe "gori run sitemap params — text" do
  it "groups rows under host and endpoint, marking reflected values" do
    out = Gori::CLI::Run.params_text([
      spi_row("q", samples: ["shoes", "hats"], reflected: true, count: 2),
      spi_row("id", path: "/b"),
    ], include_sensitive: false)
    lines = out.lines
    lines[0].should eq("h.test")
    lines[1].should eq("  GET /a")
    lines[2].should match(/^    query\s+q\s+2  reflected  shoes, hats$/)
    lines[3].should eq("  GET /b")
    lines[4].should match(/^    query\s+id\s+1\s+v$/)
  end

  it "masks a sensitive row unless --include-sensitive" do
    row = spi_row("sid", location: Gori::Miner::Location::Cookies, samples: ["s3cret"], sensitive: true)
    Gori::CLI::Run.params_text([row], include_sensitive: false).should_not contain("s3cret")
    Gori::CLI::Run.params_text([row], include_sensitive: false).should contain("[REDACTED]")
    Gori::CLI::Run.params_text([row], include_sensitive: true).should contain("s3cret")
  end

  # A captured name/value is bytes off the wire: an escape in it must not reach the terminal.
  it "neutralises control bytes in captured names and values" do
    out = Gori::CLI::Run.params_text([spi_row("a\e[31mb", samples: ["x\e]0;t\a"])], include_sensitive: false)
    out.should_not contain('\e')
    out.should_not contain('\a')
  end
end

describe "gori run sitemap params — json" do
  it "emits one object per row with the redaction stated" do
    report = SPI::Report.new([
      spi_row("q", reflected: true),
      spi_row("password", location: Gori::Miner::Location::Form, samples: ["hunter2"], sensitive: true),
    ], 2, false)
    arr = JSON.parse(Gori::CLI::Run.params_json(report, include_sensitive: false)).as_a
    arr.size.should eq(2)
    arr[0]["location"].should eq("query")
    arr[0]["reflected"].should be_true
    arr[0]["reflected_flow_id"].should eq(2)
    arr[1]["samples"].should eq(["[REDACTED]"])
    arr[1]["samples_redacted"].should be_true
    open = JSON.parse(Gori::CLI::Run.params_json(report, include_sensitive: true)).as_a
    open[1]["samples"].should eq(["hunter2"])
    open[1]["samples_redacted"].should be_false
  end

  it "is an empty array when nothing matched" do
    Gori::CLI::Run.params_json(SPI::Report.new([] of SPI::Row, 0, false), false).should eq("[]")
  end
end

describe "gori run sitemap — the params verb" do
  # `sitemap --project x params` reaches the tree with `params` as a positional; unless the
  # tree's reserved-verb guard names it, it becomes a QL free-text term and prints a tree
  # silently filtered to endpoints containing "params". `abort` cannot be driven from a
  # spec, so the guard's reserved list is read from the source it lives in.
  it "is on the tree's reserved-verb list" do
    src = File.read(File.join(__DIR__, "../../../src/gori/cli/run/sitemap.cr"))
    src.should match(/reserved_query_verb_error\(positional, "sitemap", \[[^\]]*"params"[^\]]*\]/)
  end
end

# JSON is for scripts: host/method/path keep NBSP/ZWSP/bidi as-is (a JSON string carries
# them safely), like `name` and `samples` beside them. Only invalid UTF-8 is scrubbed.
describe "gori run sitemap params — json keeps hidden Unicode" do
  it "emits host, method and path without terminal badges" do
    row = spi_row("q", host: "a\u{a0}.test", path: "/p\u{200b}\u{202e}")
    doc = Gori::CLI::Run.params_json(SPI::Report.new([row], 1, false), include_sensitive: false)
    doc.should_not contain("⟨")
    obj = JSON.parse(doc).as_a[0]
    obj["host"].as_s.should eq("a\u{a0}.test")
    obj["path"].as_s.should eq("/p\u{200b}\u{202e}")
  end

  it "still scrubs invalid UTF-8 so the document parses" do
    row = spi_row("q", path: String.new(Bytes[0x2f, 0xff]))
    doc = Gori::CLI::Run.params_json(SPI::Report.new([row], 1, false), include_sensitive: false)
    doc.valid_encoding?.should be_true
    JSON.parse(doc).as_a[0]["path"].as_s.should eq("/\u{fffd}")
  end
end
