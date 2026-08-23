require "uri"
require "./types"
require "./insertion_points"
require "../../miner/types"
require "../../proxy/codec/http1"
require "../../proxy/codec/content_decode"

module Gori
  module Probe
    module Active
      # Active error-based SQL injection probe. When a query parameter is concatenated into a SQL
      # statement, a value that BREAKS the SQL string/number literal makes the database refuse to
      # parse the statement, and a verbose backend echoes the parser's own diagnostic ("You have an
      # error in your SQL syntax…", `ORA-00933`, "Unclosed quotation mark after the character
      # string…") straight into the response. That leaked, database-specific error message is the
      # tell this rule confirms.
      #
      # For each injectable parameter it sends a baseline (the ORIGINAL request, unchanged) plus one
      # probe per param whose value is the param's ORIGINAL value with a syntax-breaking suffix
      # appended (URL-encoded `'"`), every other param left alone. A param is flagged ONLY when a
      # specific DB-error signature appears in the PROBE body and is ABSENT from the baseline body.
      #
      # Two FP guards stack — the same shape the SSTI rule uses to prove EVALUATION rather than
      # reflection:
      #   * the DIFFERENTIAL — the signature must be present after the break and absent before it.
      #     An endpoint that is PERMANENTLY broken (always renders a DB error, e.g. a misconfigured
      #     page) carries the signature in the baseline too, so the difference is empty and nothing
      #     fires. Only a NEW error induced by our syntax break counts.
      #   * a SPECIFIC signature we NEVER send ourselves — the payload is only `'"`, never any of the
      #     signature strings, so a matched signature is the database talking, not our input echoed
      #     back. (Ordinary reflection of the `'"` payload — with no DB error — matches nothing.)
      # The signature set is deliberately narrow (curated DB diagnostics, no bare "error"/"sql"/
      # "syntax"), matched case-insensitively against the DECODED, scrubbed, capped body text so an
      # invalid-UTF-8 byte can never make the PCRE `ORA-\d{5}` scan raise.
      #
      # This COMPLEMENTS `backslash_powered`, which is structural and error-message-FREE (it reads a
      # `\` vs `\\` asymmetry and never needs the backend to leak a string). This rule instead
      # catches the endpoints that DO leak a verbose DB error — including NUMERIC contexts (`id=42`
      # → `id=42'"`), where the backslash-escaping asymmetry does not appear because a lone `\` in a
      # numeric literal is not an escape. The two together cover both the quiet (structural) and the
      # loud (error-leaking) faces of the same injection surface. Insertion points come from the
      # shared `InsertionPoints` model (query today).
      class ErrorBasedSqli < Rule
        # Probe at most this many params per flow (in enumeration order, across all locations).
        # Bounds the request count so a wide param set stays light-touch; AGGRESSIVE raises the cap.
        MAX_PROBE_PARAMS            =  3
        MAX_PROBE_PARAMS_AGGRESSIVE = 10

        # Appended (URL-encoded, wire-ready) to a param's ORIGINAL value. Decodes server-side to a
        # single quote followed by a double quote — one of the two breaks whichever string literal
        # the value sits in, and the unmatched quote errors most numeric contexts too. We only ever
        # send this; we never send any signature string, so a matched signature proves a real DB error.
        PAYLOAD = "%27%22" # → '"

        # Curated, DB-specific parser/driver diagnostics, matched case-insensitively as substrings
        # against the decoded body. Kept narrow ON PURPOSE — no bare "error"/"sql"/"syntax", which
        # would false-match ordinary prose. Oracle's numbered `ORA-\d{5}` is handled by regex below.
        SIGNATURES = [
          # MySQL / MariaDB
          "you have an error in your sql syntax",
          "warning: mysql",
          "mysqli_",
          "mysql_fetch",
          "valid mysql result",
          "mysqlexception",
          # PostgreSQL
          "pg_query()",
          "pg_exec()",
          "postgresql query failed",
          "psqlexception",
          "unterminated quoted string at or near",
          "syntax error at or near",
          # MS SQL Server
          "microsoft ole db provider for sql server",
          "unclosed quotation mark after the character string",
          "system.data.sqlclient.sqlexception",
          "incorrect syntax near",
          # Oracle (ORA-##### handled by ORA_SIGNATURE below)
          "quoted string not properly terminated",
          "sql command not properly ended",
          # SQLite
          "sqlite3::",
          "sqlite3.operationalerror",
          "sqlite_error",
          "unrecognized token:",
          # Generic drivers — kept specific: bare "jdbc" was dropped (it matches any page
          # documenting a JDBC connection string or a Java stack trace, and the differential
          # cannot suppress it when the surrounding content varies between baseline and probe).
          "sqlstate[",
          "odbc sql",
        ]

        # Oracle's numbered diagnostic (e.g. ORA-00933). WORD-BOUNDED so it cannot match inside a
        # larger token — without the `\b`, `aurora-12345` contains `ora-12345` and false-fires.
        # Run ONLY on the decoded+scrubbed String, so the regex can never see an invalid-UTF-8 byte.
        ORA_SIGNATURE = /\bORA-\d{5}\b/i

        def info : RuleInfo
          RuleInfo.new("sqli_error_based", "Error-based SQL injection",
            "Appends a SQL-syntax-breaking payload to each query parameter; flags a parameter where a " \
            "database-error signature appears in the probe response but not in the clean baseline.",
            Category::ACTIVE)
        end

        # 2 baselines (the second proves the endpoint answers the same request the same way twice,
        # so a self-varying error page is not mistaken for an induced one) + up to MAX_PROBE_PARAMS
        # probes. Static annotation for the Rules sub-tab + the manual-run estimate (the analyzer
        # sends the exact count for the flow at hand; AGGRESSIVE can send more).
        def requests_per_flow : Range(Int32, Int32)
          3..(2 + MAX_PROBE_PARAMS)
        end

        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          s, slots = injectables(detail, opts) || return nil
          InsertionPoints.dedup_key("sqli_error_based", detail, s.method, s.path, slots)
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          s, slots = injectables(detail, opts) || return nil
          # Baseline: the ORIGINAL request, unchanged (results[0]).
          baseline = InsertionPoints.build(detail, InsertionPoints::NO_CHANGES)
          # A SECOND identical baseline, sent first among the follow-ups (results[1]) — the
          # stability guard BackslashPowered uses. This rule is a difference test against the
          # baseline; on a self-varying endpoint (an intermittent 5xx that renders a verbose
          # DB-error page under load, a rate limiter, a rotating backend) an error page landing on
          # a probe leg but not a SINGLE baseline reproduces the exact differential we report, once
          # per param. Requiring the signature to be absent from BOTH baselines turns "we cannot
          # tell" into a decline instead of a High false positive.
          followups = [InsertionPoints.build(detail, InsertionPoints::NO_CHANGES)]
          params = [] of Param
          slots.each do |slot|
            # One followup per param: that param's value = original + PAYLOAD, all others verbatim.
            # Appended after the two baselines, so slots[i]'s probe is results[2 + i].
            followups << InsertionPoints.build(detail, [{slot, InsertionPoints::Change.new(suffix: PAYLOAD)}])
            params << Param.new(slot.loc.label, slot.name, slot.raw_value)
          end
          key = InsertionPoints.dedup_key("sqli_error_based", detail, s.method, s.path, slots)
          Plan.new(baseline, params, key, followups)
        end

        # results[0] and results[1] are the two baselines; results[2 + i] is the probe for
        # params[i]. Fire a param when a DB-error signature is present in its probe body and ABSENT
        # from BOTH baselines. One grouped Detection per host, listing the affected params + the
        # signature each leaked.
        def detections_all(plan : Plan, results : Array(Repeater::Result), detail : Store::FlowDetail) : Array(Detection)
          base1 = results[0]?
          base2 = results[1]?
          # Both baselines must have come back ok — without a stable reference we decline rather
          # than risk a false positive (mirrors BackslashPowered#stable_baseline). The combined
          # text means a signature present in EITHER baseline suppresses the finding.
          return [] of Detection unless base1 && base1.ok? && base2 && base2.ok?
          base_body = "#{decoded_text(base1)}\n#{decoded_text(base2)}"
          base_low = base_body.downcase
          hits = [] of String
          plan.params.each_with_index do |param, i|
            probe = results[2 + i]?
            next unless probe && probe.ok?
            probe_body = decoded_text(probe)
            next if probe_body.empty?
            sig = new_db_error(probe_body, base_body, base_low)
            hits << "param `#{param.name}`: #{sig.inspect}" if sig
          end
          return [] of Detection if hits.empty?
          [Detection.new("sqli_error_based", Category::ACTIVE, detail.row.host, detail.row.url,
            "Error-based SQL injection (database error induced)", Store::Severity::High,
            hits.join(", ")[0, 120], detail.row.id)]
        rescue
          [] of Detection
        end

        # Single-response fallback (module facade / a one-shot caller): the differential needs two
        # baselines + a probe, so one response alone yields nothing (results[1] is absent → decline).
        # The analyzer always calls detections_all with the full set.
        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          detections_all(plan, [result], detail)
        end

        # The first DB-error signature present in `probe_body` but ABSENT from the baseline
        # (`base_low` is the pre-lowercased baseline). Returns a short, SAFE label for evidence — a
        # DB error string is not a secret — capped so it can't bloat the row. nil when the probe
        # leaks no new signature.
        private def new_db_error(probe_body : String, base_body : String, base_low : String) : String?
          probe_low = probe_body.downcase
          SIGNATURES.each do |sig|
            return sig[0, 40] if probe_low.includes?(sig) && !base_low.includes?(sig)
          end
          if m = ORA_SIGNATURE.match(probe_body)
            ora = m[0]
            return ora[0, 40] unless ORA_SIGNATURE.matches?(base_body)
          end
          nil
        end

        # Shared gate for plan + dedup_key so the two can't drift (equivalence-spec invariant).
        # Returns {surface, the first ≤cap injectable slots} for an eligible flow, else nil. The cap
        # spans ALL enumerated locations at once, so a wide param set can't blow up the request count.
        private def injectables(detail : Store::FlowDetail, opts : Options) : {InsertionPoints::Surface, Array(InsertionPoints::Slot)}?
          s = InsertionPoints.enumerate(detail, opts, InsertionPoints::DEFAULT_LOCATIONS) || return nil
          # Body-differential gate: the comparison reads response BODIES (HEAD has none), so HEAD is
          # always out. By default GET only — the automatic scan never auto-re-sends a state-changing
          # method — but opts.allow_unsafe (manual per-flow scan / AGGRESSIVE mode) widens to
          # POST/PUT/PATCH/DELETE, whose params can still reach a SQL statement.
          return nil unless diff_method_allowed?(s.method, opts)
          cap = opts.aggressive ? MAX_PROBE_PARAMS_AGGRESSIVE : MAX_PROBE_PARAMS
          slots = s.slots.first(cap)
          return nil if slots.empty?
          {s, slots}
        end

        # Decode + scrub the response body to text, capped at BODY_CAP. Scrubbing makes the
        # substring and PCRE scans byte-safe on an invalid-UTF-8 origin.
        private def decoded_text(result : Repeater::Result) : String
          decoded, _ = Proxy::Codec::ContentDecode.decode(result.head, result.body, BODY_CAP)
          bytes = decoded || result.body
          return "" if bytes.nil? || bytes.empty?
          String.new(bytes[0, {bytes.size, BODY_CAP}.min]).scrub
        rescue
          ""
        end
      end
    end
  end
end
