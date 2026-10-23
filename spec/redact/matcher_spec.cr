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
  # A JSON-shaped body the parser refuses (an integer past Int64, a cut at the capture cap)
  # drops to the text pass, which used to see only `"name":"string"` — so the default profile
  # sent numeric and object values out in clear that the parsed path redacts.
  describe "text fallback on a JSON body that will not parse" do
    it "redacts named numeric fields, keeping unnamed ones" do
      with_salt do
        body = %({"pin":1234,"card_number":4111111111111111,"id":123456789012345678901234})
        r = Gori::Redact::Matcher.new(Gori::Redact::DEFAULT_PROFILE).body(body.to_slice, "application/json")
        r.text.should_not contain("1234,")
        r.text.should_not contain("4111111111111111")
        r.text.should contain(%("pin":#{Gori::Redact.placeholder("1234")}))
        r.text.should contain("123456789012345678901234") # `id` is not a named field
        r.count.should eq(2)
      end
    end

    it "redacts a named object value through its matching close" do
      with_salt do
        body = %({"credentials":{"user":"a","nested":{"k":"}"},"n":[1,{"x":2}]},"after":1,"big":1e999})
        r = Gori::Redact::Matcher.new(Gori::Redact::DEFAULT_PROFILE).body(body.to_slice, "application/json")
        r.text.should_not contain(%("user":"a"))
        r.text.should_not contain(%("x":2))
        r.text.should contain(%(,"after":1,"big":1e999}))
      end
    end

    it "redacts a named container cut off at the capture cap, to end of subject" do
      with_salt do
        body = %({"ok":true,"credentials":{"password":"hunter2","otp":[12,)
        r = Gori::Redact::Matcher.new(Gori::Redact::DEFAULT_PROFILE).body(body.to_slice, "application/json")
        r.text.should_not contain("hunter2")
        r.text.should_not contain("12,")
        r.text.should start_with(%({"ok":true,"credentials":[REDACTED:))
      end
    end

    it "keeps a string value cut mid-way redacted as before" do
      with_salt do
        r = Gori::Redact::Matcher.new(Gori::Redact::DEFAULT_PROFILE).body(%({"token":"abc).to_slice, "application/json")
        r.text.should eq(%({"token":"#{Gori::Redact.placeholder("abc")}))
      end
    end
  end

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

    # The text fallback's per-byte value pattern hit PCRE2's JIT stack limit near 60 KB, and
    # the raise dropped the redaction of exactly the large secret it exists for.
    it "redacts a ~60 KB field value through the text fallback" do
      with_salt do
        prof = Gori::Redact::Profile.new("p", json_fields: ["token"])
        secret = "s" * 60_000
        r = Gori::Redact::Matcher.new(prof).body(%([{"token":"#{secret}"}).to_slice, "text/plain")
        r.count.should eq(1)
        r.text.should_not contain(secret)
      end
    end

    # An escape-dense value still outruns the JIT stack (the group repeats per escape). The rule
    # cannot finish, so the value is withheld whole instead of the read raising Regex::Error.
    it "withholds a value too escape-dense to scan instead of raising" do
      with_salt do
        prof = Gori::Redact::Profile.new("p", json_fields: ["token"])
        body = %({"token":") + "\\n" * 50_000
        r = Gori::Redact::Matcher.new(prof).body(body.to_slice, "text/html")
        r.text.should contain("too complex to scan")
        r.count.should eq(1)
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

  # A name is compiled into the text-fallback alternation, and `Regex.new` raises on a source
  # that is not UTF-8 — so one such key (a `--form-key=$'a\xff'`, or a hand-edited settings.json
  # that JSON round-trips raw) took down every export the profile was used for. Refused into
  # pattern_errors like a bad regex; the other names keep working, fallback included.
  describe "a non-UTF-8 field or form key" do
    bad = String.new(Bytes[0x61, 0xFF])

    it "is refused into pattern_errors and the remaining keys still redact" do
      with_salt do
        m = Gori::Redact::Matcher.new(Gori::Redact::Profile.new(name: "p",
          json_fields: [bad, "token"], form_keys: [bad, "password"]))
        m.pattern_errors.size.should eq(2)
        m.pattern_errors.each(&.valid_encoding?.should(be_true))
        m.body("password=s3cret".to_slice, "application/x-www-form-urlencoded").text.should_not contain("s3cret")
        m.body("x password=s3cret".to_slice, "text/plain").text.should_not contain("s3cret")
        m.body(%({"token":"tk1).to_slice, "application/json").text.should_not contain("tk1")
      end
    end

    # The key is still a NAME the structural walk matches: `a%FF` form-decodes to it. Only the
    # text-fallback rule, which matches undecoded text, cannot hold it.
    it "still redacts a form body whose decoded key is that name" do
      with_salt do
        m = Gori::Redact::Matcher.new(Gori::Redact::Profile.new(name: "p", form_keys: [bad]))
        m.body("a%FF=s3cret".to_slice, "application/x-www-form-urlencoded").text.should_not contain("s3cret")
        m.pattern_errors.should eq([%(form key "a\\xFF" is not valid UTF-8, so the text fallback for unparsed bodies cannot match it)])
        m.body("x=1".to_slice, "text/plain").text.should eq("x=1")
      end
    end

    it "is refused the same way when it comes back from persisted JSON" do
      raw = String.new(Bytes[0x5B, 0x7B] + %("name":"p","form_keys":[").to_slice + Bytes[0x61, 0xFF] + %(","pin"]}]).to_slice)
      profiles = Gori::Redact::Profile.list_from_json(JSON.parse(raw))
      Gori::Redact::Matcher.new(profiles.first).pattern_errors.size.should eq(1)
    end
  end
end
