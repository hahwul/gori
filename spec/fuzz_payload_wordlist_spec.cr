require "./spec_helper"
require "file_utils"

# Fix #24 — `gori run fuzz -w <path>` must surface a missing / unusable wordlist as a
# clean Gori::Error (→ "gori run fuzz: wordlist …"), not a raw File::NotFoundError
# backtrace leaking out of File.each_line / File.open.
describe Gori::Fuzz::WordlistFile do
  it "raises a clean Gori::Error for a missing wordlist path (not a raw File error)" do
    wl = Gori::Fuzz::WordlistFile.new("/no/such/gori-wordlist-#{Random::Secure.hex(4)}.txt")
    expect_raises(Gori::Error, /wordlist not found/) { wl.size }          # preflight open-check path
    expect_raises(Gori::Error, /wordlist not found/) { wl.open_iterator } # run-time cursor path
  end

  it "rejects a directory given as a wordlist" do
    dir = File.tempname("gori-wl-dir")
    Dir.mkdir_p(dir)
    begin
      wl = Gori::Fuzz::WordlistFile.new(dir)
      expect_raises(Gori::Error, /directory/) { wl.size }
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "counts and iterates a real wordlist unchanged" do
    path = File.tempname("gori-wl")
    File.write(path, "alpha\nbeta\ngamma\n")
    begin
      wl = Gori::Fuzz::WordlistFile.new(path)
      wl.size.should eq(3_i64)
      it = wl.open_iterator
      values = [it.next_value, it.next_value, it.next_value, it.next_value]
      values.should eq(["alpha", "beta", "gamma", nil])
      it.close
    ensure
      File.delete(path) rescue nil
    end
  end
end
