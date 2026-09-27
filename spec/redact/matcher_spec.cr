require "../spec_helper"
require "../../src/gori/redact"

# `Matcher#replace_all` walks BYTE offsets (match_at_byte_index / byte_begin / byte_end) so a
# non-ASCII body is not re-walked from the start on every match. These examples hold it to the
# CHARACTER-offset algorithm it replaced, kept below verbatim as the oracle: same output, same
# hits, on the inputs where the two could plausibly disagree — multibyte text around and
# inside a match, and a zero-width pattern that has to step over a multibyte character.

private def with_salt(salt = "spec-salt", &)
  before = Gori::Redact.salt
  Gori::Redact.salt = salt
  begin
    yield
  ensure
    Gori::Redact.salt = before
  end
end

# The pre-byte-offset `replace_all`, unchanged apart from being a free function.
private def oracle_replace_all(text : String, rx : Regex, rule : String, path : String,
                               hits : Array(Gori::Redact::Hit)) : String
  md = rx.match(text)
  return text unless md
  clean = String::Builder.new
  pos = 0
  while md
    group = md[1]?.nil? ? 0 : 1
    start = md.begin(group)
    stop = md.end(group)
    whole_end = md.end(0)
    before = pos
    value = text[start...stop]
    if value.empty?
      clean << text[before...whole_end]
    else
      clean << text[before...start]
      ph = Gori::Redact.placeholder(value)
      hits << Gori::Redact::Hit.new(path, rule, ph)
      clean << ph
      clean << text[stop...whole_end] if whole_end > stop
    end
    if whole_end > before
      pos = whole_end
    else
      clean << text[before, 1] if before < text.size
      pos = before + 1
    end
    break if pos > text.size
    md = rx.match(text, pos)
  end
  clean << text[pos..] if pos <= text.size
  clean.to_s
end

# The plain-text pass (`Matcher#plain`) as the oracle would have computed it: every text rule,
# then every value pattern, in the matcher's own order.
private def oracle_plain(m : Gori::Redact::Matcher, text : String) : {String, Array(Gori::Redact::Hit)}
  hits = [] of Gori::Redact::Hit
  clean = text
  (m.@text_rules + m.@patterns).each { |(rx, rule)| clean = oracle_replace_all(clean, rx, rule, "body", hits) }
  {clean, hits}
end

private def same_as_oracle(profile : Gori::Redact::Profile, text : String) : Gori::Redact::Result
  m = Gori::Redact::Matcher.new(profile)
  r = m.body(text.to_slice, "text/plain")
  want_text, want_hits = oracle_plain(m, text)
  r.text.should eq(want_text)
  r.hits.should eq(want_hits)
  r.text.valid_encoding?.should be_true
  r
end

describe Gori::Redact::Matcher do
  describe "replace_all over multibyte text" do
    it "redacts a field whose name, value and surroundings are non-ASCII" do
      with_salt do
        prof = Gori::Redact::Profile.new("p", json_fields: ["token", "비밀번호"])
        text = String.build do |io|
          io << "[" # not JSON: the text fallback is what runs
          20.times do |i|
            io << %({"이름":"사용자#{i}","token":"토큰-#{i}-é","비밀번호":"암호#{i}","bio":"한국어 텍스트 😀"},)
          end
          io << %({"token":"잘린 값)
        end
        r = same_as_oracle(prof, text)
        r.count.should eq(41)
        r.text.should_not contain("토큰-3-é")
        r.text.should contain("사용자3")
      end
    end

    it "takes capture group 1 at the right byte offsets after multibyte context" do
      with_salt do
        prof = Gori::Redact::Profile.new("p", patterns: ["계정=(\\d+)"])
        r = same_as_oracle(prof, "앞 계정=12345 뒤 계정=67 끝😀")
        r.text.should eq("앞 계정=#{Gori::Redact.placeholder("12345")} 뒤 계정=#{Gori::Redact.placeholder("67")} 끝😀")
      end
    end

    it "steps a zero-width match over a whole multibyte character and copies it" do
      with_salt do
        # `x*` matches empty at every position that is not an `x`: each step must advance one
        # CHARACTER (1-4 bytes) and copy it, or the output loses or splits a character.
        ["가나x다", "😀x😀xx", "éxé", "x한", "", "한"].each do |text|
          prof = Gori::Redact::Profile.new("p", patterns: ["x*"])
          r = same_as_oracle(prof, text)
          r.text.gsub(/\[REDACTED:[0-9a-f]+\]/, "").should eq(text.delete('x'))
        end
      end
    end

    it "resumes after a zero-width match on a character boundary, never inside one" do
      with_salt do
        # A pattern that looks BEHIND the cursor (`\b` here) is where a one-byte step would
        # show: resumed mid-character under NO_UTF_CHECK, PCRE2 reads a torn sequence — which
        # has been seen to crash, not just mismatch.
        ["\\b\\d*", "(?<![가-힣])\\d*"].each do |pat|
          prof = Gori::Redact::Profile.new("p", patterns: [pat])
          same_as_oracle(prof, "가나 12 다😀3 é45 끝")
        end
      end
    end

    it "copies a zero-width group through unchanged between multibyte characters" do
      with_salt do
        prof = Gori::Redact::Profile.new("p", patterns: ["키=(\\d*)"])
        r = same_as_oracle(prof, "키= 가 키=9 나 키=")
        r.count.should eq(1)
      end
    end

    it "does not raise on a lookbehind group that starts before the previous match's end" do
      with_salt do
        prof = Gori::Redact::Profile.new("p", patterns: ["(?<=(ab))a"])
        r = Gori::Redact::Matcher.new(prof).body("ababa".to_slice, "text/plain")
        ph = Gori::Redact.placeholder("ab")
        r.text.should eq("#{ph}a#{ph}a")
        r.count.should eq(2)
      end
    end

    it "does not write a lookahead group's secret back out after its placeholder" do
      with_salt do
        prof = Gori::Redact::Profile.new("p", patterns: ["key(?==(\\w+))"])
        r = Gori::Redact::Matcher.new(prof).body("key=SECRET&x=1".to_slice, "text/plain")
        r.text.should eq("key=#{Gori::Redact.placeholder("SECRET")}&x=1")
      end
    end

    it "matches a large non-ASCII body with many hits exactly" do
      with_salt do
        prof = Gori::Redact::Profile.new("p", json_fields: ["password", "token", "secret"])
        text = String.build do |io|
          io << "["
          300.times { |i| io << %({"id":#{i},"name":"사용자#{i}","bio":") << ("가" * 50) << %(","token":"tk_#{i}"},) }
          io << "{}"
        end
        same_as_oracle(prof, text).count.should eq(300)
      end
    end
  end

  # `\C` matches one code unit, so a match could end inside a multibyte character and the next
  # NO_UTF_CHECK match would start mid-character — undefined behaviour. Refused up front.
  describe "a \\C pattern" do
    it "is refused into pattern_errors, while an escaped backslash before C is not" do
      m = Gori::Redact::Matcher.new(Gori::Redact::Profile.new(name: "p", patterns: ["a\\C", "x\\\\C", "\\\\\\C"]))
      m.pattern_errors.size.should eq(2)
      m.pattern_errors[0].should start_with("a\\C:")
      m.pattern_errors[1].should start_with("\\\\\\C:")
      Gori::Redact::Matcher.single_code_unit?("x\\\\C").should be_false
    end
  end
end
