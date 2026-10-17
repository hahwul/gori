require "../spec_helper"
require "../support/demo_descriptor"
require "file_utils"

private alias Grpc = Gori::Proxy::H2::Grpc

private def with_demo_schema(&)
  dir = File.tempname("gori-grpcset-protos")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "demo.desc"), Base64.decode(DEMO_DESC_B64))
  Gori::Protobuf::Schemas.apply(dir)
  yield
ensure
  Gori::Protobuf::Schemas.clear
  FileUtils.rm_rf(dir) if dir
end

# A unary `GetUser` request carrying `name: "bob"`, its frame optionally gzip-compressed.
private def get_user(encoding : String? = nil) : Bytes
  msg = Gori::Protobuf::Encoder.length_delimited(1_u32, "bob".to_slice)
  frame = encoding ? Grpc.frame(true, Grpc.compress(encoding, msg).not_nil!) : Grpc.frame(false, msg)
  head = "POST /demo.Users/GetUser HTTP/1.1\r\nHost: api.test\r\ncontent-type: application/grpc\r\n" \
         "#{encoding ? "grpc-encoding: #{encoding}\r\n" : ""}content-length: #{frame.size}\r\n\r\n"
  io = IO::Memory.new
  io.write(head.to_slice)
  io.write(frame)
  io.to_slice
end

private def message_of(request : Bytes) : Bytes
  body = Gori::Fuzz::GrpcVerdict.body(request).not_nil!
  msgs, residual = Grpc.scan(body)
  residual.should eq(0)
  msgs.size.should eq(1)
  m = msgs[0]
  m.compressed ? Grpc.inflate(Grpc.encoding(request), m.data).as(Bytes) : m.data
end

describe Gori::Repeater::GrpcFields do
  it "sets a field by name through the loaded schema, reframing and resyncing Content-Length" do
    with_demo_schema do
      sent = Gori::Repeater::GrpcFields.apply(get_user, ["name=administrator"]).as(Bytes)
      message_of(sent).should eq(Gori::Protobuf::Encoder.length_delimited(1_u32, "administrator".to_slice))
      String.new(sent).should contain("Content-Length: 20\r\n")
    end
  end

  it "adds an undeclared field number without a schema" do
    Gori::Protobuf::Schemas.clear
    sent = Gori::Repeater::GrpcFields.apply(get_user, ["7:varint=1"]).as(Bytes)
    message_of(sent).should eq(Bytes[0x0a, 0x03, 0x62, 0x6f, 0x62, 0x38, 0x01])
  end

  it "round-trips a compressed message: inflate, edit, re-compress behind the same flag" do
    with_demo_schema do
      sent = Gori::Repeater::GrpcFields.apply(get_user("gzip"), ["name=eve", "2:bool=true"]).as(Bytes)
      body = Gori::Fuzz::GrpcVerdict.body(sent).not_nil!
      body[0].should eq(1) # still compressed
      message_of(sent).should eq(Bytes[0x0a, 0x03, 0x65, 0x76, 0x65, 0x10, 0x01])
    end
  end

  it "leaves the request alone with no specs, and refuses what it cannot edit" do
    Gori::Repeater::GrpcFields.apply(get_user, [] of String).should eq(get_user)
    plain = "POST / HTTP/1.1\r\nHost: a\r\ncontent-type: application/json\r\n\r\n{}".to_slice
    Gori::Repeater::GrpcFields.apply(plain, ["1=x"]).as(String).should contain("needs a gRPC request")
    # A Connect call (#1636) is not gRPC framing: its unary body has no envelope at all, and its
    # streams carry an end-stream flag, so the field set refuses it rather than misread it.
    connect = "POST /demo.Users/GetUser HTTP/1.1\r\nHost: a\r\ncontent-type: application/proto\r\n\r\n\x0a\x03bob".to_slice
    Gori::Repeater::GrpcFields.apply(connect, ["1=x"]).as(String).should contain("needs a gRPC request")
    Gori::Protobuf::Schemas.clear
    Gori::Repeater::GrpcFields.apply(get_user, ["name=x"]).as(String).should contain("no .proto schema")
  end
end
