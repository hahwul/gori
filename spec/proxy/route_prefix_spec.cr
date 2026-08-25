require "../spec_helper"
require "socket"
require "openssl"
require "file_utils"

# `Server#route_prefix` — the listener routing discriminator, and the one substantive change in
# its commit that arrived with no spec of its own.
#
# What it exists for: `IO::Buffered#peek` is ONE `read(2)`'s worth of bytes and refills only
# when the buffer is empty, so it can legitimately hand back a single octet — and the three
# listeners fed that answer straight into a TWO-byte test (`Tls::ClientHello.record_start?`) and
# a FOUR-byte one (`H2::Frame.preface_prefix?`). A ClientHello split `[0:1] / [1:]` across two
# writes therefore answered "not TLS", fell down the HTTP/1.1 path, and produced a flow whose
# method was `"\x16"`: no MITM, no capture, and the origin never dialled. A preface split after
# `"P"` was refused as "an h2/gRPC client preface on the HTTP/1.1 path". A `TCP_NODELAY` client,
# a PMTU boundary or an SSL layer that writes its record header separately is enough to cause
# either.
#
# Filling means CONSUMING, so the method hands the bytes back through a `PrefixIO` — and a
# regression in THAT half reaches production as the very symptom it was written to remove.
#
# TWO LAYERS, because neither alone is enough:
#
#   * the SEAM, driven directly over a loopback socket pair. The boundaries live here — that the
#     common path allocates nothing and consumes nothing cannot be observed from outside a
#     listener at all, since a correct `PrefixIO` is indistinguishable from an untouched socket
#     by construction.
#   * the THREE LISTENERS, end to end. `route_prefix` has three call sites and each hands its
#     `stream` to a different downstream (`tls.intercept`, `serve_h2c`, `ClientConn.new`); a
#     spec covering one listener leaves the other two's regressions reaching production.
#     `spec/proxy/socks5_spec.cr` already pins the SOCKS5 ClientHello split; the rest are here.
#
# THE TWO CASES DO NOT BITE THE SAME LISTENERS, and saying which is the difference between a
# spec that guards something and one that only looks like it does:
#
#   * the PREFACE split is a mis-ROUTING on all three. Each of them asks
#     `H2::Frame.preface_prefix?`, whose floor is four octets, so a one-octet peek used to send
#     an h2c connection down the HTTP/1.1 path. Neutering `route_prefix` to `{peeked, client}`
#     fails all three of these examples.
#   * the CLIENTHELLO split mis-ROUTED only on SOCKS5, which alone uses the two-byte
#     `Tls::ClientHello.record_start?`; reverse and transparent branch on `first[0]` and always
#     answered correctly. What the fill costs THEM is the REPLAY — filling consumes, so a
#     handler given the bare socket gets a ClientHello with its opening bytes gone. That is the
#     regression these two examples exist for, and dropping the `PrefixIO` from either branch
#     fails them (verified by mutation, along with the SOCKS5 one in `socks5_spec.cr`).

include Gori::Proxy
include Gori::Proxy::Tls

private alias Frame = Gori::Proxy::H2::Frame
private alias HPACK = Gori::Proxy::H2::HPACK

# The private discriminator, reachable. Reopening the class rather than widening the method's
# visibility keeps `route_prefix` what it is — listener-internal, with three call sites in one
# file — while still letting the boundaries be asserted on the real thing instead of on a copy
# of it that could drift.
class Gori::Proxy::Server
  def spec_route_prefix(client : TCPSocket, peeked : Bytes?) : {Bytes?, IO}
    route_prefix(client, peeked)
  end

  def spec_route_want(first : UInt8) : Int32
    route_want(first)
  end
end

private class RecSink < FlowSink
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

# ---------------------------------------------------------------------------------------------
# Seam harness
# ---------------------------------------------------------------------------------------------

# A REAL loopback TCP pair, not an `IO::Memory` or a stub: the whole defect is a property of
# `IO::Buffered#peek` over a socket — one `read(2)`'s worth, refilled only when empty — and a
# hand-written IO would answer whatever the spec author believed instead of what a socket does.
private def with_pair(&)
  listener = TCPServer.new("127.0.0.1", 0)
  peer = TCPSocket.new("127.0.0.1", listener.local_address.port)
  sock = listener.accept
  peer.sync = true
  sock.sync = true
  sock.read_timeout = 5.seconds
  begin
    yield peer, sock
  ensure
    peer.close rescue nil
    sock.close rescue nil
    listener.close rescue nil
  end
end

# A `Server` that is never started: `route_prefix` touches no listener state, and binding a port
# to ask it a question would only add a socket that has nothing to do with the answer.
private def discriminator : Gori::Proxy::Server
  Gori::Proxy::Server.new("127.0.0.1", 0, RecSink.new)
end

private def deliver(peer : TCPSocket, head : Bytes | String) : Nil
  peer.write(head.is_a?(String) ? head.to_slice : head)
  peer.flush
  sleep 50.milliseconds
end

# The SPLIT, reproduced exactly as a listener meets it: the first octet is delivered, `peek` is
# called on it — which is what fixes the buffer at one byte, since `IO::Buffered#peek` refills
# only when its buffer is EMPTY — and only then does the rest arrive. Peeking BETWEEN the two
# writes is the whole of it: without that the segments coalesce into one `read(2)` and the
# common path is what gets exercised, which is how this defect survived a green suite.
private def peek_split(peer : TCPSocket, sock : TCPSocket, first : Bytes | String,
                       rest : Bytes | String) : Bytes
  deliver(peer, first)
  peeked = sock.peek
  deliver(peer, rest)
  peeked
end

# The first 8 octets of a plausible TLS 1.2 ClientHello record: type, version, length, then the
# handshake header. `route_prefix` only ever looks at the first two.
private CLIENT_HELLO_HEAD = Bytes[0x16, 0x03, 0x01, 0x00, 0x40, 0x01, 0x00, 0x00]

describe "Server#route_prefix (the listener discriminator)" do
  describe "how many bytes it waits for" do
    it "waits for two on a TLS record byte, four on 'P', and one on anything else" do
      # The two floors the tests downstream state for themselves — `record_start?` needs the
      # version octet, `preface_prefix?` needs `\"PRI \"` because `0x50` also opens POST, PUT,
      # PATCH and PROPFIND. Everything else decides on the octet it already has.
      d = discriminator
      d.spec_route_want(0x16_u8).should eq(2)
      d.spec_route_want(0x50_u8).should eq(Frame::PREFACE_FLOOR)
      d.spec_route_want('G'.ord.to_u8).should eq(1)
      d.spec_route_want(0x00_u8).should eq(1)
    end
  end

  describe "the common path — the first read already satisfied `want`" do
    it "consumes nothing and allocates nothing for a whole ClientHello head" do
      # THE PROPERTY THAT KEEPS THE ROUTING BYTE-EXACT. When `peek` already answered with
      # enough, the socket ITSELF must come back, untouched: that is what lets `peek_sni` and
      # `Frame.read_preface` read their own bytes off it exactly as they did before this method
      # existed. A `PrefixIO` here would be correct and still wrong — it would mean every
      # ordinary connection pays an allocation and a wrapper for a decision that needed neither.
      with_pair do |peer, sock|
        deliver(peer, CLIENT_HELLO_HEAD)
        peeked = sock.peek
        prefix, stream = discriminator.spec_route_prefix(sock, peeked)

        stream.should be(sock)   # the socket itself — nothing was wrapped
        prefix.should be(peeked) # and the peek's own view — nothing was copied
        Tls::ClientHello.record_start?(prefix.not_nil!).should be_true
        # Nothing was consumed: the record still starts at the socket's next byte.
        sock.read_byte.should eq(0x16_u8)
        sock.read_byte.should eq(0x03_u8)
      end
    end

    it "consumes nothing for a whole preface, so `read_preface` still reads all 24 octets" do
      with_pair do |peer, sock|
        deliver(peer, Frame::PREFACE)
        prefix, stream = discriminator.spec_route_prefix(sock, sock.peek)

        stream.should be(sock)
        Frame.preface_prefix?(prefix).should be_true
        Frame.read_preface(sock).should eq(Frame::PREFACE)
      end
    end

    it "does not divert a POST, whose first byte is the preface's" do
      # `route_want` asks for four octets on `0x50` and gets them in one read, so the answer is
      # decided without any fill at all — and `\"POST\"` is not `\"PRI \"`.
      with_pair do |peer, sock|
        deliver(peer, "POST /form HTTP/1.1\r\n")
        prefix, stream = discriminator.spec_route_prefix(sock, sock.peek)

        stream.should be(sock)
        Frame.preface_prefix?(prefix).should be_false
        Tls::ClientHello.record_start?(prefix.not_nil!).should be_false
      end
    end
  end

  describe "the split path — `peek` answered with less than `want`" do
    it "fills a ClientHello split [0:1] / [1:] and replays every byte it read" do
      with_pair do |peer, sock|
        peeked = peek_split(peer, sock, Bytes[0x16], CLIENT_HELLO_HEAD[1..])
        peeked.size.should eq(1) # the shape the whole method exists for

        prefix, stream = discriminator.spec_route_prefix(sock, peeked)
        prefix.not_nil!.size.should eq(2)
        Tls::ClientHello.record_start?(prefix.not_nil!).should be_true
        stream.should be_a(PrefixIO)

        # P7: the handler is handed the COMPLETE stream. The two consumed octets come back
        # first, in order, and the socket's remaining bytes follow them seamlessly.
        replayed = Bytes.new(CLIENT_HELLO_HEAD.size)
        stream.read_fully(replayed)
        replayed.should eq(CLIENT_HELLO_HEAD)
      end
    end

    it "fills a preface split after 'P' and replays all 24 octets to `read_preface`" do
      with_pair do |peer, sock|
        peeked = peek_split(peer, sock, "P", String.new(Frame::PREFACE)[1..])
        peeked.size.should eq(1)

        prefix, stream = discriminator.spec_route_prefix(sock, peeked)
        prefix.not_nil!.size.should eq(Frame::PREFACE_FLOOR)
        String.new(prefix.not_nil!).should eq("PRI ")
        Frame.preface_prefix?(prefix).should be_true
        stream.should be_a(PrefixIO)
        Frame.read_preface(stream).should eq(Frame::PREFACE)
      end
    end

    it "fills a POST split after 'P' WITHOUT diverting it, and replays the request line" do
      # The other half of the four-octet floor: `route_want` makes the same fill for `POST`,
      # and the answer has to come back false with every byte still ahead of `ClientConn`.
      with_pair do |peer, sock|
        peeked = peek_split(peer, sock, "P", "OST /form HTTP/1.1\r\n\r\n")

        prefix, stream = discriminator.spec_route_prefix(sock, peeked)
        String.new(prefix.not_nil!).should eq("POST")
        Frame.preface_prefix?(prefix).should be_false
        stream.should be_a(PrefixIO)
        stream.gets.should eq("POST /form HTTP/1.1")
      end
    end
  end

  describe "the boundaries" do
    it "answers a SHORT prefix when the peer stops mid-fill, and routes it to h1" do
      # `0x16` and then nothing more, ever. The fill breaks on EOF rather than raising, both
      # tests answer false on one octet, and the connection goes down the HTTP/1.1 path where
      # `ClientConn` records what it actually saw (#729) — the same disposition it would have
      # had before this method existed, and never a dropped connection over a byte that never
      # came.
      with_pair do |peer, sock|
        deliver(peer, Bytes[0x16])
        peer.close
        sleep 50.milliseconds

        prefix, stream = discriminator.spec_route_prefix(sock, sock.peek)
        prefix.not_nil!.size.should eq(1)
        Tls::ClientHello.record_start?(prefix.not_nil!).should be_false
        Frame.preface_prefix?(prefix).should be_false
        stream.should be_a(PrefixIO)
        # The octet is still there for `ClientConn` to name in its flow.
        stream.read_byte.should eq(0x16_u8)
        stream.read_byte.should be_nil
      end
    end

    it "answers a SHORT prefix when the fill TIMES OUT, without raising out of the listener" do
      # The other way a fill ends early, and the one that is not an EOF: a peer that sent the
      # first octet and then held the socket open. `IO::TimeoutError` is an `IO::Error`, so it
      # is caught by the same rescue — a raise here would reach the accept-path rescue and close
      # the fd with nothing recorded anywhere, which is #755's failure over again.
      with_pair do |peer, sock|
        sock.read_timeout = 200.milliseconds
        deliver(peer, Bytes[0x16])

        prefix, stream = discriminator.spec_route_prefix(sock, sock.peek)
        prefix.not_nil!.size.should eq(1)
        Tls::ClientHello.record_start?(prefix.not_nil!).should be_false
        stream.should be_a(PrefixIO)
        peer.close
      end
    end

    it "hands EOF straight back, wrapping nothing" do
      # `IO::Buffered#peek` answers an EMPTY slice at EOF, never nil, and there is nothing to
      # fill toward — so the socket comes back untouched for the caller to dispose of.
      with_pair do |peer, sock|
        peer.close
        sleep 50.milliseconds
        peeked = sock.peek
        peeked.empty?.should be_true

        prefix, stream = discriminator.spec_route_prefix(sock, peeked)
        prefix.not_nil!.empty?.should be_true
        stream.should be(sock)
      end
    end

    it "hands a nil peek straight back, wrapping nothing" do
      # Not `IO::Buffered`'s answer, but the parameter's declared type is `Bytes?` and both
      # `peek_first` and `peek_transparent_first` are typed to return it — so the branch is
      # reachable by contract and must not wrap or consume.
      with_pair do |_peer, sock|
        prefix, stream = discriminator.spec_route_prefix(sock, nil)
        prefix.should be_nil
        stream.should be(sock)
      end
    end
  end
end

# ---------------------------------------------------------------------------------------------
# The three listeners, end to end
# ---------------------------------------------------------------------------------------------

# Splits the FIRST write into its first octet and the rest, with a scheduler yield between —
# which is what puts exactly ONE byte in gori's socket buffer when its `peek` runs.
private class SplitFirstWriteIO < IO
  def initialize(@inner : IO)
    @split = true
  end

  def read(slice : Bytes) : Int32
    @inner.read(slice)
  end

  def write(slice : Bytes) : Nil
    if @split && slice.size > 1
      @split = false
      @inner.write(slice[0, 1])
      @inner.flush
      sleep 50.milliseconds # let the listener's fiber run and peek the single octet
      @inner.write(slice[1..])
      return
    end
    @inner.write(slice)
  end

  def flush
    @inner.flush
  end

  def close
    @inner.close
  end
end

private def start_tls_origin(body : String, seen : Channel(String)) : Int32
  cert, key = CertBuilder.build_root("origin.test")
  ctx = ContextFactory.server_context(cert, key, advertise_h2: false)
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    while raw = server.accept?
      begin
        ssl = OpenSSL::SSL::Socket::Server.new(raw, ctx, sync_close: true)
        head = Codec::Http1.read_head(ssl)
        next unless head
        seen.send(String.new(head).lines.first)
        ssl << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n" << body
        ssl.flush
        ssl.close
      rescue
      end
    end
  end
  port
end

private def start_h2c_origin(body : String) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while conn = origin.accept?
      begin
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
      rescue
      end
    end
  end
  port
end

private def trusting_client(raw : IO, ca_dir : String, sni : String) : OpenSSL::SSL::Socket::Client
  ctx = OpenSSL::SSL::Context::Client.new
  ca_cert = Cert.read_pem(File.join(ca_dir, "root.crt.pem"))
  store = LibSSL.ssl_ctx_get_cert_store(ctx.to_unsafe)
  LibCrypto.x509_store_add_cert(store, ca_cert.handle)
  OpenSSL::SSL::Socket::Client.new(raw, context: ctx, sync_close: true, hostname: sni)
end

# One opener per listener mode: the three are three distinct argument shapes on `Server.new`
# (a declared `origin`, `transparent` + `target_port`, `socks5`), not one parameter, so folding
# them into a single helper would only hide which shape an example is exercising.
private def with_reverse_listener(origin : {String, String, Int32}, &)
  ca_dir = File.tempname("gori-route-prefix-ca")
  Dir.mkdir_p(ca_dir)
  sink = RecSink.new
  tunnel = Tunnel.new(CertAuthority.load_or_create(ca_dir), verify_upstream: false)
  proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, tls: tunnel, origin: origin)
  proxy.start
  begin
    yield proxy, sink, ca_dir
  ensure
    proxy.stop
    FileUtils.rm_rf(ca_dir)
  end
end

private def with_transparent_listener(target_port : Int32, &)
  ca_dir = File.tempname("gori-route-prefix-ca")
  Dir.mkdir_p(ca_dir)
  sink = RecSink.new
  tunnel = Tunnel.new(CertAuthority.load_or_create(ca_dir), verify_upstream: false)
  proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, tls: tunnel,
    transparent: true, target_port: target_port)
  proxy.start
  begin
    yield proxy, sink, ca_dir
  ensure
    proxy.stop
    FileUtils.rm_rf(ca_dir)
  end
end

private def with_socks5_listener(&)
  ca_dir = File.tempname("gori-route-prefix-ca")
  Dir.mkdir_p(ca_dir)
  sink = RecSink.new
  tunnel = Tunnel.new(CertAuthority.load_or_create(ca_dir), verify_upstream: false)
  proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, tls: tunnel, socks5: true)
  proxy.start
  begin
    yield proxy, sink, ca_dir
  ensure
    proxy.stop
    FileUtils.rm_rf(ca_dir)
  end
end

private def await(sink : RecSink, &pred : RecSink -> Bool) : Nil
  200.times do
    break if pred.call(sink)
    sleep 0.02.seconds
  end
end

# The preface + SETTINGS + one complete HEADERS, with the FIRST octet on its own segment.
private def send_split_h2c_request(client : IO, authority : String, path : String) : Nil
  client.write(Frame::PREFACE[0, 1])
  client.flush
  sleep 50.milliseconds # the listener peeks "P" and nothing else
  client.write(Frame::PREFACE[1..])
  client.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
  req = HPACK::Encoder.new.encode([
    {":method", "GET"}, {":path", path}, {":scheme", "http"}, {":authority", authority},
  ])
  client.write(Frame::Header.new(Frame::Type::Headers.value,
    Frame::END_HEADERS | Frame::END_STREAM, 1_u32, req).to_bytes)
  client.flush
end

private def read_h2c_body(client : IO) : {Bool, String}
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
    # A refused connection is closed mid-stream; that IS the answer some examples want.
  end
  {head, body}
end

# THE SOCKS5 CLIENT HALF of RFC 1928 — NO-AUTH, CONNECT by name.
private def socks5_connect(port : Int32, host : String, dst_port : Int32) : {TCPSocket, UInt8}
  sock = TCPSocket.new("127.0.0.1", port)
  sock.write(Bytes[5_u8, 1_u8, 0_u8])
  sock.flush
  selection = Bytes.new(2)
  sock.read_fully(selection)
  name = host.to_slice
  sock.write(Bytes[5_u8, 1_u8, 0_u8, 3_u8, name.size.to_u8])
  sock.write(name)
  sock.write(Bytes[(dst_port >> 8).to_u8, (dst_port & 0xFF).to_u8])
  sock.flush
  head = Bytes.new(4)
  sock.read_fully(head)
  bound = case head[3]
          when Socks5::ATYP_IPV4 then 4
          when Socks5::ATYP_IPV6 then 16
          else                        0
          end
  sock.read_fully(Bytes.new(bound + 2))
  {sock, head[1]}
end

describe "route_prefix on every listener that routes with it" do
  # `route_prefix` has three call sites and each hands its `stream` somewhere different. A spec
  # covering one leaves the other two's regressions reaching production, which is the whole
  # reason this block is shaped by LISTENER rather than by case.

  describe "reverse listener" do
    it "MITMs a ClientHello split [0:1] / [1:]" do
      # `serve_reverse_tls` is the call site: it hands `stream` to `tls.intercept`, and handing
      # the bare socket on instead would give OpenSSL a ClientHello with its first bytes gone.
      seen = Channel(String).new(1)
      origin_port = start_tls_origin("reverse-split", seen)
      with_reverse_listener({"https", "127.0.0.1", origin_port}) do |proxy, sink, dir|
        raw = TCPSocket.new("127.0.0.1", proxy.port)
        ssl = trusting_client(SplitFirstWriteIO.new(raw), dir, "127.0.0.1")
        ssl << "GET /rsplit HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
        ssl.flush
        body = ssl.gets_to_end
        ssl.close
        await(sink, &.responses.any?)

        body.should contain("reverse-split")
        seen.receive.should eq("GET /rsplit HTTP/1.1")
        # Not a `"\x16"` "not an HTTP request" row: a real decrypted flow.
        sink.requests.first.scheme.should eq("https")
        sink.requests.first.target.should eq("/rsplit")
      end
    end

    it "serves an h2c preface split after 'P'" do
      # `serve_h2c`'s call site: `stream` carries all 24 octets, whether they were still in the
      # socket's buffer or `route_prefix` had to read the first four to tell `"PRI "` from
      # `POST`. Without the fill this was refused as "an h2/gRPC client preface on the HTTP/1.1
      # path".
      origin_port = start_h2c_origin("reverse-preface-split")
      with_reverse_listener({"http", "127.0.0.1", origin_port}) do |proxy, sink, _dir|
        client = TCPSocket.new("127.0.0.1", proxy.port)
        client.read_timeout = 15.seconds
        send_split_h2c_request(client, "127.0.0.1:#{origin_port}", "/rpreface")
        head, body = read_h2c_body(client)
        client.close
        await(sink, &.responses.any?)

        head.should be_true
        body.should eq("reverse-preface-split")
        sink.requests.first.target.should eq("/rpreface")
        sink.requests.first.http_version.should eq("HTTP/2")
      end
    end
  end

  describe "transparent listener" do
    it "MITMs a ClientHello split [0:1] / [1:], deriving the destination from the SNI" do
      seen = Channel(String).new(1)
      origin_port = start_tls_origin("transparent-split", seen)
      with_transparent_listener(origin_port) do |proxy, sink, dir|
        raw = TCPSocket.new("127.0.0.1", proxy.port)
        ssl = trusting_client(SplitFirstWriteIO.new(raw), dir, "localhost")
        subject = ssl.peer_certificate.not_nil!.subject.to_a.map { |e| "#{e[0]}=#{e[1]}" }.join(",")
        ssl << "GET /tsplit HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        ssl.flush
        body = ssl.gets_to_end
        ssl.close
        await(sink, &.responses.any?)

        # gori's own leaf, minted for the SNI it could only have read after the fill replayed
        # the first octet into `peek_sni`.
        subject.should contain("localhost")
        subject.should_not contain("origin.test")
        body.should contain("transparent-split")
        seen.receive.should eq("GET /tsplit HTTP/1.1")
        sink.requests.first.scheme.should eq("https")
        sink.requests.first.host.should eq("localhost")
      end
    end

    it "reads a preface split after 'P' as h2c, and drops it rather than filing a 'P' request" do
      # The transparent h2c branch has no destination on loopback — no Host header, no SNI, and
      # the `:authority` lives inside the connection's HPACK state — so DROPPING is the correct
      # answer here and `h2c_listener_spec.cr` pins it for the unsplit case.
      #
      # What THIS example is about is which branch decided. Without the fill the split preface
      # answered `preface_prefix?` false, fell into `ClientConn`, and produced a flow — so an
      # empty sink is the proof that the four-octet fill happened and the h2c branch, not the
      # h1 one, disposed of the connection.
      seen = Channel(String).new(1)
      origin_port = start_tls_origin("unused", seen)
      with_transparent_listener(origin_port) do |proxy, sink, _dir|
        client = TCPSocket.new("127.0.0.1", proxy.port)
        client.read_timeout = 15.seconds
        send_split_h2c_request(client, "127.0.0.1:#{origin_port}", "/tpreface")
        head, _ = read_h2c_body(client)
        client.close
        sleep 0.2.seconds

        head.should be_false
        sink.requests.should be_empty

        # And the listener survived it: an ordinary cleartext request still works.
        sock = TCPSocket.new("127.0.0.1", proxy.port)
        sock.read_timeout = 15.seconds
        sock << "GET /after HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
        sock.flush
        sock.gets_to_end
        sock.close
        await(sink, &.requests.any?)
        sink.requests.first.target.should eq("/after")
      end
    end
  end

  describe "socks5 listener" do
    # The ClientHello split is pinned in `spec/proxy/socks5_spec.cr`; the preface split is here,
    # so all three of `route_prefix`'s call sites have both of its cases covered somewhere.
    it "serves an h2c preface split after 'P' to the destination the handshake named" do
      origin_port = start_h2c_origin("socks5-preface-split")
      with_socks5_listener do |proxy, sink, _dir|
        sock, reply = socks5_connect(proxy.port, "127.0.0.1", origin_port)
        reply.should eq(Socks5::REP_SUCCEEDED)
        sock.read_timeout = 15.seconds
        send_split_h2c_request(sock, "127.0.0.1:#{origin_port}", "/spreface")
        head, body = read_h2c_body(sock)
        sock.close
        await(sink, &.responses.any?)

        head.should be_true
        body.should eq("socks5-preface-split")
        sink.requests.first.target.should eq("/spreface")
        sink.requests.first.host.should eq("127.0.0.1")
      end
    end

    it "does not divert a POST split after 'P' into the h2 relay" do
      # The four-octet floor, on the listener where a split is most likely: `0x50` also opens
      # POST, and a first-byte branch would commit this connection to a relay that dies at
      # `read_preface` with the origin already dialled.
      seen = Channel(String).new(1)
      origin = TCPServer.new("127.0.0.1", 0)
      origin_port = origin.local_address.port
      spawn do
        while conn = origin.accept?
          begin
            head = Codec::Http1.read_head(conn)
            next unless head
            seen.send(String.new(head).lines.first)
            conn << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi"
            conn.flush
            conn.close
          rescue
          end
        end
      end
      with_socks5_listener do |proxy, sink, _dir|
        sock, reply = socks5_connect(proxy.port, "127.0.0.1", origin_port)
        reply.should eq(Socks5::REP_SUCCEEDED)
        sock.write("P".to_slice)
        sock.flush
        sleep 50.milliseconds
        sock << "OST /form HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\n" \
                "Connection: close\r\n\r\n"
        sock.flush
        sock.gets_to_end.should contain("200 OK")
        sock.close
        await(sink, &.responses.any?)

        seen.receive.should eq("POST /form HTTP/1.1")
        sink.requests.first.method.should eq("POST")
        sink.requests.first.target.should eq("/form")
      end
      origin.close rescue nil
    end
  end
end
