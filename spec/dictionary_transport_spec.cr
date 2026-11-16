require "./spec_helper"

private alias DT = Gori::DictionaryTransport

private HASH = ":pZGm1Av0IEBKARczz7exkNYsZb8LzaMrV7J32a2fFG4=:"

private def head(*lines : String) : Bytes
  "GET / HTTP/1.1\r\n#{lines.join("\r\n")}\r\n\r\n".to_slice
end

describe Gori::DictionaryTransport do
  describe ".strip_request" do
    it "removes both fields and keeps every other line byte-identical and in order" do
      stripped, removed = DT.strip_request(head("Host: a.test", "Available-Dictionary: #{HASH}",
        "Accept-Encoding: gzip, br, zstd, dcb, dcz", %(Dictionary-ID: "app-v1"), "X-Last: 1"))
      String.new(stripped).should eq(
        "GET / HTTP/1.1\r\nHost: a.test\r\nAccept-Encoding: gzip, br, zstd, dcb, dcz\r\nX-Last: 1\r\n\r\n")
      removed.should eq(["Available-Dictionary: #{HASH}", %(Dictionary-ID: "app-v1")])
    end

    it "matches the names case-insensitively" do
      stripped, removed = DT.strip_request(head("available-DICTIONARY: #{HASH}", "DICTIONARY-id: x"))
      String.new(stripped).should eq("GET / HTTP/1.1\r\n\r\n")
      removed.size.should eq(2)
    end

    it "takes an obs-folded value with its field, so no continuation is orphaned" do
      stripped, removed = DT.strip_request(head("Available-Dictionary: #{HASH}", " folded", "X-After: 1"))
      String.new(stripped).should eq("GET / HTTP/1.1\r\nX-After: 1\r\n\r\n")
      removed.first.should contain("folded")
    end

    it "returns the SAME slice when there is nothing to remove (P7)" do
      original = head("Host: a.test", "Accept-Encoding: gzip, dcb, dcz")
      stripped, removed = DT.strip_request(original)
      removed.should be_empty
      stripped.to_unsafe.should eq(original.to_unsafe)
      stripped.size.should eq(original.size)
    end

    it "bounds the evidence for a huge client-chosen value" do
      _, removed = DT.strip_request(head("Dictionary-ID: #{"x" * 10_000}"))
      removed.first.should eq("Dictionary-ID: #{"x" * DT::EVIDENCE_MAX}")
    end
  end

  describe ".removal_note" do
    it "counts, quotes, and names the setting" do
      note = DT.removal_note(["Available-Dictionary: #{HASH}"])
      note.should start_with("removed 1 dictionary field (Available-Dictionary: #{HASH})")
      note.should contain("RFC 9842")
      note.should contain("network.strip_available_dictionary")
    end

    it "caps the quoting and keeps the count exact" do
      removed = (1..6).map { |i| "Dictionary-ID: id#{i}" }
      note = DT.removal_note(removed)
      note.should contain("removed 6 dictionary fields")
      note.should contain("id4, and 2 more")
      note.should_not contain("id5")
    end
  end

  it ".unrestored drops a removal a rule put back" do
    removed = ["Available-Dictionary: #{HASH}", "Dictionary-ID: x"]
    DT.unrestored(removed, ["available-dictionary"]).should eq(["Dictionary-ID: x"])
    DT.unrestored(removed, head("Dictionary-Id: back")).should eq(["Available-Dictionary: #{HASH}"])
    DT.unrestored(removed, head("Host: a.test")).should eq(removed)
  end

  it ".coding? names the two dictionary codings and nothing else" do
    DT.coding?("dcb").should be_true
    DT.coding?("dcz").should be_true
    {"br", "zstd", "gzip", "compress", "dc"}.each { |c| DT.coding?(c).should be_false }
  end
end
