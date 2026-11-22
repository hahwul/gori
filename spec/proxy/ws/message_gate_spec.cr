require "../../spec_helper"

# `WS::MessageGate`'s bounds on what may pile up behind a held message: the queue, and the
# Interceptor items it creates. Driven directly through `submit`, so every assertion is about
# structure (queue length, pending items, frames on the wire), never about wall time.

private alias WS = Gori::Proxy::WS

private GATE_CTX = WS::Context.new(host: "echo.test", port: 80, scheme: "http",
  method: "GET", target: "/ws")

private class GateSink < Gori::Proxy::FlowSink
  getter messages = [] of {String, Int32, String}

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    1_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
    @messages << {direction, opcode, String.new(payload)}
  end

  def notices : Array(String)
    @messages.map(&.[2]).select(&.starts_with?("[gori] "))
  end
end

private def with_gate_interceptor(query : String, &)
  path = File.tempname("gori-ws-gate", ".db")
  store = Gori::Store.open(path)
  begin
    ic = Gori::Interceptor.new(Gori::Scope.load(store))
    ic.toggle
    ic.set_filter(query)
    yield ic
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def client_frame(payload : Bytes) : Bytes
  mask = Bytes[0xAA, 0xBB, 0xCC, 0xDD]
  io = IO::Memory.new
  io.write_byte(0x80_u8 | WS::OP_TEXT)
  io.write_byte((0x80 | payload.size).to_u8)
  io.write(mask)
  payload.each_with_index { |b, i| io.write_byte(b ^ mask[i & 3]) }
  io.to_slice
end

private def submit(gate : WS::MessageGate, text : String) : Nil
  frame = client_frame(text.to_slice)
  gate.submit(WS::OP_TEXT, text.to_slice, WS::RawFrames.new(frame, frame), WS::Shape.new)
end

# Every data payload written to `dst`, in wire order.
private def wire_payloads(dst : IO::Memory) : Array(String)
  io = IO::Memory.new(dst.to_slice)
  seen = [] of String
  while h = WS.read_header(io)
    seen << String.new(WS.read_body(io, h).not_nil!.payload)
  end
  seen
end

private def wait_until(what : String, timeout = 3.seconds, &block : -> Bool) : Nil
  deadline = Time.instant + timeout
  until block.call
    raise "timed out waiting for #{what}" if Time.instant > deadline
    sleep 1.millisecond
  end
end

describe Gori::Proxy::WS::MessageGate do
  it "fails open on a flood of empty messages queued behind a hold" do
    with_gate_interceptor("proto:ws body:hold-me") do |ic|
      dst = IO::Memory.new
      sink = GateSink.new
      gate = WS::MessageGate.new("out", WS::Leg.new("out", dst, mask: true), 1_i64, sink, ic,
        GATE_CTX, mask: true)
      submit(gate, "hold-me")
      ic.pending_count.should eq(1)

      # Zero-byte messages used to cost nothing against the byte ceiling, so the queue grew
      # without bound. One past the length cap is where it has to give.
      flood = WS::MessageGate::MAX_QUEUED_MESSAGES + 1
      flood.times { submit(gate, "") }

      gate.pending?.should be_false
      ic.pending_count.should eq(0)
      sink.notices.count(&.includes?("messages queued behind a held message")).should eq(1)
      payloads = wire_payloads(dst)
      payloads.size.should eq(1 + flood)
      payloads.first.should eq("hold-me")
      payloads[1..].all?(&.empty?).should be_true

      # The gate is usable again afterwards: the next non-matching message goes straight out.
      submit(gate, "tail")
      wire_payloads(dst).last.should eq("tail")
    end
  end

  it "keeps arrival order through a length fail-open" do
    with_gate_interceptor("proto:ws body:hold-me") do |ic|
      dst = IO::Memory.new
      sink = GateSink.new
      gate = WS::MessageGate.new("out", WS::Leg.new("out", dst, mask: true), 1_i64, sink, ic,
        GATE_CTX, mask: true)
      submit(gate, "hold-me")
      sent = (0..WS::MessageGate::MAX_QUEUED_MESSAGES).map(&.to_s)
      sent.each { |s| submit(gate, s) }
      gate.pending?.should be_false
      wire_payloads(dst).should eq(["hold-me"] + sent)
    end
  end

  it "holds at most MAX_HELD_MESSAGES items per direction and keeps the rest in order" do
    with_gate_interceptor("proto:ws") do |ic|
      dst = IO::Memory.new
      sink = GateSink.new
      gate = WS::MessageGate.new("out", WS::Leg.new("out", dst, mask: true), 1_i64, sink, ic,
        GATE_CTX, mask: true)
      cap = WS::MessageGate::MAX_HELD_MESSAGES
      sent = (0...(cap + 50)).map { |i| "m#{i}" }
      sent.each { |s| submit(gate, s) }

      # The operator keeps every message already held; the overflow waits behind them unheld.
      ic.pending_count.should eq(cap)
      ic.pending.map { |it| String.new(it.raw) }.sort!.should eq(sent[0, cap].sort)
      dst.size.should eq(0)
      sink.notices.count(&.includes?("messages are already held")).should eq(1)

      ic.forward_all
      wait_until("the queue to drain") { !gate.pending? }
      wire_payloads(dst).should eq(sent)
    end
  end

  it "bounds held items when every empty message matches the condition" do
    with_gate_interceptor("proto:ws") do |ic|
      dst = IO::Memory.new
      sink = GateSink.new
      gate = WS::MessageGate.new("out", WS::Leg.new("out", dst, mask: true), 1_i64, sink, ic,
        GATE_CTX, mask: true)
      n = WS::MessageGate::MAX_QUEUED_MESSAGES + 1000
      n.times { submit(gate, "") }
      ic.pending_count.should be <= WS::MessageGate::MAX_HELD_MESSAGES
      # Everything that is not still held reached the wire.
      held = ic.pending_count
      queued_behind = n - wire_payloads(dst).size
      queued_behind.should be >= held
      queued_behind.should be <= WS::MessageGate::MAX_QUEUED_MESSAGES + 1
      gate.close
      wire_payloads(dst).size.should eq(n)
    end
  end
end
