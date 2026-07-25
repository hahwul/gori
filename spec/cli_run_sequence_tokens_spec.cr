require "./spec_helper"

# Test seam: read_token_list is a private module method; expose a thin caller within
# the same namespace (this only exists in the test binary) so Fix #1 can be exercised
# directly without going through the network/exit paths of the full subcommand.
module Gori::CLI::Run
  def self.spec_read_token_list(file : String) : Array(String)
    read_token_list(file)
  end
end

# Fix #1 — `gori run sequence --tokens=FILE` used to crash with
# "ArgumentError: Regex match error: UTF-8 error" when the file held a non-UTF-8 byte,
# because the `raw.split(/\r?\n/)` PCRE2 split rejects invalid UTF-8. The read now
# scrubs to valid UTF-8 first so a stray byte doesn't abort the whole analysis.
describe "Gori::CLI::Run.read_token_list" do
  it "does not crash on a non-UTF-8 tokens file (scrubs the bad byte to U+FFFD)" do
    path = File.tempname("gori-tokens")
    # a \n b<0xff> \n c \n  — the 0xff used to make the regex split raise.
    File.write(path, Bytes[0x61_u8, 0x0a_u8, 0x62_u8, 0xff_u8, 0x0a_u8, 0x63_u8, 0x0a_u8])
    begin
      tokens = Gori::CLI::Run.spec_read_token_list(path)
      tokens.size.should eq(3)
      tokens[0].should eq("a")
      tokens[1].should eq("b\u{FFFD}") # invalid byte replaced with U+FFFD, token preserved
      tokens[2].should eq("c")
    ensure
      File.delete(path) rescue nil
    end
  end

  it "reads a normal UTF-8 tokens file unchanged (CRLF + blank lines handled)" do
    path = File.tempname("gori-tokens")
    File.write(path, "one\r\ntwo\n\n  three  \n")
    begin
      Gori::CLI::Run.spec_read_token_list(path).should eq(["one", "two", "three"])
    ensure
      File.delete(path) rescue nil
    end
  end
end
