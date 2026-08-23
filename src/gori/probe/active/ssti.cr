require "uri"
require "./types"
require "./insertion_points"
require "../../miner/types"
require "../../proxy/codec/http1"
require "../../proxy/codec/content_decode"

module Gori
  module Probe
    module Active
      # Active server-side template injection (SSTI) probe. When user input is concatenated into a
      # server-side template (`render("Hello #{name}")` with a real template engine), an attacker's
      # `{{7*7}}` is EVALUATED, not printed — frequently a path to RCE. This is the highest-FP check in
      # the active set, so its confirmation is deliberately strict.
      #
      # For one in-scope flow it replaces each query-parameter value with a template-polyglot
      # arithmetic marker wrapped in a unique per-parameter canary, and sends TWO requests:
      #   A: <canary>{{7*7}}${7*7}#{7*7}<%= 7*7 %><canary>   (product 49)
      #   B: <canary>{{7*8}}${7*8}#{7*8}<%= 7*8 %><canary>   (product 56)
      # It flags High for a parameter ONLY when the region BETWEEN that parameter's canary pair
      # contains `49` in A AND `56` in B. Three FP guards stack:
      #   * canary-region anchoring — the product is read only between our fresh per-request canaries,
      #     never elsewhere on the page, so a stray `49` in unrelated content can't trigger it;
      #   * we NEVER send `49`/`56` literally (only `7*7`/`7*8`), so their appearance in the region is
      #     proof of arithmetic evaluation, not reflection (a verbatim echo carries `7*7`, never `49`);
      #   * the DOUBLE product — a coincidental constant would have to read `49` in A and `56` in B at
      #     the same canary region, which distinct fresh canaries make impossible.
      # Gated to body-comparable methods (GET by default, HEAD out; Options#allow_unsafe widens), since
      # the confirmation reads response bodies. Insertion points come from the shared
      # `InsertionPoints` model (query today).
      class Ssti < Rule
        # Fresh-canary-wrapped polyglot values are built per param; these are the two arithmetic
        # products (chosen away from common page constants like 7 / 100).
        EXPR_A    = "7*7"
        PRODUCT_A = "49"
        EXPR_B    = "7*8"
        PRODUCT_B = "56"

        def info : RuleInfo
          RuleInfo.new("ssti", "Server-side template injection",
            "Injects a template arithmetic polyglot and flags a parameter whose value is evaluated.",
            Category::ACTIVE)
        end

        def requests_per_flow : Range(Int32, Int32)
          2..2 # product-49 probe + product-56 probe
        end

        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          s = InsertionPoints.enumerate(detail, opts, InsertionPoints::DEFAULT_LOCATIONS) || return nil
          return nil unless diff_method_allowed?(s.method, opts)
          return nil if s.slots.empty? || s.slots.size > opts.max_params
          InsertionPoints.dedup_key("ssti", detail, s.method, s.path, s.slots)
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          s = InsertionPoints.enumerate(detail, opts, InsertionPoints::DEFAULT_LOCATIONS) || return nil
          return nil unless diff_method_allowed?(s.method, opts)
          return nil if s.slots.empty? || s.slots.size > opts.max_params

          params = [] of Param
          changes_a = [] of {InsertionPoints::Slot, InsertionPoints::Change}
          changes_b = [] of {InsertionPoints::Slot, InsertionPoints::Change}
          s.slots.each do |slot|
            canary = Miner::Canary.fresh
            params << Param.new(slot.loc.label, slot.name, canary)
            changes_a << {slot, InsertionPoints::Change.new(replace: polyglot(canary, EXPR_A))}
            changes_b << {slot, InsertionPoints::Change.new(replace: polyglot(canary, EXPR_B))}
          end
          probe_a = InsertionPoints.build(detail, changes_a)
          probe_b = InsertionPoints.build(detail, changes_b)
          key = InsertionPoints.dedup_key("ssti", detail, s.method, s.path, s.slots)
          Plan.new(probe_a, params, key, [probe_b])
        end

        # Flag a parameter whose canary region evaluated BOTH products (49 in A, 56 in B).
        def detections_all(plan : Plan, results : Array(Repeater::Result), detail : Store::FlowDetail) : Array(Detection)
          a = results[0]?
          b = results[1]?
          return [] of Detection unless a && a.ok? && b && b.ok?
          a_body = decoded_text(a)
          b_body = decoded_text(b)
          return [] of Detection if a_body.empty? || b_body.empty?
          hits = evaluated_params(plan.params, a_body, b_body)
          return [] of Detection if hits.empty?
          [Detection.new("ssti", Category::ACTIVE, detail.row.host, detail.row.url,
            "Server-side template injection (arithmetic evaluated)", Store::Severity::High,
            hits.join(", ")[0, 120], detail.row.id)]
        rescue
          [] of Detection
        end

        # Names of the params whose canary region evaluated BOTH products (49 in A, 56 in B), deduped.
        private def evaluated_params(params : Array(Param), a_body : String, b_body : String) : Array(String)
          hits = [] of String
          params.each do |p|
            ar = between(p.canary, a_body) || next
            br = between(p.canary, b_body) || next
            hits << p.name if ar.includes?(PRODUCT_A) && br.includes?(PRODUCT_B)
          end
          hits.uniq
        end

        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          detections_all(plan, [result], detail)
        end

        # The substring strictly between the FIRST two occurrences of `canary`, or nil if it does not
        # appear twice (the value was not reflected in full).
        private def between(canary : String, text : String) : String?
          i = text.index(canary) || return nil
          j = text.index(canary, i + canary.size) || return nil
          text[(i + canary.size)...j]
        end

        # The template polyglot `<canary>{{E}}${E}#{E}<%= E %><canary>` for expression E, built by
        # concatenation so Crystal never interprets the `#{` as its own interpolation.
        private def polyglot(canary : String, expr : String) : String
          canary + "{{" + expr + "}}" + "${" + expr + "}" + "\#{" + expr + "}" + "<%= " + expr + " %>" + canary
        end

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
