require "../../spec_helper"

private alias Frame = Gori::Proxy::H2::Frame
private alias ConnectOffer = Gori::Proxy::H2::ConnectOffer

private def settings_payload(*entries : {UInt16, UInt32}) : Bytes
  io = IO::Memory.new
  entries.each do |(id, value)|
    io.write_bytes(id, IO::ByteFormat::BigEndian)
    io.write_bytes(value, IO::ByteFormat::BigEndian)
  end
  io.to_slice
end

private def settings_frame(payload : Bytes, flags : UInt8 = 0_u8, stream : UInt32 = 0_u32,
                           type : UInt8 = Frame::Type::Settings.value) : Frame::Header
  Frame.read(IO::Memory.new(Frame::Header.new(type, flags, stream, payload).to_bytes)).not_nil!
end

describe Gori::Proxy::H2::ConnectOffer do
  it "removes the offer and keeps every other parameter in its order" do
    frame = settings_frame(settings_payload({0x3_u16, 100_u32}, {0x8_u16, 1_u32}, {0x4_u16, 65_535_u32}))
    out = ConnectOffer.withhold(frame).not_nil!
    out.type.should eq(Frame::Type::Settings.value)
    out.stream_id.should eq(0_u32)
    out.payload.should eq(settings_payload({0x3_u16, 100_u32}, {0x4_u16, 65_535_u32}))
    out.raw.should be_nil
  end

  it "turns a frame carrying only the offer into an empty SETTINGS frame, not nothing" do
    frame = settings_frame(settings_payload({0x8_u16, 1_u32}), flags: 0x40_u8)
    out = ConnectOffer.withhold(frame).not_nil!
    out.wire_bytes.should eq(Bytes[0, 0, 0, Frame::Type::Settings.value, 0x40, 0, 0, 0, 0])
  end

  it "leaves a frame without the offer alone" do
    ConnectOffer.withhold(settings_frame(settings_payload({0x3_u16, 100_u32}))).should be_nil
    ConnectOffer.withhold(settings_frame(Bytes.empty)).should be_nil
  end

  it "leaves a zero-valued entry alone, since 0 is the parameter's initial value" do
    ConnectOffer.withhold(settings_frame(settings_payload({0x8_u16, 0_u32}))).should be_nil
  end

  it "removes any non-zero value, not only 1" do
    out = ConnectOffer.withhold(settings_frame(settings_payload({0x8_u16, 2_u32}, {0x3_u16, 7_u32}))).not_nil!
    out.payload.should eq(settings_payload({0x3_u16, 7_u32}))
  end

  it "keeps only the zero entry when a frame carries the id twice, in either order" do
    [{0_u32, 1_u32}, {1_u32, 0_u32}].each do |(first, second)|
      frame = settings_frame(settings_payload({0x8_u16, first}, {0x8_u16, second}))
      ConnectOffer.withhold(frame).not_nil!.payload.should eq(settings_payload({0x8_u16, 0_u32}))
    end
  end

  it "leaves a SETTINGS ACK alone" do
    ConnectOffer.withhold(settings_frame(settings_payload({0x8_u16, 1_u32}), flags: Frame::ACK)).should be_nil
  end

  it "leaves a frame of another type alone" do
    ping = settings_frame(settings_payload({0x8_u16, 1_u32}), type: Frame::Type::Ping.value)
    ConnectOffer.withhold(ping).should be_nil
  end

  it "leaves a SETTINGS frame on a stream other than 0 alone" do
    ConnectOffer.withhold(settings_frame(settings_payload({0x8_u16, 1_u32}), stream: 1_u32)).should be_nil
  end

  it "leaves a malformed SETTINGS frame alone, for the client's own error handling" do
    payload = Bytes.new(7)
    settings_payload({0x8_u16, 1_u32}).copy_to(payload)
    ConnectOffer.withhold(settings_frame(payload)).should be_nil
  end
end
