require "./types"
require "../../miner/inject"
require "../../proxy/codec/http1"

module Gori
  module Probe
    module Active
      # Active CORS origin-reflection probe. Passive analysis can only judge the origins the
      # browser actually sent; it CANNOT prove a server reflects *arbitrary* origins. This rule
      # sends ONE safe-method request with a synthetic, attacker-controlled `Origin` and reports
      # a High issue only when the server both ECHOES that probe origin AND allows credentials
      # — the definitive, exploitable reflected-origin CORS misconfiguration.
      #
      # Gated hard to keep the scan light and low-FP: only endpoints that demonstrably DO CORS,
      # and only GET/HEAD (no state mutation). A well-behaved allowlist rejects the probe origin,
      # so it is never flagged.
      #
      # "Demonstrably does CORS" is Access-Control-Allow-Origin OR `Vary: Origin`, and the second
      # half is not optional. A server only emits ACAO when the REQUEST carried an Origin, and a
      # browser sends no Origin on a same-origin GET — which is most of what a proxied browse
      # captures for an API. Gating on ACAO alone therefore probed only the endpoints whose
      # capture had already been driven cross-origin, i.e. it mostly re-confirmed CORS that was
      # visible in the capture already, and skipped the reflecting endpoint nobody had happened
      # to drive from another origin. `Vary: Origin` is the standing advertisement of exactly the
      # behaviour this rule tests — the response DEPENDS on Origin — and every framework that
      # does dynamic CORS (rack-cors, django-cors-headers, Spring, Express cors) emits it whether
      # or not an Origin arrived. Widening the gate cannot manufacture a false positive:
      # `detections` still fires only when the PROBE response echoes PROBE_ORIGIN back with
      # credentials, so a gate that opens too eagerly costs one request, not a finding.
      class CorsReflection < Rule
        def info : RuleInfo
          RuleInfo.new("cors_reflection", "CORS arbitrary origin",
            "Probes whether the server reflects an arbitrary Origin with Allow-Credentials: true.",
            Category::CORS)
        end

        # A synthetic origin that is obviously not a legitimate allowlisted one. `.example` is a
        # reserved TLD (RFC 2606) that never resolves — the value is only ever a header, never
        # dialed. If the server reflects THIS, it reflects anything.
        PROBE_ORIGIN = "https://gori-cors-probe.example"

        # The dedup key WITHOUT rebuilding the probe request — same gates as `plan` (safe method,
        # response already did CORS), same key. nil exactly when `plan` returns nil.
        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          # Request headers are never needed here (the key is method + target only), so parse
          # just the start-line. The RESPONSE head parse below IS required and stays.
          method, target, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          return nil if malformed
          return nil unless method_allowed?(method.upcase, opts)
          rhead = detail.response_head
          return nil unless rhead
          resp = Proxy::Codec::Http1.parse_response_head(rhead)
          return nil unless does_cors?(resp.headers)
          key_string(detail, method.upcase, target)
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          req = Proxy::Codec::Http1.parse_request_head(detail.request_head)
          return nil if req.malformed?
          return nil unless method_allowed?(req.method.upcase, opts)
          # Only probe endpoints that demonstrably do CORS (ACAO, or a standing `Vary: Origin`).
          rhead = detail.response_head
          return nil unless rhead
          resp = Proxy::Codec::Http1.parse_response_head(rhead)
          return nil unless does_cors?(resp.headers)
          request = rebuild_with_origin(detail.request_head, detail.request_body, PROBE_ORIGIN)
          Plan.new(request, [] of Param, key_string(detail, req.method.upcase, req.target))
        end

        # The captured response proves this endpoint participates in CORS — see the gate note in
        # the class comment for why `Vary: Origin` counts alongside ACAO.
        #
        # `HeaderList#lists?` is the one home of the list-valued-field question, and Vary is
        # exactly that: a comma-joined token list a proxy may also split across several field
        # lines. It compares WHOLE members, so the ordinary `Vary: X-Origin-Hint` does not read
        # as a match — the token-vs-substring confusion `weak_csp?` had to be corrected for once
        # already — and it reads every line, where `get?` would return only the last.
        private def does_cors?(headers : Proxy::Codec::HeaderList) : Bool
          return true if headers.get?("Access-Control-Allow-Origin")
          headers.lists?("Vary", "origin")
        end

        # The single key expression both `plan` and `dedup_key` use, so they can't drift.
        private def key_string(detail : Store::FlowDetail, method_upcase : String, target : String) : String
          "cors_reflection|#{detail.row.host}:#{detail.row.port}|#{method_upcase}|#{path_key(target)}"
        end

        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
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
