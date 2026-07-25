require "./types"
require "../../miner/inject"
require "../../proxy/codec/http1"
require "../../proxy/codec/content_decode"

module Gori
  module Probe
    module Active
      # Active Host-header injection probe (web-cache poisoning / password-reset poisoning). Many apps
      # build absolute URLs — reset links, canonical tags, redirects — from the incoming `Host` /
      # `X-Forwarded-Host` instead of a fixed configured host. If that reflected value lands in a
      # cacheable response, an attacker poisons the shared cache for every visitor; if it lands in a
      # password-reset email, the reset link points at the attacker.
      #
      # For one in-scope flow this re-sends ONE safe-method request carrying a synthetic
      # `X-Forwarded-Host: gori-host-probe.example` and flags Medium only when that reserved host comes
      # back as the AUTHORITY of an absolute URL in the response `Location` or body. A server that uses
      # a configured canonical host ignores the header and never reflects it.
      #
      # Gated to keep it quiet and low-FP: only flows whose captured response is host-reflection-prone
      # — either cacheable (a `public` / positive `max-age` Cache-Control, not `no-store`/`private`) or
      # already reflecting its OWN Host as a URL authority in Location/body. Confirmation requires the
      # probe host at an AUTHORITY position (Active.url_authority / a `//host` boundary scan), so a
      # bare mention or the `//probe@evil` userinfo trick does not fire. NOTE: this rule's dedup_key is
      # the heaviest of the set — its gate may scan the captured body — which the cacheable /
      # self-referential narrowing keeps rare.
      class HostHeaderInjection < Rule
        PROBE_HOST   = "gori-host-probe.example"
        PROBE_HEADER = "X-Forwarded-Host"

        def info : RuleInfo
          RuleInfo.new("host_header_injection", "Host header injection",
            "Sends a synthetic X-Forwarded-Host and flags it reflected as an absolute-URL authority.",
            Category::ACTIVE)
        end

        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          g = gate(detail, opts) || return nil
          key_string(detail, g[0], g[1])
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          g = gate(detail, opts) || return nil
          method_up, path = g
          request = rebuild_with_xfh(detail.request_head, detail.request_body)
          Plan.new(request, [] of Param, key_string(detail, method_up, path))
        end

        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          return [] of Detection unless result.ok?
          resp = Proxy::Codec::Http1.parse_response_head(result.head)
          loc = resp.headers.get?("Location")
          reflected = (loc && (a = Active.url_authority(loc)) && a[0] == PROBE_HOST) || body_reflects?(result)
          return [] of Detection unless reflected
          [Detection.new("host_header_injection", Category::ACTIVE, detail.row.host, detail.row.url,
            "Host header reflected (X-Forwarded-Host injection)", Store::Severity::Medium,
            "X-Forwarded-Host reflected as #{PROBE_HOST} in an absolute URL", detail.row.id)]
        rescue
          [] of Detection
        end

        # Shared gate for plan + dedup_key: {METHOD, path-no-query} for a safe-method flow whose
        # captured response is host-reflection-prone, else nil.
        private def gate(detail : Store::FlowDetail, opts : Options) : {String, String}?
          method, target, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          return nil if malformed
          method_up = method.upcase
          return nil unless method_allowed?(method_up, opts)
          return nil unless host_reflection_prone?(detail)
          {method_up, path_only(Active.origin_form(target))}
        end

        private def key_string(detail : Store::FlowDetail, method_upcase : String, path : String) : String
          "host_header_injection|#{detail.row.host}:#{detail.row.port}|#{method_upcase}|#{path}"
        end

        # A redirect that already points at its own Host (the reset-link shape — any content type) OR
        # an HTML page that is cacheable / already reflects its own Host as an absolute-URL authority.
        # The cacheable + body-scan checks are HTML-gated so the automatic scan does not fire an
        # X-Forwarded-Host probe at every cacheable static asset (JS/CSS/image/JSON), and the heavier
        # per-flow dedup body scan only runs for HTML.
        private def host_reflection_prone?(detail : Store::FlowDetail) : Bool
          rhead = detail.response_head || return false
          resp = Proxy::Codec::Http1.parse_response_head(rhead)
          host = detail.row.host.downcase
          loc = resp.headers.get?("Location")
          return true if loc && (a = Active.url_authority(loc)) && a[0] == host
          return false unless html?(detail.row.content_type)
          return true if cacheable?(resp.headers.get?("Cache-Control").try(&.downcase))
          body = decoded_body(detail.response_head, detail.response_body)
          return false unless body
          authority_reflection?(String.new(body).scrub, host)
        end

        private def html?(ct : String?) : Bool
          ct.try(&.downcase.includes?("html")) == true
        end

        # `public` or a positive `max-age`, and not explicitly `no-store`/`private`.
        private def cacheable?(cc : String?) : Bool
          return false unless cc
          return false if cc.includes?("no-store") || cc.includes?("private")
          cc.includes?("public") || positive_max_age?(cc)
        end

        private def positive_max_age?(cc : String) : Bool
          idx = cc.index("max-age=") || return false
          i = idx + 8
          n = 0
          seen = false
          while i < cc.size && cc[i].ascii_number?
            n = n * 10 + (cc[i].ord - '0'.ord)
            seen = true
            i += 1
          end
          seen && n > 0
        end

        private def body_reflects?(result : Repeater::Result) : Bool
          decoded, _ = Proxy::Codec::ContentDecode.decode(result.head, result.body, BODY_CAP)
          bytes = decoded || result.body
          return false if bytes.nil? || bytes.empty?
          authority_reflection?(String.new(bytes[0, {bytes.size, BODY_CAP}.min]).scrub, PROBE_HOST)
        end

        # Does `token` appear as the AUTHORITY host of an absolute/scheme-relative URL in `text`? The
        # token must be immediately preceded by `//` (from `://host` or `//host`) and NOT be a userinfo
        # prefix (`token@realhost`) or the start of a longer hostname (`token.evil.com`).
        private def authority_reflection?(text : String, token : String) : Bool
          start = 0
          while pos = text.index(token, start)
            start = pos + token.size
            if pos >= 2 && text[pos - 1]? == '/' && text[pos - 2]? == '/'
              after = text[pos + token.size]?
              unless after == '@' || (after && (after.ascii_alphanumeric? || after == '.' || after == '-'))
                return true
              end
            end
          end
          false
        end

        private def decoded_body(head : Bytes?, body : Bytes?) : Bytes?
          return nil if body.nil? || body.empty?
          decoded, _ = Proxy::Codec::ContentDecode.decode(head, body, BODY_CAP)
          b = decoded || body
          b[0, {b.size, BODY_CAP}.min]
        end

        private def path_only(origin_target : String) : String
          qi = origin_target.index('?')
          qi ? origin_target[0...qi] : origin_target
        end

        # Rebuild the request with a single authoritative `X-Forwarded-Host: <probe>` after the request
        # line: drop any the browser sent, normalize the request line to origin-form (probes go direct
        # to the origin). Body untouched — no Content-Length resync. Mirrors CorsReflection#rebuild.
        private def rebuild_with_xfh(head : Bytes, body : Bytes?) : Bytes
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
            next if i > 0 && header_named?(l, "x-forwarded-host") # request line (i == 0) normalized below
            kept << l
          end
          unless kept.empty?
            rl = kept[0].split(' ')
            kept[0] = "#{rl[0]} #{Active.origin_form(rl[1])} #{rl[2]}" if rl.size == 3
            kept.insert(1, "#{PROBE_HEADER}: #{PROBE_HOST}")
          end
          io = IO::Memory.new
          io << kept.join(eol) << eol << eol
          io.write(bbytes) unless bbytes.empty?
          io.to_slice
        end

        private def header_named?(line : String, name : String) : Bool
          (c = line.index(':')) ? line[0...c].strip.downcase == name : false
        end
      end
    end
  end
end
