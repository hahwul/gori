# Param-miner end-to-end benchmark — what a mine costs that is NOT per-response CPU.
#
# `miner_inject_bench` and `miner_reflect_bench` already cover the per-request code paths
# (they are microseconds). A real mine waits on its TRANSPORT: every send dialed a fresh
# connection, so an N-request mine paid N TCP handshakes and, on https, N TLS handshakes.
# Same fact `fuzz_keepalive_bench` measured for the sweep senders; the miner was left on
# `keep_alive: false`. The two columns below are that, with everything else held equal.
#
# The wall-clock TOTAL also carries the run's SCHEDULE — every location's buckets share one
# work queue, so the mine is not serialised per location and the 1-2-bucket tail of a
# bisection no longer idles the pool. That half is not an A/B here (it is not a flag); to
# measure it, run this binary against the previous build of the engine.
#
# Both costs are LATENCY, so a loopback origin understates them: with RTT ~ 0 a handshake is
# only syscalls plus (for https) crypto, and an idle worker costs nothing a stopwatch on
# localhost can see. The last origin below adds a fixed per-request server delay to stand in
# for the round trip a real target charges; read all three.
#
# Build: crystal build bench/miner_perf_bench.cr -o bin/miner_perf_bench --release
# Run:   bin/miner_perf_bench
require "benchmark"
require "socket"
require "openssl"
require "http/server"

# `Gori::Error` (src/gori.cr) is what the codec/decoder requires below raise; declare it
# first, as the other benches do, instead of pulling the whole binary in.
module Gori
  class Error < Exception; end
end

require "../src/gori/bindings"
require "../src/gori/fuzz"
require "../src/gori/miner"
require "../src/gori/outbound"

alias M = Gori::Miner

CONCURRENCY = 20
BODY        = "x" * 2048

# Parameters the origin secretly accepts — they make the run BISECT, which is what a real
# mine's request count is made of. Names taken from the built-in wordlist.
SECRETS = {"debug", "admin", "callback", "redirect_url", "template"}

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

# An origin that reacts to a secret parameter at ANY of the three mined locations: query,
# header, cookie. A hit lengthens the body, which is the metric-diff signal the miner
# bisects for; everything else gets the identical baseline page.
private def start_origin(tls : Bool, delay : Time::Span) : Int32
  server = HTTP::Server.new do |ctx|
    sleep delay if delay > Time::Span.zero
    hits = 0
    q = ctx.request.query_params
    SECRETS.each { |s| hits += 1 if q.has_key?(s) }
    ctx.request.headers.each { |name, _| hits += 1 if SECRETS.includes?(name.downcase) }
    if cookie = ctx.request.headers["Cookie"]?
      SECRETS.each { |s| hits += 1 if cookie.includes?("#{s}=") }
    end
    ctx.response.content_type = "text/html"
    ctx.response.print BODY
    hits.times { ctx.response.print "\nsecret parameter accepted\n" }
  end
  port = if tls
           cert, key = self_signed
           tls_ctx = OpenSSL::SSL::Context::Server.new
           tls_ctx.certificate_chain = cert
           tls_ctx.private_key = key
           server.bind_tls("127.0.0.1", 0, tls_ctx).port
         else
           server.bind_tcp("127.0.0.1", 0).port
         end
  spawn { server.listen }
  port
end

private def mine(scheme : String, port : Int32, keep_alive : Bool) : {Int64, Int32, Gori::Repeater::Pool?}
  request = "GET /?q=1 HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nAccept: */*\r\nCookie: sid=1\r\n\r\n"
  config = M::Config.new(
    locations: [M::Location::Query, M::Location::Headers, M::Location::Cookies],
    concurrency: CONCURRENCY, keep_alive: keep_alive)
  options = M::PlanOptions.new(request,
    target: "#{scheme}://127.0.0.1:#{port}/", locations: config.locations, config: config, verify: false)
  plan = M::Plan.build(options, Gori::Outbound.waived(nil, Gori::Outbound::Reason::NoProject))
  sent = 0_i64
  found = 0
  plan.engine.run do |ev|
    case ev
    when M::DoneEvent then sent = ev.progress.sent; found = ev.progress.found
    end
  end
  plan.sender.close
  {sent, found, plan.sender.pool}
end

# One warm-up mine per origin: the first run of the process pays lazy wordlist parsing and
# the TLS context setup, which would otherwise land entirely on whichever column runs first.
{ {"http", 0.milliseconds}, {"https", 0.milliseconds}, {"http", 2.milliseconds} }.each do |(scheme, delay)|
  port = start_origin(scheme == "https", delay)
  sleep 200.milliseconds # let the listener come up
  mine(scheme, port, true)

  sent, found, _ = mine(scheme, port, false)
  puts "\n== #{scheme} · origin delay #{delay.total_milliseconds}ms · concurrency #{CONCURRENCY} " \
       "· query/headers/cookies · #{sent} requests · #{found} params found"
  Benchmark.bm do |x|
    x.report("dial-per-request") { mine(scheme, port, false) }
    x.report("keep-alive pool ") { mine(scheme, port, true) }
  end
  if pool = mine(scheme, port, true)[2]
    puts "   handshakes: #{pool.dialed} dialed, #{pool.reused} served off a parked socket"
  end
end
