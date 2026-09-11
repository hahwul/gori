require "./spec_helper"
require "../src/gori/redact"

# The placeholder tag is an HMAC under a per-install salt (Redact.salt), which is process-wide
# state Settings owns. Every example pins a known salt so the tags below are reproducible, and
# restores what it found so a suite that loaded real settings is not left holding a test salt.
private def with_salt(salt = "spec-salt", &)
  before = Gori::Redact.salt
  Gori::Redact.salt = salt
  begin
    yield
  ensure
    Gori::Redact.salt = before
  end
end

private def matcher(profile : Gori::Redact::Profile)
  Gori::Redact::Matcher.new(profile)
end

private def body(profile, text : String, content_type : String? = nil)
  matcher(profile).body(text.to_slice, content_type)
end

describe Gori::Redact do
  describe "placeholders" do
    it "is deterministic for equal values and differs for unequal ones" do
      with_salt do
        a = Gori::Redact.placeholder("hunter2")
        b = Gori::Redact.placeholder("hunter2")
        c = Gori::Redact.placeholder("hunter3")
        a.should eq b
        a.should_not eq c
        a.should match(/\A\[REDACTED:[0-9a-f]{8}\]\z/)
      end
    end

    it "changes with the salt, so one install's tags mean nothing to another" do
      one = with_salt("a") { Gori::Redact.placeholder("hunter2") }
      two = with_salt("b") { Gori::Redact.placeholder("hunter2") }
      one.should_not eq two
    end

    it "refuses rather than falling back to an unsalted digest" do
      with_salt("") do
        expect_raises(Gori::Redact::SaltMissing) { Gori::Redact.placeholder("x") }
      end
    end
  end

  describe "JSON bodies" do
    it "replaces a matching field at any depth and leaves the rest alone" do
      with_salt do
        r = body(Gori::Redact::DEFAULT_PROFILE,
          %({"user":{"name":"ada","password":"hunter2"},"ok":true}), "application/json")
        r.shape.should eq Gori::Redact::Shape::Json
        r.count.should eq 1
        parsed = JSON.parse(r.text)
        parsed["user"]["name"].as_s.should eq "ada"
        parsed["ok"].as_bool.should be_true
        parsed["user"]["password"].as_s.should eq Gori::Redact.placeholder("hunter2")
        r.hits.first.path.should eq "/user/password"
        r.hits.first.rule.should eq "json_field password"
      end
    end

    it "matches the field name case-insensitively" do
      with_salt do
        r = body(Gori::Redact::DEFAULT_PROFILE, %({"Password":"x"}), "application/json")
        r.count.should eq 1
      end
    end

    it "correlates equal values across both sides of a document" do
      with_salt do
        r = body(Gori::Redact::DEFAULT_PROFILE,
          %({"a":{"token":"t1"},"b":{"token":"t1"},"c":{"token":"t2"}}), "application/json")
        p = JSON.parse(r.text)
        p["a"]["token"].should eq p["b"]["token"]
        p["a"]["token"].should_not eq p["c"]["token"]
      end
    end

    it "takes a whole subtree when the match lands on a container" do
      with_salt do
        r = body(Gori::Redact::Profile.new("p", json_fields: ["credentials"]),
          %({"credentials":{"u":"a","p":"b"},"keep":1}), "application/json")
        JSON.parse(r.text)["credentials"].as_s.should start_with "[REDACTED:"
        JSON.parse(r.text)["keep"].as_i.should eq 1
      end
    end

    it "honours a JSON Pointer at exactly one location" do
      with_salt do
        prof = Gori::Redact::Profile.new("p", json_pointers: ["/data/id"])
        r = body(prof, %({"data":{"id":"secret"},"other":{"id":"kept"}}), "application/json")
        r.count.should eq 1
        p = JSON.parse(r.text)
        p["other"]["id"].as_s.should eq "kept"
        r.hits.first.rule.should eq "json_pointer /data/id"
      end
    end

    it "reads the RFC 6901 `-` token as any array index" do
      with_salt do
        prof = Gori::Redact::Profile.new("p", json_pointers: ["/users/-/token"])
        r = body(prof, %({"users":[{"token":"a"},{"token":"b"}]}), "application/json")
        r.count.should eq 2
        r.hits.map(&.path).should eq ["/users/0/token", "/users/1/token"]
      end
    end

    it "unescapes ~1 and ~0 in a pointer" do
      with_salt do
        prof = Gori::Redact::Profile.new("p", json_pointers: ["/a~1b/c~0d"])
        r = body(prof, %({"a/b":{"c~d":"x"}}), "application/json")
        r.count.should eq 1
      end
    end

    it "finds a JWT inside a string leaf no field name covers" do
      with_salt do
        jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.c2ln"
        r = body(Gori::Redact::Profile.new("p"), %({"note":"use #{jwt} please"}), "application/json")
        r.count.should eq 1
        r.hits.first.rule.should eq "builtin jwt"
        JSON.parse(r.text)["note"].as_s.should eq "use #{Gori::Redact.placeholder(jwt)} please"
      end
    end

    it "falls back to the text pass when the body does not parse" do
      with_salt do
        r = body(Gori::Redact::DEFAULT_PROFILE, %({"password":"hunter2","tru), "application/json")
        r.shape.should eq Gori::Redact::Shape::Text
        r.fell_back.should be_true
        r.count.should eq 1
        r.text.should_not contain "hunter2"
      end
    end

    it "sniffs an undeclared JSON body" do
      with_salt do
        r = body(Gori::Redact::DEFAULT_PROFILE, %(  {"password":"x"}), nil)
        r.shape.should eq Gori::Redact::Shape::Json
      end
    end

    it "believes a declared non-JSON type over the opening brace" do
      with_salt do
        r = body(Gori::Redact::DEFAULT_PROFILE, %({"password":"x"}), "text/html")
        r.shape.should eq Gori::Redact::Shape::Text
      end
    end
  end

  describe "form bodies" do
    it "replaces a matching key and keeps every other segment byte-for-byte" do
      with_salt do
        r = body(Gori::Redact::DEFAULT_PROFILE, "user=ada&password=hunter2&keep=1",
          "application/x-www-form-urlencoded")
        r.shape.should eq Gori::Redact::Shape::Form
        r.count.should eq 1
        r.text.should start_with "user=ada&password=%5BREDACTED%3A"
        r.text.should end_with "&keep=1"
        URI.decode_www_form(r.text.split('&')[1].split('=', 2)[1])
          .should eq Gori::Redact.placeholder("hunter2")
      end
    end

    it "decodes the key before matching it" do
      with_salt do
        r = body(Gori::Redact::DEFAULT_PROFILE, "pass%77ord=x", "application/x-www-form-urlencoded")
        r.count.should eq 1
      end
    end

    it "keeps a segment with no '=' and the empty segments a '&&' leaves" do
      with_salt do
        r = body(Gori::Redact::DEFAULT_PROFILE, "bare&&a=1", "application/x-www-form-urlencoded")
        r.text.should eq "bare&&a=1"
        r.count.should eq 0
      end
    end
  end

  describe "the conservative text pass" do
    it "re-expresses field names as text rules over an unstructured body" do
      with_salt do
        r = body(Gori::Redact::DEFAULT_PROFILE, %(<x>"token": "abc123"</x>), "text/xml")
        r.shape.should eq Gori::Redact::Shape::Text
        r.count.should eq 1
        r.text.should_not contain "abc123"
      end
    end

    it "takes a PEM private key block whole" do
      with_salt do
        pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIBOgIB\n-----END RSA PRIVATE KEY-----"
        r = body(Gori::Redact::Profile.new("p"), "key:\n#{pem}\ndone", "text/plain")
        r.count.should eq 1
        r.text.should_not contain "MIIBOgIB"
        r.text.should end_with "\ndone"
      end
    end

    it "replaces capture group 1 and keeps the context that found it" do
      with_salt do
        prof = Gori::Redact::Profile.new("p", patterns: ["account=(\\d+)"])
        r = body(prof, "account=12345 account=12345 other=9", "text/plain")
        r.count.should eq 2
        r.text.should start_with "account=[REDACTED:"
        r.text.should end_with " other=9"
        r.text.split(' ')[0].should eq r.text.split(' ')[1]
      end
    end

    it "replaces the whole match when the pattern has no group" do
      with_salt do
        prof = Gori::Redact::Profile.new("p", patterns: ["SEC-[0-9]+"])
        r = body(prof, "id SEC-42 end", "text/plain")
        r.text.should eq "id #{Gori::Redact.placeholder("SEC-42")} end"
      end
    end

    it "reports a pattern that will not compile instead of aborting the export" do
      m = matcher(Gori::Redact::Profile.new("p", patterns: ["([unclosed", "ok[0-9]"]))
      m.pattern_errors.size.should eq 1
      m.pattern_errors.first.should start_with "([unclosed: "
      with_salt { m.body("ok1".to_slice, "text/plain").count.should eq 1 }
    end
  end

  describe "bodies that cannot be sanitized" do
    it "withholds a body that is not valid UTF-8" do
      with_salt do
        r = Gori::Redact::Matcher.new(Gori::Redact::DEFAULT_PROFILE)
          .body(Bytes[0x89, 0x50, 0x4e, 0xff], "image/png")
        r.shape.should eq Gori::Redact::Shape::Binary
        r.withheld?.should be_true
        r.count.should eq 1
        r.text.should contain "4 bytes withheld"
      end
    end

    it "withholds a multipart body whole" do
      with_salt do
        r = body(Gori::Redact::DEFAULT_PROFILE, "--b\r\nx\r\n--b--",
          "multipart/form-data; boundary=b")
        r.shape.should eq Gori::Redact::Shape::Multipart
        r.withheld?.should be_true
      end
    end

    it "leaves an empty body empty and counts nothing" do
      r = matcher(Gori::Redact::DEFAULT_PROFILE).body(nil)
      r.shape.should eq Gori::Redact::Shape::Empty
      r.text.should eq ""
      r.redacted?.should be_false
    end
  end
end

describe "a pattern that can match nothing" do
  it "does not drop a byte, or loop, on a zero-width match" do
    with_salt do
      prof = Gori::Redact::Profile.new("p", patterns: ["x*"])
      r = body(prof, "abxc", "text/plain")
      # Every character survives; only the real `x` run is replaced.
      r.text.should eq "ab#{Gori::Redact.placeholder("x")}c"
      r.count.should eq 1
    end
  end

  it "does not drop a byte when only the GROUP is zero-width" do
    with_salt do
      prof = Gori::Redact::Profile.new("p", patterns: ["a(b*)c"])
      r = body(prof, "ac ok abbc", "text/plain")
      r.text.should eq "ac ok a#{Gori::Redact.placeholder("bb")}c"
      r.count.should eq 1
    end
  end
end

describe "bytes the regex engine must never see" do
  it "withholds a non-UTF-8 value rather than letting PCRE2 raise on it" do
    with_salt do
      r = matcher(Gori::Redact::DEFAULT_PROFILE).value(String.new(Bytes[0x22, 0xff, 0x80]))
      r.shape.should eq Gori::Redact::Shape::Binary
      r.withheld?.should be_true
    end
  end

  it "leaves a form value whose percent-decoding is not UTF-8 exactly as it lies" do
    with_salt do
      prof = Gori::Redact::Profile.new("p", form_keys: ["pw"], patterns: ["[0-9]+"])
      r = body(prof, "blob=%FF%FE1&pw=secret", "application/x-www-form-urlencoded")
      # The named key still goes; the unnamed, unscannable one is untouched and does not raise.
      r.text.should start_with "blob=%FF%FE1&pw="
      r.count.should eq 1
    end
  end
end
