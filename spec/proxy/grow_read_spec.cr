require "../spec_helper"

# `GrowRead` sizes a frame's buffer by the bytes that ARRIVE, not the length the peer declared.
# Both relays read frames through it: an h2 or WebSocket header claiming 16 MiB, followed by
# one byte and a stall, allocated the whole 16 MiB up front — ~1 GB for 60 connections.

# Hands out at most `step` bytes per read, so a frame larger than `GrowRead::PRESIZE` has to
# grow its buffer several times on the way in.
private class DribbleIO < IO
  def initialize(@data : Bytes, @step : Int32)
    @pos = 0
  end

  def read(slice : Bytes) : Int32
    n = {slice.size, @step, @data.size - @pos}.min
    slice.copy_from(@data[@pos, n])
    @pos += n
    n
  end

  def write(slice : Bytes) : Nil
    raise "read-only"
  end
end

# Bytes allocated while `block` runs. `total_bytes` only goes up, so heap freed by earlier
# examples cannot hide an allocation.
private def allocated(&) : Int64
  GC.collect
  before = GC.stats.total_bytes
  yield
  (GC.stats.total_bytes - before).to_i64
end

private def ws_header(len : Int32) : Bytes
  io = IO::Memory.new
  io.write_byte(0x82_u8) # FIN + binary, unmasked (server → client)
  io.write_byte(127_u8)
  io.write_bytes(len.to_u64, IO::ByteFormat::BigEndian)
  io.to_slice
end

describe "Proxy::GrowRead (h2 and WebSocket frame reads)" do
  it "does not allocate an h2 frame's declared length before its payload arrives" do
    # 0xffffff = 16 MiB - 1, the relays' cap; one payload byte, then the peer goes quiet.
    wire = Bytes[0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x61]
    bytes = allocated do
      expect_raises(Gori::Error, /EOF mid-frame/) { Gori::Proxy::H2::Frame.read(IO::Memory.new(wire)) }
    end
    bytes.should be < 1024 * 1024
  end

  it "does not allocate a WebSocket frame's declared length before its payload arrives" do
    wire = IO::Memory.new
    wire.write(ws_header(16 * 1024 * 1024))
    wire.write_byte(0x61_u8)
    bytes = allocated do
      Gori::Proxy::WS.read_frame(IO::Memory.new(wire.to_slice)).should be_nil
    end
    bytes.should be < 1024 * 1024
  end

  it "still reads a large h2 frame byte-exact, however the bytes are split" do
    payload = Bytes.new(100_000) { |i| (i % 251).to_u8 }
    f = Gori::Proxy::H2::Frame::Header.new(Gori::Proxy::H2::Frame::Type::Data.value, 0_u8, 3_u32, payload)
    wire = f.to_bytes
    back = Gori::Proxy::H2::Frame.read(DribbleIO.new(wire, 1000)).not_nil!
    back.payload.should eq(payload)
    back.to_bytes.should eq(wire)
  end

  it "still reads a large WebSocket frame byte-exact, however the bytes are split" do
    payload = Bytes.new(100_000) { |i| (i % 251).to_u8 }
    wire = IO::Memory.new
    wire.write(ws_header(payload.size))
    wire.write(payload)
    frame = Gori::Proxy::WS.read_frame(DribbleIO.new(wire.to_slice, 1000)).not_nil!
    frame.payload.should eq(payload)
    frame.raw.should eq(wire.to_slice)
  end
end
