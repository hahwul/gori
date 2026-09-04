require "../spec_helper"
require "socket"

private alias WS = Gori::Proxy::WS
private alias Frame = Gori::Proxy::H2::Frame
private alias HPACK = Gori::Proxy::H2::HPACK
private alias WsEngine = Gori::Repeater::WsEngine
private alias H2WsStream = Gori::Repeater::H2WsStream

# The stored head of a WebSocket captured over RFC 8441 extended CONNECT — byte-for-byte the
# shape `H2::HeadCodec.synth_request` writes for one (`CONNECT` line, `Host:` from
# `:authority`, and the `X-Gori-Protocol` marker standing in for the `:protocol`
# pseudo-header). Every example replays THIS, so the specs exercise the same bytes a capture
# hands the Repeater rather than a hand-tuned convenience.
private def connect_head(port : Int32, path : String = "/chat") : Bytes
  ("CONNECT #{path} HTTP/2\r\n" \
   "Host: 127.0.0.1:#{port}\r\n" \
   "Origin: https://app.example\r\n" \
   "Sec-WebSocket-Version: 13\r\n" \
   "X-Gori-Protocol: websocket\r\n\r\n").to_slice
end

# What one fake peer observed, handed back to the example. A single Channel carrying one
# struct rather than several channels: an example that asserts on two facts must not be able
# to read them from two different runs of the origin.
private record H2WsSeen,
  fields : Array({String, String}),
  frames : Array(WS::Frame),
  raw : Bytes

# A cleartext-h2 (h2c prior-knowledge) origin that speaks RFC 8441.
#
# `enable_connect_protocol` advertises SETTINGS_ENABLE_CONNECT_PROTOCOL (§3); `status` is what
# it answers the extended CONNECT with; `initial_window` sets SETTINGS_INITIAL_WINDOW_SIZE so a
# flow-control example can force the client to wait for a WINDOW_UPDATE.
#
# `handle` is the script: it runs after the 2xx, receives the peer socket plus a `send_ws`
# lambda that wraps RFC 6455 frame bytes in DATA frames on the CONNECT stream, and returns when
# the example's scenario is done.
private def start_h2_ws_origin(seen : Channel(H2WsSeen), *,
                               enable_connect_protocol : Bool = true,
                               status : Int32 = 200,
                               initial_window : Int32? = nil,
                               ping_first : Bool = false,
                               &handle : TCPSocket, Proc(Bytes, Nil), Array(WS::Frame) -> Nil) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    begin
      conn.read_timeout = 5.seconds
      Frame.read_preface(conn)
      # §3.4 makes SETTINGS the server's first frame — unless `ping_first`, which is the shape
      # `H2Engine.await_settings`' own comment names: a chatty peer whose real SETTINGS follows
      # a PING a moment later.
      if ping_first
        conn.write(Frame::Header.new(Frame::Type::Ping.value, 0_u8, 0_u32, Bytes.new(8)).to_bytes)
      end
      settings = IO::Memory.new
      if enable_connect_protocol
        settings.write(Bytes[0x00, 0x08, 0x00, 0x00, 0x00, 0x01])
      end
      initial_window.try do |w|
        settings.write(Bytes[0x00, 0x04])
        settings.write_bytes(w.to_u32, IO::ByteFormat::BigEndian)
      end
      conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32,
        settings.to_slice).to_bytes)
      conn.flush

      dec = HPACK::Decoder.new
      fields = [] of {String, String}
      stream = 0_u32
      block = IO::Memory.new
      until stream != 0_u32 && !fields.empty?
        f = Frame.read(conn)
        break if f.nil?
        case f.frame_type
        when Frame::Type::Headers, Frame::Type::Continuation
          stream = f.stream_id
          block.write(f.frame_type == Frame::Type::Headers ? Gori::Repeater::H2Engine.header_block(f) : f.payload)
          fields = dec.decode(block.to_slice) if f.end_headers?
        else
          # SETTINGS ACK / WINDOW_UPDATE / PING ACK from the client — nothing to do.
        end
      end

      status_block = HPACK::Encoder.new.encode([{":status", status.to_s}, {"server", "gori-test"}])
      flags = status >= 200 && status < 300 ? Frame::END_HEADERS : (Frame::END_HEADERS | Frame::END_STREAM)
      conn.write(Frame::Header.new(Frame::Type::Headers.value, flags, stream, status_block).to_bytes)
      conn.flush

      frames = [] of WS::Frame
      raw = IO::Memory.new
      if status >= 200 && status < 300
        send_ws = ->(bytes : Bytes) do
          conn.write(Frame::Header.new(Frame::Type::Data.value, 0_u8, stream, bytes).to_bytes)
          conn.flush
          nil
        end
        handle.call(conn, send_ws, frames)
      end
      seen.send(H2WsSeen.new(fields, frames, raw.to_slice))
    rescue
      seen.send(H2WsSeen.new([] of {String, String}, [] of WS::Frame, Bytes.new(0))) rescue nil
    ensure
      conn.close rescue nil
    end
  end
  port
end

# Read `count` WebSocket frames out of the CONNECT stream's DATA payloads, appending them to
# `into`. The reassembly is the point: a DATA boundary has nothing to do with a frame boundary,
# so this parses a stream and not a frame per DATA.
private def read_ws_frames(conn : TCPSocket, count : Int32, into : Array(WS::Frame),
                           window : IO::Memory = IO::Memory.new) : Nil
  while into.size < count
    at = window.pos
    if h = WS.read_header(window)
      if (window.size - window.pos).to_u64 >= h.len
        if frame = WS.read_body(window, h)
          into << frame
          next
        end
      end
    end
    window.pos = at
    f = Frame.read(conn)
    break if f.nil?
    next unless f.frame_type == Frame::Type::Data
    payload = Gori::Repeater::H2Engine.data_block(f)
    next if payload.empty?
    resume = window.pos
    window.pos = window.size
    window.write(payload)
    window.pos = resume
  end
end

# A DATA frame carrying `bytes` on `stream`, written directly — for the examples that need to
# control DATA framing itself (a WebSocket frame split across two DATA frames).
private def write_data(conn : TCPSocket, stream : UInt32, bytes : Bytes) : Nil
  conn.write(Frame::Header.new(Frame::Type::Data.value, 0_u8, stream, bytes).to_bytes)
  conn.flush
end

private CLOSE_1000 = WS.encode(WS::OP_CLOSE, Bytes[0x03, 0xE8], mask: false)

private def send_over_h2(port : Int32, messages : Array(WsEngine::OutMsg),
                         head : Bytes? = nil,
                         idle : Time::Span = 500.milliseconds) : WsEngine::Result
  WsEngine.send(head || connect_head(port), messages,
    scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false, idle: idle)
end

# A real project scope, for the ONE example that exercises the send gate rather than the
# engine. The same three lines `spec/outbound_spec.cr` and `spec/protobuf_reflection_spec.cr`
# open one with; `ungated_outbound` is the helper for everything else here.
private def with_scope(&)
  path = File.tempname("gori-ws-h2", ".db")
  store = Gori::Store.open(path)
  begin
    yield Gori::Scope.load(store), store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def text(s : String, evidence : Bool = false) : WsEngine::OutMsg
  WsEngine::OutMsg.new(WS::OP_TEXT.to_i, s.to_slice, evidence: evidence)
end

describe "WebSocket over HTTP/2 (RFC 8441) replay" do
  describe "the predicate" do
    it "recognises a stored extended CONNECT head and not an ordinary CONNECT" do
      WS.extended_connect_request?(String.new(connect_head(443))).should be_true
      WS.extended_connect_request?("CONNECT example.com:443 HTTP/2\r\n\r\n").should be_false
      # `connect-udp` (RFC 9298) is an extended CONNECT that is NOT RFC 6455 framing.
      WS.extended_connect_request?("CONNECT /q HTTP/2\r\nX-Gori-Protocol: connect-udp\r\n\r\n")
        .should be_false
    end

    it "keeps the h1 and h2 halves apart and unites them in replayable?" do
      h2 = String.new(connect_head(443))
      h1 = "GET /ws HTTP/1.1\r\nHost: a\r\nUpgrade: websocket\r\n\r\n"
      WsEngine.upgrade_request?(h2).should be_false
      WsEngine.extended_connect_request?(h1).should be_false
      WsEngine.replayable?(h2).should be_true
      WsEngine.replayable?(h1).should be_true
      WsEngine.replayable?("GET / HTTP/1.1\r\nHost: a\r\n\r\n").should be_false
    end

    it "does not read the marker out of the body" do
      head = "CONNECT /chat HTTP/2\r\nHost: a\r\n\r\nX-Gori-Protocol: websocket\r\n"
      WS.extended_connect_request?(head).should be_false
    end
  end

  describe "the handshake" do
    it "opens the socket with :method CONNECT and :protocol websocket, and exchanges frames" do
      seen = Channel(H2WsSeen).new
      port = start_h2_ws_origin(seen) do |conn, send_ws, frames|
        read_ws_frames(conn, 1, frames)
        send_ws.call(WS.encode(WS::OP_TEXT, "pong-1".to_slice, mask: false))
        send_ws.call(CLOSE_1000)
      end

      res = send_over_h2(port, [text("ping-1")])
      got = receive_within(seen, what: "the origin's observations")

      res.error.should be_nil
      res.upgraded?.should be_true
      res.close_code.should eq 1000

      pseudo = got.fields.to_h
      pseudo[":method"].should eq "CONNECT"
      pseudo[":protocol"].should eq "websocket"
      pseudo[":scheme"].should eq "http"
      pseudo[":path"].should eq "/chat"
      pseudo[":authority"].should eq "127.0.0.1:#{port}"
      # The marker line is the pseudo-header now, not a regular field the origin sees.
      got.fields.map(&.[0]).should_not contain "x-gori-protocol"
      # …and the operator's own fields still ride along.
      pseudo["origin"].should eq "https://app.example"

      # RFC 6455 §5.3: a client frame is masked. The bytes the origin read back are the
      # operator's, unmasked to the payload they wrote.
      got.frames.size.should eq 1
      got.frames[0].masked?.should be_true
      String.new(got.frames[0].payload).should eq "ping-1"

      inbound = res.messages.select { |m| m.direction == "in" && m.opcode == WS::OP_TEXT.to_i }
      inbound.map { |m| String.new(m.payload) }.should eq ["pong-1"]
      res.handshake_head.empty?.should be_false
      String.new(res.handshake_head).should start_with "HTTP/2 200"
    end

    it "reads the origin's SETTINGS even when it opens with something else" do
      seen = Channel(H2WsSeen).new
      port = start_h2_ws_origin(seen, ping_first: true) do |conn, send_ws, frames|
        read_ws_frames(conn, 1, frames)
        send_ws.call(CLOSE_1000)
      end
      res = send_over_h2(port, [text("hello")])
      receive_within(seen, what: "the origin's observations").frames.size.should eq 1
      res.error.should be_nil
      res.upgraded?.should be_true
    end

    it "refuses when the origin never advertises SETTINGS_ENABLE_CONNECT_PROTOCOL" do
      seen = Channel(H2WsSeen).new
      port = start_h2_ws_origin(seen, enable_connect_protocol: false) { }
      res = send_over_h2(port, [text("hello")])

      res.ok?.should be_false
      res.upgraded?.should be_false
      res.messages.should be_empty
      err = res.error.not_nil!
      err.should contain "SETTINGS_ENABLE_CONNECT_PROTOCOL"
      err.should contain "RFC 8441"
    end

    it "reports a non-2xx as a refusal, with the origin's own head attached" do
      seen = Channel(H2WsSeen).new
      port = start_h2_ws_origin(seen, status: 403) { }
      res = send_over_h2(port, [text("hello")])

      res.ok?.should be_false
      res.upgraded?.should be_false
      res.answered?.should be_true # the origin DID reply — a 403 is not a dead socket
      res.error.not_nil!.should contain "403"
      String.new(res.handshake_head).should start_with "HTTP/2 403"
    end

    # `WsEngine.send` routes on the bytes, so a marker-less head never reaches the h2 branch
    # through it. The stream is driven directly here because this is the shape a hand-edited
    # pane can still produce once the tab IS a WebSocket tab — and the refusal has to name the
    # missing line rather than open a plain CONNECT tunnel and read frames out of a proxy.
    it "refuses a head with no :protocol rather than opening a plain CONNECT tunnel" do
      seen = Channel(H2WsSeen).new
      port = start_h2_ws_origin(seen) { }
      conn, err = Gori::Repeater::H2Engine.dial("http", "127.0.0.1", port, false, nil,
        2.seconds, nil, nil)
      err.should be_nil
      begin
        opened = H2WsStream.open(conn.not_nil!,
          "CONNECT /chat HTTP/2\r\nHost: 127.0.0.1:#{port}\r\n\r\n".to_slice,
          scheme: "http", host: "127.0.0.1", port: port, stall: 2.seconds)
        opened.stream.should be_nil
        opened.error.not_nil!.should contain "X-Gori-Protocol"
      ensure
        conn.try(&.close)
      end
    end

    it "names a body under the handshake head instead of sending or dropping it" do
      seen = Channel(H2WsSeen).new
      port = start_h2_ws_origin(seen) do |conn, send_ws, frames|
        read_ws_frames(conn, 1, frames)
        send_ws.call(CLOSE_1000)
      end
      head = String.new(connect_head(port)) + "stowaway"
      res = send_over_h2(port, [text("go")], head.to_slice)
      got = receive_within(seen, what: "the origin's observations")

      res.error.should be_nil
      res.note.not_nil!.should contain "NOT sent"
      # The origin saw the script's frame and nothing else — the stray bytes never became DATA.
      got.frames.size.should eq 1
      String.new(got.frames[0].payload).should eq "go"
    end
  end

  describe "the framed exchange" do
    it "preserves message order, opcode and binary bytes across a multi-message script" do
      seen = Channel(H2WsSeen).new
      port = start_h2_ws_origin(seen) do |conn, send_ws, frames|
        window = IO::Memory.new
        3.times do |i|
          read_ws_frames(conn, i + 1, frames, window)
          send_ws.call(WS.encode(WS::OP_BIN, Bytes[0xFF_u8, i.to_u8], mask: false))
        end
        send_ws.call(CLOSE_1000)
      end

      binary = Bytes[0x00_u8, 0xFF_u8, 0x80_u8, 0x0A_u8]
      res = send_over_h2(port, [
        text("first"),
        WsEngine::OutMsg.new(WS::OP_BIN.to_i, binary),
        WsEngine::OutMsg.new(WS::OP_PING.to_i, "keepalive".to_slice),
      ])
      got = receive_within(seen, what: "the origin's observations")

      res.error.should be_nil
      got.frames.size.should eq 3
      got.frames.map(&.opcode).should eq [WS::OP_TEXT, WS::OP_BIN, WS::OP_PING]
      String.new(got.frames[0].payload).should eq "first"
      got.frames[1].payload.should eq binary
      String.new(got.frames[2].payload).should eq "keepalive"

      # The transcript keeps the wire order, out and in interleaved.
      res.messages.map(&.direction).first(6).should eq ["out", "in", "out", "in", "out", "in"]
      res.messages.select { |m| m.direction == "in" && m.opcode == WS::OP_BIN.to_i }
        .map { |m| m.payload[1] }.should eq [0_u8, 1_u8, 2_u8]
    end

    it "sends the operator's frame SHAPE, not a folded default" do
      seen = Channel(H2WsSeen).new
      port = start_h2_ws_origin(seen) do |conn, send_ws, frames|
        read_ws_frames(conn, 1, frames)
        send_ws.call(CLOSE_1000)
      end

      shape = WS::Shape.new(fin: false, rsv: 4, mask_key: Bytes[0xAA_u8, 0xBB_u8, 0xCC_u8, 0xDD_u8])
      send_over_h2(port, [WsEngine::OutMsg.new(WS::OP_BIN.to_i, "frag".to_slice, shape)])
      got = receive_within(seen, what: "the origin's observations")

      got.frames.size.should eq 1
      f = got.frames[0]
      f.fin?.should be_false
      f.rsv.should eq 4
      f.opcode.should eq WS::OP_BIN
      f.mask_key.not_nil!.should eq Bytes[0xAA_u8, 0xBB_u8, 0xCC_u8, 0xDD_u8]
      String.new(f.payload).should eq "frag"
    end

    it "reassembles a server frame split across two DATA frames" do
      seen = Channel(H2WsSeen).new
      port = start_h2_ws_origin(seen) do |conn, send_ws, frames|
        read_ws_frames(conn, 1, frames)
        whole = WS.encode(WS::OP_TEXT, "split-across-data".to_slice, mask: false)
        stream = 1_u32
        write_data(conn, stream, whole[0, 4])
        write_data(conn, stream, whole[4, whole.size - 4])
        send_ws.call(CLOSE_1000)
      end

      res = send_over_h2(port, [text("go")])
      receive_within(seen, what: "the origin's observations")
      res.error.should be_nil
      res.messages.select { |m| m.direction == "in" && m.opcode == WS::OP_TEXT.to_i }
        .map { |m| String.new(m.payload) }.should eq ["split-across-data"]
    end

    it "reassembles two server frames that share one DATA frame" do
      seen = Channel(H2WsSeen).new
      port = start_h2_ws_origin(seen) do |conn, _send_ws, frames|
        read_ws_frames(conn, 1, frames)
        a = WS.encode(WS::OP_TEXT, "one".to_slice, mask: false)
        b = WS.encode(WS::OP_TEXT, "two".to_slice, mask: false)
        joined = Bytes.new(a.size + b.size + CLOSE_1000.size)
        a.copy_to(joined)
        b.copy_to(joined + a.size)
        CLOSE_1000.copy_to(joined + a.size + b.size)
        write_data(conn, 1_u32, joined)
      end

      res = send_over_h2(port, [text("go")])
      receive_within(seen, what: "the origin's observations")
      res.messages.select { |m| m.direction == "in" && m.opcode == WS::OP_TEXT.to_i }
        .map { |m| String.new(m.payload) }.should eq ["one", "two"]
      res.close_code.should eq 1000
    end

    it "answers an h2 PING and a WebSocket PING without losing the session" do
      seen = Channel(H2WsSeen).new
      pinged = Channel(Bool).new(1)
      port = start_h2_ws_origin(seen) do |conn, send_ws, frames|
        conn.write(Frame::Header.new(Frame::Type::Ping.value, 0_u8, 0_u32,
          Bytes[1_u8, 2, 3, 4, 5, 6, 7, 8]).to_bytes)
        conn.flush
        send_ws.call(WS.encode(WS::OP_PING, "hi".to_slice, mask: false))
        window = IO::Memory.new
        # The client's PONG for the WebSocket PING, then its own scripted message.
        read_ws_frames(conn, 2, frames, window)
        pinged.send(frames.any? { |f| f.opcode == WS::OP_PONG })
        send_ws.call(CLOSE_1000)
      end

      res = send_over_h2(port, [text("after-ping")])
      receive_within(seen, what: "the origin's observations")
      receive_within(pinged, what: "a PONG verdict").should be_true
      res.error.should be_nil
      res.messages.any? { |m| m.direction == "in" && m.opcode == WS::OP_PING.to_i }.should be_true
    end
  end

  describe "flow control" do
    it "waits for WINDOW_UPDATE instead of overrunning the peer's window" do
      seen = Channel(H2WsSeen).new
      # 64-byte initial stream window: the 4 KiB message below cannot go out in one go.
      port = start_h2_ws_origin(seen, initial_window: 64) do |conn, send_ws, frames|
        window = IO::Memory.new
        deadline = Time.instant + 5.seconds
        # Grant window in 64-byte pieces, so the client has to block for credit repeatedly.
        spawn do
          64.times do
            break if Time.instant > deadline
            payload = Bytes.new(4)
            IO::ByteFormat::BigEndian.encode(128_u32, payload)
            conn.write(Frame::Header.new(Frame::Type::WindowUpdate.value, 0_u8, 1_u32, payload).to_bytes)
            conn.write(Frame::Header.new(Frame::Type::WindowUpdate.value, 0_u8, 0_u32, payload).to_bytes)
            conn.flush
            Fiber.yield
          end
        rescue
        end
        read_ws_frames(conn, 1, frames, window)
        send_ws.call(CLOSE_1000)
      end

      big = "A" * 4096
      res = send_over_h2(port, [text(big)], idle: 2.seconds)
      got = receive_within(seen, what: "the origin's observations")

      res.error.should be_nil
      got.frames.size.should eq 1
      got.frames[0].payload.size.should eq 4096
      String.new(got.frames[0].payload).should eq big
    end

    it "credits the receive window so a response past the default window still arrives" do
      seen = Channel(H2WsSeen).new
      port = start_h2_ws_origin(seen) do |conn, send_ws, frames|
        read_ws_frames(conn, 1, frames)
        # 96 KiB of server payload — past the 65535-byte default connection window, so it
        # arrives only if gori replenishes it as it reads.
        send_ws.call(WS.encode(WS::OP_BIN, Bytes.new(96 * 1024) { |i| (i % 251).to_u8 }, mask: false))
        send_ws.call(CLOSE_1000)
      end

      res = send_over_h2(port, [text("go")], idle: 2.seconds)
      receive_within(seen, what: "the origin's observations")
      res.error.should be_nil
      inbound = res.messages.find { |m| m.direction == "in" && m.opcode == WS::OP_BIN.to_i }
      inbound.not_nil!.payload.size.should eq 96 * 1024
    end
  end

  describe "failures the operator has to see" do
    it "names a RST_STREAM and keeps the transcript it already had" do
      seen = Channel(H2WsSeen).new
      port = start_h2_ws_origin(seen) do |conn, send_ws, frames|
        read_ws_frames(conn, 1, frames)
        send_ws.call(WS.encode(WS::OP_TEXT, "before-reset".to_slice, mask: false))
        code = Bytes.new(4)
        IO::ByteFormat::BigEndian.encode(0x0b_u32, code) # ENHANCE_YOUR_CALM
        conn.write(Frame::Header.new(Frame::Type::RstStream.value, 0_u8, 1_u32, code).to_bytes)
        conn.flush
      end

      res = send_over_h2(port, [text("go")], idle: 2.seconds)
      receive_within(seen, what: "the origin's observations")
      res.upgraded?.should be_true
      res.messages.select { |m| m.direction == "in" && m.opcode == WS::OP_TEXT.to_i }
        .map { |m| String.new(m.payload) }.should eq ["before-reset"]
      note = res.note.not_nil!
      note.should contain "ENHANCE_YOUR_CALM"
      note.downcase.should contain "reset"
    end

    it "names a GOAWAY rather than reporting a quiet end" do
      seen = Channel(H2WsSeen).new
      port = start_h2_ws_origin(seen) do |conn, _send_ws, frames|
        read_ws_frames(conn, 1, frames)
        payload = Bytes.new(8)
        IO::ByteFormat::BigEndian.encode(1_u32, payload[0, 4])    # last stream id
        IO::ByteFormat::BigEndian.encode(0x0b_u32, payload[4, 4]) # ENHANCE_YOUR_CALM
        conn.write(Frame::Header.new(Frame::Type::Goaway.value, 0_u8, 0_u32, payload).to_bytes)
        conn.flush
      end

      res = send_over_h2(port, [text("go")], idle: 2.seconds)
      receive_within(seen, what: "the origin's observations")
      res.note.not_nil!.should contain "GOAWAY"
    end

    it "reports an origin that never grants flow-control window" do
      seen = Channel(H2WsSeen).new
      # A 1-byte initial window and no WINDOW_UPDATE ever: the message cannot go out.
      port = start_h2_ws_origin(seen, initial_window: 1) do |_conn, _send_ws, _frames|
        sleep 3.seconds
      end

      # `idle` is the per-read bound; the stall clock is `Settings.io_timeout`, so keep the
      # payload just past the window and let the (short) spec timeout settle it.
      res = WsEngine.send(connect_head(port), [text("A" * 64)],
        scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
        idle: 300.milliseconds, deadline: 5.seconds)
      (receive_within(seen, what: "the origin's observations") rescue nil)
      # Nothing was delivered, and the report says why rather than showing an empty clean run.
      res.messages.select(&.direction.==("out")).should be_empty
      res.note.not_nil!.should contain "flow control"
    end

    it "says keep-key has no RFC 8441 form instead of silently ignoring it" do
      seen = Channel(H2WsSeen).new
      port = start_h2_ws_origin(seen) do |conn, send_ws, frames|
        read_ws_frames(conn, 1, frames)
        send_ws.call(CLOSE_1000)
      end
      res = WsEngine.send(connect_head(port), [text("go")],
        scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
        idle: 500.milliseconds, keep_key: true)
      receive_within(seen, what: "the origin's observations")
      res.note.not_nil!.should contain "Sec-WebSocket-Key"
    end

    it "reports a dead origin in the words every other h2 send uses" do
      closed = TCPServer.new("127.0.0.1", 0)
      port = closed.local_address.port
      closed.close
      res = send_over_h2(port, [text("go")])
      res.ok?.should be_false
      res.upgraded?.should be_false
      res.answered?.should be_false
      res.error.not_nil!.should_not be_empty
    end
  end

  describe "the send seam" do
    it "refuses a sandboxed target before any socket is opened" do
      seen = Channel(H2WsSeen).new
      port = start_h2_ws_origin(seen) { }
      with_scope do |scope, _store|
        scope.enable_sandbox
        sender = Gori::Repeater::Sender.new(Gori::Outbound.interactive(scope),
          scheme: "http", host: "127.0.0.1", port: port, verify: false)
        res = sender.send_ws(connect_head(port), [text("go")])
        res.ok?.should be_false
        res.upgraded?.should be_false
        res.messages.should be_empty
        res.error.not_nil!.should eq Gori::Outbound::SANDBOX_ERROR
      end
    end

    # `downgrade_version_line` corrects an `HTTP/2` request line about to ride an h1 socket.
    # A handshake never does: this one IS sent over h2, so editing the capture's own request
    # line on the way to a send that does not read it would be a rewrite for nothing.
    it "leaves the handshake's HTTP/2 request line alone" do
      options = Gori::Repeater::PlanOptions.new(
        requests: [connect_head(443)],
        target: "https://127.0.0.1/chat", verify: false)
      plan = Gori::Repeater::Plan.build(options, ungated_outbound)
      plan.websocket?.should be_true
      String.new(plan.bytes).lines.first.should eq "CONNECT /chat HTTP/2"
    end

    it "routes an extended CONNECT session through Plan#send_ws" do
      seen = Channel(H2WsSeen).new
      port = start_h2_ws_origin(seen) do |conn, send_ws, frames|
        read_ws_frames(conn, 1, frames)
        send_ws.call(WS.encode(WS::OP_TEXT, "planned".to_slice, mask: false))
        send_ws.call(CLOSE_1000)
      end
      options = Gori::Repeater::PlanOptions.new(
        requests: [connect_head(port)],
        target: "http://127.0.0.1:#{port}/chat", verify: false)
      plan = Gori::Repeater::Plan.build(options, ungated_outbound)
      plan.websocket?.should be_true
      res = plan.send_ws([text("go")], 500.milliseconds)
      receive_within(seen, what: "the origin's observations")
      res.error.should be_nil
      res.messages.select { |m| m.direction == "in" && m.opcode == WS::OP_TEXT.to_i }
        .map { |m| String.new(m.payload) }.should eq ["planned"]
    end
  end
end
