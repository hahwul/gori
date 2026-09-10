require "../../spec_helper"
require "../../support/serialized_vectors"

private alias K = Gori::Decoder::Serialized::Pickle

private def ops(data : Bytes) : Array(String)
  JSON.parse(K.render(data).json)["ops"].as_a.map(&.["op"].as_s)
end

describe Gori::Decoder::Serialized::Pickle do
  it "disassembles a protocol-4 __reduce__ payload exactly as pickletools does" do
    # The opcode stream below is `pickletools.dis` output for this pickle, opcode for opcode.
    # It is the whole point of the reader: the same walk, and nothing executed.
    doc = SerializedVectors::PICKLE_REDUCE
    r = K.render(doc)
    r.complete.should be_true
    r.describes?(doc.size).should be_true
    ops(doc).should eq(%w[PROTO FRAME SHORT_BINUNICODE MEMOIZE SHORT_BINUNICODE MEMOIZE
      STACK_GLOBAL MEMOIZE SHORT_BINUNICODE MEMOIZE TUPLE1 MEMOIZE REDUCE MEMOIZE STOP])
    parsed = JSON.parse(r.json)
    parsed["protocol"].should eq(4)
    parsed["globals"].should eq(JSON.parse(%(["posix.system"])))
    parsed["reduce"].should eq(1)
  end

  it "resolves STACK_GLOBAL off the two literals still on the stack top" do
    # Protocol 4 pushes the module and the qualname immediately before the opcode that
    # consumes them, so the callable IS knowable — and a bare handle number is not something
    # an operator reads. Anything else in between and the resolution is declined, not guessed.
    JSON.parse(K.render(SerializedVectors::PICKLE_REDUCE).json)["ops"].as_a
      .find { |o| o["op"] == "STACK_GLOBAL" }.not_nil!["resolved"].should eq("posix.system")

    # A literal, then something that disturbs the stack, then STACK_GLOBAL: no resolution.
    doc = Bytes[0x80, 0x04, 0x8c, 0x02] + "os".to_slice +
          Bytes[0x8c, 0x06] + "system".to_slice + Bytes[0x30, 0x93, 0x2e]
    JSON.parse(K.render(doc).json)["ops"].as_a
      .find { |o| o["op"] == "STACK_GLOBAL" }.not_nil!["resolved"]?.should be_nil
  end

  it "names a protocol-0 GLOBAL, whose module and name are two plain lines" do
    doc = "cposix\nsystem\np0\n(V id\np1\ntp2\nRp3\n.".to_slice
    parsed = JSON.parse(K.render(doc).json)
    parsed["globals"].should eq(JSON.parse(%(["posix.system"])))
    parsed["reduce"].should eq(1)
    parsed["ops"][0]["arg"].should eq(JSON.parse(%(["posix","system"])))
  end

  it "spells a wide LONG1 out rather than losing it to a float" do
    # 10**40, little-endian two's complement in 17 bytes — `pickle.dumps(10**40, protocol=2)`.
    body = Bytes[0x80, 0x02, 0x8a, 0x11] +
           Bytes[0x00, 0x00, 0x00, 0x00, 0x00, 0x61, 0xf5, 0xb9, 0xab,
             0xbf, 0xa4, 0x5c, 0xc3, 0xf1, 0x29, 0x63, 0x1d] + Bytes[0x2e]
    JSON.parse(K.render(body).json)["ops"][1]["arg"].should eq(
      JSON.parse(%({"$bignum":"10000000000000000000000000000000000000000"})))
  end

  it "reads I01 and I00 as the booleans protocol 0 means by them" do
    JSON.parse(K.render("I01\n.".to_slice).json)["ops"][0]["arg"].as_bool.should be_true
    JSON.parse(K.render("I00\n.".to_slice).json)["ops"][0]["arg"].as_bool.should be_false
  end

  it "hands a protocol-0 line that is not UTF-8 back as bytes, not scrubbed" do
    doc = "V".to_slice + Bytes[0x61, 0xff] + "\n.".to_slice
    K.render(doc).json.should contain(%({"$str_invalid_utf8":"Yf8="}))
  end

  it "STOPS at STOP, so bytes behind the document are trailing rather than more opcodes" do
    doc = SerializedVectors::PICKLE_REDUCE + "NNNN".to_slice
    r = K.render(doc)
    r.stop.should eq("trailing")
    r.describes?(doc.size).should be_false
  end

  it "stops at a byte that is not an opcode, and points at where it gave up" do
    doc = Bytes[0x80, 0x04, 0x8c, 0x01] + "a".to_slice + Bytes[0xfd]
    r = K.render(doc)
    r.stop.should eq("malformed")
    r.consumed.should eq(doc.size - 1)
  end

  it "reads a body cut short as far as it goes, and never un-shows a longer prefix" do
    # A prefix holding nothing but the framing preamble (`PROTO`, `FRAME`) decoded no CONTENT,
    # so `describes?` refuses it and the operator keeps the hex view — which is right, because
    # `\x80 <proto>` is the pair the sniff gates on and counting it would let a five-byte body
    # replace a hex dump with a disassembly of nothing. What must never happen is the other
    # direction: a LONGER prefix going back to refused.
    doc = SerializedVectors::PICKLE_REDUCE
    renders = (1..doc.size).map { |n| K.render(doc[0, n]) }
    # A prefix holding nothing but the framing preamble decodes no CONTENT, so it is refused
    # (or, where it ends exactly on an opcode boundary, trivially complete — an opcode stream
    # that happens to stop). Neither says anything about the property being swept. From the
    # first prefix that read a real opcode onward, every longer one has to STAY shown: the
    # other direction is what a short read leaving the cursor behind produces.
    first = renders.index(&.decoded).not_nil!
    renders[first..].each_with_index { |r, i| r.describes?(first + i + 1).should be_true }
    # …and that first one did reach an opcode past the preamble.
    ops(doc[0, first + 1]).reject { |o| o == "PROTO" || o == "FRAME" }.should_not be_empty
  end

  it "reads a bare PROTO as the complete, contentless stream it is — and decodes nothing" do
    r = K.render(Bytes[0x80, 0x04])
    r.complete.should be_true
    r.decoded.should be_false
  end
end
