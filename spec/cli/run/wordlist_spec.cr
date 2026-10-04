require "../../spec_helper"
require "json"

# `gori run wordlist` (#1353). The verbs `abort` and `puts`, so what an example can pin is the
# part scripts read: the renderers. The catalog's own contract (resolution, atomic save,
# refusals) is spec/wordlist_catalog_spec.cr.
private alias Catalog = Gori::WordlistCatalog
private alias Run = Gori::CLI::Run

private def entry_json(e : Catalog::Entry) : JSON::Any
  JSON.parse(JSON.build { |j| Run.wordlist_entry_json(j, e) })
end

describe "gori run wordlist — renderers" do
  it "lists names, sizes and times in a table that never prints a value" do
    with_wordlist_home do
      Catalog.save_values("alpha.txt", ["s3cr3t-value", "another"])
      Catalog.save_values("Beta list.txt", ["x"] * 400)
      table = Run.wordlist_table(Catalog.list.entries)
      lines = table.lines
      lines.first.should start_with("NAME")
      lines.first.should contain("SIZE")
      lines.first.should contain("MODIFIED")
      table.should contain("alpha.txt")
      table.should contain("Beta list.txt")
      table.should contain("21B") # alpha.txt: "s3cr3t-value\nanother\n"
      table.should contain("800B")
      table.should_not contain("s3cr3t-value")
      lines.size.should eq(3)
    end
  end

  it "marks a symlinked list" do
    posix_only!("File.symlink needs Developer Mode")
    with_wordlist_home do |dir|
      Dir.mkdir_p(dir)
      real = File.join(File.dirname(dir), "elsewhere.txt")
      File.write(real, "x\n")
      File.symlink(real, File.join(dir, "linked.txt"))
      Run.wordlist_table(Catalog.list.entries).should contain("(symlink)")
    end
  end

  it "emits one JSON object per list with the documented fields" do
    with_wordlist_home do |dir|
      e = Catalog.save_values("alpha.txt", ["a", "b"])
      j = entry_json(e)
      j["name"].as_s.should eq("alpha.txt")
      j["path"].as_s.should eq(File.join(dir, "alpha.txt"))
      j["bytes"].as_i64.should eq(4_i64)
      j["symlink"].as_bool.should be_false
      j["modified"].as_s.should match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/)
      j.as_h.keys.should eq(%w[name path bytes modified symlink])
    end
  end

  describe "show" do
    it "prints metadata and no values unless a preview is given" do
      with_wordlist_home do |dir|
        Catalog.save_values("alpha.txt", ["s3cr3t-value", "another"])
        info = Catalog.info("alpha.txt")
        text = Run.wordlist_info_text(info, nil)
        text.should contain("alpha.txt")
        text.should contain(File.join(dir, "alpha.txt"))
        text.should contain("21B (21 bytes)")
        text.should match(/lines\s+2\b/)
        text.should_not contain("s3cr3t-value")
        JSON.parse(JSON.build { |j| Run.wordlist_info_json(j, info, nil) })["preview"]?.should be_nil
      end
    end

    it "includes the first lines when asked, terminal-safe in text and scrubbed in JSON" do
      with_wordlist_home do
        Catalog.save_io("alpha.txt", IO::Memory.new(Bytes[0x61, 0x1b, 0x5b, 0x33, 0x31, 0x6d, 0x0a, 0xff, 0x0a, 0x63, 0x0a]))
        info = Catalog.info("alpha.txt")
        pv = Catalog.preview("alpha.txt", 2)
        text = Run.wordlist_info_text(info, pv)
        text.should_not contain('\e') # an escape in a value never reaches the terminal
        doc = JSON.build { |j| Run.wordlist_info_json(j, info, pv) }
        doc.valid_encoding?.should be_true
        parsed = JSON.parse(doc)
        parsed["preview"].as_a.size.should eq(2)
        parsed["preview_truncated"].as_bool.should be_true
        parsed["lines"].as_i64.should eq(3_i64)
        parsed["lines_complete"].as_bool.should be_true
      end
    end

    it "says the line count is a lower bound when the list is past the scan budget" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(dir)
        File.open(File.join(dir, "huge.txt"), "w") { |f| f.truncate(5_i64 * 1024 * 1024 * 1024) }
        text = Run.wordlist_info_text(Catalog.info("huge.txt"), nil)
        text.should contain("more than")
        text.should contain("counted the first 32 MiB")
      end
    end
  end
end
