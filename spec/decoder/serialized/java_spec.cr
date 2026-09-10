require "../../spec_helper"
require "../../support/serialized_vectors"

private alias J = Gori::Decoder::Serialized::Java

private def read(data : Bytes) : String
  J.render(data).json
end

# A stream header in front of `body`.
private def stream(body : Bytes) : Bytes
  Bytes[0xac, 0xed, 0x00, 0x05] + body
end

private def utf(s : String) : Bytes
  b = s.to_slice
  Bytes[(b.size >> 8).to_u8, (b.size & 0xff).to_u8] + b
end

private def jstr(s : String) : Bytes
  Bytes[0x74] + utf(s)
end

describe Gori::Decoder::Serialized::Java do
  it "reads a real java.util.HashMap: class, declared fields, and the writeObject annotation" do
    r = J.render(SerializedVectors::JAVA_HASHMAP)
    r.complete.should be_true
    r.describes?(SerializedVectors::JAVA_HASHMAP.size).should be_true
    r.json.should eq(
      %({"$format":"java-serialized","version":5,"contents":[) +
      %({"$object":"java.util.HashMap","$handle":8257537,) +
      %("fields":{"loadFactor":0.75,"threshold":12},) +
      %("$annotation":[{"$blockdata":{"$bin":"AAAAEAAAAAE="}},"k","v"]}]}))
  end

  it "EMITS a back-reference rather than expanding it, and carries a short string's text" do
    # Inlining a shared reference is what turns a small graph into exponential output, and it
    # is also the less faithful rendering: the sharing is a fact about the graph. The text
    # rides along because a gadget chain is mostly strings and a bare handle is unreadable.
    body = Bytes[0x73] + # TC_OBJECT
           Bytes[0x72] + utf("Holder") + Bytes[0, 0, 0, 0, 0, 0, 0, 2] +
           Bytes[0x02, 0x00, 0x02] +
           Bytes['L'.ord.to_u8] + utf("a") + jstr("Ljava/lang/String;") +
           Bytes['L'.ord.to_u8] + utf("b") + jstr("Ljava/lang/String;") +
           Bytes[0x78, 0x70] +
           jstr("shared") + Bytes[0x71, 0x00, 0x7e, 0x00, 0x04]
    json = read(stream(body))
    json.should contain(%("a":"shared"))
    json.should contain(%("b":{"$ref":8257540,"$string":"shared"}))
  end

  it "keeps each class's block apart when the chain has more than one, owner-qualifying a repeat" do
    base = Bytes[0x72] + utf("Base") + Bytes[0, 0, 0, 0, 0, 0, 0, 4] +
           Bytes[0x02, 0x00, 0x01] + Bytes['I'.ord.to_u8] + utf("n") + Bytes[0x78, 0x70]
    child = Bytes[0x72] + utf("Child") + Bytes[0, 0, 0, 0, 0, 0, 0, 3] +
            Bytes[0x02, 0x00, 0x01] + Bytes['I'.ord.to_u8] + utf("n") + Bytes[0x78] + base
    json = read(stream(Bytes[0x73] + child + Bytes[0, 0, 0, 1] + Bytes[0, 0, 0, 2]))
    json.should contain(%("$classes":["Base","Child"]))
    json.should contain(%({"class":"Base","fields":{"n":1}}))
    # The child's own `n` keeps its owner, so the super's value is not overwritten.
    json.should contain(%({"class":"Child","fields":{"Child.n":2}}))
  end

  it "reads every primitive field width, and a char as the character it is" do
    desc = Bytes[0x72] + utf("Prim") + Bytes[0, 0, 0, 0, 0, 0, 0, 1] + Bytes[0x02, 0x00, 0x08] +
           Bytes['I'.ord.to_u8] + utf("i") + Bytes['J'.ord.to_u8] + utf("l") +
           Bytes['D'.ord.to_u8] + utf("d") + Bytes['F'.ord.to_u8] + utf("f") +
           Bytes['S'.ord.to_u8] + utf("s") + Bytes['B'.ord.to_u8] + utf("b") +
           Bytes['C'.ord.to_u8] + utf("c") + Bytes['Z'.ord.to_u8] + utf("z") +
           Bytes[0x78, 0x70]
    values = IO::Memory.new
    values.write_bytes(42_i32, IO::ByteFormat::BigEndian)
    values.write_bytes(-7_i64, IO::ByteFormat::BigEndian)
    values.write_bytes(1.5_f64, IO::ByteFormat::BigEndian)
    values.write_bytes(2.5_f32, IO::ByteFormat::BigEndian)
    values.write_bytes(-3_i16, IO::ByteFormat::BigEndian)
    values.write_byte(7_u8)
    values.write_bytes('x'.ord.to_u16, IO::ByteFormat::BigEndian)
    values.write_byte(1_u8)
    json = read(stream(Bytes[0x73] + desc + values.to_slice))
    json.should contain(%("fields":{"i":42,"l":-7,"d":1.5,"f":2.5,"s":-3,"b":7,"c":"x","z":true}))
  end

  it "names an array by its element type and reads the elements at that width" do
    desc = Bytes[0x72] + utf("[I") + Bytes[0, 0, 0, 0, 0, 0, 0, 5] + Bytes[0x02, 0x00, 0x00, 0x78, 0x70]
    json = read(stream(Bytes[0x75] + desc + Bytes[0, 0, 0, 3] +
                       Bytes[0, 0, 0, 1] + Bytes[0, 0, 0, 2] + Bytes[0, 0, 0, 3]))
    json.should contain(%({"$array":"[I","$handle":8257537,"values":[1,2,3]}))
  end

  it "reads an enum constant and a bare class reference" do
    edesc = Bytes[0x72] + utf("Color") + Bytes[0, 0, 0, 0, 0, 0, 0, 0] + Bytes[0x12, 0x00, 0x00, 0x78, 0x70]
    read(stream(Bytes[0x7e] + edesc + jstr("RED"))).should contain(%("$enum":"Color"))
    read(stream(Bytes[0x7e] + edesc + jstr("RED"))).should contain(%("$name":"RED"))

    cdesc = Bytes[0x72] + utf("Foo") + Bytes[0, 0, 0, 0, 0, 0, 0, 1] + Bytes[0x02, 0x00, 0x00, 0x78, 0x70]
    read(stream(Bytes[0x76] + cdesc)).should contain(%("$class_ref":"Foo"))
  end

  it "names a dynamic proxy by the interfaces it declares — the shape a gadget chain ends in" do
    handler = Bytes[0x73] + Bytes[0x72] + utf("Handler") + Bytes[0, 0, 0, 0, 0, 0, 0, 9] +
              Bytes[0x02, 0x00, 0x01] + Bytes['L'.ord.to_u8] + utf("cmd") +
              jstr("Ljava/lang/String;") + Bytes[0x78, 0x70] + jstr("calc.exe")
    superd = Bytes[0x72] + utf("java.lang.reflect.Proxy") + Bytes[0, 0, 0, 0, 0, 0, 0, 8] +
             Bytes[0x02, 0x00, 0x01] + Bytes['L'.ord.to_u8] + utf("h") +
             jstr("Ljava/lang/reflect/InvocationHandler;") + Bytes[0x78, 0x70]
    proxy = Bytes[0x7d] + Bytes[0, 0, 0, 1] + utf("java.util.Map") + Bytes[0x78] + superd
    json = read(stream(Bytes[0x73] + proxy + handler))
    json.should contain(%("$object":"$Proxy(java.util.Map)"))
    json.should contain(%("cmd":"calc.exe"))
  end

  it "STOPS at an Externalizable class that wrote raw bytes, rather than resynchronising" do
    # `writeExternal` with no `SC_BLOCK_DATA` writes in a shape only that class knows: no
    # length, no terminator. Guessing past it would invent the rest of the stream, so the
    # reader stops — and `describes?` then refuses the rendering, which is the honest answer.
    desc = Bytes[0x72] + utf("ExtRaw") + Bytes[0, 0, 0, 0, 0, 0, 0, 11] + Bytes[0x04, 0x00, 0x00, 0x78, 0x70]
    data = stream(Bytes[0x73] + desc + Bytes[0x01, 0x02, 0x03])
    r = J.render(data)
    r.stop.should eq("externalizable")
    r.describes?(data.size).should be_false
  end

  it "hands back a modified-UTF-8 string as BYTES rather than repairing it" do
    # `writeUTF` spells NUL as `C0 80`, which is not valid UTF-8. Scrubbing it would hand the
    # operator bytes the origin never sent (P7), so it goes out named.
    data = stream(Bytes[0x74, 0x00, 0x03, 'a'.ord.to_u8, 0xc0, 0x80])
    read(data).should contain(%({"$str_invalid_utf8":"YcCA"}))
  end

  it "refuses a body that is not a stream, and says nothing was decoded" do
    png = Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x11]
    r = J.render(png)
    r.decoded.should be_false
    r.describes?(png.size).should be_false
    r.json.should eq(%({"$partial":"malformed"}))
  end

  it "never un-shows a prefix of a real stream as more of it arrives" do
    # The capture-cap property, in the form this format can carry it. A prefix cut inside the
    # first CLASS DESCRIPTOR decoded nothing — a descriptor is machinery and never reaches the
    # output — so `describes?` refuses it and the operator gets the hex view, which is right.
    # What must never happen is the other direction: a LONGER prefix going back to refused,
    # which is exactly what a short read that leaves the cursor behind produces (the defect
    # the MessagePack sibling's prefix sweep exists for).
    doc = SerializedVectors::JAVA_HASHMAP
    # From 5, past the bare header: `AC ED 00 05` alone is a whole stream with no contents,
    # which the grammar allows and which is therefore complete — a true that says nothing
    # about the property being swept here.
    shown = (5..doc.size).map { |n| J.render(doc[0, n]).describes?(n) }
    first = shown.index(true).not_nil!
    shown[first..].should eq(Array.new(shown.size - first, true))
  end

  it "refuses a descriptor handle no stream could ever assign" do
    # `71 FF FF FF FF` in the `classDesc` slot. `new_handle` counts up from `BASE_WIRE_HANDLE`
    # in an `Int32`, so a handle with the top bit set names nothing — but the lookup went
    # through `be(raw).to_i32`, Crystal's CHECKED conversion, and RAISED `OverflowError`
    # instead of answering. Ten bytes of a cookie were enough, and the exception escaped
    # `Serialized.build`'s old `JSON::Error | IO::Error` net.
    r = J.render(stream(Bytes[0x73, 0x71, 0xff, 0xff, 0xff, 0xff]))
    r.json.should eq(%({"$format":"java-serialized","version":5,"contents":[{"$partial":"malformed"}]}))
    r.decoded.should be_false
    # ...and it is the SAME answer an in-range handle that names no descriptor already gave.
    J.render(stream(Bytes[0x73, 0x71, 0x00, 0x7e, 0x00, 0x00])).json.should eq(r.json)
  end

  it "reads a bare stream header as the empty stream the grammar says it is" do
    header = Bytes[0xac, 0xed, 0x00, 0x05]
    r = J.render(header)
    r.complete.should be_true
    r.json.should eq(%({"$format":"java-serialized","version":5,"contents":[]}))
  end
end
