require "../../spec_helper"

private alias Frame = Gori::Proxy::H2::Frame

describe Gori::Proxy::H2::Frame do
  it "round-trips a frame through to_bytes / read (byte-exact)" do
    payload = Bytes[0x00, 0x01, 0x02, 0xff]
    f = Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, 5_u32, payload)
    wire = f.to_bytes
    wire.size.should eq(Frame::HEADER_SIZE + payload.size)

    io = IO::Memory.new(wire)
    back = Frame.read(io).not_nil!
    back.type.should eq(Frame::Type::Data.value)
    back.frame_type.should eq(Frame::Type::Data)
    back.stream_id.should eq(5)
    back.end_stream?.should be_true
    back.payload.should eq(payload)
    back.to_bytes.should eq(wire) # stable serialization
  end

  it "encodes the 24-bit length and 31-bit stream id correctly" do
    payload = Bytes.new(300, 0xab_u8) # length spans two octets
    f = Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 0x7fffffff_u32, payload)
    wire = f.to_bytes
    # length 300 = 0x00012C
    wire[0].should eq(0x00)
    wire[1].should eq(0x01)
    wire[2].should eq(0x2c)
    back = Frame.read(IO::Memory.new(wire)).not_nil!
    back.stream_id.should eq(0x7fffffff)
    back.end_headers?.should be_true
    back.payload.size.should eq(300)
  end

  it "masks the reserved high bit of the stream id on read" do
    # craft a header with the reserved bit (0x80 on octet 5) set
    raw = Bytes[0, 0, 0, Frame::Type::WindowUpdate.value, 0, 0x80, 0, 0, 0x01]
    f = Frame.read(IO::Memory.new(raw)).not_nil!
    f.stream_id.should eq(1) # reserved bit ignored
  end

  it "keeps an unknown frame type as a raw octet (forward-compat)" do
    f = Frame::Header.new(0xfe_u8, 0_u8, 1_u32, Bytes.empty)
    f.frame_type.should be_nil
    Frame.read(IO::Memory.new(f.to_bytes)).not_nil!.type.should eq(0xfe)
  end

  it "returns nil on a clean EOF at a frame boundary" do
    Frame.read(IO::Memory.new(Bytes.empty)).should be_nil
  end

  it "raises on a truncated frame" do
    truncated = Bytes[0, 0, 0x05, Frame::Type::Data.value, 0, 0, 0, 0, 1, 0xaa] # declares 5, gives 1
    expect_raises(Gori::Error, /EOF mid-frame/) { Frame.read(IO::Memory.new(truncated)) }
  end

  it "reads and validates the client connection preface" do
    io = IO::Memory.new(Frame::PREFACE.dup)
    Frame.read_preface(io).should eq(Frame::PREFACE)
    expect_raises(Gori::Error, /preface/) { Frame.read_preface(IO::Memory.new("not-a-preface-24-bytes!!".to_slice)) }
  end

  it "distinguishes ACK (settings/ping) which shares the END_STREAM bit" do
    settings_ack = Frame::Header.new(Frame::Type::Settings.value, Frame::ACK, 0_u32, Bytes.empty)
    settings_ack.ack?.should be_true
  end
end
