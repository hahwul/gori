require "./spec_helper"

private REG = Gori::Decoder.default_registry

private def conv(name : String, input : String) : String
  c = REG[name].not_nil!
  String.new(c.apply(input.to_slice))
end

private def conv_bytes(name : String, input : Bytes) : Bytes
  REG[name].not_nil!.apply(input)
end

describe Gori::Decoder do
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

    it "returns every converter (registration order) for an empty query" do
      # Foundation for the Decoder tab's show-all-on-empty discovery popup.
      REG.match("").map(&.name).should eq REG.names
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

    it "base64-decode strips embedded whitespace (MIME-wrapped input)" do
      # The fast path returns the string untouched when clean; wrapped input must
      # still decode after the newlines/tabs are dropped (old gsub(/\s/,"") behavior).
      conv("base64-decode", "aGVsbG8g\nd29ybGQ=").should eq "hello world"
      conv("base64-decode", "aGVs bG8g\td29y\r\nbG Q=").should eq "hello world"
    end

    it "url encode/decode (form style)" do
      conv("url-encode", "a b+c").should eq "a+b%2Bc"
      conv("url-decode", "a+b%2Bc").should eq "a b+c"
    end

    it "url-encode-all percent-encodes every byte (uppercase)" do
      conv("url-encode-all", "A/").should eq "%41%2F"
      conv("url-encode-all", "hi").should eq "%68%69"
      conv("url-decode", conv("url-encode-all", "a b+c")).should eq "a b+c" # round-trips via the std decoder
    end

    it "hex encode/decode (tolerant of 0x / ':' / spaces)" do
      conv("hex-encode", "hi").should eq "6869"
      conv("hex-decode", "0x68 69").should eq "hi"
      conv("hex-decode", "68:69").should eq "hi"
      conv("hex-decode", "6869").should eq "hi"       # clean fast path (no separators)
      conv("hex-decode", "0X6869").should eq "hi"     # uppercase 0X prefix
      conv("hex-decode", "0x68:0x69").should eq "hi"  # a "0x" per byte, colon between
      conv("hex-decode", "  68\t69\n").should eq "hi" # surrounding whitespace
      # non-hex and odd-length still raise
      expect_raises(Gori::Decoder::DecoderError) { conv("hex-decode", "68z") }
      expect_raises(Gori::Decoder::DecoderError) { conv("hex-decode", "689") }
    end
  end

  describe "more encodings" do
    it "base58-decode counts leading zeros consistently across embedded whitespace" do
      # "11 1abc" and "111abc" are numerically identical to the value parser (whitespace
      # skipped); the leading-zero byte count must agree too.
      Gori::Decoder::Codecs.base58_decode("11 1abc").should eq Gori::Decoder::Codecs.base58_decode("111abc")
    end

    it "base32 round-trips and matches the RFC 4648 vector" do
      conv("base32-encode", "foobar").should eq "MZXW6YTBOI======"
      conv("base32-decode", "MZXW6YTBOI======").should eq "foobar"
    end

    it "base32-decode folds lowercase and rejects non-alphabet chars" do
      # The decode table maps both cases to the same value (no whole-string upcase).
      conv("base32-decode", "mzxw6ytboi======").should eq "foobar" # all lowercase
      conv("base32-decode", "MzXw6YtBoI").should eq "foobar"       # mixed case, no padding
      # 0/1/8/9 are not in the RFC 4648 alphabet
      expect_raises(Gori::Decoder::DecoderError) { conv("base32-decode", "MZXW0918") }
    end

    it "base32-encode emits exact RFC 4648 length + padding across input sizes" do
      # Locks the single-shot exact-size buffer: output = ceil(n/5)*8 chars, with
      # every trailing group '='-padded. Round-trips for lengths 0..17.
      (0..17).each do |n|
        bytes = Slice(UInt8).new(n) { |i| (i * 37 + 5).to_u8! }
        enc = conv_bytes("base32-encode", bytes)
        enc.size.should eq(((n + 4) // 5) * 8)
        conv_bytes("base32-decode", enc.dup).should eq bytes
      end
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

    it "raw deflate round-trips (RFC 1951, no zlib/gzip wrapper)" do
      d = conv_bytes("raw-deflate", "hello world".to_slice)
      String.new(conv_bytes("raw-inflate", d)).should eq "hello world"
    end

    it "gzip-compress is deterministic (mtime pinned to epoch)" do
      a = conv_bytes("gzip-compress", "hello world".to_slice)
      b = conv_bytes("gzip-compress", "hello world".to_slice)
      a.should eq(b) # same input → identical bytes (no wall-clock mtime)
      String.new(conv_bytes("gzip-decompress", a)).should eq "hello world"
    end
  end

  describe "number bases (byte-oriented, space-separated)" do
    it "decimal encode/decode" do
      conv("decimal-encode", "hi").should eq "104 105"
      conv("decimal-decode", "104 105").should eq "hi"
      conv("decimal-decode", "104,105").should eq "hi" # comma-separated tolerated
    end

    it "binary encode/decode (8-bit groups)" do
      conv("binary-encode", "hi").should eq "01101000 01101001"
      conv("binary-decode", "01101000 01101001").should eq "hi"
    end

    it "octal encode/decode" do
      conv("octal-encode", "hi").should eq "150 151"
      conv("octal-decode", "150 151").should eq "hi"
    end

    it "round-trips every byte value 0..255 in each base" do
      bytes = Bytes.new(256) { |i| i.to_u8 }
      {"decimal", "binary", "octal"}.each do |base|
        rt = conv_bytes("#{base}-decode", conv_bytes("#{base}-encode", bytes).dup)
        rt.should eq bytes
      end
    end

    it "raises on out-of-range or non-numeric tokens" do
      expect_raises(Gori::Decoder::DecoderError) { conv("decimal-decode", "256") }
      expect_raises(Gori::Decoder::DecoderError) { conv("decimal-decode", "-1") }
      expect_raises(Gori::Decoder::DecoderError) { conv("decimal-decode", "12x") }
      expect_raises(Gori::Decoder::DecoderError) { conv("binary-decode", "012") } # '2' not a binary digit
    end
  end

  describe "hashes (known-answer vectors)" do
    it "matches NIST/RFC vectors" do
      conv("md5", "").should eq "d41d8cd98f00b204e9800998ecf8427e"
      conv("sha1", "").should eq "da39a3ee5e6b4b0d3255bfef95601890afd80709"
      conv("sha256", "abc").should eq "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
      conv("sha512", "abc").should start_with "ddaf35a193617aba"
      conv("crc32", "hello world").should eq "0d4a1185"
      conv("crc32", "").should eq "00000000" # empty input → zero, left-padded to 8 hex
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

    it "unicode-unescape passes real multibyte chars through verbatim beside escapes" do
      # The byte-level scan copies non-escape bytes (incl. a real 'é'/'🎉' UTF-8
      # sequence) verbatim while still decoding adjacent \uXXXX escapes.
      conv("unicode-unescape", "é\\u00e9🎉\\u0041").should eq "éé🎉A"
    end

    it "unicode-unescape leaves a truncated \\u escape at end-of-string literal" do
      # `\uAB` has only 2 hex digits — it must stay literal (like the mid-string case
      # `\uABX`), not decode the short slice to U+00AB.
      conv("unicode-unescape", "x\\uAB").should eq "x\\uAB"
      conv("unicode-unescape", "\\uABC").should eq "\\uABC"
      conv("unicode-unescape", "\\u00e9x").should eq "éx" # a full 4-digit escape still decodes
    end

    it "unicode-unescape reports a lone/unpaired surrogate as a DecoderError (not a raw ArgumentError)" do
      expect_raises(Gori::Decoder::DecoderError) { conv("unicode-unescape", "\\ud800") }
      expect_raises(Gori::Decoder::DecoderError) { conv("unicode-unescape", "\\udc00") }
    end

    it "unicode-unescape treats a \\u run with a sign/space (not 4 hex digits) as literal" do
      # `to_i?(16)` also accepts a leading sign/whitespace, so without an explicit
      # hex-digit guard `\u+ABC`/`\u 1FF` silently mis-decode and `\u-1FF` reaches
      # `Int#chr` with a NEGATIVE value → a raw ArgumentError. All four must stay literal.
      conv("unicode-unescape", "\\u+ABC").should eq "\\u+ABC"
      conv("unicode-unescape", "\\u 1FF").should eq "\\u 1FF"
      conv("unicode-unescape", "\\u-1FF").should eq "\\u-1FF" # was: raw "0x-1ff out of char range"
      conv("unicode-unescape", "\\u_ABC").should eq "\\u_ABC"
      conv("unicode-unescape", "\\uABCD").should eq "ꯍ" # a genuine 4-hex-digit escape still decodes
    end
  end

  describe "text transforms" do
    it "rot13 / case / reverse" do
      conv("rot13", "Hello").should eq "Uryyb"
      conv("upper", "abc").should eq "ABC"
      conv("lower", "ABC").should eq "abc"
      conv("reverse", "abc").should eq "cba"
    end

    it "rot47 rotates printable ASCII 33..126 and is self-inverse" do
      conv("rot47", "Hello").should eq "w6==@"
      conv("rot47", conv("rot47", "Hello, World! 123")).should eq "Hello, World! 123"
      conv("rot47", " ").should eq " " # space (0x20) is below 33 → passes through unchanged
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
      expect_raises(Gori::Decoder::DecoderError) { conv("jwt-decode", "not-a-jwt") }
    end

    it "warns on an alg:none (unsigned) token" do
      h = Base64.urlsafe_encode(%({"alg":"none","typ":"JWT"}), padding: false)
      p = Base64.urlsafe_encode(%({"sub":"admin"}), padding: false)
      out = conv("jwt-decode", "#{h}.#{p}.")
      out.should contain "alg=none"
      out.should contain "UNSIGNED"
      out.should contain "signature: absent"
    end
  end

  describe ".run (chain executor)" do
    it "produces one Ok step per token with intermediates" do
      res = Gori::Decoder.run(REG, "hi".to_slice, "base64 > hex")
      res.steps.size.should eq 2
      res.steps.all?(&.ok?).should be_true
      String.new(res.steps[0].output.not_nil!).should eq "aGk="
      String.new(res.output.not_nil!).should eq "61476b3d" # hex of "aGk="
    end

    it "an empty/whitespace chain is the identity" do
      res = Gori::Decoder.run(REG, "hi".to_slice, "   ")
      res.steps.should be_empty
      String.new(res.output.not_nil!).should eq "hi"
    end

    it "halts on an unknown converter and marks the rest Skipped" do
      res = Gori::Decoder.run(REG, "hi".to_slice, "base64 > bogus > sha256")
      res.steps[0].state.should eq Gori::Decoder::StepState::Ok
      res.steps[1].state.should eq Gori::Decoder::StepState::Unknown
      res.steps[2].state.should eq Gori::Decoder::StepState::Skipped
      res.failed_at.should eq 1
      res.ok?.should be_false
    end

    it "surfaces a mid-chain decode failure without raising" do
      res = Gori::Decoder.run(REG, "!!!not base64!!!".to_slice, "base64-decode > sha256")
      res.steps[0].state.should eq Gori::Decoder::StepState::Failed
      res.steps[0].error.should_not be_nil
      res.steps[1].state.should eq Gori::Decoder::StepState::Skipped
    end

    it "carries binary intermediates through without corruption" do
      res = Gori::Decoder.run(REG, "hello".to_slice, "gzip > base64")
      res.ok?.should be_true
      String.new(conv_bytes("base64-decode", res.steps[1].output.not_nil!)
        .dup).should_not be_empty
    end

    it "fails a text converter on a binary intermediate instead of corrupting it with U+FFFD" do
      # hex-decode of 80ff412042 → raw bytes incl. invalid-UTF-8 0x80/0xff; rot13 is
      # char-oriented and can't process binary — it must FAIL cleanly, not silently
      # substitute U+FFFD (which corrupted AND inflated the bytes).
      res = Gori::Decoder.run(REG, "80ff412042".to_slice, "hex-decode > rot13")
      res.steps[0].state.should eq Gori::Decoder::StepState::Ok
      res.steps[1].state.should eq Gori::Decoder::StepState::Failed
      res.steps[1].error.not_nil!.should contain("UTF-8")
      res.ok?.should be_false
    end

    it "fails a decoder on a binary intermediate with a clean message, not a raw UTF-8 error" do
      res = Gori::Decoder.run(REG, "hello".to_slice, "gzip > hex-decode")
      res.steps[0].state.should eq Gori::Decoder::StepState::Ok # gzip → binary
      res.steps[1].state.should eq Gori::Decoder::StepState::Failed
      res.steps[1].error.not_nil!.should contain("not valid text") # was "Regex match error: UTF-8 error…"
    end
  end

  describe ".display" do
    it "renders valid UTF-8 as text and binary as base64" do
      Gori::Decoder.display("hi".to_slice).should eq({"hi", Gori::Decoder::RenderAs::Text})
      txt, mode = Gori::Decoder.display(Bytes[0xff, 0xfe])
      mode.should eq Gori::Decoder::RenderAs::Base64
      txt.should eq "//4="
      Gori::Decoder.display(Bytes[0xff], Gori::Decoder::RenderAs::Hex).should eq({"ff", Gori::Decoder::RenderAs::Hex})
    end
  end
end
