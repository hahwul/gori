require "../spec_helper"
require "file_utils"

# Issue #566 — built-in payload preset sets (sqli/xss/traversal/format-string/
# bad-strings/command-injection): each loads, is non-empty and de-duped; a preset
# drives a run as a PayloadSource and composes with a second set; and an optional
# user file merges in built-in-first, order-preserving, de-duped.
private alias F = Gori::Fuzz

# The builder takes the Outbound as an argument; this spec is not about the scope gate,
# so use one ungated decision (mirrors spec/fuzz/plan_spec.cr).
private def ungated : Gori::Outbound
  Gori::Outbound.waived(nil, Gori::Outbound::Reason::NoProject)
end

describe Gori::Fuzz::Presets do
  it "enumerates every documented preset name, sorted and stable" do
    F::Presets.names.should eq(
      ["bad-strings", "command-injection", "format-string", "sqli", "traversal", "xss"]
    )
  end

  it "loads each preset non-empty and de-duplicated" do
    F::Presets.names.each do |name|
      values = F::Presets.load(name)
      values.should_not be_empty
      values.uniq.size.should eq(values.size)          # already de-duped
      values.none?(&.empty?).should be_true            # blanks dropped
      values.none?(&.starts_with?('#')).should be_true # comments dropped
    end
  end

  it "case- and space-normalizes the preset name" do
    F::Presets.load("  SQLI  ").should eq(F::Presets.load("sqli"))
    F::Presets.exists?("Command-Injection").should be_true
    F::Presets.exists?("nope").should be_false
  end

  it "raises a clean Gori::Error for an unknown preset (listing the alternatives)" do
    expect_raises(Gori::Error, /unknown payload preset.*available:.*sqli/) do
      F::Presets.load("sqlmap")
    end
  end

  it "caches the parsed built-in list (same object across calls)" do
    F::Presets.builtin("xss").should be(F::Presets.builtin("xss"))
  end

  describe "user-file merge (extensibility)" do
    it "appends the user file built-in-first, order-preserving, de-duped" do
      builtin = F::Presets.load("sqli")
      # One line that duplicates an existing built-in payload, then one brand-new line.
      # (The merge file is read verbatim — see the byte-exact `-w` spec below — so no
      # comment/blank lines here; the dedup + order contract is what this covers.)
      path = File.tempname("gori-preset-merge")
      File.write(path, "#{builtin.first}\nCUSTOM-PAYLOAD-#{Random::Secure.hex(3)}\n")
      begin
        merged = F::Presets.load("sqli", path)
        # Built-in first, in the original order (the merge is a suffix).
        merged[0, builtin.size].should eq(builtin)
        # The duplicate of an existing payload did NOT re-appear.
        merged.uniq.size.should eq(merged.size)
        merged.size.should eq(builtin.size + 1) # only the one genuinely-new line
        merged.last.should start_with("CUSTOM-PAYLOAD-")
      ensure
        File.delete(path) rescue nil
      end
    end

    # H1 FINDING 1 (PROVENANCE): the user merge file is operator MATERIAL and must reach
    # the wire byte-exact — exactly as the SAME file does through `-w` (WordlistFile,
    # chomp only). The merge path must NOT strip leading/trailing whitespace, drop
    # `#`-leading lines (SQL `#`, `#{7*7}` SSTI, a `#!/bin/sh` shebang are real payloads),
    # or drop a blank line (an intentional empty payload; `-w` sends it too).
    it "reads the merge file verbatim, byte-identical to `-w` (WordlistFile)" do
      path = File.tempname("gori-preset-verbatim")
      # A leading-space payload, a trailing-tab payload, two `#`-leading payloads, an
      # intentional blank payload, and a normal one — none collide with a built-in.
      File.write(path, "  SP-LEAD\nTRAIL-TAB\t\n#!/bin/sh\n#{"#"}{7*7}\n\nNORMAL-PAYLOAD\n")
      begin
        # The reference: exactly what `-w` puts on the wire for this file.
        wordlist = [] of String
        F::WordlistFile.new(path).each { |v| wordlist << v }
        wordlist.should eq(["  SP-LEAD", "TRAIL-TAB\t", "#!/bin/sh", "#{"#"}{7*7}", "", "NORMAL-PAYLOAD"])

        builtin = F::Presets.load("sqli")
        merged = F::Presets.load("sqli", path)
        # Merge is a built-in-first suffix; none of the user lines collide, so the tail
        # must be byte-identical to the `-w` reference.
        merged[builtin.size..].should eq(wordlist)
      ensure
        File.delete(path) rescue nil
      end
    end

    it "raises a clean Gori::Error for a missing merge file" do
      expect_raises(Gori::Error, /preset merge file not found/) do
        F::Presets.load("xss", "/no/such/gori-preset-#{Random::Secure.hex(4)}.txt")
      end
    end

    it "rejects a directory given as a merge file" do
      dir = File.tempname("gori-preset-dir")
      Dir.mkdir_p(dir)
      begin
        expect_raises(Gori::Error, /directory/) { F::Presets.load("xss", dir) }
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end
end

describe Gori::Fuzz::PresetSource do
  it "resolves a preset name to its payload list as a PayloadSource" do
    src = F::PresetSource.new("traversal")
    src.size.should eq(F::Presets.load("traversal").size.to_i64)
    collected = [] of String
    src.each { |v| collected << v }
    collected.should eq(F::Presets.load("traversal"))
  end

  it "re-iterates from the start (Cluster-bomb inner-loop contract)" do
    src = F::PresetSource.new("sqli")
    first = [] of String
    src.each { |v| first << v }
    second = [] of String
    src.each { |v| second << v }
    second.should eq(first)
  end

  it "merges a user file through the source" do
    path = File.tempname("gori-preset-src-merge")
    File.write(path, "ZZZ-EXTRA-PAYLOAD\n")
    begin
      src = F::PresetSource.new("xss", path)
      src.size.should eq((F::Presets.load("xss").size + 1).to_i64)
    ensure
      File.delete(path) rescue nil
    end
  end

  it "raises a clean Gori::Error for an unknown preset at size (before any worker)" do
    expect_raises(Gori::Error, /unknown payload preset/) { F::PresetSource.new("bogus").size }
  end
end

# A preset drives a full plan as a source AND composes with a second inline set in a
# Cluster-bomb run (one set per position) — end to end through Plan.build, the
# surface-independent chokepoint the TUI/CLI/MCP all share.
describe "preset in a fuzz plan" do
  it "runs a preset as a single payload source" do
    options = F::PlanOptions.new(
      "GET /?q=§Q§ HTTP/1.1\r\nHost: example.com\r\n\r\n",
      target: "http://example.com",
      sources: [F::PresetSource.new("sqli").as(F::PayloadSource)],
    )
    plan = F::Plan.build(options, ungated)
    plan.total.should eq(F::Presets.load("sqli").size.to_i64)
  end

  it "composes a preset with a second inline set (cluster-bomb ∏)" do
    sqli = F::Presets.load("sqli").size.to_i64
    inline = ["x", "y", "z"]
    options = F::PlanOptions.new(
      "GET /?a=§A§&b=§B§ HTTP/1.1\r\nHost: example.com\r\n\r\n",
      target: "http://example.com",
      config: F::Config.new(mode: F::Mode::ClusterBomb),
      sources: [
        F::PresetSource.new("sqli").as(F::PayloadSource),
        F::InlineList.new(inline).as(F::PayloadSource),
      ],
    )
    plan = F::Plan.build(options, ungated)
    plan.total.should eq(sqli * inline.size)
  end
end
