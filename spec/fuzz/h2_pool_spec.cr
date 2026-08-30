require "../spec_helper"
require "socket"

private alias F = Gori::Fuzz
private alias Frame = Gori::Proxy::H2::Frame
private alias HPACK = Gori::Proxy::H2::HPACK

# A cleartext-h2 origin that serves MANY requests on ONE connection — the thing the engine
# could not do before `H2Pool`, and therefore the thing this file has to drive.
#
# It answers whatever stream a complete request arrives on (RFC 9113 §5.1.1: 1, 3, 5, …) and
# records every stream id it saw, per connection, so an example can assert both halves of
# reuse: that the ids advance, and that they advance ON THE SAME SOCKET.
#
# Its response encoder uses `indexing: true` DELIBERATELY. That makes the second response on a
# connection refer to `server: gori-test` by an index into the dynamic table the FIRST response
# established — §2.3.2 connection-lifetime state — which is the one thing a per-request decoder
# cannot get right, and gets wrong SILENTLY (an in-range index is not an error). It is the
# sharpest available test that the decoder really is connection-scoped now.
private class H2Origin
  getter port : Int32
  getter connections = 0
  # Connections whose serve loop ended because the peer went away. What makes the close
  # example an actual assertion rather than a restatement of `pool.should_not be_nil`.
  getter disconnects = 0
  # Stream ids served, in order, per accepted connection.
  getter streams = [] of Array(UInt32)

  @server : TCPServer

  def initialize(@body : String = "ok")
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    spawn { accept_loop }
  end

  def close : Nil
    @server.close rescue nil
  end

  private def accept_loop : Nil
    while conn = @server.accept?
      @connections += 1
      seen = [] of UInt32
      @streams << seen
      # `spawn serve(...)`, NOT `spawn { serve(...) }`: the block form closes over the loop
      # variables, so a fiber that starts after the next `accept?` would serve the next
      # connection and record its streams in the previous connection's list.
      spawn serve(conn, seen)
    end
  rescue
  end

  private def serve(conn : TCPSocket, seen : Array(UInt32)) : Nil
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
    conn.flush
    enc = HPACK::Encoder.new(indexing: true) # one per CONNECTION — see the class note
    dec = HPACK::Decoder.new
    open = {} of UInt32 => Bool # stream id => header block complete
    loop do
      f = Frame.read(conn)
      break if f.nil?
      case f.frame_type
      when Frame::Type::Headers
        next unless f.end_headers?
        dec.decode(f.payload)
        open[f.stream_id] = true
        respond(conn, enc, f.stream_id, seen) if f.end_stream?
      when Frame::Type::Data
        respond(conn, enc, f.stream_id, seen) if f.end_stream? && open[f.stream_id]?
      when Frame::Type::Goaway
        break
      else
        # SETTINGS / WINDOW_UPDATE / PING from the client — nothing to do here.
      end
    end
  rescue
  ensure
    @disconnects += 1
    conn.close rescue nil
  end

  private def respond(conn : TCPSocket, enc : HPACK::Encoder, id : UInt32,
                      seen : Array(UInt32)) : Nil
    seen << id
    block = enc.encode([{":status", "200"}, {"server", "gori-test"}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, id, block).to_bytes)
    conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, id, @body.to_slice).to_bytes)
    conn.flush
  end
end

# Poll rather than block, for the reason `spec/fuzz/keepalive_callers_spec.cr` states at its
# own copy: a bare blocking wait on socket-driven work is how CI hangs with no output.
private def eventually(timeout : Time::Span = 3.seconds, &) : Bool
  deadline = Time.instant + timeout
  until Time.instant > deadline
    return true if yield
    sleep 10.milliseconds
  end
  false
end

private def h2_sender(port : Int32, keep_alive : Bool) : F::Sender
  F::Sender.new(F::Origin.new("http", "127.0.0.1", port), ungated_outbound,
    http2: true, verify: false, keep_alive: keep_alive, idle_conns: 1,
    timeout: 5.seconds)
end

private def get(host_port : String) : Bytes
  "GET /x HTTP/1.1\r\nHost: #{host_port}\r\n\r\n".to_slice
end

describe Gori::Repeater::H2Pool do
  it "serves a whole sweep over ONE h2 connection, on the advancing stream ids §5.1.1 " \
     "requires — where every request used to pay its own dial (and, on https, its own TLS " \
     "handshake) because the engine only ever knew stream 1" do
    origin = H2Origin.new("hello")
    sender = h2_sender(origin.port, keep_alive: true)
    begin
      results = (1..5).map { sender.send(get("127.0.0.1:#{origin.port}")) }
      results.each do |r|
        r.error.should be_nil
        r.response.try(&.status).should eq(200)
        String.new(r.body || Bytes.empty).should eq("hello")
      end

      eventually { origin.streams.size == 1 && origin.streams[0].size == 5 }.should be_true
      origin.connections.should eq(1)
      origin.streams[0].should eq([1_u32, 3_u32, 5_u32, 7_u32, 9_u32])

      pool = sender.pool.should_not be_nil
      pool.dialed.should eq(1_i64)
      pool.reused.should eq(4_i64)
    ensure
      sender.close
      origin.close
    end
  end

  it "decodes a response whose HPACK block indexes an entry the PREVIOUS response put in the " \
     "dynamic table — the §2.3.2 connection state a per-request decoder silently gets wrong" do
    origin = H2Origin.new("ok")
    sender = h2_sender(origin.port, keep_alive: true)
    begin
      # The origin indexes `server: gori-test` on the first response and refers to it by index
      # afterwards. Every response must still carry the header, not a different one.
      3.times do
        r = sender.send(get("127.0.0.1:#{origin.port}"))
        r.error.should be_nil
        String.new(r.head).downcase.should contain("server: gori-test")
      end
    ensure
      sender.close
      origin.close
    end
  end

  it "still dials per send with keep-alive off, so an operator can take the sample over fresh " \
     "connections exactly as on HTTP/1.1" do
    origin = H2Origin.new("ok")
    sender = h2_sender(origin.port, keep_alive: false)
    begin
      3.times { sender.send(get("127.0.0.1:#{origin.port}")).error.should be_nil }
      eventually { origin.connections == 3 }.should be_true
      sender.pool.should be_nil
    ensure
      sender.close
      origin.close
    end
  end

  it "closes its parked connections when the sender is closed — a pool nobody closes is a " \
     "leaked fd per run" do
    origin = H2Origin.new("ok")
    sender = h2_sender(origin.port, keep_alive: true)
    begin
      sender.send(get("127.0.0.1:#{origin.port}")).error.should be_nil
      # Still parked and still open: the origin's serve loop is blocked on the next frame.
      eventually { origin.disconnects == 1 }.should be_false
      sender.close
      # The PEER is what makes this an assertion. Delete `close_all`'s body, or the
      # `@pool.try(&.close_all)` in `Backend#close`, and the origin never sees the hang-up.
      eventually { origin.disconnects == 1 }.should be_true
    ensure
      origin.close
    end
  end

  it "never pools a CONNECT — an h2 CONNECT is a tunnel, not a request another can follow" do
    Gori::Repeater::H2Pool.reusable_request?("GET").should be_true
    Gori::Repeater::H2Pool.reusable_request?("POST").should be_true
    Gori::Repeater::H2Pool.reusable_request?("CONNECT").should be_false
    # Taken verbatim off the operator's template, so a lowercase method is a legitimate — if
    # odd — thing to send, and it must not slip past the tunnel rule.
    Gori::Repeater::H2Pool.reusable_request?("connect").should be_false
  end
end

# An origin that (a) sends its SETTINGS exactly once, at connection start, like every real h2
# stack, and (b) replenishes only the CONNECTION flow-control window, with a stream-0
# WINDOW_UPDATE emitted while the client is reading the response.
#
# Both halves are things a pooled connection has to survive and a one-shot never met. It
# records how many requests it served and every request body length it read.
private class H2WindowOrigin
  getter port : Int32
  getter served = 0
  getter connections = 0
  @server : TCPServer

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    spawn { accept_loop }
  end

  def close : Nil
    @server.close rescue nil
  end

  private def accept_loop : Nil
    while conn = @server.accept?
      @connections += 1
      spawn serve(conn)
    end
  rescue
  end

  private def serve(conn : TCPSocket) : Nil
    conn.read_timeout = 10.seconds
    Frame.read_preface(conn)
    # ONCE, at connection start — never again. A pooled connection therefore only ever learns
    # the peer's settings on the response-read path.
    conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
    conn.flush
    enc = HPACK::Encoder.new
    dec = HPACK::Decoder.new
    body_len = 0
    loop do
      f = Frame.read(conn)
      break if f.nil?
      case f.frame_type
      when Frame::Type::Headers
        next unless f.end_headers?
        dec.decode(f.payload)
        body_len = 0
        respond(conn, enc, f.stream_id, 0) if f.end_stream?
      when Frame::Type::Data
        body_len += f.payload.size
        respond(conn, enc, f.stream_id, body_len) if f.end_stream?
      else
        # SETTINGS ACK / PING / WINDOW_UPDATE from the client.
      end
    end
  rescue
  ensure
    conn.close rescue nil
  end

  private def respond(conn : TCPSocket, enc : HPACK::Encoder, id : UInt32, consumed : Int32) : Nil
    @served += 1
    # The connection-level credit, and ONLY that: no stream WINDOW_UPDATE, and it goes out
    # ahead of the response so the client meets it inside `read_response`.
    if consumed > 0
      payload = Bytes.new(4)
      IO::ByteFormat::BigEndian.encode(consumed.to_u32, payload)
      conn.write(Frame::Header.new(Frame::Type::WindowUpdate.value, 0_u8, 0_u32, payload).to_bytes)
    end
    block = enc.encode([{":status", "200"}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, id, block).to_bytes)
    conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, id, "ok".to_slice).to_bytes)
    conn.flush
  end
end

# An origin that answers the FIRST request on a connection normally and then RST_STREAMs every
# one after it, before sending any HEADERS — a WAF that trips on a later payload, answering
# ENHANCE_YOUR_CALM / REFUSED_STREAM. The connection stays up, which is the whole point: the h1
# staleness predicate reads that as a dead parked socket.
#
# The first response is not decoration. `H2Pool#stale?` is consulted only on the REUSED branch,
# so a connection has to be cleanly parked before the refusal can be misread — which is exactly
# the shape a real sweep hits, and the reason a refuse-everything origin proves nothing.
private class H2RefusingOrigin
  getter port : Int32
  getter requests = 0
  @server : TCPServer

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    spawn { accept_loop }
  end

  def close : Nil
    @server.close rescue nil
  end

  private def accept_loop : Nil
    while conn = @server.accept?
      spawn serve(conn)
    end
  rescue
  end

  private def serve(conn : TCPSocket) : Nil
    conn.read_timeout = 10.seconds
    Frame.read_preface(conn)
    conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
    conn.flush
    enc = HPACK::Encoder.new
    dec = HPACK::Decoder.new
    seen_on_conn = 0
    body_pending = false
    loop do
      f = Frame.read(conn)
      break if f.nil?
      case f.frame_type
      when Frame::Type::Headers
        next unless f.end_headers?
        dec.decode(f.payload)
        if f.end_stream?
          seen_on_conn += 1
          answer(conn, enc, f.stream_id, seen_on_conn)
        else
          body_pending = true
        end
      when Frame::Type::Data
        next unless f.end_stream? && body_pending
        body_pending = false
        seen_on_conn += 1
        answer(conn, enc, f.stream_id, seen_on_conn)
      else
        # SETTINGS ACK / PING / WINDOW_UPDATE from the client.
      end
    end
  rescue
  ensure
    conn.close rescue nil
  end

  private def answer(conn : TCPSocket, enc : HPACK::Encoder, id : UInt32, nth : Int32) : Nil
    @requests += 1
    if nth == 1
      block = enc.encode([{":status", "200"}])
      conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, id, block).to_bytes)
      conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, id, "ok".to_slice).to_bytes)
    else
      code = Bytes.new(4)
      IO::ByteFormat::BigEndian.encode(11_u32, code) # ENHANCE_YOUR_CALM
      conn.write(Frame::Header.new(Frame::Type::RstStream.value, 0_u8, id, code).to_bytes)
    end
    conn.flush
  end
end

private def post(host_port : String, body : String) : Bytes
  ("POST /x HTTP/1.1\r\nHost: #{host_port}\r\nContent-Length: #{body.bytesize}\r\n\r\n" + body).to_slice
end

describe "H2Pool — the connection-scoped state a one-shot never needed" do
  it "credits a stream-0 WINDOW_UPDATE read on the RESPONSE path, so a sweep WITH A BODY does " \
     "not exhaust the send window it carries from request to request" do
    # 16 requests × 8 KiB = 128 KiB of request body over one connection, against the 65535-byte
    # default connection window. The origin replenishes only stream 0, and only while gori is
    # reading the response — the arm `read_response` used to discard as "ignored for a
    # one-shot". Without the credit the window runs out around request 8 and `write_data`
    # stalls out the whole patience budget, truncating the body and blaming the origin.
    origin = H2WindowOrigin.new
    sender = F::Sender.new(F::Origin.new("http", "127.0.0.1", origin.port), ungated_outbound,
      http2: true, verify: false, keep_alive: true, idle_conns: 1, timeout: 2.seconds)
    begin
      body = "x" * 8192
      16.times do
        r = sender.send(post("127.0.0.1:#{origin.port}", body))
        r.error.should be_nil
        r.response.try(&.status).should eq(200)
      end
      eventually { origin.served == 16 }.should be_true
      origin.connections.should eq(1)
      pool = sender.pool.should_not be_nil
      pool.dialed.should eq(1_i64) # never redialed — nothing stalled, nothing was poisoned
    ensure
      sender.close
      origin.close
    end
  end

  it "carries the peer's SETTINGS across requests when it was read on the RESPONSE path, so a " \
     "body-carrying request behind a bodiless one does not wait out a whole idle timeout for a " \
     "frame that already arrived" do
    origin = H2WindowOrigin.new
    sender = F::Sender.new(F::Origin.new("http", "127.0.0.1", origin.port), ungated_outbound,
      http2: true, verify: false, keep_alive: true, idle_conns: 1, timeout: 2.seconds)
    begin
      # Request 1 has NO body, so `write_request` never calls `await_settings` and the
      # origin's one-and-only SETTINGS is consumed by the response read.
      sender.send(get("127.0.0.1:#{origin.port}")).error.should be_nil
      # Request 2 does. If the response read dropped that SETTINGS, `await_settings` blocks
      # here for the full per-operation timeout waiting for a frame already spent.
      r = sender.send(post("127.0.0.1:#{origin.port}", "hello"))
      r.error.should be_nil
      (r.duration_us < 1_000_000).should be_true # nowhere near the 2s timeout
    ensure
      sender.close
      origin.close
    end
  end

  it "does not re-send a payload the peer REFUSED with RST_STREAM — that is a live connection " \
     "saying no, not a stale parked one, and the h1 staleness predicate cannot tell them apart" do
    origin = H2RefusingOrigin.new
    sender = F::Sender.new(F::Origin.new("http", "127.0.0.1", origin.port), ungated_outbound,
      http2: true, verify: false, keep_alive: true, idle_conns: 1, timeout: 2.seconds)
    begin
      # Payload 1 is answered and PARKS the connection — `stale?` is only ever consulted on
      # the reused branch, so without this the refusal below never reaches the predicate.
      sender.send(get("127.0.0.1:#{origin.port}")).error.should be_nil
      r = sender.send(get("127.0.0.1:#{origin.port}")) # refused on the parked connection
      r.error.should_not be_nil
      # The PEER's own words survive: a refusal must not be relabelled as a closed socket.
      r.error.not_nil!.downcase.should contain("rst_stream")
      r.retried?.should be_false, "the refused payload was put on the wire twice"

      # TWO payloads, two requests at the origin. Read as staleness, the refused GET is
      # re-sent on a fresh connection and the origin sees three.
      eventually { origin.requests == 2 }.should be_true
      pool = sender.pool.should_not be_nil
      pool.reused.should eq(1_i64) # it really did take the parked-connection branch
      pool.stale_retries.should eq(0_i64)
      pool.unsafe_stale.should eq(0_i64)
    ensure
      sender.close
      origin.close
    end
  end

  it "…and a REFUSED non-idempotent request keeps the origin's reason instead of a fabricated " \
     "\"the connection was closed by the origin\"" do
    origin = H2RefusingOrigin.new
    sender = F::Sender.new(F::Origin.new("http", "127.0.0.1", origin.port), ungated_outbound,
      http2: true, verify: false, keep_alive: true, idle_conns: 1, timeout: 2.seconds)
    begin
      sender.send(post("127.0.0.1:#{origin.port}", "warm")).error.should be_nil # parks it
      r = sender.send(post("127.0.0.1:#{origin.port}", "hello"))
      err = r.error.should_not be_nil
      err.downcase.should_not contain("was closed by the origin")
      sender.pool.should_not be_nil
      sender.pool.not_nil!.unsafe_stale.should eq(0_i64)
    ensure
      sender.close
      origin.close
    end
  end
end
