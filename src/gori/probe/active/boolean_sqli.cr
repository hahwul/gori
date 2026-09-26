require "./types"
require "./insertion_points"
require "../../proxy/codec/http1"
require "../../proxy/codec/content_decode"
require "../../discover/fingerprint"

module Gori
  module Probe
    module Active
      # Boolean-based blind SQL injection. Where `error_based_sqli` needs the backend to LEAK a
      # verbose parser diagnostic, this rule confirms an injection that produces NO error and NO
      # visible reflection — the classic blind case — by asking the endpoint a pair of questions
      # whose only difference is a SQL truth value.
      #
      # For each param it appends a breakout that keeps the statement valid but forces the injected
      # predicate TRUE (`… AND '1'='1`) and, separately, FALSE (`… AND '1'='2`). If the value is
      # concatenated into a SQL WHERE, the TRUE leg returns the SAME rows as the baseline (the extra
      # always-true clause is a no-op) while the FALSE leg returns a DIFFERENT page (typically empty
      # / "not found"). The tell is that differential BETWEEN the two probe legs — not probe-vs-
      # baseline, which `error_based_sqli` already covers and which a blind injection never trips.
      #
      # The "same page modulo dynamic tokens" question is answered with the 64-bit content SimHash
      # from `discover/fingerprint.cr` — the same tool (and the same `simhash_distance` default of 3)
      # the crawler uses to decide "is this body the soft-404 baseline again?". It ignores pure-
      # numeric / long-hex / uuid tokens, so a timestamp or CSRF field jittering between requests
      # does not move the hash. Two responses are treated as the SAME iff their HTTP status matches
      # AND their SimHashes are within `SIMHASH_DISTANCE` hamming.
      #
      # That distance is also the rule's RECALL boundary, on purpose: it detects the "full vs empty /
      # not-found" shape a blind boolean break usually produces. An injection whose FALSE leg drops
      # only a row or two from a large listing can stay within `SIMHASH_DISTANCE` of the baseline and
      # read as "same" — a missed detection, the safe direction. Tightening the radius to catch it
      # would start reporting ordinary content jitter as an oracle, so the boundary stays where the
      # crawler's calibration put it.
      #
      # Two false-positive guards stack (the shape `backslash_powered` uses):
      #   * a SECOND identical baseline (results[1]) proves the endpoint answers the same request
      #     the same way twice. A self-varying page (an A/B split, a rotating backend, a rate
      #     limiter) whose two baselines already disagree cannot support a difference test, so the
      #     whole flow DECLINES rather than reading its own jitter as a boolean oracle.
      #   * the TRUE leg must match the baseline. That is what suppresses REFLECTION: an endpoint
      #     that echoes the payload renders the `AND '1'='1` text into its body, so the TRUE leg
      #     differs from the baseline and the param is skipped. It also suppresses an INERT param,
      #     whose TRUE and FALSE legs are both unchanged, so the FALSE leg matches the baseline and
      #     the differential is empty. Only "TRUE == baseline AND FALSE != baseline" fires.
      #
      # A confirmed blind injection is a stronger, more directly exploitable result than a single
      # error echo, so this reports Critical — outranking `error_based_sqli`'s High. Insertion
      # points come from the shared `InsertionPoints` model (query/form/json). The differential
      # reads BODIES, so HEAD is always out; by default GET only, widened to body-bearing methods
      # under `allow_unsafe` (manual per-flow scan / AGGRESSIVE), exactly like the sibling rules.
      class BooleanBlindSqli < Rule
        # Probe at most this many params per flow (enumeration order, across all locations). The
        # default keeps the automatic scan light-touch and — with the single default breakout —
        # bounds a probed flow at 2 baselines + 2 legs × 3 params = 8 requests, the same ceiling
        # the other default-ON differential rules hold to. AGGRESSIVE raises both the cap and the
        # breakout set (below).
        MAX_PROBE_PARAMS            =  3
        MAX_PROBE_PARAMS_AGGRESSIVE = 10

        # Hamming radius under which two SimHashes are "the same body". The crawler's default
        # (`Discover::Options#simhash_distance`), reused so the two calibrations agree on what a
        # dynamic-token-insensitive "same page" means.
        SIMHASH_DISTANCE = 3

        # A TRUE/FALSE breakout pair, URL-encoded (wire-ready) so `InsertionPoints::Change#suffix`
        # splices it onto the param's raw value with no re-encode (the RAW strategy). The two legs
        # differ ONLY in the trailing digit (`1` vs `2`), so a reflected pair moves the body by a
        # single token in BOTH legs — which the TRUE-leg-matches-baseline guard rejects before the
        # legs are ever compared to each other.
        record Breakout, label : String, truthy : String, falsy : String

        # Single-quote STRING context: `' AND '1'='1` / `' AND '1'='2`. Chosen as the sole default
        # because quoted-string parameters (search, name/username lookups, filters) are the blind-
        # SQLi surface `error_based_sqli` most often misses: a break there frequently returns rows,
        # not a parser error, so the loud rule stays silent. A numeric-context value wrapped in this
        # breakout errors out (`42' AND '1'='1`), so the TRUE leg diverges from the baseline and the
        # param declines — no false positive, just no coverage, which AGGRESSIVE's numeric breakout
        # fills.
        STRING_CTX = Breakout.new("string",
          "%27%20AND%20%271%27%3D%271",         # ' AND '1'='1
          "%27%20AND%20%271%27%3D%272"        ) # ' AND '1'='2

        # NUMERIC context: ` AND 1=1` / ` AND 1=2`. AGGRESSIVE-only (it doubles a flow's request
        # count), for `id=42`-style numeric parameters where the string breakout above cannot land.
        NUMERIC_CTX = Breakout.new("numeric",
          "%20AND%201%3D1",         #  AND 1=1
          "%20AND%201%3D2"        ) #  AND 1=2

        def info : RuleInfo
          RuleInfo.new("sqli_boolean_based", "Boolean-based blind SQL injection",
            "Appends an always-true and an always-false SQL predicate to each parameter; flags a " \
            "parameter whose true leg matches the baseline while its false leg diverges (blind " \
            "injection with no error and no reflection).",
            Category::ACTIVE)
        end

        # 2 baselines + a (true, false) pair per param per breakout. Default (one breakout, ≤3
        # params) → 4..8; AGGRESSIVE sends more (two breakouts, ≤10 params) but the sub-tab
        # annotation reports the default posture, like the sibling rules.
        def requests_per_flow : Range(Int32, Int32)
          2 + 2..(2 + 2 * MAX_PROBE_PARAMS)
        end

        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          s, slots = injectables(detail, opts) || return nil
          key_string(detail, s.method, s.path, slots, opts)
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          s, slots = injectables(detail, opts) || return nil
          breakouts = breakouts(opts)
          # results[0] = baseline; results[1] = a second identical baseline (the stability guard).
          baseline = InsertionPoints.build(detail, InsertionPoints::NO_CHANGES)
          followups = [InsertionPoints.build(detail, InsertionPoints::NO_CHANGES)]
          params = [] of Param
          slots.each do |slot|
            # Per param, one (true, false) pair per breakout, laid out CONTIGUOUSLY so
            # detections_all can read a param's legs as a run without knowing which breakout set
            # was used (it derives the per-param leg count from the plan; see `legs_per_param`).
            breakouts.each do |b|
              followups << InsertionPoints.build(detail, [{slot, InsertionPoints::Change.new(suffix: b.truthy)}])
              followups << InsertionPoints.build(detail, [{slot, InsertionPoints::Change.new(suffix: b.falsy)}])
            end
            params << Param.new(slot.loc.label, slot.name, slot.raw_value)
          end
          key = key_string(detail, s.method, s.path, slots, opts)
          Plan.new(baseline, params, key, followups)
        end

        # results[0], results[1] are the two baselines; a param's legs follow contiguously as
        # (true, false) pairs — one pair per breakout. Fire a param when ANY of its breakouts shows
        # TRUE≈baseline AND FALSE≉baseline. One grouped Critical Detection per host.
        def detections_all(plan : Plan, results : Array(Repeater::Result), detail : Store::FlowDetail) : Array(Detection)
          base = stable_baseline(results) || return [] of Detection
          per = legs_per_param(plan) || return [] of Detection
          hits = [] of String
          plan.params.each_with_index do |param, i|
            hits << "param `#{param.name}`" if oracle?(results, 2 + i * per, per, base)
          end
          return [] of Detection if hits.empty?
          [Detection.new("sqli_boolean_based", Category::ACTIVE, detail.row.host, detail.row.url,
            "Boolean-based blind SQL injection (true/false differential)", Store::Severity::Critical,
            hits.join(", ")[0, 120], detail.row.id)]
        rescue
          [] of Detection
        end

        # Single-response fallback (module facade / one-shot caller): the differential needs the
        # two baselines + the leg pairs, so one response alone declines. The analyzer always calls
        # detections_all with the full set.
        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          detections_all(plan, [result], detail)
        end

        # Whether the param whose (true, false) leg pairs occupy `results[start, per]` shows the
        # boolean oracle in ANY of its breakouts: a leg pair where TRUE matches the baseline `base`
        # and FALSE does not. A failed/truncated leg makes that breakout's comparison unreliable, so
        # it is skipped, not read.
        private def oracle?(results : Array(Repeater::Result), start : Int32, per : Int32,
                            base : {Int32, UInt64}) : Bool
          j = 0
          while j < per
            truthy = results[start + j]?
            falsy = results[start + j + 1]?
            j += 2
            next unless truthy && falsy && truthy.ok? && falsy.ok?
            next if truthy.incomplete? || falsy.incomplete?
            return true if same?(fingerprint(truthy), base) && !same?(fingerprint(falsy), base)
          end
          false
        end

        # The baseline fingerprint, but only when the endpoint reproduced it on a SECOND identical
        # request (results[0] and results[1]). nil to DECLINE the whole flow: a missing/failed/
        # truncated baseline, or two baselines that disagree — a self-varying page where every
        # boolean differential below would be a coin flip.
        private def stable_baseline(results : Array(Repeater::Result)) : {Int32, UInt64}?
          base1 = results[0]?
          base2 = results[1]?
          return nil unless base1 && base1.ok? && base2 && base2.ok?
          return nil if base1.incomplete? || base2.incomplete?
          fp1 = fingerprint(base1)
          same?(fp1, fingerprint(base2)) ? fp1 : nil
        end

        # How many probe legs each param carries: the followups minus the second baseline, divided
        # over the params. Even (a whole number of true/false pairs) and ≥ 2, else nil to decline —
        # the layout is malformed (e.g. the single-response fallback with no followups).
        private def legs_per_param(plan : Plan) : Int32?
          n = plan.params.size
          return nil if n == 0
          legs = plan.followups.size - 1 # drop the second baseline
          return nil if legs <= 0 || legs % n != 0
          per = legs // n
          (per >= 2 && per.even?) ? per : nil
        end

        # {HTTP status, 64-bit content SimHash} of a response. The SimHash is over the DECODED,
        # capped body; `Fingerprint.simhash` is byte-level and skips dynamic tokens, so no scrub is
        # needed and a jittering id/timestamp does not move it.
        private def fingerprint(result : Repeater::Result) : {Int32, UInt64}
          {response_status(result), Discover::Fingerprint.simhash(decoded_body(result))}
        end

        # Two responses are "the same page" iff their status matches and their SimHashes are within
        # SIMHASH_DISTANCE hamming.
        private def same?(a : {Int32, UInt64}, b : {Int32, UInt64}) : Bool
          a[0] == b[0] && Discover::Fingerprint.hamming(a[1], b[1]) <= SIMHASH_DISTANCE
        end

        private def response_status(result : Repeater::Result) : Int32
          if r = result.response
            return r.status
          end
          Proxy::Codec::Http1.parse_response_head(result.head).status
        rescue
          0
        end

        # Decode + cap the response body to the bytes the SimHash reads. Not scrubbed: SimHash is
        # byte-level (reads only ASCII alnum), so an invalid-UTF-8 origin can never make it raise.
        private def decoded_body(result : Repeater::Result) : Bytes
          decoded, _ = Proxy::Codec::ContentDecode.decode(result.head, result.body, BODY_CAP)
          bytes = decoded || result.body
          return Bytes.empty if bytes.nil? || bytes.empty?
          bytes[0, {bytes.size, BODY_CAP}.min]
        rescue
          Bytes.empty
        end

        # The breakout set for this scan: the string-context pair by default, plus the numeric one
        # under AGGRESSIVE (which the higher param cap and doubled leg count are already gated by).
        private def breakouts(opts : Options) : Array(Breakout)
          opts.aggressive ? [STRING_CTX, NUMERIC_CTX] : [STRING_CTX]
        end

        # Shared gate for plan + dedup_key so the two can't drift (equivalence-spec invariant).
        # Returns {surface, the first ≤cap injectable slots} for an eligible flow, else nil.
        private def injectables(detail : Store::FlowDetail, opts : Options) : {InsertionPoints::Surface, Array(InsertionPoints::Slot)}?
          s = InsertionPoints.enumerate(detail, opts, InsertionPoints::DEFAULT_LOCATIONS) || return nil
          return nil unless diff_method_allowed?(s.method, opts)
          cap = opts.aggressive ? MAX_PROBE_PARAMS_AGGRESSIVE : MAX_PROBE_PARAMS
          slots = s.slots.first(cap)
          return nil if slots.empty?
          {s, slots}
        end

        # Suffix with |aggr under aggressive opts: aggressive introduces numeric breakout
        # contexts (not just string contexts), so the ACTIVE↔AGGRESSIVE backfill re-arm must
        # not suppress an already-seen surface before the wider breakouts run.
        private def key_string(detail : Store::FlowDetail, method : String, path : String,
                               slots : Array(InsertionPoints::Slot), opts : Options) : String
          "#{InsertionPoints.dedup_key("sqli_boolean_based", detail, method, path, slots)}#{opts.aggressive ? "|aggr" : ""}"
        end
      end
    end
  end
end
