# Discover connection-reuse benchmark — the cost a run pays for its TRANSPORT, not its CPU.
#
# `discover_url_bench` measures the per-link string work, which is down in the microseconds.
# What a real run actually waits on is the connection: `Repeater::Engine.send` dialed a fresh
# one, exchanged ONE request and closed it (Discover even asked for that with `Connection:
# close`), so a run paid a TCP handshake — and on https a TLS handshake — per probe. The
# brute-forcer sends ~278 of those PER DIRECTORY, so the multiplier is the whole wordlist.
#
#   OLD: dial → exchange → close, per request.
#   NEW: a `Repeater::ConnPool` per origin parks the socket and the next probe reuses it, so
#        the run pays ~concurrency handshakes per origin instead of ~N. Under `--http2` the
#        same map holds a `Repeater::H2Pool` per origin (serial stream reuse), measured in the
#        second half against a minimal h2 origin.
#
# This is an END-TO-END measurement over loopback against a real keep-alive origin, so it
# understates the win: with RTT ≈ 0 the handshake costs only syscalls and (for TLS) CPU,
# where a remote origin also pays 2-3 round trips per request. Both an http and an https
# origin are measured because the TLS handshake is where the gap is widest.
#
# Build: crystal build bench/discover_keepalive_bench.cr -o bin/discover_keepalive_bench --release
# Run:   bin/discover_keepalive_bench
require "benchmark"
require "socket"
require "openssl"
require "http/server"

# `Gori::Error` (src/gori.cr) is what the codec requires below raise; declare it first, like
# the other benches, instead of pulling the whole binary in.
module Gori
  class Error < Exception; end
end

require "../src/gori/discover/engine"
require "../src/gori/discover/wordlist"
# `Env.expand_bindings` (reached from `Sender#binding_headers`) calls `Bindings.boundary_forging?`,
# and `env.cr` cannot require `bindings.cr` back without a cycle — so a partial build that stops at
# the engine leaves the constant undefined. The full binary always has it; name it here so the
# bench does too.
require "../src/gori/bindings"

alias D = Gori::Discover
alias Frame = Gori::Proxy::H2::Frame
alias HPACK = Gori::Proxy::H2::HPACK

WORDS = D::Wordlist.builtin
BODY  = "<html><body>" + ("x" * 1024) + "</body></html>"

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

# 404s everything but "/" — a `normal` soft-404 baseline, so the brute-forcer runs its whole
# wordlist and reports nothing, which is the shape being timed.
private def start_origin(tls : Bool) : Int32
  server = HTTP::Server.new do |ctx|
    ctx.response.status_code = 404 unless ctx.request.path == "/"
    ctx.response.content_type = "text/html"
    ctx.response.print BODY
  end
  port = if tls
           cert, key = self_signed
           c = OpenSSL::SSL::Context::Server.new
           c.certificate_chain = cert
           c.private_key = key
           server.bind_tls("127.0.0.1", 0, c).port
         else
           server.bind_tcp("127.0.0.1", 0).port
         end
  spawn { server.listen }
  port
end

# A minimal h2 origin (`HTTP::Server` does not speak h2) with the same 404-everything-but-"/"
# shape as `start_origin`, so calibration settles and the brute-forcer runs its whole list.
# Same shape as bench/fuzz_keepalive_bench.cr's, which answers 200 to everything.
private def start_h2_origin(tls : Bool) : {Int32, TCPServer}
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  ctx = nil.as(OpenSSL::SSL::Context::Server?)
  if tls
    cert, key = self_signed
    ctx = OpenSSL::SSL::Context::Server.new
    ctx.certificate_chain = cert
    ctx.private_key = key
    ctx.alpn_protocol = "h2" # without it `H2Engine.open` refuses the connection
  end
  spawn do
    while conn = server.accept?
      spawn serve_h2(conn, ctx) # not `spawn { … }` — no loop-variable capture
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
    path = dec.decode(f.payload).find { |(n, _)| n == ":path" }.try(&.[1])
    status = path == "/" ? "200" : "404"
    block = enc.encode([{":status", status}, {"content-type", "text/html"}])
    io.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, f.stream_id, block).to_bytes)
    io.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, f.stream_id, BODY.to_slice).to_bytes)
    io.flush
  end
rescue
ensure
  conn.close rescue nil
end

# Brute-force only: the spider's page count depends on the origin's links, and this bench is
# about how many handshakes N sends cost, not about how N is derived.
private def run_discover(scheme : String, port : Int32, keep_alive : Bool,
                         http2 : Bool = false) : {Int64, D::Sender}
  cfg = D::Config.new(concurrency: 20, spider: false, bruteforce: true, retries: 0,
    max_depth: 0, containment: D::Containment::SameOrigin, keep_alive: keep_alive)
  sender = D::Sender.new(verify: false, timeout: 5.seconds, http2: http2,
    keep_alive: keep_alive, idle_conns: cfg.concurrency)
  engine = D::Engine.new("#{scheme}://127.0.0.1:#{port}/", WORDS, sender, cfg)
  sent = 0_i64
  engine.run { |ev| sent = ev.progress.sent if ev.is_a?(D::DoneEvent) }
  {sent, sender}
end

{"http", "https"}.each do |scheme|
  port = start_origin(scheme == "https")
  sleep 300.milliseconds # let the listener come up

  sent, _ = run_discover(scheme, port, true) # warm: the first run pays process-start noise
  puts "\n== #{scheme} · #{sent} requests · concurrency 20"
  Benchmark.bm do |x|
    x.report("OLD dial-per-request") { run_discover(scheme, port, false) }
    x.report("NEW keep-alive pool ") { run_discover(scheme, port, true) }
  end
  _, sender = run_discover(scheme, port, true)
  if stats = sender.pool_stats
    puts "   handshakes: #{stats.dialed} dialed, #{stats.reused} served off a parked socket"
  end
end

# ── h2 ────────────────────────────────────────────────────────────────────────────────────
#
# `--http2` used to switch keep-alive off outright, so an h2 run paid a TCP handshake, an h2
# preface round and (on https) a TLS handshake per probe. Cleartext isolates the first two;
# the TLS arm is what a real h2 origin costs.
{false, true}.each do |tls|
  port, server = start_h2_origin(tls)
  sleep 200.milliseconds
  scheme = tls ? "https" : "http"

  sent, warm = run_discover(scheme, port, true, http2: true)
  warm.close
  puts "\n== h2 (#{tls ? "TLS" : "cleartext"}) · #{sent} requests · concurrency 20"
  Benchmark.bm do |x|
    x.report("OLD connection-per-send") { run_discover(scheme, port, false, http2: true)[1].close }
    x.report("NEW h2 connection reuse") { run_discover(scheme, port, true, http2: true)[1].close }
  end
  _, sender = run_discover(scheme, port, true, http2: true)
  if stats = sender.pool_stats
    puts "   handshakes: #{stats.dialed} dialed, #{stats.reused} served off a parked connection"
  end
  sender.close
  server.close
end
