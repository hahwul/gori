require "./spec_helper"

# `Utf8.tolerant` recompiles a rule regex with PCRE2_MATCH_INVALID_UTF so a body-sized subject
# is not re-validated on every match. On valid UTF-8 it must match exactly like the literal it
# wraps; the rule tables that run over bodies must actually carry it, or the win silently goes.
private def tolerant_available? : Bool
  Gori::Utf8::TOLERANT_OPTION != Regex::CompileOptions::None
end

describe "Gori::Utf8.tolerant" do
  it "keeps the source and the literal's own options" do
    rx = Gori::Utf8.tolerant(/^at foo$/im)
    rx.source.should eq("^at foo$")
    rx.options.includes?(Regex::CompileOptions::IGNORE_CASE).should be_true
    rx.options.includes?(Regex::CompileOptions::MULTILINE).should be_true
    rx.options.includes?(Regex::CompileOptions::MATCH_INVALID_UTF).should eq(tolerant_available?)
  end

  it "matches valid UTF-8 exactly like the plain literal" do
    subject = "머리말 caf\u{00e9}\nError: x at Foo.bar(Foo.java:12)\n끝 AKIA0123456789ABCDEF 한"
    [/\bat [\w.$]+\([\w]+\.java:\d+\)/, /^Error:/m, /CAFÉ/i, /\bAKIA[0-9A-Z]{16}\b/, /[가-힣]+/, /(?<=\s)\S+$/].each do |plain|
      tolerant = Gori::Utf8.tolerant(plain)
      tolerant.matches?(subject).should eq(plain.matches?(subject))
      subject.scan(tolerant).map { |m| {m.byte_begin(0), m[0]} }.should eq(subject.scan(plain).map { |m| {m.byte_begin(0), m[0]} })
    end
  end

  it "does not raise on an invalid subject, where the plain literal does" do
    bad = String.new(Bytes[0x41, 0x4b, 0x49, 0x41, 0xff, 0x20] + "AKIA0123456789ABCDEF".to_slice)
    plain = /\bAKIA[0-9A-Z]{16}\b/
    expect_raises(ArgumentError) { plain.matches?(bad) }
    if tolerant_available?
      Gori::Utf8.tolerant(plain).match(bad).try(&.[0]).should eq("AKIA0123456789ABCDEF")
    end
  end

  it "passes nil through for an optional prefilter slot" do
    Gori::Utf8.tolerant(nil).should be_nil
  end

  it "is applied to the body-scanning rule tables" do
    next unless tolerant_available?
    flag = Regex::CompileOptions::MATCH_INVALID_UTF
    Gori::Probe::Passive::BodyLeaks::ERROR_SIGNATURES.each { |(rx, _)| rx.options.includes?(flag).should be_true }
    Gori::Probe::Passive::Secrets::PATTERNS.each { |(rx, _)| rx.options.includes?(flag).should be_true }
    Gori::Probe::Passive::Secrets::JWT[0].options.includes?(flag).should be_true
    Gori::Probe::Passive::JsScan::SINKS.each { |(rx, _)| rx.options.includes?(flag).should be_true }
    Gori::Probe::Passive::Tech::FRAMEWORK_MARKERS.each { |(rx, _, _, _)| rx.options.includes?(flag).should be_true }
  end
end

# `Utf8.scrub` replaces `String#scrub` on every path that repairs a body before PCRE2 sees it,
# so it must produce the SAME bytes — a regex matches the repaired projection, and a different
# projection is a different answer. Checked against the stdlib on inputs built to hit every
# decode edge: truncated sequences at the end, overlongs, surrogates, > U+10FFFF, bare
# continuation bytes, NUL.
describe "Gori::Utf8.scrub" do
  edge = [0x41, 0x00, 0x7F, 0x80, 0xBF, 0xC0, 0xC1, 0xC2, 0xC3, 0xA9, 0xDF, 0xE0, 0xA0, 0x9F,
          0xE2, 0x82, 0xAC, 0xED, 0x9F, 0xEF, 0xF0, 0x90, 0x8F, 0x9F, 0x98, 0xF4, 0x8F, 0xF5, 0xFF].map(&.to_u8)

  it "is byte-identical to String#scrub on random input" do
    rng = Random.new(20260927)
    50_000.times do
      len = rng.rand(24)
      bytes = Bytes.new(len) { rng.rand(3) == 0 ? rng.rand(256).to_u8 : edge.sample(rng) }
      got = Gori::Utf8.scrub(bytes)
      want = String.new(bytes).scrub
      got.to_slice.should eq(want.to_slice), "#{bytes}"
      got.valid_encoding?.should be_true
      got.size.should eq(want.size)
    end
  end

  it "agrees on a large binary body and keeps valid text untouched" do
    big = Bytes.new(300_000) { |i| (i.to_i64 * 7919 % 251).to_u8 }
    Gori::Utf8.scrub(big).should eq(String.new(big).scrub)
    text = "caf\u{00e9} \u{1F600} 한글 plain".to_slice
    Gori::Utf8.scrub(text).to_slice.should eq(text)
    Gori::Utf8.text(text).to_slice.should eq(text)
    Gori::Utf8.text(Bytes.empty).should eq("")
  end

  it "gives text and subject the same repaired projection" do
    bytes = Bytes[0x61, 0xFF, 0xE2, 0x82, 0x62, 0xF0, 0x9F, 0x98]
    Gori::Utf8.text(bytes).should eq(String.new(bytes).scrub)
    Gori::Utf8.subject(String.new(bytes)).should eq(String.new(bytes).scrub)
  end
end
