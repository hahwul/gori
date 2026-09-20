require "./types"
require "./insertion_points"
require "../../miner/types"
require "../../proxy/codec/http1"

module Gori
  module Probe
    module Active
      # Active CRLF / response-header injection probe. When a request value flows unsanitized into a
      # response header (a `Location`, a `Set-Cookie`, a custom header), an attacker who smuggles a
      # `\r\n` splits the response: injecting arbitrary headers (cache-poisoning keys, cookies) or,
      # in older stacks, a whole second response. Passive analysis cannot see a header the browser
      # never provoked.
      #
      # It appends a URL-encoded `\r\nGori-Probe: <canary>` to EVERY injectable value in ONE request,
      # each value carrying a DISTINCT canary, across the shared InsertionPoints surfaces: query by
      # default, plus form/JSON bodies once `allow_unsafe` admits body-bearing methods (mirrors
      # reflected_param — a GET rarely has a body, so form/JSON materialize under the same method
      # gate, not a special case). It flags High for a value whose canary comes back as a REAL parsed
      # response header `Gori-Probe: <canary>`. Confirmation is binary and self-attributing:
      #   * a distinct per-value canary tells exactly which parameter split the response, and can
      #     never collide with a pre-existing static `Gori-Probe: 1`;
      #   * the value is read from the PARSED response header list, so a body that merely echoes the
      #     literal `Gori-Probe:` text never counts.
      # A server that percent-decodes but header-sanitizes (the correct behavior) reflects nothing.
      # Gated to safe methods (GET/HEAD) unless allow_unsafe, so an automatic probe never mutates state.
      class CrlfInjection < Rule
        # The URL-encoded CR LF + header appended to each value. `%0d%0a` decodes to CRLF
        # server-side; `%20` is the space after the colon. `Gori-Probe` is a benign, unique header
        # name — its mere presence in the response proves a split.
        INJECT      = "%0d%0aGori-Probe:%20"
        HEADER_NAME = "Gori-Probe"

        def info : RuleInfo
          RuleInfo.new("crlf_injection", "CRLF header injection",
            "Injects an encoded CRLF + header in request parameters (query/form/JSON) and flags a " \
            "reflected response header.",
            Category::ACTIVE)
        end

        # The dedup key WITHOUT generating canaries or rebuilding the request — derived from the
        # same `InsertionPoints.enumerate` gate `plan` uses (same skip rules, same cap), so it is
        # byte-identical to `plan(detail).dedup_key` and nil in exactly the same cases.
        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          s = InsertionPoints.enumerate(detail, opts, InsertionPoints::DEFAULT_LOCATIONS) || return nil
          return nil unless method_allowed?(s.method, opts)
          return nil if s.slots.empty? || s.slots.size > opts.max_params
          InsertionPoints.dedup_key("crlf_injection", detail, s.method, s.path, s.slots)
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          s = InsertionPoints.enumerate(detail, opts, InsertionPoints::DEFAULT_LOCATIONS) || return nil
          return nil unless method_allowed?(s.method, opts)
          return nil if s.slots.empty? || s.slots.size > opts.max_params

          params = [] of Param
          changes = [] of {InsertionPoints::Slot, InsertionPoints::Change}
          s.slots.each do |slot|
            canary = Miner::Canary.fresh
            params << Param.new(slot.loc.label, slot.name, canary)
            # RAW suffix: wire-ready, single-encoded — the encoded CRLF stays `%0d%0a` on the query/
            # form wire (server percent-decodes it), and the JSON path URL-decodes it into the string
            # value; either way the server sees a real CRLF only if it fails to sanitize.
            changes << {slot, InsertionPoints::Change.new(suffix: "#{INJECT}#{canary}")}
          end
          request = InsertionPoints.build(detail, changes)
          key = InsertionPoints.dedup_key("crlf_injection", detail, s.method, s.path, s.slots)
          Plan.new(request, params, key)
        end

        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          return [] of Detection unless result.ok?
          injected = Proxy::Codec::Http1.parse_response_head(result.head).headers.get_all(HEADER_NAME)
          return [] of Detection if injected.empty?
          # Substring, not equality: a param reflected mid-header (`Location: <value>/dashboard`) makes
          # the split header `Gori-Probe: <canary>/dashboard`, so the canary is a substring, not the
          # whole value. The 10-char random canary keeps a substring match essentially FP-free.
          hits = plan.params.select { |p| injected.any?(&.includes?(p.canary)) }.map(&.name)
          return [] of Detection if hits.empty?
          hits.uniq!
          [Detection.new("crlf_injection", Category::ACTIVE, detail.row.host, detail.row.url,
            "CRLF header injection (response split via parameter)", Store::Severity::High,
            hits.join(", ")[0, 120], detail.row.id)]
        rescue
          [] of Detection
        end
      end
    end
  end
end
