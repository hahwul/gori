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

require "../src/gori/fuzz"
require "../src/gori/outbound"

alias F = Gori::Fuzz

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

private def start_origin(tls : Bool) : Int32
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
  port
end

private def sweep(scheme : String, port : Int32, keep_alive : Bool) : F::ConnPool?
  tmpl = F::Template.parse("GET /?q=§seed§ HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nAccept: */*\r\n\r\n")
  set = F::PayloadSet.new(F::InlineList.new((1..REQUESTS).map { |i| "word#{i}" }))
  cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: CONCURRENCY, keep_alive: keep_alive)
  sender = F::Sender.new(F::Origin.new(scheme, "127.0.0.1", port),
    Gori::Outbound.waived(nil, Gori::Outbound::Reason::NoProject),
    http2: false, verify: false, keep_alive: keep_alive, idle_conns: CONCURRENCY)
  engine = F::Engine.new(F::Generator.new(tmpl, [set], cfg), F::Matcher.new, sender, cfg)
  engine.run { |_| }
  sender.pool
end

{"http", "https"}.each do |scheme|
  port = start_origin(scheme == "https")
  sleep 200.milliseconds # let the listener come up

  puts "\n== #{scheme} · #{REQUESTS} requests · concurrency #{CONCURRENCY}"
  Benchmark.bm do |x|
    x.report("OLD dial-per-request") { sweep(scheme, port, false) }
    x.report("NEW keep-alive pool ") { sweep(scheme, port, true) }
  end
  if pool = sweep(scheme, port, true)
    puts "   handshakes: #{pool.dialed} dialed, #{pool.reused} served off a parked socket"
  end
end
