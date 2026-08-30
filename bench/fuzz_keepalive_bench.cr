# Fuzz connection-reuse benchmark — the cost a sweep pays for its TRANSPORT, not its CPU.
#
# Every other fuzz bench in here measures a per-response code path (render, match, CL sync,
# frame draw), and those are now down in the tens of microseconds. What a real run actually
# waits on is the connection: `Repeater::Engine.send` dialed a fresh one, exchanged ONE
# request and closed it, so an N-request sweep paid N TCP handshakes and, on https, N TLS
# handshakes — each an RTT (or two or three) before a single payload byte moves, plus the
# asymmetric crypto on both ends.
#
#   OLD: dial → exchange → close, per request.
#   NEW: Fuzz::ConnPool parks the socket and the next request reuses it, so the run pays
#        ~concurrency handshakes instead of ~N.
#
# This is an END-TO-END measurement over loopback against a real keep-alive origin, so it
# understates the win: with RTT ≈ 0 the handshake costs only syscalls and (for TLS) CPU,
# where a remote origin also pays 2-3 round trips per request. Both an http and an https
# origin are measured because the TLS handshake is where the gap is widest.
#
# Build: crystal build bench/fuzz_keepalive_bench.cr -o bin/fuzz_keepalive_bench --release
# Run:   bin/fuzz_keepalive_bench
require "benchmark"
require "socket"
require "openssl"
require "http/server"

# `Gori::Error` (src/gori.cr) is what the decoder/codec requires below raise; declare it
# first, like the other benches, instead of pulling the whole binary in.
module Gori
  class Error < Exception; end
end

require "../src/gori"

alias F = Gori::Fuzz
alias Frame = Gori::Proxy::H2::Frame
alias HPACK = Gori::Proxy::H2::HPACK

REQUESTS    = 2000
CONCURRENCY =   50
BODY        = "x" * 1024

# A self-signed cert, generated once into a temp dir — the https origin needs one and a
# bench must not depend on a fixture file being present.
private def self_signed : {String, String}
  dir = File.tempname("gori-bench-tls")
  Dir.mkdir_p(dir)
  cert = File.join(dir, "cert.pem")
  key = File.join(dir, "key.pem")
  ok = Process.run("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-keyout", key,
                               "-out", cert, "-days", "1", "-nodes", "-subj", "/CN=localhost"],
    output: Process::Redirect::Close, error: Process::Redirect::Close).success?
  abort "openssl is required to generate the bench's TLS cert" unless ok
  {cert, key}
end

private def start_origin(tls : Bool) : {Int32, HTTP::Server}
  server = HTTP::Server.new do |ctx|
    ctx.response.content_type = "text/html"
    ctx.response.print BODY
  end
  port = if tls
           cert, key = self_signed
           ctx = OpenSSL::SSL::Context::Server.new
           ctx.certificate_chain = cert
           ctx.private_key = key
           server.bind_tls("127.0.0.1", 0, ctx).port
         else
           server.bind_tcp("127.0.0.1", 0).port
         end
  spawn { server.listen }
  {port, server}
end

# A minimal cleartext-h2 origin, because `HTTP::Server` does not speak h2 and the h2 arm is
# the point of the second half of this bench. It answers whatever stream a complete request
# arrives on (RFC 9113 §5.1.1: 1, 3, 5, …) — which is exactly what a one-stream-per-connection
# client could never exercise, and what `Repeater::H2Pool` now does.
private def start_h2_origin(tls : Bool) : {Int32, TCPServer}
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  ctx = nil.as(OpenSSL::SSL::Context::Server?)
  if tls
    cert, key = self_signed
    ctx = OpenSSL::SSL::Context::Server.new
    ctx.certificate_chain = cert
    ctx.private_key = key
    # ALPN "h2" — without it `H2Engine.open` refuses the connection it just made, which is the
    # correct behaviour and would measure nothing.
    ctx.alpn_protocol = "h2"
  end
  spawn do
    while conn = server.accept?
      # `spawn serve_h2(conn)`, NOT `spawn { serve_h2(conn) }`: the block form closes over the
      # loop VARIABLE, so a fiber that starts after the next `accept?` serves the next
      # connection and the one it was given is never read from at all — which shows up as
      # requests that wait out the client's whole 30s exchange budget.
      spawn serve_h2(conn, ctx)
    end
  rescue
  end
  {port, server}
end

private def serve_h2(conn : TCPSocket, ctx : OpenSSL::SSL::Context::Server?) : Nil
  conn.read_timeout = 10.seconds
  io = ctx ? OpenSSL::SSL::Socket::Server.new(conn, ctx, sync_close: true).as(IO) : conn.as(IO)
  Frame.read_preface(io)
  io.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
  io.flush
  enc = HPACK::Encoder.new
  dec = HPACK::Decoder.new
  loop do
    f = Frame.read(io)
    break if f.nil?
    next unless f.frame_type == Frame::Type::Headers && f.end_headers? && f.end_stream?
    dec.decode(f.payload)
    block = enc.encode([{":status", "200"}, {"content-type", "text/html"}])
    io.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, f.stream_id, block).to_bytes)
    io.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, f.stream_id, BODY.to_slice).to_bytes)
    io.flush
  end
rescue
ensure
  conn.close rescue nil
end

private def sweep(scheme : String, port : Int32, keep_alive : Bool, http2 : Bool = false) : Gori::Repeater::Pool?
  tmpl = F::Template.parse("GET /?q=§seed§ HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nAccept: */*\r\n\r\n")
  set = F::PayloadSet.new(F::InlineList.new((1..REQUESTS).map { |i| "word#{i}" }))
  cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: CONCURRENCY, keep_alive: keep_alive)
  sender = F::Sender.new(F::Origin.new(scheme, "127.0.0.1", port),
    Gori::Outbound.waived(nil, Gori::Outbound::Reason::NoProject),
    http2: http2, verify: false, keep_alive: keep_alive, idle_conns: CONCURRENCY)
  engine = F::Engine.new(F::Generator.new(tmpl, [set], cfg), F::Matcher.new, sender, cfg)
  engine.run { |_| }
  sender.pool
end

# `sweep` and then release its connections. Every timed report goes through this: a report
# that leaked its pool left up to CONCURRENCY idle sockets open for the rest of the bench,
# and with four arms that is a few hundred fds the later measurements run against.
private def timed_sweep(scheme : String, port : Int32, keep_alive : Bool, http2 : Bool = false) : Nil
  sweep(scheme, port, keep_alive, http2).try(&.close_all)
end

{"http", "https"}.each do |scheme|
  port, server = start_origin(scheme == "https")
  sleep 200.milliseconds # let the listener come up

  puts "\n== #{scheme} · #{REQUESTS} requests · concurrency #{CONCURRENCY}"
  Benchmark.bm do |x|
    x.report("OLD dial-per-request") { timed_sweep(scheme, port, false) }
    x.report("NEW keep-alive pool ") { timed_sweep(scheme, port, true) }
  end
  if pool = sweep(scheme, port, true)
    puts "   handshakes: #{pool.dialed} dialed, #{pool.reused} served off a parked socket"
    pool.close_all
  end
  server.close
end

# ── h2 ────────────────────────────────────────────────────────────────────────────────────
#
# The arm that was structurally impossible until `H2Pool`: `H2Engine.send` dialed, wrote the
# preface, used stream 1 and closed, so an h2 sweep paid a connection per payload — on the
# protocol `gori run fuzz` selects for itself whenever the seed flow was h2. Both transports
# are measured because they answer different questions: the cleartext arm isolates the TCP +
# preface + SETTINGS round, and the h2c-over-TLS arm is what a real origin costs, where every
# one of those dials also carries a full TLS handshake.
{false, true}.each do |tls|
  h2_port, h2_server = start_h2_origin(tls)
  sleep 200.milliseconds
  scheme = tls ? "https" : "http"

  puts "\n== h2 (#{tls ? "TLS" : "cleartext"}) · #{REQUESTS} requests · concurrency #{CONCURRENCY}"
  Benchmark.bm do |x|
    x.report("OLD connection-per-send") { timed_sweep(scheme, h2_port, false, http2: true) }
    x.report("NEW h2 connection reuse") { timed_sweep(scheme, h2_port, true, http2: true) }
  end
  if pool = sweep(scheme, h2_port, true, http2: true)
    puts "   handshakes: #{pool.dialed} dialed, #{pool.reused} served off a parked connection"
    pool.close_all
  end
  h2_server.close
end
