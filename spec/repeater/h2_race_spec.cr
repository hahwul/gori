require "../spec_helper"
require "socket"

private alias Frame = Gori::Proxy::H2::Frame
private alias HPACK = Gori::Proxy::H2::HPACK

module Gori::Repeater::Timing
  def self.duration_for_spec(result : Repeater::Result) : Int64?
    duration_of(result)
  end
end

# A cleartext-h2 origin for `H2Engine.single_packet` that waits until `expect` streams have
# ended, then hands the connection and the `{stream id, :path}` list to `answer`, which writes
# whatever frames the example needs. The connection stays open until `hold` has passed.
private def start_h2_scripted_origin(expect : Int32, hold : Time::Span = 0.5.seconds,
                                     &answer : IO, Array({UInt32, String}) ->) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
    conn.flush
    dec = HPACK::Decoder.new
    paths = {} of UInt32 => String
    ended = [] of {UInt32, String}
    while ended.size < expect
      f = Frame.read(conn)
      break if f.nil?
      type = f.frame_type
      if type == Frame::Type::Headers
        dec.decode(f.payload).each { |(n, v)| paths[f.stream_id] = v if n == ":path" }
      end
      # A SETTINGS ack carries the same 0x1 flag bit, so only HEADERS/DATA end a stream.
      next unless f.end_stream? && (type == Frame::Type::Headers || type == Frame::Type::Data)
      ended << {f.stream_id, paths[f.stream_id]? || "?"}
    end
    answer.call(conn, ended)
    sleep hold
    conn.close rescue nil
  rescue
  end
  port
end

private def h2_headers(io : IO, sid : UInt32, fields : Array({String, String}), end_stream : Bool) : Nil
  flags = Frame::END_HEADERS | (end_stream ? Frame::END_STREAM : 0_u8)
  io.write(Frame::Header.new(Frame::Type::Headers.value, flags, sid, HPACK::Encoder.new.encode(fields)).to_bytes)
  io.flush
end

private def h2_data(io : IO, sid : UInt32, body : String, end_stream : Bool) : Nil
  io.write(Frame::Header.new(Frame::Type::Data.value, end_stream ? Frame::END_STREAM : 0_u8, sid, body.to_slice).to_bytes)
  io.flush
end

private def race_wires(*paths : String) : Array(Bytes)
  paths.map { |p| "GET #{p} HTTP/2\r\nHost: 127.0.0.1\r\n\r\n".to_slice }.to_a
end

private STATUS_200_INDEX = 0x80_u8 | (HPACK::STATIC.index({":status", "200"}).not_nil! + 1).to_u8
private SERVER_INDEX     = 0x80_u8 | (HPACK::STATIC.index({"server", ""}).not_nil! + 1).to_u8
# Literal with incremental indexing: `x-sync: yes`, which lands in the dynamic table.
private SYNC_FIELD = Bytes[0x40, 0x06, 'x'.ord.to_u8, '-'.ord.to_u8, 's'.ord.to_u8,
  'y'.ord.to_u8, 'n'.ord.to_u8, 'c'.ord.to_u8, 0x03, 'y'.ord.to_u8,
  'e'.ord.to_u8, 's'.ord.to_u8]

# One header block as HEADERS + CONTINUATION frames of at most 16 KiB.
private def write_header_block(io : IO, sid : UInt32, block : Bytes, *, end_stream : Bool) : Nil
  offset = 0
  while offset < block.size
    size = Math.min(16_384, block.size - offset)
    type = offset == 0 ? Frame::Type::Headers : Frame::Type::Continuation
    flags = offset + size == block.size ? Frame::END_HEADERS : 0_u8
    flags |= Frame::END_STREAM if end_stream && offset == 0
    io.write(Frame::Header.new(type.value, flags, sid, block[offset, size]).to_bytes)
    offset += size
  end
end

describe "Repeater::H2Engine.single_packet" do
  # A member whose response ends on HEADERS(END_STREAM) — a 204/304/HEAD answer — used to close
  # without recording a duration, so it read 0µs and the timing verdict called the OTHER member
  # slower.
  it "records the duration of a stream that ends on its header block" do
    port = start_h2_scripted_origin(2) do |io, ended|
      sids = ended.to_h { |(sid, path)| {path, sid} }
      h2_headers(io, sids["/fast"], [{":status", "200"}], end_stream: false)
      h2_data(io, sids["/fast"], "body", end_stream: true)
      sleep 60.milliseconds
      h2_headers(io, sids["/slow"], [{":status", "204"}], end_stream: true)
    end

    slow, fast = Gori::Repeater::H2Engine.single_packet(race_wires("/slow", "/fast"),
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    slow.ok?.should be_true
    slow.response.not_nil!.status.should eq(204)
    fast.ok?.should be_true
    slow.duration_us.should be >= 50_000
    slow.duration_us.should be > fast.duration_us
  end

  # A header block the origin chose that breaks the HPACK decode must come back as a failed
  # result, not raise out of the race: the connection-wide decoder is desynced, so every stream
  # still open fails with that error while one that already finished keeps its response.
  it "fails the still-open streams on a malformed header block instead of raising" do
    port = start_h2_scripted_origin(3) do |io, ended|
      sids = ended.to_h { |(sid, path)| {path, sid} }
      h2_headers(io, sids["/done"], [{":status", "200"}], end_stream: false)
      h2_data(io, sids["/done"], "ok", end_stream: true)
      # 0x80 = indexed field, index 0 — never a valid reference.
      io.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, sids["/bad"], Bytes[0x80]).to_bytes)
      io.flush
    end

    done, bad, open = Gori::Repeater::H2Engine.single_packet(race_wires("/done", "/bad", "/open"),
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    done.ok?.should be_true
    String.new(done.body.not_nil!).should eq("ok")
    bad.ok?.should be_false
    bad.error.not_nil!.should contain("hpack")
    open.ok?.should be_false
    open.error.not_nil!.should contain("hpack")
  end

  it "keeps other streams alive after an oversized but synchronized header block" do
    port = start_h2_scripted_origin(2) do |io, ended|
      sids = ended.to_h { |(sid, path)| {path, sid} }
      repeat_count = HPACK::Decoder::MAX_HEADER_LIST // ("server".bytesize + HPACK::Decoder::ENTRY_OVERHEAD) + 1
      block = Bytes.new(1 + repeat_count + SYNC_FIELD.size) do |i|
        if i == 0
          STATUS_200_INDEX
        elsif i <= repeat_count
          SERVER_INDEX
        else
          SYNC_FIELD[i - repeat_count - 1]
        end
      end

      write_header_block(io, sids["/large"], block, end_stream: true)

      ok_block = Bytes[STATUS_200_INDEX, 0xbe_u8] # :status 200, then the final dynamic entry
      io.write(Frame::Header.new(Frame::Type::Headers.value,
        Frame::END_HEADERS | Frame::END_STREAM, sids["/ok"], ok_block).to_bytes)
      io.flush
    end

    large, ok = Gori::Repeater::H2Engine.single_packet(race_wires("/large", "/ok"),
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    large.ok?.should be_false
    large.error.not_nil!.should contain("header list too large")
    ok.ok?.should be_true
    ok.response.not_nil!.status.should eq(200)
    String.new(ok.head).should contain("x-sync: yes")
  end

  # A RAW block past MAX_HEADER_BLOCK is never decoded, so the table update inside it never
  # reached the shared decoder: the sibling then failed on (or silently misread) a dynamic index,
  # and the oversized stream itself said only "no response". Every live stream now names why.
  it "fails every live stream when a raw header block passes the 1 MiB cap" do
    port = start_h2_scripted_origin(2) do |io, ended|
      sids = ended.to_h { |(sid, path)| {path, sid} }
      # Literal-with-indexing x-sync: yes FIRST, then > 1 MiB of 1-byte indexed fields.
      block = IO::Memory.new
      block.write_byte(STATUS_200_INDEX)
      block.write(SYNC_FIELD)
      ((1 << 20) + 10).times { block.write_byte(SERVER_INDEX) }
      write_header_block(io, sids["/large"], block.to_slice, end_stream: true)
      ok_block = Bytes[STATUS_200_INDEX, 0xbe_u8] # :status 200, then the dynamic entry x-sync
      io.write(Frame::Header.new(Frame::Type::Headers.value,
        Frame::END_HEADERS | Frame::END_STREAM, sids["/ok"], ok_block).to_bytes)
      io.flush
    end

    large, ok = Gori::Repeater::H2Engine.single_packet(race_wires("/large", "/ok"),
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    large.ok?.should be_false
    large.error.not_nil!.should contain("HPACK state lost")
    ok.ok?.should be_false
    ok.error.not_nil!.should contain("HPACK state lost")
  end

  # DATA for a stream the race already closed returned before crediting the CONNECTION window,
  # so a failed stream's body could drain the shared 65535 bytes and stall every sibling.
  it "credits the connection window for DATA on a stream it already closed" do
    port = start_h2_scripted_origin(2, hold: 0.1.seconds) do |io, ended|
      sids = ended.to_h { |(sid, path)| {path, sid} }
      # /gone: a header list past the decoder's cap — failed locally, but its body still comes.
      repeat_count = HPACK::Decoder::MAX_HEADER_LIST // ("server".bytesize + HPACK::Decoder::ENTRY_OVERHEAD) + 1
      block = Bytes.new(1 + repeat_count) { |i| i == 0 ? STATUS_200_INDEX : SERVER_INDEX }
      write_header_block(io, sids["/gone"], block, end_stream: false)
      {16_384, 16_384, 16_384, 16_383}.each do |n| # exactly the default 65535 connection window
        io.write(Frame::Header.new(Frame::Type::Data.value, 0_u8, sids["/gone"], Bytes.new(n)).to_bytes)
      end
      h2_headers(io, sids["/ok"], [{":status", "200"}], end_stream: false)
      # A flow-controlled origin sends /ok's body only once the connection window is credited.
      io.as(TCPSocket).read_timeout = 1.second
      loop do
        f = Frame.read(io)
        break if f && f.frame_type == Frame::Type::WindowUpdate && f.stream_id == 0
      end
      h2_data(io, sids["/ok"], "ok", end_stream: true)
    end

    gone, ok = Gori::Repeater::H2Engine.single_packet(race_wires("/gone", "/ok"),
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false, timeout: 3.seconds)

    gone.ok?.should be_false
    ok.ok?.should be_true
    String.new(ok.body.not_nil!).should eq("ok")
  end

  # The read loop used to take its patience and deadline from the global io timeout, so an
  # origin trickling body bytes held a `timeout: 0.5s` race for up to three times the global one.
  it "bounds the read by the caller's timeout" do
    port = start_h2_scripted_origin(2, hold: 0.seconds) do |io, ended|
      ended.each { |(sid, _)| h2_headers(io, sid, [{":status", "200"}], end_stream: false) }
      80.times do
        ended.each { |(sid, _)| h2_data(io, sid, "x", end_stream: false) }
        sleep 100.milliseconds
      end
    end

    t0 = Time.instant
    results = Gori::Repeater::H2Engine.single_packet(race_wires("/a", "/b"),
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
      timeout: 500.milliseconds)
    elapsed = Time.instant - t0

    elapsed.should be < 3.seconds
    results.each(&.incomplete?.should(be_true))
  end

  # A stream still open when the read ends was closed by the collector in member order, so its
  # duration said B always finished last. Kept as the race's data, flagged so a timing run does
  # not count it as a sample.
  it "flags a stream the read left open, and timing drops it" do
    port = start_h2_scripted_origin(2, hold: 2.seconds) do |io, ended|
      ended.each do |(sid, _)|
        h2_headers(io, sid, [{":status", "200"}], end_stream: false)
        h2_data(io, sid, "partial", end_stream: false)
      end
    end

    results = Gori::Repeater::H2Engine.single_packet(race_wires("/a", "/b"),
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
      timeout: 150.milliseconds)

    results.each do |r|
      r.ok?.should be_true
      r.incomplete?.should be_true
      r.cut_short?.should be_true
      r.response.not_nil!.status.should eq(200)
    end
    Gori::Repeater::Timing.duration_for_spec(results[0]).should be_nil
  end
end
