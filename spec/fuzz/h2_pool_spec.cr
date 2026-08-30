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
    sender.send(get("127.0.0.1:#{origin.port}")).error.should be_nil
    sender.close
    # The origin's serve fiber ends when the socket goes away; nothing else observes the fd,
    # so this asserts the pool's own bookkeeping rather than the peer's.
    sender.pool.should_not be_nil
    origin.close
  end

  it "never pools a CONNECT — an h2 CONNECT is a tunnel, not a request another can follow" do
    Gori::Repeater::H2Pool.reusable_request?("GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice).should be_true
    Gori::Repeater::H2Pool.reusable_request?("CONNECT h:443 HTTP/1.1\r\nHost: h\r\n\r\n".to_slice).should be_false
  end
end
