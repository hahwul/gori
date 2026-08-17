require "../spec_helper"
require "socket"

private alias Frame = Gori::Proxy::H2::Frame
private alias HPACK = Gori::Proxy::H2::HPACK

# The SERVER connection preface: RFC 9113 §3.4 makes a (possibly empty) SETTINGS frame the
# FIRST frame a server sends. These origins used to hold it back until they had read the whole
# request, which no real stack does — and the client now reads it before writing the request
# body, because §6.9.2 lets SETTINGS_INITIAL_WINDOW_SIZE put the send window below the 65535
# default. `settings` carries the id/value pairs (empty = defaults).
private def send_server_preface(conn : IO, settings : Bytes = Bytes.empty) : Nil
  conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, settings).to_bytes)
  conn.flush
end

# An origin that accepts the TCP connection and nothing more. The refusal examples below never
# write a request, so the h2-speaking origin's `read_preface` would hit EOF and print an
# unhandled-spawn backtrace into the spec output — noise that reads like a failure. All these
# examples need is a port `H2Engine.open` can connect to.
private def start_quiet_origin : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  # Closes each connection immediately — "this port is not TLS" — but accepts REPEATEDLY.
  # The one-shot version served only the first dial, so an example that dials twice (the
  # h1-vs-h2 comparison does, once per engine) got the intended verdict on the first connection
  # and whatever a vanished listener produces on the second. That read as the two engines
  # disagreeing when it was the harness running out.
  spawn do
    while conn = origin.accept?
      conn.close rescue nil
    end
  rescue
  end
  port
end

# A real TLS listener presenting a leaf minted by a throwaway gori CA — self-signed as far as
# this process is concerned, so `verify_upstream: true` fails verification against it. It never
# answers: every example using it is about what happens BEFORE a request goes out.
#
# `advertise_h2: false` makes `context_for` offer only `http/1.1` over ALPN, which is the
# "handshake fine, this origin has no h2" case — a lab or legacy origin, and the one dial
# failure gori can state without hedging.
private def start_tls_origin(advertise_h2 : Bool) : Int32
  dir = File.tempname("gori-h2ca")
  ca = Gori::Proxy::Tls::CertAuthority.load_or_create(dir)
  ctx = ca.context_for("127.0.0.1", advertise_h2: advertise_h2)
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while conn = origin.accept?
      spawn do
        ssl = OpenSSL::SSL::Socket::Server.new(conn, ctx, sync_close: true)
        # Longer than any example's own timeout. At 2s a second connection on a loaded runner
        # could start its handshake after this fiber had closed, and the example then compared
        # a verification verdict against a reset — a harness race that read as a real divergence
        # between the h1 and h2 engines.
        sleep 30.seconds
        ssl.close
      rescue
        conn.close rescue nil
      end
    end
  rescue
  ensure
    FileUtils.rm_rf(dir) if Dir.exists?(dir)
  end
  port
end

# A minimal cleartext-h2 origin: reads the preface + request, records the decoded
# request line and body, then replies HEADERS(:status) + DATA.
private def start_h2_origin(status : Int32, body : String, seen : Channel(String)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    send_server_preface(conn)
    dec = HPACK::Decoder.new
    method = path = ""
    req_body = IO::Memory.new
    headers_done = false
    loop do
      f = Frame.read(conn)
      break if f.nil?
      case f.frame_type
      when Frame::Type::Headers
        if f.stream_id == 1 && f.end_headers?
          dec.decode(f.payload).each do |(n, v)|
            method = v if n == ":method"
            path = v if n == ":path"
          end
          headers_done = true
          break if f.end_stream?
        end
      when Frame::Type::Data
        req_body.write(f.payload) if f.stream_id == 1
        break if f.end_stream?
      else
        # ignore SETTINGS/WINDOW_UPDATE from the client
      end
    end
    seen.send("#{method} #{path} body=#{req_body}")

    status_block = HPACK::Encoder.new.encode([{":status", status.to_s}, {"server", "gori-test"}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, status_block).to_bytes)
    conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, 1_u32, body.to_slice).to_bytes)
    conn.flush
    sleep 0.2.seconds
    conn.close
  end
  port
end

# A cleartext-h2 origin that records the decoded `:authority` pseudo-header of the
# request (so a test can assert what authority the client actually put on the wire).
private def start_h2_origin_authority(status : Int32, seen : Channel(String)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    send_server_preface(conn)
    dec = HPACK::Decoder.new
    authority = "(none)"
    loop do
      f = Frame.read(conn)
      break if f.nil?
      if f.frame_type == Frame::Type::Headers && f.stream_id == 1 && f.end_headers?
        dec.decode(f.payload).each { |(n, v)| authority = v if n == ":authority" }
        break if f.end_stream?
      elsif f.frame_type == Frame::Type::Data && f.end_stream?
        break
      end
    end
    seen.send(authority)
    sb = HPACK::Encoder.new.encode([{":status", status.to_s}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, sb).to_bytes)
    conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, 1_u32, "ok".to_slice).to_bytes)
    conn.flush
    sleep 0.2.seconds
    conn.close
  end
  port
end

# A cleartext-h2 origin that sends HEADERS(:status) + one DATA frame WITHOUT
# END_STREAM, then drops the connection — a truncated response the client must
# flag as incomplete (no END_STREAM ever arrives).
# Sibling of `start_h2_origin_truncated` that closes STRICTLY INSIDE a frame rather than on
# its boundary: it writes a complete HEADERS + DATA, then 5 bytes of a 9-byte frame header
# and hangs up. `Frame.read` -> `read_exact` answers that with `Gori::Error`, NOT `IO::Error`
# — so it used to escape both rescue arms and destroy the fully decoded 200 + body. The
# boundary helper cannot reach this path: there `Frame.read` returns nil.
private def start_h2_origin_truncated_midframe(status : Int32, partial : String) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    send_server_preface(conn)
    loop do
      f = Frame.read(conn)
      break if f.nil?
      break if f.frame_type.in?(Frame::Type::Headers, Frame::Type::Data) && f.end_stream?
    end
    block = HPACK::Encoder.new.encode([{":status", status.to_s}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, block).to_bytes)
    conn.write(Frame::Header.new(Frame::Type::Data.value, 0_u8, 1_u32, partial.to_slice).to_bytes)
    # A PARTIAL frame header — 5 of the 9 bytes — then close. EOF lands mid-frame.
    conn.write(Bytes[0, 0, 8, 0, 0])
    conn.flush
    conn.close
  end
  port
end

private def start_h2_origin_truncated(status : Int32, partial : String) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    send_server_preface(conn)
    loop do
      f = Frame.read(conn)
      break if f.nil?
      break if f.frame_type.in?(Frame::Type::Headers, Frame::Type::Data) && f.end_stream?
    end
    block = HPACK::Encoder.new.encode([{":status", status.to_s}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, block).to_bytes)
    # DATA WITHOUT END_STREAM, then close mid-stream.
    conn.write(Frame::Header.new(Frame::Type::Data.value, 0_u8, 1_u32, partial.to_slice).to_bytes)
    conn.flush
    conn.close
  end
  port
end

# A cleartext-h2 origin that ENFORCES flow control: it sends `body` as DATA frames
# but never exceeds the available connection/stream window (both start at the 65535
# default), blocking for the client's WINDOW_UPDATE frames to replenish. A client
# that never sends WINDOW_UPDATE stalls past 65535 bytes (the bug this guards).
private def start_h2_origin_flow_controlled(status : Int32, body : Bytes) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    send_server_preface(conn)
    # drain to the request's END_STREAM (a body-less GET)
    loop do
      f = Frame.read(conn)
      break if f.nil?
      break if f.frame_type == Frame::Type::Headers && f.stream_id == 1 && f.end_stream?
    end
    sb = HPACK::Encoder.new.encode([{":status", status.to_s}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, sb).to_bytes)
    conn.flush

    conn_win = 65535
    stream_win = 65535
    offset = 0
    begin
      while offset < body.size
        while conn_win <= 0 || stream_win <= 0
          f = Frame.read(conn)
          break if f.nil?
          next unless f.frame_type == Frame::Type::WindowUpdate
          inc = (IO::ByteFormat::BigEndian.decode(UInt32, f.payload) & 0x7fff_ffff).to_i
          f.stream_id == 0 ? (conn_win += inc) : (stream_win += inc)
        end
        n = {16384, body.size - offset, conn_win, stream_win}.min
        last = offset + n >= body.size
        conn.write(Frame::Header.new(Frame::Type::Data.value, last ? Frame::END_STREAM : 0_u8, 1_u32, body[offset, n]).to_bytes)
        conn.flush
        conn_win -= n
        stream_win -= n
        offset += n
      end
      sleep 0.2.seconds
    rescue
    end
    conn.close
  end
  port
end

# An origin that interleaves PING frames (no END_STREAM) before the real response — the
# non-terminal-frame path the MAX_FRAMES counter now guards. A handful must be ACKed and
# must NOT stall or corrupt the response.
private def start_h2_origin_pings(status : Int32, body : String, pings : Int32) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    send_server_preface(conn)
    loop do
      f = Frame.read(conn)
      break if f.nil?
      break if f.frame_type.in?(Frame::Type::Headers, Frame::Type::Data) && f.end_stream?
    end
    pings.times { conn.write(Frame::Header.new(Frame::Type::Ping.value, 0_u8, 0_u32, Bytes.new(8)).to_bytes) }
    sb = HPACK::Encoder.new.encode([{":status", status.to_s}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, sb).to_bytes)
    conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, 1_u32, body.to_slice).to_bytes)
    conn.flush
    sleep 0.2.seconds
    conn.close
  end
  port
end

# A cleartext-h2 origin that records the request's DECODED FIELD LIST verbatim and the
# {type, payload size} of every frame that carried the header block. The existing origins
# project the request down to `"#{method} #{path}"`, which cannot see the two things this
# file's newest examples are about: which regular fields survived the encoder, and whether
# the block went out as one over-size HEADERS or as HEADERS + CONTINUATION.
private def start_h2_origin_recording(seen : Channel({Array({String, String}), Array({String, Int32})})) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    send_server_preface(conn)
    dec = HPACK::Decoder.new
    block = IO::Memory.new
    shape = [] of {String, Int32}
    fields = [] of {String, String}
    # END_STREAM rides the HEADERS frame while END_HEADERS rides the LAST CONTINUATION, so
    # neither flag alone ends a split request — latch the first and wait for the second.
    end_stream = false
    loop do
      f = Frame.read(conn)
      break if f.nil?
      case f.frame_type
      when Frame::Type::Headers, Frame::Type::Continuation
        next unless f.stream_id == 1
        shape << {f.frame_type.to_s, f.payload.size}
        block.write(f.payload)
        end_stream ||= f.end_stream?
        if f.end_headers?
          dec.decode(block.to_slice).each { |(n, v)| fields << {n, v} }
          break if end_stream
        end
      when Frame::Type::Data
        break if f.end_stream?
      else
        # SETTINGS / WINDOW_UPDATE from the client
      end
    end
    seen.send({fields, shape})

    sb = HPACK::Encoder.new.encode([{":status", "200"}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, sb).to_bytes)
    conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, 1_u32, "ok".to_slice).to_bytes)
    conn.flush
    sleep 0.2.seconds
    conn.close
  end
  port
end

# A cleartext-h2 origin that answers the first HEADERS with GOAWAY(`code`) + debug data and
# hangs up, the way a real stack rejects a frame it will not accept.
private def start_h2_origin_goaway(code : UInt32, debug : String) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    send_server_preface(conn)
    loop do
      f = Frame.read(conn)
      break if f.nil?
      next unless f.frame_type == Frame::Type::Headers
      payload = IO::Memory.new
      payload.write_bytes(0_u32, IO::ByteFormat::BigEndian) # last-stream-id
      payload.write_bytes(code, IO::ByteFormat::BigEndian)
      payload.write(debug.to_slice)
      conn.write(Frame::Header.new(Frame::Type::Goaway.value, 0_u8, 0_u32, payload.to_slice).to_bytes)
      conn.flush
      break
    end
    conn.close
  end
  port
end

# A cleartext-h2 origin that enforces RECEIVE-side flow control the way nginx/envoy/Go do:
# it advertises `init_window` as SETTINGS_INITIAL_WINDOW_SIZE, tracks the connection and
# stream windows, and answers a client that overruns them with GOAWAY(FLOW_CONTROL_ERROR)
# — the frame that made every h2 request body past the peer's window unsendable.
#
# `grant: false` never replenishes: the client must stop at the window and time out on its
# own side (the socket is HELD OPEN, so a stall is distinguishable from a hangup). Reports
# the body bytes it received, or -1 when the client overran the window.
private def start_h2_origin_window(init_window : Int32, grant : Bool, seen : Channel(Int32)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    settings = IO::Memory.new
    settings.write_bytes(0x4_u16, IO::ByteFormat::BigEndian) # SETTINGS_INITIAL_WINDOW_SIZE
    settings.write_bytes(init_window.to_u32, IO::ByteFormat::BigEndian)
    send_server_preface(conn, settings.to_slice)

    win = init_window
    got = 0
    overran = false
    finished = false
    until finished
      if win <= 0
        # The window is spent, so a client that respects §6.9.1 must WAIT right here. Probe
        # for exactly that: anything that arrives during this idle slice was sent past the
        # window. Crediting eagerly per DATA frame would hide the defect entirely — the
        # window is back before the overrunning frame is even read.
        conn.read_timeout = 200.milliseconds
        stray = begin
          Frame.read(conn)
        rescue IO::TimeoutError
          nil
        end
        conn.read_timeout = 5.seconds
        if stray && stray.frame_type == Frame::Type::Data && stray.payload.size > 0
          overran = true
          break
        end
        break unless grant
        inc = Bytes.new(4)
        IO::ByteFormat::BigEndian.encode(init_window.to_u32, inc)
        {0_u32, 1_u32}.each do |sid|
          conn.write(Frame::Header.new(Frame::Type::WindowUpdate.value, 0_u8, sid, inc).to_bytes)
        end
        conn.flush
        win += init_window
      end
      f = begin
        Frame.read(conn)
      rescue IO::Error
        nil
      end
      break if f.nil?
      case f.frame_type
      when Frame::Type::Headers
        finished = true if f.stream_id == 1 && f.end_stream?
      when Frame::Type::Data
        next unless f.stream_id == 1
        win -= f.payload.size
        got += f.payload.size
        finished = true if f.end_stream?
      else
        # SETTINGS ack / PING / WINDOW_UPDATE from the client
      end
    end
    seen.send(overran ? -1 : got)
    if overran
      payload = IO::Memory.new
      payload.write_bytes(1_u32, IO::ByteFormat::BigEndian) # last-stream-id
      payload.write_bytes(3_u32, IO::ByteFormat::BigEndian) # FLOW_CONTROL_ERROR
      conn.write(Frame::Header.new(Frame::Type::Goaway.value, 0_u8, 0_u32, payload.to_slice).to_bytes)
      conn.flush
    elsif finished
      sb = HPACK::Encoder.new.encode([{":status", "200"}])
      conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, sb).to_bytes)
      conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, 1_u32, "ok".to_slice).to_bytes)
      conn.flush
      sleep 0.2.seconds
    else
      sleep 3.seconds # grant:false — hold the socket so the client times out, not sees an EOF
    end
    conn.close
  end
  port
end

# An origin that ANSWERS WHILE THE REQUEST BODY IS STILL GOING OUT — the 413 every upload /
# body-size probe exists to find, and explicitly permitted by RFC 9113 §8.1. It advertises
# `init_window`, never replenishes it, and once `after` body bytes have arrived replies
# `status` either as HEADERS+DATA/END_STREAM (`with_body: true` — the ORDINARY shape of an
# error response) or as a bodiless HEADERS/END_STREAM. Both are needed: END_HEADERS is a
# HEADERS/CONTINUATION flag, so a detector that tests for it can only ever fire on the
# bodiless one. Reports the body bytes it received.
private def start_h2_origin_early_response(init_window : Int32, after : Int32, status : Int32,
                                           with_body : Bool, seen : Channel(Int32)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    settings = IO::Memory.new
    settings.write_bytes(0x4_u16, IO::ByteFormat::BigEndian) # SETTINGS_INITIAL_WINDOW_SIZE
    settings.write_bytes(init_window.to_u32, IO::ByteFormat::BigEndian)
    send_server_preface(conn, settings.to_slice)

    got = 0
    begin
      until got >= after
        f = Frame.read(conn)
        break if f.nil?
        next unless f.frame_type == Frame::Type::Data && f.stream_id == 1
        got += f.payload.size
        break if f.end_stream?
      end
      sb = HPACK::Encoder.new.encode([{":status", status.to_s}, {"content-length", with_body ? "17" : "0"}])
      flags = Frame::END_HEADERS | (with_body ? 0_u8 : Frame::END_STREAM)
      conn.write(Frame::Header.new(Frame::Type::Headers.value, flags, 1_u32, sb).to_bytes)
      if with_body
        conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, 1_u32,
          "request too large".to_slice).to_bytes)
      end
      conn.flush
      sleep 0.3.seconds # hold the socket open: a stall must be distinguishable from a hangup
    rescue
    end
    seen.send(got)
    conn.close
  end
  port
end

# An origin that answers a tight window with an INTERIM 1xx and then expects the rest of the
# body — the complement of `start_h2_origin_early_response`, and the shape that decides
# whether "a header block on stream 1" may be read as "stop writing". It advertises
# `init_window`, sends `100 Continue` (HEADERS, END_HEADERS, NO END_STREAM) once the window is
# spent, then replenishes until the whole body has arrived and answers 200. A client that
# stops writing at the 1xx starves here. Reports the body bytes it received.
private def start_h2_origin_interim(init_window : Int32, total : Int32, seen : Channel(Int32)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    settings = IO::Memory.new
    settings.write_bytes(0x4_u16, IO::ByteFormat::BigEndian)
    settings.write_bytes(init_window.to_u32, IO::ByteFormat::BigEndian)
    send_server_preface(conn, settings.to_slice)

    got = 0
    sent_interim = false
    begin
      until got >= total
        f = Frame.read(conn)
        break if f.nil?
        next unless f.frame_type == Frame::Type::Data && f.stream_id == 1
        got += f.payload.size
        break if f.end_stream?
        unless sent_interim
          sent_interim = true
          ib = HPACK::Encoder.new.encode([{":status", "100"}])
          conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, ib).to_bytes)
        end
        inc = Bytes.new(4)
        IO::ByteFormat::BigEndian.encode(init_window.to_u32, inc)
        {0_u32, 1_u32}.each do |sid|
          conn.write(Frame::Header.new(Frame::Type::WindowUpdate.value, 0_u8, sid, inc).to_bytes)
        end
        conn.flush
      end
      sb = HPACK::Encoder.new.encode([{":status", "200"}])
      conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, sb).to_bytes)
      conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, 1_u32, "ok".to_slice).to_bytes)
      conn.flush
      sleep 0.2.seconds
    rescue
    end
    seen.send(got)
    conn.close
  end
  port
end

# An origin whose FIRST frame is NOT SETTINGS — a PING or a connection WINDOW_UPDATE — with
# its real SETTINGS (`init_window`) arriving `delay` later. RFC 9113 §3.4 says SETTINGS comes
# first, but a client that reads exactly ONE frame draws the wrong conclusion from any other
# opener and writes against the 65535-byte default. Enforces the advertised window and
# answers an overrun with GOAWAY(FLOW_CONTROL_ERROR), reporting body bytes or -1 on overrun.
private def start_h2_origin_late_settings(init_window : Int32, first : Symbol, delay : Time::Span,
                                          seen : Channel(Int32)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 10.seconds
    Frame.read_preface(conn)
    if first == :ping
      conn.write(Frame::Header.new(Frame::Type::Ping.value, 0_u8, 0_u32, Bytes.new(8)).to_bytes)
    else
      inc = Bytes.new(4)
      IO::ByteFormat::BigEndian.encode(1_u32, inc)
      conn.write(Frame::Header.new(Frame::Type::WindowUpdate.value, 0_u8, 0_u32, inc).to_bytes)
    end
    conn.flush
    spawn do
      sleep delay
      settings = IO::Memory.new
      settings.write_bytes(0x4_u16, IO::ByteFormat::BigEndian)
      settings.write_bytes(init_window.to_u32, IO::ByteFormat::BigEndian)
      send_server_preface(conn, settings.to_slice) rescue nil
    end

    win = init_window
    got = 0
    overran = false
    begin
      loop do
        f = Frame.read(conn)
        break if f.nil?
        next unless f.frame_type == Frame::Type::Data && f.stream_id == 1
        if f.payload.size > win
          overran = true
          break
        end
        win -= f.payload.size
        got += f.payload.size
        break if f.end_stream?
      end
    rescue
    end
    seen.send(overran ? -1 : got)
    if overran
      payload = IO::Memory.new
      payload.write_bytes(1_u32, IO::ByteFormat::BigEndian) # last-stream-id
      payload.write_bytes(3_u32, IO::ByteFormat::BigEndian) # FLOW_CONTROL_ERROR
      conn.write(Frame::Header.new(Frame::Type::Goaway.value, 0_u8, 0_u32, payload.to_slice).to_bytes)
      conn.flush rescue nil
    else
      sleep 2.seconds
    end
    conn.close
  end
  port
end

# An origin that advertises `init_window`, NEVER grants more, and keeps the socket busy —
# either with keepalive PINGs or with the RFC 9113 §6.9.1-illegal `WINDOW_UPDATE +0`. Both
# reset the per-read idle timer without ever reopening the send window, which is how the
# "bounded wait" turned out to be bounded by frame COUNT (MAX_FRAMES: ~55 hours at a 2 s
# ping cadence) rather than by any wall clock. Reports the body bytes it received.
private def start_h2_origin_busy_stall(init_window : Int32, filler : Symbol,
                                       interval : Time::Span, seen : Channel(Int32)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 30.seconds
    Frame.read_preface(conn)
    settings = IO::Memory.new
    settings.write_bytes(0x4_u16, IO::ByteFormat::BigEndian)
    settings.write_bytes(init_window.to_u32, IO::ByteFormat::BigEndian)
    send_server_preface(conn, settings.to_slice)

    stop = false
    spawn do
      until stop
        sleep interval
        break if stop
        begin
          if filler == :ping
            conn.write(Frame::Header.new(Frame::Type::Ping.value, 0_u8, 0_u32, Bytes.new(8)).to_bytes)
          else
            conn.write(Frame::Header.new(Frame::Type::WindowUpdate.value, 0_u8, 1_u32, Bytes.new(4)).to_bytes)
          end
          conn.flush
        rescue
          break
        end
      end
    end

    got = 0
    begin
      loop do
        f = Frame.read(conn)
        break if f.nil?
        next unless f.frame_type == Frame::Type::Data && f.stream_id == 1
        got += f.payload.size
        break if f.end_stream?
      end
    rescue
    end
    stop = true
    seen.send(got)
    conn.close rescue nil
  end
  port
end

# A cleartext-h2 origin that answers with RST_STREAM(`code`) on stream 1 — optionally after
# a complete response head and a partial body, which is how a server aborts a response it
# already began (CANCEL / INTERNAL_ERROR) and the case where the cause used to vanish.
private def start_h2_origin_rst(code : UInt32, after_headers : Bool = false) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    send_server_preface(conn)
    loop do
      f = Frame.read(conn)
      break if f.nil?
      break if f.frame_type.in?(Frame::Type::Headers, Frame::Type::Data) && f.end_stream?
    end
    if after_headers
      sb = HPACK::Encoder.new.encode([{":status", "200"}, {"content-type", "text/plain"}])
      conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, sb).to_bytes)
      conn.write(Frame::Header.new(Frame::Type::Data.value, 0_u8, 1_u32, "partial".to_slice).to_bytes)
    end
    payload = Bytes.new(4)
    IO::ByteFormat::BigEndian.encode(code, payload)
    conn.write(Frame::Header.new(Frame::Type::RstStream.value, 0_u8, 1_u32, payload).to_bytes)
    conn.flush
    sleep 0.2.seconds
    conn.close
  end
  port
end

# A cleartext-h2 origin that completes its own preface and then says NOTHING — the idle
# read timeout, which is a different finding from a socket that hung up.
private def start_h2_origin_mute : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    send_server_preface(conn)
    sleep 3.seconds
    conn.close
  end
  port
end

# A cleartext-h2 origin that reads the request and then HANGS UP without a single response
# frame — the dead-socket case.
private def start_h2_origin_hangup : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    send_server_preface(conn)
    loop do
      f = Frame.read(conn)
      break if f.nil?
      break if f.frame_type.in?(Frame::Type::Headers, Frame::Type::Data) && f.end_stream?
    end
    conn.close
  end
  port
end

# A gRPC origin in one of the two structurally different shapes an operator has to be able to
# tell apart: `trailers_only` puts grpc-status in the INITIAL HEADERS block (the gRPC
# "Trailers-Only" response), otherwise it arrives in a real TRAILING HEADERS block after the
# message. Both render the same fields — only WHERE they arrived differs.
private def start_h2_origin_grpc(trailers_only : Bool) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    send_server_preface(conn)
    loop do
      f = Frame.read(conn)
      break if f.nil?
      break if f.frame_type.in?(Frame::Type::Headers, Frame::Type::Data) && f.end_stream?
    end
    enc = HPACK::Encoder.new
    if trailers_only
      blk = enc.encode([{":status", "200"}, {"content-type", "application/grpc"},
                        {"grpc-status", "5"}, {"grpc-message", "not found"}])
      conn.write(Frame::Header.new(Frame::Type::Headers.value,
        Frame::END_HEADERS | Frame::END_STREAM, 1_u32, blk).to_bytes)
    else
      blk = enc.encode([{":status", "200"}, {"content-type", "application/grpc"}])
      conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, blk).to_bytes)
      conn.write(Frame::Header.new(Frame::Type::Data.value, 0_u8, 1_u32, Bytes[0, 0, 0, 0, 2, 0x68, 0x69]).to_bytes)
      tb = enc.encode([{"grpc-status", "5"}, {"grpc-message", "not found"}])
      conn.write(Frame::Header.new(Frame::Type::Headers.value,
        Frame::END_HEADERS | Frame::END_STREAM, 1_u32, tb).to_bytes)
    end
    conn.flush
    sleep 0.2.seconds
    conn.close
  end
  port
end

# An origin that DRIPS flow-control window: it advertises SETTINGS_INITIAL_WINDOW_SIZE 0 and
# then grants `per_grant` bytes on the connection AND the stream every `interval`, `grants`
# times, before closing. A throttling gateway looks like this, and so does a DoS-shaped answer
# to an upload probe — and it is the shape a per-STALL deadline cannot bound at all, because
# every grant is progress and restarts the clock. Reports the body bytes it received; answers
# 200 the moment `total` of them have arrived, so "it finished inside the budget" is testable
# with the same origin.
private def start_h2_origin_drip(per_grant : Int32, interval : Time::Span, grants : Int32,
                                 total : Int32, seen : Channel(Int32)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 30.seconds
    Frame.read_preface(conn)
    settings = IO::Memory.new
    settings.write_bytes(0x4_u16, IO::ByteFormat::BigEndian) # SETTINGS_INITIAL_WINDOW_SIZE
    settings.write_bytes(0_u32, IO::ByteFormat::BigEndian)   # …of ZERO: nothing may be sent yet
    send_server_preface(conn, settings.to_slice)

    stop = false
    spawn do
      inc = Bytes.new(4)
      IO::ByteFormat::BigEndian.encode(per_grant.to_u32, inc)
      grants.times do
        sleep interval
        break if stop
        begin
          {0_u32, 1_u32}.each do |sid|
            conn.write(Frame::Header.new(Frame::Type::WindowUpdate.value, 0_u8, sid, inc).to_bytes)
          end
          conn.flush
        rescue
          break
        end
      end
    end

    got = 0
    begin
      loop do
        f = Frame.read(conn)
        break if f.nil?
        next unless f.frame_type == Frame::Type::Data && f.stream_id == 1
        got += f.payload.size
        break if got >= total || f.end_stream?
      end
      if got >= total
        sb = HPACK::Encoder.new.encode([{":status", "200"}])
        conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, sb).to_bytes)
        conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, 1_u32, "ok".to_slice).to_bytes)
        conn.flush
        sleep 0.2.seconds
      end
    rescue
    end
    stop = true
    seen.send(got)
    conn.close rescue nil
  end
  port
end

# An origin that answers with an INTERIM 1xx and then either goes SILENT with the socket held
# OPEN (`final_after` nil) or sends the real final response after that delay. RFC 9110 §15.2:
# a 1xx precedes the final response and is not one, so the first shape is an exchange with no
# response — reported for years as `ok:true, status:100, error:null`. The socket is never
# closed in the silent case: any sentence about the origin "closing" is provably false of it.
private def start_h2_origin_interim_then(status : Int32, final_after : Time::Span?) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 30.seconds
    Frame.read_preface(conn)
    send_server_preface(conn)
    sent = false
    begin
      loop do
        f = Frame.read(conn)
        break if f.nil?
        next unless f.stream_id == 1 && f.frame_type.in?(Frame::Type::Headers, Frame::Type::Data)
        unless sent
          sent = true
          ib = HPACK::Encoder.new.encode([{":status", status.to_s}])
          # END_HEADERS but NO END_STREAM: an interim block cannot end the stream.
          conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, ib).to_bytes)
          conn.flush
        end
        break if f.end_stream?
      end
      if d = final_after
        sleep d
        sb = HPACK::Encoder.new.encode([{":status", "200"}, {"server", "late"}])
        conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, sb).to_bytes)
        conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, 1_u32, "late".to_slice).to_bytes)
        conn.flush
        sleep 0.2.seconds
      else
        sleep 10.seconds # hold the socket OPEN: "the origin closed" must stay falsifiable
      end
    rescue
    end
    conn.close rescue nil
  end
  port
end

# An origin that answers with a COMPLETE final response and then sends a header block AFTER it.
# What that block is decides what gori must do with it:
#
#   `late: :interim`    — `HEADERS(:status 103, link)`. An RFC 9110 §15.2 violation: a 1xx
#                         precedes the final response, it is not one. This is what an h2
#                         response-splitting / header-injection probe produces and what a
#                         buggy gateway or an h1→h2 translating proxy emits.
#   `late: :trailers`   — a real trailers block (no `:status`). Must stay trailers.
#   `late: :interim_x2` — two late 1xx blocks, so the drop cannot accumulate.
#
# `end_stream_on_late` puts END_STREAM on the late block itself instead of on a following DATA
# frame; before the fix that variant failed DIFFERENTLY (the 1xx's field was MERGED into the
# final head rather than replacing it), so both shapes are driven.
private def start_h2_origin_late_block(late : Symbol, end_stream_on_late : Bool = false) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 30.seconds
    Frame.read_preface(conn)
    send_server_preface(conn)
    begin
      loop do
        f = Frame.read(conn)
        break if f.nil?
        break if f.frame_type.in?(Frame::Type::Headers, Frame::Type::Data) && f.end_stream?
      end
      body = "REALBODY"
      enc = HPACK::Encoder.new # ONE encoder: the dynamic table spans every block on the stream
      final = enc.encode([{":status", "200"}, {"content-type", "text/plain"},
                          {"x-final", "yes"}, {"content-length", body.bytesize.to_s}])
      conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, final).to_bytes)
      conn.flush
      blocks = case late
               when :trailers then [[{"x-checksum", "deadbeef"}]]
               when :interim_x2 then [[{":status", "103"}, {"link", "</a.css>; rel=preload"}],
                                      [{":status", "103"}, {"link", "</b.css>; rel=preload"}]]
               else [[{":status", "103"}, {"link", "</late.css>; rel=preload"}]]
               end
      blocks.each_with_index do |fields, i|
        last = i == blocks.size - 1
        flags = Frame::END_HEADERS | ((end_stream_on_late && last) ? Frame::END_STREAM : 0_u8)
        conn.write(Frame::Header.new(Frame::Type::Headers.value, flags, 1_u32, enc.encode(fields)).to_bytes)
        conn.flush
      end
      unless end_stream_on_late
        conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, 1_u32, body.to_slice).to_bytes)
        conn.flush
      end
      sleep 0.3.seconds
    rescue
    end
    conn.close rescue nil
  end
  port
end

# HEADERS(:status) + one DATA frame WITHOUT END_STREAM, and then the socket is HELD OPEN — the
# sibling of `start_h2_origin_truncated`, which closes. Both produce an incomplete response;
# only one of them involves the origin closing anything.
private def start_h2_origin_stalled_body(status : Int32, partial : String) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 30.seconds
    Frame.read_preface(conn)
    send_server_preface(conn)
    loop do
      f = Frame.read(conn)
      break if f.nil?
      break if f.frame_type.in?(Frame::Type::Headers, Frame::Type::Data) && f.end_stream?
    end
    block = HPACK::Encoder.new.encode([{":status", status.to_s}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, block).to_bytes)
    conn.write(Frame::Header.new(Frame::Type::Data.value, 0_u8, 1_u32, partial.to_slice).to_bytes)
    conn.flush
    sleep 10.seconds # never closes, never finishes the framed body
    conn.close rescue nil
  end
  port
end

describe Gori::Repeater::H2Engine do
  it "repeaters a GET as real cleartext h2 and reassembles the response" do
    seen = Channel(String).new(1)
    port = start_h2_origin(200, "replayed!", seen)

    request = "GET /api/thing HTTP/2\r\nx-repeater: yes\r\n\r\n".to_slice
    result = Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    receive_within(seen).should eq("GET /api/thing body=") # origin saw the HPACK-encoded request
    result.ok?.should be_true
    result.response.not_nil!.status.should eq(200)
    String.new(result.head).should contain("HTTP/2 200")
    String.new(result.head).should contain("server: gori-test")
    String.new(result.body.not_nil!).should eq("replayed!")
    result.incomplete?.should be_false # END_STREAM was seen — a complete response
  end

  # The Fuzzer marks a position inside a header VALUE. `parse_request` rebuilds the h2 fields
  # from the h1 text by splitting on '\n', so a payload carrying a bare LF split the field and
  # the orphan tail hit a `next unless colon` — `x-fuzz: be\naf` went out as `x-fuzz: be` while
  # the result row was still labelled with the whole payload. The operator then reads a status
  # measured against a request gori never sent. Measured at the wire against an HPACK-decoding
  # origin before the fix. h1 carries these bytes verbatim (P7); h2 has no encoding for them,
  # so refusing is the only answer that does not lie.
  it "refuses a header value carrying a bare LF rather than silently dropping the tail" do
    port = start_quiet_origin

    request = "GET /f HTTP/2\r\nx-fuzz: be\naf\r\n\r\n".to_slice
    result = Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1",
      port: port, verify_upstream: false)

    result.ok?.should be_false
    result.error.not_nil!.should contain("not a header field")
    result.error.not_nil!.should contain("HTTP/2")
  end

  it "refuses a lone CR inside a header value (rstrip only ever removed a trailing one)" do
    port = start_quiet_origin

    request = "GET /f HTTP/2\r\nx-fuzz: x\ry\r\n\r\n".to_slice
    result = Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1",
      port: port, verify_upstream: false)

    result.ok?.should be_false
    result.error.not_nil!.should contain("CR, LF or NUL")
  end

  it "refuses a NUL inside a header value" do
    port = start_quiet_origin

    request = "GET /f HTTP/2\r\nx-fuzz: nul\u0000byte\r\n\r\n".to_slice
    result = Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1",
      port: port, verify_upstream: false)

    result.ok?.should be_false
    result.error.not_nil!.should contain("CR, LF or NUL")
  end

  # The deliberate non-case: a CRLF that yields two WELL-FORMED fields is indistinguishable
  # from the operator typing two headers, and the h1 engine puts two headers on the wire for
  # it too. Refusing that would break the smuggling primitive P7 exists to preserve.
  it "still sends a CRLF that parses as two well-formed header fields" do
    seen = Channel(String).new(1)
    port = start_h2_origin(200, "ok", seen)

    request = "GET /f HTTP/2\r\nx-a: one\r\nx-b: two\r\n\r\n".to_slice
    result = Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1",
      port: port, verify_upstream: false)

    receive_within(seen).should eq("GET /f body=")
    result.ok?.should be_true
  end

  it "keeps a response whose origin hung up MID-FRAME, not just on a frame boundary" do
    # One wire event used to split three ways: boundary EOF -> kept; RST -> kept; mid-frame
    # FIN -> everything destroyed, because `Frame.read` raises Gori::Error there and only
    # IO::Error was rescued. The status and body below plainly arrived, so they must
    # survive — "a response that arrived keeps its head and body regardless".
    port = start_h2_origin_truncated_midframe(200, "partial")

    request = "GET /midframe HTTP/2\r\n\r\n".to_slice
    result = Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    result.error.should be_nil
    result.ok?.should be_true
    result.response.not_nil!.status.should eq(200)
    String.new(result.body.not_nil!).should eq("partial")
    result.incomplete?.should be_true # no END_STREAM ever arrived
  end

  it "flags an h2 response cut short before END_STREAM as incomplete" do
    port = start_h2_origin_truncated(200, "partial")

    request = "GET /trunc HTTP/2\r\n\r\n".to_slice
    result = Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    result.ok?.should be_true # a status + partial body did arrive
    result.response.not_nil!.status.should eq(200)
    String.new(result.body.not_nil!).should eq("partial") # what arrived is captured
    result.incomplete?.should be_true                     # but no END_STREAM — incomplete
  end

  it "sends a request body as DATA frames" do
    seen = Channel(String).new(1)
    port = start_h2_origin(201, "created", seen)

    request = "POST /submit HTTP/2\r\ncontent-type: text/plain\r\n\r\nhello-h2-body".to_slice
    result = Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    receive_within(seen).should eq("POST /submit body=hello-h2-body")
    result.response.not_nil!.status.should eq(201)
    String.new(result.body.not_nil!).should eq("created")
  end

  it "handles interleaved PING frames before the response without stalling" do
    port = start_h2_origin_pings(200, "pong-ok", 20)
    result = Gori::Repeater::H2Engine.send("GET / HTTP/2\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)
    result.ok?.should be_true
    result.response.not_nil!.status.should eq(200)
    String.new(result.body.not_nil!).should eq("pong-ok")
  end

  it "maps an edited Host header to :authority (h1↔h2 parity for host-confusion probes)" do
    seen = Channel(String).new(1)
    port = start_h2_origin_authority(200, seen)

    # Connect to 127.0.0.1 but CLAIM a different authority via the Host header — the
    # h2 engine must send :authority = the edited Host, not the dialed target.
    request = "GET / HTTP/2\r\nHost: victim.internal\r\n\r\n".to_slice
    result = Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    receive_within(seen).should eq("victim.internal")
    result.ok?.should be_true
  end

  it "falls back to the dialed host for :authority when no Host header is present" do
    seen = Channel(String).new(1)
    port = start_h2_origin_authority(200, seen)

    result = Gori::Repeater::H2Engine.send("GET / HTTP/2\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    receive_within(seen).should eq("127.0.0.1:#{port}")
    result.ok?.should be_true
  end

  it "reports an error when the origin is unreachable" do
    result = Gori::Repeater::H2Engine.send("GET / HTTP/2\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: 1, verify_upstream: false)
    result.ok?.should be_false
    result.error.should_not be_nil
  end

  # gori has TWO h2 request encoders. The proxy's intercept-edit path puts these fields on
  # the wire; this one — which every scripted surface uses — dropped them from a `FORBIDDEN`
  # set and reported the resulting 200 as though they had been sent. The h2.TE / h2.CL
  # downgrade desync is DEFINED by putting `transfer-encoding` inside an h2 HEADERS block, so
  # the drop made the single most important h2 test inexpressible everywhere but the TUI's
  # live intercept editor.
  it "puts connection-specific headers on the h2 wire instead of dropping them" do
    seen = Channel({Array({String, String}), Array({String, Int32})}).new(1)
    port = start_h2_origin_recording(seen)

    request = "POST /desync HTTP/2\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n" \
              "Upgrade: h2c\r\nKeep-Alive: timeout=5\r\nProxy-Connection: keep-alive\r\n\r\nx".to_slice
    result = Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1",
      port: port, verify_upstream: false)

    fields, _ = receive_within(seen)
    fields.should contain({"transfer-encoding", "chunked"})
    fields.should contain({"connection", "keep-alive"})
    fields.should contain({"upgrade", "h2c"})
    fields.should contain({"keep-alive", "timeout=5"})
    fields.should contain({"proxy-connection", "keep-alive"})
    result.ok?.should be_true
  end

  # RFC 9113 §8.2.1: a field value may not start or end with whitespace, and a conformant
  # peer must treat one that does as malformed. Whether a given CDN/target actually does is a
  # standard conformance probe — the encoder `strip`ped both sides, so the probe always came
  # back "accepted" having never left. The proxy's encoder kept it (`HeadCodec.header_field`),
  # which is the rule this one now shares.
  it "keeps a trailing space in a header value (the §8.2.1 probe)" do
    seen = Channel({Array({String, String}), Array({String, Int32})}).new(1)
    port = start_h2_origin_recording(seen)

    request = "GET /pad HTTP/2\r\nX-Pad: trailing   \r\n\r\n".to_slice
    Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1",
      port: port, verify_upstream: false)

    fields, _ = receive_within(seen)
    fields.should contain({"x-pad", "trailing   "})
  end

  # The leading OWS after the colon is h1 SYNTAX, not value — `lstrip(' ')` is right, and it
  # is the same cut the proxy encoder makes. Pinned so a later "fix everything verbatim" pass
  # cannot quietly start sending it.
  it "drops only the h1 syntactic space after the colon, not the value's own tail" do
    seen = Channel({Array({String, String}), Array({String, Int32})}).new(1)
    port = start_h2_origin_recording(seen)

    Gori::Repeater::H2Engine.send("GET / HTTP/2\r\nx-lead:    lead\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    fields, _ = receive_within(seen)
    fields.should contain({"x-lead", "lead"})
  end

  it "lowercases field names by default (an h1 paste must stay sendable over h2)" do
    seen = Channel({Array({String, String}), Array({String, Int32})}).new(1)
    port = start_h2_origin_recording(seen)

    Gori::Repeater::H2Engine.send("GET / HTTP/2\r\nX-MiXeD-Case: KeepMe\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    fields, _ = receive_within(seen)
    fields.should contain({"x-mixed-case", "KeepMe"}) # name folded, VALUE untouched
  end

  # What `--verbatim` / MCP `verbatim:true` buys on h2. The flag promised "the stored bytes
  # EXACTLY" and changed nothing this encoder does, so an operator was told the bytes were
  # exact when the names had been folded. An uppercase name is malformed h2 a conformant peer
  # must reject — which is the point of typing one.
  it "preserves field-name case under preserve_field_case" do
    seen = Channel({Array({String, String}), Array({String, Int32})}).new(1)
    port = start_h2_origin_recording(seen)

    Gori::Repeater::H2Engine.send("GET / HTTP/2\r\nX-MiXeD-Case: KeepMe\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
      preserve_field_case: true)

    fields, _ = receive_within(seen)
    fields.should contain({"X-MiXeD-Case", "KeepMe"})
  end

  # A version-less request line is what a parser-differential / HTTP-0.9 probe writes, and
  # what hand-editing the line in the TUI editor produces. The encoder's own copy of the
  # request-line rule cut at the LAST space unconditionally, so `last_sp == first_sp` fell
  # through to `"/"` — gori reported a normal 200 for a URL the operator never asked for.
  # `HeadCodec.request_line` (now shared) strips the trailing token only when it is a version.
  it "keeps the path when the request line carries no HTTP/x version token" do
    seen = Channel(String).new(1)
    port = start_h2_origin(200, "ok", seen)

    result = Gori::Repeater::H2Engine.send("GET /noversion\r\nx-case: a\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    receive_within(seen).should eq("GET /noversion body=")
    result.ok?.should be_true
  end

  # RFC 9113 §4.2 caps EVERY frame at the peer's SETTINGS_MAX_FRAME_SIZE, whose initial value
  # (§6.5.2) is 2^14 and which may never be set lower — so 16384 is safe against every peer
  # and needs no round trip. The old code wrote the whole block as one HEADERS frame because
  # MAX_FRAME had been read as a DATA-only concern; a large cookie jar, a JWT, or a
  # header-size probe therefore produced an illegal frame that strict origins answered with
  # GOAWAY(FRAME_SIZE_ERROR).
  it "splits an over-size header block into HEADERS + CONTINUATION at MAX_FRAME" do
    seen = Channel({Array({String, String}), Array({String, Int32})}).new(1)
    port = start_h2_origin_recording(seen)

    request = "GET /big HTTP/2\r\nx-big: #{"A" * 30_000}\r\n\r\n".to_slice
    result = Gori::Repeater::H2Engine.send(request, scheme: "http", host: "127.0.0.1",
      port: port, verify_upstream: false)

    fields, shape = receive_within(seen)
    shape.size.should be > 1
    shape.first[0].should eq("Headers")
    shape[1..].each { |(type, _)| type.should eq("Continuation") }
    shape.each { |(_, size)| size.should be <= Gori::Repeater::H2Engine::MAX_FRAME }
    fields.should contain({"x-big", "A" * 30_000}) # and it still decodes as one field
    result.ok?.should be_true
  end

  # A GOAWAY is the origin naming the reason it hung up (§6.8), and it is usually about the
  # bytes GORI sent. The code was read only as "stop looping", so the operator got "no h2
  # response" and went looking at the network.
  it "reports a GOAWAY error code and debug data instead of 'no h2 response'" do
    port = start_h2_origin_goaway(6_u32, "frame too large")

    result = Gori::Repeater::H2Engine.send("GET / HTTP/2\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    result.ok?.should be_false
    error = result.error.not_nil!
    error.should contain("GOAWAY")
    error.should contain("FRAME_SIZE_ERROR")
    error.should contain("frame too large")
  end

  # The refusal fires on the `colon == 0` guard, but its message blamed a CR, LF or NUL —
  # bytes the line does not contain — so the operator went hunting for an invisible control
  # character. The refusal itself is correct and stays.
  it "names the pseudo-header, not a phantom CR/LF/NUL, when refusing `:scheme: http`" do
    port = start_quiet_origin

    result = Gori::Repeater::H2Engine.send("GET /p HTTP/2\r\n:scheme: http\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    result.ok?.should be_false
    error = result.error.not_nil!
    error.should contain("pseudo-header")
    error.should_not contain("CR, LF or NUL")
  end

  describe ".encoded_request" do
    # Every "the request actually put on the wire" report was derived from the operator's
    # TEXT, which on the h2 path is only an input: the encoder resolves `:path` from the
    # request line, folds `Host:` into `:authority` and lowercases names. MCP therefore
    # answered `target: "/mcp-noversion"` with `Transfer-Encoding` in the recorded head while
    # `GET /` had gone out, and `run show --format raw` printed those same bytes back.
    it "projects the ENCODED fields, not the source text" do
      source = "GET /noversion\r\nHost: claimed.example\r\nX-MiXeD: Keep\r\n" \
               "Transfer-Encoding: chunked\r\n\r\n".to_slice
      wire = String.new(Gori::Repeater::H2Engine.encoded_request(source,
        scheme: "https", host: "127.0.0.1", port: 8443))

      wire.should start_with("GET /noversion HTTP/2\r\n")
      wire.should contain("Host: claimed.example\r\n") # the :authority actually encoded
      wire.should contain("x-mixed: Keep\r\n")         # folded, as the wire has it
      wire.should contain("transfer-encoding: chunked\r\n")
    end

    it "carries the body through unchanged" do
      wire = String.new(Gori::Repeater::H2Engine.encoded_request(
        "POST /p HTTP/2\r\ncontent-length: 5\r\n\r\nhello".to_slice,
        scheme: "http", host: "h", port: 80))
      wire.should end_with("\r\n\r\nhello")
    end

    it "reports the preserved case when the send will preserve it" do
      wire = String.new(Gori::Repeater::H2Engine.encoded_request(
        "GET / HTTP/2\r\nX-MiXeD: Keep\r\n\r\n".to_slice,
        scheme: "http", host: "h", port: 80, preserve_field_case: true))
      wire.should contain("X-MiXeD: Keep\r\n")
    end

    # PR 7. `encoded_request` is the projection MCP's `effective_request` and `run show
    # --format raw` report the wire through, and it shares `parse_request` with `send` — so
    # the reframe has to show up here or a surface would report bytes the send did not put on
    # the wire, which is the exact defect this projection was added to close.
    it "reports the reframed gRPC body when the send will reframe it" do
      # prefix declares 5, payload is 8 — a hex edit that changed the message length.
      source = "POST /p.S/M HTTP/2\r\ncontent-type: application/grpc\r\n\r\n".to_slice
      body = Bytes[0, 0, 0, 0, 5, 65, 65, 65, 65, 65, 65, 65, 65]
      request = Bytes.new(source.size + body.size)
      source.copy_to(request)
      body.copy_to(request[source.size, body.size])

      off = Gori::Repeater::H2Engine.encoded_request(request, scheme: "http", host: "h", port: 80)
      on = Gori::Repeater::H2Engine.encoded_request(request, scheme: "http", host: "h", port: 80,
        reframe_grpc: true)
      off[off.size - body.size, body.size].hexstring.should eq("00000000054141414141414141")
      on[on.size - body.size, body.size].hexstring.should eq("00000000084141414141414141")
      on.size.should eq(off.size) # size-preserving, so a Content-Length stays right
    end

    it "leaves a non-gRPC body alone even with reframe_grpc on" do
      wire = String.new(Gori::Repeater::H2Engine.encoded_request(
        "POST /p HTTP/2\r\ncontent-type: application/json\r\ncontent-length: 5\r\n\r\nhello".to_slice,
        scheme: "http", host: "h", port: 80, reframe_grpc: true))
      wire.should end_with("\r\n\r\nhello")
    end
  end

  it "credits flow-control windows so a response past the default window completes" do
    body = Bytes.new(100_000) { |i| (65 + i % 26).to_u8 } # 100 KB > the 65535 window
    port = start_h2_origin_flow_controlled(200, body)

    result = Gori::Repeater::H2Engine.send("GET / HTTP/2\r\nhost: 127.0.0.1\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    result.ok?.should be_true # would time out (incomplete) without WINDOW_UPDATE
    result.response.not_nil!.status.should eq(200)
    result.body.not_nil!.size.should eq(100_000)
  end

  describe ".send_fields" do
    # The whole reason the field-native path exists: an HTTP/1.1 head cannot carry a duplicate
    # pseudo-header, a pseudo AFTER a regular field, a `:scheme` that disagrees with the
    # connection, an unknown pseudo, or a leading-space value — `HeadCodec.h1_faithful?` is
    # exactly that loss set — so `send`/`parse_request` could express NONE of them. Here the
    # fields ARE the message: the origin must see them byte-for-byte, in order, unnormalized.
    it "puts the EXACT field list on the wire, in order, with the shapes h1 text cannot hold" do
      seen = Channel({Array({String, String}), Array({String, Int32})}).new(1)
      port = start_h2_origin_recording(seen)

      fields = [
        {":method", "GET"}, {":method", "POST"}, # duplicate pseudo (parser-differential)
        {"x-early", "1"},                        # a regular field BEFORE the rest of the pseudos
        {":path", "/fn"}, {":scheme", "http"},   # :scheme disagrees with the (cleartext, but "http") conn
        {":authority", "spoofed.example"},       # authority the operator chose, not the dial host
        {":foo", "bar"},                         # unknown pseudo
        {"X-Upper", "  lead"},                   # uppercase name + leading-space value
      ]
      result = Gori::Repeater::H2Engine.send_fields(fields, nil,
        scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

      got, _ = receive_within(seen)
      got.should eq(fields) # nothing dropped, reordered, deduped, folded or stripped
      result.ok?.should be_true
    end

    it "sends a field-native body as a DATA frame with END_STREAM" do
      seen = Channel(String).new(1)
      port = start_h2_origin(201, "created", seen)

      fields = [{":method", "POST"}, {":path", "/upload"}, {":scheme", "https"}, {":authority", "h"}]
      result = Gori::Repeater::H2Engine.send_fields(fields, "payload".to_slice,
        scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

      receive_within(seen).should eq("POST /upload body=payload")
      result.response.not_nil!.status.should eq(201)
    end

    # The default frame sequence (and MAX_FRAME chunking) is UNCHANGED — this widens what the
    # HEADERS block carries, not how it is framed. A 30 KB pseudo value still splits.
    it "still splits an over-size field block into HEADERS + CONTINUATION at MAX_FRAME" do
      seen = Channel({Array({String, String}), Array({String, Int32})}).new(1)
      port = start_h2_origin_recording(seen)

      fields = [{":method", "GET"}, {":path", "/big"}, {":scheme", "https"}, {":authority", "h"},
                {"x-big", "A" * 30_000}]
      Gori::Repeater::H2Engine.send_fields(fields, nil,
        scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

      got, shape = receive_within(seen)
      shape.size.should be > 1
      shape.first[0].should eq("Headers")
      shape[1..].each { |(type, _)| type.should eq("Continuation") }
      shape.each { |(_, size)| size.should be <= Gori::Repeater::H2Engine::MAX_FRAME }
      got.should contain({"x-big", "A" * 30_000})
    end
  end

  describe ".field_dump" do
    # "Report before capability": `synth_request`'s h1 projection drops `:scheme` and collapses
    # a duplicate pseudo (F11), so a field-native shape would land INVISIBLE in `run show` /
    # MCP `effective_request` (the F5 failure). The dump is the faithful view — every field, in
    # order, pseudo-headers included — the same raw-frames-are-truth split `Assembler` draws.
    it "renders every field in order, pseudo-headers and duplicates included" do
      fields = [{":method", "GET"}, {":method", "POST"}, {":path", "/x"},
                {":scheme", "http"}, {":authority", "h"}, {"x-foo", "bar"}]
      dump = String.new(Gori::Repeater::H2Engine.field_dump(fields, nil))
      dump.should eq(":method: GET\r\n:method: POST\r\n:path: /x\r\n:scheme: http\r\n" \
                     ":authority: h\r\nx-foo: bar\r\n\r\n")
    end

    it "appends the body after the blank line" do
      fields = [{":method", "POST"}, {":path", "/p"}, {":scheme", "https"}, {":authority", "h"}]
      dump = String.new(Gori::Repeater::H2Engine.field_dump(fields, "hello".to_slice))
      dump.should end_with("\r\n\r\nhello")
    end
  end

  # F2. The send direction had no flow-control accounting at all: `write_data` blasted the
  # whole body in MAX_FRAME chunks, so every conformant origin answered GOAWAY
  # FLOW_CONTROL_ERROR — and the report named the ORIGIN for gori's own violation. Upload
  # fuzzing, large JSON/protobuf bodies and body-size probes were unsendable over h2 from
  # EVERY surface (repeater, run repeater, MCP send_request, fuzz, mine, discover).
  describe "request-direction flow control" do
    it "sends a body larger than the peer's window, blocking for WINDOW_UPDATE" do
      seen = Channel(Int32).new(1)
      port = start_h2_origin_window(65_535, grant: true, seen: seen)
      body = ("A" * 200_000).to_slice
      result = Gori::Repeater::H2Engine.send_fields(
        [{":method", "POST"}, {":path", "/big"}, {":scheme", "http"}, {":authority", "h"},
         {"content-length", body.size.to_s}], body,
        scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
        timeout: 5.seconds)

      receive_within(seen).should eq(200_000) # -1 would mean gori overran the window
      result.error.should be_nil
      result.response.try(&.status).should eq(200)
    end

    it "honours a peer SETTINGS_INITIAL_WINDOW_SIZE below the 65535 default" do
      seen = Channel(Int32).new(1)
      # 20 000 bytes against a 16384 window: the whole body fits under the DEFAULT window,
      # so only reading the peer's SETTINGS before the first DATA frame can catch this.
      port = start_h2_origin_window(16_384, grant: true, seen: seen)
      body = ("B" * 20_000).to_slice
      result = Gori::Repeater::H2Engine.send_fields(
        [{":method", "POST"}, {":path", "/k20"}, {":scheme", "http"}, {":authority", "h"}], body,
        scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
        timeout: 5.seconds)

      receive_within(seen).should eq(20_000)
      result.error.should be_nil
    end

    it "names the flow-control stall instead of blaming the origin, and says the body did not go out" do
      seen = Channel(Int32).new(1)
      port = start_h2_origin_window(65_535, grant: false, seen: seen)
      body = ("C" * 200_000).to_slice
      result = Gori::Repeater::H2Engine.send_fields(
        [{":method", "POST"}, {":path", "/stall"}, {":scheme", "http"}, {":authority", "h"}], body,
        scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
        timeout: 500.milliseconds)

      receive_within(seen).should eq(65_535) # exactly the window, not a byte more
      error = result.error.should_not be_nil
      error.should contain("h2 flow control")
      error.should contain("only 65535 of 200000 request body bytes")
      error.should contain("never granted flow-control window")
      error.should contain("NOT fully sent")
    end

    # R1-F1. An origin that answers WHILE the body is still going out — the 413 every upload /
    # body-size probe is looking for — was never detected. The early-stop test was
    # `end_stream? && end_headers?`, but END_HEADERS is a HEADERS/CONTINUATION flag (on a DATA
    # frame that bit means PADDED), so it could only fire for a response with NO body. With a
    # body gori waited out the whole io_timeout and then RAISED from `write_data`, and the
    # raise unwound before `read_response` ran — destroying the complete 413 that had been
    # sitting in `flow.pending` the entire time.
    #
    # Both shapes are asserted here on purpose: the bodiless one is what round 2's fixer
    # tested, and it is the ONLY one the old condition could satisfy.
    describe "an origin that answers before the request body finishes (RFC 9113 §8.1)" do
      it "reports the response WITH a body, and says the request body was cut short" do
        seen = Channel(Int32).new(1)
        port = start_h2_origin_early_response(4096, after: 4096, status: 413,
          with_body: true, seen: seen)
        body = ("A" * 20_000).to_slice
        started = Time.instant
        result = Gori::Repeater::H2Engine.send_fields(
          [{":method", "POST"}, {":path", "/big"}, {":scheme", "http"}, {":authority", "h"},
           {"content-length", body.size.to_s}], body,
          scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
          timeout: 3.seconds)

        receive_within(seen).should eq(4096)
        # The response ARRIVED — it must survive the writer's disposition.
        result.response.try(&.status).should eq(413)
        String.new(result.head).should contain("413")
        String.new(result.body || Bytes.empty).should eq("request too large")
        # …and the send must not be reported as clean.
        error = result.error.should_not be_nil
        error.should contain("truncated at 4096 of 20000 bytes")
        error.should contain("NOT fully sent")
        # It must not spend the io_timeout: the answer was already on the socket.
        (Time.instant - started).should be < 3.seconds
      end

      it "reports the same truncation for a BODILESS response, which used to come back clean" do
        seen = Channel(Int32).new(1)
        port = start_h2_origin_early_response(4096, after: 4096, status: 413,
          with_body: false, seen: seen)
        body = ("B" * 20_000).to_slice
        result = Gori::Repeater::H2Engine.send_fields(
          [{":method", "POST"}, {":path", "/big"}, {":scheme", "http"}, {":authority", "h"},
           {"content-length", body.size.to_s}], body,
          scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
          timeout: 3.seconds)

        receive_within(seen).should eq(4096)
        result.response.try(&.status).should eq(413)
        error = result.error.should_not be_nil # was `ok:true, error:null`
        error.should contain("truncated at 4096 of 20000 bytes")
      end

      it "leaves a body that DID go out whole reporting clean" do
        # The complement of the two above: same origin, a body that fits the window. Nothing
        # was truncated, so nothing may be said about truncation.
        seen = Channel(Int32).new(1)
        port = start_h2_origin_early_response(65_535, after: 500, status: 200,
          with_body: true, seen: seen)
        body = ("C" * 500).to_slice
        result = Gori::Repeater::H2Engine.send_fields(
          [{":method", "POST"}, {":path", "/small"}, {":scheme", "http"}, {":authority", "h"},
           {"content-length", body.size.to_s}], body,
          scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
          timeout: 3.seconds)

        receive_within(seen).should eq(500)
        result.response.try(&.status).should eq(200)
        result.error.should be_nil
      end

      it "keeps writing the body through an interim 1xx on the same stream" do
        # The complement that constrains the fix's SHAPE. "A header block arrived on stream 1"
        # is NOT the end-of-write condition, because a 100 Continue is one — and an
        # `Expect: 100-continue` origin sends it precisely to ask for the body. END_STREAM is,
        # and it excludes the interim for free: a 1xx cannot end the stream.
        seen = Channel(Int32).new(1)
        port = start_h2_origin_interim(4096, 20_000, seen)
        body = ("I" * 20_000).to_slice
        result = Gori::Repeater::H2Engine.send_fields(
          [{":method", "POST"}, {":path", "/expect"}, {":scheme", "http"}, {":authority", "h"},
           {"expect", "100-continue"}, {"content-length", body.size.to_s}], body,
          scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
          timeout: 3.seconds)

        receive_within(seen).should eq(20_000)       # the whole body, not 4096
        result.response.try(&.status).should eq(200) # the FINAL status, not the 100
        result.error.should be_nil                   # nothing was truncated
      end
    end

    # R1-F2. `await_settings` read exactly ONE frame. `pump_once` ACKs a PING, credits a
    # WINDOW_UPDATE and falls straight through a SETTINGS **ACK** without setting
    # `settings_seen`, so an origin whose opening frame is any of those got the whole body
    # written against the RFC default 65535-byte window — and the GOAWAY(FLOW_CONTROL_ERROR)
    # it drew was reported as the ORIGIN misbehaving, the exact misattribution the send-side
    # flow control was added to remove.
    describe "an origin whose first frame is not SETTINGS" do
      {:ping, :window_update}.each do |first|
        it "waits for the real SETTINGS when the opener is a #{first}" do
          seen = Channel(Int32).new(1)
          port = start_h2_origin_late_settings(4096, first, 300.milliseconds, seen)
          body = ("D" * 20_000).to_slice
          result = Gori::Repeater::H2Engine.send_fields(
            [{":method", "POST"}, {":path", "/late"}, {":scheme", "http"}, {":authority", "h"},
             {"content-length", body.size.to_s}], body,
            scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
            timeout: 2.seconds)

          receive_within(seen).should eq(4096) # -1 = gori overran the window it was told about
          # No window was ever granted, so this stalls — but on gori's OWN accounting, with
          # no GOAWAY drawn and the origin never blamed.
          error = result.error.should_not be_nil
          error.should contain("h2 flow control")
          error.should contain("only 4096 of 20000 request body bytes")
          error.should_not contain("GOAWAY")
          # …and it is "never granted" for BOTH openers. A `WINDOW_UPDATE`-first origin has
          # credited a byte before the body starts, which is not a grant FOR the body: the
          # stall accounting counts only what arrived while DATA was going out, or this
          # would read "the origin stopped granting" for one that never started.
          error.should contain("never granted flow-control window")
        end
      end

      it "names gori's own overrun when it did proceed on the RFC defaults" do
        # The complement: an origin that sends a non-SETTINGS opener and then NO SETTINGS at
        # all within the budget. gori legitimately falls back to the §6.9.2 default — and the
        # GOAWAY that follows must be attributed to gori, not handed over as the origin's fault.
        seen = Channel(Int32).new(1)
        port = start_h2_origin_late_settings(4096, :ping, 30.seconds, seen)
        body = ("E" * 20_000).to_slice
        result = Gori::Repeater::H2Engine.send_fields(
          [{":method", "POST"}, {":path", "/never"}, {":scheme", "http"}, {":authority", "h"},
           {"content-length", body.size.to_s}], body,
          scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
          timeout: 2.seconds)

        receive_within(seen).should eq(-1) # gori overran, as the RFC default entitles it to
        error = result.error.should_not be_nil
        error.should contain("FLOW_CONTROL_ERROR")
        error.should contain("gori's own accounting")
        error.should contain("the origin's SETTINGS had not arrived")
      end
    end

    # R1-F3. The stall's only exits were `flow.available > 0`, `flow.closed?` and a
    # `pump_once` that returned false — which happens on an IDLE read, an EOF, or
    # MAX_FRAMES. Any frame at all resets the idle timer, so a keepalive PING under the
    # timeout left MAX_FRAMES (a COUNT) as the only ceiling: ~55 hours at 2 s, ~17 days at a
    # 15 s gRPC keepalive. `WsEngine::DRAIN_DEADLINE` is the wall clock this loop was missing.
    describe "a stall kept alive by frames that grant no window" do
      it "gives up on the wall clock when the origin sends keepalive PINGs" do
        seen = Channel(Int32).new(1)
        port = start_h2_origin_busy_stall(1024, :ping, 150.milliseconds, seen)
        body = ("F" * 20_000).to_slice
        started = Time.instant
        result = Gori::Repeater::H2Engine.send_fields(
          [{":method", "POST"}, {":path", "/ping"}, {":scheme", "http"}, {":authority", "h"},
           {"content-length", body.size.to_s}], body,
          scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
          timeout: 1.second)
        elapsed = Time.instant - started

        receive_within(seen).should eq(1024)
        elapsed.should be < 10.seconds # unbounded before: the PINGs reset the idle timer
        error = result.error.should_not be_nil
        error.should contain("only 1024 of 20000 request body bytes")
        error.should contain("never granted flow-control window")
      end

      it "names the §6.9.1 violation when the filler is WINDOW_UPDATE +0" do
        seen = Channel(Int32).new(1)
        port = start_h2_origin_busy_stall(1024, :window_update, 50.milliseconds, seen)
        body = ("G" * 20_000).to_slice
        result = Gori::Repeater::H2Engine.send_fields(
          [{":method", "POST"}, {":path", "/wuzero"}, {":scheme", "http"}, {":authority", "h"},
           {"content-length", body.size.to_s}], body,
          scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
          timeout: 1.second)

        receive_within(seen).should eq(1024)
        error = result.error.should_not be_nil
        error.should contain("WINDOW_UPDATE with a 0 increment")
        error.should contain("§6.9.1")
      end

      it "still fails in ONE idle timeout when the origin sends nothing at all" do
        # The complement of both: total silence. The deadline must not double the wall clock
        # for the commonest failure — an origin that simply never grants window.
        seen = Channel(Int32).new(1)
        port = start_h2_origin_window(65_535, grant: false, seen: seen)
        body = ("H" * 200_000).to_slice
        started = Time.instant
        result = Gori::Repeater::H2Engine.send_fields(
          [{":method", "POST"}, {":path", "/silent"}, {":scheme", "http"}, {":authority", "h"}], body,
          scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
          timeout: 700.milliseconds)
        elapsed = Time.instant - started

        receive_within(seen).should eq(65_535)
        result.error.should_not be_nil
        # One patience budget, not two: the write stall must not be followed by a full
        # response-read timeout on a socket that produced no frames.
        elapsed.should be < 1600.milliseconds
      end
    end

    # R4-F2. The per-stall deadline above restarts on every DATA frame written — deliberately,
    # so an origin that legitimately drips window is never cut short. That left the send with
    # NO upper bound at all: an origin granting one byte of window per second held an MCP
    # `send_request{timeout_ms: 2000}` at 69 of 20 000 bytes after 70 s, i.e. ~5.5 hours for a
    # call whose stated budget was 2 s, and MAX_FRAMES is a COUNT that a drip costs 2 frames
    # per byte to reach. The caller's `timeout` is a ceiling to everyone who passes one, so it
    # is now also a ceiling for the whole exchange.
    describe "an origin that drips flow-control window" do
      it "stops at the caller's whole-exchange budget and names the clock that ran out" do
        seen = Channel(Int32).new(1)
        # 1 byte every 25 ms for 5 s — progress forever, and never enough.
        port = start_h2_origin_drip(1, 25.milliseconds, 200, 200, seen)
        body = ("D" * 200).to_slice
        started = Time.instant
        result = Gori::Repeater::H2Engine.send_fields(
          [{":method", "POST"}, {":path", "/drip"}, {":scheme", "http"}, {":authority", "h"},
           {"content-length", body.size.to_s}], body,
          scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
          timeout: 700.milliseconds)
        elapsed = Time.instant - started

        got = receive_within(seen)
        got.should be > 0   # it DID make progress — that is the whole difficulty
        got.should be < 200 # …and it never finished
        elapsed.should be < 2.seconds
        error = result.error.should_not be_nil
        error.should contain("h2 flow control")
        error.should contain("of 200 request body bytes")
        error.should contain("0.7s budget for the whole exchange")
        error.should contain("NOT fully sent")
        # The origin granted window the whole time and never closed anything: neither of the
        # other two sentences may be reached for it.
        error.should_not contain("never granted")
        error.should_not contain("closed the connection")
      end

      it "does NOT cut short a dripping origin that finishes inside the budget" do
        # The complement that constrains the fix's shape: the budget is a ceiling on the
        # exchange, not an excuse to stop writing at a slow origin. 40 bytes every 20 ms
        # finishes a 200-byte body in ~100 ms, well inside a 2 s budget.
        seen = Channel(Int32).new(1)
        port = start_h2_origin_drip(40, 20.milliseconds, 40, 200, seen)
        body = ("E" * 200).to_slice
        result = Gori::Repeater::H2Engine.send_fields(
          [{":method", "POST"}, {":path", "/slow"}, {":scheme", "http"}, {":authority", "h"},
           {"content-length", body.size.to_s}], body,
          scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
          timeout: 2.seconds)

        receive_within(seen).should eq(200)
        result.error.should be_nil
        result.response.try(&.status).should eq(200)
      end
    end
  end

  # F3. Seven distinct causes collapsed into one "no h2 response from HOST" sentence. A
  # WAF / rate-limiter test is MADE of telling these apart, and REFUSED_STREAM is an explicit
  # retry-on-a-new-connection instruction (RFC 9113 §8.7), not a flat refusal.
  describe "RST_STREAM and silence reporting" do
    it "names the RST_STREAM error code" do
      {7_u32 => "REFUSED_STREAM", 11_u32 => "ENHANCE_YOUR_CALM", 8_u32 => "CANCEL"}.each do |code, name|
        port = start_h2_origin_rst(code)
        result = Gori::Repeater::H2Engine.send(
          "GET /x HTTP/2\r\nHost: h\r\n\r\n".to_slice,
          scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false, timeout: 5.seconds)
        error = result.error.should_not be_nil
        error.should contain("h2 RST_STREAM #{name} on stream 1")
        error.should contain("127.0.0.1:#{port}")
      end
    end

    it "keeps the RST_STREAM reason on a result that already carries a partial response" do
      port = start_h2_origin_rst(8_u32, after_headers: true)
      result = Gori::Repeater::H2Engine.send(
        "GET /x HTTP/2\r\nHost: h\r\n\r\n".to_slice,
        scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false, timeout: 5.seconds)

      result.response.try(&.status).should eq(200) # the head and body survive
      String.new(result.body.not_nil!).should eq("partial")
      result.incomplete?.should be_true
      # ...and the cause is not lost to "origin closed before the framed body finished",
      # which names an event that never happened.
      result.error.should_not be_nil
      result.error.not_nil!.should contain("h2 RST_STREAM CANCEL on stream 1")
    end

    it "tells an idle read timeout apart from a connection that closed" do
      mute = Gori::Repeater::H2Engine.send(
        "GET /x HTTP/2\r\nHost: h\r\n\r\n".to_slice,
        scheme: "http", host: "127.0.0.1", port: start_h2_origin_mute,
        verify_upstream: false, timeout: 500.milliseconds)
      mute.error.not_nil!.should contain("the origin sent nothing before the read timed out")

      hangup = Gori::Repeater::H2Engine.send(
        "GET /x HTTP/2\r\nHost: h\r\n\r\n".to_slice,
        scheme: "http", host: "127.0.0.1", port: start_h2_origin_hangup,
        verify_upstream: false, timeout: 5.seconds)
      hangup.error.not_nil!.should contain("the connection closed before a response frame arrived")
    end
  end

  # R4-F3. An origin that answered `HEADERS(:status 100)` and then went silent — socket held
  # OPEN — came back `ok:true, status:100, error:null` after a full idle timeout, with
  # `incomplete_reason: "origin closed before the framed body finished"` for a connection it
  # never closed. Two causes: the failure guard tested `status == 0 && headers.empty?`, and an
  # interim block sets a status and then clears its headers (RFC 9110 §15.2 — a 1xx precedes
  # the final response and is not one); and `timed_out`, which the read computes, reached only
  # `no_response`, i.e. only when nothing at all had arrived.
  describe "an interim 1xx that is never followed by a final response" do
    {100, 103}.each do |code|
      it "reports no response — not a #{code} — when the origin then goes silent" do
        started = Time.instant
        result = Gori::Repeater::H2Engine.send(
          "GET /x HTTP/2\r\nHost: h\r\n\r\n".to_slice,
          scheme: "http", host: "127.0.0.1",
          port: start_h2_origin_interim_then(code, nil),
          verify_upstream: false, timeout: 600.milliseconds)
        elapsed = Time.instant - started

        result.ok?.should be_false
        result.response.should be_nil
        result.head.size.should eq(0) # never render "HTTP/2 100" as the answer
        error = result.error.should_not be_nil
        error.should contain("no h2 response")
        error.should contain("interim #{code}")
        error.should contain("nothing more before the read timed out")
        error.should contain("RFC 9110 §15.2")
        # The origin held the socket open for the whole exchange.
        error.should_not contain("closed the connection")
        # The idle timeout is carried, so a renderer stops attributing this to a close…
        result.timed_out?.should be_true
        # …and the request IS with the origin (gori writes it up front), so re-sending a
        # non-idempotent one would double its side effect.
        result.delivered?.should be_true
        elapsed.should be < 3.seconds
      end
    end

    it "still succeeds when the final response merely arrives LATE" do
      # (see below for the AFTER-the-final-response case — the mirror of this one)
      # The complement: an interim is not a failure, it is a PRELUDE. The fix must key on
      # "did a final response arrive", never on "was an interim seen".
      result = Gori::Repeater::H2Engine.send(
        "GET /x HTTP/2\r\nHost: h\r\n\r\n".to_slice,
        scheme: "http", host: "127.0.0.1",
        port: start_h2_origin_interim_then(100, 400.milliseconds),
        verify_upstream: false, timeout: 3.seconds)

      result.error.should be_nil
      result.response.try(&.status).should eq(200)
      String.new(result.body || Bytes.empty).should eq("late")
      String.new(result.head).should_not contain("100")
      result.timed_out?.should be_false
    end
  end

  # R5-F3. The mirror of the block above, and the case its rework walked straight past. A 1xx
  # header block arriving AFTER the final response used to overwrite the status, append its
  # fields, file them as trailers, and then `headers.clear` everything the FINAL block had
  # contributed — the guard was `interim?(status)` with no `!final_seen` term. A
  # `200 + content-type + content-length + x-final` followed by `103 link:` and the body was
  # reported, and STORED, as a clean `status: 103` with NO headers and no error. That is the
  # output of an h2 response-splitting probe reported as a benign informational response.
  describe "an interim 1xx that arrives AFTER the final response (RFC 9110 §15.2 violation)" do
    it "keeps the final response's status, headers and body, and names the late 1xx" do
      result = Gori::Repeater::H2Engine.send(
        "GET /x HTTP/2\r\nHost: h\r\n\r\n".to_slice,
        scheme: "http", host: "127.0.0.1",
        port: start_h2_origin_late_block(:interim),
        verify_upstream: false, timeout: 3.seconds)

      # The real answer survives, intact.
      result.response.try(&.status).should eq(200)
      head = String.new(result.head)
      head.should contain("HTTP/2 200")
      head.should contain("content-type: text/plain")
      head.should contain("x-final: yes")
      head.should contain("content-length: 8")
      String.new(result.body || Bytes.empty).should eq("REALBODY")
      # The interloper reaches NEITHER the head nor the trailers marker.
      head.should_not contain("103")
      head.should_not contain("late.css")
      head.should_not contain("X-Gori-Trailers")
      # …and it is not swallowed either: gori exists to reveal exactly this.
      error = result.error.should_not be_nil
      error.should contain("interim 103")
      error.should contain("AFTER its final response")
      error.should contain("RFC 9110 §15.2")
      # A response DID arrive, so this is a clause on it, not a failed send.
      result.delivered?.should be_true
      result.incomplete?.should be_false
    end

    it "does the same when END_STREAM rides on the late 1xx itself" do
      # This variant failed DIFFERENTLY before the fix — `headers.clear` was gated on
      # `!end_stream_pending`, so the 1xx's `link` was MERGED into the final head instead of
      # replacing it, and the status was still 103. Both shapes have to end up right.
      result = Gori::Repeater::H2Engine.send(
        "GET /x HTTP/2\r\nHost: h\r\n\r\n".to_slice,
        scheme: "http", host: "127.0.0.1",
        port: start_h2_origin_late_block(:interim, end_stream_on_late: true),
        verify_upstream: false, timeout: 3.seconds)

      result.response.try(&.status).should eq(200)
      head = String.new(result.head)
      head.should contain("HTTP/2 200")
      head.should contain("x-final: yes")
      head.should_not contain("late.css")
      head.should_not contain("X-Gori-Trailers")
      result.error.should_not be_nil
      result.error.not_nil!.should contain("interim 103")
    end

    it "drops only what EACH late block added, however many arrive" do
      result = Gori::Repeater::H2Engine.send(
        "GET /x HTTP/2\r\nHost: h\r\n\r\n".to_slice,
        scheme: "http", host: "127.0.0.1",
        port: start_h2_origin_late_block(:interim_x2),
        verify_upstream: false, timeout: 3.seconds)

      result.response.try(&.status).should eq(200)
      head = String.new(result.head)
      head.should contain("x-final: yes")
      head.should contain("content-length: 8")
      head.should_not contain("a.css")
      head.should_not contain("b.css")
      String.new(result.body || Bytes.empty).should eq("REALBODY")
    end

    it "still files a REAL trailing block as trailers" do
      # The complement of the condition the fix keys on. `note_trailers` must keep firing for
      # a block after the final response that is NOT an interim — a gRPC trailers response, and
      # whether a gateway promotes a trailer into a header, is a first-class test.
      result = Gori::Repeater::H2Engine.send(
        "GET /x HTTP/2\r\nHost: h\r\n\r\n".to_slice,
        scheme: "http", host: "127.0.0.1",
        port: start_h2_origin_late_block(:trailers),
        verify_upstream: false, timeout: 3.seconds)

      result.response.try(&.status).should eq(200)
      head = String.new(result.head)
      head.should contain("HTTP/2 200")
      head.should contain("x-checksum: deadbeef")
      head.should contain("X-Gori-Trailers: x-checksum")
      String.new(result.body || Bytes.empty).should eq("REALBODY")
      result.error.should be_nil # a trailers block is not a violation
    end
  end

  # R5 / H3-F1. Four dial failures with four different fixes arrived as ONE sentence — "host
  # unreachable, the origin doesn't offer HTTP/2 via ALPN, or its TLS certificate failed
  # verification" — while the SAME operator one `^V` away got the h1 engine's named refusals for
  # three of them. Two causes: `H2Engine.connect_error` took no `DialError` and built its string
  # from `scheme`/`verify` alone, and `open` called the nil-returning `Upstream.dial_tls`, which
  # discards `DialErrorKind` before any caller can ask.
  describe "why an h2 dial produced no connection" do
    # The three transport failures are h1's to word — a refused TCP connect and a rejected
    # certificate fail identically whatever runs on top — so the invariant asserted here is
    # PARITY, not any particular phrase. `Repeater::Engine.connect_error` is where the wording
    # (and `DialErrorKind`'s split, and its remedies) is decided and re-decided; keying these
    # examples on literals would mean an h1-side improvement lands as an h2-side spec failure,
    # which is how the two drifted apart in the first place.
    {
      # Both origins hold every connection open for far longer than these timeouts, on purpose:
      # each example below dials TWICE (once per engine), and a one-shot or short-lived listener
      # made the second dial fail differently from the first — which read as the two engines
      # disagreeing when it was the harness running out.
      {"a TCP connect that never came up", -> { s = TCPServer.new("127.0.0.1", 0); p = s.local_address.port; s.close; p }, false},
      {"a certificate the client does not trust", -> { start_tls_origin(advertise_h2: true) }, true},
      {"a plaintext port addressed as https", -> { start_quiet_origin }, false},
    }.each do |(label, open_port, verify)|
      it "says exactly what the h1 engine says about #{label}" do
        # A FRESH origin per engine. Sharing one made each engine's dial a different connection
        # to the same listener, and the second connection is not the case under test: it saw a
        # listener mid-teardown and reported a reset rather than the verdict the first got. Each
        # engine now gets a first connection, which is what the example is actually about.
        args = {"GET /x HTTP/2\r\nHost: h\r\n\r\n".to_slice}
        h2 = Gori::Repeater::H2Engine.send(*args, scheme: "https", host: "127.0.0.1",
          port: open_port.call, verify_upstream: verify, timeout: 3.seconds)
        h1 = Gori::Repeater::Engine.send(*args, scheme: "https", host: "127.0.0.1",
          port: open_port.call, verify_upstream: verify, timeout: 3.seconds)

        # Compared WITHOUT the trailing `(cause)` and without the port. The cause is the TLS
        # library's own words about the syscall that observed the failure, and two connections
        # legitimately differ there ("Unexpected EOF while reading" vs "Connection reset by
        # peer") for one verdict. What must match is the verdict, the layer and the remedy —
        # which is the whole of what the h2 engine used to collapse.
        verdict = ->(s : String?) { s.to_s.sub(/ \([^)]*\)\z/, "").sub(/:\d+ /, " ") }
        error = h2.error.should_not be_nil
        verdict.call(error).should eq(verdict.call(h1.error))
        # …and none of the three carries the collapsed sentence's guesses.
        error.should_not contain("no h2 negotiated")
        error.should_not contain("doesn't offer HTTP/2")
      end
    end

    it "names an origin whose ALPN is http/1.1 — the one case gori OBSERVED" do
      # The handshake COMPLETED and the origin named its protocol, so this is the only one of
      # the four that needs no hedging. It was buried third in a list of three guesses.
      port = start_tls_origin(advertise_h2: false)

      result = Gori::Repeater::H2Engine.send(
        "GET /x HTTP/2\r\nHost: h\r\n\r\n".to_slice,
        scheme: "https", host: "127.0.0.1", port: port,
        verify_upstream: false, timeout: 3.seconds)

      error = result.error.should_not be_nil
      error.should contain("h2 not negotiated")
      error.should contain("completed the TLS handshake")
      # gori offers `h2` alone, so an http/1.1-only origin has nothing to select and the
      # negotiated protocol is EMPTY. Naming that is the point — the old sentence's "the
      # origin doesn't offer HTTP/2 via ALPN" was one guess of three, applied to all four.
      error.should contain("did not accept `h2` over ALPN")
      error.should contain("HTTP/1.1 instead")
      # Not blamed on reachability or on the certificate — both are demonstrably fine.
      error.should_not contain("host unreachable")
      error.should_not contain("certificate")
      # This one is h2's ALONE: the h1 engine reaches the same origin without complaint, which
      # is precisely the advice the sentence gives. It is also why it cannot be delegated.
      h1 = Gori::Repeater::Engine.send(
        "GET /x HTTP/1.1\r\nHost: h\r\n\r\n".to_slice,
        scheme: "https", host: "127.0.0.1", port: port,
        verify_upstream: false, timeout: 3.seconds)
      h1.error.should_not eq(error)
    end

    it "gives the four failures four DIFFERENT sentences" do
      # The defect was not any one wording, it was that all four were byte-identical.
      closed = TCPServer.new("127.0.0.1", 0)
      dead = closed.local_address.port
      closed.close
      cases = {
        {dead, false},
        {start_tls_origin(advertise_h2: true), true},
        {start_quiet_origin, false},
        {start_tls_origin(advertise_h2: false), false},
      }
      errors = cases.map do |(port, verify)|
        Gori::Repeater::H2Engine.send(
          "GET /x HTTP/2\r\nHost: h\r\n\r\n".to_slice,
          scheme: "https", host: "127.0.0.1", port: port,
          verify_upstream: verify, timeout: 3.seconds).error.to_s.sub(port.to_s, "PORT")
      end
      errors.to_a.uniq.size.should eq(4)
    end
  end

  # The other half of the same fact: `incomplete?` conflates an origin that CLOSED early with
  # one that simply stopped sending, and its two renderers had only the first sentence to
  # offer. The engine knows which happened; it just was not carrying it.
  describe "why a delivered response is incomplete" do
    it "marks an idle timeout on a response the origin never finished framing" do
      result = Gori::Repeater::H2Engine.send(
        "GET /x HTTP/2\r\nHost: h\r\n\r\n".to_slice,
        scheme: "http", host: "127.0.0.1", port: start_h2_origin_stalled_body(200, "partial"),
        verify_upstream: false, timeout: 600.milliseconds)

      result.response.try(&.status).should eq(200)
      String.new(result.body || Bytes.empty).should eq("partial")
      result.incomplete?.should be_true
      result.timed_out?.should be_true # the socket was open the whole time
    end

    it "does NOT mark one on an origin that really did close mid-body" do
      result = Gori::Repeater::H2Engine.send(
        "GET /x HTTP/2\r\nHost: h\r\n\r\n".to_slice,
        scheme: "http", host: "127.0.0.1", port: start_h2_origin_truncated(200, "partial"),
        verify_upstream: false, timeout: 5.seconds)

      result.incomplete?.should be_true
      result.timed_out?.should be_false
    end
  end

  # F4. `synth_head` concatenated the final and the trailing header blocks with no record of
  # which arrived where, so a gRPC Trailers-Only response and a real trailers response were
  # byte-identical in the Repeater — while the capture path has carried `X-Gori-Trailers`
  # since #492. Whether a gateway/CDN/WAF promotes a trailer into a header is a first-class
  # gRPC test, and the Repeater is where it is run.
  describe "trailing header blocks" do
    it "marks the fields that arrived in a real TRAILING block" do
      result = Gori::Repeater::H2Engine.send(
        "POST /svc/M HTTP/2\r\nHost: h\r\ncontent-type: application/grpc\r\n\r\n".to_slice,
        scheme: "http", host: "127.0.0.1", port: start_h2_origin_grpc(trailers_only: false),
        verify_upstream: false, timeout: 5.seconds)
      head = String.new(result.head)
      head.should contain("grpc-status: 5")
      head.should contain("#{Gori::Proxy::H2::HeadCodec::TRAILER_MARKER}: grpc-status, grpc-message")
    end

    it "does NOT mark a Trailers-Only response, whose status arrived in the response head" do
      result = Gori::Repeater::H2Engine.send(
        "POST /svc/M HTTP/2\r\nHost: h\r\ncontent-type: application/grpc\r\n\r\n".to_slice,
        scheme: "http", host: "127.0.0.1", port: start_h2_origin_grpc(trailers_only: true),
        verify_upstream: false, timeout: 5.seconds)
      head = String.new(result.head)
      head.should contain("grpc-status: 5")
      head.should_not contain(Gori::Proxy::H2::HeadCodec::TRAILER_MARKER)
    end
  end

  # F5. The guard was `scheme == "https" && verify`, so `-k` / MCP `insecure:true` routed an
  # https target into the h2c branch and reported a cleartext prior-knowledge diagnosis for a
  # failed ALPN negotiation — on the branch operators hit most against a lab origin.
  #
  # R5 / H3-F1 kept both negative assertions and replaced the positive one: this origin is a
  # PLAINTEXT port, so "the origin doesn't offer HTTP/2 via ALPN" was itself one of the three
  # guesses the sentence was collapsing. The h2 engine now says which layer broke, in the h1
  # engine's own words — see "why an h2 dial produced no connection" above.
  it "does not diagnose h2c, or invent a certificate clause, for an https target with -k" do
    port = start_quiet_origin # accepts TCP, never completes a TLS handshake
    result = Gori::Repeater::H2Engine.send(
      "GET /x HTTP/2\r\nHost: h\r\n\r\n".to_slice,
      scheme: "https", host: "127.0.0.1", port: port, verify_upstream: false,
      timeout: 2.seconds)
    error = result.error.should_not be_nil
    error.should contain("TLS handshake failed")
    error.should_not contain("h2c")
    error.should_not contain("certificate") # verification was off — don't invent a clause
  end

  # F6. `authority_override` was one slot each `Host:` line overwrote, so the first vanished
  # with no notice — a duplicate `Host:` is a standard host-header-confusion / cache-poisoning
  # / h2-downgrade-desync probe, and h1 puts both lines on the wire for the same bytes.
  describe "duplicate and empty Host on the h1-text path" do
    it "carries a second Host: as a regular `host` field instead of dropping the first" do
      seen = Channel({Array({String, String}), Array({String, Int32})}).new(1)
      port = start_h2_origin_recording(seen)
      Gori::Repeater::H2Engine.send(
        "GET /dup HTTP/2\r\nHost: first.example\r\nHost: second.example\r\nX-A: 1\r\n\r\n".to_slice,
        scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false, timeout: 5.seconds)
      fields, _ = receive_within(seen)
      fields.should contain({":authority", "first.example"})
      fields.should contain({"host", "second.example"})
    end

    it "maps an EMPTY Host: to an empty :authority, not to gori's dial target" do
      seen = Channel({Array({String, String}), Array({String, Int32})}).new(1)
      port = start_h2_origin_recording(seen)
      Gori::Repeater::H2Engine.send(
        "GET /e HTTP/2\r\nHost: \r\nX-A: 1\r\n\r\n".to_slice,
        scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false, timeout: 5.seconds)
      fields, _ = receive_within(seen)
      fields.should contain({":authority", ""})
      fields.map(&.[1]).should_not contain("127.0.0.1:#{port}")
    end
  end
end
