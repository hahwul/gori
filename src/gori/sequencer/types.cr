require "../token_extract"

module Gori
  # The token-randomness analyzer ("Sequencer"): collects a large sample of a
  # security token (session cookie, CSRF token, reset token, API key) and grades
  # its predictability with entropy + statistical randomness tests — the gori
  # counterpart of Burp Sequencer / the Caido Sequencer plugin.
  #
  # Two collection modes over one event stream: LIVE REPLAY sends ONE fixed request
  # N times and pulls a token out of each response; MANUAL analyzes a pasted set of
  # tokens without touching the network. Headless and self-contained: it depends
  # only on the reused Fuzz::Sender/Backend send seam and the body decoder, never on
  # Store or the TUI — so the one engine drives the TUI Sequencer tab, `gori run
  # sequence`, and the MCP sequence_* tools.
  module Sequencer
    # How tokens are gathered.
    enum Mode
      LiveReplay # send @request repeatedly, extract a token per response
      Manual     # analyze a fixed list of pasted tokens (no network)

      def label : String
        live_replay? ? "live replay" : "manual"
      end

      def self.parse?(token : String) : Mode?
        case token.downcase.strip
        when "live", "replay", "live-replay", "l" then LiveReplay
        when "manual", "paste", "m"               then Manual
        end
      end
    end

    # The descriptor types moved to `Gori::ExtractKind` / `Gori::TokenLoc` when session
    # bindings (#501) became their second consumer. Aliased rather than renamed at the ~40
    # call sites that spell them `Sequencer::` — the Sequencer is still where an operator
    # meets them, and a rename would have been churn in five surfaces for no reader's
    # benefit. See `token_extract.cr`.
    alias ExtractKind = Gori::ExtractKind
    alias TokenLoc = Gori::TokenLoc

    # One collected token: a network row in live mode, or a pasted line in manual
    # mode. `token` is nil on an extraction miss (still emitted so the operator sees
    # the failure); `error` carries the send error OR the miss reason.
    record Sample,
      index : Int32,
      token : String?,
      status : Int32?,
      length : Int32,
      duration_us : Int64,
      error : String?,
      # The gRPC CALL's outcome (`grpc-status`/`grpc-message` trailers) — `status` above is
      # 200 for every gRPC response, so a live-replay collection against a gRPC endpoint that
      # is actually rejecting every call (an expired session token, say) looked identical to
      # one collecting from a healthy target: every sample read "200". nil for a manual-mode
      # sample (no network) and for any non-gRPC response (see `Fuzz::GrpcVerdict`).
      grpc_status : Int32? = nil,
      grpc_message : String? = nil

    # Live counters. `collected` counts successful extractions (the goal is met by
    # these); `sent` is the real request count (always ≥ collected — misses + retries).
    # `sent` is REPLAYS completed — one per collected sample slot, and the numerator that
    # belongs against `goal`. `requests` is what actually went on the wire
    # (`Fuzz::CappedBackend#sent`, the counter `max_requests` is enforced against): a retry
    # costs one there and none in `sent`, so a `--retries 2` collection against a dead origin
    # reported "6 sent" for 18 real requests. Both are published because they answer
    # different questions — progress, and the load the run put on the target.
    record ProgressEvent, collected : Int32, sent : Int32, goal : Int32, errors : Int32,
      requests : Int64 = 0_i64
    record SampleEvent, sample : Sample
    record DoneEvent, collected : Int32, sent : Int32, stopped : Bool, requests : Int64 = 0_i64
    record ErrorEvent, message : String

    # Engine → consumer events. A union of records (matches Fuzz/Miner so a
    # Channel(Event) carries them without boxing). Progress is droppable (latest
    # wins); Sample/Done/Error are never dropped.
    alias Event = SampleEvent | ProgressEvent | DoneEvent | ErrorEvent

    # When a background collection posts to the notification center on completion.
    enum NotifyMode
      WhenDone # default — post when the run finishes (a collection is worth flagging)
      Off      # never post a completion notification
      Always   # post even on a stopped/empty run

      def label : String
        case self
        in WhenDone then "when done"
        in Off      then "off"
        in Always   then "always"
        end
      end

      def token : String
        case self
        in WhenDone then "when-done"
        in Off      then "off"
        in Always   then "always"
        end
      end

      def posts_notification?(collected : Int32, error : Bool = false) : Bool
        return false if off?
        return true if error || always?
        collected > 0
      end

      def self.parse?(token : String) : NotifyMode?
        norm = token.downcase.strip.gsub(/[\s_]+/, "-")
        case norm
        when "when-done", "whendone", "done" then WhenDone
        when "off", "none", "no"             then Off
        when "always", "on", "all"           then Always
        end
      end
    end

    # All knobs for a run. A mutable class (the TUI config overlay binds one
    # instance); the engine only reads it.
    class Config
      property mode : Mode
      property token_loc : TokenLoc
      property goal : Int32 # target successful-extraction count (live mode)
      property concurrency : Int32
      property rps : Float64?
      property throttle_ms : Int32?
      property jitter_ms : Int32
      property timeout : Time::Span?
      property retries : Int32
      property retry_pause : Time::Span
      property max_requests : Int64? # hard cap on real sends (Fuzz::CappedBackend)
      property manual_tokens : Array(String)
      property notify : NotifyMode
      # Reuse ONE connection across the run's samples (see `Plan.build`). On by default, and
      # the escape hatch matters more here than anywhere else in gori: this tool's output is a
      # statistical claim about how an origin generates tokens, so an origin whose session
      # issuance is connection-bound — connection-oriented auth, a gateway pinning a session
      # to a socket — would have its answer shaped by the transport. `--no-keep-alive` lets
      # the operator re-take the sample over fresh connections and compare.
      property? keep_alive : Bool

      # Upper bound on collection to avoid runaway (a wrong descriptor extracts
      # nothing, so a goal counted by hits would never terminate). Any of goal,
      # max_sends, or max_requests reaching its ceiling ends the run.
      GOAL_CEILING = 50_000

      def initialize(@mode = Mode::LiveReplay,
                     @token_loc = TokenLoc.new(ExtractKind::Cookie),
                     @goal = 500, @concurrency = 1, @rps = nil, @throttle_ms = nil,
                     @jitter_ms = 0, @timeout = nil, @retries = 1,
                     @retry_pause = 500.milliseconds, @max_requests = nil,
                     @manual_tokens = [] of String, @notify = NotifyMode::WhenDone,
                     @keep_alive = true)
      end

      # A safety ceiling on real sends: an explicit cap, else twice the goal so a
      # broken extractor terminates instead of spinning forever counting only hits.
      def max_sends : Int64
        if (c = @max_requests) && c > 0
          c
        else
          (@goal.to_i64 * 2).clamp(@goal.to_i64, GOAL_CEILING.to_i64)
        end
      end
    end
  end
end
