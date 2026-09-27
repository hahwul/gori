require "../spec_helper"
require "socket"

private alias D = Gori::Discover
private alias Frame = Gori::Proxy::H2::Frame
private alias HPACK = Gori::Proxy::H2::HPACK

# A cleartext-h2 origin that serves any number of requests per connection, counts the
# connections it accepted and keeps every request's DECODED header list — so an example can
# assert the fields Discover put on the h2 wire, not only the connection arithmetic. The same
# shape as spec/fuzz/h2_pool_spec.cr's origin, which wants different accessors.
private class H2DiscoverOrigin
  getter port : Int32
  getter connections = 0
  getter requests = 0
  getter fields = [] of Array({String, String})

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
    # server closed
  end

  private def serve(conn : TCPSocket) : Nil
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
    conn.flush
    enc = HPACK::Encoder.new
    dec = HPACK::Decoder.new
    loop do
      f = Frame.read(conn)
      break if f.nil?
      case f.frame_type
      when Frame::Type::Headers
        next unless f.end_headers?
        @fields << dec.decode(f.payload)
        respond(conn, enc, f.stream_id) if f.end_stream?
      when Frame::Type::Goaway
        break
      else
        # SETTINGS / WINDOW_UPDATE / PING from the client — nothing to do here.
      end
    end
  rescue
    # The client closing a parked connection is the normal end of a pooled one.
  ensure
    conn.close rescue nil
  end

  private def respond(conn : TCPSocket, enc : HPACK::Encoder, id : UInt32) : Nil
    @requests += 1
    block = enc.encode([{":status", "200"}, {"content-type", "text/plain"}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, id, block).to_bytes)
    conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, id, "pong".to_slice).to_bytes)
    conn.flush
  end
end

private def h2_sender(keep_alive : Bool) : D::Sender
  D::Sender.new(verify: false, timeout: 5.seconds, http2: true, keep_alive: keep_alive, idle_conns: 4)
end

describe "Discover over HTTP/2" do
  # `Connection` is a connection-specific field: RFC 9113 §8.2.2 says a request carrying one is
  # MALFORMED, and `H2Engine` passes it through untouched (right for operator bytes). Discover's
  # requests are gori's own, so the h1 `Connection: close` must never be written under h2 —
  # with keep-alive on or off.
  it "writes no connection field on the h2 wire" do
    [true, false].each do |keep_alive|
      origin = H2DiscoverOrigin.new
      s = h2_sender(keep_alive)
      s.fetch("http", "127.0.0.1", origin.port, "/a").error.should be_nil
      origin.fields.size.should eq(1)
      names = origin.fields[0].map(&.[0])
      names.should_not contain("connection")
      names.should contain(":path")
      String.new(s.request_head("http", "127.0.0.1", origin.port, "/a")).downcase.should_not contain("connection:")
      s.close
      origin.close
    end
  end
end
