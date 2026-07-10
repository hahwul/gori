require "./spec_helper"

private REG = Gori::Convert.default_registry

private def conv(name : String, input : String) : String
  c = REG[name].not_nil!
  String.new(c.apply(input.to_slice))
end

private def conv_bytes(name : String, input : Bytes) : Bytes
  REG[name].not_nil!.apply(input)
end

describe Gori::Convert do
  describe "registry" do
    it "resolves canonical names, aliases, and is case/separator insensitive" do
      REG["base64-encode"].should_not be_nil
      REG["base64"].should eq REG["base64-encode"]  # alias
      REG["B64"].should eq REG["base64-encode"]     # case-insensitive
      REG["URL ENCODE"].should eq REG["url-encode"] # space-folded
      REG["url_encode"].should eq REG["url-encode"] # underscore-folded
      REG["nope"]?.should be_nil
    end

    it "matches by prefix then substring for autocomplete" do
      names = REG.match("base64").map(&.name)
      names.should contain "base64-encode"
      names.should contain "base64url-encode"
      REG.match("zzz").should be_empty
    end

    it "ranks a canonical-name prefix above an alias-only prefix" do
      # "ur": url-encode/url-decode (name starts with "ur") must precede
      # base64url-encode (only its alias "urlsafe-base64" starts with "ur").
      names = REG.match("ur").map(&.name)
      names.first.should eq "url-encode"
      names.index("url-encode").not_nil!.should be < names.index("base64url-encode").not_nil!
    end
  end

  describe "base64 / url / hex round-trips" do
    it "base64 encode/decode" do
      conv("base64-encode", "hello world").should eq "aGVsbG8gd29ybGQ="
      conv("base64-decode", "aGVsbG8gd29ybGQ=").should eq "hello world"
      conv("base64-decode", "aGVsbG8gd29ybGQ").should eq "hello world" # missing padding tolerated
    end

    it "base64url uses the -_ alphabet" do
      String.new(conv_bytes("base64url-encode", Bytes[0xfb, 0xff])).should eq "-_8="
    end

    it "url encode/decode (form style)" do
      conv("url-encode", "a b+c").should eq "a+b%2Bc"
      conv("url-decode", "a+b%2Bc").should eq "a b+c"
    end

    it "hex encode/decode (tolerant of 0x / ':' / spaces)" do
      conv("hex-encode", "hi").should eq "6869"
      conv("hex-decode", "0x68 69").should eq "hi"
      conv("hex-decode", "68:69").should eq "hi"
    end
  end

  describe "more encodings" do
    it "base58-decode counts leading zeros consistently across embedded whitespace" do
      # "11 1abc" and "111abc" are numerically identical to the value parser (whitespace
      # skipped); the leading-zero byte count must agree too.
      Gori::Convert::Codecs.base58_decode("11 1abc").should eq Gori::Convert::Codecs.base58_decode("111abc")
    end

    it "base32 round-trips and matches the RFC 4648 vector" do
      conv("base32-encode", "foobar").should eq "MZXW6YTBOI======"
      conv("base32-decode", "MZXW6YTBOI======").should eq "foobar"
    end

    it "ascii85 round-trips, incl. encodings that contain '<'/'>' data symbols" do
      conv("ascii85-decode", conv("ascii85-encode", "hello world")).should eq "hello world"
      # "foobar" encodes to "AoDTs@<)" — the interior '<' is real data, not a wrapper.
      enc = conv("ascii85-encode", "foobar")
      enc.should contain "<"
      conv("ascii85-decode", enc).should eq "foobar"
      # tolerates the optional <~ ~> Adobe wrapper at the boundaries
      conv("ascii85-decode", "<~#{enc}~>").should eq "foobar"
      # exhaustive small round-trip across byte values that exercise '<'/'>' outputs
      (0..255).each_slice(3) do |sl|
        bytes = Slice(UInt8).new(sl.size) { |i| sl[i].to_u8 }
        conv_bytes("ascii85-decode", conv_bytes("ascii85-encode", bytes).dup).should eq bytes
      end
    end

    it "base58 round-trips (incl. leading-zero bytes)" do
      enc = conv("base58-encode", "hello world")
      conv("base58-decode", enc).should eq "hello world"
      rt = conv_bytes("base58-decode", conv_bytes("base58-encode", Bytes[0, 0, 1, 2, 3]).to_slice.dup)
      rt.should eq Bytes[0, 0, 1, 2, 3]
    end
  end

  describe "compression" do
    it "gzip round-trips" do
      gz = conv_bytes("gzip-compress", "hello world".to_slice)
      String.new(conv_bytes("gzip-decompress", gz)).should eq "hello world"
    end

    it "zlib round-trips" do
      z = conv_bytes("zlib-compress", "hello world".to_slice)
      String.new(conv_bytes("zlib-decompress", z)).should eq "hello world"
    end
  end

  describe "hashes (known-answer vectors)" do
    it "matches NIST/RFC vectors" do
      conv("md5", "").should eq "d41d8cd98f00b204e9800998ecf8427e"
      conv("sha1", "").should eq "da39a3ee5e6b4b0d3255bfef95601890afd80709"
      conv("sha256", "abc").should eq "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
      conv("sha512", "abc").should start_with "ddaf35a193617aba"
    end
  end

  describe "escapes" do
    it "html escape/unescape" do
      conv("html-escape", "<a href=\"x\">").should eq "&lt;a href=&quot;x&quot;&gt;"
      conv("html-unescape", "&lt;a&gt;&#65;").should eq "<a>A"
    end

    it "json string escape/unescape (quoted + bare)" do
      conv("json-escape", "a\nb").should eq "\"a\\nb\""
      conv("json-unescape", "\"a\\nb\"").should eq "a\nb"
      conv("json-unescape", "a\\tb").should eq "a\tb" # bare input tolerated
    end

    it "unicode escape/unescape (incl. astral via surrogate pair)" do
      conv("unicode-escape", "aé").should eq "a\\u00e9"
      conv("unicode-unescape", "a\\u00e9").should eq "aé"
      conv("unicode-unescape", conv("unicode-escape", "x🎉y")).should eq "x🎉y"
    end

    it "unicode-unescape reports a lone/unpaired surrogate as a ConvertError (not a raw ArgumentError)" do
      expect_raises(Gori::Convert::ConvertError) { conv("unicode-unescape", "\\ud800") }
      expect_raises(Gori::Convert::ConvertError) { conv("unicode-unescape", "\\udc00") }
    end
  end

  describe "text transforms" do
    it "rot13 / case / reverse" do
      conv("rot13", "Hello").should eq "Uryyb"
      conv("upper", "abc").should eq "ABC"
      conv("lower", "ABC").should eq "abc"
      conv("reverse", "abc").should eq "cba"
    end
  end

  describe "jwt-decode" do
    it "decodes header + payload of a known unsigned token" do
      # {"alg":"HS256","typ":"JWT"} . {"sub":"1234567890","name":"John Doe"} . sig
      token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9." \
              "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIn0.abc"
      out = conv("jwt-decode", token)
      out.should contain %("alg": "HS256")
      out.should contain %("name": "John Doe")
      out.should contain "not verified"
    end

    it "raises a clean error on junk" do
      expect_raises(Gori::Convert::ConvertError) { conv("jwt-decode", "not-a-jwt") }
    end
  end

  describe ".run (chain executor)" do
    it "produces one Ok step per token with intermediates" do
      res = Gori::Convert.run(REG, "hi".to_slice, "base64 > hex")
      res.steps.size.should eq 2
      res.steps.all?(&.ok?).should be_true
      String.new(res.steps[0].output.not_nil!).should eq "aGk="
      String.new(res.output.not_nil!).should eq "61476b3d" # hex of "aGk="
    end

    it "an empty/whitespace chain is the identity" do
      res = Gori::Convert.run(REG, "hi".to_slice, "   ")
      res.steps.should be_empty
      String.new(res.output.not_nil!).should eq "hi"
    end

    it "halts on an unknown converter and marks the rest Skipped" do
      res = Gori::Convert.run(REG, "hi".to_slice, "base64 > bogus > sha256")
      res.steps[0].state.should eq Gori::Convert::StepState::Ok
      res.steps[1].state.should eq Gori::Convert::StepState::Unknown
      res.steps[2].state.should eq Gori::Convert::StepState::Skipped
      res.failed_at.should eq 1
      res.ok?.should be_false
    end

    it "surfaces a mid-chain decode failure without raising" do
      res = Gori::Convert.run(REG, "!!!not base64!!!".to_slice, "base64-decode > sha256")
      res.steps[0].state.should eq Gori::Convert::StepState::Failed
      res.steps[0].error.should_not be_nil
      res.steps[1].state.should eq Gori::Convert::StepState::Skipped
    end

    it "carries binary intermediates through without corruption" do
      res = Gori::Convert.run(REG, "hello".to_slice, "gzip > base64")
      res.ok?.should be_true
      String.new(conv_bytes("base64-decode", res.steps[1].output.not_nil!)
        .dup).should_not be_empty
    end

    it "fails a text converter on a binary intermediate instead of corrupting it with U+FFFD" do
      # hex-decode of 80ff412042 → raw bytes incl. invalid-UTF-8 0x80/0xff; rot13 is
      # char-oriented and can't process binary — it must FAIL cleanly, not silently
      # substitute U+FFFD (which corrupted AND inflated the bytes).
      res = Gori::Convert.run(REG, "80ff412042".to_slice, "hex-decode > rot13")
      res.steps[0].state.should eq Gori::Convert::StepState::Ok
      res.steps[1].state.should eq Gori::Convert::StepState::Failed
      res.steps[1].error.not_nil!.should contain("UTF-8")
      res.ok?.should be_false
    end

    it "fails a decoder on a binary intermediate with a clean message, not a raw UTF-8 error" do
      res = Gori::Convert.run(REG, "hello".to_slice, "gzip > hex-decode")
      res.steps[0].state.should eq Gori::Convert::StepState::Ok # gzip → binary
      res.steps[1].state.should eq Gori::Convert::StepState::Failed
      res.steps[1].error.not_nil!.should contain("not valid text") # was "Regex match error: UTF-8 error…"
    end
  end

  describe ".display" do
    it "renders valid UTF-8 as text and binary as base64" do
      Gori::Convert.display("hi".to_slice).should eq({"hi", Gori::Convert::RenderAs::Text})
      txt, mode = Gori::Convert.display(Bytes[0xff, 0xfe])
      mode.should eq Gori::Convert::RenderAs::Base64
      txt.should eq "//4="
      Gori::Convert.display(Bytes[0xff], Gori::Convert::RenderAs::Hex).should eq({"ff", Gori::Convert::RenderAs::Hex})
    end
  end
end
