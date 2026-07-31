require "uri"
require "../repeater/engine"
require "../repeater/h2_engine"
require "../proxy/codec/http1"
require "../outbound"
require "../env"
require "../scope"
require "../repeater/conn_pool"

module Gori::Fuzz
  # The keep-alive pool moved to `Repeater::ConnPool` when Discover became its second caller
  # (it is transport over `Repeater::Engine`, not anything fuzz-specific). The fuzz-side name
  # is what the sweep code, its spec and half a dozen comments say, so it stays spelled here.
  alias ConnPool = Repeater::ConnPool

  # The origin a run targets (also the boundary for redirect following).
  #
  # The scheme is folded ws→http / wss→https at construction so the TLS decision is correct
  # by construction for EVERY surface that builds an Origin — the Fuzzer/Miner/Sequencer Plan
  # builders, Repeater Minimize (TUI/CLI/MCP), and Probe active. `Sender#send` dials through
  # `Repeater::Engine`/`H2Engine`, which decide TLS with `scheme == "https"` ALONE, so a
  # `wss://` target (from an operator TARGET field, `--target`, an MCP `url`, or a captured WS
  # flow row replayed one-shot) that reached them unfolded went out CLEARTEXT to a TLS port,
  # leaking the request's cookies and auth. Only `http`/`https` are recorded by the capture
  # proxy, so this fold is a no-op on a normal captured origin. Repeater::Plan folds the same
  # way on its own tuple path; centralising it here removes the ad hoc per-CLI guards.
  struct Origin
    getter scheme : String
    getter host : String
    getter port : Int32

    def initialize(scheme : String, @host : String, @port : Int32)
      @scheme = case scheme
                when "ws"  then "http"
                when "wss" then "https"
                else            scheme
                end
    end
  end

  # The send seam. Swappable so specs (and the baseline calibrator) can drive the
  # engine without a real socket.
  abstract class Backend
    abstract def send(bytes : Bytes) : Repeater::Result
    abstract def origin : Origin

    # Release any transport a backend is holding open (the keep-alive pool's parked
    # sockets). Called once when a run ends. A no-op by default so the spec doubles and
    # the connection-per-send backends stay three-line classes.
    def close : Nil
    end
  end

  # Production backend over the Repeater engines (fresh connection per send — there is
  # no upstream pool; worker count == max simultaneous connections).
  #
  # The `Gori::Outbound` decision is a REQUIRED constructor argument, not a wrapper the
  # caller may forget: this is the one sender every automated sweep on every surface
  # (Fuzzer, Miner, Sequencer, Repeater minimize, Probe active — TUI, `gori run`, MCP)
  # dials through, so requiring it here is what makes "no active request leaves gori
  # without a scope decision" a compile-time property instead of a convention. It
  # replaces the old opt-in `ScopedBackend` wrapper, whose absence was invisible.
  class Sender < Backend
    getter origin : Origin
    # Sends refused by the scope gate — never put on the wire.
    getter blocked : Int64 = 0_i64
    # The HTTP/1.1 keep-alive pool, or nil for connection-per-send (h2, or keep_alive off).
    # Exposed so a surface can report how many handshakes a run actually paid for.
    getter pool : ConnPool?

    # `keep_alive` reuses one connection across many sends (see ConnPool) — the sweep
    # senders (Fuzzer) opt in; the one-shot senders (Repeater minimize, Probe active) have
    # nothing to amortise and leave it off. `idle_conns` bounds the parked sockets and
    # should be the run's concurrency: one per worker fiber is the most that can ever be
    # checked out at once, so a larger pool would only hold dead sockets open.
    def initialize(@origin : Origin, @outbound : Gori::Outbound, @http2 : Bool, @verify : Bool,
                   @sni : String? = nil, @timeout : Time::Span? = nil,
                   @overrides : Gori::HostOverrides? = nil,
                   keep_alive : Bool = false, idle_conns : Int32 = 0)
      # h2 is excluded: H2Engine frames its own connection per send, and multiplexing it is
      # a separate change with its own stream-state rules.
      @pool = (keep_alive && !@http2) ? ConnPool.new(@origin.scheme, @origin.host, @origin.port,
        @verify, @sni, @timeout, @overrides, Math.max(idle_conns, 1)) : nil
    end

    def send(bytes : Bytes) : Repeater::Result
      # Session bindings (#501) resolve HERE, per send, not at plan-build: a rotating token
      # can change between request 1 and request 20 of the same run, which is exactly the
      # run that otherwise produces a page of 401s. Env vars are untouched — the plan
      # builders already expanded those once (#356), and this pass only ever substitutes a
      # name an extract rule declares.
      #
      # A declared-but-unbound name REFUSES rather than shipping `""` or the literal
      # `$SESSION`, and is charged to `blocked` rather than to a second counter — the same
      # argument the comment below makes for the scope gate. The refusal names the binding.
      if (unbound = Gori::Env.unbound(bytes)).present?
        @blocked += 1
        return Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, Gori::Env.unbound_error(unbound))
      end
      # BEFORE the scope gate, because the gate keys on the target actually sent — the same
      # rule `ClientConn` states for Match&Replace on the proxy path.
      bytes = Gori::Env.expand_bindings(bytes)
      # Sandbox mode / an explicit EXCLUDE rule hard-blocks BEFORE the socket, so a
      # blocked attempt never reaches the network. It still costs a request from the
      # engine's budget, exactly as CappedBackend already charges retries and redirect
      # hops — one accounting path, not two.
      if err = @outbound.sweep_block(@origin.scheme, @origin.host, Gori::Outbound.request_target(bytes))
        @blocked += 1
        return Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, err)
      end
      if @http2
        Repeater::H2Engine.send(bytes, scheme: @origin.scheme, host: @origin.host,
          port: @origin.port, verify_upstream: @verify, sni: @sni, timeout: @timeout, overrides: @overrides)
      elsif p = @pool
        p.send(bytes)
      else
        Repeater::Engine.send(bytes, scheme: @origin.scheme, host: @origin.host,
          port: @origin.port, verify_upstream: @verify, sni: @sni, timeout: @timeout, overrides: @overrides)
      end
    end

    def close : Nil
      @pool.try(&.close_all)
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

    def close : Nil
      @inner.close
    end
  end

  # Applies the `Gori::Outbound` gate to a backend the caller INJECTED (Probe Active lets
  # a scan drive the rules through a supplied Backend). `Sender` gates itself, so this is
  # only for the non-Sender case — it is never stacked on one, and both use the same
  # `Outbound#sweep_block` decision, so the gate can't drift between the two paths.
  class GatedBackend < Backend
    getter blocked : Int64 = 0_i64

    def initialize(@inner : Backend, @outbound : Gori::Outbound)
    end

    def origin : Origin
      @inner.origin
    end

    def send(bytes : Bytes) : Repeater::Result
      o = origin
      if err = @outbound.sweep_block(o.scheme, o.host, Gori::Outbound.request_target(bytes))
        @blocked += 1
        return Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, err)
      end
      @inner.send(bytes)
    end

    def close : Nil
      @inner.close
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
      # Every worker has left run_one, so no fiber can be holding a checked-out socket:
      # release the keep-alive pool's parked ones instead of waiting for GC to finalize
      # them (a stopped 50-worker run would otherwise sit on 50 fds).
      @backend.close
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
      # The `Location` is chosen by whatever host answered, and the next line splices it
      # straight into a request line — so it gets the same rule as any other remote-chosen
      # request-line token (#397). Checked HERE rather than inside resolve_redirect_path
      # because this is the method that assembles the bytes, and both of that method's
      # branches (relative, and absolute-form same-origin — `URI.parse` keeps a raw space in
      # `path` and `query` just as verbatim) reach the wire through it.
      #
      # Both halves of the rule are live here, not just the SP/TAB one. A bare LF or CR in a
      # field-value survives `parse_headers` (which breaks lines on the two-byte CRLF only),
      # and the response path gates on `framing_ambiguous?` rather than the stricter
      # `obfuscated_header?` — so a `Location` carrying a smuggled request line that does not
      # disturb framing reaches this method and used to put a whole second, attacker-chosen
      # request on the connection. spec/fuzz/redirect_wire_spec.cr pins that off a real socket.
      #
      # An unsafe Location is not followed at all rather than percent-encoded: gori cannot
      # know whether the origin meant a literal space or a broken link, and refusing leaves
      # the run reporting the 3xx it actually got. That matches the existing treatment of a
      # cross-origin Location — the chain stops, the 3xx is the result.
      return nil unless path && Proxy::Codec::Http1.request_token_safe?(path)
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
