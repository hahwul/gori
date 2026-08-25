require "./spec_helper"
require "base64"
require "json"

private alias CB = Gori::Cbor

# Render a body written as hex — the spelling RFC 8949 Appendix A uses, so the
# vectors below can be read straight off the table.
private def render(hex : String) : {String, Bool}
  CB.to_json(hex.hexbytes)
end

# Render a body that must decode completely, and return just the JSON text.
private def whole(hex : String) : String
  text, complete = render(hex)
  complete.should be_true
  text
end

# The numeric value of a body that renders as a bare JSON number.
private def number(hex : String) : Float64
  JSON.parse(whole(hex)).as_f
end

# Nothing decoded at all: the whole render is one marker naming why.
private def only_partial(hex : String, reason : String) : Nil
  text, complete = render(hex)
  complete.should be_false
  text.should eq(%({"$partial":"#{reason}"}))
end

describe Gori::Cbor do
  # RFC 8949 Appendix A, "Examples of Encoded CBOR Data Items". The table is the
  # only conformance suite CBOR has; these are its canonical rows.
  describe "RFC 8949 Appendix A vectors" do
    it "decodes unsigned integers" do
      whole("00").should eq("0")
      whole("0a").should eq("10")
      whole("17").should eq("23")
      whole("1818").should eq("24")
      whole("1903e8").should eq("1000")
      whole("1a000f4240").should eq("1000000")
      whole("1b000000e8d4a51000").should eq("1000000000000")
    end

    it "decodes negative integers" do
      whole("20").should eq("-1")
      whole("29").should eq("-10")
      whole("3863").should eq("-100")
      whole("3903e7").should eq("-1000")
    end

    it "decodes byte strings" do
      whole("40").should eq(%({"$bin":""}))
      whole("4401020304").should eq(%({"$bin":"AQIDBA=="}))
    end

    it "decodes text strings" do
      whole("60").should eq(%(""))
      whole("6161").should eq(%("a"))
      whole("6449455446").should eq(%("IETF"))
      whole("63e6b0b4").should eq(%("水"))
      # "\" — the two characters JSON has to escape.
      JSON.parse(whole("62225c")).as_s.should eq("\"\\")
    end

    it "decodes arrays" do
      whole("80").should eq("[]")
      whole("83010203").should eq("[1,2,3]")
      whole("8301820203820405").should eq("[1,[2,3],[4,5]]")
      whole("98190102030405060708090a0b0c0d0e0f101112131415161718181819")
        .should eq("[#{(1..25).join(",")}]")
    end

    it "decodes maps" do
      whole("a0").should eq("{}")
      whole("a26161016162820203").should eq(%({"a":1,"b":[2,3]}))
      whole("826161a161626163").should eq(%(["a",{"b":"c"}]))
      whole("a56161614161626142616361436164614461656145")
        .should eq(%({"a":"A","b":"B","c":"C","d":"D","e":"E"}))
    end

    it "decodes the major-7 literals" do
      whole("f4").should eq("false")
      whole("f5").should eq("true")
      whole("f6").should eq("null")
    end

    it "decodes floats" do
      number("f90000").should eq(0.0)
      number("f93c00").should eq(1.0)
      number("fb3ff199999999999a").should eq(1.1)
      number("f93e00").should eq(1.5)
      number("f97bff").should eq(65504.0)
      number("fa47c35000").should eq(100000.0)
      number("fa7f7fffff").should eq(3.4028234663852886e+38)
      number("fb7e37e43c8800759c").should eq(1.0e+300)
      number("f90001").should eq(5.960464477539063e-8) # smallest half subnormal
      number("f90400").should eq(6.103515625e-5)       # smallest half normal
      number("f9c400").should eq(-4.0)
      number("fbc010666666666666").should eq(-4.1)
    end

    it "decodes indefinite-length forms" do
      whole("5f42010243030405ff").should eq(%({"$bin":"AQIDBAU="}))
      whole("7f657374726561646d696e67ff").should eq(%("streaming"))
      whole("9fff").should eq("[]")
      whole("9f018202039f0405ffff").should eq("[1,[2,3],[4,5]]")
      whole("9f01820203820405ff").should eq("[1,[2,3],[4,5]]")
      whole("83018202039f0405ff").should eq("[1,[2,3],[4,5]]")
      whole("83019f0203ff820405").should eq("[1,[2,3],[4,5]]")
      whole("bf61610161629f0203ffff").should eq(%({"a":1,"b":[2,3]}))
      whole("826161bf61626163ff").should eq(%(["a",{"b":"c"}]))
      whole("bf6346756ef563416d7421ff").should eq(%({"Fun":true,"Amt":-2}))
    end
  end

  describe "integers that JSON cannot hold" do
    it "emits a uint past Int64 as a decimal string, not a wrong number" do
      # 1b ff ff ff ff ff ff ff ff — 2^64-1. As a JSON number literal every
      # 64-bit reader either overflows or rounds it.
      whole("1bffffffffffffffff").should eq(%("18446744073709551615"))
      # …and one below the boundary is still a real number.
      whole("1b7fffffffffffffff").should eq("9223372036854775807")
    end

    it "emits a negative past Int64 as a decimal string" do
      whole("3bffffffffffffffff").should eq(%("-18446744073709551616"))
      # 3b 7f ff … is -2^63 exactly: the last one that fits.
      whole("3b7ffffffffffffffe").should eq("-9223372036854775807")
      whole("3b7fffffffffffffff").should eq("-9223372036854775808")
    end
  end

  describe "byte strings and invalid UTF-8" do
    it "envelopes a byte string in $bin rather than guessing at text" do
      whole("4401020304").should eq(%({"$bin":"AQIDBA=="}))
      Base64.decode(JSON.parse(whole("4401020304"))["$bin"].as_s)
        .should eq(Bytes[0x01, 0x02, 0x03, 0x04])
    end

    it "never scrubs invalid UTF-8 in a text string" do
      # 62 ff fe — a text string whose two bytes are not UTF-8 at all.
      whole("62fffe").should eq(%({"$str_invalid_utf8":"//4="}))
      Base64.decode(JSON.parse(whole("62fffe"))["$str_invalid_utf8"].as_s)
        .should eq(Bytes[0xff, 0xfe])
    end

    it "keeps the document parseable when a text string is not UTF-8" do
      # The point of the envelope: writing the raw bytes as a JSON string would
      # make the whole render unparseable.
      text, _ = render("826161" + "62fffe")
      JSON.parse(text).as_a.size.should eq(2)
    end
  end

  describe "maps with non-string keys" do
    it "renders the key as its own JSON text and flags the map" do
      whole("a201020304").should eq(%({"1":2,"3":4,"$non_string_keys":true}))
    end

    it "handles a composite key" do
      # a1 82 01 02 03 — {[1,2]: 3}
      whole("a182010203").should eq(%({"[1,2]":3,"$non_string_keys":true}))
    end

    it "treats an invalid-UTF-8 text key as a non-string key" do
      json = JSON.parse(whole("a162fffe01"))
      json["$non_string_keys"].as_bool.should be_true
      json[%({"$str_invalid_utf8":"//4="})].as_i.should eq(1)
    end

    it "does not flag a map whose keys are all text" do
      whole("a26161016162820203").should_not contain("$non_string_keys")
    end

    it "passes duplicate keys through instead of merging them" do
      # a2 61 61 01 61 61 02 — {"a":1,"a":2}. Merging would hide a body built to
      # exploit which one a downstream parser keeps.
      whole("a2616101616102").should eq(%({"a":1,"a":2}))
    end
  end

  describe "tags" do
    it "envelopes an unknown tag without inventing a meaning" do
      whole("d74401020304").should eq(%({"$tag":23,"value":{"$bin":"AQIDBA=="}}))
      whole("d818456449455446").should eq(%({"$tag":24,"value":{"$bin":"ZElFVEY="}}))
      whole("d82076687474703a2f2f7777772e6578616d706c652e636f6d")
        .should eq(%({"$tag":32,"value":"http://www.example.com"}))
    end

    it "leaves a tag 0 date string exactly as the bytes spelled it" do
      whole("c074323031332d30332d32315432303a30343a30305a")
        .should eq(%({"$tag":0,"value":"2013-03-21T20:04:00Z"}))
    end

    it "adds a readable timestamp beside a tag 1 epoch number" do
      whole("c11a514b67b0")
        .should eq(%({"$tag":1,"$time":"2013-03-21T20:04:00Z","value":1363896240}))
    end

    it "handles a fractional tag 1 epoch and keeps the number verbatim" do
      json = JSON.parse(whole("c1fb41d452d9ec200000"))
      json["$time"].as_s.should eq("2013-03-21T20:04:00Z")
      json["value"].as_f.should eq(1363896240.5)
    end

    it "does not raise on a tag 1 whose epoch is outside Time's range" do
      # c1 1b 7f ff ff ff ff ff ff ff — year ~292 billion. `Time.unix` raises on
      # it, so $time is simply absent and the number still renders.
      json = JSON.parse(whole("c11b7fffffffffffffff"))
      json["$time"]?.should be_nil
      json["value"].as_i64.should eq(Int64::MAX)
    end

    it "falls back to the generic envelope for a mislabelled tag 1" do
      # c1 61 61 — tag 1 over a text string is not an epoch.
      whole("c16161").should eq(%({"$tag":1,"value":"a"}))
    end

    it "renders a tag 2 bignum as decimal and keeps the bytes" do
      whole("c249010000000000000000")
        .should eq(%({"$tag":2,"$bignum":"18446744073709551616","value":{"$bin":"AQAAAAAAAAAA"}}))
    end

    it "renders a tag 3 bignum as -1 - n" do
      whole("c349010000000000000000")
        .should eq(%({"$tag":3,"$bignum":"-18446744073709551617","value":{"$bin":"AQAAAAAAAAAA"}}))
    end

    it "renders small and zero bignums" do
      whole("c24401020304").should eq(%({"$tag":2,"$bignum":"16909060","value":{"$bin":"AQIDBA=="}}))
      whole("c240").should eq(%({"$tag":2,"$bignum":"0","value":{"$bin":""}}))
      whole("c340").should eq(%({"$tag":3,"$bignum":"-1","value":{"$bin":""}}))
    end

    it "drops the decimal (never the bytes) past MAX_BIGNUM_BYTES" do
      # A byte string one over the ceiling: base-256 to base-10 is quadratic, so
      # the decimal is the part that has to be bounded.
      size = CB::MAX_BIGNUM_BYTES + 1
      body = IO::Memory.new
      body.write_byte(0xc2_u8)
      body.write_byte(0x59_u8) # byte string, 2-byte length
      body.write_bytes(size.to_u16, IO::ByteFormat::BigEndian)
      size.times { body.write_byte(0xff_u8) }
      text, complete = CB.to_json(body.to_slice)
      complete.should be_true
      json = JSON.parse(text)
      json["$bignum"]?.should be_nil
      json["value"]["$bin"].as_s.size.should be > 0
      # …and SAYS it dropped it. Silence made a bignum whose decimal was declined identical to
      # a tag 2 the reader had never looked at, which is the one distinction this module exists
      # to keep (the msgpack sibling states the same rule over its `$ext` bytes).
      json["$bignum_omitted"].as_s.should eq("max_bignum_bytes")
    end

    it "bounds the total bignum work in one document, not only one bignum" do
      # `MAX_BIGNUM_BYTES` bounds ONE bignum and nothing bounded how many there were. Base-256
      # to base-10 is quadratic, so a 1 MiB body — a size `Pretty::MAX_PRETTY` hands straight to
      # this reader — packed with maximum-size bignums cost 770 ms of straight-line CPU against
      # 2.2 ms for the same body of plain byte strings. `build_detail_view` caches per selection,
      # so that is a blocking freeze every time the operator lands on the flow, and again on
      # every theme or `p` toggle.
      body = IO::Memory.new
      body.write_byte(0x9f_u8) # one indefinite array, so the whole body is ONE document
      while body.bytesize < 1_000_000
        body.write_byte(0xc2_u8)
        body.write_byte(0x59_u8)
        body.write_bytes(Gori::Cbor::MAX_BIGNUM_BYTES.to_u16, IO::ByteFormat::BigEndian)
        Gori::Cbor::MAX_BIGNUM_BYTES.times { body.write_byte(0xff_u8) }
      end
      body.write_byte(0xff_u8)

      t = Time.instant
      text, complete = CB.to_json(body.to_slice)
      ms = (Time.instant - t).total_milliseconds
      complete.should be_true
      # Loose on purpose — this guards against the unbounded path reopening, not a slow machine.
      ms.should be < 150.0
      # The budget is spent on the FIRST bignums and named on the rest; the bytes never go.
      text.should contain(%("$bignum":))
      text.should contain(%("$bignum_omitted":"max_bignum_work"))
      text.should_not contain("$partial")
    end

    it "falls back to the generic envelope for a mislabelled bignum" do
      whole("c201").should eq(%({"$tag":2,"value":1}))
    end
  end

  describe "major 7" do
    it "envelopes undefined and the simple values" do
      whole("f7").should eq(%({"$undefined":true}))
      whole("f0").should eq(%({"$simple":16}))
      whole("f818").should eq(%({"$simple":24}))
      whole("f8ff").should eq(%({"$simple":255}))
    end

    it "envelopes NaN and the infinities, which are not JSON numbers" do
      whole("f97c00").should eq(%({"$float":"Infinity"}))
      whole("f97e00").should eq(%({"$float":"NaN"}))
      whole("f9fc00").should eq(%({"$float":"-Infinity"}))
      whole("fa7f800000").should eq(%({"$float":"Infinity"}))
      whole("faff800000").should eq(%({"$float":"-Infinity"}))
      whole("fb7ff0000000000000").should eq(%({"$float":"Infinity"}))
      whole("fbfff0000000000000").should eq(%({"$float":"-Infinity"}))
    end

    it "keeps the document parseable with a NaN inside a container" do
      JSON.parse(whole("82f97e0001")).as_a[0]["$float"].as_s.should eq("NaN")
    end
  end

  describe "truncated and malformed input" do
    it "returns the items that did decode and reports partial" do
      # 83 01 02 — an array of three that stops after two.
      text, complete = render("830102")
      complete.should be_false
      text.should eq(%([1,2,{"$partial":"truncated"}]))
    end

    it "is partial on an empty body" do
      text, complete = CB.to_json(Bytes.empty)
      complete.should be_false
      text.should eq(%({"$partial":"truncated"}))
    end

    it "is partial when a map value is missing" do
      text, complete = render("a16161")
      complete.should be_false
      text.should eq(%({"a":{"$partial":"truncated"}}))
    end

    it "is partial, and still valid JSON, when a map key is missing" do
      # The map NAMES why it stopped rather than inventing a member out of the failed key's own
      # marker text. That text is a whole rendering, and using it as a member name is what made
      # a chain of maps-as-keys cost 2^depth to build (see "the output bound" below) — and it
      # also flagged `$non_string_keys` on a map where no key had been read at all.
      text, complete = render("a1")
      complete.should be_false
      text.should eq(%({"$partial":"truncated"}))
      JSON.parse(text).as_h.has_key?("$non_string_keys").should be_false
    end

    it "names the stop inside an indefinite-length map, like every other container" do
      # `bf` opens a map that ends at a `break`. The branch that runs out of input first set the
      # flags and wrote NOTHING, so the map closed as a bare `{}` — "an empty map", not "this
      # stopped" — with `complete` false and `$partial` nowhere in the text. Every consumer that
      # tests the TEXT (`Decoder::Codecs#document`) read that as a decode that worked, and
      # `bf 61 61 01` was worse: `{"a":1}`, a document that looks whole and is not.
      text, complete = render("bf")
      complete.should be_false
      text.should eq(%({"$partial":"truncated"}))

      text, complete = render("bf616101")
      complete.should be_false
      text.should eq(%({"a":1,"$partial":"truncated"}))

      # The sibling branches, which always did name it — this is the parity that had drifted.
      render("9f")[0].should eq(%([{"$partial":"truncated"}]))
      render("a2616101")[0].should eq(%({"a":1,"$partial":"truncated"}))
    end

    it "consumes what it looked at when a cut lands inside an item's ARGUMENT" do
      # A head's argument bytes are read by `read_arg`, which used to leave the cursor on the
      # INITIAL byte on a short read while `take` — the same situation one field over — moved it
      # to the end. `describes?` reads that gap as a header that lied, so every prefix of a real
      # document whose cut landed inside a length field got the binary placeholder instead of
      # the kilobytes that had already decoded.
      {"1b0000", "1900", "5a0001", "1a00"}.each do |hex|
        r = CB.render(hex.hexbytes)
        r.stop.should eq("truncated")
        r.consumed.should eq(hex.hexbytes.size)
      end
    end

    it "is partial when an indefinite container never breaks" do
      text, complete = render("9f0102")
      complete.should be_false
      text.should eq(%([1,2,{"$partial":"truncated"}]))
    end

    it "rejects a reserved additional-info value" do
      # 1c..1e are reserved by RFC 8949 §3 and have never been assigned.
      %w[1c 1d 1e].each do |hex|
        text, complete = render(hex)
        complete.should be_false
        text.should eq(%({"$partial":"malformed"}))
      end
    end

    it "rejects an indefinite integer and an indefinite tag" do
      only_partial("1f", "malformed")
      only_partial("3f", "malformed")
      only_partial("df", "malformed")
    end

    it "rejects a break with no container to close" do
      only_partial("ff", "malformed")
    end

    it "rejects an indefinite string chunk of the wrong major type" do
      # 5f 61 61 ff — a byte string whose chunk is a text string.
      only_partial("5f6161ff", "malformed")
    end

    it "reports trailing bytes rather than dropping them" do
      # One item, then a second: a CBOR sequence (RFC 8742) is a different media
      # type, so the first item renders and the leftovers make it partial.
      text, complete = render("0001")
      complete.should be_false
      text.should eq("0")
    end
  end

  describe "bounds" do
    it "stops a depth bomb without overflowing the stack" do
      # 81 81 81 … — three bytes per array level is all a crafted body needs.
      text, complete = render(("81" * (CB::MAX_DEPTH + 8)) + "00")
      complete.should be_false
      text.should contain(%({"$partial":"max_depth"}))
      JSON.parse(text) # still one well-formed document
    end

    it "stops an item bomb" do
      # 9f 00 00 00 … — one byte per item, which a per-container limit would
      # wave through.
      body = IO::Memory.new
      body.write_byte(0x9f_u8)
      (CB::MAX_ITEMS + 10).times { body.write_byte(0x00_u8) }
      body.write_byte(0xff_u8)
      text, complete = CB.to_json(body.to_slice)
      complete.should be_false
      text.should contain(%({"$partial":"max_items"}))
    end

    it "does not allocate on a claimed length with no bytes behind it" do
      # 5b ff ff ff ff ff ff ff ff — a byte string claiming 2^64-1 bytes.
      only_partial("5bffffffffffffffff", "truncated")
      only_partial("7bffffffffffffffff", "truncated")
    end

    it "does not loop on a container claiming 2^64 entries" do
      # The count is never trusted; the first unreadable entry ends the loop.
      text, complete = render("9bffffffffffffffff")
      complete.should be_false
      text.should eq(%([{"$partial":"truncated"}]))
      text, complete = render("bbffffffffffffffff")
      complete.should be_false
      JSON.parse(text)
    end

    it "honours a caller-supplied max_depth" do
      text, complete = CB.to_json("8181810100".hexbytes, max_depth: 1)
      complete.should be_false
      text.should contain("max_depth")
    end
  end

  describe "never raises" do
    it "produces valid JSON for arbitrary bytes" do
      rng = Random.new(0xc807)
      600.times do
        data = Bytes.new(rng.rand(1..48)) { rng.rand(256).to_u8 }
        text, _complete = CB.to_json(data)
        # The strong invariant: whatever went in, what comes out parses.
        JSON.parse(text)
      end
    end

    it "produces valid JSON for every truncation of a real body" do
      full = "a3616183010203616283f97e00c11a514b67b0c2490100000000000000006163bf61616162ff".hexbytes
      (0..full.size).each do |n|
        text, _complete = CB.to_json(full[0, n])
        JSON.parse(text)
      end
      CB.to_json(full)[1].should be_true
    end
  end

  # Vectors produced by an INDEPENDENT implementation (python `cbor2`), not by hand: a
  # hand-written fixture agrees with whatever the author believed the spec says. The sibling
  # `Gori::Msgpack` had exactly one bug and this is the shape that found it — `Int64::MIN`,
  # which major type 1 reaches as `-1 - 0x7fffffffffffffff` and a checked conversion raises on.
  describe "against a reference encoder" do
    it "reads what python-cbor2 writes" do
      {
        {"a0", "{}"},
        {"a461610161626374776f6163f66164f5", %({"a":1,"b":"two","c":null,"d":true})},
        {"a26178830102a1617922617aa1646465657082f5f4",
         %({"x":[1,2,{"y":-3}],"z":{"deep":[true,false]}})},
        {"1bffffffffffffffff", %("18446744073709551615")},
        {"86203738ff39ffff3affffffff3b7fffffffffffffff",
         "[-1,-24,-256,-65536,-4294967296,-9223372036854775808]"},
        {"83fb3ff8000000000000fbbfc0000000000000fb400921fb54442d18",
         "[1.5,-0.125,3.141592653589793]"},
        {"a164626c6f6243fffe00", %({"blob":{"$bin":"//4A"}})},
        {"94000102030405060708090a0b0c0d0e0f10111213",
         "[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]"},
        {"9f018202039f0405ffff", "[1,[2,3],[4,5]]"},      # indefinite array, RFC 8949 App. A
        {"bf61610161629f0203ffff", %({"a":1,"b":[2,3]})}, # indefinite map
        {"7f657374726561646d696e67ff", %("streaming")},   # indefinite text
        {"f93c00", "1.0"},                                # half float
      }.each do |(hex, want)|
        json, ok = Gori::Cbor.to_json(hex.hexbytes)
        ok.should be_true
        json.should eq(want)
      end
    end

    it "reads a bignum and an epoch tag beside their raw value, never instead of it" do
      Gori::Cbor.to_json("c249400000000000000000".hexbytes)[0]
        .should eq(%({"$tag":2,"$bignum":"1180591620717411303424","value":{"$bin":"QAAAAAAAAAAA"}}))
      Gori::Cbor.to_json("c074323032302d30312d30325430333a30343a30355a".hexbytes)[0]
        .should eq(%({"$tag":0,"value":"2020-01-02T03:04:05Z"}))
    end
  end
  describe "the depth bound binds on every path that recurses" do
    # Found by an adversarial pass, not by construction: a map's VALUE was read at the map's
    # own depth, so a chain of maps-as-values did not count as nesting AT ALL. Arrays and tags
    # were always right, which is why every hand-written nesting spec passed.
    it "bounds a chain of maps-as-values" do
      # {"a": {"a": … }} — `a1 61 61` is one map with the text key "a".
      io = IO::Memory.new
      (Gori::Cbor::MAX_DEPTH + 8).times { io.write(Bytes[0xa1, 0x61, 0x61]) }
      io.write(Bytes[0x01])
      json, ok = Gori::Cbor.to_json(io.to_slice)
      ok.should be_false
      json.should contain("max_depth")
      JSON.parse(json) # and it is still a document
    end

    it "bounds a chain deep enough to have blown the JSON builder's own limit" do
      # ~100 levels tripped `JSON::Builder`'s nesting cap, and the rescue at the public
      # boundary turned that into `{"$partial":"internal"}` — a mostly-legible document
      # discarded whole. The bound exists so that limit is never what stops us.
      io = IO::Memory.new
      5_000.times { io.write(Bytes[0xa1, 0x61, 0x61]) }
      io.write(Bytes[0x01])
      json, _ = Gori::Cbor.to_json(io.to_slice)
      json.should contain("max_depth")
      json.should_not contain("internal")
      json.should start_with(%({"a":{"a":)) # what WAS legible is still rendered
    end

    it "bounds arrays and tag chains the same way" do
      arr = Bytes.new(Gori::Cbor::MAX_DEPTH + 8) { 0x81_u8 }
      Gori::Cbor.to_json(arr)[0].should contain("max_depth")
      tags = Bytes.new(Gori::Cbor::MAX_DEPTH + 8) { 0xc0_u8 } # tag 0, chained
      Gori::Cbor.to_json(tags)[0].should contain("max_depth")
    end

    it "bounds items across the WHOLE document, not per container" do
      # The cheap bomb is flat, not nested: an indefinite array of one-byte items.
      io = IO::Memory.new
      io.write(Bytes[0x9f])
      (Gori::Cbor::MAX_ITEMS + 1000).times { io.write(Bytes[0x00]) }
      io.write(Bytes[0xff])
      json, ok = Gori::Cbor.to_json(io.to_slice)
      ok.should be_false
      json.should contain("max_items")
    end
  end

  # The depth and item ceilings bound the INPUT walk. Neither bounds the OUTPUT, and a map
  # keyed on a MAP is where the two part company: `map_item` renders a non-string key as its
  # own JSON text and uses that text as the member name, so every level nests the level below
  # inside a JSON string and the escaping roughly doubles it. `a1` is one byte per level.
  describe "the output bound" do
    it "does not BUILD a chain of maps-as-keys that runs out of input" do
      # 28 bytes. Before the ceiling this reached 2^32 and raised `IO::EOFError` out of
      # `String::Builder`, ten seconds in — from a body a target can put on the wire and an
      # operator only has to LOOK at (`Pretty#try_binary_doc`, `gori run show --format json`).
      # The ceiling stopped the crash and still paid the 2^depth to reach it: `a1` × 24 spent
      # 46 ms walking to 8 MiB, ~1 000× the msgpack sibling on `81` × 24. `pair` no longer uses
      # a FAILED key's marker text as the member name, so there is nothing left to re-escape
      # and the work is linear in the depth. Measured next to the sibling, both under a
      # millisecond.
      json, ok = CB.to_json(Bytes.new(28) { 0xa1_u8 })
      ok.should be_false
      json.should eq(%({"$partial":"truncated"}))

      t = Time.instant
      50.times { CB.to_json(Bytes.new(24) { 0xa1_u8 }) }
      cbor_ms = (Time.instant - t).total_milliseconds
      t = Time.instant
      50.times { Gori::Msgpack.to_json(Bytes.new(24) { 0x81_u8 }) }
      msgpack_ms = (Time.instant - t).total_milliseconds
      # Loose on purpose: this guards against the 2^depth path reopening, not against a slow
      # machine. 50 rounds took ~2 300 ms before and under 1 ms after.
      cbor_ms.should be < 200.0
      cbor_ms.should be < msgpack_ms + 200.0
    end

    it "bounds one whose keys all terminate, not only a truncated one" do
      # `a1`*22 then `f6`*23 — every map closed, nothing running out of input, so the parse
      # has no other reason to stop. 45 bytes rendered 16.7 MB before the ceiling.
      io = IO::Memory.new
      22.times { io.write_byte(0xa1_u8) }
      23.times { io.write_byte(0xf6_u8) }
      json, ok = CB.to_json(io.to_slice)
      ok.should be_false
      json.bytesize.should be < Gori::Cbor::MAX_JSON_BYTES
      json.should contain("max_bytes")
    end

    it "bounds it at the depth ceiling too, where the walk itself is legal" do
      # Every level is inside MAX_DEPTH, so nothing about the INPUT is out of bounds.
      json, _ = CB.to_json(Bytes.new(5_000) { 0xa1_u8 })
      json.bytesize.should be < Gori::Cbor::MAX_JSON_BYTES
    end

    it "leaves an ordinary document untouched" do
      # The ceiling is a ceiling, not a rewrite: a body nowhere near it renders as it did.
      whole("a26161016162820203").should eq(%({"a":1,"b":[2,3]}))
    end
  end
end
