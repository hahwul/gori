module Gori
  # The parameter-mining engine ("Param Miner"): discovers hidden/unlinked
  # parameters a server accepts but that aren't in the captured request. It stuffs a
  # BATCH of candidate names (each with a unique canary value) into a location in ONE
  # request, diffs the response against a calibrated baseline, then BINARY-SEARCHES
  # the batch to isolate the responsible name — far cheaper than one name per request.
  #
  # Headless and self-contained: it depends only on the Repeater send engines (via the
  # reused Fuzz::Sender/Backend), the body decoder, and Fuzz::ContentLength — never on
  # Store or the TUI. The one engine drives the TUI Miner tab, `gori run mine`, and the
  # MCP mine_* tools.
  module Miner
    # Where candidate names are injected. Enum order is also the display order in the
    # config overlay.
    enum Location
      Query
      Form
      Json
      Headers
      Cookies

      def label : String
        case self
        in Query   then "query"
        in Form    then "form"
        in Json    then "json"
        in Headers then "headers"
        in Cookies then "cookies"
        end
      end

      # The location a CLI/MCP token names (lenient: case/whitespace-insensitive).
      def self.parse?(token : String) : Location?
        case token.downcase.strip
        when "query", "q"             then Query
        when "form", "body", "f"      then Form
        when "json", "j"              then Json
        when "header", "headers", "h" then Headers
        when "cookie", "cookies", "c" then Cookies
        end
      end
    end

    # Why a name was flagged. Reflection is self-identifying (its canary echoed); the
    # rest are metric diffs isolated by bisection.
    enum Evidence
      Reflection
      Status
      Length
      Words
      Lines

      def label : String
        case self
        in Reflection then "reflection"
        in Status     then "status"
        in Length     then "length"
        in Words      then "words"
        in Lines      then "lines"
        end
      end
    end

    enum Confidence
      Confirmed # reproduced alone AND baseline stable AND location not reflection-only
      Tentative # signal seen but confirm inconclusive / baseline unstable

      def label : String
        confirmed? ? "confirmed" : "tentative"
      end
    end

    # When a background mine posts to the notification center on completion.
    # Persisted/config tokens: "when-found", "off", "always" (see #token / .parse?).
    enum NotifyMode
      WhenFound # default — only when at least one parameter was discovered
      Off       # never post a completion notification
      Always    # always post, even when zero parameters were found

      def label : String
        case self
        in WhenFound then "when found"
        in Off       then "off"
        in Always    then "always"
        end
      end

      # Canonical persisted token (round-trips through JSON config).
      def token : String
        case self
        in WhenFound then "when-found"
        in Off       then "off"
        in Always    then "always"
        end
      end

      # True when a finished mine should post to the notification center.
      def posts_notification?(found : Int32, error : Bool = false) : Bool
        return false if off?
        return true if error
        return false if when_found? && found == 0
        true
      end

      def self.parse?(token : String) : NotifyMode?
        norm = token.downcase.strip.gsub(/[\s_]+/, "-")
        case norm
        when "when-found", "whenfound", "found" then WhenFound
        when "off", "none", "no"                then Off
        when "always", "on", "all"              then Always
        end
      end
    end

    # One discovered parameter.
    record Finding,
      name : String,
      location : Location,
      evidence : Evidence,
      confidence : Confidence,
      canary : String?, # the value that reflected (nil for metric-based)
      status : Int32?,  # observed response status when isolated
      delta : Int64     # observed length delta vs baseline (0 for pure reflection)

    # Live counters. `names_done/names_total` is the stable progress bar; `sent` is the
    # real request count (always larger — bucketing + bisection + confirmation).
    record Progress,
      names_total : Int64,
      names_done : Int64,
      sent : Int64,
      found : Int32,
      errors : Int64

    # Engine → consumer events. A union of records (matches Fuzz's pattern so a
    # Channel(Event) carries them without boxing). Progress is droppable (latest wins);
    # Baseline/Finding/Done/Error are never dropped.
    record BaselineEvent, stable : Bool, warning : String?
    record FindingEvent, finding : Finding
    record ProgressEvent, progress : Progress
    record DoneEvent, progress : Progress, stopped : Bool
    record ErrorEvent, message : String

    alias Event = BaselineEvent | FindingEvent | ProgressEvent | DoneEvent | ErrorEvent

    # Fixed-length canary so no canary can be a substring of another (which would
    # wrongly attribute a reflection). "gq" + 8 lower-hex chars — all URL/JSON/header/cookie
    # safe, so it survives any location's encoding verbatim and reflects unchanged.
    module Canary
      LEN = 10 # "gq" + 8 hex

      def self.fresh : String
        "gq#{Random::Secure.hex(4)}"
      end

      # A random name that almost certainly does not exist — for the per-location
      # baseline control (does the app react to ANY unknown param here?).
      def self.bogus_name : String
        "zz#{Random::Secure.hex(5)}"
      end
    end

    # All knobs for a run. A mutable class (the TUI config overlay binds one instance);
    # the engine only reads it.
    class Config
      property locations : Array(Location)
      property bucket_size : Hash(Location, Int32)
      property concurrency : Int32
      property rps : Float64?
      property throttle_ms : Int32?
      property jitter_ms : Int32
      property timeout : Time::Span?
      property retries : Int32
      property retry_pause : Time::Span
      property stability_rounds : Int32 # baseline resends to learn tolerance
      property confirm_rounds : Int32   # isolate re-tests before Confirmed
      property max_requests : Int64?    # hard cap on total sends
      property? add_content_length_when_missing : Bool
      property user_wordlist : String?
      property notify : NotifyMode

      # Per-Burp ceilings; query/form are additionally clamped by the URL byte budget
      # in Inject so a stuffed line can't exceed common request-line limits.
      DEFAULT_BUCKETS = Hash(Location, Int32){
        Location::Json    => 256,
        Location::Query   => 128,
        Location::Form    => 128,
        Location::Headers => 64,
        Location::Cookies => 64,
      }

      def initialize(@locations = [Location::Query],
                     @bucket_size = DEFAULT_BUCKETS.dup,
                     @concurrency = 10, @rps = nil, @throttle_ms = nil, @jitter_ms = 0,
                     @timeout = nil, @retries = 1, @retry_pause = 500.milliseconds,
                     @stability_rounds = 4, @confirm_rounds = 2, @max_requests = nil,
                     @add_content_length_when_missing = false, @user_wordlist = nil,
                     @notify = NotifyMode::WhenFound)
      end

      def bucket_for(loc : Location) : Int32
        (@bucket_size[loc]? || 64).clamp(1, 1024)
      end
    end
  end
end
