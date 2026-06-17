require "../spec_helper"

describe Gori::Proxy::PrefixIO do
  it "replays the prefix, then delegates reads to the inner IO" do
    io = Gori::Proxy::PrefixIO.new(Bytes['P'.ord.to_u8], IO::Memory.new("RI * HTTP/2.0"))
    io.gets_to_end.should eq("PRI * HTTP/2.0")
  end

  it "passes writes through to the inner IO" do
    inner = IO::Memory.new
    Gori::Proxy::PrefixIO.new(Bytes.empty, inner).write("hello".to_slice)
    inner.to_s.should eq("hello")
  end

  it "replays a multi-byte prefix across reads" do
    io = Gori::Proxy::PrefixIO.new("PRI".to_slice, IO::Memory.new("XY"))
    io.gets_to_end.should eq("PRIXY")
  end
end
