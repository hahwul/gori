require "../issue"
require "../out_of_band"
require "../../store"
require "../../repeater/engine"
require "../../proxy/codec/http1"
require "../../proxy/codec/content_decode"
require "../../miner/inject"
require "../../fuzz/content_length"
require "./insertion_points"

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
      #   oob          — the out-of-band payload minter, present only when this project has a
      #                  registered OAST session. This is what GATES the OAST rules: they are
      #                  ordinary default-ON entries in the Rules sub-tab, but with no listener
      #                  to mint from they `plan` nothing, so nothing is sent and no row appears.
      #                  A capability, not a switch — an operator who never set up an interaction
      #                  server never pays for the checks that need one.
      record Options, allow_unsafe : Bool = false, aggressive : Bool = false,
        oob : OutOfBand::Minter? = nil do
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
      #
      # `oob` carries the OUT-OF-BAND half of the probe: payloads this plan planted whose proof
      # can only arrive later, through an OAST callback rather than through any response the
      # analyzer is about to read. The analyzer records them AFTER a successful primary send
      # (a payload that never left is not outstanding) and never interprets them; promotion is
      # `Probe::OutOfBand.sweep`'s job. Empty for every in-band rule.
      record Plan, request : Bytes, params : Array(Param), dedup_key : String,
        followups : Array(Bytes) = [] of Bytes,
        pipeline : Array(Bytes) = [] of Bytes,
        probe_timeout : Time::Span? = nil,
        oob : Array(OutOfBand::Candidate) = [] of OutOfBand::Candidate

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
        # An UNBRACKETED authority is a whole IPv6 host when it is a valid v6 literal — a
        # port cannot be told apart from the address colons without brackets. Shared with
        # `Upstream.split_host_port`, whose comment states the rule; this copy omitted it, so
        # "::1" split on the last colon into host ":" port 1 and "2001:db8::1" into
        # "2001:db8:". `url_authority` only rejects an EMPTY host, so that garbage reached
        # the open-redirect and host-header rules, where it can only fail to match
        # PROBE_HOST — a missed detection rather than a false one, but silent either way.
        return {authority, nil} if Gori::Proxy::Upstream.valid_ipv6?(authority)
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

        # Shared gate for plan + dedup_key so the two can't drift (equivalence-spec invariant).
        # Returns {surface, the first ≤cap injectable slots} for an eligible flow, else nil. The cap
        # spans ALL enumerated locations at once, so a wide param set can't blow up the request count.
        protected def injectables(detail : Store::FlowDetail, opts : Options, max_params : Int32,
                                  max_params_aggressive : Int32) : {InsertionPoints::Surface, Array(InsertionPoints::Slot)}?
          s = InsertionPoints.enumerate(detail, opts, InsertionPoints::DEFAULT_LOCATIONS) || return nil
          return nil unless diff_method_allowed?(s.method, opts)
          cap = opts.aggressive ? max_params_aggressive : max_params
          slots = s.slots.first(cap)
          return nil if slots.empty?
          {s, slots}
        end

        # How many probe legs each param carries: the followups minus the second baseline, divided
        # over the params. Even (a whole number of pairs) and ≥ 2, else nil to decline — the layout
        # is malformed (e.g. the single-response fallback with no followups).
        protected def legs_per_param(plan : Plan) : Int32?
          n = plan.params.size
          return nil if n == 0
          legs = plan.followups.size - 1 # drop the second baseline
          return nil if legs <= 0 || legs % n != 0
          per = legs // n
          (per >= 2 && per.even?) ? per : nil
        end

        # Whether the captured request body is one an injected value can be spliced into: present,
        # within BODY_CAP, unobfuscated and unencoded, with exactly one injectable Content-Type.
        protected def body_eligible?(detail : Store::FlowDetail) : Bool
          body = detail.request_body || return false
          return false if body.empty? || body.size > BODY_CAP || detail.request_body_truncated?
          return false if Proxy::Codec::Http1.obfuscated_header?(detail.request_head)
          req = Proxy::Codec::Http1.parse_request_head(detail.request_head)
          return false if req.malformed? || req.headers.get?("Transfer-Encoding")
          return false unless req.headers.get_all("Content-Encoding").all? { |v| v.strip.downcase == "identity" }
          types = req.headers.get_all("Content-Type")
          return false unless types.size == 1
          injectable_type?(types.first)
        end

        protected def injectable_type?(value : String) : Bool
          media = value.split(';', 2).first.strip.downcase
          media == "application/x-www-form-urlencoded" || media == "application/json" ||
            (media.starts_with?("application/") && media.ends_with?("+json"))
        end

        protected def path_only(origin_target : String) : String
          qi = origin_target.index('?')
          qi ? origin_target[0...qi] : origin_target
        end

        # A copy of the query pairs with pair `idx`'s value replaced (name kept verbatim).
        protected def with_replaced(pairs : Array(String), idx : Int32, value : String) : String
          dup = pairs.dup
          pair = dup[idx]
          if eq = pair.index('=')
            dup[idx] = "#{pair[0...eq]}=#{value}"
          end
          dup.join('&')
        end

        # Rebuild the request with a new request-line target; headers and body are untouched (no
        # Content-Length change), so no resync is needed.
        protected def rebuild_target(head : Bytes, body : Bytes?, new_target : String) : Bytes
          combined = if body && !body.empty?
                       io = IO::Memory.new(head.size + body.size)
                       io.write(head)
                       io.write(body)
                       io.to_slice
                     else
                       head
                     end
          hbytes, bbytes, eol = Miner::Inject.split(combined)
          lines = String.new(hbytes).split(eol)
          unless lines.empty?
            parts = lines[0].split(' ')
            lines[0] = "#{parts[0]} #{new_target} #{parts[2]}" if parts.size == 3
          end
          io = IO::Memory.new
          io << lines.join(eol) << eol << eol
          io.write(bbytes) unless bbytes.empty?
          io.to_slice
        end

        # Reassemble the request with a new query on the request line, preserving the body and
        # re-syncing Content-Length.
        protected def rebuild_query(orig_head : Bytes, body : Bytes?, path : String, new_query : String) : Bytes
          head, _, eol = Miner::Inject.split(orig_head)
          lines = String.new(head).split(eol)
          unless lines.empty?
            parts = lines[0].split(' ')
            if parts.size == 3
              target = new_query.empty? ? path : "#{path}?#{new_query}"
              lines[0] = "#{parts[0]} #{target} #{parts[2]}"
            end
          end
          io = IO::Memory.new
          io << lines.join(eol) << eol << eol
          b = body || Bytes.empty
          io.write(b) unless b.empty?
          Fuzz::ContentLength.sync(io.to_slice, false)
        end

        # The probe response's status, 0 when its head does not parse.
        protected def probe_status(result : Repeater::Result) : Int32
          if r = result.response
            return r.status
          end
          Proxy::Codec::Http1.parse_response_head(result.head).status
        rescue
          0
        end

        # The probe response's Content-Type, downcased; "" when absent or unparseable.
        protected def response_content_type(result : Repeater::Result) : String
          if r = result.response
            return (r.headers.get?("Content-Type") || "").downcase
          end
          (Proxy::Codec::Http1.parse_response_head(result.head).headers.get?("Content-Type") || "").downcase
        rescue
          ""
        end

        # Inflate (Content-Encoding) and cap at BODY_CAP for a byte-comparable buffer. Capping BOTH
        # sides at the same bound sidesteps capture-truncation skew: only the first BODY_CAP bytes
        # are ever compared. nil when there is no body.
        protected def decoded_body(head : Bytes?, body : Bytes?) : Bytes?
          return nil if body.nil? || body.empty?
          decoded, _ = Proxy::Codec::ContentDecode.decode(head, body, BODY_CAP)
          b = decoded || body
          b[0, {b.size, BODY_CAP}.min]
        end

        # Decode + scrub the response body to text, capped at BODY_CAP. Scrubbing makes the
        # substring and PCRE scans byte-safe on an invalid-UTF-8 origin.
        protected def decoded_text(result : Repeater::Result) : String
          decoded, _ = Proxy::Codec::ContentDecode.decode(result.head, result.body, BODY_CAP)
          bytes = decoded || result.body
          return "" if bytes.nil? || bytes.empty?
          String.new(bytes[0, {bytes.size, BODY_CAP}.min]).scrub
        rescue
          ""
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
