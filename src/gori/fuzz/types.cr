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
    # un-resolvable chain is refused up front by `Plan.refuse_unusable_chains`), but raised
    # on these specific bytes, so `Template#apply_chains` sent the payload UNTRANSFORMED. That
    # is a different request than the operator declared; the reason rides to the row here so no
    # surface reports it under `0 errors` / `"error":null`. nil = every chain ran (or none).
    record Job,
      index : Int64,
      payloads : Array(String),
      position : Int32?,
      bytes : Bytes,
      payload_spans : Array({Int32, Int32}) = [] of {Int32, Int32},
      chain_error : String? = nil

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
      # The declared `¦chain` for one of this request's positions did NOT run on that payload
      # (it raised on these bytes, or its output exceeded MAX_OUT), so the payload went out
      # untransformed — a different test than the operator asked for. Carried per row and
      # counted in the run's error tally so a swallowed chain is never hidden inside `0 errors`.
      # Distinct from `error` (a network/send failure): a request can succeed on the wire yet
      # still carry a chain_error. nil when every position's chain ran (or none was declared).
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

      def initialize(@index, @payloads, @position, @status, @length, @words, @lines,
                     @duration_us, @error, @matched, @incomplete, @extracted,
                     @head = nil, @body = nil, @request = nil, @retried = false,
                     @chain_error = nil, @grpc_status = nil, @grpc_message = nil,
                     @timed_out = false, @resent_count = 0)
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
      grpc_stale_reason : String? = nil

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
      property? auto_calibrate : Bool # drop responses identical to the baseline
      property keep_bodies : Symbol   # :none | :matched | :all
      property max_requests : Int64?  # hard cap on total sends
      # Reuse one HTTP/1.1 connection across many sends instead of dialing per request
      # (see Fuzz::ConnPool). On by default: a sweep pays one TCP — and, on https, one TLS
      # — handshake per WORKER rather than per request, which is the single largest cost of
      # a run against a remote origin. Turn it off to make every request a fresh connection:
      # per-connection origin state (a connection-scoped rate limit, a load balancer pinning
      # by connection, a target you are probing for keep-alive behaviour itself) is then
      # observable per payload again. Requests the pool cannot prove unambiguous — a
      # mis-declared Content-Length, `Connection: close`, CL+TE — get their own connection
      # regardless of this flag.
      property? keep_alive : Bool

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
                     @auto_calibrate : Bool = false,
                     @keep_bodies : Symbol = :matched,
                     @max_requests : Int64? = nil,
                     @keep_alive : Bool = true)
      end
    end
  end
end
