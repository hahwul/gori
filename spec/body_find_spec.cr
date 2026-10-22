require "./spec_helper"

private def find(body : String | Bytes, pattern : String, from = 0_i64, max = 20, context = 4)
  Gori::BodyFind.run(body.to_slice, pattern, from, max, context)
end

describe Gori::BodyFind do
  it "returns raw byte offsets, lengths and a context snippet" do
    page = find("id=1&token=abc123&x=2", "token=\\w+")
    page.matches.map { |m| {m.offset, m.length, m.snippet} }.should eq([{5_i64, 12_i64, "d=1&token=abc123&x=2"}])
    page.has_more?.should be_false
  end

  it "stops at max and continues from next_offset without losing or repeating a match" do
    body = "a1 a2 a3 a4 a5"
    first = find(body, "a\\d", max: 2)
    first.matches.map(&.offset).should eq([0, 3])
    first.next_offset.should eq(6)
    rest = find(body, "a\\d", from: first.next_offset.not_nil!, max: 10)
    rest.matches.map(&.offset).should eq([6, 9, 12])
    rest.has_more?.should be_false
  end

  it "matches invalid UTF-8 as QL body~ does and maps offsets back to the raw bytes" do
    bytes = Bytes[0xff, 0xfe, 'x'.ord, 0x80, 's'.ord, 'e'.ord, 'c'.ord]
    page = find(bytes, "sec")
    page.matches.first.offset.should eq(4)
    # Context is counted in the scrubbed text, where U+FFFD is three bytes.
    page.matches.first.snippet.should eq("x�sec")
    # `.` reads an invalid byte as U+FFFD, one character standing for one raw byte.
    m = find(bytes, "x.s").matches.first
    {m.offset, m.length}.should eq({2_i64, 3_i64})
    # A start offset past the invalid bytes lands on the same raw position.
    find(bytes, "e", from: 4_i64).matches.first.offset.should eq(5)
  end

  it "starts a search inside a multibyte character at the next character" do
    find("é-é", "é", from: 1_i64).matches.map(&.offset).should eq([3])
  end

  it "steps past an empty match instead of finding it forever" do
    find("ab", "x*", max: 10).matches.map(&.offset).should eq([0, 1, 2])
  end

  it "caps a long match in the snippet but reports its whole length" do
    m = find("k" * 5000, "k+", context: 0).matches.first
    m.length.should eq(5000)
    m.snippet.bytesize.should eq(Gori::BodyFind::MATCH_SHOWN)
  end

  it "raises ArgumentError for a pattern that does not compile" do
    expect_raises(ArgumentError) { find("x", "(") }
  end

  describe "a budget trip" do
    slow = "(?:(?:[\\s\\S]|[\\s\\S]){20}(?!))?[\\x01-\\x02]"
    subject = ("X-A: " + "a" * 60 + "\r\n") * 1100

    it "offers no resume point when nothing was found past the start, so a caller cannot loop" do
      page = find(subject, slow, from: 5_i64)
      {page.stopped, page.matches.empty?, page.next_offset}.should eq({true, true, nil})
    end

    it "resumes just after the last match it returned" do
      page = find("\x01" + subject, slow)
      page.stopped.should be_true
      page.matches.map(&.offset).should eq([0])
      page.next_offset.should eq(1)
    end
  end
end
