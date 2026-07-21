require "../spec_helper"

# Concatenate string / raw-byte parts into one Bytes slice (for building bodies that mix
# ASCII text with adversarial / invalid-UTF-8 bytes).
private def cat(*parts : String | Bytes) : Bytes
  io = IO::Memory.new
  parts.each do |p|
    case p
    in String then io.write(p.to_slice)
    in Bytes  then io.write(p)
    end
  end
  io.to_slice
end

# A clean response head with a status but NO canary-shaped token and NO content/transfer
# encoding header (so ContentDecode short-circuits and the body is used verbatim).
private def clean_head : Bytes
  "HTTP/1.1 200 OK\r\n\r\n".to_slice
end

# Build a Repeater::Result exactly as engine_spec's ok() does, then probe it.
private def probe_raw(head : Bytes, body : Bytes) : Gori::Miner::Probe
  resp = Gori::Proxy::Codec::Http1.parse_response_head(head)
  Gori::Miner::Fingerprint.probe(Gori::Repeater::Result.new(head, body, resp, 1000_i64))
end

private def probe_body(body : Bytes) : Gori::Miner::Probe
  probe_raw(clean_head, body)
end

private def probe_str(body : String) : Gori::Miner::Probe
  probe_body(body.to_slice)
end

describe Gori::Miner::Fingerprint do
  describe "canary reflection (scan_canaries via probe)" do
    it "finds a canary placed at the LAST valid body offset (i == last boundary)" do
      # 3 bytes of padding then the 10-byte canary as the final bytes: 'g' sits at
      # index size-10 == last, the highest offset the `i <= last` loop still checks.
      p = probe_str("ZZZgqdeadbeef")
      p.reflects?("gqdeadbeef").should be_true
      p.canaries.should eq(Set{"gqdeadbeef"})
    end

    it "collects TWO adjacent canaries with no separator as distinct set entries" do
      p = probe_str("gqaaaaaaaagqbbbbbbbb")
      p.reflects?("gqaaaaaaaa").should be_true
      p.reflects?("gqbbbbbbbb").should be_true
      p.canaries.should eq(Set{"gqaaaaaaaa", "gqbbbbbbbb"})
    end

    it "returns an empty canary set for a body of exactly LEN-1 (9) bytes" do
      # size 9 < Canary::LEN (10): scan_canaries early-returns before the loop.
      p = probe_str("gqaaaaaaa") # gq + 7 hex = 9 bytes
      p.canaries.should be_empty
      p.reflects?("gqaaaaaaa").should be_false
    end

    it "finds a canary whose body is exactly LEN (10) bytes (last == 0)" do
      p = probe_str("gq09af09af")
      p.reflects?("gq09af09af").should be_true
      p.canaries.size.should eq(1)
    end

    it "does NOT match an UPPERCASE hex tail (lower-hex only)" do
      p = probe_str("gqAABBCCDD")
      p.canaries.should be_empty
      p.reflects?("gqAABBCCDD").should be_false
    end

    it "rejects a tail with a non-hex byte (gq + 7 hex + 'z')" do
      p = probe_str("gq1234567z")
      p.canaries.should be_empty
      p.reflects?("gq1234567z").should be_false
    end

    it "accepts the full lower-hex alphabet 0-9 a-f in the tail" do
      p = probe_str("gqabcdef01")
      p.reflects?("gqabcdef01").should be_true
    end

    it "rejects tail bytes just outside each hex range (off-by-one boundaries)" do
      # '/'=0x2f (below '0'), ':'=0x3a (above '9'), '`'=0x60 (below 'a'), 'g'=0x67 (above 'f')
      probe_str("gq/0000000").canaries.should be_empty
      probe_str("gq:0000000").canaries.should be_empty
      probe_str("gq`0000000").canaries.should be_empty
      probe_str("gqg0000000").canaries.should be_empty
      # and the inclusive endpoints ARE accepted
      probe_str("gq0000000f").reflects?("gq0000000f").should be_true
      probe_str("gq9999999a").reflects?("gq9999999a").should be_true
    end

    it "requires the exact 'gq' prefix ('g' + non-'q' is not a canary)" do
      p = probe_str("ghdeadbeef") # second byte 'h' (0x68) != 'q' (0x71)
      p.canaries.should be_empty
    end

    it "reports a canary echoed ONLY in the response head (head scanned separately)" do
      head = "HTTP/1.1 200 OK\r\nX-Reflected: gqcafebabe\r\n\r\n".to_slice
      body = "clean baseline response, no token here".to_slice
      p = probe_raw(head, body)
      p.reflects?("gqcafebabe").should be_true
      p.canaries.should eq(Set{"gqcafebabe"})
    end

    it "does NOT find a canary that straddles the body/head split (slices scanned independently)" do
      # body ends with 'gqaaa' (partial); head begins with the remaining 'aaaaa'. Concatenated
      # they spell 'gqaaaaaaaa', but each slice is scanned on its own so neither contains it.
      body = "PADDINGgqaaa".to_slice # 'g' at index 7 > last (2) → never even inspected
      head = "aaaaaHTTP/1.1 200 OK\r\n\r\n".to_slice
      p = probe_raw(head, body)
      p.reflects?("gqaaaaaaaa").should be_false
      p.canaries.should be_empty
    end

    it "reports false for a canary-shaped needle that never appears" do
      probe_str("nothing to see").reflects?("gq00000000").should be_false
    end

    it "finds a canary surrounded by invalid UTF-8 bytes (byte scan, not string scan)" do
      body = cat(Bytes[0xff_u8, 0xfe_u8, 0x80_u8], "gqdeadbeef", Bytes[0x81_u8, 0xff_u8])
      p = probe_body(body)
      p.reflects?("gqdeadbeef").should be_true
    end

    it "does not treat overlapping 'gq' prefixes as a match when the tail starts with 'g'" do
      # 'gqgqaaaaaa': at i=0 the tail's first byte is 'g' (0x67, not hex) → rejected.
      probe_str("gqgqaaaaaa").canaries.should be_empty
    end
  end

  describe "count_words (metrics.words via probe)" do
    it "counts 0 words for an empty body" do
      probe_body(Bytes.empty).metrics.words.should eq(0)
    end

    it "counts 0 words for whitespace-only bodies" do
      probe_str(" \t\r\n ").metrics.words.should eq(0)
    end

    it "counts 1 word for a single token (with surrounding whitespace)" do
      probe_str("  hello  ").metrics.words.should eq(1)
    end

    it "collapses a mixed run of space/tab/CR/LF between two tokens to a single boundary" do
      probe_str("foo \t\r\n bar").metrics.words.should eq(2)
    end

    it "counts multibyte tokens by whitespace transition, not grapheme" do
      probe_str("안녕 世界").metrics.words.should eq(2)
      probe_str("안녕世界").metrics.words.should eq(1) # no whitespace → one contiguous run
    end
  end

  describe "count_lines (metrics.lines via probe)" do
    it "counts 0 lines for an empty body" do
      probe_body(Bytes.empty).metrics.lines.should eq(0)
    end

    it "counts only LF (0x0a) — bare CR line endings yield 0 lines" do
      probe_str("line1\rline2\rline3\r").metrics.lines.should eq(0)
    end

    it "counts a trailing LF" do
      probe_str("only one line\n").metrics.lines.should eq(1)
    end

    it "counts each LF, including those inside CRLF sequences" do
      probe_str("a\r\nb\r\nc").metrics.lines.should eq(2)
      probe_str("a\nb\nc\n").metrics.lines.should eq(3)
    end
  end

  describe "metrics scalars" do
    it "carries status, decoded length, and duration through the probe" do
      body = "hello world".to_slice
      p = probe_body(body)
      p.metrics.status.should eq(200)
      p.metrics.length.should eq(body.size.to_i64)
      p.metrics.duration_us.should eq(1000_i64)
    end

    it "treats a nil body as empty (0 length, no words/lines, no canaries)" do
      resp = Gori::Proxy::Codec::Http1.parse_response_head(clean_head)
      p = Gori::Miner::Fingerprint.probe(Gori::Repeater::Result.new(clean_head, nil, resp, 1000_i64))
      p.metrics.length.should eq(0_i64)
      p.metrics.words.should eq(0)
      p.metrics.lines.should eq(0)
      p.canaries.should be_empty
    end
  end

  describe "adversarial / performance" do
    it "scans a huge near-miss body in linear time without matching (backtracking-bait)" do
      # 100k blocks of 'gqaaaaaaa!' = gq + 7 hex + '!': every block forces the full 8-byte
      # tail loop and fails only on the last byte. A million bytes must complete promptly and
      # find nothing (the scan is O(n), never quadratic).
      body = ("gqaaaaaaa!" * 100_000).to_slice
      elapsed = Time.measure do
        p = probe_body(body)
        p.canaries.should be_empty
      end
      elapsed.total_seconds.should be < 5.0
    end

    it "still finds a real canary buried in a large adversarial haystack" do
      body = ("gqaaaaaaa!" * 50_000 + "gqfeedface" + "gqaaaaaaa!" * 50_000).to_slice
      p = probe_body(body)
      p.reflects?("gqfeedface").should be_true
    end
  end
end
