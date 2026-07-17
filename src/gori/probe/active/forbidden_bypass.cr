require "./types"
require "../../miner/inject"
require "../../proxy/codec/http1"

module Gori
  module Probe
    module Active
      # Active IP-header access-control bypass probe. Many gateways/apps gate a resource on the
      # *claimed* client IP (an allowlist, an "internal only" path, an admin panel), trusting a
      # proxy header like X-Forwarded-For instead of the real socket peer. Passive analysis can't
      # tell such a control apart from any other 403/401; re-sending the SAME request with a
      # spoofed loopback IP in those headers surfaces a candidate header-controllable gate.
      #
      # For one in-scope flow whose captured response was 401/403, it re-sends ONE request with the
      # full IP-spoofing header set (all 127.0.0.1) and flags a Medium "possible bypass" when the
      # response flips to 2xx. It is a single-shot probe against the CAPTURED baseline (no control
      # re-send without the headers), so a transient/rate-limited 403 that later clears can also
      # flip — hence "possible", to be confirmed by re-sending without the headers. Gated to
      # safe methods (GET/HEAD) so an automatic probe never mutates server state, and to originally-
      # denied responses so a normally-200 endpoint is never probed. A control that correctly keys
      # on the socket peer ignores the headers and still returns 401/403, so it is never flagged.
      #
      # Header set + loopback value follow https://www.hahwul.com/blog/2021/bypass-403/.
      class ForbiddenBypass < Rule
        def info : RuleInfo
          RuleInfo.new("forbidden_bypass", "Access-control bypass (IP headers)",
            "Re-sends a denied (401/403) request with spoofed client-IP headers and flags a 2xx bypass.",
            Category::ACTIVE)
        end

        # The value every spoofing header carries: loopback is the strongest "I am the server /
        # an internal client" claim an IP allowlist can be tricked by.
        BYPASS_VALUE = "127.0.0.1"

        # IP-spoofing request headers a client-IP gate may trust in place of the socket peer. Order
        # is stable so the built probe is deterministic across runs (dedup + reproducibility).
        BYPASS_HEADERS = %w[
          X-Forwarded-For
          X-Forwarded
          X-Forward-For
          X-Forwarded-By
          X-Real-IP
          X-Originating-IP
          X-Remote-IP
          X-Remote-Addr
          X-Client-IP
          X-Cluster-Client-IP
          Client-IP
          True-Client-IP
          X-True-IP
          X-ProxyUser-Ip
          X-Custom-IP-Authorization
        ]

        # Downcased names, for dropping any the browser already sent (so we insert exactly one of
        # each and the forged value can't be diluted by a second header line).
        BYPASS_HEADER_SET = BYPASS_HEADERS.map(&.downcase).to_set

        # The dedup key WITHOUT rebuilding the probe — same gates as `plan` (safe method, response
        # was 401/403), same key. nil exactly when `plan` returns nil. Both gates read
        # detail.row.status (not a header re-parse), so the two paths cannot drift.
        def dedup_key(detail : Store::FlowDetail) : String?
          method, target, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          return nil if malformed
          return nil unless SAFE_METHODS.includes?(method.upcase)
          return nil unless denied_status?(detail.row.status)
          key_string(detail, method.upcase, target)
        end

        def plan(detail : Store::FlowDetail) : Plan?
          req = Proxy::Codec::Http1.parse_request_head(detail.request_head)
          return nil if req.malformed?
          return nil unless SAFE_METHODS.includes?(req.method.upcase)
          return nil unless denied_status?(detail.row.status)
          request = rebuild_with_bypass_headers(detail.request_head, detail.request_body)
          Plan.new(request, [] of Param, key_string(detail, req.method.upcase, req.target))
        end

        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          return [] of Detection unless result.ok?
          status = probe_status(result)
          # Only a flip INTO 2xx is a confirmed bypass. A 3xx (login redirect) or another 4xx is
          # ambiguous and would inflate false positives, so it is intentionally not flagged.
          return [] of Detection unless (200..299).includes?(status)
          orig = detail.row.status
          # A single-shot flip against the CAPTURED baseline (no control re-send without the
          # headers at probe time) can't prove the header caused it — a transient/rate-limited
          # 403 that later clears looks identical. Report it as a Medium "possible" lead, not a
          # confirmed High bypass, so a naturally-varying 403 doesn't produce a false High.
          [Detection.new("forbidden_bypass", Category::ACTIVE, detail.row.host, detail.row.url,
            "Possible access-control bypass via spoofed client-IP header", Store::Severity::Medium,
            "#{orig} → #{status} with X-Forwarded-For/X-Real-IP=#{BYPASS_VALUE} (single-shot; confirm by re-sending WITHOUT the headers)", detail.row.id)]
        rescue
          [] of Detection
        end

        # Only responses that DENIED access are worth probing: a normally-served (2xx) endpoint has
        # no gate to bypass, and 404/5xx aren't access-control denials. 401 (auth challenge) is
        # included alongside 403 because IP allowlists front some auth gateways with a 401.
        private def denied_status?(status : Int32?) : Bool
          status == 401 || status == 403
        end

        # The single key expression both `plan` and `dedup_key` use, so they can't drift. Query is
        # stripped (a client-IP gate is per-endpoint, not per-query-value) → one probe per
        # (host, method, path); host:PORT so the same host on another service is a distinct surface.
        private def key_string(detail : Store::FlowDetail, method_upcase : String, target : String) : String
          "forbidden_bypass|#{detail.row.host}:#{detail.row.port}|#{method_upcase}|#{path_key(target)}"
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

        # Rebuild the request with the full IP-spoofing header set inserted right after the request
        # line: first drop any of those headers the browser already sent (so exactly one authoritative
        # copy of each remains), then insert ours. The body is untouched — none of the inserted names
        # is Content-Length — so no resync is needed.
        private def rebuild_with_bypass_headers(head : Bytes, body : Bytes?) : Bytes
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
            next if i > 0 && bypass_header?(l) # request line (i == 0) is normalized below
            kept << l
          end
          # Normalize an absolute-form (forward-proxy) request line to origin-form: like the other
          # active probes this is sent DIRECT to the origin (no proxy rewrite), and some origins
          # reject an absolute-form target on a non-proxied request — which would make the bypass
          # probe silently miss a real header-controllable gate. Origin-form passes through.
          unless kept.empty?
            rl = kept[0].split(' ')
            kept[0] = "#{rl[0]} #{Active.origin_form(rl[1])} #{rl[2]}" if rl.size == 3
            BYPASS_HEADERS.each_with_index { |name, i| kept.insert(1 + i, "#{name}: #{BYPASS_VALUE}") }
          end
          io = IO::Memory.new
          io << kept.join(eol) << eol << eol
          io.write(bbytes) unless bbytes.empty?
          io.to_slice
        end

        private def bypass_header?(line : String) : Bool
          (c = line.index(':')) ? BYPASS_HEADER_SET.includes?(line[0...c].strip.downcase) : false
        end
      end
    end
  end
end
