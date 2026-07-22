require "uri"
require "../repeater/engine"
require "../repeater/h2_engine"
require "../scope"

module Gori::Fuzz
  # The origin a run targets (also the boundary for redirect following).
  record Origin, scheme : String, host : String, port : Int32

  # The send seam. Swappable so specs (and the baseline calibrator) can drive the
  # engine without a real socket.
  abstract class Backend
    abstract def send(bytes : Bytes) : Repeater::Result
    abstract def origin : Origin
  end

  # Production backend over the Repeater engines (fresh connection per send — there is
  # no upstream pool; worker count == max simultaneous connections).
  class Sender < Backend
    getter origin : Origin

    def initialize(@origin : Origin, @http2 : Bool, @verify : Bool,
                   @sni : String? = nil, @timeout : Time::Span? = nil)
    end

    def send(bytes : Bytes) : Repeater::Result
      if @http2
        Repeater::H2Engine.send(bytes, scheme: @origin.scheme, host: @origin.host,
          port: @origin.port, verify_upstream: @verify, sni: @sni, timeout: @timeout)
      else
        Repeater::Engine.send(bytes, scheme: @origin.scheme, host: @origin.host,
          port: @origin.port, verify_upstream: @verify, sni: @sni, timeout: @timeout)
      end
    end
  end

  # Enforces a HARD ceiling on the total number of real network sends. Wraps any Backend
  # and, past the cap, returns a benign error Result WITHOUT touching the network — so
  # retries, redirect hops, and baseline calibration all count against `max_requests`,
  # unlike a dispatch-only check (which counts one-per-payload and overshoots). A nil or
  # non-positive cap is a pass-through no-op. (Shared by the fuzzer and the param-miner.)
  class CappedBackend < Backend
    # Stable error string so run_one can skip retries on a permanent budget stop.
    CAP_ERROR = "max-requests cap reached"

    getter sent : Int64 = 0_i64

    def initialize(@inner : Backend, @cap : Int64?)
    end

    def origin : Origin
      @inner.origin
    end

    def cap_reached? : Bool
      (c = @cap) && c > 0 ? @sent >= c : false
    end

    def send(bytes : Bytes) : Repeater::Result
      return Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, CAP_ERROR) if cap_reached?
      @sent += 1
      @inner.send(bytes)
    end
  end

  # Refuses to send when the target falls outside the project's Scope (a sandbox
  # block or an explicit exclude rule) — the same per-request gate Discover applies
  # via `bounded_url` (discover/adapters.cr). Fuzz and Miner otherwise dial a
  # Backend directly with no Scope awareness, so Sandbox mode's "blocks ALL
  # out-of-scope traffic" promise didn't hold for either tool. Wrap OUTERMOST
  # (around CappedBackend) so a blocked attempt never reaches the network — the
  # request budget is still spent on it, same as CappedBackend already does for
  # retries/redirects, rather than adding a second accounting path.
  class ScopedBackend < Backend
    SCOPE_ERROR = "blocked by scope"

    getter blocked : Int64 = 0_i64

    def initialize(@inner : Backend, @scope : Gori::Scope)
    end

    def origin : Origin
      @inner.origin
    end

    def send(bytes : Bytes) : Repeater::Result
      o = origin
      url = "#{o.scheme}://#{o.host}#{request_target(bytes)}"
      if @scope.sandbox_blocks?(url, o.host) || @scope.excluded?(url, o.host)
        @blocked += 1
        return Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, SCOPE_ERROR)
      end
      @inner.send(bytes)
    end

    # The request-target (path) from the first line of a raw request, mirroring
    # mcp/tools/send.cr#request_target — builds the scheme://host/target URL the
    # scope string/regex rules match against.
    private def request_target(bytes : Bytes) : String
      line = String.new(bytes).each_line.first? || ""
      line.split(' ')[1]? || "/"
    end
  end

  # Runs a generator's jobs concurrently and streams events. Concurrency model
  # (single-threaded fiber scheduler — no `-Dpreview_mt` — so plain ivars need no
  # locking):
  #   dispatcher fiber  — owns the rate-limit clock; pulls jobs, paces, enqueues onto
  #                       the BOUNDED @jobs channel (which IS the concurrency cap:
  #                       a send blocks when all workers are busy → backpressure).
  #   worker fibers ×N  — receive a job, send it (with retries / redirects), build the
  #                       Result, push it to @events with a BLOCKING send (never drop).
  #   coordinator fiber — waits for all workers to finish, emits Done, closes @events.
  # Progress events are droppable (latest wins); Result/Done/Error are not.
  class Engine
    EVENT_BUFFER    =  256
    MAX_CONCURRENCY = 1000 # hard ceiling on worker fibers / channel capacity
    # Synthetic baseline requests sent before the sweep when auto-calibration is on (see
    # calibrate_baseline). A single exact-match snapshot can't tell a target's ordinary
    # per-request variability apart from a genuine anomaly; a handful of staggered,
    # randomly-payloaded samples can, at the cost of this many extra sends up front.
    CALIBRATION_SAMPLES = 6

    enum State : UInt8
      Running
      Paused
      Stopped
    end

    # Thrown inside the captured generation block to halt it (a captured block can't
    # `break`). Unwinds the generator's iterator `ensure`s, so file fds still close.
    private class Halt < Exception
    end

    getter events : Channel(Event)

    @backend : Backend
    @concurrency : Int32
    @state : State
    @wake : Channel(Nil)
    @jobs : Channel(Job)
    @finished : Channel(Nil)
    @sent : Int64
    @matched : Int64
    @errors : Int64
    @dispatched : Int64
    @last_dispatch : Time::Instant
    @total : Int64?
    @total_computed : Bool

    def initialize(@generator : Generator, @matcher : Matcher, backend : Backend, @config : Config)
      # Wrap so max_requests is a TRUE hard cap on real sends — retries, redirect hops and
      # baseline calibration all count, not just one-per-dispatched-payload (nil cap = no-op).
      @backend = CappedBackend.new(backend, @config.max_requests)
      # Clamp here (the deepest point) so no frontend can spawn an OOM-sized fiber +
      # channel fleet — the CLI's --concurrency is otherwise unbounded.
      conc = @config.concurrency.clamp(1, MAX_CONCURRENCY)
      @concurrency = conc
      @state = State::Running
      @wake = Channel(Nil).new(1)
      @jobs = Channel(Job).new(conc)
      @events = Channel(Event).new(EVENT_BUFFER)
      @finished = Channel(Nil).new(conc)
      @sent = 0_i64
      @matched = 0_i64
      @errors = 0_i64
      @dispatched = 0_i64
      @last_dispatch = Time.instant
      @total = nil.as(Int64?)
      @total_computed = false
    end

    # Total request count (memoized). Computing it also opens/counts wordlists, which
    # surfaces a missing/unreadable file before any worker spawns.
    def total : Int64?
      unless @total_computed
        @total = @generator.total
        @total_computed = true
      end
      @total
    end

    # Seed the matcher's calibration set from CALIBRATION_SAMPLES synthetic,
    # randomly-payloaded requests (see Generator#calibration_requests and
    # Matcher.reflects_length?) — replaces the old single-snapshot baseline, which a
    # target with ANY legitimate per-request variability (a nonce, rotating content, a
    # reflected parameter) trivially defeated. Optional; call before `start`. Every
    # send routes through @backend like any other, so calibration sends still count
    # against a configured max_requests cap; under a tight cap, sample count is
    # trimmed so at least one send is left for the sweep itself. A failed/empty
    # calibration is non-fatal — auto_calibrate then simply suppresses nothing.
    def calibrate_baseline : Nil
      wanted = CALIBRATION_SAMPLES
      if (cap = @config.max_requests) && cap > 0 && cap - 1 < wanted
        wanted = Math.max(cap - 1, 1_i64).to_i32
      end
      samples = [] of BaselineSample
      @generator.calibration_requests(wanted).each do |bytes, payload_len|
        raw = @backend.send(bytes)
        samples << BaselineSample.new(@matcher.metrics(raw), payload_len) if raw.error.nil?
      end
      @matcher.baseline = samples
    rescue
      # a failed baseline is non-fatal — just skip calibration
    end

    def start : Nil
      begin
        total # pre-flight (may raise on a bad wordlist)
      rescue ex
        @events.send(ErrorEvent.new(ex.message || "fuzz setup error"))
        @events.send(DoneEvent.new(Progress.new(0, nil, 0, 0), false))
        @events.close
        return
      end
      spawn(name: "fuzz-dispatch") { dispatch_loop }
      @concurrency.times { |i| spawn(name: "fuzz-worker-#{i}") { worker_loop } }
      spawn(name: "fuzz-coord") { coordinate }
    end

    # Blocking drain — for synchronous consumers (CLI, the MCP background fiber).
    def run(& : Event ->) : Nil
      start
      while ev = @events.receive?
        yield ev
      end
    end

    def stop : Nil
      @state = State::Stopped
      poke
    end

    def pause : Nil
      @state = State::Paused
    end

    def resume : Nil
      @state = State::Running
      poke
    end

    def stopped? : Bool
      @state == State::Stopped
    end

    # ── fibers ─────────────────────────────────────────────────────────────────

    private def dispatch_loop : Nil
      interval = pace_interval
      @generator.each do |job|
        raise Halt.new if @state == State::Stopped
        park_if_paused
        raise Halt.new if @state == State::Stopped
        # Soft job-count check (cheap) plus the hard real-send ceiling: retries/redirects
        # can exhaust CappedBackend mid-run while @dispatched is still under cap.
        raise Halt.new if (cap = @config.max_requests) && cap > 0 && @dispatched >= cap
        raise Halt.new if (b = @backend).is_a?(CappedBackend) && b.cap_reached?
        pace(interval)
        @jobs.send(job)
        @dispatched += 1
      end
    rescue Halt
      # graceful stop or request cap reached
    rescue ex
      @events.send(ErrorEvent.new(ex.message || "fuzz generation error"))
    ensure
      @jobs.close
    end

    private def worker_loop : Nil
      while job = @jobs.receive?
        # On stop, drain the jobs still buffered in the channel WITHOUT sending them.
        # The channel is buffered to `conc` on top of `conc` busy workers, so without
        # this the operator's stop still fired ~2x concurrency of extra requests; now
        # only the requests already in-flight (inside run_one) finish, matching the
        # documented "in-flight requests finish".
        next if @state == State::Stopped
        result = run_one(job)
        @sent += 1
        @matched += 1 if result.matched?
        @errors += 1 if result.error
        @events.send(ResultEvent.new(result)) # blocking — never drop a row
        emit_progress
      end
    ensure
      @finished.send(nil)
    end

    private def coordinate : Nil
      @concurrency.times { @finished.receive }
      @events.send(DoneEvent.new(snapshot, @state == State::Stopped))
      @events.close
    end

    # ── per-request ──────────────────────────────────────────────────────────────

    private def run_one(job : Job) : Result
      attempts = 0
      loop do
        raw = @backend.send(job.bytes)
        # Don't burn retries/sleep on a permanent max-requests stop — further send()s
        # are also refused. Real network errors still retry as configured.
        if raw.error && raw.error != CappedBackend::CAP_ERROR && attempts < @config.retries
          attempts += 1
          sleep @config.retry_pause
          next
        end
        raw = follow_redirects(raw) if @config.follow_redirects? && raw.error.nil?
        return @matcher.build(job, raw)
      end
    end

    # Follow up to max_redirects SAME-ORIGIN redirects (relative, or absolute to the
    # same scheme/host/port), re-issuing a GET. Cross-origin redirects are left as the
    # final 3xx (no implicit off-target sends).
    private def follow_redirects(raw : Repeater::Result) : Repeater::Result
      current = raw
      total_us = raw.duration_us
      hops = 0
      while hops < @config.max_redirects
        resp = current.response
        break unless resp && (300..399).includes?(resp.status)
        loc = resp.headers.get?("location")
        break unless loc
        nxt = redirect_request(loc)
        break unless nxt
        current = @backend.send(nxt)
        total_us += current.duration_us
        hops += 1
        break unless current.error.nil?
      end
      # Report the whole chain's end-to-end time, not just the final hop's — otherwise a
      # slow original request that 3xx's to a fast resource masks a time-based signal.
      hops > 0 ? Repeater::Result.new(current.head, current.body, current.response, total_us, current.error, current.incomplete?) : current
    end

    private def redirect_request(loc : String) : Bytes?
      o = @backend.origin
      path = resolve_redirect_path(loc, o)
      return nil unless path
      default = o.scheme == "https" ? 443 : 80
      host = o.port == default ? o.host : "#{o.host}:#{o.port}"
      "GET #{path} HTTP/1.1\r\nHost: #{host}\r\nConnection: close\r\n\r\n".to_slice
    end

    # The same-origin path to follow a Location to, or nil for cross-origin / unparsable.
    private def resolve_redirect_path(loc : String, o : Origin) : String?
      return loc if loc.starts_with?('/')
      return nil unless loc.starts_with?("http://") || loc.starts_with?("https://")
      uri = URI.parse(loc) rescue nil
      return nil unless uri && uri.host == o.host
      sc = uri.scheme || "http"
      pt = uri.port || (sc == "https" ? 443 : 80)
      return nil unless sc == o.scheme && pt == o.port
      p = uri.path
      p = "/" if p.empty?
      uri.query ? "#{p}?#{uri.query}" : p
    end

    # ── rate limiting (dispatcher-local clock → no cross-fiber race) ─────────────

    private def pace_interval : Time::Span?
      if (rps = @config.rps) && rps > 0
        (1.0 / rps).seconds
      elsif (t = @config.throttle_ms) && t > 0
        t.milliseconds
      else
        nil
      end
    end

    private def pace(interval : Time::Span?) : Nil
      if interval
        now = Time.instant
        target = @last_dispatch + interval
        sleep(target - now) if now < target
        @last_dispatch = Time.instant
      end
      # Jitter applies on its own — don't gate it behind a base rate, which silently
      # dropped jitter unless rps/throttle was also set.
      sleep(rand(@config.jitter_ms).milliseconds) if @config.jitter_ms > 0
    end

    private def park_if_paused : Nil
      while @state == State::Paused
        @wake.receive
      end
    end

    private def poke : Nil
      select
      when @wake.send(nil)
      else
      end
    end

    private def emit_progress : Nil
      ev = ProgressEvent.new(snapshot)
      select
      when @events.send(ev)
      else
      end
    end

    private def snapshot : Progress
      Progress.new(@sent, total, @matched, @errors)
    end
  end
end
