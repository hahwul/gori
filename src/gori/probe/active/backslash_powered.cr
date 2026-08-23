require "uri"
require "./types"
require "./insertion_points"
require "../../miner/types"
require "../../proxy/codec/http1"
require "../../proxy/codec/content_decode"

module Gori
  module Probe
    module Active
      # Backslash-powered scanning (James Kettle, PortSwigger 2016 —
      # https://portswigger.net/research/backslash-powered-scanning-hunting-unknown-vulnerability-classes).
      # The idea: tell whether a parameter is treated as inert DATA or is fed to a server-side
      # string INTERPRETER (SQL, a template/expression engine, a shell, …) — without relying on a
      # specific error message — by exploiting how a backslash escapes.
      #
      # For each parameter it sends three requests that carry the param's ORIGINAL value with a
      # suffix appended:
      #   baseline  value          (unchanged)
      #   single    value\         (a lone trailing backslash)
      #   double    value\\        (an escaped, i.e. literal, backslash)
      # A value that is pure data is unaffected by either suffix, so all three responses match. But
      # inside a string interpreter the LONE `\` escapes the next character (often the closing
      # delimiter) and breaks parsing, while the DOUBLED `\\` is just a literal backslash and parses
      # cleanly. So the tell is an ASYMMETRY: `single` differs from `baseline` while `double` matches
      # it. That asymmetry — not any single error string — is what flags a probable injection surface.
      #
      # The comparison assumes the endpoint answers the same request the same way twice, so it sends
      # the baseline TWICE and reports nothing unless the two agree: on an endpoint that varies on
      # its own (an intermittent 503, a rate limiter, a rotating backend) noise landing on a `\` leg
      # but not its `\\` leg reproduces this exact asymmetry, once per probed param. Measuring the
      # endpoint against itself turns "we cannot tell" into a decline instead of a finding.
      #
      # This is the active scanner's first DIFFERENTIAL (multi-probe) rule: `plan` builds two
      # baselines plus a `\`/`\\` pair per param into `Plan.followups`, the analyzer sends them all,
      # and `detections_all` compares the responses. The differential compares BODIES, so HEAD is always
      # out; by default GET only (POST/PUT/… are never auto-probed — they mutate state), but an
      # explicit opt-in (Options#allow_unsafe: the manual per-flow scan or AGGRESSIVE mode) widens
      # it to any body-bearing method. Capped at MAX_PROBE_PARAMS params (raised under AGGRESSIVE)
      # so a wide param set can't blow up the request count. Insertion points come from the shared
      # `InsertionPoints` model (query today).
      class BackslashPowered < Rule
        # Probe at most this many params per flow (in enumeration order, across all locations).
        # Bounds the request count and keeps the automatic scan light-touch; a wider set is still
        # covered for its first params. AGGRESSIVE (opts.aggressive) raises the cap.
        MAX_PROBE_PARAMS            =  3
        MAX_PROBE_PARAMS_AGGRESSIVE = 10

        # Appended (URL-encoded, wire-ready, so it decodes to a real backslash server-side).
        SINGLE = "%5C"    # one backslash  →  value\
        DOUBLE = "%5C%5C" # two backslashes →  value\\

        def info : RuleInfo
          RuleInfo.new("backslash_powered", "Backslash-powered scanning",
            "Appends \\ and \\\\ to each query parameter; flags a parameter where the lone backslash " \
            "perturbs the response but the doubled one does not (server-side string interpretation).",
            Category::ACTIVE)
        end

        # TWO baselines + a (`\`, `\\`) pair per probed param: 1 param → 4 requests,
        # MAX_PROBE_PARAMS → 8. Static annotation for the Rules sub-tab + the manual-run estimate
        # (the analyzer sends the exact count for the flow at hand).
        def requests_per_flow : Range(Int32, Int32)
          4..(2 + 2 * MAX_PROBE_PARAMS)
        end

        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          s, slots = injectables(detail, opts) || return nil
          InsertionPoints.dedup_key("backslash_powered", detail, s.method, s.path, slots)
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          s, slots = injectables(detail, opts) || return nil
          baseline = InsertionPoints.build(detail, InsertionPoints::NO_CHANGES)
          # A SECOND, identical baseline, sent first among the follow-ups. The whole rule is a
          # difference test against the baseline fingerprint, which silently assumed the endpoint
          # answers the same request the same way twice. When it does not — an intermittent 503, a
          # rate limiter kicking in, a health-checked backend rotating — noise that happens to land
          # on a `\` leg and not its `\\` leg reproduces the exact asymmetry this rule reports, and
          # every param gets its own roll of that die. Measuring the endpoint against itself costs
          # one request and turns "we cannot tell" into a decline instead of a finding.
          followups = [InsertionPoints.build(detail, InsertionPoints::NO_CHANGES)]
          params = [] of Param
          slots.each do |slot|
            # Order matters: single (`\`) then double (`\\`) — detections_all reads them back at
            # results[2 + 2*i] / results[3 + 2*i] for the i-th param (results[0] and results[1]
            # are the two baselines).
            followups << InsertionPoints.build(detail, [{slot, InsertionPoints::Change.new(suffix: SINGLE)}])
            followups << InsertionPoints.build(detail, [{slot, InsertionPoints::Change.new(suffix: DOUBLE)}])
            params << Param.new(slot.loc.label, slot.name, slot.raw_value)
          end
          key = InsertionPoints.dedup_key("backslash_powered", detail, s.method, s.path, slots)
          Plan.new(baseline, params, key, followups)
        end

        # Compare the responses: for each probed param, fire when the lone `\` changed the response
        # (status or a surfaced interpreter error) AND the doubled `\\` reverted to baseline. One
        # grouped Detection per host, listing the affected params.
        # results = [baseline, baseline2, single_0, double_0, single_1, double_1, …].
        def detections_all(plan : Plan, results : Array(Repeater::Result), detail : Store::FlowDetail) : Array(Detection)
          base, with_size = stable_baseline(results) || return [] of Detection
          hits = [] of String
          plan.params.each_with_index do |param, i|
            single = results[2 + 2 * i]?
            double = results[3 + 2 * i]?
            next unless single && double
            next unless single.ok? && double.ok? # a failed leg ⇒ incomplete comparison, skip
            sa = attrs(single, with_size)
            da = attrs(double, with_size)
            # The asymmetry that marks an escape being interpreted. A reflecting/echoing endpoint
            # changes for BOTH the `\` and `\\` forms (no asymmetry) and is never flagged here.
            hits << "#{param.name}#{describe_break(base, sa)}" if sa != base && da == base
          end
          return [] of Detection if hits.empty?
          [Detection.new("backslash_powered", Category::ACTIVE, detail.row.host, detail.row.url,
            "Server-side string interpretation (backslash escaping)", Store::Severity::Medium,
            hits.join(", ")[0, 120], detail.row.id)]
        rescue
          [] of Detection
        end

        # Single-response fallback (module facade / a one-shot caller): the differential needs the
        # follow-up probes, so one response alone yields nothing. The analyzer always calls
        # detections_all with the full set.
        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          detections_all(plan, [result], detail)
        end

        # Shared gate for plan + dedup_key so the two can't drift (equivalence-spec invariant).
        # Returns {surface, the first ≤cap injectable slots} for an eligible flow, else nil. The cap
        # spans ALL enumerated locations at once, so a wide param set can't blow up the request count.
        private def injectables(detail : Store::FlowDetail, opts : Options) : {InsertionPoints::Surface, Array(InsertionPoints::Slot)}?
          s = InsertionPoints.enumerate(detail, opts, InsertionPoints::DEFAULT_LOCATIONS) || return nil
          # Body-differential gate: the comparison reads response BODIES (HEAD has none), so HEAD is
          # always out. By default GET only — the automatic scan never auto-re-sends a state-changing
          # method — but opts.allow_unsafe (manual per-flow scan / AGGRESSIVE mode) widens to
          # POST/PUT/PATCH/DELETE, whose params can still be interpreted server-side.
          return nil unless diff_method_allowed?(s.method, opts)
          cap = opts.aggressive ? MAX_PROBE_PARAMS_AGGRESSIVE : MAX_PROBE_PARAMS
          slots = s.slots.first(cap)
          return nil if slots.empty?
          {s, slots}
        end

        # {baseline fingerprint, whether body LENGTH is part of it} — but only when the endpoint
        # reproduced that fingerprint on a SECOND identical request (results[0] and results[1]).
        # nil when either baseline is missing or failed to send, or when the two disagree even
        # ignoring length: an endpoint whose answer to one request varies on its own cannot support
        # a difference test, so every asymmetry below would be a coin flip.
        #
        # The length decision is what the second baseline buys beyond the stability check. Status +
        # error-class alone missed the technique's central signal — a body that changes COMPLETELY
        # with no status flip and no recognised error string read as "identical" — but adding length
        # blindly would have fired on every page with a timestamp in it. Asking the endpoint whether
        # its own length is reproducible answers that per target instead of guessing globally: a
        # length-stable endpoint gets the sharper comparison, a jittery one falls back to the
        # historic status + error-class fingerprint rather than losing the check entirely.
        private def stable_baseline(results : Array(Repeater::Result)) : { {Int32, String?, Int32}, Bool }?
          first = results[0]?
          second = results[1]?
          return nil unless first && first.ok? && second && second.ok?
          sized = attrs(first, true)
          return {sized, true} if sized == attrs(second, true)
          blind = attrs(first, false)
          blind == attrs(second, false) ? {blind, false} : nil
        end

        # A comparable response fingerprint: status code, a coarse interpreter-error class (nil when
        # the body shows none), and — when `with_size` — the decoded body length. Two responses are
        # "the same" iff all three match. Still not a byte diff: length moves only when the body
        # really changed shape, so ordinary same-length content jitter doesn't read as a difference.
        # `with_size: false` substitutes a constant, so a jittery endpoint compares on the other two.
        private def attrs(result : Repeater::Result, with_size : Bool) : {Int32, String?, Int32}
          body = decoded_body(result)
          {response_status(result), error_signature_of(body), with_size ? body.bytesize : -1}
        end

        private def response_status(result : Repeater::Result) : Int32
          if r = result.response
            return r.status
          end
          Proxy::Codec::Http1.parse_response_head(result.head).status
        rescue
          0
        end

        # Known server-side interpreter/parser error fingerprints. Presence is a strong signal, but
        # it only STRENGTHENS the differential (severity/evidence) — the rule fires on the `\` vs
        # `\\` asymmetry whether or not a signature matched (e.g. a bare 200→500 flip).
        ERROR_SIGNATURES = {
          "SQL" => ["you have an error in your sql syntax", "sqlstate", "unclosed quotation mark",
                    "quoted string not properly terminated", "unterminated quoted string",
                    "warning: mysql", "mysqli", "pg::", "psql", "ora-0", "odbc", "sqlite"],
          "syntax" => ["unterminated string", "unexpected end of", "unexpected token",
                       "syntaxerror", "parse error", "invalid escape", "eol while scanning"],
        }

        private def error_signature_of(body : String) : String?
          return nil if body.empty?
          hay = body.downcase
          ERROR_SIGNATURES.each do |label, needles|
            return label if needles.any? { |n| hay.includes?(n) }
          end
          nil
        end

        private def decoded_body(result : Repeater::Result) : String
          decoded, _ = Proxy::Codec::ContentDecode.decode(result.head, result.body, BODY_CAP)
          bytes = decoded || result.body
          return "" unless bytes && !bytes.empty?
          String.new(bytes[0, {bytes.size, BODY_CAP}.min]).scrub
        rescue
          ""
        end

        # A short human tag for the evidence line: prefer the interpreter-error class, else the
        # status flip, else nothing (a difference the fingerprint can't name).
        private def describe_break(base : {Int32, String?, Int32}, single : {Int32, String?, Int32}) : String
          if err = single[1]
            " (#{err} error)"
          elsif single[0] != base[0]
            " (#{base[0]}→#{single[0]})"
          elsif single[2] >= 0 && single[2] != base[2]
            # Same status, no recognised error string, but the body changed shape — the case the
            # old status-only fingerprint reported as "identical" and silently dropped.
            " (body #{base[2]}→#{single[2]} bytes)"
          else
            ""
          end
        end
      end
    end
  end
end
