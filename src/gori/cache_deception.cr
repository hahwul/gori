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
  # cache, re-request the SAME url anonymously, then use an anonymous cache-busted query as a
  # control. Matching control content supports a public verdict only when the control itself has
  # no cache-hit signal; a control HIT may mean the cache ignored the query. Matching anonymous
  # content with a cache hit and different control content is a deception candidate. The
  # delimiter tricks that make a cache key an origin ignores (`;`, `.css`, `%00`, …) are the
  # Fuzzer's `cache-delimiters` payload set.
  #
  # This is EXACTLY the shape `Authorize::Engine` already runs — baseline-first (so the
  # authenticated send primes before the anonymous one, ordered not raced), each on its own
  # connection, judged against the baseline — so the engine is reused verbatim. What this module
  # adds are the fixed identities and a verdict that reads the facts Authorize does not: the
  # anonymous response's `Gori::CacheStatus` and the cache-busted control response. The control
  # uses the same `Authorize::Engine` and sender path, with only its request-target varied.
  module CacheDeception
    # The identity whose session the anonymous re-request drops. `Cookie` and `Authorization`
    # are the two the Authorize tab's built-in "anonymous" strips, and they are the credential
    # carriers that make a request "logged in" — dropping them is what makes the second send a
    # no-session one.
    ANONYMOUS_STRIP = ["Cookie", "Authorization"]
    ANONYMOUS_NAME  = "anonymous"
    CACHE_BUST_NAME = "anonymous-cache-busted"

    # The headline for one flow's check.
    enum Verdict
      # The anonymous re-request matched the authenticated response with `cache:hit`, and the
      # cache-busted anonymous control differed. That is a likely cache deception; confirm the
      # body was actually private before writing it up.
      Cached
      # The anonymous re-request got matching content but had no cache-hit evidence, or its
      # cache-busted control matched without cache-hit evidence. It is not confirmed deception.
      Served
      # The anonymous re-request got a SIMILAR-but-not-identical response, or a cache hit on the
      # control left public content unproven. Authorize's `Review` — the operator judges.
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

    # One flow's result: the headline plus its measured trials, so a surface can show the
    # authenticated, anonymous and control responses side by side and let the operator confirm
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
      # The anonymous cache-busted control response, when it was sent.
      getter control : Authorize::Trial?
      # The anonymous response's cache status — the fact that turns "same body" into a candidate.
      getter cache : CacheStatus::Signal
      # gori refused a send here (Sandbox / EXCLUDE), and the first refusal's text.
      getter blocked_reason : String?
      # Requests that passed Outbound's pre-socket block gate.
      getter sent_count : Int32

      def initialize(@flow_id, @method, @url, @verdict, @authenticated, @anonymous,
                     @control, @cache, @blocked_reason, @sent_count)
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

    def self.cache_bust_identity : Authorize::Identity
      Authorize::Identity.new(CACHE_BUST_NAME, remove_headers: ANONYMOUS_STRIP)
    end

    # Why this flow cannot be checked, or nil when it can. Reuses `Authorize::Passive`'s rules so
    # a cache-deception check declines exactly what an authorize replay declines, for the same
    # reasons: an incomplete flow, one gori answered itself, and — unless `unsafe` — an unsafe
    # method, whose replay would run its side effect up to three times (prime, anonymous, control).
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

    # Run the check for one flow through the Authorize engine. The cache-busted control is a
    # third send on the same sender/Outbound path. `stop` is polled before every send by the
    # engine; a partial run is not a verdict.
    def self.check(engine : Authorize::Engine, detail : Store::FlowDetail,
                   stop : Proc(Bool)? = nil) : Report?
      target = engine.run(detail, identities, stop)
      return nil unless target
      sent = target.trials.size - target.blocked.to_i
      return classify(target, sent_count: sent) if target.fully_blocked?
      return classify(target, sent_count: sent) if unanchored?(target)

      anonymous = target.trials.find { |trial| !trial.baseline? }
      cache_candidate = anonymous && anonymous.verdict.same? &&
                        CacheStatus.classify(anonymous.response_head).hit?
      # The cache-busted request distinguishes public content from a cache leak only after an
      # identical anonymous response carries hit evidence. Keep ordinary and protected checks
      # at two sends, especially when the operator opted into an unsafe method.
      return classify(target, sent_count: sent) unless cache_candidate

      request_target = cache_busted_target(detail)
      return classify(target, sent_count: sent) unless request_target
      control_target = engine.run(detail, [cache_bust_identity], stop, request_target: request_target)
      return nil unless control_target
      control = control_target.trials.first?
      return nil unless control

      sent += control_target.trials.size - control_target.blocked.to_i
      classify(target, control, control_blocked: control_target.fully_blocked?,
        control_blocked_reason: control_target.blocked_reason, sent_count: sent)
    end

    # Turn a finished `Authorize::Target` into a cache-deception `Report`. Pure, so it is spec'd
    # without a socket.
    def self.classify(target : Authorize::Target, control : Authorize::Trial? = nil, *,
                      control_blocked : Bool = false, control_blocked_reason : String? = nil,
                      sent_count : Int32 = 0) : Report
      authed = target.trials.find(&.baseline?)
      anon = target.trials.find { |t| !t.baseline? }
      control ||= target.trials.find { |trial| trial.identity == CACHE_BUST_NAME }
      compared_control = control && authed ? compare_control(authed, control) : control
      cache = anon ? CacheStatus.classify(anon.response_head) : CacheStatus::Signal::None
      verdict = verdict_for(target, authed, anon, compared_control, cache, control_blocked)
      Report.new(target.flow_id, target.method, target.url, verdict, authed, anon, compared_control, cache,
        target.blocked_reason || control_blocked_reason, sent_count)
    end

    private def self.compare_control(baseline : Authorize::Trial,
                                     control : Authorize::Trial) : Authorize::Trial
      verdict = Authorize::Judge.verdict(baseline.summary, control.summary)
      delta = Repeater::ExchangeMeta.delta(baseline.meta, control.meta)
      Authorize::Trial.new(control.identity, false, control.meta, verdict, delta, control.summary,
        control.request, control.response_head, control.response_body)
    end

    private def self.verdict_for(target : Authorize::Target, authed : Authorize::Trial?,
                                 anon : Authorize::Trial?, control : Authorize::Trial?,
                                 cache : CacheStatus::Signal, control_blocked : Bool) : Verdict
      # gori refused every send — the strongest fact about traffic that never left (mirrors
      # `Authorize::Target#fully_blocked?`, the false negative it exists to keep out of a report).
      return Verdict::Blocked if target.fully_blocked? || control_blocked
      return Verdict::Errored unless authed && anon
      return Verdict::Errored unless comparison_anchored?(target, authed, anon, control)

      verdict_for_anonymous(authed, anon, control, cache)
    end

    # A failed baseline cannot anchor a comparison; a failed control cannot confirm a candidate.
    private def self.comparison_anchored?(target : Authorize::Target, authed : Authorize::Trial,
                                          anon : Authorize::Trial, control : Authorize::Trial?) : Bool
      # The authenticated baseline could not anchor: it errored, or it was itself denied, so
      # "the anonymous request got the same thing" would describe two failures, not a cache.
      return false unless authed.summary.error.nil? && !target.baseline_denied? && anon.summary.error.nil?
      return true unless control
      control.summary.error.nil?
    end

    private def self.verdict_for_anonymous(authed : Authorize::Trial, anon : Authorize::Trial,
                                           control : Authorize::Trial?, cache : CacheStatus::Signal) : Verdict
      case anon.verdict
      when .same?
        # Without a cache hit there is no cache-deception signal. With a hit, compare a unique
        # anonymous URL: matching content supports a public verdict only if the control has no
        # cache-hit evidence of its own.
        return Verdict::Served unless cache.hit?
        return Verdict::Review unless control
        verdict_for_control(authed, control)
      when .review?
        Verdict::Review
      else # different / baseline
        Verdict::Protected
      end
    end

    private def self.verdict_for_control(authed : Authorize::Trial, control : Authorize::Trial) : Verdict
      case Authorize::Judge.verdict(authed.summary, control.summary)
      when .same?
        # A matching control can prove public content only if the buster got past the cache. If
        # it is a hit too, the query may not be part of the cache key, so leave the result open.
        CacheStatus.classify(control.response_head).hit? ? Verdict::Review : Verdict::Served
      when .different? then Verdict::Cached
      when .review?    then Verdict::Review
      else                  Verdict::Errored
      end
    end

    private def self.unanchored?(target : Authorize::Target) : Bool
      baseline = target.baseline
      anonymous = target.trials.find { |trial| !trial.baseline? }
      baseline.nil? || anonymous.nil? || !baseline.summary.error.nil? || target.baseline_denied? ||
        !anonymous.summary.error.nil?
    end

    private def self.cache_busted_target(detail : Store::FlowDetail) : String?
      bytes = Repeater::FlowRequest.build(detail).bytes
      target = Proxy::Codec::Http1.request_target_line(bytes)
      target_bytes = target.to_slice
      fragment_at = target_bytes.index(0x23_u8) # Keep a raw fragment-like suffix after the query.
      prefix = fragment_at ? target.byte_slice(0, fragment_at) : target
      fragment = fragment_at ? target.byte_slice(fragment_at, target.bytesize - fragment_at) : ""
      separator = if prefix.includes?('?')
                    prefix.ends_with?("?") || prefix.ends_with?("&") ? "" : "&"
                  else
                    "?"
                  end
      query = "#{prefix}#{separator}__gori_cache_bust=#{Random::Secure.hex(8)}#{fragment}"
      Repeater::FlowRequest.replace_request_target(bytes, query) ? query : nil
    end
  end
end
