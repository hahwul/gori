require "./spec_helper"

private def mp(*bytes) : Bytes
  Bytes.new(bytes.size) { |i| bytes[i].to_u8 }
end

private def json_of(data : Bytes) : String
  Gori::Msgpack.to_json(data)[0]
end

private def complete?(data : Bytes) : Bool
  Gori::Msgpack.to_json(data)[1]
end

describe Gori::Msgpack do
  describe ".to_json" do
    it "reads the scalar forms" do
      json_of(mp(0x05)).should eq("5")
      json_of(mp(0xff)).should eq("-1") # negative fixint
      json_of(mp(0xc0)).should eq("null")
      json_of(mp(0xc2)).should eq("false")
      json_of(mp(0xc3)).should eq("true")
      json_of(mp(0xa3, 0x68, 0x69, 0x21)).should eq(%("hi!"))
    end

    it "reads containers, and a map with string keys stays an ordinary object" do
      json_of(mp(0x93, 0x01, 0x02, 0x03)).should eq("[1,2,3]")
      json_of(mp(0x81, 0xa1, 0x61, 0x01)).should eq(%({"a":1}))
      json_of(mp(0x90)).should eq("[]")
      json_of(mp(0x80)).should eq("{}")
    end

    it "says so when the map keys were not strings" do
      # JSON has only string keys. Rendering `1` as `"1"` and saying nothing would leave the
      # reader unable to tell it from a string key that really was "1".
      json_of(mp(0x81, 0x01, 0xa1, 0x78)).should eq(%({"1":"x","$keys":"non-string"}))
    end

    it "names a binary value instead of folding it into a string" do
      json_of(mp(0xc4, 0x02, 0xff, 0xfe)).should eq(%({"$bin":"//4="}))
    end

    it "names a str that is not valid UTF-8 rather than scrubbing it" do
      # Scrubbing would hand the operator bytes the origin never sent.
      json_of(mp(0xa2, 0xff, 0xfe)).should eq(%({"$str_invalid_utf8":"//4="}))
    end

    it "keeps a uint64 past Int64::MAX exact, as digits" do
      json_of(mp(0xcf, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff))
        .should eq(%("18446744073709551615"))
      json_of(mp(0xcf, 0, 0, 0, 0, 0, 0, 0, 0x2a)).should eq("42") # inside range: a number
    end

    it "sign-extends the fixed-width signed forms" do
      json_of(mp(0xd0, 0xff)).should eq("-1")
      json_of(mp(0xd1, 0xff, 0xfe)).should eq("-2")
      json_of(mp(0xd2, 0xff, 0xff, 0xff, 0xfd)).should eq("-3")
    end

    it "reads floats, and names the ones JSON has no literal for" do
      json_of(mp(0xcb, 0x3f, 0xf8, 0, 0, 0, 0, 0, 0)).should eq("1.5")
      json_of(mp(0xca, 0x3f, 0xc0, 0, 0)).should eq("1.5")
      json_of(mp(0xcb, 0x7f, 0xf8, 0, 0, 0, 0, 0, 0)).should eq(%({"$float":"NaN"}))
      json_of(mp(0xcb, 0x7f, 0xf0, 0, 0, 0, 0, 0, 0)).should eq(%({"$float":"Infinity"}))
    end

    it "carries an ext through with its type, and decodes the one the spec defines" do
      # An application's own ext type is what an operator is usually looking at, so it keeps
      # its number; -1 is the spec's timestamp, and base64 there would be withholding a fact.
      json_of(mp(0xd6, 0x05, 0xde, 0xad, 0xbe, 0xef))
        .should eq(%({"$ext":"3q2+7w==","$ext_type":5}))
      # The bytes ride along with the reading: `$timestamp` is second-resolution and the wider
      # forms carry nanoseconds, so without `$ext` the reading is unreconstructible.
      json_of(mp(0xd6, 0xff, 0, 0, 0, 0))
        .should eq(%({"$timestamp":"1970-01-01T00:00:00Z","$ext":"AAAAAA==","$ext_type":-1}))
    end
  end

  # Vectors produced by an INDEPENDENT implementation (python-msgpack 1.2.1, `use_bin_type`),
  # not by hand: a hand-written fixture encodes whatever the author believed the spec says, so
  # it agrees with a misreading. These caught one — `int64` was being converted rather than
  # reinterpreted, and every negative one raised `OverflowError` out of a module whose whole
  # contract is that it does not raise.
  describe "against a reference encoder" do
    it "reads what python-msgpack writes" do
      {
        {"80", "{}"},
        {"84a16101a162a374776fa163c0a164c3", %({"a":1,"b":"two","c":null,"d":true})},
        {"82a17893010281a179fda17a81a46465657081a664656570657292c3c2",
         %({"x":[1,2,{"y":-3}],"z":{"deep":{"deeper":[true,false]}}})},
        {"81a16ecfffffffffffffffff", %({"n":"18446744073709551615"})},
        {"95ffd0dfd1ff7fd2ffff7fffd3ffffffff7fffffff", "[-1,-33,-129,-32769,-2147483649]"},
        {"93cb3ff8000000000000cbbfc0000000000000cb400921fb54442d18",
         "[1.5,-0.125,3.141592653589793]"},
        {"81a4626c6f62c403fffe00", %({"blob":{"$bin":"//4A"}})},
        {"dc0014000102030405060708090a0b0c0d0e0f10111213",
         "[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]"},
        {"8201a36f6e6502a374776f", %({"1":"one","2":"two","$keys":"non-string"})},
      }.each do |(hex, want)|
        json, ok = Gori::Msgpack.to_json(hex.hexbytes)
        ok.should be_true
        json.should eq(want)
      end
    end

    it "reinterprets an int64 rather than converting it" do
      json_of(mp(0xd3, 0x80, 0, 0, 0, 0, 0, 0, 0)).should eq(Int64::MIN.to_s)
      json_of(mp(0xd3, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff)).should eq(Int64::MAX.to_s)
    end
  end

  describe "map keys" do
    it "decides string-vs-not off the key's HEADER, never off its rendering" do
      # A `uint64` past Int64::MAX renders as digits so it stays exact — the one non-string
      # type whose rendering is a JSON string. Testing the text read it as string-keyed and
      # dropped the marker, so a map keyed only on wide integers was byte-identical to one
      # really keyed on the decimal string.
      # The member name is the key's own JSON TEXT, quotes included — which is what makes it
      # visible that the key RENDERED as a string rather than being one. Same shape the CBOR
      # sibling produces for the same document.
      wide = mp(0x81, 0xcf, 0x80, 0, 0, 0, 0, 0, 0, 0, 0x01)
      json_of(wide).should eq(%q({"\"9223372036854775808\"":1,"$keys":"non-string"}))
      # …and a real string key by that name is still plain.
      digits = "9223372036854775808"
      real = Bytes[0x81, 0xa0_u8 + digits.bytesize.to_u8] + digits.to_slice + Bytes[0x01]
      json_of(real).should eq(%({"9223372036854775808":1}))
    end

    it "treats a `bin` key as non-string — it is a byte string, not text" do
      json_of(mp(0x81, 0xc4, 0x01, 0x61, 0x01))
        .should eq(%q({"{\"$bin\":\"YQ==\"}":1,"$keys":"non-string"}))
    end
  end

  describe "hostile and truncated input" do
    it "renders what it read and reports the parse as incomplete" do
      json, ok = Gori::Msgpack.to_json(mp(0x93, 0x01, 0x02))
      ok.should be_false
      # The marker NAMES why, where a bare `null` would have been indistinguishable from a
      # document whose third element really is nil.
      json.should eq(%([1,2,{"$partial":"truncated"}]))
    end

    it "reports trailing bytes as incomplete — the rendering is not the whole body" do
      complete?(mp(0x01)).should be_true
      complete?(mp(0x01, 0x02)).should be_false
    end

    it "refuses the one byte the spec leaves undefined" do
      complete?(mp(0xc1)).should be_false
    end

    it "stops at the depth ceiling instead of blowing the stack" do
      deep = Bytes.new(Gori::Msgpack::MAX_DEPTH + 8) { 0x91_u8 } # nested fixarrays, no leaf
      json, ok = Gori::Msgpack.to_json(deep)
      ok.should be_false
      json.should start_with("[[[")
    end

    it "bounds a chain of maps-as-VALUES, not only of arrays" do
      # The sibling CBOR reader had exactly this gap: a map's value was read at the map's own
      # depth, so nesting through values did not count at all and the JSON builder's own limit
      # was what eventually stopped it — discarding the whole document.
      io = IO::Memory.new
      (Gori::Msgpack::MAX_DEPTH + 8).times { io.write(Bytes[0x81, 0xa1, 0x61]) } # {"a": {...}}
      io.write(Bytes[0x01])
      json, ok = Gori::Msgpack.to_json(io.to_slice)
      ok.should be_false
      json.should start_with(%({"a":{"a":))
      JSON.parse(json) # and it is still a document
    end

    it "bounds items across the WHOLE document, not per container" do
      io = IO::Memory.new
      io.write(Bytes[0xdd, 0x00, 0x01, 0xd4, 0xc0]) # array32 of 119_999 elements
      (Gori::Msgpack::MAX_ITEMS + 1000).times { io.write(Bytes[0x00]) }
      json, ok = Gori::Msgpack.to_json(io.to_slice)
      ok.should be_false
      JSON.parse(json)
    end

    # The depth and item ceilings bound the INPUT walk. Neither bounds the OUTPUT, and a map
    # keyed on a MAP is where the two part company: `map` renders a non-string key as its own
    # JSON text and uses that text as the member name, so every level nests the level below
    # inside a JSON string and the escaping roughly doubles it. `81` is one byte per level.
    it "bounds the OUTPUT of a map keyed on a map" do
      # `81`*29, a nil key at the bottom, then a nil value per level — every map closed, so the
      # parse has no other reason to stop. 59 bytes raised `IO::EOFError` out of
      # `String::Builder` before the ceiling, from a body a target can put on the wire and an
      # operator only has to LOOK at (`Pretty#try_binary_doc`, `gori run show --format json`).
      io = IO::Memory.new
      29.times { io.write_byte(0x81_u8) }
      30.times { io.write_byte(0xc0_u8) }
      json, ok = Gori::Msgpack.to_json(io.to_slice)
      ok.should be_false
      json.bytesize.should be < Gori::Msgpack::MAX_JSON_BYTES
      json.should contain("$partial")
      JSON.parse(json) # and it is still a document
    end

    it "leaves an ordinary document untouched" do
      # The ceiling is a ceiling, not a rewrite: a body nowhere near it renders as it did.
      json_of(mp(0x82, 0xa1, 0x61, 0x01, 0xa1, 0x62, 0x92, 0x02, 0x03)).should eq(%({"a":1,"b":[2,3]}))
    end

    it "names the stop when a map gives up on its KEY" do
      # `81`*40 — the depth ceiling trips inside the key render, which writes into a scratch
      # builder, so nothing had been written into the map itself and it closed as a bare `{}`:
      # "an empty map", with `complete` false and no reason anywhere in the text. The CBOR
      # sibling has always named it.
      json, ok = Gori::Msgpack.to_json(Bytes.new(40) { 0x81_u8 })
      ok.should be_false
      json.should contain("$partial")
      JSON.parse(json)
    end

    it "does not allocate on a length no body could satisfy" do
      # bin32 claiming 4 GiB with four bytes behind it, and array32 / map32 claiming 4 G
      # elements. A count that cannot be an Int32 never reaches a loop or an allocation.
      complete?(mp(0xc6, 0xff, 0xff, 0xff, 0xff)).should be_false
      complete?(mp(0xdd, 0xff, 0xff, 0xff, 0xff)).should be_false
      complete?(mp(0xdf, 0xff, 0xff, 0xff, 0xff)).should be_false
    end

    it "renders a container whose declared count outruns the body, up to where it stops" do
      # 16.7 M elements declared, three bytes behind it: the loop ends at the first element
      # that has no input left, rather than either looping 16 M times or refusing the body.
      json, ok = Gori::Msgpack.to_json(mp(0xdd, 0x00, 0xff, 0xff, 0xff, 0x01, 0x02))
      ok.should be_false
      json.should eq(%([1,2,{"$partial":"truncated"}]))
    end

    it "never raises, on any single byte" do
      (0..255).each do |b|
        Gori::Msgpack.to_json(Bytes[b.to_u8])
      end
      # …or on a fuzzy walk over the type table with nothing behind the headers.
      (0..255).each do |b|
        Gori::Msgpack.to_json(Bytes[b.to_u8, 0xff_u8, 0x00_u8, 0x7f_u8])
      end
    end

    it "names an empty body rather than rendering a bare null" do
      json, ok = Gori::Msgpack.to_json(Bytes.empty)
      json.should eq(%({"$partial":"truncated"}))
      ok.should be_false
    end
  end

  describe "the rendering record" do
    it "reports how far it got and why it stopped, which is what tells truncation from a lie" do
      whole = Gori::Msgpack.render(mp(0x91, 0x01))
      whole.complete.should be_true
      whole.stop.should be_nil
      whole.consumed.should eq(2)
      whole.describes?(2).should be_true

      # Cut short: consumed every byte it was given and wanted more. This IS the body.
      cut = Gori::Msgpack.render(mp(0x93, 0x01, 0x02))
      cut.stop.should eq("truncated")
      cut.consumed.should eq(3)
      cut.describes?(3).should be_true

      # A complete value with a tail behind it — the shape a gzip or JSON body makes when a
      # header claims msgpack. Not this document.
      tail = Gori::Msgpack.render("{\"a\":1}".to_slice)
      tail.stop.should eq("trailing")
      tail.describes?(6).should be_false

      # Stopped on a byte it could not read, with bytes to go. Also not this document.
      bad = Gori::Msgpack.render(mp(0x92, 0xc1, 0x01))
      bad.stop.should eq("malformed")
      bad.describes?(3).should be_false
    end

    it "renders with an indent when asked, without a re-parse" do
      # The text goes to a caller verbatim: a document may carry a DUPLICATE member, and
      # `JSON.parse(...).to_pretty_json` would keep one and silently drop the other.
      dup = Gori::Msgpack.render(mp(0x82, 0xa1, 0x61, 0x01, 0xa1, 0x61, 0x02), indent: "  ")
      dup.json.should eq(%({\n  "a": 1,\n  "a": 2\n}))
    end
  end
end
