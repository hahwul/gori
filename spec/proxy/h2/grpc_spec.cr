require "../../spec_helper"

private alias Grpc = Gori::Proxy::H2::Grpc

# Build a gRPC-framed body (1-byte flag + 4-byte big-endian length + payload)*.
private def framed(*msgs : String) : Bytes
  io = IO::Memory.new
  msgs.each do |m|
    io.write_byte(0_u8)
    len = m.bytesize
    io.write_byte(((len >> 24) & 0xff).to_u8)
    io.write_byte(((len >> 16) & 0xff).to_u8)
    io.write_byte(((len >> 8) & 0xff).to_u8)
    io.write_byte((len & 0xff).to_u8)
    io << m
  end
  io.to_slice
end

# Build a single grpc-web TRAILER frame (flag 0x80 + 4-byte length + ASCII payload).
private def trailer_frame(payload : String) : Bytes
  io = IO::Memory.new
  io.write_byte(0x80_u8)
  len = payload.bytesize
  io.write_byte(((len >> 24) & 0xff).to_u8)
  io.write_byte(((len >> 16) & 0xff).to_u8)
  io.write_byte(((len >> 8) & 0xff).to_u8)
  io.write_byte((len & 0xff).to_u8)
  io << payload
  io.to_slice
end

describe Gori::Proxy::H2::Grpc do
  it "detects application/grpc content types" do
    Grpc.grpc?("application/grpc").should be_true
    Grpc.grpc?("application/grpc+proto").should be_true
    Grpc.grpc?("application/json").should be_false
    Grpc.grpc?(nil).should be_false
  end

  it "frames length-prefixed messages" do
    msgs = Grpc.messages(framed("hello", "world!"))
    msgs.size.should eq(2)
    String.new(msgs[0].data).should eq("hello")
    String.new(msgs[1].data).should eq("world!")
    msgs[0].compressed.should be_false
  end

  it "ignores a trailing partial frame (still streaming)" do
    io = IO::Memory.new
    io.write(framed("done"))
    io.write(Bytes[0x00, 0x00, 0x00, 0x00, 0x05, 0x61]) # declares 5, gives 1
    Grpc.messages(io.to_slice).map { |m| String.new(m.data) }.should eq(["done"])
  end

  it "marks compressed messages" do
    m = Grpc.messages(Bytes[0x01, 0x00, 0x00, 0x00, 0x02, 0xab, 0xcd]).first
    m.compressed.should be_true
    m.trailer.should be_false # flag 0x01 → compressed, not a trailer
    m.data.should eq(Bytes[0xab, 0xcd])
  end

  it "flags a grpc-web trailer frame (top bit 0x80) and does not treat it as compressed" do
    m = Grpc.messages(trailer_frame("grpc-status: 0\r\ngrpc-message: OK\r\n")).first
    m.trailer.should be_true
    m.compressed.should be_false
  end

  it "reads the compressed bit independently of the trailer bit (flag 0x81)" do
    m = Grpc.messages(Bytes[0x81_u8, 0x00, 0x00, 0x00, 0x02, 0xab, 0xcd]).first
    m.compressed.should be_true
    m.trailer.should be_true
  end

  it "parses grpc-status / grpc-message from a trailer payload" do
    h = Grpc.trailer_headers("grpc-status: 5\r\ngrpc-message: not found\r\n".to_slice)
    h["grpc-status"].should eq("5")
    h["grpc-message"].should eq("not found")
  end

  it "parses a trailer payload with an invalid UTF-8 byte instead of raising" do
    payload = Bytes[0x67, 0x72, 0x70, 0x63, 0x2d, 0x6d, 0x65, 0x73, 0x73, 0x61, 0x67,
      0x65, 0x3a, 0x20, 0xff, 0x0d, 0x0a] # "grpc-message: \xFF\r\n"
    h = Grpc.trailer_headers(payload)
    h["grpc-message"]?.should_not be_nil
  end

  it "names known status codes and falls back for unknown ones" do
    Grpc.status_name(0).should eq("OK")
    Grpc.status_name(7).should eq("PERMISSION_DENIED")
    Grpc.status_name(16).should eq("UNAUTHENTICATED")
    Grpc.status_name(99).should eq("CODE99")
  end

  describe ".frame" do
    it "prefixes a payload with the flag + big-endian length (inverse of .messages)" do
      f = Grpc.frame(false, Bytes[0xDE, 0xAD, 0xBE, 0xEF])
      f.should eq(Bytes[0x00, 0x00, 0x00, 0x00, 0x04, 0xDE, 0xAD, 0xBE, 0xEF])
      msgs = Grpc.messages(f)
      msgs.size.should eq(1)
      msgs[0].compressed.should be_false
      msgs[0].data.should eq(Bytes[0xDE, 0xAD, 0xBE, 0xEF])
    end

    it "preserves the compressed flag" do
      Grpc.frame(true, Bytes[0x01])[0].should eq(1_u8)
    end

    it "recomputes the length prefix for an edited (grown) payload" do
      # a hex edit that changes the byte count must re-length or the origin rejects it
      grown = Grpc.frame(false, "hello world".to_slice)
      Grpc.messages(grown).first.data.should eq("hello world".to_slice)
      grown[1, 4].should eq(Bytes[0x00, 0x00, 0x00, 0x0B]) # 11
    end

    it "frames an empty payload as a 5-byte header with zero length" do
      Grpc.frame(false, Bytes.empty).should eq(Bytes[0x00, 0x00, 0x00, 0x00, 0x00])
    end

    it "sets the trailer bit (0x80) and round-trips via messages" do
      f = Grpc.frame(false, "grpc-status: 0\r\n".to_slice, trailer: true)
      f[0].should eq(0x80_u8)
      Grpc.messages(f).first.trailer.should be_true
    end
  end
end
