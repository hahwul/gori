require "../spec_helper"
require "openssl"
require "../../src/gori/proxy/tls/fingerprint"

include Gori::Proxy::Tls

# ── ClientHello builder ────────────────────────────────────────────────────────────────────
#
# Hand-assembled so the two PUBLISHED worked examples below can be reproduced byte for byte.
# That is the whole point of this file: a fixture captured from gori's own OpenSSL and an
# expectation written from gori's own parser would agree with each other no matter how badly
# either read the spec. These build the hellos the specs describe and compare against the
# answers the spec authors printed.

private def u16(value : Int32) : Bytes
  Bytes[(value >> 8).to_u8, (value & 0xff).to_u8]
end

private def vec16(body : Bytes) : Bytes
  cat(u16(body.size), body)
end

private def vec8(body : Bytes) : Bytes
  cat(Bytes[body.size.to_u8], body)
end

private def cat(*parts : Bytes) : Bytes
  io = IO::Memory.new
  parts.each { |p| io.write(p) }
  io.to_slice
end

private def u16s(values : Array(Int32)) : Bytes
  io = IO::Memory.new
  values.each { |v| io.write(u16(v)) }
  io.to_slice
end

# One extension: type(2) length(2) body.
private def ext(type : Int32, body : Bytes = Bytes.empty) : Bytes
  cat(u16(type), vec16(body))
end

private def sni_ext(host : String = "example.test") : Bytes
  ext(0x0000, vec16(cat(Bytes[0x00], vec16(host.to_slice))))
end

private def alpn_ext(protocols : Array(String)) : Bytes
  list = IO::Memory.new
  protocols.each { |p| list.write(vec8(p.to_slice)) }
  ext(0x0010, vec16(list.to_slice))
end

private def groups_ext(values : Array(Int32)) : Bytes
  ext(0x000a, vec16(u16s(values)))
end

private def point_formats_ext(values : Array(UInt8)) : Bytes
  ext(0x000b, vec8(Bytes.new(values.size) { |i| values[i] }))
end

private def sigalgs_ext(values : Array(Int32)) : Bytes
  ext(0x000d, vec16(u16s(values)))
end

private def supported_versions_ext(values : Array(Int32)) : Bytes
  ext(0x002b, vec8(u16s(values)))
end

# A whole ClientHello handshake message. `legacy_version` is the one JA3 reports; the fake
# 32-byte session id is what every TLS 1.3 client sends for middlebox compatibility.
private def client_hello(legacy_version : Int32, ciphers : Array(Int32), extensions : Bytes) : Bytes
  body = cat(
    u16(legacy_version),
    Bytes.new(32, 0x11_u8),       # random
    vec8(Bytes.new(32, 0x22_u8)), # legacy_session_id
    vec16(u16s(ciphers)),
    vec8(Bytes[0x00]), # legacy_compression_methods: null
    vec16(extensions),
  )
  len = body.size
  cat(Bytes[0x01_u8, ((len >> 16) & 0xff).to_u8, ((len >> 8) & 0xff).to_u8, (len & 0xff).to_u8], body)
end

# Wrap a handshake message in a TLS record, the form the wire (and gori's own capture) carries.
private def as_record(handshake : Bytes) : Bytes
  cat(Bytes[0x16_u8, 0x03_u8, 0x01_u8], u16(handshake.size), handshake)
end

# ── the JA4 spec's worked example ──────────────────────────────────────────────────────────
#
# https://github.com/FoxIO-LLC/ja4/blob/main/technical_details/JA4.md — every number below is
# copied from that document, including the expected fingerprint.

private JA4_EXAMPLE_CIPHERS = [
  0x1301, 0x1302, 0x1303, 0xc02b, 0xc02f, 0xc02c, 0xc030, 0xcca9,
  0xcca8, 0xc013, 0xc014, 0x009c, 0x009d, 0x002f, 0x0035,
]

private JA4_EXAMPLE_SIGALGS = [0x0403, 0x0804, 0x0401, 0x0503, 0x0805, 0x0501, 0x0806, 0x0601]

# The spec's extension list, in the spec's own order:
#   001b,0000,0033,0010,4469,0017,002d,000d,0005,0023,0012,002b,ff01,000b,000a,0015
private def ja4_example_extensions(with_grease : Bool = false) : Bytes
  parts = [
    ext(0x001b, Bytes[0x02, 0x00, 0x02]),
    sni_ext,
    ext(0x0033, Bytes[0x00, 0x01]),
    alpn_ext(["h2", "http/1.1"]),
    ext(0x4469, Bytes[0x00]),
    ext(0x0017),
    ext(0x002d, Bytes[0x01, 0x01]),
    sigalgs_ext(JA4_EXAMPLE_SIGALGS),
    ext(0x0005, Bytes[0x01, 0x00, 0x00, 0x00, 0x00]),
    ext(0x0023),
    ext(0x0012),
    supported_versions_ext([0x0304, 0x0303]),
    ext(0xff01, Bytes[0x00]),
    point_formats_ext([0x00_u8]),
    groups_ext([0x001d, 0x0017, 0x0018]),
    ext(0x0015, Bytes.new(8, 0_u8)),
  ]
  # RFC 8701 reserved values, which BOTH specs require be ignored. A browser really does put
  # them here, and OpenSSL picks fresh ones per handshake — so a fingerprint that counted them
  # would differ on every single connection.
  parts.unshift(ext(0x1a1a)) if with_grease
  io = IO::Memory.new
  parts.each { |p| io.write(p) }
  io.to_slice
end

private def ja4_example_hello(with_grease : Bool = false) : Bytes
  ciphers = with_grease ? [0x0a0a] + JA4_EXAMPLE_CIPHERS : JA4_EXAMPLE_CIPHERS
  client_hello(0x0303, ciphers, ja4_example_extensions(with_grease))
end

describe Gori::Proxy::Tls::Fingerprint do
  describe "JA4" do
    # The single most important example in the file: the fingerprint below is the one the JA4
    # authors published for this exact hello. It pins the version source (supported_versions,
    # NOT legacy_version), both counts, the ALPN characters, the sorted-cipher hash, and the
    # sorted-extensions-then-unsorted-sigalgs hash — every place this algorithm can be
    # misread, judged by someone other than its implementer.
    it "reproduces the published worked example" do
      hello = Fingerprint.parse(ja4_example_hello).should_not be_nil
      Fingerprint.ja4(hello).should eq("t13d1516h2_8daaf6152771_e5627efa2ab1")
    end

    it "reproduces the published raw (JA4_r) form" do
      hello = Fingerprint.parse(ja4_example_hello).should_not be_nil
      Fingerprint.ja4_raw(hello).should eq(
        "t13d1516h2_" \
        "002f,0035,009c,009d,1301,1302,1303,c013,c014,c02b,c02c,c02f,c030,cca8,cca9_" \
        "0005,000a,000b,000d,0012,0015,0017,001b,0023,002b,002d,0033,4469,ff01_" \
        "0403,0804,0401,0503,0805,0501,0806,0601")
    end

    # GREASE in the cipher list AND in the extension list. If either leaked through, the counts
    # (15/16) would rise and both hashes would change — so this one expectation covers every
    # place the stripping has to happen.
    it "ignores GREASE values in ciphers and extensions" do
      plain = Fingerprint.parse(ja4_example_hello).should_not be_nil
      greased = Fingerprint.parse(ja4_example_hello(with_grease: true)).should_not be_nil
      Fingerprint.ja4(greased).should eq(Fingerprint.ja4(plain))
    end

    it "reads the same hello out of a TLS record as out of a bare handshake message" do
      bare = Fingerprint.parse(ja4_example_hello).should_not be_nil
      framed = Fingerprint.parse(as_record(ja4_example_hello)).should_not be_nil
      Fingerprint.ja4(framed).should eq(Fingerprint.ja4(bare))
    end

    # The classic misread: every TLS 1.3 client writes 0x0303 in legacy_version for middlebox
    # compatibility, so a JA4 taken from there reports the whole modern web as TLS 1.2.
    it "takes the version from supported_versions, not from legacy_version" do
      without = client_hello(0x0303, JA4_EXAMPLE_CIPHERS, cat(sni_ext, alpn_ext(["h2"])))
      Fingerprint.ja4(Fingerprint.parse(without).not_nil!).should start_with("t12d")
      Fingerprint.ja4(Fingerprint.parse(ja4_example_hello).not_nil!).should start_with("t13d")
    end

    it "reports i (IP) when there is no SNI, and 00 when there is no ALPN" do
      hello = Fingerprint.parse(client_hello(0x0303, [0x1301], Bytes.empty)).should_not be_nil
      Fingerprint.ja4(hello).should start_with("t12i0100")
    end

    # The spec's ALPN table, verbatim. Every row is a case that the "just take the first and
    # last character" reading gets wrong.
    it "follows the spec's ALPN character rules for non-alphanumeric values" do
      {
        "h2"               => "h2",
        "http/1.1"         => "h1",
        "a"                => "aa",
        "\xAB"             => "ab",
        "\x20"             => "20",
        "\xAB\xCD"         => "ad",
        "\x20\x61"         => "21",
        "\x30\xAB"         => "3b",
        "\x61\x20"         => "60",
        "\x30\x31\xAB\xCD" => "3d",
        "\x30\xAB\xCD\x31" => "01",
      }.each do |value, expected|
        hello = Fingerprint.parse(
          client_hello(0x0303, [0x1301], cat(sni_ext, alpn_ext([value])))).should_not be_nil
        Fingerprint.ja4(hello)[8, 2].should eq(expected)
      end
    end

    # "If there are no ciphers … then the value of JA4_b is set to 000000000000. We do this
    # rather than running a sha256 hash of nothing" — the spec is explicit, and a hash of the
    # empty string would look like a real answer.
    it "writes zeros rather than a hash of nothing for an empty list" do
      hello = Fingerprint.parse(client_hello(0x0303, [] of Int32, sni_ext)).should_not be_nil
      Fingerprint.ja4(hello).should contain("_000000000000_000000000000")
    end
  end

  describe "JA3" do
    # The example string printed in salesforce/ja3's README. JA3's digest is only an MD5 of
    # this text, so pinning the TEXT is what actually pins the algorithm: field order, the `,`
    # between fields and the `-` between values.
    it "reproduces the published example string" do
      extensions = cat(
        sni_ext,
        groups_ext([23, 24, 25]),
        point_formats_ext([0_u8]),
      )
      ciphers = [47, 53, 5, 10, 49161, 49162, 49171, 49172, 50, 56, 19, 4]
      hello = Fingerprint.parse(client_hello(769, ciphers, extensions)).should_not be_nil
      Fingerprint.ja3_text(hello).should eq(
        "769,47-53-5-10-49161-49162-49171-49172-50-56-19-4,0-10-11,23-24-25,0")
      Fingerprint.ja3(hello).should eq(Digest::MD5.hexdigest(Fingerprint.ja3_text(hello)))
    end

    # "If there are no SSL Extensions in the Client Hello, the fields are left empty" — the
    # trailing commas are part of the answer, not a formatting accident.
    it "leaves the last three fields empty when there are no extensions at all" do
      hello = Fingerprint.parse(client_hello(769, [4, 5], Bytes.empty)).should_not be_nil
      Fingerprint.ja3_text(hello).should eq("769,4-5,,,")
    end

    # JA3 reads the CLIENT HELLO's version, not supported_versions and not the record header's
    # (which this builder writes as 0x0301 — a different number, deliberately).
    it "uses the ClientHello's own legacy_version" do
      hello = Fingerprint.parse(as_record(ja4_example_hello)).should_not be_nil
      Fingerprint.ja3_text(hello).should start_with("771,")
    end
  end

  describe ".parse" do
    it "returns nil rather than raising on bytes that are not a ClientHello" do
      Fingerprint.parse(Bytes.empty).should be_nil
      Fingerprint.parse("not tls at all".to_slice).should be_nil
      Fingerprint.parse(Bytes[0x16, 0x03, 0x01, 0x00, 0x05, 0x02, 0x00, 0x00, 0x01, 0x00]).should be_nil
    end

    # Truncation at every length is the shape a hostile peer sends. None of them may raise:
    # the same parser is fed unauthenticated bytes.
    it "survives every truncation of a valid hello" do
      full = as_record(ja4_example_hello)
      (0...full.size).each { |n| Fingerprint.parse(full[0, n]) }
    end
  end

  describe ".grease?" do
    it "matches the sixteen reserved values and nothing else" do
      [0x0a0a, 0x1a1a, 0x2a2a, 0x3a3a, 0x4a4a, 0x5a5a, 0x6a6a, 0x7a7a,
       0x8a8a, 0x9a9a, 0xaaaa, 0xbaba, 0xcaca, 0xdada, 0xeaea, 0xfafa].each do |v|
        Fingerprint.grease?(v).should be_true
      end
      [0x0000, 0x1301, 0x0a0b, 0x1a0a, 0xaaab, 0x000a].each do |v|
        Fingerprint.grease?(v).should be_false
      end
    end
  end

  # ── the capture ──────────────────────────────────────────────────────────────────────────
  #
  # These are the ones that make the FEATURE verifiable rather than the algorithm: they assert
  # that what OpenSSL writes for a configured context is what the report describes.
  describe ".of_context" do
    it "captures a parseable ClientHello from a real client context" do
      report = Fingerprint.of_context(OpenSSL::SSL::Context::Client.new).should_not be_nil
      report.ja3.size.should eq(32) # md5 hex
      report.ja4.should match(/\At1[23]d\d\d\d\d[0-9a-z]{2}_[0-9a-f]{12}_[0-9a-f]{12}\z/)
      report.ja3_text.should start_with("771,")
    end

    # The hostname gori passes is what puts SNI in the hello — and the JA4 `d`/`i` character is
    # the only place that shows.
    it "reports d for a named destination" do
      report = Fingerprint.of_context(OpenSSL::SSL::Context::Client.new).should_not be_nil
      report.ja4[3].should eq('d')
    end

    it "is stable across repeated captures from one context (the randoms are not fingerprinted)" do
      ctx = OpenSSL::SSL::Context::Client.new
      a = Fingerprint.of_context(ctx).should_not be_nil
      b = Fingerprint.of_context(ctx).should_not be_nil
      a.ja3.should eq(b.ja3)
      a.ja4.should eq(b.ja4)
      # …and the bytes themselves are NOT identical, which is what makes the line above a
      # claim about the algorithm rather than about a cached buffer.
      Fingerprint.hello_bytes(ctx).should_not eq(Fingerprint.hello_bytes(ctx))
    end
  end
end
