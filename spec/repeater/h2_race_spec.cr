require "../spec_helper"
require "socket"

private alias Frame = Gori::Proxy::H2::Frame
private alias HPACK = Gori::Proxy::H2::HPACK

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
      status_index = 0x80_u8 | (HPACK::STATIC.index({":status", "200"}).not_nil! + 1).to_u8
      server_index = 0x80_u8 | (HPACK::STATIC.index({"server", ""}).not_nil! + 1).to_u8
      repeat_count = HPACK::Decoder::MAX_HEADER_LIST // ("server".bytesize + HPACK::Decoder::ENTRY_OVERHEAD) + 1
      sync_field = Bytes[0x40, 0x06, 'x'.ord.to_u8, '-'.ord.to_u8, 's'.ord.to_u8,
        'y'.ord.to_u8, 'n'.ord.to_u8, 'c'.ord.to_u8, 0x03, 'y'.ord.to_u8,
        'e'.ord.to_u8, 's'.ord.to_u8]
      block = Bytes.new(1 + repeat_count + sync_field.size) do |i|
        if i == 0
          status_index
        elsif i <= repeat_count
          server_index
        else
          sync_field[i - repeat_count - 1]
        end
      end

      offset = 0
      first = true
      while offset < block.size
        size = Math.min(16_384, block.size - offset)
        last = offset + size == block.size
        type = first ? Frame::Type::Headers : Frame::Type::Continuation
        flags = last ? Frame::END_HEADERS : 0_u8
        flags |= Frame::END_STREAM if first
        io.write(Frame::Header.new(type.value, flags, sids["/large"], block[offset, size]).to_bytes)
        offset += size
        first = false
      end

      ok_block = Bytes[status_index, 0xbe_u8] # :status 200, then the final dynamic entry
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
end
