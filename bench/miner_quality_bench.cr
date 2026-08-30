# Param-miner QUALITY + COST harness: what a mine FINDS, and what it costs to find it.
#
# `miner_perf_bench` measures the transport (keep-alive) and the run's schedule;
# `miner_inject_bench` and `miner_reflect_bench` measure per-request CPU. None of them answers
# the two questions an operator actually has: did the mine report the parameters that exist
# and nothing else (FP/FN), and how many requests did it burn getting there.
#
# A mine is LATENCY-bound, so REQUESTS SENT is the honest cost number here — wall clock
# against an in-process loopback origin is mostly scheduler noise. Each origin below is a
# server behaviour that is ordinary on the real internet and that the bucketing, the
# calibration and the bisection all have to survive:
#
#   clean page             a static page. The control case: nothing must regress here.
#   param-count reactive   "N filters applied" — the body reacts to HOW MANY parameters
#                          arrived, which is what a width-matched control cancels.
#   jittery body           a rotating element, so the length band is wide and noisy while the
#                          count metrics stay quiet. Tests which metric the verdict comes from.
#   echoes param names     the page prints back what it received, so the byte count moves with
#                          the NAMES gori chose — the correction `Reference#echo` measures.
#   400 over 100 params    a max_input_vars ceiling. The width has to come down before mining.
#   oversized-cookie 400   the same refusal by header BYTES rather than by count.
#   403 on any unknown     a WAF that rejects every request carrying a name it does not know,
#                          at every width — there is no anchor here, and inventing one reports
#                          the whole wordlist. The number to read on this row is FP.
#   bytes-only reaction    a JSON API that names back the keys it did not recognise, on one
#                          line: length moves on every probe, words and lines do not.
#
# Each origin hides the same five parameters, taken from the built-in wordlist, and each hit
# is worth ~4% of the page — a modest signal, deliberately: one worth 30% would be found by
# any comparison at all and would measure nothing.
#
# Build: crystal build bench/miner_quality_bench.cr -o bin/miner_quality_bench --release
# Run:   bin/miner_quality_bench          (repeat it — two of the origins are stochastic)
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

CONCURRENCY = 20
FILLER      = "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod\n"
PAGE        = FILLER * 30 # ~2 KB of ordinary body
HIT         = "secret parameter accepted\nvalue applied to this request\nsee the audit log\n"

SECRETS = ["debug", "admin", "callback", "template", "redirect_url"]

record Outcome, sent : Int64, found : Array(String), errors : Int64, elapsed : Time::Span

# How many of the hidden parameters this request carried. Cookies are parsed into NAMES:
# `cookie.includes?("admin=")` also matches `is_admin=`, which would score the miner against a
# bug in this file rather than one in the miner.
private def hits_in(ctx : HTTP::Server::Context) : Int32
  q = ctx.request.query_params
  cookie = ctx.request.headers["Cookie"]? || ""
  names = cookie.split(';').compact_map { |c| c.split('=', 2)[0]?.try(&.strip) }
  SECRETS.count { |s| q.has_key?(s) || names.includes?(s) }
end

# The body each origin returns, minus the hit marker.
private def page_for(mode : Symbol, q : URI::Params) : String
  String.build do |io|
    io << PAGE
    case mode
    when :width, :widecap
      # A "N filters applied" counter: the page reacts to the NUMBER of query parameters and
      # to nothing else. Common (search UIs, error pages that list what was received).
      io << "applied " << q.size << " filters\n"
      q.size.times { |i| io << "filter row " << i << "\n" }
    when :bytesonly
      # Length moves with the parameters; the counts do not (one line, no spaces).
      io << "unknown:" << q.join(",") { |k, _| k } << "\n"
    when :echo
      # A canonical link / "you searched for" page: the parameter NAMES are printed back, so
      # the byte count moves with the names, not only with how many there were.
      q.each { |k, _| io << "seen " << k << "\n" }
    when :noisy
      # An ad slot / rotating token: the body jitters on every request.
      io << Random.rand(400).times.join("") { "n" } << "\n"
    end
  end
end

# nil when the origin accepts the request, or the refusal to send instead.
private def refusal_for(mode : Symbol, ctx : HTTP::Server::Context) : String?
  case mode
  when :wafall
    # Rejects any parameter it has never heard of — gori's control names included, at every
    # width the walk can reach.
    unknown = ctx.request.query_params.any? { |k, _| k != "q" && !SECRETS.includes?(k) }
    "request blocked" if unknown
  when :widecap
    "too many parameters" if ctx.request.query_params.size >= 100
  when :cookiecap
    # nginx/haproxy-style refusal of an oversized header set: a property of the bucket's
    # width, never of any name inside it.
    "Request Header Or Cookie Too Large" if (ctx.request.headers["Cookie"]? || "").bytesize > 512
  end
end

private def start_origin(mode : Symbol) : Int32
  server = HTTP::Server.new do |ctx|
    if refused = refusal_for(mode, ctx)
      ctx.response.status_code = 400
      ctx.response.print refused
    else
      ctx.response.content_type = "text/html"
      ctx.response.print page_for(mode, ctx.request.query_params)
      hits_in(ctx).times { ctx.response.print HIT }
    end
  end
  port = server.bind_tcp("127.0.0.1", 0).port
  spawn { server.listen }
  port
end

private def mine(port : Int32, locations : Array(M::Location)) : Outcome
  request = "GET /?q=1 HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nAccept: */*\r\nCookie: sid=1\r\n\r\n"
  config = M::Config.new(locations: locations, concurrency: CONCURRENCY, keep_alive: true)
  options = M::PlanOptions.new(request,
    target: "http://127.0.0.1:#{port}/", locations: locations, config: config, verify: false)
  plan = M::Plan.build(options, Gori::Outbound.waived(nil, Gori::Outbound::Reason::NoProject))
  sent = 0_i64
  errors = 0_i64
  found = [] of String
  started = Time.instant
  plan.engine.run do |ev|
    case ev
    when M::FindingEvent then found << ev.finding.name
    when M::DoneEvent    then sent = ev.progress.sent; errors = ev.progress.errors
    end
  end
  elapsed = Time.instant - started
  plan.sender.close
  Outcome.new(sent, found.uniq!, errors, elapsed)
end

private def report(label : String, res : Outcome) : Nil
  tp = res.found & SECRETS
  fp = res.found - SECRETS
  fn = SECRETS - res.found
  puts "  #{label.ljust(22)} sent #{res.sent.to_s.rjust(5)} · " \
       "TP #{tp.size}/#{SECRETS.size} · FP #{fp.size} · errors #{res.errors} · " \
       "#{res.elapsed.total_milliseconds.round(0).to_i}ms"
  puts "      missed: #{fn.join(", ")}" unless fn.empty?
  puts "      false:  #{fp.first(8).join(", ")}#{fp.size > 8 ? " …" : ""}" unless fp.empty?
end

QUERY   = [M::Location::Query]
COOKIES = [M::Location::Cookies]

CASES = [
  {:clean, "clean page", QUERY},
  {:width, "param-count reactive", QUERY},
  {:noisy, "jittery body", QUERY},
  {:echo, "echoes param names", QUERY},
  {:widecap, "400 over 100 params", QUERY},
  {:cookiecap, "oversized-cookie 400", COOKIES},
  {:wafall, "403 on any unknown", QUERY},
  {:bytesonly, "bytes-only reaction", QUERY},
]

puts "Miner quality + cost (concurrency #{CONCURRENCY}, built-in wordlist)"
CASES.each do |(mode, label, locs)|
  port = start_origin(mode.as(Symbol))
  sleep 150.milliseconds
  locations = locs.as(Array(M::Location))
  mine(port, locations) # warm-up: lazy wordlist parse, first dial
  report(label.as(String), mine(port, locations))
end
