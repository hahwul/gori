module Gori::Fuzz
  # Streams concrete `Job`s for a template + payload sets under one attack mode.
  # Block-based and lazy — it never materializes the cross product, so a cluster bomb
  # of billions of requests costs O(1) memory. Set contract:
  #   Sniper / BatteringRam → exactly 1 shared set.
  #   Pitchfork / ClusterBomb → one set per position (set[i] → position i).
  # (the frontend builds that mapping; out-of-range positions fall back to set 0.)
  class Generator
    # calibration_requests: injected-payload length of the FIRST sample, and the
    # per-sample increment — chosen small enough to stay a plausible query/body value,
    # but distinct enough (multiples of CALIBRATION_STEP) that Matcher.reflects_length?'s
    # byte-level correlation check isn't fooled by incidental ±1-byte noise.
    CALIBRATION_BASE_LEN = 6
    CALIBRATION_STEP     = 5
    CALIBRATION_ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789"

    @has_chains : Bool
    # Whether this run's rendered requests really get their gRPC length prefix recomputed —
    # `Config#reframe_grpc?` AND a template `GrpcVerdict.reframable_template?` accepted, the
    # decision taken once in the ctor. Exposed because it is a pass BETWEEN the splice and the
    # wire, so a surface that RECONSTRUCTS a request it did not retain (the TUI's request
    # pane, `FuzzerView#result_request`) has to reproduce it or show bytes no socket carried —
    # the same reason `auto_encode` and the Content-Length knobs are frozen per run there.
    getter? reframe_grpc : Bool

    # `registry` (when given) applies each marked position's inline Decoder chain to
    # its payload at render time — see Template#apply_chains. nil = no transforms
    # (keeps bare 3-arg callers and specs compiling).
    #
    # `auto_encode` percent-encodes the payload of every QUERY-STRING / FORM-BODY position
    # this request substitutes — see `Fuzz::AutoEncode`, which is where the decision is
    # taken (`Fuzz::Plan.build`). Defaults to the no-op, so a Generator built directly
    # renders exactly what it always did.
    # `marked` is a `Template` for an ordinary HTTP sweep, a `WsScript` for a WebSocket one, and
    # a `GrpcFieldTemplate` for a sweep that names schema-known gRPC fields.
    # A UNION rather than three Generators or an abstract base: every attack mode, the totals,
    # the chain pass and the payload-set contract are defined over the payload-VALUE vector, and
    # all three types answer that vector identically (`position_count`, `positions`,
    # `default_payloads`, `apply_chains{,_reported}`). Only the SPLICE differs — one buffer,
    # a handshake plus N frames, or a head plus a re-encoded protobuf message — so only `emit`
    # and `baseline_raw` branch, and `sniper`/`battering`/`pitchfork`/`cluster`/`recurse`/`total`
    # are untouched.
    def initialize(marked : Template | WsScript | GrpcFieldTemplate,
                   @sets : Array(PayloadSet), @config : Config,
                   @registry : Decoder::Registry? = nil,
                   @auto_encode : AutoEncode = AutoEncode.none)
      @marked = marked
      # Whether ANY marked position carries an inline `¦chain`. Computed once over the
      # immutable template so the per-request `chained` hot path can skip apply_chains'
      # array allocation entirely on the common no-chain template (auto_mark / bare §v§).
      @has_chains = @marked.positions.any? { |p| !p.chain.empty? }
      # Does this run re-length-prefix its gRPC bodies? ONE decision, taken off the seed
      # rendering, never per request (P6): `reframable_template?` reads the head as a String
      # to find content-type, which is fine once and not fine ten thousand times. The knob is
      # short-circuited first, so a run that did not ask pays nothing — not even the extra
      # `baseline_raw` render.
      @reframe_grpc = @config.reframe_grpc? && GrpcVerdict.reframable_template?(baseline_raw)
    end

    # The opt-in gRPC re-length-prefix, applied to a request that is otherwise finished.
    #
    # AFTER `ContentLength.sync`, deliberately: the reframe is size-preserving (only the four
    # length octets change), so it can neither invalidate the Content-Length that pass just
    # wrote nor move a payload span, while the reverse order would leave the CL pass reading a
    # body it had already framed. A no-op on every non-gRPC run and on any request `Grpc.reframe`
    # cannot repair unambiguously — those still go out stale, and `Matcher#note_grpc_framing`
    # still counts and names them.
    private def reframed(bytes : Bytes) : Bytes
      @reframe_grpc ? GrpcVerdict.reframe(bytes) : bytes
    end

    # Does this run sweep a WebSocket script rather than an HTTP request? Read by `Fuzz::Engine`
    # (which routes `run_one` and skips `calibrate_baseline`) and by `Fuzz::Plan` (which reports
    # the knobs a WS run cannot honour).
    def ws? : Bool
      @marked.is_a?(WsScript)
    end

    def mode : Mode
      @config.mode
    end

    # Total request count, or nil when unknown / Int64-overflowing (→ confirm + cap
    # in every frontend). Pitchfork's total is an UPPER bound (min of the KNOWN set
    # sizes; an unknown-length set could end the lockstep sooner).
    def total : Int64?
      case @config.mode
      when .sniper?        then mul(@marked.position_count.to_i64, set_size(0))
      when .battering_ram? then set_size(0)
      when .pitchfork?     then pitchfork_total
      when .cluster_bomb?  then cluster_total
      else                      nil
      end
    end

    # Capture the caller's block as a Proc and thread it through the mode methods —
    # `yield` is illegal inside the captured recursion/iteration closures below.
    def each(&block : Job ->) : Nil
      case @config.mode
      when .sniper?        then sniper(block)
      when .battering_ram? then battering(block)
      when .pitchfork?     then pitchfork(block)
      when .cluster_bomb?  then cluster(block)
      end
    end

    # The unmodified base request (all positions = their defaults), CL-synced — used
    # to seed the matcher baseline for anomaly diffing.
    def baseline_request : Bytes
      raw = baseline_raw
      reframed(@config.update_content_length? ? ContentLength.sync(raw, @config.add_content_length_when_missing?) : raw)
    end

    # The same request WITHOUT the Content-Length pass. Split out so a surface can ask
    # whether the resync is about to REWRITE framing the operator authored — a template
    # declaring `Content-Length: 5` over a ten-byte body is the CL-desync probe itself, and
    # a sweep that silently corrects it tests something else and reports success.
    def baseline_raw : Bytes
      values = chained(@marked.default_payloads)
      # On a WS script this is the HANDSHAKE, which is what every caller of `baseline_raw`
      # wants: `Outbound.request_target` needs a request line, `GrpcVerdict.framed_template?`
      # and `reframable_template?` need a content-type head (and correctly answer "no" for an
      # upgrade), and `Plan#rewrites_content_length?` asks about the one part that declares a
      # length. The frames are rendered and dropped here — a bounded, plan-time cost, and
      # cheaper than a second render path that could disagree with `emit`'s.
      if script = @marked.as?(WsScript)
        return script.render_spans(values).handshake
      end
      render_variation(values)[0]
    end

    # One variation's request bytes, its BASE payload spans, and the reason a schema-known gRPC
    # field could not be encoded from this variation's payload (nil on every other run).
    #
    # The union's one branching seam on the HTTP side. WebSocket never reaches it — `emit`
    # routes a script to `emit_ws` and `baseline_raw` renders the handshake above — because a
    # WS variation is several buffers and this returns one.
    private def render_variation(values : Array(String)) : {Bytes, Array({Int32, Int32}), String?}
      if grpc = @marked.as?(GrpcFieldTemplate)
        grpc.render_spans(values)
      else
        raw, spans = @marked.as(Template).render_spans(values)
        {raw, spans, nil}
      end
    end

    # `n` synthetic requests for auto-calibration (Engine#calibrate_baseline): each
    # substitutes EVERY marked position with a random, nonce-like value — never a real
    # attack payload — so the target's ordinary per-request variability (a timestamp, a
    # session nonce, a rotating banner, a reflected parameter) can be sampled as "noise"
    # up front rather than compared against a single lucky/unlucky snapshot. Injected
    # payload BYTE LENGTH is staggered across samples (see CALIBRATION_BASE_LEN/_STEP)
    # so Matcher.reflects_length? can tell "this target echoes the payload" (length
    # grows with payload length) apart from ordinary noise. Returns {request bytes,
    # total injected payload length across all positions} per sample.
    def calibration_requests(n : Int32) : Array({Bytes, Int32})
      # Empty on a WebSocket script, and `Engine#calibrate_baseline` also returns early on
      # `ws?` — belt and braces, for the reason a race run gets the same treatment there: each
      # sample would open a FULL session and perform the script's side effects, up to
      # CALIBRATION_SAMPLES times, before the sweep proper. That is exactly what
      # `Config#race_warmup`'s doc forbids ("never the race request itself"). Rendering the
      # handshake alone and calling it a sample would be worse than skipping: it measures a
      # 101 no payload can change, so every baseline would be identical and `--ac` would
      # calibrate the sweep away.
      return [] of {Bytes, Int32} if ws?
      count = @marked.position_count
      nonced = nonceable_positions
      defaults = @marked.default_payloads
      (0...n).map do |i|
        plen = CALIBRATION_BASE_LEN + i * CALIBRATION_STEP
        payloads = Array.new(count) { |k| k < nonced ? random_nonce(plen) : defaults[k] }
        raw, _, _ = render_variation(chained(payloads))
        bytes = @config.update_content_length? ? ContentLength.sync(raw, @config.add_content_length_when_missing?) : raw
        {reframed(bytes), plen * nonced}
      end
    end

    # How many of this run's positions a calibration sample may fill with a nonce.
    #
    # Every one on an ordinary sweep. On a gRPC field run only the request's own `§…§` byte
    # positions, because a nonce like `q7f2ka` is not a value an `int32` / `bool` / `enum`
    # declaration can hold: the sample would come back with a field-encode failure and the
    # capture's own value in place, i.e. an identical request every time, sent under a lie
    # about how much payload it carried. A field position therefore keeps the CAPTURE's value
    # across every sample — still an honest measure of the target's ordinary variability (a
    # timestamp, a rotating banner, a session nonce), which is what `--ac` is for. Only
    # `Matcher.reflects_length?` has less to work with, and it is not MISLED, because
    # `payload_len` counts what was actually injected.
    private def nonceable_positions : Int32
      (grpc = @marked.as?(GrpcFieldTemplate)) ? grpc.base.position_count : @marked.position_count
    end

    # ── modes ────────────────────────────────────────────────────────────────────

    private def sniper(emit_to : Job ->) : Nil
      set = @sets[0]?
      return if set.nil?
      idx = 0_i64
      defaults = @marked.default_payloads
      (0...@marked.position_count).each do |p|
        set.each do |v|
          payloads = defaults.dup
          payloads[p] = v
          emit_to.call(emit(idx, payloads, p))
          idx += 1
        end
      end
    end

    private def battering(emit_to : Job ->) : Nil
      set = @sets[0]?
      return if set.nil?
      idx = 0_i64
      n = @marked.position_count
      set.each do |v|
        emit_to.call(emit(idx, Array.new(n, v), nil))
        idx += 1
      end
    end

    private def pitchfork(emit_to : Job ->) : Nil
      count = @marked.position_count
      return if count == 0
      # Open inside the begin so a raise on the k-th open_iterator (e.g. a wordlist file
      # removed after preflight) still closes the 0..k-1 already opened, rather than
      # leaking their file descriptors.
      iters = [] of SetIterator
      idx = 0_i64
      begin
        (0...count).each { |p| iters << set_for(p).open_iterator }
        loop do
          payloads = [] of String
          iters.each do |it|
            v = it.next_value
            return if v.nil? # the shortest set ends the run
            payloads << v
          end
          emit_to.call(emit(idx, payloads, nil))
          idx += 1
        end
      ensure
        iters.each(&.close)
      end
    end

    private def cluster(emit_to : Job ->) : Nil
      count = @marked.position_count
      return if count == 0
      idx = 0_i64
      acc = Array.new(count, "")
      combo = ->(payloads : Array(String)) do
        emit_to.call(emit(idx, payloads, nil))
        idx += 1
      end
      recurse(0, count, acc, combo)
    end

    private def recurse(level : Int32, count : Int32, acc : Array(String), emit_combo : Array(String) ->) : Nil
      if level == count
        emit_combo.call(acc.dup)
        return
      end
      set_for(level).each do |v|
        acc[level] = v
        recurse(level + 1, count, acc, emit_combo)
      end
    end

    # ── helpers ──────────────────────────────────────────────────────────────────

    private def emit(idx : Int64, payloads : Array(String), pos : Int32?) : Job
      values, chain_error = chained_reported(payloads)
      # LAST transform before the splice: whatever a `¦chain` produced is still going into a
      # query string or a form body, and the bytes that reach the wire are the ones that have
      # to be legal there. (A position that declares a chain opts OUT of this entirely — see
      # `AutoEncode.build` — so in practice the two never stack.)
      values = @auto_encode.apply(values, pos)
      if script = @marked.as?(WsScript)
        return emit_ws(script, idx, payloads, pos, values, chain_error)
      end
      raw, spans, field_error = render_variation(values)
      # A schema-known gRPC field whose declaration could not hold THIS payload left the
      # capture's own octets in that field — a different request than the operator declared, so
      # the reason rides out on the row rather than being swallowed under `0 errors`. Same
      # contract, same field, and the same argument as a `¦chain` that raised on these bytes;
      # `Plan.build`'s preflight is what keeps it rare (see `GrpcFieldTemplate#refuse_unencodable`).
      # `||=`: a chain failure happened FIRST in the pipeline, so it is the cause to name.
      chain_error ||= field_error
      bytes = raw
      if @config.update_content_length?
        bytes, at, delta = ContentLength.sync_at(raw, @config.add_content_length_when_missing?)
        spans = shift_spans(spans, at, delta) unless delta == 0
      end
      bytes = reframed(bytes)
      # keep the ORIGINAL payloads for reporting; only the wire bytes are transformed.
      # `chain_error` names any position whose `¦chain` could not run on its payload, so a
      # request that went out with the transform SKIPPED is not reported as a clean send.
      Job.new(idx, payloads, pos, bytes, spans, chain_error)
    end

    # One WebSocket variation: the handshake plus the rendered outbound frame script.
    #
    # The Content-Length pass runs over the HANDSHAKE ONLY, and `shift_spans` is applied ONLY
    # to the handshake's spans. That restriction is the point, not an omission: the frames are
    # separate buffers, so shifting their offsets by a delta computed over a different slice
    # would silently move each frame's payload exclusion off the payload — and that exclusion is
    # the one thing standing between `--payloads '$TOKEN'` and the live session credential going
    # out in a frame (`Env.expand_bindings_frame`). A frame declares no length of its own
    # anyway; `WS.encode` writes its header after the send seam.
    #
    # `reframed` is not applied either. It is the gRPC 5-byte length prefix, which is an h2
    # body concern; a WS run's `@reframe_grpc` is false by construction (`baseline_raw` is an
    # upgrade head, which `reframable_template?` refuses), so calling it would be a no-op that
    # reads as if gRPC-over-WebSocket were a supported combination.
    private def emit_ws(script : WsScript, idx : Int64, payloads : Array(String),
                        pos : Int32?, values : Array(String), chain_error : String?) : Job
      r = script.render_spans(values)
      hs, spans = r.handshake, r.handshake_spans
      if @config.update_content_length?
        hs, at, delta = ContentLength.sync_at(hs, @config.add_content_length_when_missing?)
        spans = shift_spans(spans, at, delta) unless delta == 0
      end
      Job.new(idx, payloads, pos, hs, spans, chain_error, r.frames)
    end

    # `spans` moved across the Content-Length rewrite, which is the one pass that runs
    # between the splice and the wire and can change a byte offset. `at`/`delta` come from
    # `ContentLength.sync_at`: everything at or past `at` moved by `delta`.
    #
    # A span that lay INSIDE the rewritten header line is left where it is rather than
    # dropped. Those payload bytes have no image in the output — the line was replaced by
    # the canonical `Content-Length: N` — so the range now covers digits gori wrote itself,
    # and excluding those from a `$NAME` scan is a no-op either way. Dropping it would be a
    # silent narrowing of the exclusion instead, which is the direction that bites.
    private def shift_spans(spans : Array({Int32, Int32}), at : Int32,
                            delta : Int32) : Array({Int32, Int32})
      spans.map { |(a, b)| a >= at ? {a + delta, b + delta} : {a, b} }
    end

    # A random alphanumeric string with no whitespace — safe to drop into a query/body
    # position without corrupting framing, and (deliberately) never a real payload, so a
    # calibration send can't coincide with anything meaningful on the target.
    private def random_nonce(len : Int32) : String
      String.build(len) { |sb| len.times { sb << CALIBRATION_ALPHABET[Random.rand(CALIBRATION_ALPHABET.size)] } }
    end

    # Apply each position's inline Decoder chain to its payload (identity when no
    # registry was supplied). Kept separate so `render` stays a byte-verbatim splice.
    # Values only — for the baseline/calibration paths, which never surface a per-row chain
    # error (they seed the matcher, they are not reported requests).
    private def chained(payloads : Array(String)) : Array(String)
      # No registry, or no position has a chain ⇒ apply_chains is a per-element identity, so
      # return payloads verbatim (byte-for-byte the same wire request) and skip its allocation.
      (reg = @registry) && @has_chains ? @marked.apply_chains(payloads, reg) : payloads
    end

    # Like `chained`, but for a REPORTED request: also returns the first position's chain
    # failure reason (nil when every chain ran), so the emitted `Job` can carry it to the row.
    # Fast path — no registry / no chains — returns the payloads verbatim with no error and no
    # extra allocation, so the common `auto_mark` / bare `§v§` sweep is unchanged.
    private def chained_reported(payloads : Array(String)) : {Array(String), String?}
      return {payloads, nil} unless (reg = @registry) && @has_chains
      transformed = @marked.apply_chains_reported(payloads, reg)
      # First failing position wins the row's reason; a request with several failing chains is
      # still one wrong-on-the-wire request, and the first named cause is enough to act on.
      err = transformed.each.compact_map(&.[1]).first?
      {transformed.map(&.[0]), err}
    end

    private def set_for(p : Int32) : PayloadSet
      @sets[p]? || @sets[0]
    end

    private def set_size(i : Int32) : Int64?
      @sets[i]?.try(&.size)
    end

    private def pitchfork_total : Int64?
      known = (0...@marked.position_count).compact_map { |p| @sets[p]?.try(&.size) }
      known.empty? ? nil : known.min
    end

    private def cluster_total : Int64?
      return nil if @sets.empty?
      # Use set_for(p) (with the set-0 fallback) exactly like each()/recurse() do —
      # otherwise a run with fewer payload sets than positions reports an unknown
      # ('?') total and demands --force, even though it's perfectly bounded.
      acc = 1_i64.as(Int64?)
      (0...@marked.position_count).each { |p| acc = mul(acc, set_for(p).size) }
      acc
    end

    private def mul(a : Int64?, b : Int64?) : Int64?
      return nil if a.nil? || b.nil?
      return 0_i64 if a == 0 || b == 0
      return nil if a > Int64::MAX // b
      a * b
    end
  end
end
