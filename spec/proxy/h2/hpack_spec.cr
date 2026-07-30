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

  it "the default encoder never touches its dynamic table" do
    # Literal-without-indexing for everything not an exact static hit, so a block
    # decodes the same against any decoder in any order — see Encoder's comment on
    # why that is the default on a path where some heads may still pass through raw.
    enc = HPACK::Encoder.new
    2.times { enc.encode([{"cookie", "a=1"}, {"authorization", "Bearer x"}]) }
    enc.dynamic_entries.should be_empty
    # Both blocks are byte-identical: no history means no drift.
    a = enc.encode([{"cookie", "a=1"}])
    b = HPACK::Encoder.new.encode([{"cookie", "a=1"}])
    a.should eq(b)
    # 0x00-prefixed = §6.2.2 literal without indexing (not 0x40, not 0x10).
    (a[0] & 0xf0).should eq(0x00)
  end

  # --- RFC 7541 Appendix C encode vectors -------------------------------------
  # Each is asserted BOTH ways: the fixture must decode to the header list (which
  # validates the fixture itself against the already-trusted decoder) and the
  # encoder must reproduce the fixture byte-for-byte. That second half is the
  # interoperability claim — these are the bytes a real HPACK peer emits.

  it "encodes RFC 7541 C.4 (requests, Huffman + incremental indexing)" do
    enc = HPACK::Encoder.new(indexing: true)
    dec = HPACK::Decoder.new
    [
      {"828684418cf1e3c2e5f23a6ba0ab90f4ff",
       [{":method", "GET"}, {":scheme", "http"}, {":path", "/"},
        {":authority", "www.example.com"}]},
      {"828684be5886a8eb10649cbf",
       [{":method", "GET"}, {":scheme", "http"}, {":path", "/"},
        {":authority", "www.example.com"}, {"cache-control", "no-cache"}]},
      {"828785bf408825a849e95ba97d7f8925a849e95bb8e8b4bf",
       [{":method", "GET"}, {":scheme", "https"}, {":path", "/index.html"},
        {":authority", "www.example.com"}, {"custom-key", "custom-value"}]},
    ].each do |(hex, headers)|
      dec.decode(hexb(hex)).should eq(headers) # the fixture is what the RFC says
      enc.encode(headers).should eq(hexb(hex)) # and we emit exactly that
    end
    # Both tables ended on the same three entries, in the same order.
    enc.dynamic_entries.should eq(dec.dynamic_entries)
  end

  it "encodes RFC 7541 C.6 (responses, Huffman, 256-byte table with eviction)" do
    enc = HPACK::Encoder.new(max_size: 256, indexing: true)
    dec = HPACK::Decoder.new(max_size: 256)    # fed the RFC's bytes
    mirror = HPACK::Decoder.new(max_size: 256) # fed ours
    c61 = "4882640258 85aec3771a4b 6196d07abe941054d444a8200595040b8166e082a62d1bff " \
          "6e919d29ad1718 63c78f0b97c8e9ae82ae43d3"
    c61_headers = [{":status", "302"},
                   {"cache-control", "private"},
                   {"date", "Mon, 21 Oct 2013 20:13:21 GMT"},
                   {"location", "https://www.example.com"}]
    dec.decode(hexb(c61)).should eq(c61_headers)
    ours = enc.encode(c61_headers)
    ours.should eq(hexb(c61))
    mirror.decode(ours).should eq(c61_headers)

    # C.6.2 is the same response with a new :status, so every other field is a
    # back-reference into the dynamic table both sides just built.
    c62 = "4883640eff c1 c0 bf"
    c62_headers = [{":status", "307"},
                   {"cache-control", "private"},
                   {"date", "Mon, 21 Oct 2013 20:13:21 GMT"},
                   {"location", "https://www.example.com"}]
    dec.decode(hexb(c62)).should eq(c62_headers)
    ours = enc.encode(c62_headers)
    # One byte of deliberate divergence: "307" is 3 raw octets and 17 Huffman bits,
    # i.e. 3 bytes either way, and we break that tie toward the raw literal (see
    # Encoder#encode_string) where the RFC's encoder codes it. Same length, and the
    # three back-references — the part that proves the tables are in step — are the
    # RFC's bytes exactly.
    ours.size.should eq(hexb(c62).size)
    ours[-3, 3].should eq(Bytes[0xc1, 0xc0, 0xbf])
    mirror.decode(ours).should eq(c62_headers)

    # C.6.2 evicted the ":status 302" entry on all three sides — same §4.1 sizing,
    # same eviction moment, which is why 0xc1/0xc0/0xbf resolved at all.
    enc.dynamic_entries.should eq(dec.dynamic_entries)
    enc.dynamic_entries.should eq(mirror.dynamic_entries)
    enc.dynamic_entries.first.should eq({":status", "307"})
  end

  it "re-encodes the existing decode fixtures back through a decoder" do
    # Cheapest real-traffic check: take blocks a real HPACK encoder produced,
    # decode them, and put the header list back through our encoder. The block
    # will NOT be byte-identical (HPACK is stateful and the representation choice
    # is the encoder's) — the header list must be.
    ["828684410f7777772e6578616d706c652e636f6d", # C.3.1 request, no Huffman
     "828684418cf1e3c2e5f23a6ba0ab90f4ff",       # C.4.1 request, Huffman
     "4882640258 85aec3771a4b 6196d07abe941054d444a8200595040b8166e082a62d1bff " \
     "6e919d29ad1718 63c78f0b97c8e9ae82ae43d3" # C.6.1 response
    ].each do |hex|
      headers = HPACK::Decoder.new.decode(hexb(hex))
      HPACK::Decoder.new.decode(HPACK::Encoder.new.encode(headers)).should eq(headers)
      HPACK::Decoder.new(max_size: 256)
        .decode(HPACK::Encoder.new(max_size: 256, indexing: true).encode(headers))
        .should eq(headers)
    end
  end

  # --- never-indexed (§6.2.3) --------------------------------------------------

  it "preserves the never-indexed marking through decode (RFC 7541 C.2.3)" do
    # 0x10 prefix, literal name "password", literal value "secret".
    fields = HPACK::Decoder.new.decode_fields(hexb("1008 70617373776f7264 06 736563726574"))
    fields.map(&.to_tuple).should eq([{"password", "secret"}])
    fields[0].never_indexed?.should be_true
    # C.2.2 §6.2.2 (0x00 prefix) then C.2.4 §6.1 (0x82) — neither is never-indexed,
    # and neither entered the table.
    dec = HPACK::Decoder.new
    plain = dec.decode_fields(hexb("040c 2f73616d706c652f70617468 82"))
    plain.map(&.to_tuple).should eq([{":path", "/sample/path"}, {":method", "GET"}])
    plain.map(&.never_indexed?).should eq([false, false])
    dec.dynamic_entries.should be_empty
  end

  it "re-emits never-indexed fields as never-indexed and keeps them out of the table" do
    enc = HPACK::Encoder.new(indexing: true) # indexing ON — the flag still wins
    fields = [
      HPACK::Field.new("authorization", "Bearer sk-live-1234567890", never_indexed: true),
      HPACK::Field.new("x-plain", "indexable"),
    ]
    block = enc.encode(fields)
    (block[0] & 0xf0).should eq(0x10) # §6.2.3 representation, re-emitted
    # The sensitive header never entered the table; the ordinary one did.
    enc.dynamic_entries.should eq([{"x-plain", "indexable"}])

    out = HPACK::Decoder.new.decode_fields(block)
    out.map(&.to_tuple).should eq(fields.map(&.to_tuple))
    out.map(&.never_indexed?).should eq([true, false]) # marking survives the round trip
    # And a decoder's table agrees: only the non-sensitive field was indexed.
    dec = HPACK::Decoder.new
    dec.decode(block)
    dec.dynamic_entries.should eq([{"x-plain", "indexable"}])
  end

  it "keeps the never-indexed representation even on an exact static hit" do
    # §6.2.3 says forward it with the SAME representation, so an exact static match
    # must not collapse to a one-byte index — that would drop the marking.
    enc = HPACK::Encoder.new(indexing: true)
    block = enc.encode([HPACK::Field.new(":method", "GET", never_indexed: true)])
    block.should_not eq(Bytes[0x82])
    (block[0] & 0xf0).should eq(0x10)
    out = HPACK::Decoder.new.decode_fields(block)
    out.map(&.to_tuple).should eq([{":method", "GET"}])
    out[0].never_indexed?.should be_true
    enc.dynamic_entries.should be_empty
  end

  it "encodes plain tuples as not-never-indexed" do
    # The marking is honoured, never guessed from the name: a caller handing us
    # bare pairs gets the ordinary representation even for a sensitive-looking name.
    block = HPACK::Encoder.new.encode([{"authorization", "Bearer x"}])
    (block[0] & 0xf0).should eq(0x00)
  end

  # --- dynamic table: encoder and decoder stay in step -------------------------

  it "keeps encoder and decoder tables in step across many blocks (with eviction)" do
    rng = Random.new(0x51ac)
    enc = HPACK::Encoder.new(max_size: 512, indexing: true)
    dec = HPACK::Decoder.new(max_size: 512)
    200.times do
      headers = Array.new(rng.rand(1..6)) do
        # A small name pool so entries repeat (exercising indexed hits) mixed with
        # fresh ones (exercising insertion + eviction at the 512-byte cap).
        name = ["cookie", "x-req-id", "accept", "user-agent", "x-#{rng.rand(8)}"].sample(rng)
        value = rng.rand(3) == 0 ? "v#{rng.rand(4)}" : "x" * rng.rand(0..120)
        {name, value}
      end
      dec.decode(enc.encode(headers)).should eq(headers)
      enc.dynamic_entries.should eq(dec.dynamic_entries)
    end
  end

  it "signals a dynamic table size change before the next block (§4.2/§6.3)" do
    enc = HPACK::Encoder.new(indexing: true)
    dec = HPACK::Decoder.new
    dec.decode(enc.encode([{"x-a", "1"}, {"x-b", "2"}]))
    enc.dynamic_entries.size.should eq(2)

    # 40 bytes holds exactly one 36-byte entry, so the older one is evicted here,
    # before the decoder has been told anything.
    enc.max_size = 40
    enc.dynamic_entries.should eq([{"x-b", "2"}])
    block = enc.encode([{"x-c", "3"}])
    (block[0] & 0xe0).should eq(0x20) # §6.3 dynamic table size update leads the block
    dec.decode(block).should eq([{"x-c", "3"}])
    dec.max_size.should eq(40)
    enc.dynamic_entries.should eq(dec.dynamic_entries) # decoder evicted with us

    # Two moves between blocks collapse to {low-water mark, final}: the decoder has
    # to perform the eviction the low value caused, or every later index is off.
    enc.max_size = 0
    enc.max_size = 4096
    block = enc.encode([{"x-d", "4"}])
    dec.decode(block).should eq([{"x-d", "4"}])
    dec.max_size.should eq(4096)
    enc.dynamic_entries.should eq(dec.dynamic_entries)
    # No change since the last block → no update byte.
    (enc.encode([{"x-e", "5"}])[0] & 0xe0).should_not eq(0x20)
  end

  it "clamps a size update to the bound the decoder enforces" do
    enc = HPACK::Encoder.new
    enc.max_size = Int32::MAX
    enc.max_size.should eq(HPACK::Encoder::MAX_TABLE_SIZE)
    HPACK::Decoder.new.decode(enc.encode([{"x", "y"}])).should eq([{"x", "y"}]) # not rejected
  end

  # --- adversarial input (P7: encode what the peer sent, don't judge it) -------

  it "encodes adversarial header content without raising" do
    long = "A" * 100_000
    binary = String.new(Bytes[0x00_u8, 0xff_u8, 0xfe_u8, 0x80_u8, 0x0a_u8, 0x0d_u8])
    headers = [
      {"", ""},             # empty name AND value
      {"x-empty", ""},      # empty value
      {"", "orphan-value"}, # empty name
      {"x-long", long},     # value past every prefix-int boundary
      {long, "x"},          # and a name just as long
      {"x-binary", binary}, # NUL + non-UTF-8 bytes
      {String.new(Bytes[0xc3_u8, 0x28_u8]), "invalid-utf8-name"},
      {"x-dup", "1"}, {"x-dup", "2"}, # duplicate names
      {"x-euckr", String.new(Bytes[0xb0_u8, 0xa1_u8])},
    ]
    [HPACK::Encoder.new, HPACK::Encoder.new(indexing: true),
     HPACK::Encoder.new(max_size: 0, indexing: true)].each do |enc|
      HPACK::Decoder.new.decode(enc.encode(headers)).should eq(headers)
    end
  end

  it "skips Huffman when it would make the literal longer (§5.2)" do
    # Layout for a literal with a literal name: [repr][name len]["x"][value len]...
    # High bytes cost 20+ bits each, so 2 of them never compress back down to 2.
    value = String.new(Bytes[0xff_u8, 0xfe_u8])
    block = HPACK::Encoder.new.encode([{"x", value}])
    HPACK::Decoder.new.decode(block).should eq([{"x", value}])
    block[3].should eq(0x02_u8) # length 2, H-bit clear → raw octets
    # A compressible value does take the H-bit: 16 'a' = 16×5 bits = 10 bytes.
    HPACK::Encoder.new.encode([{"x", "a" * 16}])[3].should eq(0x8a_u8)
  end

  it "round-trips random header lists through encoder and decoder" do
    rng = Random.new(0xbeef)
    300.times do
      headers = Array.new(rng.rand(0..8)) do
        name = String.new(Bytes.new(rng.rand(0..12)) { rng.rand(0_u8..255_u8) })
        value = String.new(Bytes.new(rng.rand(0..40)) { rng.rand(0_u8..255_u8) })
        {name, value}
      end
      HPACK::Decoder.new.decode(HPACK::Encoder.new.encode(headers)).should eq(headers)
      enc = HPACK::Encoder.new(indexing: true)
      HPACK::Decoder.new.decode(enc.encode(headers)).should eq(headers)
    end
  end
end
