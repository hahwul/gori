module Gori
  # The Discover engine: spiders a target (follows links a user never clicked) AND
  # brute-forces unlinked directories/paths, feeding every found endpoint back into the
  # Sitemap. Headless and self-contained — it depends only on the Repeater send engines
  # (via the reused Fuzz::Sender/Backend), the body decoder, and a caller-injected scope
  # closure; never on Store or the TUI. The one engine drives the TUI Discover sub-tab,
  # `gori run discover`, and the MCP discover_* tools.
  #
  # Correctness under adversarial/huge sites is the whole point: five independent bounds
  # (max_depth, max_pages, template saturation, content-cluster saturation, and the global
  # max_requests) keep a crawl from running away, and a per-directory soft-404 calibrator
  # keeps the brute-force false-positive rate down.
  module Discover
    # How wide a run may roam from its seed, applied BEFORE the injected scope closure.
    enum Containment
      SameOrigin        # exact scheme+host+port of the seed (strictest)
      HostAndSubdomains # seed host or *.seedhost (no Public Suffix List — naive suffix match)
      ScopeAware        # defer entirely to the injected scope closure

      def label : String
        case self
        in SameOrigin        then "same-origin"
        in HostAndSubdomains then "host+subdomains"
        in ScopeAware        then "scope-aware"
        end
      end

      # Lenient CLI/MCP token decode (case + separators ignored).
      def self.parse?(token : String) : Containment?
        case token.downcase.strip.gsub(/[\s_]+/, "-")
        when "same-origin", "origin", "strict"                                                 then SameOrigin
        when "host", "subdomains", "host+subdomains", "host-and-subdomains", "host-subdomains" then HostAndSubdomains
        when "scope", "scope-aware", "scoped"                                                  then ScopeAware
        end
      end
    end

    # Where a finding came from (also its confidence anchor).
    enum Source
      Seed
      Crawled
      Bruteforced
      Robots
      Sitemap
      Redirect

      def label : String
        case self
        in Seed        then "seed"
        in Crawled     then "crawled"
        in Bruteforced then "bruteforced"
        in Robots      then "robots"
        in Sitemap     then "sitemap"
        in Redirect    then "redirect"
        end
      end
    end

    enum Phase
      Seeding
      Crawling
      Bruteforcing
      Draining

      def label : String
        case self
        in Seeding      then "seeding"
        in Crawling     then "crawling"
        in Bruteforcing then "bruteforcing"
        in Draining     then "draining"
        end
      end
    end

    # One discovered resource. `confidence` (0..1) is the FP/FN dial: crawled/linked
    # resources are high (they exist by construction); brute-forced ones carry the
    # soft-404 divergence score.
    record Finding,
      url : String,
      method : String,
      status : Int32?,
      length : Int64,
      content_type : String?,
      source : Source,
      depth : Int32,
      confidence : Float64,
      note : String?

    # Live counters. `est_total` is a MOVING estimate that RISES as discovery proceeds
    # (a live crawl has no stable denominator), nil early — frontends render
    # "N found · M sent · K queued", not a hard percent. `sent` is the real network count.
    record Progress,
      sent : Int64,
      est_total : Int64?,
      found : Int32,
      errors : Int64,
      queued : Int32,
      phase : Phase

    # End-of-run FP/FN figures (the user's "FP/FN 수치"), also emitted periodically.
    #   calibrated_out      — brute probes the soft-404 calibrator suppressed (FPs avoided)
    #   dedup_suppressed     — URLs skipped by the exact-identity seen set
    #   template_suppressed  — URLs skipped by folded-template saturation (param-explosion guard)
    #   cluster_suppressed   — crawl expansions stopped by content-cluster saturation (template trap)
    #   uncalibratable_dirs  — catch-all dirs where signal is weak (elevated FN risk)
    #   conf_hist            — 4-bucket confidence distribution [.5,.7) [.7,.85) [.85,.95) [.95,1]
    record RunStats,
      sent : Int64,
      found : Int32,
      calibrated_out : Int32,
      dedup_suppressed : Int32,
      template_suppressed : Int32,
      cluster_suppressed : Int32,
      uncalibratable_dirs : Int32,
      conf_hist : Array(Int32)

    # Engine → consumer events (a record union, matching Fuzz/Miner so a Channel(Event)
    # carries them without boxing). Progress is droppable (latest wins); the rest never
    # dropped. `kind` on BaselineEvent is the DirBaseline kind label (a String to keep
    # this file free of a require cycle with calibrate.cr).
    record BaselineEvent, dir : String, kind : String, note : String?
    record FindingEvent, finding : Finding
    record ProgressEvent, progress : Progress
    record DoneEvent, progress : Progress, stats : RunStats, stopped : Bool
    record ErrorEvent, message : String

    alias Event = BaselineEvent | FindingEvent | ProgressEvent | DoneEvent | ErrorEvent

    # All knobs for a run. A mutable class (the TUI config overlay binds one instance);
    # the engine only reads it. Pacing/budget knobs mirror Fuzz::Config / Miner::Config.
    class Config
      # pacing / budget
      property concurrency : Int32
      property rps : Float64?
      property throttle_ms : Int32?
      property jitter_ms : Int32
      property timeout : Time::Span?
      property retries : Int32
      property retry_pause : Time::Span
      property max_requests : Int64? # GLOBAL hard ceiling (CappedBackend) across BOTH engines

      # techniques (default BOTH)
      property? spider : Bool
      property? bruteforce : Bool

      # spider
      property max_depth : Int32           # BFS depth cap from the seed
      property max_pages : Int32           # global crawl page cap
      property? follow_redirects : Bool    # enqueue a 3xx Location as a discovery
      property template_saturation : Int32 # distinct URLs per folded template before it freezes

      # bruteforce
      property user_wordlist : String?
      property extensions : Array(String) # probe /admin AND /admin.php AND /admin.json …
      property per_dir_cap : Int32        # max probe sends per directory (0 = wordlist size)
      property calibrate_probes : Int32   # K bogus paths per directory (2..3)

      # duplicate-content trap guard
      property cluster_saturation : Int32 # distinct URLs per content cluster before its links freeze
      property simhash_distance : Int32   # hamming ≤ this ⇒ same cluster / same-as-baseline

      # scoring
      property confidence_floor : Float64 # min confidence to EMIT a brute finding

      # boundary
      property containment : Containment

      # custom request headers ({name, value}) added to every GET; overrides the
      # default Accept/User-Agent, appended otherwise. Host/Connection are forced by
      # the Sender and ignored here (see Discover::Headers).
      property headers : Array({String, String})

      def initialize(@concurrency = 20, @rps = nil, @throttle_ms = nil, @jitter_ms = 0,
                     @timeout = nil, @retries = 1, @retry_pause = 500.milliseconds, @max_requests = nil,
                     @spider = true, @bruteforce = true,
                     @max_depth = 4, @max_pages = 5000, @follow_redirects = true, @template_saturation = 20,
                     @user_wordlist = nil, @extensions = [] of String, @per_dir_cap = 0, @calibrate_probes = 3,
                     @cluster_saturation = 15, @simhash_distance = 3,
                     @confidence_floor = 0.5, @containment = Containment::ScopeAware,
                     @headers = [] of {String, String})
      end
    end
  end
end
