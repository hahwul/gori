require "../../spec_helper"
require "socket"
require "log/spec"

# settings `network.strip_extended_connect` (#1896): the relay withholds the origin's RFC 8441
# offer from the client, on every SETTINGS frame the origin sends, and on no other leg.

private alias Frame = Gori::Proxy::H2::Frame

private ORIGIN_HOST = "Origin.Test"
private ORIGIN_PORT = 443

private class FrameLogSink < Gori::Proxy::FlowSink
  getter frames = [] of {String, UInt8, Bytes}

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    1_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end

  def on_h2_frame(conn_id : Int64, direction : String, type : UInt8, flags : UInt8,
                  stream_id : UInt32, payload : Bytes) : Nil
    @frames << {direction, type, payload.dup}
  end

  def settings(direction : String) : Array(Bytes)
    @frames.select { |f| f[0] == direction && f[1] == Frame::Type::Settings.value }.map(&.[2])
  end
end

private def entries(*pairs : {UInt16, UInt32}) : Bytes
  io = IO::Memory.new
  pairs.each do |(id, value)|
    io.write_bytes(id, IO::ByteFormat::BigEndian)
    io.write_bytes(value, IO::ByteFormat::BigEndian)
  end
  io.to_slice
end

private def settings_bytes(payload : Bytes) : Bytes
  Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, payload).to_bytes
end

private def read_frame_bytes(io : IO) : Bytes
  Frame.read(io).not_nil!.wire_bytes.dup
end

# The origin's first SETTINGS: a header table size, the offer, an initial window size.
private ORIGIN_FIRST = entries({0x1_u16, 4096_u32}, {0x8_u16, 1_u32}, {0x4_u16, 1_048_576_u32})
private ORIGIN_LATER = entries({0x8_u16, 1_u32}, {0x3_u16, 100_u32})
# A client has no business sending the parameter, which is what makes it a probe of the leg.
private CLIENT_SETTINGS = entries({0x2_u16, 0_u32}, {0x8_u16, 1_u32})

# `withheld` is whether the origin was recorded, read before the marker is reset.
private record Exchange, client_saw : Array(Bytes), origin_saw : Bytes, sink : FrameLogSink,
  withheld : Bool

# One connection through `Relay.run`: the client's preface and SETTINGS out, two origin SETTINGS
# frames in, then both ends close.
private def relay_exchange(strip : Bool, gated : Bool) : Exchange
  before = Gori::Settings.strip_extended_connect?
  Gori::Settings.strip_extended_connect = strip
  Gori::Settings.reset_extended_connect_withheld
  result = nil
  with_store do |store|
    browser, client_side = UNIXSocket.pair
    origin, upstream_side = UNIXSocket.pair
    sink = FrameLogSink.new
    ic = gated ? Gori::Interceptor.new(Gori::Scope.load(store)) : nil
    done = Channel(Nil).new(1)
    spawn do
      Gori::Proxy::H2::Relay.run(client_side, upstream_side, ORIGIN_HOST, ORIGIN_PORT, sink, interceptor: ic)
      done.send(nil)
    end

    browser.write(Frame::PREFACE)
    browser.write(settings_bytes(CLIENT_SETTINGS))
    browser.flush
    origin.read_fully(Bytes.new(Frame::PREFACE.size))
    origin_saw = read_frame_bytes(origin)

    origin.write(settings_bytes(ORIGIN_FIRST))
    origin.flush
    first = read_frame_bytes(browser)
    origin.write(settings_bytes(ORIGIN_LATER))
    origin.flush
    later = read_frame_bytes(browser)

    browser.close
    origin.close
    receive_within(done, 5, "the relay to end")
    # Keyed by the origin the relay dialled, case-folded.
    withheld = Gori::Settings.extended_connect_withheld?("origin.test", ORIGIN_PORT)
    result = Exchange.new([first, later], origin_saw, sink, withheld)
  end
  result.not_nil!
ensure
  Gori::Settings.strip_extended_connect = before.not_nil!
  Gori::Settings.reset_extended_connect_withheld
end

describe Gori::Proxy::H2::Relay do
  {false, true}.each do |gated|
    describe gated ? "with an interceptor (gated pump)" : "without an interceptor (plain pump)" do
      it "withholds the extended CONNECT offer from every origin SETTINGS frame when the switch is on" do
        ex = relay_exchange(strip: true, gated: gated)
        ex.client_saw[0].should eq(settings_bytes(entries({0x1_u16, 4096_u32}, {0x4_u16, 1_048_576_u32})))
        ex.client_saw[1].should eq(settings_bytes(entries({0x3_u16, 100_u32})))
        # The frame log holds the frame gori wrote, not the one it read.
        ex.sink.settings("in").should eq([entries({0x1_u16, 4096_u32}, {0x4_u16, 1_048_576_u32}),
                                          entries({0x3_u16, 100_u32})])
      end

      it "relays the origin's SETTINGS byte for byte when the switch is off" do
        ex = relay_exchange(strip: false, gated: gated)
        ex.client_saw.should eq([settings_bytes(ORIGIN_FIRST), settings_bytes(ORIGIN_LATER)])
        ex.sink.settings("in").should eq([ORIGIN_FIRST, ORIGIN_LATER])
      end

      it "never rewrites what the client sends the origin" do
        ex = relay_exchange(strip: true, gated: gated)
        ex.origin_saw.should eq(settings_bytes(CLIENT_SETTINGS))
        ex.sink.settings("out").should eq([CLIENT_SETTINGS])
      end
    end
  end

  it "records the origin it withheld the offer from, and logs it once" do
    Log.capture(level: :info) do |logs|
      relay_exchange(strip: true, gated: false).withheld.should be_true
      logs.check(:info, /h2 Origin\.Test:443: withheld SETTINGS_ENABLE_CONNECT_PROTOCOL.*network\.strip_extended_connect/)
      expect_raises(Spec::AssertionFailed) { logs.check(:info, /withheld SETTINGS_ENABLE_CONNECT_PROTOCOL/) }
    end
  end

  it "records nothing when the switch is off" do
    relay_exchange(strip: false, gated: false).withheld.should be_false
  end
end
