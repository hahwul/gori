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
end
