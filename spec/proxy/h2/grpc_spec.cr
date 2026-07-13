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
    m.data.should eq(Bytes[0xab, 0xcd])
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
  end
end
