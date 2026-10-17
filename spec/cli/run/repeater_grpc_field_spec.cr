require "../../spec_helper"

# `gori run repeater send --grpc-field … -H …` (#1632): the field set runs BEFORE the `-H`
# overrides, so a deliberately-wrong Content-Length the operator pinned is the one that ships.
private def get_user_wire : Bytes
  frame = Gori::Proxy::H2::Grpc.frame(false, Gori::Protobuf::Encoder.length_delimited(1_u32, "bob".to_slice))
  io = IO::Memory.new
  io.write("POST /demo.Users/GetUser HTTP/1.1\r\nHost: api.test\r\ncontent-type: application/grpc\r\n" \
           "Content-Length: #{frame.size}\r\n\r\n".to_slice)
  io.write(frame)
  io.to_slice
end

describe "gori run repeater send --grpc-field" do
  it "keeps a Content-Length pinned with -H over the edited body" do
    Gori::Protobuf::Schemas.clear
    built = Gori::CLI::Run.per_send_request(get_user_wire, ["Content-Length: 999"], ["7:varint=1"])
    bytes, pinned = built.as({Bytes, Bool})
    pinned.should be_true
    String.new(bytes).should contain("Content-Length: 999\r\n")
    msgs, _ = Gori::Proxy::H2::Grpc.scan(Gori::Fuzz::GrpcVerdict.body(bytes).not_nil!)
    msgs[0].data.should eq(Bytes[0x0a, 0x03, 0x62, 0x6f, 0x62, 0x38, 0x01])
  end

  it "resyncs the stored Content-Length when nothing pins it" do
    Gori::Protobuf::Schemas.clear
    bytes, pinned = Gori::CLI::Run.per_send_request(get_user_wire, [] of String, ["7:varint=1"]).as({Bytes, Bool})
    pinned.should be_false
    String.new(bytes).should contain("Content-Length: 12\r\n")
  end

  it "returns the refusal for a spec it cannot apply" do
    Gori::Protobuf::Schemas.clear
    Gori::CLI::Run.per_send_request(get_user_wire, [] of String, ["name=x"]).as(String).should contain("no .proto schema")
  end
end
