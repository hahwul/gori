require "../spec_helper"

# `Matcher#spans` — the coordinate form of the same engine `Matcher#value` runs, added so a
# screenshot can paint over the cells a secret occupies rather than rewrite a string.
#
# The property worth holding it to is not "spans == what value did" (it is deliberately a
# SUPERSET; see the method's doc) but "every span names a region value would have replaced,
# and slices back to the text that was replaced".
private def with_salt(salt = "spec-salt", &)
  before = Gori::Redact.salt
  Gori::Redact.salt = salt
  begin
    yield
  ensure
    Gori::Redact.salt = before
  end
end

private def spans_of(text : String, profile = Gori::Redact::DEFAULT_PROFILE, **opts)
  Gori::Redact::Matcher.new(profile).spans(text, **opts)
end

private JWT = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"

describe Gori::Redact::Matcher do
  describe "#spans" do
    it "finds the built-in shapes, and each range slices back to what matched" do
      with_salt do
        text = "Authorization: Bearer #{JWT} end"
        found = spans_of(text)
        found.size.should eq(1)
        text[found[0].range].should eq(JWT)
        found[0].rule.should eq("builtin jwt")
        found[0].placeholder.should eq(Gori::Redact.placeholder(JWT))
      end
    end

    it "finds a PEM private key block across its newlines" do
      with_salt do
        pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIBOgIBAAJB\n-----END RSA PRIVATE KEY-----"
        text = "key:\n#{pem}\ndone"
        found = spans_of(text)
        found.size.should eq(1)
        text[found[0].range].should eq(pem)
        found[0].rule.should eq("builtin pem-private-key")
      end
    end

    it "finds the profile's field names through the text fallback rules" do
      with_salt do
        text = %(log line {"password": "hunter2"} and token=abc123 tail)
        found = spans_of(text)
        found.map { |s| text[s.range] }.should eq(["hunter2", "abc123"])
        found.map(&.rule).should eq(["json_field (text fallback)", "form_key (text fallback)"])
      end
    end

    it "names the same regions `value` replaces" do
      with_salt do
        text = %({"password": "hunter2"} #{JWT})
        matcher = Gori::Redact::Matcher.new(Gori::Redact::DEFAULT_PROFILE)
        replaced = matcher.value(text).text
        matcher.spans(text).each do |span|
          # The tag `value` wrote for this region is in its output, and the region this span
          # names is the text that produced it.
          replaced.should contain(span.placeholder)
          Gori::Redact.placeholder(text[span.range]).should eq(span.placeholder)
        end
      end
    end

    it "skips the derived name rules when asked for values only" do
      with_salt do
        text = %({"password": "hunter2"} Bearer #{JWT})
        spans_of(text, values_only: true).map(&.rule).should eq(["builtin jwt"])
        spans_of(text).map(&.rule).should contain("json_field (text fallback)")
      end
    end

    it "merges overlapping matches and leaves neighbours alone" do
      with_salt do
        # Two profile patterns that claim overlapping regions of the same run.
        profile = Gori::Redact::Profile.new(name: "p", patterns: ["abcdef", "cdefgh"])
        text = "xxabcdefghxx"
        found = spans_of(text, profile)
        found.size.should eq(1)
        text[found[0].range].should eq("abcdefgh")
        # …while two that merely touch stay two findings.
        two = spans_of("abcd", Gori::Redact::Profile.new(name: "p", patterns: ["ab", "cd"]))
        two.size.should eq(2)
        two.map { |s| "abcd"[s.range] }.sort!.should eq(["ab", "cd"])
      end
    end

    it "reports spans in order, left to right, whichever rule found them" do
      with_salt do
        text = "token=zzz then a jwt #{JWT} then password=qqq"
        starts = spans_of(text).map(&.range.begin)
        starts.size.should eq(3)
        starts.should eq(starts.dup.sort!)
      end
    end

    it "does not loop on a pattern that can match nothing" do
      with_salt do
        # A zero-width match never advances the regex cursor on its own; the walk steps one
        # character instead, and empty ranges are dropped rather than tagged.
        profile = Gori::Redact::Profile.new(name: "p", patterns: ["x*"])
        spans_of("yyy", profile).should be_empty
        found = spans_of("yxxy", profile)
        found.size.should eq(1)
        "yxxy"[found[0].range].should eq("xx")
      end
    end

    it "answers nothing for bytes that are not valid UTF-8" do
      with_salt do
        # PCRE2 RAISES on the first illegal byte rather than declining to match, and a
        # screenshot of a pane holding undecodable bytes must not take the process with it.
        text = String.new(Bytes[0x41, 0xff, 0x42])
        text.valid_encoding?.should be_false
        spans_of(text).should be_empty
      end
    end

    it "still names the region when no salt is armed to tag it with" do
      with_salt("") do
        found = spans_of("Bearer #{JWT}")
        found.size.should eq(1)
        # Redacted without a correlation tag beats left on the screen.
        found[0].placeholder.should eq("")
        found[0].rule.should eq("builtin jwt")
      end
    end

    it "answers nothing for a profile with no rules but the built-ins, over clean text" do
      with_salt do
        spans_of("nothing secret here at all").should be_empty
      end
    end
  end
end
