require "../../spec_helper"
require "../../support/serialized_vectors"

private alias V = Gori::Decoder::Serialized::DotnetViewState

private def read(data : Bytes) : String
  V.render(data).json
end

private def e7(n : Int32) : Bytes
  SerializedVectors.e7(n)
end

private def vs(body : Bytes) : Bytes
  Bytes[0xff, 0x01] + body
end

private def str(s : String) : Bytes
  Bytes[5] + e7(s.bytesize) + s.to_slice
end

describe Gori::Decoder::Serialized::DotnetViewState do
  it "reads the classic /wE… sample into the Pair/Triplet tree it is" do
    doc = SerializedVectors::VIEWSTATE_CLASSIC
    r = V.render(doc)
    r.complete.should be_true
    r.describes?(doc.size).should be_true
    r.json.should eq(
      %({"$format":"aspnet-viewstate","version":1,"state":{"$pair":[{"$pair":["-162691655",) +
      %({"$pair":[null,[3,{"$pair":[null,[1,{"$pair":[{"$pair":[["Text","Hello World"],null]}) +
      %(,null]}]]}]]}]},null]},"mac":false}))
  end

  it "names a MAC by its length, and says so when there is none" do
    # A ViewState carries no marker for its signature — `GetDecodedData` just strips the hash
    # off the end — so a short trailing run IS the MAC. Leaving it as trailing bytes would make
    # `describes?` refuse the majority of real, signed ViewStates.
    doc = SerializedVectors::VIEWSTATE_CLASSIC
    {20 => "SHA1 / HMACSHA1", 32 => "HMACSHA256", 64 => "HMACSHA512"}.each do |n, algo|
      signed = doc + Bytes.new(n, 0xab_u8)
      r = V.render(signed)
      r.describes?(signed.size).should be_true
      r.json.should contain(%("mac":{"bytes":#{n},"algorithm":"#{algo}"))
    end
    # MAC-absent is the finding, not the absence of a finding (CVE-2020-0688's precondition).
    read(doc).should contain(%("mac":false))
  end

  it "refuses a body with a long trailing run, which was never a ViewState" do
    doc = SerializedVectors::VIEWSTATE_CLASSIC + Bytes.new(300, 0x41_u8)
    V.render(doc).describes?(doc.size).should be_false
  end

  it "tells the two indexed-string tokens apart, and resolves the reference" do
    # `Token_IndexedStringAdd` is 30 and `Token_IndexedString` is 31 — the two are trivially
    # transposable, and the classic vector only exercises the ADD form, so swapping them would
    # leave every other example here green. This one pins the pair: the same text has to come
    # back from the reference as from the add.
    body = Bytes[22] + e7(3) +
           Bytes[30] + e7(4) + "Text".to_slice +
           Bytes[31, 0] +
           Bytes[31, 9]
    read(vs(body)).should contain(%("state":["Text","Text",{"$string_index":9}]))
  end

  it "keeps a non-text indexed string in the table, because the index is POSITIONAL" do
    # Dropping an entry that is not UTF-8 shifts every later `Token_IndexedString` by one, so
    # the index resolves to a real but WRONG string with nothing on the row to say so. The
    # bytes still go out named; only the SLOT has to survive.
    body = Bytes[22] + e7(3) +
           Bytes[30] + e7(2) + Bytes[0xff, 0xfe] +
           Bytes[30] + e7(4) + "Text".to_slice +
           Bytes[31, 1]
    read(vs(body)).should contain(
      %("state":[{"$str_invalid_utf8":"//4="},"Text","Text"]))
  end

  it "refuses a NEGATIVE type index instead of counting back from the end of the table" do
    # Crystal's `Array#[]?` indexes from the END for a negative index, so an unguarded lookup
    # answers a `Token_TypeRef` of -1 with the most recent type — a name the stream never
    # wrote, presented as if it had.
    body = Bytes[16] +
           Bytes[25] + Bytes[41] + e7(12) + "System.Int32".to_slice +
           Bytes[25] + Bytes[43] + Bytes[0xff, 0xff, 0xff, 0xff, 0x0f] +
           Bytes[100]
    read(vs(body)).should contain(
      %("state":{"$triplet":[{"$type":"System.Int32"},{"$type":"$type_index:-1"},null]}))
  end

  it "tells the three type-reference tokens apart, and resolves the index" do
    body = Bytes[16] +
           Bytes[25] + Bytes[41] + e7(12) + "System.Int32".to_slice +
           Bytes[25] + Bytes[43] + e7(0) +
           Bytes[25] + Bytes[42] + e7(4) + "Page".to_slice
    # The TypeRef (43) resolves back to the name TypeRefAdd (41) put in the table, and
    # TypeRefAddLocal (42) is the one that resolves against `System.Web`.
    read(vs(body)).should contain(
      %("state":{"$triplet":[{"$type":"System.Int32"},{"$type":"System.Int32"},) +
      %({"$type":"Page, System.Web"}]}))
  end

  it "names a BinaryFormatter payload without unpacking it — a different format, out of scope" do
    payload = Bytes[0x00, 0x01, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0x11]
    json = read(vs(Bytes[50] + e7(payload.size) + payload))
    json.should contain(%("$binaryformatter":true))
    json.should contain(%("bytes":10))
    # …and a payload without the record header is not claimed to have one.
    read(vs(Bytes[50] + e7(2) + Bytes[1, 2])).should contain(%("$binaryformatter":false))
  end

  it "guards the event-validation count BEFORE multiplying it by the hash size" do
    # `n * 16` is a CHECKED multiply in Crystal, so a count near `Int32::MAX` raises
    # `OverflowError` — which is neither exception `Serialized.build` rescues, and `CLI.run`
    # rescues only `Gori::Error`, so it would reach the operator as a backtrace.
    data = vs(Bytes[29, 0] + e7(0x7fff_fff0))
    r = V.render(data)
    r.stop.should eq("truncated")
    r.json.should contain(%("$partial":"truncated"))
    # A truthful store still reads.
    ok = vs(Bytes[29, 0] + e7(1) + Bytes.new(16, &.to_u8))
    read(ok).should contain(%("$event_validation":1,"hashes":["000102030405060708090a0b0c0d0e0f"]))
  end

  it "reads a Hashtable, marking a non-string key rather than passing it off as one" do
    body = Bytes[23] + e7(2) + str("a") + Bytes[2] + e7(7) + Bytes[2] + e7(5) + Bytes[103]
    json = read(vs(body))
    json.should contain(%("$type":"Hashtable"))
    json.should contain(%("entries":{"a":7,"5":true}))
    json.should contain(%("$keys":"non-string"))
  end

  it "spells a DateTime out, and keeps the ticks it came from" do
    bits = (1_u64 << 62) | 638_000_000_000_000_000_u64
    raw = IO::Memory.new
    raw.write_bytes(bits, IO::ByteFormat::LittleEndian)
    json = read(vs(Bytes[6] + raw.to_slice))
    json.should contain(%("$datetime":"2022-09-28T22:13:20Z","kind":"Utc","ticks":638000000000000000))
  end

  it "refuses a body that does not open FF 01, and says nothing was decoded" do
    r = V.render("hello, an ordinary page".to_slice)
    r.decoded.should be_false
    r.json.should eq(%({"$partial":"malformed"}))
  end
end
