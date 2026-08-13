require "./spec_helper"
require "json"

# GOLDEN VECTORS — every cookie below was minted by the REAL library (Flask 3.1 /
# itsdangerous 2.2, Django 6.0, and Rack's documented Base64-Marshal+HMAC scheme) under
# secret "s3cr3t-key" and a fixed clock, then pasted here. They are the ground truth for
# interoperability: if the engine's crypto drifts, `.verify` on these stops returning true.
# Regenerating: see the venv script in the PR that added this file.
private SECRET = "s3cr3t-key"

# {"user_id":42,"admin":true,"name":"alice"}
private FLASK             = "eyJ1c2VyX2lkIjo0MiwiYWRtaW4iOnRydWUsIm5hbWUiOiJhbGljZSJ9.am71Yg.gd2MWkbBsGdhg4rScrYWBdGoj-Q"
private FLASK_COMPRESSED  = ".eJyrVkpJLElUslJyHAWDCijpKBXl56QCY6a0OLVIqRYAhzxtRA.am75Tw.zkCxjFhDiNxL_5Iyoq1GoJNlUBk"
private DJANGO            = "eyJ1c2VyX2lkIjo0MiwiYWRtaW4iOnRydWUsIm5hbWUiOiJhbGljZSJ9:1wqQs6:ofPm07XfGfVUimPfVs9Bdy5M7H0cxBS_265YiN3lQsY"
private DJANGO_SALTED     = "eyJ1c2VyX2lkIjo0MiwiYWRtaW4iOnRydWUsIm5hbWUiOiJhbGljZSJ9:1wqQs6:9xbI_dkuxU80EIQKjrNucKXsYJ2IMbwYIy8_Y6FkKyw" # salt "my.custom.salt"
private DJANGO_COMPRESSED = ".eJyrVkpJLElUslJyHAWDCijpKBXl56QCY6a0OLVIqRYAhzxtRA:1wqR8J:8cg4YrNnvAr1qe7zFsz_Lu83Y4LH95Sq0A7AW1M3RqE"
private DJANGO_SHA1       = "eyJhIjoxfQ:1wqR8T:8BooTFI1B28NGHSf42JyGt1Or-0" # algorithm sha1, payload {"a":1}
private RACK              = "BAh7BkkiCXVzZXIGOgZFVEkiCmFsaWNlBjsAVA==--9156ef2ac6989f37064259efa196770c3ee052ca"

describe Gori::Cookie do
  describe ".detect" do
    it "distinguishes the three formats by punctuation" do
      Gori::Cookie.detect(FLASK).should eq("flask")
      Gori::Cookie.detect(DJANGO).should eq("django")
      Gori::Cookie.detect(RACK).should eq("rack")
    end

    it "returns nil for something that is none of them" do
      Gori::Cookie.detect("not-a-cookie").should be_nil
    end

    it "prefers Rack over Django when a '--' hex tail is present" do
      # Rack's `--<40 hex>` is the strongest signal; check it wins the ordering.
      Gori::Cookie.detect(RACK).should eq("rack")
    end

    it "detects a Flask/Django cookie whose base64url payload contains a '--' run" do
      # base64url's alphabet includes '-', so two adjacent '-' occur naturally in ~2% of
      # payloads. Rejecting them as "Rack punctuation" made real cookies undetectable, and
      # every surface (CLI/MCP/TUI) then aborts with "unrecognized cookie format" — even
      # when the operator supplies the right secret. Rack is still disambiguated by being
      # tested first and by its 40-hex tail, which neither of these has.
      Gori::Cookie.detect("eyJhIjoxfQ--x.am71Yg.gd2MWkbBsGdhg4rScrYWBdGoj-Q").should eq("flask")
      Gori::Cookie.detect("eyJhIjoxfQ--x:1wqQs6:ofPm07XfGfVUimPfVs9Bdy5M7H0").should eq("django")
    end
  end

  describe "shared helpers" do
    it "base62 round-trips a unix second" do
      Gori::Cookie.base62_encode(1785656674_i64).should eq("1wqQs6")
      Gori::Cookie.base62_decode("1wqQs6").should eq(1785656674_i64)
    end

    it "base62_decode answers nil (not OverflowError) on a segment past Int64" do
      # A crafted Django cookie can carry an arbitrarily long timestamp segment. The
      # accumulator is Int64 and Crystal's arithmetic is overflow-checked, so this used to
      # raise out of decode_text/decode_json and escape as an unhandled crash. `nil` is the
      # channel the callers already speak — they render "(invalid base62 …)" — and it is
      # what the non-base62 character case has always returned. Same contract as the
      # `unix_to_s` rescue immediately below it in the source.
      Gori::Cookie.base62_decode("zzzzzzzzzzzzzzzzzzzzzzzz").should be_nil
      Gori::Cookie.base62_decode("!!!").should be_nil
    end

    it "decodes a Django cookie carrying an oversized timestamp instead of crashing" do
      oversized = "eyJhIjoxfQ:zzzzzzzzzzzzzzzzzzzzzzzz:8BooTFI1B28NGHSf42JyGt1Or-0"
      Gori::Cookie.decode(oversized, "django").should contain("invalid base62")
      Gori::Cookie.decode_json(oversized, "django").should contain(%("timestamp":null))
    end

    it "int_to_b64 is the itsdangerous timestamp codec (plain unix, minimal big-endian)" do
      # The FLASK vector's timestamp segment decodes back to a real unix second.
      seg = FLASK.split('.')[1]
      Gori::Cookie.int_to_b64(Gori::Cookie.b64_to_int(seg)).should eq(seg)
    end

    it "b64_to_int? answers nil (not raise) on an invalid or oversized segment" do
      # The tolerant DECODE sibling of b64_to_int, mirroring the nil contract base62_decode
      # already gives Django, so a mangled Flask timestamp renders "(invalid …)"/null instead
      # of raising CookieError and refusing the whole cookie.
      seg = FLASK.split('.')[1]
      Gori::Cookie.b64_to_int?(seg).should eq(Gori::Cookie.b64_to_int(seg)) # a real ts still decodes
      Gori::Cookie.b64_to_int?("@@@bad@@@").should be_nil                   # not valid base64
      Gori::Cookie.b64_to_int?("AAAAAAAAAAAAAAAA").should be_nil            # decodes to > 8 bytes
    end

    it "secure_compare is length- and content-exact" do
      Gori::Cookie.secure_compare("abc", "abc").should be_true
      Gori::Cookie.secure_compare("abc", "abd").should be_false
      Gori::Cookie.secure_compare("abc", "ab").should be_false
    end
  end

  describe "Flask" do
    it "verifies the golden cookie with the right secret, rejects a wrong one" do
      Gori::Cookie.verify(FLASK, SECRET).should be_true
      Gori::Cookie.verify(FLASK, "wrong").should be_false
    end

    it "re-signs byte-identically (round-trip) with the correct secret" do
      Gori::Cookie::Flask.resign(FLASK, SECRET).should eq(FLASK)
    end

    it "decodes the payload, timestamp, and signature" do
      j = JSON.parse(Gori::Cookie.decode_json(FLASK))
      j["format"].as_s.should eq("flask")
      j["payload"]["user_id"].as_i.should eq(42)
      j["payload"]["admin"].as_bool.should be_true
      j["timestamp"].as_i64.should eq(1785656674)
      j["compressed"].as_bool.should be_false
    end

    it "decodes a zlib-compressed payload (leading '.')" do
      j = JSON.parse(Gori::Cookie.decode_json(FLASK_COMPRESSED))
      j["compressed"].as_bool.should be_true
      j["payload"]["role"].as_s.should eq("user")
      Gori::Cookie.verify(FLASK_COMPRESSED, SECRET).should be_true
    end

    it "forges a fresh cookie that verifies under the same secret" do
      forged = Gori::Cookie::Flask.forge(%({"admin":true}), SECRET, 1785656674_i64)
      Gori::Cookie::Flask.verify(forged, SECRET).should be_true
      Gori::Cookie::Flask.verify(forged, "other").should be_false
    end

    it "decodes a cookie with a mangled timestamp instead of crashing (Django parity)" do
      # A crafted timestamp segment must not refuse the whole cookie: the payload and
      # signature are perfectly readable, and Django already degrades this gracefully.
      bad_ts = FLASK.sub(FLASK.split('.')[1], "@@@bad@@@")
      txt = Gori::Cookie.decode(bad_ts, "flask")
      txt.should contain("invalid timestamp")
      txt.should contain("alice") # the payload is still shown
      JSON.parse(Gori::Cookie.decode_json(bad_ts, "flask"))["timestamp"].raw.should be_nil
    end
  end

  describe "Django" do
    it "verifies with the default salt + sha256, rejects a wrong secret" do
      Gori::Cookie.verify(DJANGO, SECRET).should be_true
      Gori::Cookie.verify(DJANGO, "wrong").should be_false
    end

    it "re-signs byte-identically" do
      Gori::Cookie::Django.resign(DJANGO, SECRET).should eq(DJANGO)
    end

    it "honors a custom salt (the signed-with-salt variant)" do
      # Same payload+ts, different salt → different signature; each verifies under its own.
      Gori::Cookie::Django.verify(DJANGO_SALTED, SECRET, salt: "my.custom.salt").should be_true
      Gori::Cookie::Django.verify(DJANGO_SALTED, SECRET).should be_false # default salt must fail
    end

    it "honors the sha1 algorithm variant" do
      Gori::Cookie::Django.verify(DJANGO_SHA1, SECRET, algorithm: "sha1").should be_true
      Gori::Cookie::Django.verify(DJANGO_SHA1, SECRET, algorithm: "sha256").should be_false
    end

    it "decodes a zlib-compressed payload" do
      j = JSON.parse(Gori::Cookie.decode_json(DJANGO_COMPRESSED))
      j["compressed"].as_bool.should be_true
      j["payload"]["role"].as_s.should eq("user")
    end

    it "forges a fresh cookie that verifies" do
      forged = Gori::Cookie::Django.forge(%({"admin":true}), SECRET, 1785656674_i64)
      Gori::Cookie::Django.verify(forged, SECRET).should be_true
    end
  end

  describe "Rack" do
    it "verifies the golden cookie, rejects a wrong secret" do
      Gori::Cookie.verify(RACK, SECRET).should be_true
      Gori::Cookie.verify(RACK, "wrong").should be_false
    end

    it "re-signs byte-identically" do
      Gori::Cookie::Rack.resign(RACK, SECRET).should eq(RACK)
    end

    it "surfaces the opaque marshalled value as hex + ascii, never verifying" do
      j = JSON.parse(Gori::Cookie.decode_json(RACK))
      j["format"].as_s.should eq("rack")
      j["value_size"].as_i.should eq(28)
      j["signature"].as_s.should eq("9156ef2ac6989f37064259efa196770c3ee052ca")
    end

    it "forges from an opaque base64 value + secret" do
      value = RACK.split("--").first
      Gori::Cookie::Rack.forge(value, SECRET).should eq(RACK) # same value+secret → same cookie
    end

    # A cookie is bytes lifted verbatim off the wire, so the tail after "--" need not be valid
    # UTF-8. The hex-tail test used to be a Regex, and PCRE2 RAISES on an invalid byte instead
    # of not matching — `gori run cookie` died with a Crystal backtrace, and `verify`'s "false
    # on a structural parse failure too" contract went with it. Rack is tested FIRST by
    # `detect`, so this reached every caller before the byte-safe Django/Flask predicates ran.
    it "answers, rather than raising, on a signature tail that is not valid UTF-8" do
      bad = "sess--" + "0" * 39 + String.new(Bytes[0xFF])
      Gori::Cookie.detect(bad).should be_nil
      Gori::Cookie.verify(bad, SECRET).should be_false
      expect_raises(Gori::Cookie::CookieError, /unrecognized cookie format/) do
        Gori::Cookie.decode(bad)
      end
      expect_raises(Gori::Cookie::CookieError, /unrecognized cookie format/) do
        Gori::Cookie.crack(bad, ["a", SECRET])
      end
      # Pinned to rack, the parse failure is still a CookieError, not an ArgumentError.
      expect_raises(Gori::Cookie::CookieError, /40-char hex/) do
        Gori::Cookie.decode(bad, "rack")
      end
    end

    # The byte-level hex test has to keep the Regex's exact charset and length.
    it "keeps the 40-hex tail rule, either case and that length only" do
      Gori::Cookie.detect("v--" + "AbCdEf0123" * 4).should eq("rack")
      Gori::Cookie.detect("v--" + "0" * 39).should be_nil
      Gori::Cookie.detect("v--" + "0" * 41).should be_nil
      Gori::Cookie.detect("v--" + "g" * 40).should be_nil
    end
  end

  describe ".crack" do
    it "finds the planted secret in a small wordlist (per format)" do
      list = ["foo", "bar", "s3cr3t-key", "baz"]
      Gori::Cookie.crack(FLASK, list).should eq(SECRET)
      Gori::Cookie.crack(DJANGO, list).should eq(SECRET)
      Gori::Cookie.crack(RACK, list).should eq(SECRET)
    end

    it "returns nil when no candidate matches" do
      Gori::Cookie.crack(FLASK, ["a", "b", "c"]).should be_nil
    end

    it "reuses the fuzzer payload-source model (InlineList / WordlistFile)" do
      Gori::Cookie.crack(RACK, Gori::Fuzz::InlineList.new(["x", SECRET])).should eq(SECRET)
    end
  end

  describe "error handling" do
    it "raises CookieError on an unrecognized format" do
      expect_raises(Gori::Cookie::CookieError, /unrecognized/) do
        Gori::Cookie.decode("plain-text-not-a-cookie")
      end
    end

    it "raises CookieError on a malformed cookie of a known shape" do
      expect_raises(Gori::Cookie::CookieError) do
        Gori::Cookie::Django.parse("only:two") # needs three colon-parts
      end
    end

    it "verify returns false (not raise) on a structurally broken cookie" do
      Gori::Cookie.verify("a.b", SECRET).should be_false
    end

    it "raises CookieError on invalid forge payload JSON" do
      expect_raises(Gori::Cookie::CookieError, /invalid payload JSON/) do
        Gori::Cookie::Flask.forge("{not json", SECRET, 0_i64)
      end
    end
  end
end
