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

    # How a token is pulled out of a response. Enum order is the display order in the
    # descriptor editor / config overlay.
    enum ExtractKind
      Cookie   # a Set-Cookie value by name
      Header   # a named response header value
      Regex    # capture group 1 (else whole match) over the decoded body
      Position # a fixed byte range of the decoded body
      JsonPath # a dotted/bracketed path into a JSON body

      def label : String
        case self
        in Cookie   then "cookie"
        in Header   then "header"
        in Regex    then "regex"
        in Position then "position"
        in JsonPath then "jsonpath"
        end
      end

      def self.parse?(token : String) : ExtractKind?
        case token.downcase.strip
        when "cookie", "c"           then Cookie
        when "header", "h"           then Header
        when "regex", "re", "r"      then Regex
        when "position", "pos", "p"  then Position
        when "jsonpath", "json", "j" then JsonPath
        end
      end
    end

    # Where the token lives in a response. One `selector` string is reused per kind
    # (cookie name | header name | regex source | jsonpath expr); Position uses the
    # ints (a half-open byte range over the DECODED body).
    record TokenLoc,
      kind : ExtractKind,
      selector : String = "",
      pos_start : Int32 = 0,
      pos_end : Int32 = 0 do
      def label : String
        case kind
        in ExtractKind::Cookie   then "cookie #{selector.inspect}"
        in ExtractKind::Header   then "header #{selector}"
        in ExtractKind::Regex    then "regex /#{selector}/"
        in ExtractKind::Position then "body[#{pos_start}...#{pos_end}]"
        in ExtractKind::JsonPath then "jsonpath #{selector}"
        end
      end

      def self.cookie(name : String) : TokenLoc
        new(ExtractKind::Cookie, name)
      end
    end

    # One collected token: a network row in live mode, or a pasted line in manual
    # mode. `token` is nil on an extraction miss (still emitted so the operator sees
    # the failure); `error` carries the send error OR the miss reason.
    record Sample,
      index : Int32,
      token : String?,
      status : Int32?,
      length : Int32,
      duration_us : Int64,
      error : String?

    # Live counters. `collected` counts successful extractions (the goal is met by
    # these); `sent` is the real request count (always ≥ collected — misses + retries).
    record ProgressEvent, collected : Int32, sent : Int32, goal : Int32, errors : Int32
    record SampleEvent, sample : Sample
    record DoneEvent, collected : Int32, sent : Int32, stopped : Bool
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

      # Upper bound on collection to avoid runaway (a wrong descriptor extracts
      # nothing, so a goal counted by hits would never terminate). Any of goal,
      # max_sends, or max_requests reaching its ceiling ends the run.
      GOAL_CEILING = 50_000

      def initialize(@mode = Mode::LiveReplay,
                     @token_loc = TokenLoc.new(ExtractKind::Cookie),
                     @goal = 500, @concurrency = 1, @rps = nil, @throttle_ms = nil,
                     @jitter_ms = 0, @timeout = nil, @retries = 1,
                     @retry_pause = 500.milliseconds, @max_requests = nil,
                     @manual_tokens = [] of String, @notify = NotifyMode::WhenDone)
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
