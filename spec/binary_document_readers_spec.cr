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

  # The pair `describes?` has to separate, and they pull opposite ways: the FIRST header of a
  # mislabelled body lies about a length and the short read then consumes every byte, landing on
  # the same `{truncated, consumed == size}` a capture cap lands on. `{` is CBOR major 3 /
  # additional info 27, so an ordinary JSON body under an `application/cbor` label reads as a
  # text string of 2.4 × 10^18 bytes — and a 20 KB response was replaced in the detail panel by
  # `{"$partial": "truncated"}`, with the binary placeholder suppressed because a document had
  # "decoded". What separates them is whether the reader made ANYTHING of the body.
  it "refuses a body whose first header lied, and shows one the capture cap cut" do
    rng = Random.new(5)
    tail = Bytes.new(20_000) { rng.rand(256).to_u8 }
    mislabelled = {
      {"json", (%({"key":") + "A" * 20_000 + %("})).to_slice},
      {"small json", %({"a":1,"b":"hi"}).to_slice},
      {"html", "<html><body>x</body></html>".to_slice},
      {"png", Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] + tail},
      {"gzip", Bytes[0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03] + tail},
      {"zlib", Bytes[0x78, 0x9c] + tail},
    }
    shown = [] of String
    mislabelled.each do |(label, body)|
      shown << "cbor #{label}" if Gori::Cbor.render(body).describes?(body.size)
      shown << "msgpack #{label}" if Gori::Msgpack.render(body).describes?(body.size)
    end
    shown.should eq([] of String)
  end

  it "shows EVERY prefix of a real document, which is what a capture cap produces" do
    # The other half of the pair, and the one a fix for the first half breaks. Cutting a real
    # document at every offset is exactly what a body cap does, and each cut has to stay
    # readable — `read_arg`'s short read used to leave the cursor on the head's initial byte,
    # so a cut landing inside a LENGTH field reported two bytes consumed out of two thousand
    # and `describes?` called a 2 KB rendering a lie. Sweeping the prefixes is the only way
    # this is visible: 172 of 2 247 CBOR prefixes were refused, and the count is 0.
    # Both written by an INDEPENDENT encoder (see "against a reference encoder" in each
    # reader's spec) from one value: nested maps, arrays, a float, a byte string, a wide
    # integer — so the cut lands inside a head, an argument, a count and a payload in turn.
    docs = {
      {"cbor", ("a66269647175726e3a757569643a39633866316434306274731a68aa6eff647573657" \
                "2a2646e616d656668616877756c65726f6c6573826561646d696e6761756469746f72" \
                "656974656d7381a463736b7568534b552d303030316371747903657072696365fb3ff8" \
                "00000000000064626c6f62480001020304050607626f6bf5646e6f7465f6")
                  .hexbytes},
      {"msgpack", ("86a26964b175726e3a757569643a3963386631643430a27473ce68aa6effa4757365" \
                   "7282a46e616d65a668616877756ca5726f6c657392a561646d696ea761756469746f" \
                   "72a56974656d739184a3736b75a8534b552d30303031a371747903a57072696365cb" \
                   "3ff8000000000000a4626c6f62c4080001020304050607a26f6bc3a46e6f7465c0")
                     .hexbytes},
    }
    docs.each do |(fmt, doc)|
      refused = [] of String
      (1..doc.size).each do |n|
        cut = doc[0, n]
        r = fmt == "cbor" ? Gori::Cbor.render(cut) : Gori::Msgpack.render(cut)
        refused << "#{fmt} #{n}: #{r.stop} #{r.json[0, 40]}" unless r.describes?(n)
      end
      refused.should eq([] of String)
    end
  end
end
