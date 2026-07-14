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
    record Job,
      index : Int64,
      payloads : Array(String),
      position : Int32?,
      bytes : Bytes

    # One emitted result row. `length`/`words`/`lines` are computed over the DECODED
    # response body (gzip/deflate/br/zstd inflated). `head`/`body` are retained only
    # per the run's keep_bodies policy (a billion-row cluster bomb can't keep them all).
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
      getter extracted : String?
      getter head : Bytes?
      getter body : Bytes?

      def initialize(@index, @payloads, @position, @status, @length, @words, @lines,
                     @duration_us, @error, @matched, @incomplete, @extracted,
                     @head = nil, @body = nil)
      end
    end

    # Live counters. `total` is nil when the run size is unknown (cluster bomb / brute
    # force overflowing Int64).
    record Progress,
      sent : Int64,
      total : Int64?,
      matched : Int64,
      errors : Int64

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
                     @max_requests : Int64? = nil)
      end
    end
  end
end
