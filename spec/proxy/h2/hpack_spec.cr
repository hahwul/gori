require "../../spec_helper"

private alias HPACK = Gori::Proxy::H2::HPACK

private def hexb(s : String) : Bytes
  clean = s.gsub(/\s/, "")
  Bytes.new(clean.size // 2) { |i| clean[i * 2, 2].to_u8(16) }
end

describe Gori::Proxy::H2::HPACK do
  it "has the 61-entry static table" do
    HPACK::STATIC.size.should eq(61)
    HPACK::STATIC[1].should eq({":method", "GET"})
    HPACK::STATIC[15].should eq({"accept-encoding", "gzip, deflate"})
    HPACK::STATIC[60].should eq({"www-authenticate", ""})
  end

  it "the Huffman table is a complete prefix code (Kraft equality)" do
    sum = HPACK::HUFF_LEN.sum { |l| 2.0 ** (-l.to_i) } + 2.0 ** (-HPACK::EOS_LEN)
    sum.should be_close(1.0, 1e-9)
  end

  it "decodes RFC 7541 C.3.1 (first request, no Huffman)" do
    block = hexb("828684410f7777772e6578616d706c652e636f6d")
    HPACK::Decoder.new.decode(block).should eq([
      {":method", "GET"}, {":scheme", "http"}, {":path", "/"}, {":authority", "www.example.com"},
    ])
  end

  it "decodes RFC 7541 C.4.1 (first request, Huffman)" do
    block = hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff")
    HPACK::Decoder.new.decode(block).should eq([
      {":method", "GET"}, {":scheme", "http"}, {":path", "/"}, {":authority", "www.example.com"},
    ])
  end

  it "decodes RFC 7541 C.6.1 (response, Huffman — uppercase/punct coverage)" do
    block = hexb("4882640258 85aec3771a4b 6196d07abe941054d444a8200595040b8166e082a62d1bff " \
                 "6e919d29ad1718 63c78f0b97c8e9ae82ae43d3")
    HPACK::Decoder.new.decode(block).should eq([
      {":status", "302"},
      {"cache-control", "private"},
      {"date", "Mon, 21 Oct 2013 20:13:21 GMT"},
      {"location", "https://www.example.com"},
    ])
  end

  it "keeps dynamic-table state across blocks (incremental indexing)" do
    dec = HPACK::Decoder.new
    dec.decode(hexb("828684418cf1e3c2e5f23a6ba0ab90f4ff")) # adds :authority www.example.com at 62
    dec.dynamic_entries.first.should eq({":authority", "www.example.com"})
    # a later block can reference the dynamic entry by index 62 (0xbe)
    dec.decode(hexb("be")).should eq([{":authority", "www.example.com"}])
  end

  it "raises on a dynamic index that has no entry" do
    expect_raises(Gori::Error, /dynamic index/) { HPACK::Decoder.new.decode(hexb("be")) }
  end

  it "Huffman round-trips arbitrary bytes" do
    ["www.example.com", "Mon, 21 Oct 2013 20:13:21 GMT", "ABCxyz0189-_/:%", ""].each do |s|
      HPACK.huffman_decode(HPACK.huffman_encode(s)).should eq(s)
    end
  end

  it "rejects Huffman trailing padding that isn't the all-ones EOS prefix (RFC 7541 §5.2)" do
    # '0' is the 5-bit Huffman code 00000. 0x07 = 00000|111 → valid EOS-prefix padding.
    HPACK.huffman_decode(Bytes[0x07_u8]).should eq("0")
    # 0x00 = 00000|000 → the 3 padding bits are zeros, not the EOS prefix → must error
    # (otherwise distinct byte strings decode to the same value — a canonicality bypass).
    expect_raises(Gori::Error, /huffman padding/) { HPACK.huffman_decode(Bytes[0x00_u8]) }
  end

  it "rejects a trailing partial code longer than 7 bits (RFC 7541 §5.2)" do
    # 0xff = 8 all-ones bits: the EOS-prefix path, but 8 > 7 leftover bits is never
    # valid padding — a truncated code, not the last-byte EOS pad.
    expect_raises(Gori::Error, /truncated huffman code/) { HPACK.huffman_decode(Bytes[0xff_u8]) }
    expect_raises(Gori::Error, /truncated huffman code/) { HPACK.huffman_decode(Bytes[0xff_u8, 0xff_u8]) }
  end

  it "Huffman decode is exact over many random byte strings (FSM regression guard)" do
    # The nibble-driven decode FSM must reproduce the bit-by-bit walk for every input.
    # Seeded so it's deterministic; round-trips a broad spread of byte values/lengths.
    rng = Random.new(0x90ac)
    500.times do
      s = String.new(Bytes.new(rng.rand(0..48)) { rng.rand(0_u8..255_u8) })
      HPACK.huffman_decode(HPACK.huffman_encode(s)).should eq(s)
    end
  end

  it "encoder output round-trips through the decoder" do
    headers = [
      {":method", "POST"},        # exact static match → indexed
      {":scheme", "https"},       # exact static match
      {":path", "/api/v1/login"}, # name static, literal value
      {":authority", "acme.test"},
      {"content-type", "application/grpc"},
      {"x-custom-header", "Hello, World! 0123"}, # new name + value
    ]
    block = HPACK::Encoder.new.encode(headers)
    HPACK::Decoder.new.decode(block).should eq(headers)
  end

  it "encoder uses static indexing for exact matches (compact)" do
    # :method GET is static index 2 → a single indexed byte 0x82
    HPACK::Encoder.new.encode([{":method", "GET"}]).should eq(Bytes[0x82])
  end
end
