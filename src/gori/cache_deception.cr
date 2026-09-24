require "./authorize/engine"
require "./authorize/identity"
require "./authorize/passive"
require "./cache_status"
require "./store/models"

module Gori
  # Web cache DECEPTION check (#1247, PortSwigger "Gotta cache 'em all") — a small tool that
  # BORROWS the Authorize engine rather than reimplementing a send loop.
  #
  # The test: replay a captured request as its captured (AUTHENTICATED) identity to PRIME any
  # cache, then re-request the SAME url with NO session, and compare. If the anonymous
  # re-request is served the authenticated response FROM a cache, that private response was
  # cached under a key the anonymous client also hits — a cache deception. The delimiter tricks
  # that make a cache key an origin ignores (`;`, `.css`, `%00`, …) are the Fuzzer's
  # `cache-delimiters` payload set; this confirms the caching for one crafted (or plain) path.
  #
  # This is EXACTLY the shape `Authorize::Engine` already runs — baseline-first (so the
  # authenticated send primes before the anonymous one, ordered not raced), each on its own
  # connection, judged against the baseline — so the engine is reused verbatim. What this module
  # adds is the two fixed identities and a verdict that reads the ONE fact Authorize does not:
  # the anonymous response's `Gori::CacheStatus`. "Anonymous was served the authenticated body"
  # (Authorize's `Same`) plus "and it came from a cache" (a `hit`) is the deception; the same
  # body served WITHOUT a cache hit is a public endpoint, not a finding.
  module CacheDeception
    # The identity whose session the anonymous re-request drops. `Cookie` and `Authorization`
    # are the two the Authorize tab's built-in "anonymous" strips, and they are the credential
    # carriers that make a request "logged in" — dropping them is what makes the second send a
    # no-session one.
    ANONYMOUS_STRIP = ["Cookie", "Authorization"]
    ANONYMOUS_NAME  = "anonymous"

    # The headline for one flow's check.
    enum Verdict
      # The anonymous re-request was served the authenticated response AND it came from a cache
      # (`cache:hit`). The deception: a private response cached under a key an anonymous client
      # hits. Confirm the body was actually private before writing it up.
      Cached
      # The anonymous re-request got matching content but with NO cache-hit evidence. Either the
      # endpoint is genuinely public, or a cache served it without stamping a hit header — the
      # operator judges, but it is not confirmed cache deception.
      Served
      # The anonymous re-request got a SIMILAR-but-not-identical response (same status, divergent
      # body, or an ambiguous redirect). Authorize's `Review` — the operator judges.
      Review
      # The anonymous re-request did NOT get the authenticated response (different status class,
      # unrelated content, or a denial). No private content was served anonymously.
      Protected
      # gori's own outbound gate refused a send (Sandbox / an EXCLUDE rule) before the socket, so
      # nothing was measured.
      Blocked
      # A send failed, or the authenticated baseline could not anchor a comparison (it errored or
      # was itself denied). The check proved nothing.
      Errored

      def label : String
        case self
        in Cached    then "cached"
        in Served    then "served"
        in Review    then "review"
        in Protected then "protected"
        in Blocked   then "blocked"
        in Errored   then "errored"
        end
      end

      # The one an operator acts on — a confirmed cache of a (possibly private) response.
      def deception? : Bool
        self == Cached
      end
    end

    # One flow's result: the headline plus the two trials it was read from, so a surface can
    # show the authenticated and anonymous responses side by side and let the operator confirm
    # the body was private.
    struct Report
      getter flow_id : Int64?
      getter method : String
      getter url : String
      getter verdict : Verdict
      # The authenticated (as-captured) trial — the one that primed the cache. Its response is
      # the private baseline the anonymous one is judged against.
      getter authenticated : Authorize::Trial?
      # The anonymous (no-session) re-request's trial, or nil when the run was stopped before it
      # or never produced one.
      getter anonymous : Authorize::Trial?
      # The anonymous response's cache status — the fact that turns "same body" into "cached".
      getter cache : CacheStatus::Signal
      # gori refused a send here (Sandbox / EXCLUDE), and the first refusal's text.
      getter blocked_reason : String?

      def initialize(@flow_id, @method, @url, @verdict, @authenticated, @anonymous,
                     @cache, @blocked_reason)
      end
    end

    # The two identities, in the order the engine sends them (baseline first): the authenticated
    # as-captured request primes the cache, then the anonymous one re-requests it. `as_captured`
    # is the baseline, so the engine judges the anonymous trial against it.
    def self.identities : Array(Authorize::Identity)
      [
        Authorize::Identity.as_captured,
        Authorize::Identity.new(ANONYMOUS_NAME, remove_headers: ANONYMOUS_STRIP),
      ]
    end

    # Why this flow cannot be checked, or nil when it can. Reuses `Authorize::Passive`'s rules so
    # a cache-deception check declines exactly what an authorize replay declines, for the same
    # reasons: an incomplete flow, one gori answered itself, and — unless `unsafe` — an unsafe
    # method, whose replay would run its side effect twice (once to prime, once anonymous).
    def self.skip_reason(detail : Store::FlowDetail, unsafe : Bool) : Symbol?
      row = detail.row
      return :incomplete unless row.state.complete?
      return :short_circuited if row.short_circuited?
      return :unsafe_method unless unsafe || Authorize::Passive::SAFE_METHODS.includes?(row.method.upcase)
      nil
    end

    # A human sentence for a skip reason — delegates to `Authorize::Passive.reason_label`, the one home for
    # these strings, so the two tools word an identical refusal identically.
    def self.reason_label(reason : Symbol) : String
      Authorize::Passive.reason_label(reason)
    end

    # Run the check for one flow through the Authorize engine. `stop` is polled between the two
    # sends (the engine's own contract). Returns nil ONLY when `stop` fired before the anonymous
    # send — a partial run is not a verdict.
    def self.check(engine : Authorize::Engine, detail : Store::FlowDetail,
                   stop : Proc(Bool)? = nil) : Report?
      target = engine.run(detail, identities, stop)
      return nil unless target
      classify(target)
    end

    # Turn a finished `Authorize::Target` into a cache-deception `Report`. Pure, so it is spec'd
    # without a socket.
    def self.classify(target : Authorize::Target) : Report
      authed = target.trials.find(&.baseline?)
      anon = target.trials.find { |t| !t.baseline? }
      cache = anon ? CacheStatus.classify(anon.response_head) : CacheStatus::Signal::None
      verdict = verdict_for(target, authed, anon, cache)
      Report.new(target.flow_id, target.method, target.url, verdict, authed, anon, cache,
        target.blocked_reason)
    end

    private def self.verdict_for(target : Authorize::Target, authed : Authorize::Trial?,
                                 anon : Authorize::Trial?, cache : CacheStatus::Signal) : Verdict
      # gori refused every send — the strongest fact about traffic that never left (mirrors
      # `Authorize::Target#fully_blocked?`, the false negative it exists to keep out of a report).
      return Verdict::Blocked if target.fully_blocked?
      # The authenticated baseline could not anchor: it errored, or it was itself denied, so
      # "the anonymous request got the same thing" would describe two failures, not a cache.
      return Verdict::Errored if anon.nil? || authed.nil? || authed.verdict.error? ||
                                 target.baseline_denied? || anon.verdict.error?

      case anon.verdict
      when .same?
        # Anonymous was served the authenticated response. It is deception ONLY if that came
        # from a cache — a public endpoint serves everyone the same without one.
        cache.hit? ? Verdict::Cached : Verdict::Served
      when .review?
        Verdict::Review
      else # different / baseline
        Verdict::Protected
      end
    end
  end
end
