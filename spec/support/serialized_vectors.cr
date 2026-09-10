require "../../src/gori"
require "base64"

# Real documents of each native-serialization format, shared by `binary_document_readers_spec`
# and the four reader specs under `spec/decoder/serialized/`. Each was produced by a
# reference implementation and checked back through one (`javaobj-py3` for the Java stream,
# `pickletools` for the pickle) rather than typed out — a hand-written stream only proves the
# spec agrees with what its author believed the format says, which is the failure a reader's
# spec exists to catch.
module SerializedVectors
  extend self

  # `Write7BitEncodedInt` — the encoding every count and length in a ViewState uses, and the
  # only way to hand-build one. Here rather than in either spec because both need it.
  def e7(n : Int32) : Bytes
    io = IO::Memory.new
    v = n.to_u32
    while v >= 0x80
      io.write_byte(((v & 0x7f) | 0x80).to_u8)
      v >>= 7
    end
    io.write_byte(v.to_u8)
    io.to_slice
  end

  # `AC ED 00 05` + a `java.util.HashMap` with its two declared fields and the `writeObject`
  # annotation that carries one entry — the shape every serialized collection has.
  JAVA_HASHMAP = ("aced0005737200116a6176612e7574696c2e486173684d61700507dac1c31660d10300" \
                  "0246000a6c6f6164466163746f724900097468726573686f6c6478703f400000000000" \
                  "0c770800000010000000017400016b7400017678")
                    .hexbytes

  # The `/wE…` sample every ViewState decoder is tested against:
  # `Pair(Pair("-162691655", Pair(null, [3, Pair(null, [1, Pair(Pair(["Text","Hello World"],
  # null), null)])])), null)`, with no MAC.
  VIEWSTATE_CLASSIC = Base64.decode(
    "/wEPDwUKLTE2MjY5MTY1NQ9kFgICAw9kFgICAQ8PFgIeBFRleHQFC0hlbGxvIFdvcmxkZGRk")

  # `pickle.dumps(x, protocol=4)` where `x.__reduce__` returns `(os.system, ("id",))` — the
  # canonical dangerous pickle, and the one `STACK_GLOBAL` resolution has to name.
  PICKLE_REDUCE = Base64.decode(
    "gASVHQAAAAAAAACMBXBvc2l4lIwGc3lzdGVtlJOUjAJpZJSFlFKULg==")

  # `O:7:"MyClass":3:{s:3:"pub";s:2:"hi";s:13:"\0MyClass\0priv";i:7;s:7:"\0*\0prot";b:1;}`
  # — a public, a private and a protected property, with PHP's name mangling on the wire.
  PHP_OBJECT = %(O:7:"MyClass":3:{s:3:"pub";s:2:"hi";s:13:"\u0000MyClass\u0000priv";i:7;s:7:"\u0000*\u0000prot";b:1;}).to_slice
end
