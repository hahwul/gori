require "uri"
require "../replay/engine"
require "../replay/h2_engine"

module Gori::Fuzz
  # The origin a run targets (also the boundary for redirect following).
  record Origin, scheme : String, host : String, port : Int32

  # The send seam. Swappable so specs (and the baseline calibrator) can drive the
  # engine without a real socket.
  abstract class Backend
    abstract def send(bytes : Bytes) : Replay::Result
    abstract def origin : Origin
  end

  # Production backend over the Replay engines (fresh connection per send — there is
  # no upstream pool; worker count == max simultaneous connections).
  class Sender < Backend
    getter origin : Origin

    def initialize(@origin : Origin, @http2 : Bool, @verify : Bool,
                   @sni : String? = nil, @timeout : Time::Span? = nil)
    end

    def send(bytes : Bytes) : Replay::Result
      if @http2
        Replay::H2Engine.send(bytes, scheme: @origin.scheme, host: @origin.host,
          port: @origin.port, verify_upstream: @verify, sni: @sni, timeout: @timeout)
      else
        Replay::Engine.send(bytes, scheme: @origin.scheme, host: @origin.host,
          port: @origin.port, verify_upstream: @verify, sni: @sni, timeout: @timeout)
      end
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
    EVENT_BUFFER = 256

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

    def initialize(@generator : Generator, @matcher : Matcher, @backend : Backend, @config : Config)
      conc = @config.concurrency < 1 ? 1 : @config.concurrency
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

    # Seed the baseline metrics from the unmodified request (all-defaults), for
    # anomaly diffing / auto-calibration. Optional; call before `start`.
    def calibrate_baseline : Nil
      raw = @backend.send(@generator.baseline_request)
      @matcher.baseline = @matcher.metrics(raw) if raw.error.nil?
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
        raise Halt.new if (cap = @config.max_requests) && @dispatched >= cap
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
        if raw.error && attempts < @config.retries
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
    private def follow_redirects(raw : Replay::Result) : Replay::Result
      current = raw
      hops = 0
      while hops < @config.max_redirects
        resp = current.response
        break unless resp && (300..399).includes?(resp.status)
        loc = resp.headers.get?("location")
        break unless loc
        nxt = redirect_request(loc)
        break unless nxt
        current = @backend.send(nxt)
        hops += 1
        break unless current.error.nil?
      end
      current
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
      return unless interval
      now = Time.instant
      target = @last_dispatch + interval
      sleep(target - now) if now < target
      @last_dispatch = Time.instant
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
