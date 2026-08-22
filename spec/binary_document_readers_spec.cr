require "./spec_helper"

# `Gori::Msgpack` and `Gori::Cbor` each make the same two promises, and neither can be checked
# by reading: NEVER RAISE on any input, and always emit a document that parses. A body handed to
# either one came off the wire, so hostile and truncated input is the normal case — and the
# failure mode of getting this wrong is a raise unwinding into a TUI draw, or a JSON document
# with a hole in it reaching an agent.
#
# A cross-cutting spec because the property is one and the readers are two: it belongs to
# neither file, and a copy in each is how the two would drift.
describe "the binary document readers" do
  it "survives every byte, every prefix, and thousands of random buffers" do
    raises = [] of String
    bad_json = [] of String

    check = ->(label : String, data : Bytes) do
      {"msgpack", "cbor"}.each do |fmt|
        begin
          json, _ = fmt == "msgpack" ? Gori::Msgpack.to_json(data) : Gori::Cbor.to_json(data)
          begin
            JSON.parse(json)
          rescue
            bad_json << "#{fmt} #{label}: #{json[0, 80]}"
          end
        rescue ex
          raises << "#{fmt} #{label}: #{ex.class} #{ex.message}"
        end
      end
    end

    # every single byte, and every byte with assorted filler behind it
    (0..255).each do |b|
      check.call("byte #{b}", Bytes[b.to_u8])
      [Bytes[0xff_u8], Bytes[0x00_u8, 0x00_u8], Bytes[0x9f_u8, 0xff_u8],
       Bytes[0x61_u8, 0x61_u8, 0x61_u8, 0x61_u8, 0x61_u8, 0x61_u8, 0x61_u8, 0x61_u8]].each_with_index do |tail, i|
        check.call("byte #{b}+#{i}", Bytes[b.to_u8] + tail)
      end
    end

    # every prefix of a real document of each kind
    mp = Bytes[0x82, 0xa1, 0x61, 0x01, 0xa1, 0x62, 0xc4, 0x02, 0xff, 0xfe]
    cb = "a26178830102a1617922617aa1646465657082f5f4".hexbytes
    [mp, cb].each_with_index do |doc, di|
      (0..doc.size).each { |n| check.call("prefix #{di}/#{n}", doc[0, n]) }
    end

    # seeded random buffers
    rng = Random.new(4242)
    3_000.times do |i|
      len = rng.rand(1..48)
      check.call("rand #{i}", Bytes.new(len) { rng.rand(256).to_u8 })
    end

    # CBOR indefinite-form abuse: a break where it does not belong
    [
      "9f01ff", "bf01ff", "82ff01", "a1ff01", "7f01ff", "5f61 61ff".gsub(" ", ""),
      "7f7f6161ffff", "bf6161ff", "ff", "9fff", "bfff",
    ].each_with_index { |h, i| check.call("indef #{i}", h.hexbytes) }

    # msgpack ext with every type byte, length 0
    (0..255).each { |t| check.call("ext #{t}", Bytes[0xc7, 0x00, t.to_u8]) }

    raises.should eq([] of String)
    bad_json.should eq([] of String)
  end

  it "bounds the time a pathological body can take" do
    rng = Random.new(9)
    worst = 0.0
    20.times do
      data = Bytes.new(200_000) { rng.rand(256).to_u8 }
      t = Time.instant
      Gori::Msgpack.to_json(data)
      Gori::Cbor.to_json(data)
      ms = (Time.instant - t).total_milliseconds
      worst = ms if ms > worst
    end
    # Measured at ~1 ms for 200 KB. The ceiling is loose on purpose — this guards against a
    # quadratic path opening up, not against a slow machine.
    worst.should be < 1000.0
  end
  it "renders a document's own $-named key the same as a marker, which is a decision" do
    # `{"$bin": 1}` and a byte-string wrapper share a shape. Escaping every key in every body to
    # defend against the one body that does this would make the common body harder to read, and
    # the bytes stay reachable (^X, and the raw store) either way. Pinned so the ambiguity is a
    # decision that has to be re-argued to change, rather than a thing nobody noticed.
    Gori::Msgpack.to_json(Bytes[0x81, 0xa4, 0x24, 0x62, 0x69, 0x6e, 0x01])[0].should eq(%({"$bin":1}))
    Gori::Cbor.to_json("a1642474616701".hexbytes)[0].should eq(%({"$tag":1}))
    # …and the wrappers themselves still carry what they claim.
    Gori::Msgpack.to_json(Bytes[0xc4, 0x02, 0xff, 0xfe])[0].should eq(%({"$bin":"//4="}))
  end

  it "keeps a document's own $keys member beside the marker rather than losing it" do
    # This one is NOT the harmless half of the collision: the reader appends its own `$keys`
    # after the document's, so re-parsing the text to pretty-print it kept the marker and
    # DESTROYED the operator's value. Both members survive now, on every surface.
    # {"$keys": "REAL", 1: "int"}
    doc = Bytes[0x82, 0xa5, 0x24, 0x6b, 0x65, 0x79, 0x73, 0xa4, 0x52, 0x45, 0x41, 0x4c,
      0x01, 0xa3, 0x69, 0x6e, 0x74]
    json = Gori::Msgpack.to_json(doc)[0]
    json.should contain(%("$keys":"REAL"))
    json.should contain(%("$keys":"non-string"))
  end
  it "keeps a body cut short INSIDE a value, which is where a capture cap lands" do
    # `take` used to leave the cursor behind on a short read, so a cut inside a string looked
    # like a reader that stopped early with bytes to go — a lying header — and the operator got
    # the binary placeholder instead of the partial rendering `describes?` promises.
    name = "a" * 40
    mp = Bytes[0x81, 0xa4, 0x6e, 0x61, 0x6d, 0x65, 0xd9, name.bytesize.to_u8] + name.to_slice
    cut = mp[0, mp.size - 15]
    r = Gori::Msgpack.render(cut)
    r.stop.should eq("truncated")
    r.describes?(cut.size).should be_true
    r.json.should contain(%("name"))

    cb = "a1646e616d6578".hexbytes + Bytes[name.bytesize.to_u8] + name.to_slice
    ccut = cb[0, cb.size - 15]
    rc = Gori::Cbor.render(ccut)
    rc.stop.should eq("truncated")
    rc.describes?(ccut.size).should be_true
  end
end
