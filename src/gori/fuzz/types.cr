require "../proxy/ws/frame"     # Proxy::WS::Shape — the frame shape a WS fuzz job carries
require "../repeater/ws_engine" # WsEngine::DEFAULT_IDLE — the WS transport's own pacing default

module Gori
  # The fuzzer / intruder engine: takes a base HTTP request with marked positions,
  # substitutes payloads into them, and sends the variations concurrently while
  # collecting per-response metrics. Headless and self-contained — it depends only on
  # the Repeater send engines and the body decoder, never on Store or the TUI, so the
  # same engine drives the TUI Fuzzer tab, `gori run fuzz`, and the MCP fuzz tools.
  module Fuzz
    # The four classic Intruder / Automate attack shapes. With P marked positions and
    # payload set sizes Nᵢ: Sniper = P×N (one position at a time, others = default),
    # BatteringRam = N (same payload in every position), Pitchfork = min(Nᵢ) (one set
    # per position, lockstep), ClusterBomb = ∏Nᵢ (one set per position, every combo).
    enum Mode
      Sniper
      BatteringRam
      Pitchfork
      ClusterBomb

      def label : String
        case self
        in Sniper       then "sniper"
        in BatteringRam then "battering-ram"
        in Pitchfork    then "pitchfork"
        in ClusterBomb  then "cluster-bomb"
        end
      end

      # One payload set shared across all positions (Sniper/BatteringRam) vs one set
      # per position (Pitchfork/ClusterBomb).
      def per_position? : Bool
        pitchfork? || cluster_bomb?
      end

      # Lenient parse of a CLI/MCP token — ignores case and -/_/space so
      # "cluster-bomb", "ClusterBomb", "clusterbomb" all resolve.
      def self.parse?(token : String) : Mode?
        case token.downcase.delete("-_ ")
        when "sniper"                           then Sniper
        when "batteringram", "battering", "ram" then BatteringRam
        when "pitchfork"                        then Pitchfork
        when "clusterbomb", "cluster", "bomb"   then ClusterBomb
        end
      end
    end

    # One outbound WebSocket frame as a SURFACE hands it in — before marking and before the
    # template parse. `payload` is marked TEXT and may carry `§…§`, exactly as
    # `PlanOptions#template` does: a Crystal String holds arbitrary bytes and the whole marking
    # layer is byte-oriented (see `Template`), so a BIN frame's payload survives it intact.
    #
    # Deliberately NOT `Store::WsOutMessage`. This module never depends on Store (see
    # `src/gori/fuzz.cr`), and each surface already holds the conversion at its own edge — the
    # CLI reads `ws_messages_for_repeater`, MCP parses its `messages` array.
    record WsMessageSource,
      opcode : Int32,
      payload : String,
      shape : Proxy::WS::Shape = Proxy::WS::Shape::DEFAULT,
      evidence : Bool = false

    # One RENDERED outbound frame of one variation: payloads spliced, spans computed.
    #
    # `payload_spans` are offsets into THIS FRAME's payload, not into the job's handshake — the
    # frames are separate buffers. That is also why the handshake's Content-Length pass must
    # never `shift_spans` these: shifting a frame's spans by a delta computed over a different
    # buffer silently corrupts the one exclusion that keeps a `$TOKEN` payload out of the live
    # session table (`Env.expand_bindings_frame`).
    record WsFrame,
      opcode : Int32,
      payload : Bytes,
      shape : Proxy::WS::Shape,
      evidence : Bool = false,
      payload_spans : Array({Int32, Int32}) = [] of {Int32, Int32}

    # The WebSocket facts of one session that `Repeater::Result` has no field for — and must not
    # grow one for: that struct is shared with every other engine, the same argument
    # `Engine#gate_refused?` makes for keeping the gate's contract in two string constants.
    #
    # `truncated` is NOT carried here: it means "the captured transcript is SHORT of what the
    # server sent", which is precisely `Repeater::Result#incomplete?`, so the adapter maps it
    # there rather than inventing a second spelling. `note` — a handshake accept mismatch, an
    # unconfirmed delivery, a script that stopped early because the peer sent CLOSE — is a
    # per-RUN advisory and rides `Progress#ws_notes`, beside `grpc_stale`.
    record WsOutcome,
      close_code : Int32?,
      # NILABLE, and `0` would be a different claim. A session that never upgraded — a dial
      # failure, a scope-gate refusal, a `max_requests` stop — received no frames because it
      # never opened a socket, which is not the same fact as "the origin answered nothing".
      # `Result#ws_frames_in` documents itself as nil in exactly that case, and every reader
      # tests presence (`if fi = r.ws_frames_in`), so a `0` printed `ws 0 frames` on an errored
      # row and emitted `"ws_frames_in": 0` into JSON and MCP.
      frames_in : Int32?,
      note : String?,
      truncated : String? do
      # The outcome of a session that never happened (a refused or unsupported send).
      def self.failed : WsOutcome
        new(nil, nil, nil, nil)
      end
    end

    # One concrete request to send: `bytes` already has payloads substituted and
    # Content-Length synced. `position` is the fuzzed position for Sniper (nil
    # otherwise). `index` is the monotonic emit order (results stream back out of
    # order, so every row carries it).
    #
    # `payload_spans` are the byte ranges of `bytes` the payloads occupy, in splice order —
    # the one fact that distinguishes the operator's TEST CASE from the template around it
    # once the request is one flat slice. `Fuzz::Sender` skips them when it substitutes
    # session bindings, so a payload of `$TOKEN` is sent as those six characters instead of
    # as the live session credential. Empty for a `Job` a spec or a non-generator caller
    # built by hand, which means "no exclusions" — the pre-existing behaviour.
    #
    # `chain_error` is set when a marked position's inline `¦chain` (a Decoder chain) could
    # not run on THIS payload's bytes — e.g. `shell-escape` on a non-UTF-8 payload, or a
    # `*-decode` on non-alphabet text. The chain resolved fine at template time (an
    # un-resolvable chain is refused up front by `Plan.refuse_unrunnable_chains`), but raised
    # on these specific bytes, so `Template#apply_chains` sent the payload UNTRANSFORMED. That
    # is a different request than the operator declared; the reason rides to the row here so no
    # surface reports it under `0 errors` / `"error":null`. nil = every chain ran (or none).
    record Job,
      index : Int64,
      payloads : Array(String),
      position : Int32?,
      bytes : Bytes,
      payload_spans : Array({Int32, Int32}) = [] of {Int32, Int32},
      chain_error : String? = nil,
      # The rendered outbound frame script, or nil for an ordinary HTTP job. When set, `bytes`
      # is the HANDSHAKE — so `Outbound.request_target(job.bytes)`, `Result#request` and
      # `HistoryRecord.split_head_body` all keep reading an HTTP request head, and the
      # handshake is itself part 0 of the run's position space (see `Fuzz::WsScript`).
      ws_frames : Array(WsFrame)? = nil

    # One emitted result row. `length`/`words`/`lines` are computed over the DECODED
    # response body (gzip/deflate/br/zstd inflated). `head`/`body`/`request` are
    # retained only per the run's keep_bodies policy (a billion-row cluster bomb
    # can't keep them all). `request` is the exact rendered request bytes sent, for
    # audit/evidence (MCP records these as History flows when asked).
    struct Result
      getter index : Int64
      getter payloads : Array(String)
      getter position : Int32?
      getter status : Int32?
      getter length : Int64
      getter words : Int32
      getter lines : Int32
      getter duration_us : Int64
      getter error : String?
      getter? matched : Bool
      getter? incomplete : Bool
      # This variation went out TWICE: the keep-alive pool found its parked socket closed and
      # re-sent on a fresh connection (`Repeater::Result#retried?`). "No response arrived" does
      # not prove the origin never processed the first copy, so the row — not just the run's
      # connections line — has to say which payload was duplicated.
      getter? retried : Bool
      getter extracted : String?
      getter head : Bytes?
      getter body : Bytes?
      getter request : Bytes?
      # The bytes this variation actually PUT ON THE WIRE, when they differ from `request`.
      #
      # `request` is the rendered TEMPLATE — what the generator produced — and stays that way
      # on purpose: it is the row a surface prints and the bytes "send to Repeater" seeds a tab
      # from, where a session slot's header overlay must NOT be baked in (the slot applies per
      # send, so a seed carrying one would pin an identity the operator can no longer change).
      # `Fuzz::Sender` then substitutes `$NAME` and writes the active slot's overlay at the send
      # seam, and THOSE are the bytes History has to hold: `--record-history` was writing the
      # template, so a sweep run as a slot recorded up to 5000 flows missing the very header
      # that produced the responses stored beside them. Retained on the same `keep_bodies` axis
      # as `request`; nil when nothing rewrote the template.
      getter wire : Bytes?
      # This request is not the one the operator DECLARED, though it went out cleanly. Two
      # populations, and the sentence names which:
      #
      #   * the declared `¦chain` for one of its positions did not run on that payload (it
      #     raised on these bytes, or its output exceeded MAX_OUT), so the payload went out
      #     untransformed — `chain '…' step '…' failed: …`;
      #   * a schema-known gRPC field's DECLARATION could not hold that payload, so the field
      #     kept the capture's own octets — `field role: "abc" is not an integer` (#843).
      #     `Plan.build` refuses those before the first dial wherever the payload set can be
      #     dry-run; this is the backstop past that bound, and it is not allowed to be silent.
      #
      # Carried per row and counted in the run's error tally so neither is hidden inside
      # `0 errors`. Distinct from `error` (a network/send failure): a request can succeed on
      # the wire yet still carry one. nil when nothing intervened.
      #
      # The NAME predates the second population and is kept deliberately: it is the JSON key
      # `fuzz_results` and `--format json` have always emitted, and renaming it would break
      # every reader for a wording improvement. The surfaces label it neutrally
      # ("payload not as declared") and let the sentence say which.
      getter chain_error : String?
      # The gRPC CALL's outcome, from the response's `grpc-status` / `grpc-message` (the
      # trailers the Assembler merges into the head). nil for every non-gRPC response, and for
      # a gRPC one whose origin sent no status at all.
      #
      # `status` cannot carry this: for gRPC the h2 `:status` is 200 BY DEFINITION, so a sweep
      # against an origin that answers `7 PERMISSION_DENIED` to every call produced output
      # byte-identical to one against an origin that allowed them all — `200 · matched` on
      # every row, including the denied ones. The engine had the evidence the whole time (it
      # reaches `run show --format json`, MCP `get_flow`, the Repeater head and the TUI
      # transcript); the fuzz row was the one place it was dropped. Same shape and the same
      # argument as `chain_error` above: carried per row, emitted only when present, so a
      # non-gRPC run's output is unchanged.
      getter grpc_status : Int32?
      getter grpc_message : String?
      # The read that captured this response ended on an IDLE TIMEOUT — the origin held the
      # socket open and simply stopped sending — rather than on a close or a completed body.
      # `incomplete?` already says the captured body is SHORT; this says WHICH of the two events
      # cut it, the twin of `Repeater::Result#timed_out?` (engine.cr:37). Until now `Fuzz::Result`
      # had no such field at all: the engine observed both `incomplete?` and `timed_out?` and
      # forwarded only the first, so `incomplete?` reached no consumer and a truncated body was
      # reported as the whole response on every fuzz surface. Paired with `incomplete?` in the
      # three-way `CLI::Run.incomplete_reason` classifier the Repeater already uses, so the two
      # surfaces cannot come to word one flow's truncation differently. false for a completed
      # send and for any failure that was not a read-deadline stall.
      getter? timed_out : Bool
      # How many times this variation was RE-SENT after a network error because `--retries` is on
      # (a CONFIG retry). DISTINCT from `retried?` above, which is a keep-alive pool re-send on a
      # parked socket the pool found closed — a caller must be able to tell "the pool redialed a
      # dead socket" from "the request errored and `--retries` sent it again". `run_one` keeps
      # re-sending every method on `--retries` by policy; the bug was never the re-send, it was
      # that the row said nothing about it, so a POST that went out three times before it stuck
      # read as a single clean send. It is also the count the run's `errors` adds per row: every
      # superseded attempt is a failed send, and counting only the last one hid the rest inside
      # `0 errors`. 0 = sent once, no config retry fired (the common path).
      getter resent_count : Int32

      # A CONFIG retry fired for this variation (see `resent_count`). Derived, not a second
      # stored field: `resent_count > 0` IS "was it re-sent", and one field carries both the
      # marker and the count. Deliberately separate from `retried?` (the keep-alive re-send).
      def resent? : Bool
        @resent_count > 0
      end

      # The RFC 6455 close code the origin sent, and how many INBOUND frames this variation's
      # session carried. nil on every non-WebSocket row, and on a WS session that never
      # upgraded — the same shape and the same argument as `grpc_status`/`grpc_message` above:
      # carried per row, emitted only when present, so an HTTP run's output is unchanged.
      #
      # `status` cannot carry either. For a WebSocket the handshake status is 101 BY
      # DEFINITION, so a sweep whose payloads all made the origin close with `1008 Policy
      # Violation` produced output byte-identical to one it accepted — `101 · matched` on every
      # row. And `length` counts the concatenated inbound BYTES, which cannot distinguish one
      # 90-byte answer from thirty 3-byte keepalives.
      getter ws_close_code : Int32?
      getter ws_frames_in : Int32?

      # KEYWORD-ONLY, for the reason `Repeater::Result`'s tail is (see its comment): three
      # same-typed nilable scalars appended by three different fixers is exactly how `retried`
      # and `timed_out` got written into each other's field twice.
      def initialize(@index, @payloads, @position, @status, @length, @words, @lines,
                     @duration_us, @error, @matched, @incomplete, @extracted,
                     @head = nil, @body = nil, @request = nil, @retried = false,
                     @chain_error = nil, @grpc_status = nil, @grpc_message = nil,
                     @timed_out = false, @resent_count = 0, @wire = nil, *,
                     @ws_close_code : Int32? = nil, @ws_frames_in : Int32? = nil)
      end

      # The same row carrying its session's WebSocket facts. A copy-returning method rather
      # than two more arguments threaded through `Matcher#build`: the matcher is the one build
      # site for every `Fuzz::Result` and it reads the SYNTHESIZED `Repeater::Result` alone —
      # keeping it ignorant of `WsOutcome` is what makes "the matcher is unchanged" true rather
      # than nearly true. `Engine#run_one_ws` applies this at the one seam that has both.
      def with_ws(o : WsOutcome) : Result
        Result.new(@index, @payloads, @position, @status, @length, @words, @lines,
          @duration_us, @error, @matched, @incomplete, @extracted,
          @head, @body, @request, @retried, @chain_error, @grpc_status, @grpc_message,
          @timed_out, @resent_count, @wire,
          ws_close_code: o.close_code, ws_frames_in: o.frames_in)
      end
    end

    # Live counters. `total` is nil when the run size is unknown (cluster bomb / brute
    # force overflowing Int64).
    record Progress,
      # PAYLOADS completed — one per generated variation, and therefore the numerator that
      # belongs against `total`. NOT the number of requests: see `requests`.
      sent : Int64,
      total : Int64?,
      matched : Int64,
      errors : Int64,
      # Attempts the gate REFUSED before the socket (Sandbox / an exclude rule / an unbound
      # session binding), and the first refusal's text. Carried on Progress rather than left
      # on the Backend because the surfaces that must not render a fully-refused run as
      # "0 matches" only ever see events. See `Fuzz::Backend#blocked`.
      blocked : Int64 = 0_i64,
      blocked_reason : String? = nil,
      # REQUESTS actually put on the wire — `CappedBackend#sent`, the counter `max_requests`
      # is enforced against. Retries and redirect hops each cost one here and NONE in `sent`,
      # so the two diverge by up to `(retries + 1) * (max_redirects + 1)`: a 3-payload sweep
      # with `--follow-redirects` against a redirect chain reported "3 sent" for 18 real
      # requests. For a tester working inside an agreed request budget on a client's
      # production system — or against anything that rate-limits or alerts on volume — this
      # is the number that matters, and mine/discover have always published it as their own
      # `sent`. Kept as a SECOND field rather than replacing `sent`, because `sent/total` is
      # the progress meter's fraction and would otherwise run past 100%.
      requests : Int64 = 0_i64,
      # Requests that left a STALE gRPC length prefix, out of how many were scanned, plus the
      # first `Grpc.framing_error` sentence. Non-zero only for a run whose template is a gRPC
      # request that framed cleanly before a payload was spliced in (`Matcher#grpc_template?`).
      #
      # Carried on Progress for the same reason `blocked`/`blocked_reason` are: a surface that
      # must not report a mis-framed sweep as `3 sent · 0 errors` only ever sees events. gori
      # does NOT re-frame the body (P7 — the payload is the operator's test case); this is the
      # one line that says so, the counterpart of the `--verbatim` note Content-Length gets.
      grpc_stale : Int64 = 0_i64,
      grpc_requests : Int64 = 0_i64,
      grpc_stale_reason : String? = nil,
      # WebSocket sessions that came back with a non-fatal ADVISORY, and the first one's
      # sentence: a handshake whose `Sec-WebSocket-Accept` did not verify, a delivery the
      # engine could not confirm, a script that stopped early because the peer sent CLOSE, or a
      # transcript a capture cap cut short.
      #
      # Carried on Progress for the reason `blocked`/`grpc_stale` are — a surface that must not
      # report a half-delivered sweep as `50 sent · 0 errors` only ever sees events. NOT folded
      # into `errors`: the session ran and its response is real evidence, so counting it as a
      # failed send would both inflate the error tally and flip the exit code of a clean run.
      # And not dropped, which is the silent false negative this field exists to prevent.
      ws_notes : Int64 = 0_i64,
      ws_note_reason : String? = nil

    # Engine → consumer events. A union (not a class hierarchy) so `Channel(Event)`
    # carries them without boxing surprises. Progress is droppable (latest wins);
    # Result/Done/Error are never dropped.
    record ProgressEvent, progress : Progress
    record ResultEvent, result : Result
    record DoneEvent, progress : Progress, stopped : Bool
    record ErrorEvent, message : String

    alias Event = ProgressEvent | ResultEvent | DoneEvent | ErrorEvent

    # All knobs for a run. A mutable class (not a record) because the TUI config
    # overlay binds and edits one instance live; the engine only reads it.
    class Config
      property mode : Mode
      property concurrency : Int32
      property rps : Float64?       # requests/sec cap (nil = unlimited)
      property throttle_ms : Int32? # fixed delay between sends (alt. to rps)
      property jitter_ms : Int32    # random 0..jitter added after each pace
      property retries : Int32      # retries on a network error
      property retry_pause : Time::Span
      property timeout : Time::Span? # per-request connect+read timeout override
      property? follow_redirects : Bool
      property max_redirects : Int32
      property? update_content_length : Bool # recompute CL after body substitution
      property? add_content_length_when_missing : Bool
      # Recompute the gRPC 5-byte length prefix after a payload is spliced into a gRPC
      # message body — the opt-in inverse of the `grpc_stale` notice, and DEFAULT FALSE.
      #
      # The default is the P7 answer and stays it: a payload that changes the message length
      # leaves the prefix declaring the old one, gori SAYS so once per run (`grpc_stale`
      # below) and sends the operator's bytes, because a deliberately-wrong length prefix is
      # one of the standard gRPC parser tests. This flag is for the other run — a sweep of an
      # ordinary unary call where every request being rejected at the framing layer is noise,
      # not the test — and it is exactly the shape `update_content_length` already has for the
      # other length declaration in the same request.
      #
      # Applied by `Generator` (beside the Content-Length pass, and size-preservingly) rather
      # than at the send seam, so `Result#request` and the matcher's own `grpc_stale` scan
      # both read the bytes that went out.
      property? reframe_grpc : Bool
      property? auto_calibrate : Bool # drop responses identical to the baseline
      property keep_bodies : Symbol   # :none | :matched | :all
      property max_requests : Int64?  # hard cap on total sends
      # Reuse one connection across many sends instead of dialing per request — `ConnPool` on
      # HTTP/1.1, `H2Pool` on h2, both behind `Repeater::Pool`. On by default: a sweep pays one
      # TCP — and, on https, one TLS — handshake per WORKER rather than per request, which is
      # the single largest cost of a run against a remote origin. Turn it off to make every
      # request a fresh connection: per-connection origin state (a connection-scoped rate
      # limit, a load balancer pinning by connection, a target you are probing for keep-alive
      # behaviour itself) is then observable per payload again. Requests the pool cannot prove
      # unambiguous — a mis-declared Content-Length, `Connection: close`, CL+TE — get their own
      # connection regardless of this flag.
      #
      # h2 was excluded from this until `H2Pool`, which mattered more than an opt-in flag
      # normally would: `gori run fuzz`'s `http2 = force_h2 || seed.http2` (and the TUI's ⇧I)
      # turn h2 ON for any sweep seeded from a captured h2 flow, so the default workflow
      # against a modern target was the one paying a handshake per payload.
      property? keep_alive : Bool
      # Race condition (last-byte-sync) mode: nil = off (the ordinary Mode-driven sweep runs).
      # N = dial N dedicated connections to the origin, hold back the request's final byte on
      # each, then release every held-back byte in one tight write loop so the target receives
      # all N as close to simultaneously as gori's single-threaded fiber scheduler allows. This
      # bypasses `Mode`/`Generator` entirely (see `Fuzz::Engine#run_race`) — a race group is N
      # copies of ONE request, not a payload-substitution sweep, so it does not fit the
      # Sniper/BatteringRam/Pitchfork/ClusterBomb combinatorial model at all.
      property race_count : Int32?
      # Exact raw wire bytes sent (and fully read) on each race connection BEFORE the held-back
      # race request is queued — equalizes per-connection TLS-handshake/accept latency, which
      # narrows the achievable release window in practice. nil = no warm-up. Never synthesized:
      # the operator supplies the exact bytes (mirrors `--request=FILE`'s raw-bytes contract),
      # because gori does not guess a "harmless" request on the operator's behalf, and reusing
      # the race request itself as its own warm-up would perform a non-idempotent action once
      # before the timed attempt.
      property race_warmup : Bytes?
      # WebSocket only: the gap of server silence that ends each session's drain, and whether to
      # send the template's own `Sec-WebSocket-Key` rather than a fresh one per session.
      #
      # `ws_idle` is the WS transport's pacing knob and `timeout` is NOT its synonym —
      # `WsEngine.send` takes `idle`/`deadline` and no per-operation timeout at all, which is
      # what `gori run repeater send --timeout`'s own help text already says. Keeping them
      # separate is why a WS run can report `timeout` as ignored instead of quietly honouring
      # neither.
      #
      # `ws_keep_key` lets an absent, short, duplicate or non-base64 key be the thing under
      # test; without it every session dials with a fresh conforming key and that test is
      # unreachable. Same spelling and same default as `Repeater::Plan#send_ws`.
      property ws_idle : Time::Span
      property? ws_keep_key : Bool

      # PER-RUN TLS fingerprint override (#844): the name of a `Settings::TLS_PRESETS` entry
      # every send in this run presents, or nil to use whatever the destination policy says.
      #
      # RUN-level rather than per request, and that is the honest granularity: keep-alive
      # parks a socket whose handshake is already done, so a per-request fingerprint would be
      # a value the wire cannot carry. It rides `Config` (not `PlanOptions`) because this is
      # what a finished run has to be able to REPORT — "which handshake produced these
      # results" is a property of the result set, and `Config` is what every surface already
      # reads a run's settings back off.
      #
      # An APPROXIMATION of the named client's hello, exactly as #822 documents the presets.
      # A run tagged `chrome` did not send Chrome's ClientHello; it sent gori's, shaped by
      # Chrome's value-level fields. `gori settings tls-fingerprint --preset chrome` prints
      # the JA3/JA4 that actually goes out.
      property tls_preset : String?

      def initialize(@mode : Mode = Mode::Sniper,
                     @concurrency : Int32 = 20,
                     @rps : Float64? = nil,
                     @throttle_ms : Int32? = nil,
                     @jitter_ms : Int32 = 0,
                     @retries : Int32 = 0,
                     @retry_pause : Time::Span = 1.second,
                     @timeout : Time::Span? = nil,
                     @follow_redirects : Bool = false,
                     @max_redirects : Int32 = 5,
                     @update_content_length : Bool = true,
                     @add_content_length_when_missing : Bool = false,
                     @reframe_grpc : Bool = false,
                     @auto_calibrate : Bool = false,
                     @keep_bodies : Symbol = :matched,
                     @max_requests : Int64? = nil,
                     @keep_alive : Bool = true,
                     @race_count : Int32? = nil,
                     @race_warmup : Bytes? = nil,
                     @ws_idle : Time::Span = Repeater::WsEngine::DEFAULT_IDLE,
                     @ws_keep_key : Bool = false,
                     @tls_preset : String? = nil)
      end
    end
  end
end
