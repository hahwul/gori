require "./types"
require "../../miner/inject"
require "../../proxy/codec/http1"

module Gori
  module Prism
    module Active
      # Active CORS origin-reflection probe. Passive analysis can only judge the origins the
      # browser actually sent; it CANNOT prove a server reflects *arbitrary* origins. This rule
      # sends ONE safe-method request with a synthetic, attacker-controlled `Origin` and reports
      # a High finding only when the server both ECHOES that probe origin AND allows credentials
      # — the definitive, exploitable reflected-origin CORS misconfiguration.
      #
      # Gated hard to keep the scan light and low-FP: only endpoints that ALREADY do CORS (the
      # captured response carried an Access-Control-Allow-Origin header) are probed, and only
      # GET/HEAD (no state mutation). A well-behaved allowlist rejects the probe origin, so it is
      # never flagged.
      class CorsReflection < Rule
        # A synthetic origin that is obviously not a legitimate allowlisted one. `.example` is a
        # reserved TLD (RFC 2606) that never resolves — the value is only ever a header, never
        # dialed. If the server reflects THIS, it reflects anything.
        PROBE_ORIGIN = "https://gori-cors-probe.example"

        def plan(detail : Store::FlowDetail) : Plan?
          req = Proxy::Codec::Http1.parse_request_head(detail.request_head)
          return nil if req.malformed?
          return nil unless SAFE_METHODS.includes?(req.method.upcase)
          # Only probe endpoints that demonstrably do CORS (response already carried an ACAO).
          rhead = detail.response_head
          return nil unless rhead
          resp = Proxy::Codec::Http1.parse_response_head(rhead)
          return nil unless resp.headers.get?("Access-Control-Allow-Origin")
          request = rebuild_with_origin(detail.request_head, detail.request_body, PROBE_ORIGIN)
          key = "cors_reflection|#{detail.row.host}|#{req.method.upcase}|#{path_key(req.target)}"
          Plan.new(request, [] of Param, key)
        end

        def detections(plan : Plan, result : Replay::Result, detail : Store::FlowDetail) : Array(Detection)
          return [] of Detection unless result.ok?
          resp = Proxy::Codec::Http1.parse_response_head(result.head)
          acao = resp.headers.get?("Access-Control-Allow-Origin").try(&.strip)
          # Only a reflection of OUR probe origin proves arbitrary-origin echoing; `*` or a fixed
          # allowlisted value is not (and `*` is handled by the passive wildcard check).
          return [] of Detection unless acao == PROBE_ORIGIN
          creds = resp.headers.get?("Access-Control-Allow-Credentials").try(&.downcase.strip) == "true"
          return [] of Detection unless creds
          [Detection.new("cors_arbitrary_origin", Category::CORS, detail.row.host, detail.row.url,
            "CORS reflects an arbitrary origin with credentials", Store::Severity::High,
            "confirmed by probe", detail.row.id)]
        rescue
          [] of Detection
        end

        # Rebuild the request with a single, authoritative `Origin: <probe>` header: drop any
        # existing Origin the browser sent, then insert ours right after the request line. The
        # body is untouched, so Content-Length stays valid (no resync needed).
        private def rebuild_with_origin(head : Bytes, body : Bytes?, origin : String) : Bytes
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
            next if i > 0 && origin_header?(l) # the request line (i == 0) is normalized below
            kept << l
          end
          # Normalize an absolute-form (forward-proxy) request line to origin-form: like the
          # ReflectedParam probe, this is sent DIRECT to the origin (no proxy rewrite), and some
          # origins reject an absolute-form target on a non-proxied request — which would make the
          # CORS probe silently miss a real arbitrary-origin reflection. Origin-form passes through.
          unless kept.empty?
            rl = kept[0].split(' ')
            kept[0] = "#{rl[0]} #{Active.origin_form(rl[1])} #{rl[2]}" if rl.size == 3
          end
          kept.insert(1, "Origin: #{origin}") unless kept.empty?
          io = IO::Memory.new
          io << kept.join(eol) << eol << eol
          io.write(bbytes) unless bbytes.empty?
          io.to_slice
        end

        private def origin_header?(line : String) : Bool
          (c = line.index(':')) ? line[0...c].strip.downcase == "origin" : false
        end

        # Dedup path: origin-form target with the query stripped (a CORS policy is per-endpoint,
        # not per-query-value), so one probe per (host, method, path).
        private def path_key(target : String) : String
          t = Active.origin_form(target)
          qi = t.index('?')
          qi ? t[0...qi] : t
        end
      end
    end
  end
end
