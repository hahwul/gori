require "./types"
require "./forbidden_bypass"
require "../../miner/inject"
require "../../proxy/codec/http1"

module Gori
  module Probe
    module Active
      # Active rate-limit bypass probe (429). Many rate limiters bucket by the CLAIMED client IP —
      # an X-Forwarded-For / X-Real-IP the app trusts instead of the socket peer — so an attacker
      # who forges that header gets a fresh bucket and sidesteps the limit (credential stuffing,
      # scraping, brute force). Passive analysis cannot tell a header-keyed limiter apart from any
      # other 429: re-sending the SAME request with a spoofed IP surfaces the header-controllable case.
      #
      # For one in-scope flow whose captured response was 429, it sends TWO requests:
      #   probe   = the same request + the client-IP spoofing header set (ForbiddenBypass's set)
      #   control = the same request, UNCHANGED
      # and flags a Medium bypass only when the probe was SERVED (2xx/3xx) AND the control is still
      # 429. The control — sent AFTER the probe — is what makes the finding attributable: judging
      # the probe against the captured 429 alone could not tell "the header reset the bucket" from
      # "the window simply elapsed between capture and probe". If the limit cleared on its own, the
      # control answers non-429 too and the finding is suppressed.
      #
      # Still Medium: two adjacent requests cannot rule out a limiter whose window happened to roll
      # over between them, so this is a lead to confirm — just no longer one that fires on ordinary
      # window expiry. Gated to safe methods (GET/HEAD) so an automatic probe never mutates state.
      # The IP-header list is ForbiddenBypass's (one source of truth for "spoofable client-IP
      # headers"); the two rules differ only in trigger status and success condition.
      class RateLimitBypass < Rule
        def info : RuleInfo
          RuleInfo.new("ratelimit_bypass", "Rate-limit bypass (spoofed client IP)",
            "Re-sends a rate-limited (429) request with spoofed client-IP headers and flags a served response.",
            Category::ACTIVE)
        end

        # probe (spoofed headers) + control (the request UNCHANGED).
        def requests_per_flow : Range(Int32, Int32)
          2..2
        end

        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          method, target, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          return nil if malformed
          return nil unless method_allowed?(method.upcase, opts)
          return nil unless detail.row.status == 429
          key_string(detail, method.upcase, target, opts.aggressive)
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          req = Proxy::Codec::Http1.parse_request_head(detail.request_head)
          return nil if req.malformed?
          return nil unless method_allowed?(req.method.upcase, opts)
          return nil unless detail.row.status == 429
          request = rebuild_with_bypass_headers(detail.request_head, detail.request_body, opts.aggressive)
          control = rebuild_with_bypass_headers(detail.request_head, detail.request_body,
            opts.aggressive, insert: false)
          Plan.new(request, [] of Param, key_string(detail, req.method.upcase, req.target, opts.aggressive), [control])
        end

        # results = [probe, control]. Flag only when the spoofed request was SERVED (2xx/3xx) AND
        # the control — the same request without the headers, sent right after — is still 429.
        def detections_all(plan : Plan, results : Array(Repeater::Result), detail : Store::FlowDetail) : Array(Detection)
          probe = results[0]?
          return [] of Detection unless probe && probe.ok?
          status = probe_status(probe)
          # A served response is any non-429 success/redirect. Another 4xx/5xx is ambiguous (the
          # limiter may have changed its answer, not been bypassed) and is intentionally not flagged.
          return [] of Detection unless (200..399).includes?(status)
          control = results[1]?
          # No usable control ⇒ no attribution. Refuse rather than fall back to the captured status.
          return [] of Detection unless control && control.ok?
          # The control was served too ⇒ the window simply elapsed; the headers proved nothing.
          return [] of Detection unless probe_status(control) == 429
          [Detection.new("ratelimit_bypass", Category::ACTIVE, detail.row.host, detail.row.url,
            "Possible rate-limit bypass via spoofed client-IP header", Store::Severity::Medium,
            "429 → #{status} with X-Forwarded-For=#{ForbiddenBypass::BYPASS_VALUE}; control without the headers still 429"[0, 120],
            detail.row.id)]
        rescue
          [] of Detection
        end

        # Single-response fallback: the control leg makes this rule's finding attributable, so one
        # response alone yields nothing. The analyzer always calls detections_all with the full set.
        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          detections_all(plan, [result], detail)
        end

        # Query is stripped (a rate limiter is per-endpoint, not per-query-value); host:PORT so the
        # same host on another service is a distinct surface. The aggressive tag keeps the ACTIVE↔
        # AGGRESSIVE backfill from skipping an already-seen surface before the wider header set ran.
        private def key_string(detail : Store::FlowDetail, method_upcase : String, target : String,
                               aggressive : Bool) : String
          tag = aggressive ? "aggr" : "base"
          "ratelimit_bypass|#{detail.row.host}:#{detail.row.port}|#{method_upcase}|#{path_key(target)}|#{tag}"
        end

        private def path_key(target : String) : String
          t = Active.origin_form(target)
          qi = t.index('?')
          qi ? t[0...qi] : t
        end

        private def probe_status(result : Repeater::Result) : Int32
          if r = result.response
            return r.status
          end
          Proxy::Codec::Http1.parse_response_head(result.head).status
        rescue
          0
        end

        # Drop any client-IP headers the browser sent, insert one authoritative copy of each (the
        # spoofed value), and normalize the request line to origin-form. `insert: false` builds the
        # CONTROL — the same rebuild without the forged values, so the two legs differ in exactly
        # one thing. Mirrors ForbiddenBypass#rebuild_with_bypass_headers (kept local so the two
        # rules stay independent; the header list is shared via the constants).
        private def rebuild_with_bypass_headers(head : Bytes, body : Bytes?, aggressive : Bool,
                                                insert : Bool = true) : Bytes
          headers = aggressive ? ForbiddenBypass::BYPASS_HEADERS_AGGRESSIVE : ForbiddenBypass::BYPASS_HEADERS
          drop_set = aggressive ? ForbiddenBypass::BYPASS_HEADER_SET_AGGRESSIVE : ForbiddenBypass::BYPASS_HEADER_SET
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
          kept = [] of String
          lines.each_with_index do |l, i|
            next if i > 0 && bypass_header?(l, drop_set)
            kept << l
          end
          unless kept.empty?
            rl = kept[0].split(' ')
            kept[0] = "#{rl[0]} #{Active.origin_form(rl[1])} #{rl[2]}" if rl.size == 3
            headers.each_with_index { |name, i| kept.insert(1 + i, "#{name}: #{ForbiddenBypass::BYPASS_VALUE}") } if insert
          end
          io = IO::Memory.new
          io << kept.join(eol) << eol << eol
          io.write(bbytes) unless bbytes.empty?
          io.to_slice
        end

        private def bypass_header?(line : String, drop_set : Set(String)) : Bool
          (c = line.index(':')) ? drop_set.includes?(line[0...c].strip.downcase) : false
        end
      end
    end
  end
end
