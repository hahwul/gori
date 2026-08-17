require "../spec_helper"
require "socket"

# h2c PRIOR KNOWLEDGE arriving directly on a listener (#737) — no CONNECT, no TLS, no ALPN. The
# client opens with `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n` exactly as `curl --http2-prior-knowledge
# http://host/` and a cleartext gRPC client do.
#
# Only the two listeners where the destination is settled WITHOUT reading the request: a reverse
# listener (the origin is declared) and a transparent one (the kernel names it). The forward
# proxy still refuses, and `spec/proxy/codec/http1_spec.cr` plus `h2c_spec.cr` cover that side.

private alias Frame = Gori::Proxy::H2::Frame
private alias HPACK = Gori::Proxy::H2::HPACK

private class RecSink < Gori::Proxy::FlowSink
  getter requests = [] of Gori::Store::CapturedRequest
  getter responses = [] of Gori::Store::CapturedResponse
  @id = 0_i64

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    @requests << req
    @id += 1
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
    @responses << resp
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

# A minimal cleartext-HTTP/2 (h2c) origin: reads the preface, waits for the request HEADERS,
# then replies SETTINGS + HEADERS(:status 200) + DATA. Serves one connection.
private def start_h2c_origin(body : String) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    Frame.read_preface(conn)
    loop do
      f = Frame.read(conn)
      break if f.nil? || f.frame_type == Frame::Type::Headers
    end
    conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
    status = HPACK::Encoder.new.encode([{":status", "200"}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, status).to_bytes)
    conn.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, 1_u32, body.to_slice).to_bytes)
    conn.flush
    sleep 0.2.seconds
    conn.close
  ensure
    origin.close rescue nil
  end
  port
end

# A cleartext HTTP/1.1 origin that reports the request line it received.
private def start_h1_origin(seen : Channel(String)) : Int32
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    while conn = server.accept?
      begin
        head = Gori::Proxy::Codec::Http1.read_head(conn)
        next unless head
        seen.send(String.new(head).lines.first)
        conn << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi"
        conn.flush
        conn.close
      rescue
      end
    end
  end
  port
end

# Everything an h2c client sends before it expects an answer: preface, SETTINGS, one HEADERS
# carrying a complete request.
private def send_h2c_request(client : IO, authority : String, path : String = "/") : Nil
  client.write(Frame::PREFACE)
  client.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
  req = HPACK::Encoder.new.encode([
    {":method", "GET"}, {":path", path}, {":scheme", "http"}, {":authority", authority},
  ])
  client.write(Frame::Header.new(Frame::Type::Headers.value,
    Frame::END_HEADERS | Frame::END_STREAM, 1_u32, req).to_bytes)
  client.flush
end

# Read frames until the END_STREAM DATA on stream 1, or EOF. {saw a :status head?, body}.
private def read_h2c_response(client : IO) : {Bool, String}
  body = ""
  head = false
  begin
    loop do
      f = Frame.read(client)
      break if f.nil?
      head = true if f.frame_type == Frame::Type::Headers && f.stream_id == 1
      if f.frame_type == Frame::Type::Data && f.stream_id == 1
        body += String.new(f.payload)
        break if f.end_stream?
      end
    end
  rescue
    # A refused connection is closed mid-preface; that IS the answer these examples want.
  end
  {head, body}
end

private def await_capture(sink : RecSink) : Nil
  attempts = 0
  while sink.responses.empty? && attempts < 250
    sleep 0.02.seconds
    attempts += 1
  end
end

private def with_reverse_h2c(origin : {String, String, Int32}, &)
  sink = RecSink.new
  proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, origin: origin)
  proxy.start
  begin
    yield proxy, sink
  ensure
    proxy.stop
  end
end

describe "h2c prior knowledge on a listener (#737)" do
  describe "reverse listener" do
    it "relays a prior-knowledge h2 connection to the declared origin and captures it" do
      origin_port = start_h2c_origin("reverse-h2c-ok")
      with_reverse_h2c({"http", "127.0.0.1", origin_port}) do |proxy, sink|
        client = TCPSocket.new("127.0.0.1", proxy.port)
        client.read_timeout = 15.seconds
        # Straight into HTTP/2: no CONNECT, no ClientHello. This is what curl
        # --http2-prior-knowledge puts on the wire.
        send_h2c_request(client, "declared.test")
        head, body = read_h2c_response(client)
        client.close

        head.should be_true
        body.should eq("reverse-h2c-ok")

        await_capture(sink)
        sink.requests.first.http_version.should eq("HTTP/2")
        sink.requests.first.target.should eq("/")
        sink.responses.first.status.should eq(200)
      end
    end

    # THE REGRESSION GUARD for the routing byte. The h2 preface begins 0x50, and so do POST, PUT
    # and PATCH — on the CONNECT path 0x50 can only be the preface, on a listener it is usually a
    # form submission. A first-byte branch would divert every one of them into the h2 relay.
    it "still serves a POST, whose first byte is the preface's" do
      seen = Channel(String).new(1)
      origin_port = start_h1_origin(seen)
      with_reverse_h2c({"http", "127.0.0.1", origin_port}) do |proxy, sink|
        sock = TCPSocket.new("127.0.0.1", proxy.port)
        sock.read_timeout = 15.seconds
        sock << "POST /submit HTTP/1.1\r\nHost: declared.test\r\nContent-Length: 4\r\n\r\nform"
        sock.flush
        response = sock.gets_to_end
        sock.close

        response.should contain("200 OK")
        response.should contain("hi")
        seen.receive.should eq("POST /submit HTTP/1.1")
        # It went down the ordinary h1 path, so it is an HTTP/1.1 flow, not an h2 one.
        sink.requests.size.should eq(1)
        sink.requests.first.target.should eq("/submit")
      end
    end

    # `PRI` is not the only method starting with P that is not the preface. The full comparison
    # is what separates them; a four-byte one would too, this proves neither is a prefix match on
    # one letter.
    it "still serves a PATCH" do
      seen = Channel(String).new(1)
      origin_port = start_h1_origin(seen)
      with_reverse_h2c({"http", "127.0.0.1", origin_port}) do |proxy, _sink|
        sock = TCPSocket.new("127.0.0.1", proxy.port)
        sock.read_timeout = 15.seconds
        sock << "PATCH /thing HTTP/1.1\r\nHost: declared.test\r\nContent-Length: 2\r\n\r\nok"
        sock.flush
        sock.gets_to_end.should contain("200 OK")
        sock.close
        seen.receive.should eq("PATCH /thing HTTP/1.1")
      end
    end

    # "force HTTP/1.1" must not be quietly untrue on this socket. The client already sent the
    # preface, so there is nothing to downgrade — the honest answer is a visible refusal.
    it "refuses when HTTP/2 is switched off, without disturbing the listener" do
      origin_port = start_h2c_origin("must-not-arrive")
      seen = Channel(String).new(1)
      h1_port = start_h1_origin(seen)
      Gori::Settings.http2 = "off"
      with_reverse_h2c({"http", "127.0.0.1", origin_port}) do |proxy, sink|
        client = TCPSocket.new("127.0.0.1", proxy.port)
        client.read_timeout = 15.seconds
        send_h2c_request(client, "declared.test")
        head, body = read_h2c_response(client)
        client.close

        head.should be_false
        body.should eq("")
        sink.requests.should be_empty
      end
      Gori::Settings.http2 = "auto"

      # The listener is still alive and still serves h1 (a fresh one — the refusal must not
      # have wedged the accept loop).
      with_reverse_h2c({"http", "127.0.0.1", h1_port}) do |proxy, _sink|
        sock = TCPSocket.new("127.0.0.1", proxy.port)
        sock.read_timeout = 15.seconds
        sock << "GET /after HTTP/1.1\r\nHost: declared.test\r\n\r\n"
        sock.flush
        sock.gets_to_end.should contain("200 OK")
        sock.close
        seen.receive.should eq("GET /after HTTP/1.1")
      end
    ensure
      Gori::Settings.http2 = "auto"
    end

    # A TLS origin needs an h2-over-TLS upstream leg, and the h2c relay dials in the clear. A
    # refusal that says so beats a plaintext preface arriving at a TLS port.
    it "refuses prior knowledge when the declared origin is https" do
      origin_port = start_h2c_origin("must-not-arrive")
      with_reverse_h2c({"https", "127.0.0.1", origin_port}) do |proxy, sink|
        client = TCPSocket.new("127.0.0.1", proxy.port)
        client.read_timeout = 15.seconds
        send_h2c_request(client, "declared.test")
        head, _body = read_h2c_response(client)
        client.close
        head.should be_false
        sink.requests.should be_empty
      end
    end
  end

  describe "transparent listener" do
    # h2c is the one transparent branch with no second source for the destination: no Host
    # header, no SNI, and the `:authority` is inside the connection's HPACK state. With no
    # kernel answer — which is every loopback connection, since nothing redirected it — the
    # only honest move is to drop it. What must NOT happen is a dial to something invented, or
    # a hang.
    it "drops prior knowledge when the kernel has no original destination, and stays up" do
      seen = Channel(String).new(1)
      origin_port = start_h1_origin(seen)
      sink = RecSink.new
      proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink,
        transparent: true, target_port: origin_port)
      proxy.start
      begin
        client = TCPSocket.new("127.0.0.1", proxy.port)
        client.read_timeout = 15.seconds
        send_h2c_request(client, "127.0.0.1:#{origin_port}")
        head, _body = read_h2c_response(client)
        client.close
        head.should be_false
        sink.requests.should be_empty

        # The listener survived: an ordinary cleartext request still works.
        sock = TCPSocket.new("127.0.0.1", proxy.port)
        sock.read_timeout = 15.seconds
        sock << "GET /after HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
        sock.flush
        sock.gets_to_end.should contain("200 OK")
        sock.close
        seen.receive.should eq("GET /after HTTP/1.1")
      ensure
        proxy.stop
      end
    end

    # The kernel's answer itself cannot be produced in a spec — it needs a root-owned
    # iptables/pf redirect in front of the listener — so this drives the seam `Server` fills
    # from it, with the answer injected, exactly as `transparent_dial_pin_spec.cr` does for the
    # cleartext and TLS branches. `::1` is the lie: every origin here binds 127.0.0.1 only, so
    # the dial can only succeed if the kernel's address decided it.
    it "dials the kernel's address on the h2c path (#529's pin), not the name" do
      origin_port = start_h2c_origin("pinned-h2c")
      sink = RecSink.new
      listener = TCPServer.new("127.0.0.1", 0)
      spawn do
        if accepted = listener.accept?
          conn = Gori::Proxy::ClientConn.new(accepted, "http", sink,
            origin_dst: {"127.0.0.1", origin_port})
          conn.serve_h2c_prior_knowledge("::1", origin_port, accepted)
          accepted.close rescue nil
        end
      end
      begin
        client = TCPSocket.new("127.0.0.1", listener.local_address.port)
        client.read_timeout = 15.seconds
        send_h2c_request(client, "[::1]:#{origin_port}")
        head, body = read_h2c_response(client)
        client.close

        head.should be_true
        body.should eq("pinned-h2c")
        await_capture(sink)
        # The NAME is what History records — the pin changed the connect target, not the flow.
        sink.requests.first.host.should eq("::1")
        sink.requests.first.http_version.should eq("HTTP/2")
      ensure
        listener.close rescue nil
      end
    end

    # THE CONTROL for the example above: same call, one argument different.
    it "cannot reach the origin when nothing pinned the h2c dial" do
      origin_port = start_h2c_origin("unreachable")
      sink = RecSink.new
      listener = TCPServer.new("127.0.0.1", 0)
      spawn do
        if accepted = listener.accept?
          conn = Gori::Proxy::ClientConn.new(accepted, "http", sink)
          conn.serve_h2c_prior_knowledge("::1", origin_port, accepted)
          accepted.close rescue nil
        end
      end
      begin
        client = TCPSocket.new("127.0.0.1", listener.local_address.port)
        client.read_timeout = 15.seconds
        begin
          send_h2c_request(client, "[::1]:#{origin_port}")
        rescue IO::Error
          # The dial fails and gori closes with the client's bytes still unread. On Linux that
          # is an RST, so this write raises EPIPE; macOS buffers it and the write returns. The
          # difference is not what this example is about — the refusal is, and the assertions
          # below hold either way. Narrowed to IO::Error so a real failure still surfaces.
        end
        head, body = read_h2c_response(client)
        client.close
        head.should be_false
        body.should eq("")
      ensure
        listener.close rescue nil
      end
    end
  end
end
