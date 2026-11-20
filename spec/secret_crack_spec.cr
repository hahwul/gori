require "./spec_helper"

describe Gori::SecretCrack do
  it "streams inline values before a saved wordlist, preserving empty lines and spaces" do
    with_wordlist_home do |dir|
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "jwt-secrets.txt"), "\n spaced \nlast\n")
      source = Gori::SecretCrack::Candidates.new(["inline"], "jwt-secrets.txt")
      values = [] of String
      source.each { |v| values << v }
      values.should eq(["inline", "", " spaced ", "last"])
    end
  end

  it "does not open the file after an inline hit, and surfaces missing files otherwise" do
    source = Gori::SecretCrack::Candidates.new(["hit"], "/missing/gori-wordlist")
    Gori::SecretCrack.search(source, "hit") { |s| s }.tried.should eq(1)
    expect_raises(Gori::Error, "wordlist not found") do
      Gori::SecretCrack.search(source, "miss") { |s| s }
    end
  end

  it "reports zero attempts when cancelled before starting" do
    result = Gori::SecretCrack.search(["hit"], "hit", -> { true }) { |s| s }
    result.tried.should eq(0)
    result.stopped.should be_true
  end

  it "yields after an expensive candidate instead of waiting for the count stride" do
    stop = false
    spawn { stop = true }
    result = Gori::SecretCrack.search(Array.new(4096, "wrong"), "hit", -> { stop }) do |candidate|
      deadline = Time.instant + 12.milliseconds
      while Time.instant < deadline
        # Deliberately CPU-bound: sleep would yield without exercising the search's budget.
      end
      candidate
    end
    result.stopped.should be_true
    result.tried.should be <= 1
  end
end
