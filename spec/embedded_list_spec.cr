require "./spec_helper"

describe Gori::EmbeddedList do
  it "reads one trimmed entry per line, skipping blank and comment lines" do
    raw = "# header\n\nadmin\n  login \t\n#skip\n\t\nbackup\r\n"
    Gori::EmbeddedList.parse(raw).should eq(["admin", "login", "backup"])
  end

  it "de-duplicates keeping the first occurrence in place" do
    Gori::EmbeddedList.dedup(["b", "a", "b", "c", "a"]).should eq(["b", "a", "c"])
  end

  # The three embedded readers share the helper; each built-in must still come out non-empty
  # with no blank or comment line surviving.
  it "backs every built-in list" do
    [Gori::Discover::Wordlist.builtin, Gori::Miner::Wordlist.builtin,
     Gori::Fuzz::Presets.builtin("sqli")].each do |list|
      list.should_not be_empty
      list.none? { |entry| entry.empty? || entry.starts_with?('#') }.should be_true
    end
  end
end
