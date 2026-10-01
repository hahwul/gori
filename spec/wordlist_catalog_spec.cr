require "./spec_helper"

# The global wordlist catalog (#1353): named lists that live as files under
# `Paths.wordlists_dir`. What these examples pin is the contract every surface leans on —
# the resolution rule (path as given, bare name → cwd then catalog), that a name can never
# leave the directory, that a listing costs a `stat` and never a read of the lists, that a
# save is atomic, owner-only and refuses to overwrite by accident, and that the bytes are
# NEVER normalized (a blank line and a `#` line are payloads to the Fuzzer).
private alias Catalog = Gori::WordlistCatalog
private alias Reason = Gori::WordlistCatalog::Error::Reason

private def refuses(reason : Reason, &)
  yield
  fail "expected a WordlistCatalog::Error (#{reason}), but nothing was raised"
rescue ex : Gori::WordlistCatalog::Error
  ex.reason.should eq(reason)
end

# An `IO` that fails the example if anything reads it: a save that is refused for its NAME
# must not have started on its content.
private class NeverReadIO < IO
  def read(slice : Bytes) : Int32
    raise "the source was read although the save was already refused"
  end

  def write(slice : Bytes) : Nil
    raise "read-only"
  end
end

# A `IO` that, on its first read, creates `path` — the concurrent writer that lands between a
# save's staging and its install.
private class RacingIO < IO
  def initialize(@path : String, @body : String)
    @io = IO::Memory.new(@body)
    @raced = false
  end

  def read(slice : Bytes) : Int32
    unless @raced
      @raced = true
      File.write(@path, "the other writer's list\n")
    end
    @io.read(slice)
  end

  def write(slice : Bytes) : Nil
    raise "read-only"
  end
end

describe Gori::WordlistCatalog do
  describe ".valid_name?" do
    it "accepts a filename in any script, with . _ + - and inner spaces" do
      ["common.txt", "raft-large_words+2", "a", "_x", "사전.txt", "my list.txt", "9lives", "v1.2.3"].each do |n|
        Catalog.valid_name?(n).should be_true
      end
    end

    it "refuses anything that is a path, hidden, an option, or unaddressable" do
      ["", ".", "..", "../x", "a/b", "/abs", ".hidden", ".x.gori1.tmp", "-x", " x", "x ", "x.",
       "a\\b", "tab\there", "nul\0byte", "new\nline", "x" * 201, "\xff\xfe.txt"].each do |n|
        Catalog.valid_name?(n).should be_false
      end
    end

    it "measures the length limit in bytes, not characters" do
      Catalog.valid_name?("가" * 66).should be_true  # 198 bytes
      Catalog.valid_name?("가" * 67).should be_false # 201 bytes
    end
  end

  describe ".resolve" do
    it "hands a path back untouched, whether or not it exists" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(dir)
        File.write(File.join(dir, "common.txt"), "x\n")
        {"./common.txt", "sub/common.txt", "/no/such/common.txt", "../common.txt"}.each do |spec|
          r = Catalog.resolve(spec)
          r.path.should eq(spec)
          r.source.should eq(Catalog::Source::Explicit)
        end
      end
    end

    it "finds a bare name in the current directory first" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(dir)
        File.write(File.join(dir, "common.txt"), "catalog\n")
        File.write("common.txt", "cwd\n")
        r = Catalog.resolve("common.txt")
        r.path.should eq("common.txt") # the string as typed: every existing message keeps its text
        r.source.should eq(Catalog::Source::Cwd)
      end
    end

    it "falls back to the global catalog from any working directory" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(dir)
        File.write(File.join(dir, "common.txt"), "catalog\n")
        r = Catalog.resolve("common.txt")
        r.path.should eq(File.join(dir, "common.txt"))
        r.source.should eq(Catalog::Source::Catalog)
      end
    end

    it "does not take a directory in the current directory for the list" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(dir)
        Dir.mkdir_p("common")
        File.write(File.join(dir, "common"), "catalog\n")
        Catalog.resolve("common").source.should eq(Catalog::Source::Catalog)
      end
    end

    it "returns a name found nowhere as typed, marked missing" do
      with_wordlist_home do
        r = Catalog.resolve("nope.txt")
        r.path.should eq("nope.txt")
        r.source.should eq(Catalog::Source::Missing)
        Catalog.missing_hint(r).to_s.should contain(Gori::Paths.wordlists_dir)
        Catalog.missing_hint(Catalog.resolve("./nope.txt")).should be_nil
      end
    end

    it "never resolves a name the catalog would not address, nor one holding a NUL" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(dir)
        File.write(File.join(dir, ".hidden"), "x\n")
        File.write(File.join(dir, "bad name."), "x\n")
        Catalog.resolve(".hidden").source.should eq(Catalog::Source::Missing)
        Catalog.resolve("bad name.").source.should eq(Catalog::Source::Missing)
        Catalog.resolve("a\0b").source.should eq(Catalog::Source::Missing)
        Catalog.resolve("").source.should eq(Catalog::Source::Missing)
        Catalog.resolve("..").source.should eq(Catalog::Source::Missing)
      end
    end

    it "does not resolve a directory in the catalog" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(File.join(dir, "sub"))
        Catalog.resolve("sub").source.should eq(Catalog::Source::Missing)
      end
    end

    it "follows a symlink to a list" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(dir)
        real = File.join(File.dirname(dir), "elsewhere.txt")
        File.write(real, "x\n")
        File.symlink(real, File.join(dir, "linked.txt"))
        Catalog.resolve("linked.txt").source.should eq(Catalog::Source::Catalog)
      end
    end
  end

  describe ".list" do
    it "is empty, not an error, before the directory exists" do
      with_wordlist_home do
        l = Catalog.list
        l.entries.should be_empty
        l.truncated.should be_false
      end
    end

    it "lists plain files by name with stat metadata, sorted case-insensitively" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(dir)
        File.write(File.join(dir, "beta.txt"), "b\nb\n")
        File.write(File.join(dir, "Alpha.txt"), "a\n")
        File.write(File.join(dir, "alpha2.txt"), "")
        l = Catalog.list
        l.entries.map(&.name).should eq(["Alpha.txt", "alpha2.txt", "beta.txt"])
        l.entries.map(&.bytes).should eq([2_i64, 0_i64, 4_i64])
        l.entries.first.path.should eq(File.join(dir, "Alpha.txt"))
        l.entries.none?(&.symlink).should be_true
      end
    end

    it "leaves out directories, hidden and in-flight files, and unaddressable names" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(File.join(dir, "adir"))
        File.write(File.join(dir, ".DS_Store"), "x")
        File.write(File.join(dir, ".ok.txt.gori123.tmp"), "x")
        File.write(File.join(dir, "trailing-dot."), "x")
        File.write(File.join(dir, "good.txt"), "x\n")
        Catalog.list.entries.map(&.name).should eq(["good.txt"])
      end
    end

    it "reports a link to a list as a list, marked, with the target's size" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(dir)
        real = File.join(File.dirname(dir), "elsewhere.txt")
        File.write(real, "12345\n")
        File.symlink(real, File.join(dir, "linked.txt"))
        File.symlink("/no/such/target", File.join(dir, "dangling.txt"))
        e = Catalog.list.entries
        e.map(&.name).should eq(["linked.txt"]) # a dangling link is not a list
        e.first.symlink.should be_true
        e.first.bytes.should eq(6_i64)
      end
    end

    it "caps the listing and says so" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(dir)
        5.times { |i| File.write(File.join(dir, "l#{i}.txt"), "x\n") }
        l = Catalog.list(3)
        l.entries.size.should eq(3)
        l.truncated.should be_true
        Catalog.list(5).truncated.should be_false
      end
    end

    it "costs a stat per list however large the lists are" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(dir)
        # A sparse 5 GiB file: `list` must report its size without reading a byte of it.
        File.open(File.join(dir, "huge.txt"), "w") { |f| f.truncate(5_i64 * 1024 * 1024 * 1024) }
        started = Time.instant
        l = Catalog.list
        (Time.instant - started).should be < 1.second
        l.entries.first.bytes.should eq(5_i64 * 1024 * 1024 * 1024)
      end
    end
  end

  describe ".info and .line_count" do
    it "counts lines the way File.each_line does" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(dir)
        {"a\nb\n" => 2, "a\nb" => 2, "" => 0, "\n\n" => 2, "one" => 1, "a\r\nb\r\n" => 2}.each do |body, want|
          File.write(File.join(dir, "l.txt"), body)
          info = Catalog.info("l.txt")
          info.lines.should eq(want.to_i64)
          info.lines_complete.should be_true
          n = 0
          File.each_line(File.join(dir, "l.txt")) { n += 1 }
          n.should eq(want)
        end
      end
    end

    it "bounds the scan and says the count is a prefix's, on a file past the cap" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(dir)
        path = File.join(dir, "big.txt")
        File.write(path, "abc\n" * 1000) # 4000 bytes
        lines, complete = Catalog.line_count(path, 400_i64)
        complete.should be_false
        lines.should eq(100_i64)
        Catalog.line_count(path, 4000_i64).should eq({1000_i64, true}) # the cap is the size exactly
      end
    end

    it "reads at most the scan budget of a sparse multi-GiB list" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(dir)
        File.open(File.join(dir, "huge.txt"), "w") { |f| f.truncate(5_i64 * 1024 * 1024 * 1024) }
        started = Time.instant
        info = Catalog.info("huge.txt")
        (Time.instant - started).should be < 5.seconds
        info.lines_complete.should be_false
      end
    end

    it "refuses an unknown or invalid name" do
      with_wordlist_home do
        refuses(Reason::NotFound) { Catalog.info("nope.txt") }
        refuses(Reason::InvalidName) { Catalog.info("../etc/passwd") }
      end
    end
  end

  describe ".preview" do
    it "returns the first lines exactly as a Fuzzer run would read them" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(dir)
        File.write(File.join(dir, "l.txt"), "  padded  \r\n\n# not a comment\r\nlast")
        p = Catalog.preview("l.txt", 10)
        p.lines.should eq(["  padded  ", "", "# not a comment", "last"])
        p.truncated.should be_false
      end
    end

    it "stops at the requested line count and says there is more" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(dir)
        File.write(File.join(dir, "l.txt"), (1..50).map(&.to_s).join("\n") + "\n")
        p = Catalog.preview("l.txt", 5)
        p.lines.should eq(%w[1 2 3 4 5])
        p.truncated.should be_true
      end
    end

    it "is bounded in bytes however long a line is, and never shows half a line" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(dir)
        File.write(File.join(dir, "l.txt"), "head\n" + "x" * (Catalog::PREVIEW_BYTES_MAX * 2))
        p = Catalog.preview("l.txt", 100)
        p.lines.should eq(["head"])
        p.truncated.should be_true
      end
    end

    it "keeps a line that is not valid UTF-8 as its own octets" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(dir)
        File.write(File.join(dir, "l.txt"), Bytes[0xff, 0xfe, 0x41, 0x0a])
        Catalog.preview("l.txt").lines.first.to_slice.should eq(Bytes[0xff, 0xfe, 0x41])
      end
    end

    it "clamps a huge line request" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(dir)
        File.write(File.join(dir, "l.txt"), "a\n")
        Catalog.preview("l.txt", 10_000_000).lines.should eq(["a"])
      end
    end
  end

  # What a one-value-per-line file cannot carry is decided in ONE place: `save_values` refuses on
  # it, and a caller that read its values from a source drops them through `one_per_line`
  # (the CLI's and MCP's `--payload-from` saves both do).
  describe ".one_per_line" do
    it "keeps the values a file can carry, in order, and counts the rest" do
      kept, skipped = Catalog.one_per_line(["a", "", "b\nc", "d\re", "f\r\ng", "#h", " i "])
      kept.should eq(["a", "", "#h", " i "]) # blank, `#` and edge whitespace are payloads, kept as given
      skipped.should eq(3)
    end

    it "agrees with save_values about what a line break is" do
      Catalog.line_break?("a\nb").should be_true
      Catalog.line_break?("a\rb").should be_true
      Catalog.line_break?("a\tb").should be_false
      Catalog.line_break?("a\0b").should be_false # NUL is not a line break, so it is kept (P7)
    end
  end

  describe ".save_values" do
    it "writes one value per line exactly as given" do
      with_wordlist_home do |dir|
        values = ["admin", "", "# comment-looking", "  spaced  ", "tab\there", "ünï", "\xff\xfe"]
        e = Catalog.save_values("p.txt", values)
        e.name.should eq("p.txt")
        File.read(File.join(dir, "p.txt")).should eq(values.join("\n") + "\n")
        File.open(File.join(dir, "p.txt")) do |f|
          got = [] of String
          while l = f.gets(chomp: true)
            got << l
          end
          got.should eq(values)
        end
      end
    end

    it "creates the directory owner-only and the list 0600" do
      with_wordlist_home do |dir|
        Catalog.save_values("p.txt", ["a"])
        (File.info(dir).permissions.value & 0o777).should eq(0o700)
        (File.info(File.join(dir, "p.txt")).permissions.value & 0o777).should eq(0o600)
      end
    end

    it "leaves no staging file behind" do
      with_wordlist_home do |dir|
        Catalog.save_values("p.txt", ["a"])
        Catalog.save_values("p.txt", ["b"], overwrite: true)
        Dir.children(dir).should eq(["p.txt"])
      end
    end

    it "refuses a value that cannot be one line, naming which" do
      with_wordlist_home do |dir|
        ex = expect_raises(Catalog::Error, /value 2 contains a line break/) do
          Catalog.save_values("p.txt", ["ok", "two\nlines"])
        end
        ex.reason.should eq(Reason::BadValue)
        refuses(Reason::BadValue) { Catalog.save_values("p.txt", ["cr\rhere"]) }
        File.exists?(File.join(dir, "p.txt")).should be_false
      end
    end

    it "refuses an empty list and an invalid name, writing nothing" do
      with_wordlist_home do |dir|
        refuses(Reason::Empty) { Catalog.save_values("p.txt", [] of String) }
        refuses(Reason::InvalidName) { Catalog.save_values("../escape.txt", ["a"]) }
        refuses(Reason::InvalidName) { Catalog.save_values("a/b", ["a"]) }
        refuses(Reason::InvalidName) { Catalog.save_values(".hidden", ["a"]) }
        # A refusal has no side effects: not even the directory is created for it.
        Dir.exists?(dir).should be_false
        File.exists?(File.join(File.dirname(dir), "escape.txt")).should be_false
      end
    end

    it "refuses to replace an existing list unless asked, and leaves it untouched" do
      with_wordlist_home do |dir|
        Catalog.save_values("p.txt", ["first"])
        refuses(Reason::Exists) { Catalog.save_values("p.txt", ["second"]) }
        File.read(File.join(dir, "p.txt")).should eq("first\n")
        Catalog.save_values("p.txt", ["second"], overwrite: true)
        File.read(File.join(dir, "p.txt")).should eq("second\n")
      end
    end

    it "refuses to write through, or replace, a symlink" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(dir)
        real = File.join(File.dirname(dir), "elsewhere.txt")
        File.write(real, "precious\n")
        File.symlink(real, File.join(dir, "linked.txt"))
        refuses(Reason::Exists) { Catalog.save_values("linked.txt", ["x"]) }
        refuses(Reason::NotRegular) { Catalog.save_values("linked.txt", ["x"], overwrite: true) }
        File.read(real).should eq("precious\n")
      end
    end

    it "reports a catalog directory it cannot use as an I/O refusal, not a raw error" do
      with_wordlist_home do |dir|
        File.write(dir, "in the way") # the catalog directory's path is occupied by a plain file
        refuses(Reason::Io) { Catalog.save_values("p.txt", ["a"]) }
        refuses(Reason::Io) { Catalog.save_io("p.txt", IO::Memory.new("a\n")) }
        File.read(dir).should eq("in the way")
      end
    end

    it "refuses to replace a directory" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(File.join(dir, "adir"))
        refuses(Reason::Exists) { Catalog.save_values("adir", ["x"]) }
        refuses(Reason::NotRegular) { Catalog.save_values("adir", ["x"], overwrite: true) }
      end
    end
  end

  describe ".save_file / .save_io" do
    it "copies the bytes verbatim — CRLF, binary, no trailing newline" do
      with_wordlist_home do |dir|
        body = Bytes[0x61, 0x0d, 0x0a, 0xff, 0x00, 0x0a, 0x23, 0x62]
        src = File.join(File.dirname(dir), "src.bin")
        File.write(src, body)
        Catalog.save_file("copy.txt", src)
        File.read(File.join(dir, "copy.txt")).to_slice.should eq(body)
      end
    end

    it "streams from an IO" do
      with_wordlist_home do |dir|
        Catalog.save_io("io.txt", IO::Memory.new("a\nb\n"))
        File.read(File.join(dir, "io.txt")).should eq("a\nb\n")
      end
    end

    it "refuses an empty source and does not replace a list with nothing" do
      with_wordlist_home do |dir|
        Catalog.save_values("p.txt", ["keep"])
        refuses(Reason::Empty) { Catalog.save_io("p.txt", IO::Memory.new(""), overwrite: true) }
        File.read(File.join(dir, "p.txt")).should eq("keep\n")
        Dir.children(dir).should eq(["p.txt"])
      end
    end

    it "reports a missing or unusable source as an I/O refusal" do
      with_wordlist_home do |dir|
        refuses(Reason::Io) { Catalog.save_file("x.txt", "/no/such/source.txt") }
        Dir.mkdir_p(dir)
        refuses(Reason::Io) { Catalog.save_file("x.txt", dir) }
        File.exists?(File.join(dir, "x.txt")).should be_false
      end
    end

    it "refuses an existing name before it reads a byte of the source" do
      with_wordlist_home do |dir|
        Catalog.save_values("p.txt", ["keep"])
        refuses(Reason::Exists) { Catalog.save_io("p.txt", NeverReadIO.new) }
        File.read(File.join(dir, "p.txt")).should eq("keep\n")
        Dir.children(dir).should eq(["p.txt"])
      end
    end

    it "loses no data to a writer that lands between the staging and the install" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(dir)
        target = File.join(dir, "race.txt")
        refuses(Reason::Exists) { Catalog.save_io("race.txt", RacingIO.new(target, "mine\n")) }
        File.read(target).should eq("the other writer's list\n")
        Dir.children(dir).should eq(["race.txt"]) # and the staging file is gone
      end
    end
  end

  describe ".delete" do
    it "removes the list" do
      with_wordlist_home do |dir|
        Catalog.save_values("p.txt", ["a"])
        Catalog.delete("p.txt")
        File.exists?(File.join(dir, "p.txt")).should be_false
        refuses(Reason::NotFound) { Catalog.delete("p.txt") }
      end
    end

    it "removes a link, never what it points at" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(dir)
        real = File.join(File.dirname(dir), "elsewhere.txt")
        File.write(real, "precious\n")
        File.symlink(real, File.join(dir, "linked.txt"))
        Catalog.delete("linked.txt")
        File.symlink?(File.join(dir, "linked.txt")).should be_false
        File.read(real).should eq("precious\n")
      end
    end

    it "refuses a name that escapes the directory, and touches nothing outside it" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(dir)
        outside = File.join(File.dirname(dir), "outside.txt")
        File.write(outside, "x\n")
        refuses(Reason::InvalidName) { Catalog.delete("../outside.txt") }
        File.exists?(outside).should be_true
      end
    end
  end

  describe ".rename" do
    it "moves the list to the new name" do
      with_wordlist_home do |dir|
        Catalog.save_values("old.txt", ["a"])
        e = Catalog.rename("old.txt", "new.txt")
        e.name.should eq("new.txt")
        File.exists?(File.join(dir, "old.txt")).should be_false
        File.read(File.join(dir, "new.txt")).should eq("a\n")
        Dir.children(dir).should eq(["new.txt"])
      end
    end

    it "refuses to replace an existing list unless asked" do
      with_wordlist_home do |dir|
        Catalog.save_values("a.txt", ["A"])
        Catalog.save_values("b.txt", ["B"])
        refuses(Reason::Exists) { Catalog.rename("a.txt", "b.txt") }
        File.read(File.join(dir, "a.txt")).should eq("A\n")
        File.read(File.join(dir, "b.txt")).should eq("B\n")
        Catalog.rename("a.txt", "b.txt", overwrite: true)
        File.read(File.join(dir, "b.txt")).should eq("A\n")
        File.exists?(File.join(dir, "a.txt")).should be_false
      end
    end

    it "renames to a spelling that differs only in case" do
      # On a case-insensitive filesystem (macOS's default) the new spelling already "exists":
      # it is the source entry itself, and the exclusive link used to refuse it as a clash.
      with_wordlist_home do |dir|
        Catalog.save_values("ids.txt", ["40"])
        Catalog.rename("ids.txt", "IDS.txt").name.should eq("IDS.txt")
        Dir.children(dir).should eq(["IDS.txt"])
        File.read(File.join(dir, "IDS.txt")).should eq("40\n")
      end
    end

    it "validates both names and requires the source to exist" do
      with_wordlist_home do
        Catalog.save_values("a.txt", ["A"])
        refuses(Reason::NotFound) { Catalog.rename("nope.txt", "b.txt") }
        refuses(Reason::InvalidName) { Catalog.rename("a.txt", "../b.txt") }
        refuses(Reason::InvalidName) { Catalog.rename("../a.txt", "b.txt") }
        Catalog.list.entries.map(&.name).should eq(["a.txt"])
      end
    end

    it "is a no-op onto its own name" do
      with_wordlist_home do
        Catalog.save_values("a.txt", ["A"])
        Catalog.rename("a.txt", "a.txt").name.should eq("a.txt")
        Catalog.list.entries.map(&.name).should eq(["a.txt"])
      end
    end

    it "moves a symlink as a link and will not clobber a link's target" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(dir)
        real = File.join(File.dirname(dir), "elsewhere.txt")
        File.write(real, "precious\n")
        File.symlink(real, File.join(dir, "linked.txt"))
        Catalog.save_values("plain.txt", ["p"])
        Catalog.rename("linked.txt", "moved.txt")
        File.symlink?(File.join(dir, "moved.txt")).should be_true
        refuses(Reason::NotRegular) { Catalog.rename("plain.txt", "moved.txt", overwrite: true) }
        File.read(real).should eq("precious\n")
      end
    end
  end
end
