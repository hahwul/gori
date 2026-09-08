require "../spec_helper"

private alias F = Gori::Fuzz

# `Matcher#build`'s per-response body scan, after it stopped paying for work it never needed.
#
# Three passes run over EVERY response of every run, and each was doing something more
# expensive than the answer required:
#
#   * `String.new(body).scrub` — the scrub is mandatory (PCRE2 RAISES on an invalid byte
#     rather than not matching), but `String#scrub` walks the whole string a CHARACTER at a
#     time and returns `self` when there was nothing to fix. `Gori::Utf8.text` asks
#     `valid_encoding?` — a DFA over the raw bytes — first. 681µs -> 81µs on a 216 KB body.
#   * `Regex#matches?` / `#match` take a CHARACTER index and convert it, and the conversion
#     computes `String#size`: a full UTF-8 character count of the body, to turn the constant 0
#     into byte 0. `matches_at_byte_index?` / `match_at_byte_index` skip it.
#   * `count_metrics` classified each byte with a four-way `==` chain; it is now a 256-entry
#     table plus a branchless word-transition. 147µs -> 80µs.
#
# All three are pure speed, so what has to be pinned is that the ANSWERS did not move — most
# of all on the bodies the slow spellings existed for. A body that is not valid UTF-8 is the
# one that must still be repaired rather than raise, and it is also the one whose word/line
# counts a byte-level scan could get wrong.
private def metrics_for(body : Bytes, head : String = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n") : F::Metrics
  raw = Gori::Repeater::Result.new(head.to_slice, body, nil, 1000_i64, nil)
  F::Matcher.new(keep_bodies: :none).metrics(raw)
end

private def build_for(body : Bytes, &) : F::Result
  m = F::Matcher.new(keep_bodies: :none)
  yield m
  raw = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, body, nil, 1000_i64, nil)
  job = F::Job.new(0_i64, ["p"], 0, "GET / HTTP/1.1\r\n\r\n".to_slice)
  m.build(job, raw)
end

describe "Fuzz::Matcher body scan" do
  describe "word/line counting" do
    it "counts the four whitespace bytes as separators and 0x0a as a line" do
      m = metrics_for("one two\tthree\nfour\r\nfive".to_slice)
      m.words.should eq(5)
      m.lines.should eq(2) # two 0x0a bytes; the CR is a separator but not a line
    end

    it "opens a word at the very first byte and closes one at the very last" do
      metrics_for("a".to_slice).words.should eq(1)
      metrics_for("  a  ".to_slice).words.should eq(1)
      metrics_for("a b".to_slice).words.should eq(2)
    end

    it "counts nothing for an empty or all-whitespace body" do
      metrics_for(Bytes.empty).words.should eq(0)
      metrics_for(Bytes.empty).lines.should eq(0)
      metrics_for(" \t\r\n".to_slice).words.should eq(0)
      metrics_for(" \t\r\n".to_slice).lines.should eq(1)
    end

    it "treats a UTF-8 continuation byte as part of a word, never as a separator" do
      # 0xA0 is NBSP's continuation byte and 0x20-ish nowhere: a scan that folded high bytes
      # into "whitespace" would report 2 words here.
      metrics_for("caf\u{00e9}\u{00a0}x".to_slice).words.should eq(1)
    end

    it "counts a body that is not valid UTF-8 without raising" do
      body = Bytes[0x61, 0x20, 0xff, 0xfe, 0x20, 0x62, 0x0a] # "a \xff\xfe b\n"
      m = metrics_for(body)
      m.words.should eq(3)
      m.lines.should eq(1)
      m.length.should eq(body.size.to_i64)
    end
  end

  describe "regex dimensions over the scrubbed body" do
    it "matches --mr from byte 0, exactly as a character-indexed match did" do
      body = "hello dolor sit amet".to_slice
      build_for(body, &.match_regex=(Regex.new("^hello"))).matched?.should be_true # anchored at the start
      build_for(body, &.match_regex=(Regex.new("amet$"))).matched?.should be_true  # and at the end
      build_for(body, &.match_regex=(Regex.new("nothing"))).matched?.should be_false
      build_for(Bytes.empty, &.match_regex=(Regex.new("x"))).matched?.should be_false # empty body, no raise
    end

    it "runs --mr and --extract over an INVALID-UTF-8 body instead of killing the worker" do
      # The reason the scrub is not optional: PCRE2 raises `ArgumentError: UTF-8 error` on
      # these bytes, and a raise here used to take the fuzz worker fiber with it.
      body = Bytes[0x69, 0x64, 0x3d, 0x37, 0x37, 0x0a, 0xff, 0xfe, 0x0a] # "id=77\n\xff\xfe\n"
      r = build_for(body) do |m|
        m.match_regex = Regex.new("id=[0-9]+")
        m.extract = Regex.new("id=([0-9]+)")
      end
      r.matched?.should be_true
      r.extracted.should eq("77")
    end

    it "filters on --fr over the same text the matcher saw" do
      body = "keep me\nDEBUG=1\n".to_slice
      build_for(body, &.filter_regex=(Regex.new("DEBUG"))).matched?.should be_false
      build_for(body, &.filter_regex=(Regex.new("ABSENT"))).matched?.should be_true
    end

    it "extracts group 1, falling back to the whole match when the pattern has no group" do
      body = "token: abc123\n".to_slice
      build_for(body, &.extract=(Regex.new("token: ([a-z0-9]+)"))).extracted.should eq("abc123")
      build_for(body, &.extract=(Regex.new("[a-z0-9]{6}"))).extracted.should eq("abc123")
    end
  end
end

describe Gori::Utf8 do
  it "returns a valid body unchanged, and repairs an invalid one" do
    Gori::Utf8.text("plain ascii".to_slice).should eq("plain ascii")
    Gori::Utf8.text("caf\u{00e9}".to_slice).should eq("caf\u{00e9}")
    # Same repair `String#scrub` performs — the fast path only decides WHETHER to run it.
    Gori::Utf8.text(Bytes[0x61, 0xff, 0x62]).should eq(String.new(Bytes[0x61, 0xff, 0x62]).scrub)
    Gori::Utf8.text(Bytes.empty).should eq("")
  end

  it "hands back the SAME String object when it is already valid" do
    s = "already fine"
    Gori::Utf8.subject(s).should be(s) # no allocation on the common path
  end
end
