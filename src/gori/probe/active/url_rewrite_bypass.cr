require "./types"
require "../../miner/inject"
require "../../fuzz/content_length"
require "../../proxy/codec/http1"
require "../../proxy/codec/content_decode"

module Gori
  module Probe
    module Active
      # Active access-control bypass probe via URL-REWRITE headers (`X-Original-URL` / `X-Rewrite-URL`).
      # Some app frameworks (classic ASP.NET, some Symfony/PHP setups) let a request to an ALLOWED path
      # (`/`) be internally re-routed to another path named in these headers — while the edge proxy
      # enforces its ACL on the literal request line (`/`). So `GET /` + `X-Original-URL: /admin` can
      # serve `/admin` past a proxy that would have blocked `GET /admin`. These path-rewrite headers
      # were DELIBERATELY excluded from ForbiddenBypass (which forges a single flat client-IP value);
      # this is their dedicated probe.
      #
      # For one in-scope flow whose captured response was 401/403/404, it sends TWO requests:
      #   probe   = `GET /` + X-Original-URL/X-Rewrite-URL naming the original (gated) path
      #   control = plain `GET /` (no rewrite headers)
      # and flags Medium "possible bypass" when the probe is 2xx AND its response differs from the
      # control's. The control is the crucial guard: `GET /` usually 200s regardless, so a bare "probe
      # 200" is meaningless — only a probe response that DIFFERS from the plain-root control shows the
      # rewrite header actually selected the gated resource. Comparison is a coarse {status, body-size}
      # fingerprint: it tolerates FIXED-length root jitter (a same-length rotating token) but can still
      # miss a gated page that happens to match the root's length, or fire when the root's body length
      # varies between the two sends — hence Medium/"possible", to be confirmed manually. Gated to
      # body-comparable methods (GET by default, HEAD out; Options#allow_unsafe widens).
      class UrlRewriteBypass < Rule
        def info : RuleInfo
          RuleInfo.new("url_rewrite_bypass", "Access-control bypass (URL-rewrite headers)",
            "Requests / with X-Original-URL/X-Rewrite-URL naming a denied path and flags a served 2xx.",
            Category::ACTIVE)
        end

        def requests_per_flow : Range(Int32, Int32)
          2..2 # probe + control
        end

        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          g = gate(detail, opts) || return nil
          key_string(detail, g[0], g[1])
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          g = gate(detail, opts) || return nil
          method_up, path, orig_full = g
          probe = rebuild_root(detail.request_head, detail.request_body, orig_full)
          control = rebuild_root(detail.request_head, detail.request_body, nil)
          Plan.new(probe, [] of Param, key_string(detail, method_up, path), [control])
        end

        def detections_all(plan : Plan, results : Array(Repeater::Result), detail : Store::FlowDetail) : Array(Detection)
          probe = results[0]?
          control = results[1]?
          return [] of Detection unless probe && probe.ok? && control && control.ok?
          ps = probe_status(probe)
          return [] of Detection unless (200..299).includes?(ps)
          cs = probe_status(control)
          psize = body_size(probe)
          csize = body_size(control)
          # Header ignored ⇒ the probe is just the plain-root response (same status + size) ⇒ no bypass.
          return [] of Detection if ps == cs && psize == csize
          [Detection.new("url_rewrite_bypass", Category::ACTIVE, detail.row.host, detail.row.url,
            "Possible access-control bypass via URL-rewrite header", Store::Severity::Medium,
            "#{detail.row.status} → #{ps} via X-Original-URL/X-Rewrite-URL (differs from root; single-shot, confirm)"[0, 120],
            detail.row.id)]
        rescue
          [] of Detection
        end

        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          detections_all(plan, [result], detail)
        end

        # Shared gate for plan + dedup_key: {METHOD, path-no-query, full origin-form target} for a
        # body-comparable 401/403/404 with a non-root path, else nil.
        private def gate(detail : Store::FlowDetail, opts : Options) : {String, String, String}?
          method, target, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          return nil if malformed
          method_up = method.upcase
          return nil unless diff_method_allowed?(method_up, opts)
          status = detail.row.status
          return nil unless status == 401 || status == 403 || status == 404
          orig_full = Active.origin_form(target)
          path = path_only(orig_full)
          return nil unless path.starts_with?('/') && path.size > 1
          {method_up, path, orig_full}
        end

        private def key_string(detail : Store::FlowDetail, method_upcase : String, path : String) : String
          "url_rewrite_bypass|#{detail.row.host}:#{detail.row.port}|#{method_upcase}|#{path}"
        end

        # Rebuild the request as `<method> / <version>`: drop any X-Original-URL/X-Rewrite-URL the
        # browser sent, then (for the PROBE, orig != nil) insert one authoritative copy of each naming
        # the gated path. Body untouched.
        private def rebuild_root(head : Bytes, body : Bytes?, orig : String?) : Bytes
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
          return head if lines.empty?
          parts = lines[0].split(' ')
          method = parts.size == 3 ? parts[0] : "GET"
          version = parts.size == 3 ? parts[2] : "HTTP/1.1"
          kept = ["#{method} / #{version}"]
          lines[1..].each do |l|
            kept << l unless header_named?(l, "x-original-url") || header_named?(l, "x-rewrite-url")
          end
          if orig
            kept.insert(1, "X-Original-URL: #{orig}")
            kept.insert(2, "X-Rewrite-URL: #{orig}")
          end
          io = IO::Memory.new
          io << kept.join(eol) << eol << eol
          io.write(bbytes) unless bbytes.empty?
          Fuzz::ContentLength.sync(io.to_slice, false)
        end

        private def header_named?(line : String, name : String) : Bool
          (c = line.index(':')) ? line[0...c].strip.downcase == name : false
        end

        private def path_only(origin_target : String) : String
          qi = origin_target.index('?')
          qi ? origin_target[0...qi] : origin_target
        end

        private def probe_status(result : Repeater::Result) : Int32
          if r = result.response
            return r.status
          end
          Proxy::Codec::Http1.parse_response_head(result.head).status
        rescue
          0
        end

        private def body_size(result : Repeater::Result) : Int32
          decoded, _ = Proxy::Codec::ContentDecode.decode(result.head, result.body, BODY_CAP)
          b = decoded || result.body
          b ? {b.size, BODY_CAP}.min : 0
        end
      end
    end
  end
end
