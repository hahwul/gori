require "./spec_helper"

private REG = Gori::Decoder.default_registry

private def conv(name : String, input : String) : String
  c = REG[name].not_nil!
  String.new(c.apply(input.to_slice))
end

private def conv_bytes(name : String, input : Bytes) : Bytes
  REG[name].not_nil!.apply(input)
end

# What "bidirectional" has to mean for every codec that claims it: empty input, plain
# ASCII, the codecs' own metacharacters, multibyte non-ASCII, CR/LF/tab plus trailing
# whitespace (which quoted-printable must promote), and enough length to cross a
# line-wrapping boundary.
private TEXT_SAMPLES = [
  "",
  "hello world",
  "a=b&c=d <tag> 'quo' \"dq\" \\esc",
  "안녕하세요 überstraße",
  "line1\r\nline2\ttrailing ",
  "x" * 200,
]

# The same contract at the byte level, for the codecs whose declared domain is arbitrary
# bytes: NULs (leading, so the bignum bases have to carry them out-of-band), high bytes,
# and a hex digit right after a non-printable (the C-string \xNN run-on trap).
private BINARY_SAMPLES = [
  Bytes.empty,
  Bytes[0],
  Bytes[0, 0, 1, 2],
  Bytes[0xff, 0xfe, 0x00, 0x7f],
  Bytes[0x01, 0x41, 0xff, 0x61, 0x1b, 0x5b, 0x30, 0x6d],
]

private def round_trips_text(encoder : String, decoder : String)
  TEXT_SAMPLES.each do |s|
    conv(decoder, conv(encoder, s)).should eq s
  end
end

private def round_trips_bytes(encoder : String, decoder : String)
  BINARY_SAMPLES.each do |b|
    conv_bytes(decoder, conv_bytes(encoder, b).dup).should eq b
  end
end

# Publish a named-chain library, hand the rebuilt registry to the block, and ALWAYS put the
# previous one back: `Decoder.library` is process-global, so a leaked fixture would make a
# later spec's chain resolve a name it never registered.
private def with_library(entries : Array({String, String}), &)
  before = Gori::Decoder.library
  Gori::Decoder.library = entries
  begin
    yield Gori::Decoder.shared_registry
  ensure
    Gori::Decoder.library = before
  end
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

    # A group is five base-85 digits packed into 32 bits, so 0xFFFFFFFF ("s8W-!") is the
    # largest that exists. The old UInt32 wrap-around accumulate turned anything above it into
    # four plausible-looking bytes — a decoder inventing data, which no other codec here does.
    it "refuses an ascii85 group whose value overflows 32 bits" do
      conv_bytes("ascii85-decode", "s8W-!".to_slice).should eq Bytes[0xff, 0xff, 0xff, 0xff] # the ceiling itself decodes
      res = Gori::Decoder.run(REG, "uuuuu".to_slice, "ascii85-decode")
      res.steps.first.state.failed?.should be_true
      res.steps.first.error.to_s.should contain("overflows 32 bits")
      # The 'u'-padded PARTIAL groups a real encode produces stay under the ceiling, so the
      # check cannot reject valid data: every 1/2/3-byte tail still round-trips.
      [Bytes[0xff], Bytes[0xff, 0xff], Bytes[0xff, 0xff, 0xff]].each do |tail|
        conv_bytes("ascii85-decode", conv_bytes("ascii85-encode", tail).dup).should eq tail
      end
    end

    it "base58 round-trips (incl. leading-zero bytes)" do
      enc = conv("base58-encode", "hello world")
      conv("base58-decode", enc).should eq "hello world"
      rt = conv_bytes("base58-decode", conv_bytes("base58-encode", Bytes[0, 0, 1, 2, 3]).to_slice.dup)
      rt.should eq Bytes[0, 0, 1, 2, 3]
      # The shared bignum radix codec must not have moved base58's known answer.
      enc.should eq "StV1DL6CwTryKyV"
    end

    it "base36 / base62 round-trip and preserve leading NUL bytes" do
      round_trips_text("base36-encode", "base36-decode")
      round_trips_text("base62-encode", "base62-decode")
      round_trips_bytes("base36-encode", "base36-decode")
      round_trips_bytes("base62-encode", "base62-decode")
      # A leading zero byte is worth nothing to the bignum, so it rides out-of-band as the
      # alphabet's zero digit — without that, "\0\0\x01\x02" would decode back two bytes short.
      conv("base36-encode", "").should eq ""
      conv_bytes("base36-encode", Bytes[0, 0, 1, 2]).should eq "0076".to_slice
      conv_bytes("base36-decode", "0076".to_slice).should eq Bytes[0, 0, 1, 2]
    end

    it "folds case for base36 but not base62 (its alphabet uses both)" do
      conv_bytes("base36-decode", "2WVWKS".to_slice).should eq conv_bytes("base36-decode", "2wvwks".to_slice)
      conv_bytes("base62-decode", "aB".to_slice).should_not eq conv_bytes("base62-decode", "Ab".to_slice)
      expect_raises(Gori::Decoder::DecoderError, /invalid base36 char/) { conv("base36-decode", "abc!") }
      expect_raises(Gori::Decoder::DecoderError, /invalid base62 char/) { conv("base62-decode", "ab_") }
    end

    it "quoted-printable round-trips arbitrary bytes and stays inside 76 columns" do
      round_trips_text("quoted-printable-encode", "quoted-printable-decode")
      round_trips_bytes("quoted-printable-encode", "quoted-printable-decode")
      conv("quoted-printable-encode", "a=b").should eq "a=3Db"
      conv("quoted-printable-encode", "über").should eq "=C3=BCber"
      conv("quoted-printable-encode", "abc " * 40).split("\r\n").each(&.size.should(be <= 76))
    end

    it "quoted-printable encodes CR/LF and any line-final whitespace" do
      # Encoding CR/LF is what makes the codec byte-exact: a hard break in the data can
      # never be confused with a soft break the encoder inserted.
      conv("quoted-printable-encode", "a\r\nb").should eq "a=0D=0Ab"
      # Trailing whitespace does not survive transport, so it must not be emitted literally.
      conv("quoted-printable-encode", "trail ").should eq "trail=20"
      conv("quoted-printable-encode", "trail\t").should eq "trail=09"
    end

    it "quoted-printable-decode drops soft breaks and keeps a malformed '=' verbatim" do
      conv("quoted-printable-decode", "Hello=20World=\r\n!=3D").should eq "Hello World!="
      conv("quoted-printable-decode", "soft=\nbreak").should eq "softbreak" # bare-LF variant
      conv("quoted-printable-decode", "a=zb").should eq "a=zb"              # not a hex pair — literal
      conv("quoted-printable-decode", "trailing=").should eq "trailing="    # nothing follows
    end

    it "punycode matches the IANA/RFC 3492 vectors, per dot-label" do
      conv("punycode-encode", "münchen.de").should eq "xn--mnchen-3ya.de"
      conv("punycode-encode", "bücher").should eq "xn--bcher-kva"
      conv("punycode-encode", "日本語.jp").should eq "xn--wgv71a119e.jp"
      conv("punycode-decode", "xn--maana-pta.com").should eq "mañana.com"
      conv("punycode-decode", "xn--r8jz45g.xn--zckzah").should eq "例え.テスト"
      # Astral plane (a surrogate pair in UTF-16 terms) must survive the bootstring.
      conv("punycode-encode", "💩.la").should eq "xn--ls8h.la"
    end

    it "punycode leaves ASCII labels alone, so a plain hostname round-trips unchanged" do
      ["", "ascii.example.com", "a-b-c.com", "-hyphen.com", "xn--"].each do |s|
        conv("punycode-encode", s).should eq s
        conv("punycode-decode", s).should eq s
      end
      ["münchen.de", "münchen.例え.com", "bücher", "💩.la"].each do |s|
        conv("punycode-decode", conv("punycode-encode", s)).should eq s
      end
    end

    it "punycode-decode rejects a malformed xn-- label instead of emitting garbage" do
      expect_raises(Gori::Decoder::DecoderError, /invalid punycode/) { conv("punycode-decode", "xn--a-!!") }
    end

    # punycode-encode (alias idn-encode) is IDN encode, not raw bootstring: a label with an
    # uppercase or otherwise un-mapped code point must be case-folded + NFC-normalised (RFC 3490
    # ToASCII step 2) BEFORE the bootstring, so the output is the ACE label a resolver produces.
    # Golden column is Python stdlib `s.encode('idna')`.
    it "punycode-encode applies ToASCII case-folding so an upper/mixed-case IDN encodes to the resolver's label" do
      conv("punycode-encode", "MÜNCHEN.de").should eq "xn--mnchen-3ya.de"
      conv("punycode-encode", "München.de").should eq "xn--mnchen-3ya.de"
      conv("punycode-encode", "BÜCHER.example").should eq "xn--bcher-kva.example"
      # Cyrillic: not merely a case change in the OUTPUT — the bootstring DIGITS differ, because
      # the lowercase Cyrillic code points are distinct characters (raw bootstring gave xn--c0adxhks).
      conv("punycode-encode", "МОСКВА.РФ").should eq "xn--80adxhks.xn--p1ai"
      # NFC normalisation: this label is DECOMPOSED ('u' + U+0308 combining diaeresis); the fix
      # NFC-composes it before the bootstring so it folds to the same ACE as the precomposed form.
      conv("punycode-encode", "münchen.de").should eq "xn--mnchen-3ya.de"
      # Round-trips: the ACE our encoder now emits decodes back to the folded Unicode name.
      conv("punycode-decode", conv("punycode-encode", "MÜNCHEN.de")).should eq "münchen.de"
    end

    # Complements of the branch the fix keys on: an already-lowercase IDN label is unchanged
    # (no regression on the working path), and a pure-ASCII label passes through with its case
    # intact (matching Python idna, which nameprep-maps only non-ASCII labels).
    it "punycode-encode leaves an all-lowercase IDN and a pure-ASCII label exactly as before" do
      conv("punycode-encode", "münchen.de").should eq "xn--mnchen-3ya.de" # all-lowercase: same as today
      conv("punycode-encode", "PAYPAL.com").should eq "PAYPAL.com"        # pure ASCII: case preserved
      conv("punycode-encode", "Example.COM").should eq "Example.COM"      # pure ASCII, mixed: untouched
    end
  end

  describe "serialization" do
    it "renders a MessagePack document as JSON, naming what JSON cannot hold" do
      # {"a": 1, "b": <2 raw bytes>}
      doc = Bytes[0x82, 0xa1, 0x61, 0x01, 0xa1, 0x62, 0xc4, 0x02, 0xff, 0xfe]
      String.new(conv_bytes("msgpack-decode", doc)).should eq(%({"a":1,"b":{"$bin":"//4="}}))
      String.new(conv_bytes("msgpack", doc)).should eq(%({"a":1,"b":{"$bin":"//4="}}))
    end

    it "keeps a partial document and fails only one that decoded nothing" do
      # `drain`'s rule, one format over: a body cut short by the capture cap is the ordinary
      # case, and what it did decode is what the operator came for.
      String.new(conv_bytes("msgpack-decode", Bytes[0x93, 0x01, 0x02]))
        .should eq(%([1,2,{"$partial":"truncated"}]))
      expect_raises(Gori::Decoder::DecoderError, /not a MessagePack document/) do
        conv_bytes("msgpack-decode", Bytes[0xc1])
      end
      # A converter is where the operator ALREADY decided what the bytes are — they typed the
      # name — so it keeps far more than the content-type-driven panes do, and fails only when
      # the reader could not take the very first byte.
      String.new(conv_bytes("msgpack-decode", %({"a":1}).to_slice)).should eq("123")
    end

    it "does not mistake a document that IS null for one that failed" do
      # The failure rule is "rendered only `null` AND did not finish". A top-level null is a
      # legitimate one-byte document in both formats and finishes cleanly, so it survives —
      # the two halves of that rule are what keep it apart from a first byte the reader could
      # not take.
      String.new(conv_bytes("msgpack-decode", Bytes[0xc0])).should eq("null")
      String.new(conv_bytes("cbor-decode", Bytes[0xf6])).should eq("null")
    end

    it "renders a CBOR document, naming what JSON cannot hold" do
      # {"a": 1} and a tagged bignum, the two shapes the projection is about.
      String.new(conv_bytes("cbor-decode", "a161610 1".gsub(" ", "").hexbytes)).should eq(%({"a":1}))
      String.new(conv_bytes("cbor", "c249400000000000000000".hexbytes))
        .should contain(%("$bignum":"1180591620717411303424"))
    end

    it "chains, which is the point of it being a converter" do
      # base64 in, JSON out — the shape of a body pasted out of a header or a JSON string.
      chain = Gori::Decoder.run(REG, "kQE=".to_slice, "base64-decode > msgpack-decode")
      String.new(chain.output.not_nil!).should eq("[1]")
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

    # gori links the brotli DECODER and wraps libzstd's decompressor only — what a proxy needs
    # is to read what an origin sent — so these two cannot be round-tripped through the
    # workbench. The fixtures are real streams produced by `brotli -q 11` and `zstd -19`,
    # embedded rather than shelled out for so the suite does not need either tool installed.
    it "brotli-decompresses a real `Content-Encoding: br` stream" do
      br = "2128000468656c6c6f20776f726c6403".hexbytes
      String.new(conv_bytes("brotli-decompress", br)).should eq "hello world"
      String.new(conv_bytes("br", br)).should eq "hello world" # the alias a header spells it with
    end

    it "zstd-decompresses a real `Content-Encoding: zstd` stream" do
      zs = "28b52ffd240b59000068656c6c6f20776f726c6468691eb2".hexbytes
      String.new(conv_bytes("zstd-decompress", zs)).should eq "hello world"
      String.new(conv_bytes("zstd", zs)).should eq "hello world"
    end

    # The drain used to stop at `>= MAX_OUT`, which left the answer to chunk alignment: a last
    # read landing exactly ON the ceiling passed `Chain.run`'s `size > max_out` gate, so the
    # step reported Ok for output that had been silently cut, while one byte over it the same
    # bomb failed. One answer now, and it is the failure.
    it "fails a decompression that would exceed the 32 MiB ceiling instead of silently cutting it" do
      bomb = conv_bytes("gzip-compress", Bytes.new(Gori::Decoder::MAX_OUT + 1024, 0_u8))
      res = Gori::Decoder.run(REG, bomb, "gunzip")
      res.ok?.should be_false
      res.output.should be_nil
      res.steps.first.error.to_s.should contain("exceeds")
    end

    it "turns a buffer that was never one of these streams into a FAILED step, not a raise" do
      # Through the chain, which is what every surface runs: `DecoderError` is what `Chain.run`
      # converts into a Failed step, and anything else would unwind into a TUI draw.
      %w[brotli-decompress zstd-decompress].each do |name|
        res = Gori::Decoder.run(REG, "not a compressed stream at all".to_slice, name)
        res.steps.first.state.failed?.should be_true
        res.steps.first.error.to_s.should contain("decompress failed")
        res.output.should be_nil
      end
    end

    it "lets a stream that really decodes to nothing through" do
      # `zstd -19` over an empty file. The libraries answer a corrupt buffer and a valid empty
      # payload identically — no bytes, no raise — so the reader's own "did this end cleanly"
      # is what separates them. Guessing from the output length gets one of the two wrong.
      empty = "28b52ffd240001000099e9d851".hexbytes
      conv_bytes("zstd-decompress", empty).size.should eq(0)
    end

    it "keeps a truncated stream rather than calling it a failure" do
      # `drain`'s rule: a body cut short by the capture cap is the ordinary case, and what it
      # did decode is what the operator came for.
      next unless Gori::Proxy::Codec::Zstd::AVAILABLE
      full = "28b52ffd240b59000068656c6c6f20776f726c6468691eb2".hexbytes
      conv_bytes("zstd-decompress", full[0, full.size - 4]).size.should be > 0
    end

    it "resolves every new name, and says why on a build that cannot run them" do
      # `Registry#[]` RAISES on a miss, so `should_not be_nil` on its result asserts nothing —
      # `[]?` is the one that can answer "missing". A `-Dwithout_native_codecs` build must not
      # make `br` read as a typo: the name resolves and the converter carries the reason,
      # prefixed with its own name because `Fuzz::Plan` and the Repeater collect several of
      # these into one list.
      %w[brotli-decompress brotli br unbrotli zstd-decompress zstd unzstd].each do |name|
        REG[name]?.should_not be_nil
      end
      available = Gori::Proxy::Codec::Brotli::AVAILABLE
      %w[brotli-decompress zstd-decompress].each do |name|
        reason = REG[name].unusable
        reason.nil?.should eq(available)
        reason.try(&.starts_with?("#{name}: ")).should eq(available ? nil : true)
      end
      # Nothing else in the catalog claims to be unusable.
      REG.each { |c| c.unusable.should be_nil } if available
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

    it "handles invalid decompression data cleanly as DecoderError" do
      expect_raises(Gori::Decoder::DecoderError) { conv_bytes("gzip-decompress", "invalid".to_slice) }
      expect_raises(Gori::Decoder::DecoderError) { conv_bytes("zlib-decompress", "invalid".to_slice) }
      expect_raises(Gori::Decoder::DecoderError) { conv_bytes("raw-inflate", "invalid".to_slice) }
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
      conv("sha224", "abc").should eq "23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7"
      conv("sha256", "abc").should eq "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
      conv("sha384", "abc").should eq "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7"
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

    # `String.from_json` stops at the first complete value and ignores the rest, so this used
    # to decode to "a" and drop everything after it without a word.
    it "json-unescape refuses input that carries more than the one string literal" do
      res = Gori::Decoder.run(REG, %("a" "b").to_slice, "json-unescape")
      res.steps.first.state.failed?.should be_true
      res.steps.first.error.to_s.should contain("invalid JSON string")
      # Trailing whitespace is not "more input" — it strips, and the literal still decodes.
      conv("json-unescape", %("a"  )).should eq "a"
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

    it "xml escape/unescape round-trips and covers the five predefined entities" do
      round_trips_text("xml-escape", "xml-unescape")
      conv("xml-escape", %(a & b < c > d " e ' f)).should eq "a &amp; b &lt; c &gt; d &quot; e &apos; f"
      conv("xml-unescape", "&lt;tag attr=&quot;v&quot;&gt;it&apos;s&lt;/tag&gt; &amp;").should eq %(<tag attr="v">it's</tag> &)
      # '&' is escaped first, so an entity in the SOURCE text survives the round-trip.
      conv("xml-escape", "&amp;").should eq "&amp;amp;"
    end

    it "xml-unescape resolves numeric references and leaves unknown entities alone" do
      conv("xml-unescape", "&#65;&#x42;&#x1F600;").should eq "AB😀"
      # &nbsp; is an HTML entity, not one of XML's five — keep it verbatim rather than
      # dropping it, since this reads captured values instead of validating them.
      conv("xml-unescape", "&nbsp; bare & here &#xZZ;").should eq "&nbsp; bare & here &#xZZ;"
    end

    it "shell-escape wraps in POSIX single quotes and neutralizes an embedded quote" do
      conv("shell-escape", "it's a $VAR; rm -rf /").should eq %('it'\\''s a $VAR; rm -rf /')
      conv("shell-escape", "").should eq "''"
      conv("shell-escape", "line1\nline2").should eq "'line1\nline2'" # a newline is literal inside ''
    end

    it "powershell-escape wraps in single quotes and doubles an embedded quote" do
      conv("powershell-escape", "it's $env:PATH").should eq "'it''s $env:PATH'"
      conv("powershell-escape", "").should eq "''"
    end

    it "c-string escape/unescape round-trips text and arbitrary bytes" do
      round_trips_text("c-string-escape", "c-string-unescape")
      round_trips_bytes("c-string-escape", "c-string-unescape")
      conv("c-string-escape", "a\tb\"c\\d\ne").should eq %(a\\tb\\"c\\\\d\\ne)
      conv("c-string-unescape", %(\\x41\\102\\n\\u0043)).should eq "AB\nC"
    end

    it "c-string-escape falls back to octal when \\xNN would run on into the next byte" do
      # \xNN is greedy in C: "\x01" + 'A' compiles as the single byte 0x1A. The fixed-width
      # 3-digit octal form cannot run on, so it is used exactly when the next byte is a hex digit.
      conv_bytes("c-string-escape", Bytes[0x01, 0x41]).should eq "\\001A".to_slice
      conv_bytes("c-string-escape", Bytes[0xff, 0x7a]).should eq "\\xffz".to_slice # 'z' is not a hex digit
      conv_bytes("c-string-unescape", "\\001A".to_slice).should eq Bytes[0x01, 0x41]
      conv_bytes("c-string-unescape", "\\xffz".to_slice).should eq Bytes[0xff, 0x7a]
    end

    it "c-string-unescape keeps an unknown or truncated escape verbatim" do
      conv("c-string-unescape", "\\q").should eq "\\q"
      conv("c-string-unescape", "\\x").should eq "\\x"         # \x with no digits
      conv("c-string-unescape", "\\ud800").should eq "\\ud800" # a lone surrogate has no UTF-8 form
      conv("c-string-unescape", "trailing\\").should eq "trailing\\"
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

    it "homoglyph swaps ASCII letters for confusables and leaves the rest alone" do
      conv("homoglyph", "google.com").should eq "ɡооɡⅼе.соm"
      # Lossy and partial by design: 'D'/'N' have no established lookalike here, and the
      # separators/digits stay ASCII so the result is still a usable hostname shape.
      conv("homoglyph", "ADMIN-1").should eq "АDМІN-1"
      conv("homoglyph", "").should eq ""
    end

    it "typo generates deduped near-miss variants, one per line, excluding the input" do
      variants = conv("typo", "ab").lines
      variants.should eq ["b", "a", "ba", "qb", "sb", "zb", "av", "ag", "ah", "an"]
      variants.should_not contain "ab" # the input itself is never a variant
      variants.size.should eq variants.uniq.size
      conv("typo", "").should eq ""
      conv("typo", "a").should eq "q\ns\nz" # the empty omission is dropped
    end

    it "typo mirrors case on an adjacent-key substitution and caps its input" do
      conv("typo", "Ab").lines.should contain "Qb"
      expect_raises(Gori::Decoder::DecoderError, /too long/) { conv("typo", "a" * 129) }
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

    it "still decodes header/payload/signature exactly as before for a plain 3-part token (no regression)" do
      token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9." \
              "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIn0.abc"
      out = conv("jwt-decode", token)
      out.should_not contain "WARNING"
      out.should_not contain "extra segment"
    end

    it "surfaces segments beyond the 3rd instead of silently dropping them (fix #22)" do
      # a.b.c.d.e — a naive parts[0..2] read would decode this as if it were a plain
      # 3-part JWT and silently drop "d" and "e", hiding smuggled/obfuscated trailing data.
      out = conv("jwt-decode", "a.b.c.d.e")
      out.should contain "WARNING"
      out.should contain "5 dot-separated parts"
      out.should contain "JWE-shaped"
      out.should contain "[3] d"
      out.should contain "[4] e"
    end

    it "flags a non-5-part extra-segment token generically, still showing the raw extras" do
      out = conv("jwt-decode", "a.b.c.d")
      out.should contain "WARNING"
      out.should contain "4 dot-separated parts"
      out.should contain "not a standard JWT"
      out.should contain "[3] d"
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

  # The global named-chain library (settings.json `decoder.chains`) registered as converters,
  # so a saved name is a chain STEP everywhere a spec runs — the Decoder tab, the
  # Repeater/Fuzzer §value¦chain§ marker, `gori run decoder`, MCP `decode`.
  describe "saved-chain library" do
    it "calls a saved chain by name, as one step, next to built-ins" do
      with_library([{"myenc", "base64-encode > upper"}]) do |reg|
        res = Gori::Decoder.run(reg, "abc".to_slice, "myenc > lower")
        res.ok?.should be_true
        res.steps.size.should eq 2 # the saved chain is ONE row, not its two converters
        res.steps[0].name.should eq "myenc"
        String.new(res.steps[0].output.not_nil!).should eq "YWJJ" # base64("abc")=YWJj, uppercased
        String.new(res.output.not_nil!).should eq "ywjj"
      end
    end

    it "offers saved names to the chain autocomplete" do
      with_library([{"myenc", "base64-encode"}]) do |reg|
        reg.match("mye").map(&.name).should contain "myenc"
      end
    end

    it "resolves a saved chain that references another, in either definition order" do
      with_library([{"inner", "base64-encode"}, {"outer", "inner > upper"}]) do |reg|
        String.new(Gori::Decoder.run(reg, "abc".to_slice, "outer").output.not_nil!).should eq "YWJJ"
      end
      with_library([{"outer", "inner > upper"}, {"inner", "base64-encode"}]) do |reg|
        String.new(Gori::Decoder.run(reg, "abc".to_slice, "outer").output.not_nil!).should eq "YWJJ"
      end
    end

    it "matches a saved name case- and separator-insensitively, like any converter" do
      with_library([{"My Chain", "upper"}]) do |reg|
        String.new(Gori::Decoder.run(reg, "ab".to_slice, "my-chain").output.not_nil!).should eq "AB"
        String.new(Gori::Decoder.run(reg, "ab".to_slice, "MY_CHAIN").output.not_nil!).should eq "AB"
      end
    end

    it "never lets a saved name shadow a built-in name OR alias" do
      with_library([{"hex", "upper"}, {"base64-encode", "lower"}]) do |reg|
        String.new(Gori::Decoder.run(reg, "a".to_slice, "hex").output.not_nil!).should eq "61"
        String.new(Gori::Decoder.run(reg, "A".to_slice, "base64-encode").output.not_nil!).should eq "QQ=="
      end
    end

    it "fails a recursive definition as a step instead of hanging" do
      with_library([{"a", "b > upper"}, {"b", "a"}]) do |reg|
        res = Gori::Decoder.run(reg, "x".to_slice, "a")
        res.steps[0].state.should eq Gori::Decoder::StepState::Failed
        res.steps[0].error.not_nil!.should contain "recursive"
      end
    end

    it "names the inner step that broke, not just the saved chain" do
      with_library([{"peel", "upper > gunzip"}]) do |reg|
        res = Gori::Decoder.run(reg, "not gzip".to_slice, "peel")
        res.steps[0].state.should eq Gori::Decoder::StepState::Failed
        err = res.steps[0].error.not_nil!
        err.should contain "peel"
        err.should contain "gunzip"
      end
    end

    it "reports an unresolvable token inside a saved chain against that token" do
      with_library([{"x", "base64-encode > bogus"}]) do |reg|
        res = Gori::Decoder.run(reg, "a".to_slice, "x")
        res.steps[0].state.should eq Gori::Decoder::StepState::Failed
        res.steps[0].error.not_nil!.should contain "bogus"
      end
    end

    it "treats an empty saved chain as the identity" do
      with_library([{"nop", "  "}]) do |reg|
        res = Gori::Decoder.run(reg, "hi".to_slice, "nop")
        res.ok?.should be_true
        String.new(res.output.not_nil!).should eq "hi"
      end
    end

    # ── ordering independence ─────────────────────────────────────────────────────
    #
    # `register_all` used to flatten and register in ONE loop, so `flatten`'s `r[tok]?` probe
    # read a registry the loop was mutating: by entry i, entries 0..i-1 answered it and every
    # BACKWARD reference stayed a run-time nested call instead of being spliced. Only forward
    # references were spliced, so only forward references were counted against MAX_TOKENS —
    # and the ordinary authoring order (save the helper, THEN save the chain that calls it) is
    # entirely backward references, which left the guard dead on the path it exists for.
    #
    # Every example below states the same library TWICE, helper-first and helper-last, because
    # the defect was invisible in one ordering and only in one.
    it "refuses an over-MAX_TOKENS library in EITHER definition order" do
      # Depth 9 of `x(n) = x(n-1) > x(n-1)` is 512 flattened steps — past MAX_TOKENS (256).
      # Written helper-LAST this was already refused; written helper-FIRST it registered fine
      # and one `run` burned 2^9 applications, growing to 73 seconds of CPU at depth 25.
      deep = [{"z0", "upper"}]
      (1..9).each { |i| deep << {"z#{i}", "z#{i - 1} > z#{i - 1}"} }

      with_library(deep) do |reg| # helper FIRST (what ^S produces)
        res = Gori::Decoder.run(reg, "hi".to_slice, "z9")
        res.steps[0].state.should eq Gori::Decoder::StepState::Failed
        res.steps[0].error.not_nil!.should contain "expands past 256 steps"
      end
      with_library(deep.reverse) do |reg| # helper LAST
        res = Gori::Decoder.run(reg, "hi".to_slice, "z9")
        res.steps[0].state.should eq Gori::Decoder::StepState::Failed
        res.steps[0].error.not_nil!.should contain "expands past 256 steps"
      end
    end

    it "keeps an UNDER-MAX_TOKENS library usable in either order (the complement)" do
      # The same shape one level shallower — 256 steps, at the ceiling and not past it. If the
      # fix refused this it would have turned a working library into a broken one.
      ok = [{"z0", "upper"}]
      (1..8).each { |i| ok << {"z#{i}", "z#{i - 1} > z#{i - 1}"} }
      [ok, ok.reverse].each do |entries|
        with_library(entries) do |reg|
          String.new(Gori::Decoder.run(reg, "hi".to_slice, "z8").output.not_nil!).should eq "HI"
        end
      end
    end

    it "reports the SAME failing built-in at the same depth in either order" do
      # The ordering also decided the error TEXT from a two-entry library: helper-first left
      # `inner` as a run-time call and reported "outer: step 1 'inner': inner: step 1
      # 'base64-decode': …", helper-last spliced it and reported "outer: step 1
      # 'base64-decode': …". One library, one meaning.
      pair = [{"inner", "base64-decode"}, {"outer", "inner > upper"}]
      msgs = [pair, pair.reverse].map do |entries|
        with_library(entries) do |reg|
          Gori::Decoder.run(reg, "!!!!".to_slice, "outer").steps[0].error.not_nil!
        end
      end
      msgs[0].should eq msgs[1]
      msgs[0].should contain "base64-decode"
    end

    it "detects a cycle in either order, and does not memoize a false one" do
      cyc = [{"cyc-a", "cyc-b"}, {"cyc-b", "cyc-a"}]
      [cyc, cyc.reverse].each do |entries|
        with_library(entries) do |reg|
          ["cyc-a", "cyc-b"].each do |name|
            res = Gori::Decoder.run(reg, "x".to_slice, name)
            res.steps[0].state.should eq Gori::Decoder::StepState::Failed
            res.steps[0].error.not_nil!.should contain "recursive"
          end
        end
      end
      # Self-reference, both orders (there is only one entry, but the DIAMOND below is the
      # case a naive "don't memoize failures" fix regresses).
      with_library([{"selfref", "selfref > upper"}]) do |reg|
        Gori::Decoder.run(reg, "x".to_slice, "selfref").steps[0].error.not_nil!
          .should contain "recursive"
      end
      # A DIAMOND is not a cycle: `top` reaches `leaf` by two routes. Flattening must succeed
      # in either order — the memo has to be reused, not mistaken for a stack hit.
      dia = [{"leaf", "upper"}, {"l", "leaf"}, {"r", "leaf"}, {"top", "l > r"}]
      [dia, dia.reverse].each do |entries|
        with_library(entries) do |reg|
          String.new(Gori::Decoder.run(reg, "hi".to_slice, "top").output.not_nil!).should eq "HI"
        end
      end
    end

    it "leaves a dangling reference dangling in either order" do
      dang = [{"outer", "nosuch > upper"}]
      [dang, dang.reverse].each do |entries|
        with_library(entries) do |reg|
          res = Gori::Decoder.run(reg, "x".to_slice, "outer")
          res.steps[0].state.should eq Gori::Decoder::StepState::Failed
          res.steps[0].error.not_nil!.should contain "nosuch"
        end
      end
    end

    it "still lets a built-in win over a saved name that shadows it, in either order" do
      # The two-pass split changes WHAT `r` holds while flattening, so the "a built-in wins"
      # filter is worth re-stating on both sides of it.
      shadow = [{"hexer", "hex-encode"}, {"hex", "upper"}]
      [shadow, shadow.reverse].each do |entries|
        with_library(entries) do |reg|
          String.new(Gori::Decoder.run(reg, "a".to_slice, "hex").output.not_nil!).should eq "61"
          String.new(Gori::Decoder.run(reg, "a".to_slice, "hexer").output.not_nil!).should eq "61"
        end
      end
    end

    # ── the flag a caller reads instead of running the converter ──────────────────
    it "marks an unusable saved chain `unusable` and a working one nil" do
      with_library([{"good", "upper"}, {"selfref", "selfref > upper"}]) do |reg|
        reg["good"].unusable.should be_nil
        reg["selfref"].unusable.not_nil!.should contain "recursive"
        # A built-in is never unusable.
        reg["upper"].unusable.should be_nil
      end
    end

    it "marks a saved chain with an unknown converter token unusable" do
      # Left as typed, this registered with unusable:nil so Fuzz::Plan's pre-dial
      # refusal never fired and apply_chains sent the payload untransformed.
      with_library([{"myenc", "url-encode > nosuchthing"}]) do |reg|
        reg["myenc"].unusable.not_nil!.should contain "unknown converter"
        reg["myenc"].unusable.not_nil!.should contain "nosuchthing"
      end
    end

    # A saved chain is only as runnable as its steps. `brotli-decompress` / `zstd-decompress`
    # are registered CARRYING a reason on a `-Dwithout_native_codecs` build (the catalog's
    # `native_codec_reason`) so their names still resolve; a saved chain wrapping one inherited
    # `unusable: nil`, so `Fuzz::Plan.refuse_unrunnable_chains` — which reads that flag off the
    # ONE token the spec names — waved the run through and every payload failed at send instead.
    # Same defect as the unknown-token case above, one arm over. Built by hand rather than off
    # the shared registry because this build links the native codecs.
    it "inherits a built-in's `unusable` into a saved chain that wraps it" do
      r = Gori::Decoder::Registry.new
      r.register Gori::Decoder.bytes("no-native",
        category: Gori::Decoder::Category::Compression,
        direction: Gori::Decoder::Direction::Decode,
        description: "stand-in for a codec this build dropped",
        unusable: "no-native: this gori was built without it") { |b| b }
      r.register Gori::Decoder.text("upcase-it", category: Gori::Decoder::Category::Text,
        direction: Gori::Decoder::Direction::Transform, description: "x", &.upcase)

      Gori::Decoder::Library.register_all(r, [
        {"wrapper", "upcase-it > no-native"},
        {"clean", "upcase-it"},
      ])
      r["wrapper"].unusable.not_nil!.should contain "no-native"
      r["wrapper"].unusable.not_nil!.should contain "built without it"
      # The complement: a saved chain over runnable steps stays runnable.
      r["clean"].unusable.should be_nil
    end

    it "publishes through the Settings setter, so every surface sees the same library" do
      before = Gori::Settings.decoder_chains
      begin
        Gori::Settings.decoder_chains = [{"fromsettings", "upper"}]
        String.new(Gori::Decoder.run(Gori::Decoder.shared_registry, "ab".to_slice, "fromsettings")
          .output.not_nil!).should eq "AB"
      ensure
        Gori::Settings.decoder_chains = before
      end
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
