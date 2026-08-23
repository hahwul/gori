require "uri"
require "json"
require "./types"
require "./insertion_points"
require "../../miner/types"
require "../../fuzz/engine"
require "../../proxy/codec/http1"
require "../../proxy/codec/content_decode"

module Gori
  module Probe
    module Active
      # Reflected parameters. For one in-scope flow it replaces each existing parameter value
      # (query / form / JSON) with a distinct canary, sends ONE request, and reports the
      # parameters whose canary echoes back — grading each by whether the echo was ENCODED.
      # Gated to safe methods so an automatic probe never mutates server state.
      #
      # Insertion points come from the shared `InsertionPoints` model (query + form + JSON); the
      # rule keeps its own method gate + param cap + canary-grading. A GET/HEAD rarely carries a
      # body, so the form/JSON surfaces materialize almost only under `allow_unsafe` (which admits
      # body-bearing methods) — the method gate, not a special case, does that.
      #
      # The canary carries a MARKER of the four characters that decide whether a reflection is
      # exploitable: `"`, `'`, `<`, `>`. An alphanumeric canary on its own cannot answer that
      # question — it survives HTML-escaping unchanged, so "the value came back" was reported
      # identically for a raw injection point and for output a template escaped correctly. Since
      # correct escaping is the norm, that made the common case the finding: nearly every
      # reflecting endpoint scored Medium.
      #
      # Reading which marker characters came back VERBATIM, immediately after the canary, splits
      # them apart:
      #   * `<` survived        — tag injection is possible; the classic XSS candidate.
      #   * only `"` / `'`      — an attribute-context break, exploitable only in some sinks.
      #   * none survived       — the value was escaped, stripped, or encoded. Still worth knowing
      #                           as a reflection point, so it is reported at Info rather than
      #                           dropped, but it is not an XSS finding.
      # A partial survival is read in order, so `"'<>` reports `"'` — an escaped `<` stops
      # the run exactly where the server's filter did.
      class ReflectedParam < Rule
        # Appended to every canary. Sent URL-encoded (query/form) or JSON-escaped (body), so the
        # server decodes real characters; what comes back tells us what its output layer did with
        # them. Order matters: `survived` reads this prefix-wise.
        MARKER = "\"'<>"

        # The full value sent for a canary. Public so specs (and a manual re-send) can reproduce
        # the exact bytes the probe put in the parameter.
        def self.probe_value(canary : String) : String
          canary + MARKER
        end

        def info : RuleInfo
          RuleInfo.new("reflected_param", "Reflected parameter",
            "Sends a canary in query parameters and flags unencoded reflection (potential XSS).",
            Category::ACTIVE)
        end

        # The dedup key WITHOUT generating canaries or rebuilding the request — derived from the
        # same `InsertionPoints.enumerate` gate `plan` uses (same skip rules, same cap), so it is
        # byte-identical to `plan(detail).dedup_key` and nil in exactly the same cases.
        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          s = InsertionPoints.enumerate(detail, opts, InsertionPoints::DEFAULT_LOCATIONS) || return nil
          return nil unless method_allowed?(s.method, opts)
          return nil if s.slots.empty? || s.slots.size > opts.max_params
          InsertionPoints.dedup_key("reflected_param", detail, s.method, s.path, s.slots)
        end

        # Build a probe from a captured flow, or nil if there is nothing reflectable.
        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          s = InsertionPoints.enumerate(detail, opts, InsertionPoints::DEFAULT_LOCATIONS) || return nil
          return nil unless method_allowed?(s.method, opts)
          return nil if s.slots.empty? || s.slots.size > opts.max_params

          params = [] of Param
          changes = [] of {InsertionPoints::Slot, InsertionPoints::Change}
          s.slots.each do |slot|
            canary = Miner::Canary.fresh
            params << Param.new(slot.loc.label, slot.name, canary)
            changes << {slot, InsertionPoints::Change.new(replace: ReflectedParam.probe_value(canary))}
          end
          request = InsertionPoints.build(detail, changes)
          key = InsertionPoints.dedup_key("reflected_param", detail, s.method, s.path, s.slots)
          Plan.new(request, params, key)
        end

        # Interpret the probe's response: at most ONE Detection, graded by the strongest echo seen
        # (one grouped row per host).
        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          hits = reflections(result, plan.params)
          return [] of Detection if hits.empty?
          html = response_content_type(result).includes?("html")
          # Grade on the strongest echo: a raw `<` anywhere outranks a bare quote, which outranks
          # an escaped echo. Only the params at that tier are named, so the evidence describes the
          # finding rather than mixing an injection point in with correctly-escaped output.
          tier, sev, title = grade(hits, html)
          names = hits.select { |(_, s)| tier_of(s) == tier }
            .map { |(p, s)| "#{p.name} (#{p.location}#{s.empty? ? "" : ", #{s} survived"})" }
          names.uniq!
          [Detection.new("reflected_param", Category::ACTIVE, detail.row.host, detail.row.url,
            title, sev, names.join(", ")[0, 120], detail.row.id)]
        end

        # 2 = a raw `<` (tag injection), 1 = a quote only (attribute context), 0 = escaped/stripped.
        private def tier_of(survived : String) : Int32
          return 2 if survived.includes?('<')
          survived.empty? ? 0 : 1
        end

        # {tier, severity, title} for the strongest echo present. Only a raw `<` in an HTML
        # response keeps the historic Medium; an escaped echo is Info — a reflection point worth
        # knowing, not a vulnerability.
        private def grade(hits : Array({Param, String}), html : Bool) : {Int32, Store::Severity, String}
          tier = hits.max_of { |(_, s)| tier_of(s) }
          case tier
          when 2
            if html
              {2, Store::Severity::Medium, "Reflected parameter (unencoded, tag injection possible)"}
            else
              {2, Store::Severity::Low, "Reflected parameter (unencoded, non-HTML context)"}
            end
          when 1
            {1, Store::Severity::Low, "Reflected parameter (quote survived, attribute context)"}
          else
            {0, Store::Severity::Info, "Reflected parameter (escaped or filtered)"}
          end
        end

        # {param, surviving marker characters} for every param whose canary echoed back. Scans BOTH
        # the response head (reflected Location/Set-Cookie/custom headers) and the decoded body —
        # header reflections (e.g. open-redirect Location) are invisible to a body-only scan.
        private def reflections(result : Repeater::Result, params : Array(Param)) : Array({Param, String})
          found = [] of {Param, String}
          # NOTE: not `out` — that is a Crystal keyword (C-binding output parameters), and
          # `return out unless …` parses as the keyword, not the local.
          return found unless result.ok?
          head = String.new(result.head).scrub
          # Canary search only reads the first BODY_CAP bytes, so cap the inflate to match.
          decoded, _ = Proxy::Codec::ContentDecode.decode(result.head, result.body, BODY_CAP)
          bytes = decoded || result.body
          body = (bytes && !bytes.empty?) ? String.new(bytes[0, {bytes.size, BODY_CAP}.min]).scrub : ""
          params.each do |p|
            # Search head and body separately: concatenating them allocated a full copy of both
            # (up to BODY_CAP + head) on every probe just to run one substring scan per param.
            # Take the BEST of the two — a value echoed into several contexts (escaped in the
            # page text, raw inside a script block or a header) is only as safe as its weakest
            # sink, so grading on whichever context preserved the most characters is the correct
            # reading, not merely the first one found.
            best = [survived(head, p.canary), survived(body, p.canary)].compact.max_by?(&.size)
            found << {p, best} if best
          end
          found
        end

        # The MARKER characters that came back VERBATIM right after `canary` in `hay`, read
        # prefix-wise; "" when the canary echoed but every marker character was escaped, stripped,
        # or re-encoded. nil when the canary does not appear at all.
        #
        # Every occurrence is examined, not just the first: the same value routinely lands in more
        # than one place in one response, and the first hit is as likely to be the escaped one as
        # the raw one. Returns the longest surviving prefix across them. Occurrences of a 10-char
        # random canary are few, so the walk is bounded in practice.
        private def survived(hay : String, canary : String) : String?
          from = 0
          best = nil.as(String?)
          while i = hay.index(canary, from)
            tail = i + canary.size
            n = 0
            while n < MARKER.size && (c = hay[tail + n]?) && c == MARKER[n]
              n += 1
            end
            best = MARKER[0, n] if best.nil? || n > best.size
            break if n == MARKER.size # nothing can beat a full survival
            from = tail
          end
          best
        end

        private def response_content_type(result : Repeater::Result) : String
          if r = result.response
            return (r.headers.get?("Content-Type") || "").downcase
          end
          (Proxy::Codec::Http1.parse_response_head(result.head).headers.get?("Content-Type") || "").downcase
        rescue
          ""
        end
      end
    end
  end
end
