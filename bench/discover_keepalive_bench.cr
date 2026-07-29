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
#        the run pays ~concurrency handshakes per origin instead of ~N.
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

alias D = Gori::Discover

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

# Brute-force only: the spider's page count depends on the origin's links, and this bench is
# about how many handshakes N sends cost, not about how N is derived.
private def run_discover(scheme : String, port : Int32, keep_alive : Bool) : {Int64, D::Sender}
  cfg = D::Config.new(concurrency: 20, spider: false, bruteforce: true, retries: 0,
    max_depth: 0, containment: D::Containment::SameOrigin, keep_alive: keep_alive)
  sender = D::Sender.new(verify: false, timeout: 5.seconds,
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
