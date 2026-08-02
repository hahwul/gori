require "../spec_helper"

# Round 8, item 1 (round 7 h1-seams.md FINDING 4): the user merge file for `--wordlist` is
# operator MATERIAL. `Wordlist.load` used to `.strip` every line before appending it, which
# not only destroyed a leading/trailing space or tab but then let the stripped copy DEDUPE
# AWAY against its own trimmed twin — a path segment silently vanished from the run with no
# warning. Fixed to `chomp: true` (line-ending only), classifying blank/`#`-comment lines on
# a TRIMMED copy but yielding the UNSTRIPPED line, exactly the fidelity round 6 gave
# `Fuzz::Presets`/`WordlistFile` for payloads.
private alias D = Gori::Discover

private def with_wordlist(raw : String, &)
  path = File.tempname("gori-discover-wordlist", ".txt")
  File.write(path, raw)
  begin
    yield path
  ensure
    File.delete?(path)
  end
end

describe Gori::Discover::Wordlist do
  it "loads the built-in list stripped and comment-free (unchanged, curated asset)" do
    D::Wordlist.builtin.should_not be_empty
    D::Wordlist.builtin.none?(&.empty?).should be_true
    D::Wordlist.builtin.none? { |n| n.starts_with?('#') }.should be_true
  end

  describe "user merge file (operator material)" do
    it "keeps a leading/trailing space or tab instead of stripping it away" do
      with_wordlist("zzadmin \n zzadmin\nzzTRAILTAB\t\n") do |path|
        merged = D::Wordlist.load(path)
        merged.should contain("zzadmin ")
        merged.should contain(" zzadmin")
        merged.should contain("zzTRAILTAB\t")
      end
    end

    it "does NOT collapse the trailing-space and leading-space variants into one entry" do
      with_wordlist("zzadmin \n zzadmin\n") do |path|
        merged = D::Wordlist.load(path)
        # Both survive as DISTINCT entries — this is the exact dedupe-away this round fixes.
        merged.count { |n| n == "zzadmin " || n == " zzadmin" }.should eq(2)
      end
    end

    it "still skips a blank line and a #-comment line (kept as intentional conventions)" do
      with_wordlist("zzone\n\n#zzcomment\nzztwo\n") do |path|
        merged = D::Wordlist.load(path)
        merged.should contain("zzone")
        merged.should contain("zztwo")
        merged.none?(&.starts_with?('#')).should be_true
        merged.none?(&.empty?).should be_true
      end
    end

    it "keeps an interior # (not comment-classified) and still de-dupes an exact duplicate" do
      with_wordlist("zzhash#x\nzzhash#x\n") do |path|
        merged = D::Wordlist.load(path)
        merged.count("zzhash#x").should eq(1) # exact duplicate — legitimate dedupe
      end
    end

    it "merges built-in first, order preserving, de-duped against a real collision" do
      baseline = D::Wordlist.load # deduped baseline (raw .builtin may carry internal dupes)
      with_wordlist("#{baseline.first}\nCUSTOM-#{Random::Secure.hex(3)}\n") do |path|
        merged = D::Wordlist.load(path)
        merged[0, baseline.size].should eq(baseline)
        merged.uniq.size.should eq(merged.size)
      end
    end

    it "raises for a missing merge path" do
      expect_raises(File::NotFoundError) do
        D::Wordlist.load("/no/such/gori-wordlist-#{Random::Secure.hex(4)}.txt")
      end
    end
  end
end
