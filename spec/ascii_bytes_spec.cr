require "./spec_helper"

private def bytes(str : String) : Bytes
  str.to_slice
end

private def contains?(hay : String, needle : String) : Bool
  Gori::AsciiBytes.contains_ci?(hay.to_slice, needle.to_slice)
end

private def starts?(hay : String, needle : String) : Bool
  Gori::AsciiBytes.starts_with_ci?(hay.to_slice, needle.to_slice)
end

describe Gori::AsciiBytes do
  describe ".contains_ci?" do
    describe "empty and size boundaries" do
      it "returns true for an empty needle regardless of hay" do
        contains?("", "").should be_true
        contains?("anything", "").should be_true
        Gori::AsciiBytes.contains_ci?(Bytes[0xff, 0x00, 0x80], Bytes.empty).should be_true
      end

      it "returns false for a non-empty needle against an empty hay" do
        contains?("", "x").should be_false
        contains?("", "content-type").should be_false
      end

      it "returns false when hay is exactly one byte shorter than needle (off-by-one)" do
        # hay.size == needle.size - 1 must take the `hay.size < n` early-out.
        contains?("abcd", "abcde").should be_false
        contains?("a", "ab").should be_false
      end

      it "matches when hay and needle are the same single byte" do
        contains?("a", "a").should be_true
        contains?("A", "a").should be_true # single byte, folded
      end

      it "matches when hay equals needle exactly (limit == 0)" do
        contains?("content-type", "content-type").should be_true
        contains?("CONTENT-TYPE", "content-type").should be_true
      end
    end

    describe "ASCII case-folding" do
      it "folds A-Z in hay to match a lowercase needle in any casing of hay" do
        contains?("CONTENT-TYPE", "content-type").should be_true
        contains?("Content-Type", "content-type").should be_true
        contains?("CoNtEnT-TyPe", "content-type").should be_true
      end

      it "finds the needle as a substring of a larger hay" do
        contains?("HTTP/1.1 200\r\nContent-Type: text/html", "content-type").should be_true
        contains?("x-Content-Type-Options", "content-type").should be_true
      end

      it "matches a needle occurring at the very end of hay (i == limit)" do
        # The trailing occurrence is only found because the scan runs through i == limit.
        contains?("set-cookie: CONTENT-TYPE", "content-type").should be_true
        contains?("zzzab", "ab").should be_true
      end

      it "does not match when a needle byte is absent even after folding" do
        contains?("content-length", "content-type").should be_false
        contains?("CONTENT", "content-type").should be_false # hay shorter overall handled, but also non-match
      end
    end

    describe "fold boundary bytes (only A-Z 0x41-0x5a fold)" do
      it "does not fold '@' (0x40, just below 'A')" do
        # 0x40 | 0x20 == 0x60 ('`'); folding would wrongly match a '`' needle.
        Gori::AsciiBytes.contains_ci?(Bytes[0x40_u8], Bytes[0x60_u8]).should be_false
        Gori::AsciiBytes.contains_ci?(Bytes[0x40_u8], Bytes[0x40_u8]).should be_true
      end

      it "does not fold '[' (0x5b, just above 'Z')" do
        # needle "{" (0x7b) differs from hay "[" (0x5b) by exactly 0x20 but 0x5b is
        # outside A-Z, so it must NOT be folded and must NOT match.
        Gori::AsciiBytes.contains_ci?(Bytes[0x5b_u8], Bytes[0x7b_u8]).should be_false
        # identical non-folded byte still matches verbatim
        Gori::AsciiBytes.contains_ci?(Bytes[0x5b_u8], Bytes[0x5b_u8]).should be_true
      end

      it "folds exactly the endpoints 'A' (0x41) and 'Z' (0x5a)" do
        Gori::AsciiBytes.contains_ci?(Bytes[0x41_u8], Bytes[0x61_u8]).should be_true # A -> a
        Gori::AsciiBytes.contains_ci?(Bytes[0x5a_u8], Bytes[0x7a_u8]).should be_true # Z -> z
      end
    end

    describe "non-ASCII bytes compared verbatim" do
      it "matches a CJK UTF-8 needle only against an identical byte sequence" do
        contains?("헤더 안녕하세요", "안녕").should be_true
        contains?("世界 hello", "世界").should be_true
        # a different CJK sequence of the same length must not match
        contains?("안녕", "세요").should be_false
      end

      it "matches an emoji needle byte-for-byte" do
        contains?("status \u{1F600} ok", "\u{1F600}").should be_true
        contains?("no emoji here", "\u{1F600}").should be_false
      end

      it "never case-folds bytes > 0x7f" do
        # 0x61 ('a') and 0x41 ('A') fold; 0xC1 (== 0xA1 | 0x20) must not.
        Gori::AsciiBytes.contains_ci?(Bytes[0xc1_u8], Bytes[0xa1_u8]).should be_false
        Gori::AsciiBytes.contains_ci?(Bytes[0xc1_u8], Bytes[0xc1_u8]).should be_true
      end

      it "handles invalid/truncated UTF-8 bytes as raw bytes" do
        hay = Bytes[0xff_u8, 0xfe_u8, 0x41_u8, 0x00_u8]
        Gori::AsciiBytes.contains_ci?(hay, Bytes[0xff_u8, 0xfe_u8]).should be_true
        Gori::AsciiBytes.contains_ci?(hay, Bytes[0x61_u8]).should be_true # 0x41 'A' folds to 'a'
        Gori::AsciiBytes.contains_ci?(hay, Bytes[0x00_u8]).should be_true
        Gori::AsciiBytes.contains_ci?(hay, Bytes[0xfd_u8]).should be_false
      end
    end

    describe "lowercase-needle precondition (caller responsibility)" do
      it "does not match when the needle carries an uppercase byte (documented precondition)" do
        # Per the contract the needle MUST already be lowercase. Only hay is folded,
        # so an uppercase needle byte cannot equal a folded (lowercase) hay byte.
        # This asserts the documented precondition — a non-match, not a bug.
        contains?("content-type", "content-TYPE").should be_false
        contains?("content-type", "CONTENT-TYPE").should be_false
        contains?("CONTENT-TYPE", "CONTENT-TYPE").should be_false
      end

      it "an uppercase needle byte still matches a verbatim uppercase hay byte" do
        # 'T' (0x54) is in A-Z, so hay's 'T' folds to 't' (0x74) which != 'T' needle.
        contains?("TYPE", "TYPE").should be_false
      end
    end

    describe "overlapping / near-miss scanning" do
      it "advances i past a partial match to find the true occurrence (hay 'aab', needle 'ab')" do
        contains?("aab", "ab").should be_true
      end

      it "finds an occurrence that only appears after several false starts" do
        contains?("aaaab", "aab").should be_true
        contains?("abababc", "abc").should be_true
      end

      it "returns false when repeated prefixes never complete the needle" do
        contains?("aaaa", "aab").should be_false
        contains?("ababab", "abc").should be_false
      end
    end

    describe "adversarial / performance" do
      it "completes quickly on a large hay with a near-matching needle (no pathological blowup)" do
        # 200k 'a's followed by 'b'; needle 'a'*64 + 'b' forces a full-length compare
        # to restart at nearly every position — O(hay·needle) must still finish fast.
        hay = ("a" * 200_000) + "b"
        needle = ("a" * 64) + "b"
        elapsed = Time.measure do
          contains?(hay, needle).should be_true
        end
        elapsed.should be < 2.seconds
      end

      it "handles a large hay that never contains the needle" do
        hay = "A" * 100_000
        contains?(hay, "ab").should be_false
      end
    end
  end

  # A byte-level prefix test exists so nothing that inspects a WIRE request line has to reach
  # for a Regex: PCRE2 RAISES on invalid UTF-8 rather than not matching, and that raise killed
  # a fuzz worker fiber mid-sweep the first time a payload carried a high byte.
  describe ".starts_with_ci?" do
    it "folds only A-Z and matches a prefix" do
      starts?("HTTP://host/x", "http://").should be_true
      starts?("HtTpS://host/x", "https://").should be_true
      starts?("http://host", "https://").should be_false
      starts?("ftp://host", "http://").should be_false
    end

    it "is true for an empty needle and false when the hay is shorter" do
      starts?("", "").should be_true
      starts?("ht", "http://").should be_false
    end

    it "does not raise on invalid UTF-8 (the whole reason it is not a Regex)" do
      hay = Bytes[0xc3, 0x28, 0x80, 0x2f]
      Gori::AsciiBytes.starts_with_ci?(hay, "http://".to_slice).should be_false
      Gori::Store::FlowRow.absolute_form?(String.new(hay)).should be_false
      Gori::Store::FlowRow.absolute_form?(String.new(Bytes[0x48, 0x54, 0x54, 0x50, 0x3a, 0x2f, 0x2f, 0x80])).should be_true
    end
  end

  describe ".ascii_only?" do
    it "is true for empty and pure-ASCII input, false for any byte >= 0x80 wherever it sits" do
      Gori::AsciiBytes.ascii_only?(Bytes.empty).should be_true
      Gori::AsciiBytes.ascii_only?(Bytes.new(300) { |i| (i % 128).to_u8 }).should be_true
      [0, 1, 7, 8, 31, 32, 299].each do |at|
        Gori::AsciiBytes.ascii_only?(Bytes.new(300) { |i| i == at ? 0x80_u8 : 0x41_u8 }).should be_false
      end
    end
  end

  describe ".range_eq_ci?" do
    it "folds A-Z only and requires the exact length" do
      h = "xContent-TYPEx".to_slice
      Gori::AsciiBytes.range_eq_ci?(h, 1, 13, "content-type".to_slice).should be_true
      Gori::AsciiBytes.range_eq_ci?(h, 1, 12, "content-type".to_slice).should be_false
      Gori::AsciiBytes.range_eq_ci?(h, 0, 13, "content-type".to_slice).should be_false
      Gori::AsciiBytes.range_eq_ci?("[]".to_slice, 0, 2, "{}".to_slice).should be_false
    end
  end

  describe ".each_head_field" do
    it "yields trimmed name/value offsets per colon line and stops at the blank line" do
      h = "GET / HTTP/1.1\r\n A :  b \r\nnocolon\r\nC:\r\n\r\nD: e\r\n".to_slice
      seen = [] of {String, String}
      Gori::AsciiBytes.each_head_field(h) do |na, nz, va, vz|
        seen << {String.new(h[na, nz - na]), String.new(h[va, vz - va])}
      end
      seen.should eq([{"A", "b"}, {"C", ""}])
    end
  end
end
