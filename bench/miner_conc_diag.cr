# Where does a mine's wall clock go, and what does the bisection branch factor cost?
#
# `miner_perf_bench` measures the TRANSPORT A/B (dial-per-send vs the keep-alive pool) but
# says its other half — the run's SCHEDULE — "is not an A/B here". This is that half. A mine
# is latency-bound and its critical path is the bisection tree's DEPTH, so the question that
# ranks every further optimization is: at a realistic RTT, is the worker pool SATURATED
# (cut requests) or STARVED waiting on the tree's tail (cut depth)?
#
# Part 1 wraps the send seam to timestamp every request and reports average in-flight
# concurrency = Σ(send durations) / wall. Against a fixed-delay origin that number is the
# answer: ≈ the configured concurrency means saturated; far below means depth-bound, and the
# n-ary split (Engine#split / BISECT_MAX_WAYS) is what lowers that floor.
#
# Part 2 answers the budget question the split raises: a wider split must never send MORE
# probes than binary, or a run under `--max-requests` finds fewer. It counts sends for a
# single 128-bucket across positive densities, binary (conc 2) vs 4-ary (conc 4).
#
# Build: crystal build bench/miner_conc_diag.cr -o bin/miner_conc_diag --release
# Run:   bin/miner_conc_diag
require "socket"
require "http/server"

module Gori
  class Error < Exception; end
end

require "../src/gori/bindings"
require "../src/gori/fuzz"
require "../src/gori/miner"
require "../src/gori/outbound"

alias M = Gori::Miner
alias F = Gori::Fuzz

SECRETS = {"debug", "admin", "callback", "redirect_url", "template"}
BODY    = "x" * 2048

# Timestamps every send that reaches the wire, as microsecond offsets from its own start.
class Recorder < F::Backend
  getter spans = [] of {Int64, Int64}
  getter baseline_mark = 0

  def initialize(@inner : F::Backend)
    @t0 = Time.instant
  end

  def origin : F::Origin
    @inner.origin
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    send(bytes, nil)
  end

  def send(bytes : Bytes, verbatim : Array({Int32, Int32})?) : Gori::Repeater::Result
    a = (Time.instant - @t0).total_microseconds.to_i64
    r = @inner.send(bytes, verbatim)
    @spans << {a, (Time.instant - @t0).total_microseconds.to_i64}
    r
  end

  def mark_baseline_done : Nil
    @baseline_mark = @spans.size
  end

  def evidence? : Bool
    @inner.evidence?
  end

  def blocked : Int64
    @inner.blocked
  end

  def blocked_reason : String?
    @inner.blocked_reason
  end

  def extra_requests : Int64
    @inner.extra_requests
  end

  def close : Nil
    @inner.close
  end
end

# Counts sends only — for the density/budget half. No socket.
class CountingBackend < F::Backend
  getter origin : F::Origin
  getter sent : Int32 = 0

  def initialize(@origin : F::Origin, @grow : Set(String))
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent += 1
    params = query_params(bytes)
    body = "BASELINE BODY CONTENT"
    body += " XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" if @grow.any? { |g| params.has_key?(g) }
    head = "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n".to_slice
    resp = Gori::Proxy::Codec::Http1.parse_response_head(head)
    Gori::Repeater::Result.new(head, body.to_slice, resp, 1000_i64)
  end

  private def query_params(bytes : Bytes) : Hash(String, String)
    pairs = Hash(String, String).new
    line = String.new(bytes).lines.first? || ""
    target = line.split(' ')[1]? || ""
    qi = target.index('?')
    return pairs unless qi
    target[(qi + 1)..].split('&').each do |pair|
      k, _, v = pair.partition('=')
      pairs[k] = v unless k.empty?
    end
    pairs
  end
end

private def start_origin(delay : Time::Span) : Int32
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
  port = server.bind_tcp("127.0.0.1", 0).port
  spawn { server.listen }
  port
end

private def run_mine(port : Int32, concurrency : Int32, locations : Array(M::Location)) : {Float64, Recorder, Int32}
  request = "GET /?q=1 HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nAccept: */*\r\nCookie: sid=1\r\n\r\n"
  config = M::Config.new(locations: locations, concurrency: concurrency, keep_alive: true)
  options = M::PlanOptions.new(request,
    target: "http://127.0.0.1:#{port}/", locations: locations, config: config, verify: false)
  plan = M::Plan.build(options, Gori::Outbound.waived(nil, Gori::Outbound::Reason::NoProject))
  rec = Recorder.new(plan.sender)
  engine = M::Engine.new(plan.request, false, plan.names, rec, config)
  found = 0
  t0 = Time.instant
  engine.run do |ev|
    case ev
    when M::BaselineEvent then rec.mark_baseline_done
    when M::DoneEvent     then found = ev.progress.found
    end
  end
  wall = (Time.instant - t0).total_milliseconds
  plan.sender.close
  {wall, rec, found}
end

private def report(label : String, wall : Float64, rec : Recorder, found : Int32, conc : Int32) : Nil
  spans = rec.spans
  busy = spans.sum { |(a, b)| (b - a) } / 1000.0
  avg = busy / wall
  puts "  #{label.ljust(24)} wall #{wall.round(1).to_s.rjust(7)}ms · #{spans.size.to_s.rjust(4)} reqs " \
       "(#{rec.baseline_mark} baseline) · #{found} found · avg in-flight #{avg.round(2).to_s.rjust(6)}/#{conc} " \
       "· util #{(100.0 * avg / conc).round(1)}%"
end

# ── Part 1: schedule / utilization vs concurrency ──────────────────────────────────────────
ALL = [M::Location::Query, M::Location::Headers, M::Location::Cookies]
puts "Part 1 — schedule: is the pool saturated (cut requests) or depth-bound (cut depth)?"
{20.milliseconds, 50.milliseconds}.each do |delay|
  port = start_origin(delay)
  sleep 200.milliseconds
  run_mine(port, 20, ALL) # warm-up
  puts "\n== origin delay #{delay.total_milliseconds}ms · query/headers/cookies =="
  {10, 20, 40}.each do |c|
    wall, rec, found = run_mine(port, c, ALL)
    report("concurrency #{c}", wall, rec, found, c)
  end
end

# ── Part 2: what the branch factor costs — sends by positive density ───────────────────────
def count_run(names : Array(String), grow : Set(String), conc : Int32) : {Int32, Int32}
  c = M::Config.new
  c.locations = [M::Location::Query]
  c.bucket_size = M::Config::DEFAULT_BUCKETS.dup
  c.bucket_size[M::Location::Query] = 128
  c.concurrency = conc
  c.stability_rounds = 2
  c.retries = 0
  base = "GET /api HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
  backend = CountingBackend.new(F::Origin.new("http", "h", 80), grow)
  engine = M::Engine.new(base, http2: false, names: names, backend: backend, config: c)
  found = 0
  engine.run { |ev| found += 1 if ev.is_a?(M::FindingEvent) }
  {backend.sent, found}
end

NAMES = (1..128).map { |i| "p#{i}" }
puts "\nPart 2 — budget: a wider split must never send MORE than binary (128-bucket)"
puts "  density   binary conc2   4-ary conc4   overage"
[1, 8, 32, 64, 128].each do |d|
  grow = NAMES.first(d).to_set
  bsent, bfound = count_run(NAMES, grow, 2)
  wsent, wfound = count_run(NAMES, grow, 4)
  over = wsent - bsent
  pct = bsent.zero? ? 0.0 : (100.0 * over / bsent)
  puts "  #{d.to_s.rjust(3)}/128    #{bsent.to_s.rjust(4)} (#{bfound.to_s.rjust(3)})     " \
       "#{wsent.to_s.rjust(4)} (#{wfound.to_s.rjust(3)})     #{over >= 0 ? "+" : ""}#{over} (#{pct.round(0)}%)"
end
