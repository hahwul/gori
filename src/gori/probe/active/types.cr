require "../issue"
require "../../store"
require "../../repeater/engine"

module Gori
  module Probe
    # The lightweight active scan: each rule builds ONE probe per in-scope flow, the analyzer
    # sends it, and the rule interprets the response. Pure: rules depend only on the codec, the
    # body decoder, and the Fuzz sender — no Store/TUI. One rule per file under `active/`;
    # register new ones in `Active::RULES` (active.cr).
    module Active
      BODY_CAP = 64 * 1024

      # Per-flow param budget. The default keeps the automatic scan light (request-size / canary
      # budget); AGGRESSIVE (opts.aggressive) probes wider param sets on an authorized target.
      MAX_PARAMS            =  50 # don't probe pathological param sets
      MAX_PARAMS_AGGRESSIVE = 150 # AGGRESSIVE mode: cover wide queries/forms too

      # Methods WITHOUT side effects — probed by default. The active scan normally runs
      # automatically over captured traffic, so re-sending a POST/PUT/PATCH/DELETE with canary
      # values would cause real server-side mutations (duplicate records, messages, deletions).
      # Reflected-XSS via query parameters — the common case — is fully covered by GET/HEAD.
      # Unsafe methods are probed ONLY when the caller opts in (Options#allow_unsafe): the manual
      # per-flow "Run active scan" or AGGRESSIVE mode over in-scope traffic.
      SAFE_METHODS = Set{"GET", "HEAD"}

      # Per-scan knobs threaded into every rule's `plan`/`dedup_key`, so a rule stays a pure
      # function of (flow, opts). The DEFAULT (both false) reproduces the historic safe-method,
      # base-cap behaviour, so any 1-arg caller is unchanged.
      #   allow_unsafe — widen the method gate beyond SAFE_METHODS (re-sends POST/PUT/PATCH/DELETE).
      #   aggressive   — raise per-rule caps (MAX_PARAMS_AGGRESSIVE, MAX_PROBE_PARAMS_AGGRESSIVE)
      #                  and use the wider bypass-header set.
      record Options, allow_unsafe : Bool = false, aggressive : Bool = false do
        DEFAULT = new

        # The param budget for this scan (aggressive raises it).
        def max_params : Int32
          aggressive ? MAX_PARAMS_AGGRESSIVE : MAX_PARAMS
        end
      end

      record Param, location : String, name : String, canary : String

      # A built probe: the (primary) request bytes, the canary↔param map, the dedup key the analyzer
      # uses to probe each (rule, host, method, path, param-set) only once, and — for a differential
      # rule — any FOLLOW-UP requests. The analyzer sends `request` first, then each entry of
      # `followups` in order, and hands every response to `detections_all` (primary first). Single-
      # probe rules leave `followups` empty, so exactly one request is sent (the historic behaviour).
      #
      # `pipeline` is a SAME-CONNECTION request GROUP: the analyzer sends it AFTER `request` +
      # `followups` on ONE dedicated socket, back-to-back and in order, via `Fuzz::Backend#send_pipeline`
      # (`Repeater::Engine.send_pipeline` underneath), and appends its results in order — so
      # `detections_all` sees `[primary, followups…, pipeline…]`. This is the ONE thing a fresh
      # connection per send can never reveal: a desync induced by pipeline member N surfaces only as a
      # corrupted/misaligned response to member N+1 on the same socket. The active request-smuggling /
      # desync rule is the only one that uses it (a CL.TE/TE.CL/TE.TE probe sequence); `probe_timeout`
      # bounds those sends tighter than the analyzer's ACTIVE_TIMEOUT so an INCOMPLETE timing probe
      # returns (via a read timeout) well inside the per-probe budget. An EMPTY `pipeline` (every other
      # rule) is a strict no-op — the branch is skipped and behaviour is byte-for-byte unchanged. Both
      # tail-default so all existing `Plan.new` sites (≤4 positional args) keep compiling untouched.
      record Plan, request : Bytes, params : Array(Param), dedup_key : String,
        followups : Array(Bytes) = [] of Bytes,
        pipeline : Array(Bytes) = [] of Bytes,
        probe_timeout : Time::Span? = nil

      # Strip a scheme://authority prefix so an absolute-form (forward-proxy) target becomes
      # origin-form; an already-origin-form target passes through unchanged. The authority
      # ends at the FIRST '/', '?', or '#', so a pathless absolute-URI carrying a query
      # ("http://h?q=v") normalizes to "/?q=v" — the query (and its reflectable params) is
      # preserved, not silently dropped to "/" — and a '/' that appears only INSIDE the query
      # ("http://h?next=/x") is never mistaken for the start of the path.
      def self.origin_form(target : String) : String
        return target unless target.starts_with?("http://") || target.starts_with?("https://")
        scheme_end = target.index("://") || return target
        rest = target[(scheme_end + 3)..]
        # Find the authority terminator with Char index, not a regex: `target` derives from a
        # captured request and can be invalid UTF-8, which would make a PCRE `index(/[\/?#]/)`
        # raise on the active-probe planning path (only partly rescued). index(Char) is byte-safe
        # and preserves the target's bytes for the re-sent probe. Mirrors from_repeater.cr's idiom.
        cut = [rest.index('/'), rest.index('?'), rest.index('#')].compact.min? || return "/"
        seg = rest[cut..]
        seg.starts_with?('/') ? seg : "/#{seg}"
      end

      # The true authority HOST (lower-cased) and optional port of an absolute
      # (`scheme://[user@]host[:port]/…`) or scheme-relative (`//host[:port]/…`) URL — nil for a
      # relative path, an unparseable value, or an empty authority. This is the SECURITY-CRITICAL
      # guard the open-redirect / host-header rules confirm against: it must return the host AFTER
      # any `user@` userinfo, so `https://gori-probe.example@evil.test/` reports `evil.test` (the
      # real redirect target) — NOT our probe host — and the rule does not false-fire.
      #
      # Two subtleties, both deliberate:
      #   * `://` is honored ONLY when the text before it is a valid scheme (letter, then
      #     letter/digit/+/-/.), so a RELATIVE `Location: /go?next=https://x` — where `://` sits in
      #     the query — is correctly read as relative (nil), not as a redirect to `x`.
      #   * `String#scrub` first: a captured Location/body value can carry a non-UTF-8 byte, which
      #     would make the Char scans raise; scrub keeps this total (the byte-safety convention).
      def self.url_authority(s : String) : {String, Int32?}?
        str = s.scrub.strip
        authority =
          if (se = str.index("://")) && valid_scheme?(str[0...se])
            str[(se + 3)..]
          elsif str.starts_with?("//")
            str[2..]
          else
            return nil
          end
        # Authority ends at the first '/', '?' or '#'.
        cut = [authority.index('/'), authority.index('?'), authority.index('#')].compact.min?
        authority = authority[0...cut] if cut
        # Drop userinfo up to and including the LAST '@' — the host is what follows.
        if at = authority.rindex('@')
          authority = authority[(at + 1)..]
        end
        return nil if authority.empty?
        host, port = split_host_port(authority)
        return nil if host.empty?
        {host.downcase, port}
      end

      # A valid URI scheme: a leading letter then letter/digit/'+'/'-'/'.' (RFC 3986). Empty or a
      # value carrying '/','?','#',… (i.e. text before a `://` that sits inside a path/query) fails.
      private def self.valid_scheme?(s : String) : Bool
        return false if s.empty?
        s.each_char_with_index do |c, i|
          if i == 0
            return false unless c.ascii_letter?
          else
            return false unless c.ascii_alphanumeric? || c == '+' || c == '-' || c == '.'
          end
        end
        true
      end

      # Split "host[:port]" (host may be a "[::1]" IPv6 literal) into {host, port?}.
      private def self.split_host_port(authority : String) : {String, Int32?}
        if authority.starts_with?('[')
          close = authority.index(']') || return {authority, nil}
          host = authority[1...close]
          rest = authority[(close + 1)..]
          return {host, rest.starts_with?(':') ? rest[1..].to_i? : nil}
        end
        if (colon = authority.rindex(':')) && (p = authority[(colon + 1)..].to_i?)
          return {authority[0...colon], p}
        end
        {authority, nil}
      end

      # An active rule: build a probe for one flow (nil if nothing to test), then turn the
      # probe's response into Detections. The analyzer owns the send between the two calls.
      abstract class Rule
        # The probe's dedup key WITHOUT building the probe — same value as `plan(detail).dedup_key`
        # (nil exactly when `plan` returns nil). The analyzer checks this against the seen-set
        # BEFORE calling `plan`, so a repeat surface (the common case in steady browsing) skips
        # the expensive canary generation + request rebuild that `plan` does. MUST stay identical
        # to the key `plan` produces or the seen-set would re-probe / skip (see the equivalence spec).
        abstract def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
        abstract def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
        abstract def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)

        # Whether METHOD (already upcased) is eligible for a rule gated to SAFE_METHODS. Unsafe
        # methods pass only under an explicit opt-in (manual per-flow scan / AGGRESSIVE mode).
        protected def method_allowed?(method_upcase : String, opts : Options) : Bool
          opts.allow_unsafe || SAFE_METHODS.includes?(method_upcase)
        end

        # Whether METHOD (already upcased) is eligible for a BODY-DIFFERENTIAL rule (compares
        # response bodies, so HEAD is always out). By default GET only; opts.allow_unsafe widens
        # to any body-bearing method (POST/PUT/PATCH/DELETE) but never HEAD.
        protected def diff_method_allowed?(method_upcase : String, opts : Options) : Bool
          return false if method_upcase == "HEAD"
          opts.allow_unsafe || method_upcase == "GET"
        end

        # Interpret ALL of a plan's probe responses at once: the primary (`plan.request`) first,
        # then one per `plan.followups` entry, in the SAME order they were built. The analyzer calls
        # this after sending them all. The default ignores follow-ups and interprets only the primary
        # via `detections`, so a single-probe rule (no follow-ups) implements just `detections` and
        # behaves exactly as before. A DIFFERENTIAL rule (non-empty `plan.followups`) overrides this
        # to compare the responses (e.g. baseline vs `\` vs `\\`); its `detections` stays a thin
        # single-response fallback. `results` is never empty when the primary send succeeded.
        def detections_all(plan : Plan, results : Array(Repeater::Result), detail : Store::FlowDetail) : Array(Detection)
          first = results.first?
          first ? detections(plan, first, detail) : [] of Detection
        end

        # Static identity for the Rules sub-tab (list + per-rule enable/disable). One RuleInfo
        # per class; the analyzer skips a rule when its `info.id` is in the project disabled set.
        abstract def info : RuleInfo

        # How many probe requests this rule sends for ONE qualifying flow — drives the manual
        # "Run active scan" estimate and the Rules sub-tab annotation. Every rule today sends
        # exactly one (a rule that tests many params stuffs them all into a single request); a
        # future multi-probe rule overrides this with its own (possibly wider) range.
        def requests_per_flow : Range(Int32, Int32)
          1..1
        end
      end
    end
  end
end
