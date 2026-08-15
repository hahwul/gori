require "uri"
require "../repeater/engine"
require "../repeater/h2_engine"
require "../proxy/codec/http1"
require "../outbound"
require "../env"
require "../scope"
require "../repeater/conn_pool"
require "../pacing"

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

    # `verbatim`: byte ranges of `bytes` whose PROVENANCE is not the template's — today,
    # the fuzz payloads `Fuzz::Generator` spliced in (`Job#payload_spans`). A backend that
    # rewrites the request before the socket must leave them alone; one that does not
    # rewrite anything ignores the argument, which is why this is a concrete delegation
    # rather than a second abstract: every spec double and every wrapper backend in the tree
    # keeps compiling as a three-line class, and only `Sender` — the one that substitutes
    # session bindings — overrides it.
    def send(bytes : Bytes, verbatim : Array({Int32, Int32})?) : Repeater::Result
      send(bytes)
    end

    # The MAXIMAL `verbatim` span: "no byte of this buffer is eligible to expand."
    #
    # One spelling, because EVIDENCE and a payload exclusion are the same mechanism at
    # different widths — see `Sender#evidence?`. `Env.expand` and `Env.scan_unresolved` walk
    # `verbatim` with a cursor, so a `{0, n}` span is hit on the first iteration, copies the
    # whole buffer in one write and sets `i = n`: both halves of the gate become exact no-ops
    # rather than "a scan that happens to match nothing". `Env.clip_spans` splits it correctly
    # across the head/body boundary, so this is honest at the two-slice level too.
    def self.all_verbatim(bytes : Bytes) : Array({Int32, Int32})
      [{0, bytes.size}]
    end

    # PROVENANCE of the buffers this backend is being handed: true when they are CAPTURED
    # evidence rather than something an operator authored. Answered by the BACKEND rather
    # than re-decided at each `send` call, because the call sites are engines
    # (`Fuzz::Engine`, `Miner::Baseline`, `Sequencer::Engine`, `Repeater::Minimize`) that
    # receive a ready-made Backend and never see the plan options — while the plan builder
    # that DOES know is the one constructing the `Sender`. See `Sender#evidence?`.
    #
    # Reported here, and delegated (not defaulted) by the wrappers below, for the same
    # reason `blocked` and `extra_requests` are: a wrapper is what the engine holds, so a
    # `false` that stopped at the outermost layer would describe every wrapped run wrongly.
    def evidence? : Bool
      false
    end

    # Sends this backend REFUSED before the socket — Sandbox, an explicit exclude rule, or
    # a session binding nothing has bound yet. Zero for a backend with no gate.
    #
    # Counting these was never the problem; not REPORTING them was. A refused send still
    # produces a Result with an error, so it lands in `errors` and vanishes into a number
    # that also covers timeouts and 500s — and a run where every single send was refused
    # came back as `sent:N, matched:0` with an empty result list, which reads as "the
    # payloads were tried and nothing matched". For a security tool that is the worst
    # possible failure mode: a false negative that looks like a clean bill of health.
    def blocked : Int64
      0_i64
    end

    # The first refusal, verbatim, so a surface can SAY why rather than only count.
    def blocked_reason : String?
      nil
    end

    # Release any transport a backend is holding open (the keep-alive pool's parked
    # sockets). Called once when a run ends. A no-op by default so the spec doubles and
    # the connection-per-send backends stay three-line classes.
    def close : Nil
    end

    # Requests this backend put on the wire BELOW the caller's own count. Today that is only
    # `ConnPool`'s stale re-sends, which happen inside one `send` call: `CappedBackend` counts
    # calls, so without this a run that re-sent three requests reported the traffic of four
    # when seven left the machine. `Progress#requests` documents itself as "REQUESTS actually
    # put on the wire", which is the number a tester works an agreed budget against.
    def extra_requests : Int64
      0_i64
    end

    # Send a GROUP of requests as ONE same-connection sequence, capturing each response in
    # order — the primitive the active request-smuggling / desync rule needs (see
    # `Repeater::Engine.send_pipeline`): a desync induced by member N surfaces only in the
    # response to member N+1 on the SAME socket, which fresh-connection-per-send `send` can
    # never reveal. `timeout` bounds the group's per-operation reads (nil = the backend's own).
    #
    # A CONCRETE DEFAULT, not a second abstract, and it deliberately delegates to per-member
    # `send`: every wrapper backend (`GatedBackend`/`CappedBackend`) then inherits its gating /
    # capping through the `send` overrides it already has, and every spec double stays a
    # three-line class with no group logic to write. Only `Sender` — the production transport —
    # overrides this to reach a REAL dedicated socket (the default's per-member sends are each a
    # fresh connection, so it does not prove a same-socket desync; a caller that needs the true
    # single socket is on `Sender`, and a spec that only asserts routing/gating does not need it).
    # Whole-buffer `verbatim` per member, matching how the probe path marks every send: a crafted
    # smuggling probe carries no operator `$NAME` to expand.
    def send_pipeline(requests : Array(Bytes), timeout : Time::Span? = nil) : Array(Repeater::Result)
      requests.map { |b| send(b, Backend.all_verbatim(b)) }
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
    getter blocked_reason : String? = nil
    # The HTTP/1.1 keep-alive pool, or nil for connection-per-send (h2, or keep_alive off).
    # Exposed so a surface can report how many handshakes a run actually paid for.
    getter pool : ConnPool?

    # PROVENANCE, carried from the plan builder's `PlanOptions#evidence?` — the twin of
    # `Repeater::Sender#evidence?`, which has gated this same pair of passes since #501.
    #
    # Every plan builder already skips its DRAFT-time passes for a captured request
    # (`fuzz/plan.cr`, `miner/plan.cr`, `sequencer/plan.cr` all branch on `evidence?`; the
    # three minimize surfaces branch the same way inside their `resolve` proc). The decision
    # then stopped at the plan and the SEND seam ran unconditionally — so the intent was
    # preserved for env vars and silently reversed for session bindings, one seam later.
    #
    # It matters because captured traffic is full of `$NAME`-shaped bytes nobody typed. The
    # grammar is `$` + `[A-Za-z_]` + `[A-Za-z0-9_]*` with no delimiter requirement and it
    # runs over the BODY too, so Mongo's `$ne`/`$gt`/`$where`, JSON Schema's `$ref`/`$schema`
    # and a GraphQL operation — which is MADE of `$variable` references — are all tokens
    # here. With an ordinary extract rule named `id` bound, a captured
    #
    #   {"query":"query GetUser($id: ID!) { user(id: $id) { name } }", ...}
    #
    # left for the target as `query GetUser(<live session token>: ID!)`: a real credential in
    # the target's access log, inside a request nobody authored, and no longer valid GraphQL,
    # so the sweep's verdict was about a parse error. Measured on one capture: 12 copies of
    # the token across 6 `minimize_repeater {verbatim: true}` probes, 6 across 8 `gori run
    # mine` requests, 5 across 6 `gori run sequence` requests.
    #
    # EVIDENCE IS JUST THE MAXIMAL SPAN, which is why this composes with `verbatim` rather
    # than competing with it: `send` widens the caller's spans to `Backend.all_verbatim`, a
    # strict superset of the fuzz payload spans and of the miner's injected-candidate spans,
    # so every narrower exclusion those already won still holds.
    #
    # The cost is the same one `Repeater::Sender#evidence?` names: an operator's own `$TOKEN`
    # merged INTO a capture (a TUI edit over a seeded tab) now ships literally rather than
    # resolving. That is the direction that can only be read wrong, never sent wrong.
    #
    # A ctor keyword rather than a required argument, deliberately — unlike `Gori::Outbound`,
    # which is required because there was no existing answer and a caller could silently omit
    # a scope decision. Here every caller that matters already HOLDS the boolean and is only
    # forwarding it; a required arg would buy nothing but churn across the spec doubles and
    # the probe/analyzer paths, whose buffers are handled at their own call sites.
    getter? evidence : Bool

    # `keep_alive` reuses one connection across many sends (see ConnPool). `idle_conns` bounds
    # the parked sockets and should be the run's concurrency: one per worker fiber is the most
    # that can ever be checked out at once, so a larger pool would only hold dead sockets open.
    #
    # This comment used to say the "one-shot senders (Repeater minimize, Probe active) have
    # nothing to amortise", and every caller believed it. None of them is one-shot: a minimize
    # is a greedy bisection firing up to `Minimize::SEND_CAP` candidates at one origin, Probe
    # Active drives every rule's probes through ONE sender, and the Sequencer re-sends the same
    # captured request `--count` times (default 500) at a default concurrency of 1. All three
    # now opt in. The rule is not "one-shot vs sweep" — it is simply whether more than one
    # request goes to the same origin, and a caller that closes the backend when it is done.
    #
    # Whoever turns it on OWNS calling `close`, or the parked sockets outlive the run.
    def initialize(@origin : Origin, @outbound : Gori::Outbound, @http2 : Bool, @verify : Bool,
                   @sni : String? = nil, @timeout : Time::Span? = nil,
                   @overrides : Gori::HostOverrides? = nil,
                   keep_alive : Bool = false, idle_conns : Int32 = 0,
                   @evidence : Bool = false)
      # h2 is excluded: H2Engine frames its own connection per send, and multiplexing it is
      # a separate change with its own stream-state rules.
      @pool = (keep_alive && !@http2) ? ConnPool.new(@origin.scheme, @origin.host, @origin.port,
        @verify, @sni, @timeout, @overrides, Math.max(idle_conns, 1)) : nil
    end

    def send(bytes : Bytes) : Repeater::Result
      send(bytes, nil)
    end

    # `verbatim` excludes the run's PAYLOAD bytes from both halves below. A payload is the
    # operator's test case, not a draft: SSTI / template-injection / env-reflection payload
    # sets are made of `$X` strings, and with an extract rule up, `--payloads '$TOKEN'` went
    # out as the live session token — a real credential in an arbitrary query or body
    # position of a request aimed at the target, landing in its access log, while every
    # surface (the terminal row, `--format json`, MCP `fuzz_results`) still reported
    # `$TOKEN`.
    def send(bytes : Bytes, verbatim : Array({Int32, Int32})?) : Repeater::Result
      # PROVENANCE first, and by WIDENING rather than by branching: on an evidence run no
      # byte of `bytes` was authored by anyone, so the exclusion the caller asked for grows
      # to cover the whole buffer. Both halves below then read the widened list, which is the
      # invariant `Env.unbound`'s comment demands ("it has to be the SAME list"). See
      # `evidence?` for why this is the only place the two ideas need to meet: a run is
      # either template+payloads (narrow spans) or evidence (the maximal one), and the
      # maximal span contains every narrow one, so nothing a previous fix protected is lost.
      verbatim = Backend.all_verbatim(bytes) if @evidence
      # Session bindings (#501) resolve HERE, per send, not at plan-build: a rotating token
      # can change between request 1 and request 20 of the same run, which is exactly the
      # run that otherwise produces a page of 401s. Env vars are untouched — the plan
      # builders already expanded those once (#356), and this pass only ever substitutes a
      # name an extract rule declares.
      #
      # A declared-but-unbound name ships LITERALLY, and there is no refusal here any more.
      # The refusal was right about the credential-shaped case (`$SESSION` with nothing bound)
      # and wrong about every other one: the token grammar is also GraphQL's variable syntax
      # and Mongo's operator syntax, so an extract rule named `id` made every captured GraphQL
      # body in the project unsendable — `Probe::Active` lost 7 of one flow's 9 checks and
      # still reported the flow scanned. See `Env.unbound`; `$$id` is the escape.
      #
      # BEFORE the scope gate, because the gate keys on the target actually sent — the same
      # rule `ClientConn` states for Match&Replace on the proxy path.
      bytes = Gori::Env.expand_bindings(bytes, verbatim)
      # Sandbox mode / an explicit EXCLUDE rule hard-blocks BEFORE the socket, so a
      # blocked attempt never reaches the network. It still costs a request from the
      # engine's budget, exactly as CappedBackend already charges retries and redirect
      # hops — one accounting path, not two.
      if err = @outbound.sweep_block(@origin.scheme, @origin.host, Gori::Outbound.request_target(bytes))
        @blocked += 1
        @blocked_reason ||= err
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

    def extra_requests : Int64
      @pool.try(&.stale_retries) || 0_i64
    end

    # Same-connection group send for the active smuggling/desync probe. Unlike `send`, the whole
    # group MUST ride ONE dedicated socket (a desync induced by member N shows up only in member
    # N+1's response), so this routes to `Repeater::Engine.send_pipeline`, which dials one socket
    # and retires it on the first error/incomplete exchange. That deliberately BYPASSES the
    # keep-alive `ConnPool` (`reusable_request?` refuses CL+TE / obfuscated payloads by design —
    # exactly the bytes this carries) and never touches `Fuzz::ContentLength.sync`: the caller owns
    # the framing (a deliberately wrong Content-Length is the whole point), so nothing rewrites it.
    def send_pipeline(requests : Array(Bytes), timeout : Time::Span? = nil) : Array(Repeater::Result)
      return [] of Repeater::Result if requests.empty?
      # send_pipeline frames HTTP/1.1 only (`Repeater::Engine.send_pipeline` is h1). h2 multiplexes
      # its own connection per send with separate stream-state rules, so a "same socket" group is
      # meaningless there — DEGRADE to the per-member default (each on its own h2 connection via
      # `send`, still gated, still one Result per request in order). The rule pre-filters to
      # HTTP/1.1 anyway, so this is a belt-and-braces guard, not a hot path.
      return super if @http2
      # GROUP-GATE up front, sweep-side, mirroring `Repeater::Sender#group_refusal`: one blocked
      # member refuses the WHOLE batch and returns all-error Results — a group is one connection
      # carrying a deliberate sequence, so a partial send would be a misleading half-probe. The
      # target is read off each member AFTER the same binding expansion `send` applies, so the
      # scope decision is identical to the lone-send path (BEFORE the socket, per `ClientConn`).
      requests.each do |req|
        target = Gori::Outbound.request_target(@evidence ? req : Gori::Env.expand_bindings(req))
        if err = @outbound.sweep_block(@origin.scheme, @origin.host, target)
          @blocked += requests.size
          @blocked_reason ||= err
          return requests.map { Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, err) }
        end
      end
      reqs = @evidence ? requests : requests.map { |b| Gori::Env.expand_bindings(b) }
      Repeater::Engine.send_pipeline(reqs, scheme: @origin.scheme, host: @origin.host,
        port: @origin.port, verify_upstream: @verify, sni: @sni,
        timeout: timeout || @timeout, overrides: @overrides)
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

    # Delegated, not defaulted: this wrapper is what the Engine holds, so a Backend#blocked
    # that stopped at the outermost layer would report 0 for every gated run there is.
    def blocked : Int64
      @inner.blocked
    end

    def blocked_reason : String?
      @inner.blocked_reason
    end

    # Delegated for the same reason as `blocked`: this wrapper is what the Engine holds, so a
    # default 0 here would hide every re-send the pool underneath it made.
    def extra_requests : Int64
      @inner.extra_requests
    end

    # Delegated for that same reason once more. Nothing here CONSUMES it — the widening
    # happens inside `Sender#send`, below this wrapper — but this is the object every
    # minimize surface and the Miner hold, so a `false` stopping at the cap would make the
    # run's provenance unreadable from the outside and let a spec assert the wrong thing.
    def evidence? : Bool
      @inner.evidence?
    end

    def send(bytes : Bytes) : Repeater::Result
      send(bytes, nil)
    end

    def send(bytes : Bytes, verbatim : Array({Int32, Int32})?) : Repeater::Result
      return Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, CAP_ERROR) if cap_reached?
      @sent += 1
      @inner.send(bytes, verbatim)
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
    getter blocked_reason : String? = nil

    def initialize(@inner : Backend, @outbound : Gori::Outbound)
    end

    def origin : Origin
      @inner.origin
    end

    def extra_requests : Int64
      @inner.extra_requests
    end

    # Delegated, as on `CappedBackend` — see `Backend#evidence?`.
    def evidence? : Bool
      @inner.evidence?
    end

    def send(bytes : Bytes) : Repeater::Result
      send(bytes, nil)
    end

    def send(bytes : Bytes, verbatim : Array({Int32, Int32})?) : Repeater::Result
      o = origin
      if err = @outbound.sweep_block(o.scheme, o.host, Gori::Outbound.request_target(bytes))
        @blocked += 1
        @blocked_reason ||= err
        return Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, err)
      end
      @inner.send(bytes, verbatim)
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
    # Outbound rate limiting (rps / throttle_ms / jitter_ms) over `@last_dispatch`.
    include Gori::Pacing

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

    # The CAP WRAPPER, not the raw Backend the caller passed: the engine always wraps (a nil
    # cap is a pass-through), and typing it as the wrapper is what lets `snapshot` publish
    # `CappedBackend#sent` — the true wire count — without a runtime `is_a?` at every read.
    @backend : CappedBackend
    @concurrency : Int32
    @state : State
    @wake : Channel(Nil)
    @jobs : Channel(Job)
    @finished : Channel(Nil)
    @sent : Int64
    @matched : Int64
    @errors : Int64
    # PAYLOAD-unit refusals, counted on the ENGINE rather than read off `@backend.blocked`. The
    # backend increments on EVERY refused `send` call, so a gate-refused payload that `--retries`
    # re-sent — and a redirect hop the gate refused — each bumped it, and `all_blocked`
    # (`sent>0 && blocked>=sent`, mcp/tools/fuzz.cr) then read true on a run where a payload came
    # back 200. Here it is exactly one increment per refused PAYLOAD (see `run_one`), the unit
    # that compares to `@sent`. The backend keeps its own per-call counter — the Miner
    # (miner/engine.cr) and the injected-backend Probe path read it and are out of this scope —
    # but the fuzz `snapshot` now publishes THIS one.
    @blocked : Int64
    @blocked_reason : String?
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
      @blocked = 0_i64
      @blocked_reason = nil.as(String?)
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

    # Whether Config asked for auto-calibration. Surfaces that own their start path
    # (CLI, TUI) call `calibrate_baseline` themselves; MCP's job fiber asks this so the
    # documented `auto_calibrate` flag is not a silent no-op.
    def auto_calibrate? : Bool
      @config.auto_calibrate?
    end

    # Seed the matcher's calibration set from CALIBRATION_SAMPLES synthetic,
    # randomly-payloaded requests (see Generator#calibration_requests and
    # Matcher.reflects_length?) — replaces the old single-snapshot baseline, which a
    # target with ANY legitimate per-request variability (a nonce, rotating content, a
    # reflected parameter) trivially defeated. Optional; call before `start`. Every
    # send routes through @backend like any other, so calibration sends still count
    # against a configured max_requests cap; under a tight cap, sample count is
    # trimmed so at least one send is left for the sweep itself (at max_requests=1
    # calibration is skipped entirely — the old `Math.max(cap - 1, 1)` still wanted 1
    # sample and left zero for the sweep, despite the comment promising the opposite).
    # A failed/empty calibration is non-fatal — auto_calibrate then simply suppresses
    # nothing.
    def calibrate_baseline : Nil
      # A stop that landed before the run fiber's first tick (the TUI publishes `v.engine`
      # before spawning, so ^X can arrive here) must not open with a burst of real sends.
      return if @state == State::Stopped
      wanted = CALIBRATION_SAMPLES
      if (cap = @config.max_requests) && cap > 0
        room = cap - 1
        return if room <= 0
        wanted = Math.min(wanted.to_i64, room).to_i32
      end
      samples = [] of BaselineSample
      interval = pace_interval
      @generator.calibration_requests(wanted).each do |bytes, payload_len|
        # `stop` only sets the flag and pokes @wake, which this loop never waits on, so the
        # remaining samples used to go out one by one AFTER the operator asked to stop — and
        # `pace` below widens that window to a full rate interval each (at rps 0.2, ~25s of
        # trailing sends under "stopping…"). `dispatch_loop` re-reads the flag every job for
        # the same reason; this is the same check at the phase that runs BEFORE it.
        break if @state == State::Stopped
        # Calibration samples are real requests at the target, sent before `start`'s dispatch
        # loop exists — so without this they were the one burst that ignored `--rate` outright.
        pace(interval)
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
        raise Halt.new if @backend.cap_reached?
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
        result =
          begin
            run_one(job)
          rescue ex
            # A raise here used to kill the worker outright. `@finished` still fires from the
            # ensure below, so `coordinate` completes and the sweep reports Done with a
            # plausible count — while that payload's row is gone and concurrency is silently
            # down one for the rest of the run. Worse, if EVERY worker dies this way,
            # `dispatch_loop` is left parked on `@jobs.send` with no receiver and never reaches
            # its own `ensure @jobs.close`, leaking a fiber that holds the generator and its
            # open wordlist fds. Turn it into an ordinary errored row instead: `run_one` already
            # reports network failures that way, and this is the same thing one level out.
            @errors += 1
            @events.send(ErrorEvent.new(ex.message || "fuzz worker error"))
            next
          end
        @sent += 1
        @matched += 1 if result.matched?
        # A swallowed `¦chain` (the transform did not run, the payload went out raw) is an
        # error too — otherwise a sweep reports `0 errors` while sending the untransformed
        # payload. `||` not `+2`: one request is one error even if it both failed on the wire
        # AND carried a chain that could not run.
        @errors += 1 if result.error || result.chain_error
        # Every SUPERSEDED attempt was a failed send too: `run_one` only re-sends after a
        # network error, so `resent_count` is exactly the count of earlier attempts that failed
        # and were replaced. The line above counts the FINAL result; without this one a POST
        # that failed twice and then succeeded on try 3 reported `0 errors` for two real network
        # failures. `resent_count` is 0 on the common path, so a clean run is byte-unchanged; and
        # it never double-counts the final attempt, which is the one the `||` above already saw.
        @errors += result.resent_count
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
      # them (a stopped 50-worker run would otherwise sit on 50 fds). `rescue nil` for the
      # same reason `Discover::Engine#orchestrate` guards its teardown: a raise here used to
      # skip the `@events.close` below, and a synchronous consumer (`Engine#run`, the CLI,
      # the MCP job fiber) sits in `while ev = @events.receive?` forever — which for MCP also
      # means `finalize_job` never runs, pinning the job at `:running` and blocking
      # `switch_project`/`delete_project` for the rest of the session.
      @backend.close rescue nil
      @events.send(DoneEvent.new(snapshot, @state == State::Stopped))
    ensure
      # ALWAYS close, on every exit path: closing is what turns the consumer's blocking
      # `receive?` into a nil and lets it finish. `Channel#close` is idempotent.
      @events.close
    end

    # ── per-request ──────────────────────────────────────────────────────────────

    private def run_one(job : Job) : Result
      attempts = 0
      resent_count = 0
      loop do
        # The payload spans ride with the bytes: `Sender` needs them to tell the operator's
        # test case from the template it was spliced into (see `Backend#send`).
        raw = @backend.send(job.bytes, job.payload_spans)
        # A scope-gate refusal (Sandbox / an explicit exclude rule) is a PAYLOAD-unit block:
        # count it once HERE and return, never retry it. Two things depended on this together:
        #   * the OLD loop DID retry it — a gate error is not `CAP_ERROR` — so with `--retries N`
        #     the same refused payload re-ran N times, and each re-run bumped `@backend.blocked`
        #     again; `blocked` then climbed past `sent` and `all_blocked` read true on a run that
        #     never was fully blocked. Retrying is also pointless: the decision is stable within
        #     `Outbound::RELOAD_INTERVAL`, so a re-send only burns `retry_pause` and one request.
        #   * counting on the engine (not the backend) is what keeps a refused redirect HOP —
        #     which still bumps `@backend.blocked` — out of this tally, since only the PRIMARY
        #     send reaches this line. See the `@blocked` field comment.
        # Detected by the two exact strings `Outbound#sweep_block` returns and nothing else does,
        # so it is precise and race-free across worker fibers (no shared-counter delta to read).
        if gate_refused?(raw.error)
          @blocked += 1
          @blocked_reason ||= raw.error
          return @matcher.build(job, raw, resent_count: resent_count)
        end
        # Don't burn retries/sleep on a permanent max-requests stop — further send()s
        # are also refused. Real network errors still retry as configured; each retry means the
        # previous attempt was a failed send, tallied via `resent_count` (see `worker_loop`).
        if raw.error && raw.error != CappedBackend::CAP_ERROR && attempts < @config.retries
          attempts += 1
          resent_count += 1
          sleep @config.retry_pause
          next
        end
        raw = follow_redirects(raw) if @config.follow_redirects? && raw.error.nil?
        return @matcher.build(job, raw, resent_count: resent_count)
      end
    end

    # A send the SCOPE GATE refused before the socket, told apart from a network error by the
    # two exact strings `Outbound#sweep_block` returns (via `Sender#send`/`GatedBackend#send`).
    # Kept a string compare rather than a new `Repeater::Result` flag: that struct is shared with
    # every other engine and must not grow a fuzz-only field — the constants ARE the contract.
    private def gate_refused?(err : String?) : Bool
      err == Gori::Outbound::SANDBOX_SWEEP_ERROR || err == Gori::Outbound::EXCLUDE_SWEEP_ERROR
    end

    # Follow up to max_redirects SAME-ORIGIN redirects (relative, or absolute to the
    # same scheme/host/port), re-issuing a GET. Cross-origin redirects are left as the
    # final 3xx (no implicit off-target sends).
    private def follow_redirects(raw : Repeater::Result) : Repeater::Result
      current = raw
      total_us = raw.duration_us
      # A keep-alive re-send ANYWHERE in the chain has to reach the row: the collapsed Result
      # below keeps the last hop's fields, so without this an original request that was
      # re-sent and then redirected would report as a single clean send.
      retried = raw.retried?
      # A hop that FAILED — the gate refused its off-scope `Location`, or the target was dead —
      # must NOT overwrite the payload's real answer. The payload's answer is the 3xx we already
      # hold in `current`, and that 302 is exactly what an open-redirect probe is hunting; the
      # old collapse replaced it with the hop's "never dialed" error and destroyed the finding.
      # When a hop errors we keep the last good response and carry the hop's failure as a NOTE on
      # the collapsed error — status and body stay the payload's, since an error and a response
      # are not exclusive (see `cli/run/repeater.cr`). A refused hop is also NOT a payload-block,
      # so it never touches `@blocked`; only `run_one`'s PRIMARY refusal does.
      hop_error : String? = nil
      hops = 0
      while hops < @config.max_redirects
        resp = current.response
        break unless resp && (300..399).includes?(resp.status)
        loc = resp.headers.get?("location")
        break unless loc
        nxt = redirect_request(loc)
        break unless nxt
        # WHOLE-message verbatim, and not `nil` and not the job's spans. `Sender#send`'s
        # 1-argument overload means "no exclusions", i.e. substitute every `$NAME` an extract
        # rule has bound — and `nxt` is assembled below from a `Location` the ORIGIN chose. A
        # target that reflects a query parameter into `Location` (an ordinary login/redirect
        # endpoint, and precisely what an open-redirect probe aims at) therefore reproduced the
        # operator's payload inside this hop, where the exclusion the first hop got no longer
        # applied: `--payloads '$TOKEN'` put the live session credential in the target's query
        # string and access log while every surface still showed `$TOKEN` and `0 errors`.
        #
        # The job's spans cannot be forwarded — they index the ORIGINAL request's offsets, and
        # the origin may have re-encoded, moved or duplicated the payload on its way through
        # `Location`, so locating them again is guesswork with a credential as the stake.
        # Excluding the whole message needs no guess and gives up nothing: every byte of `nxt`
        # is either a literal gori wrote (`GET`, `Host:`, `Connection: close`) or the origin's
        # own `Location`. Neither is a place an operator could have written a `$NAME` for a
        # binding to resolve, so there is nothing here to substitute in the first place.
        # A hop is a REQUEST, so it owes the operator's rate the same as any other. Only the
        # first request of a payload goes through the dispatch loop's `pace`, so an unpaced
        # chain ran at up to (max_redirects + 1)x the configured rate — 6x at defaults, on
        # every 3xx, which is the ordinary shape of an auth-gated target. `pace` claims its
        # slot without yielding, so calling it from this worker fiber is safe.
        pace(pace_interval)
        hop = @backend.send(nxt, Backend.all_verbatim(nxt))
        retried ||= hop.retried?
        total_us += hop.duration_us
        hops += 1
        # Keep `current` (the last good response, e.g. the 302) when the hop failed; attach the
        # reason rather than replacing the response with it. Prefixed so no surface reads it as
        # the PAYLOAD's own failure — it is a note about a hop gori chose to follow.
        if err = hop.error
          hop_error = "redirect hop refused: #{err}"
          break
        end
        current = hop
      end
      # Report the whole chain's end-to-end time, not just the final hop's — otherwise a
      # slow original request that 3xx's to a fast resource masks a time-based signal.
      # Named tail, for the reason `Repeater::Result#as_retried` states: `retried` used to sit
      # in the eighth POSITIONAL slot, which `timed_out` had taken in the same round — so every
      # keep-alive re-send in a redirect-following sweep lost its row marker and gained a false
      # `timed_out`. The constructor's tail is keyword-only now, so this cannot recur silently.
      hops > 0 ? Repeater::Result.new(current.head, current.body, current.response, total_us,
        hop_error || current.error, current.incomplete?,
        delivered: current.delivered?, timed_out: current.timed_out?, retried: retried) : current
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

    # ── lifecycle (pause / wake) ─────────────────────────────────────────────────

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
      # The gRPC framing tally rides along from the Matcher, which is the one object that
      # sees every RENDERED request (see `Matcher#grpc_template?`). All zeroes / nil unless
      # the template was a cleanly-framed gRPC request, so no surface changes for anything else.
      # `@blocked`/`@blocked_reason` are the ENGINE's payload-unit tally (see the field comment),
      # NOT `@backend.blocked` — the backend counts every refused call, which double-counts a
      # gate-refused payload's retries and its redirect hops and poisons `all_blocked`.
      Progress.new(@sent, total, @matched, @errors, @blocked, @blocked_reason,
        @backend.sent + @backend.extra_requests,
        @matcher.grpc_stale, @matcher.grpc_requests, @matcher.grpc_stale_reason)
    end
  end
end
