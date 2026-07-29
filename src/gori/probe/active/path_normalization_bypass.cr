require "./types"
require "../../miner/inject"
require "../../proxy/codec/http1"

module Gori
  module Probe
    module Active
      # Active access-control bypass probe via PATH NORMALIZATION (sibling of ForbiddenBypass, which
      # forges client-IP headers; this one mangles the path). A gateway and its backend often disagree
      # on how a path normalizes: the proxy enforces the ACL on the literal `/admin` but the backend
      # collapses `/admin/..;/admin`, `/./admin`, `/%2e/admin`, a trailing `%2e`/`%20`, … back to
      # `/admin` and serves it. Passive analysis cannot tell such a control apart from any 401/403.
      #
      # For one in-scope flow whose captured response was 401/403, it re-requests the SAME resource
      # through a small set of normalization tricks, plus a CONTROL request for the canonical path
      # exactly as captured, and flags a Medium "possible bypass" when a variant flips to 2xx AND
      # the control is still denied. The control is what makes the flip attributable: judging the
      # variants against the CAPTURED status alone could not tell "the proxy ACL disagrees with the
      # backend" from "the 403 was transient and had already cleared", so a rate-limited or flapping
      # endpoint produced a bypass finding for every variant at once. The control is sent LAST, so a
      # gate that opened on its own answers 2xx there too and the whole finding is suppressed.
      #
      # Still Medium: two adjacent requests cannot rule out backends that disagree, so this remains
      # a lead — just no longer one that fires on ordinary flapping. Gated to safe methods (GET/HEAD
      # — the confirmation is a status flip, which HEAD provides) and to originally-denied responses,
      # so a normally-served endpoint is never probed. A control that normalizes correctly answers
      # every variant with the same 401/403 and is never flagged.
      #
      # Every variant is chosen to resolve to the ORIGINAL resource (`/admin`), NOT to `/admin/`: a
      # bare trailing slash legitimately 200s on many servers, so tricks that canonicalize to `path/`
      # (`/admin/.`, `/admin/./`, `/admin//`) are deliberately EXCLUDED as a false-positive vector.
      class PathNormalizationBypass < Rule
        def info : RuleInfo
          RuleInfo.new("path_normalization_bypass", "Access-control bypass (path normalization)",
            "Re-requests a denied (401/403) path through normalization tricks and flags a 2xx bypass.",
            Category::ACTIVE)
        end

        # 5 variants (+1 under aggressive) plus the canonical-path control.
        def requests_per_flow : Range(Int32, Int32)
          6..7
        end

        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          g = gate(detail, opts) || return nil
          key_string(detail, g[0], g[1], opts)
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          g = gate(detail, opts) || return nil
          method_up, path = g
          vs = variants(path, opts.aggressive)
          requests = vs.map { |(_, np)| rebuild_target(detail.request_head, detail.request_body, np) }
          params = vs.map { |(label, np)| Param.new("path", label, np) }
          # The control is the CANONICAL path, appended LAST so it is sent after every variant:
          # `params` keeps indexing results 0..n-1 and the control lands at results[params.size].
          requests << rebuild_target(detail.request_head, detail.request_body, path)
          Plan.new(requests.first, params, key_string(detail, method_up, path, opts), requests[1..])
        end

        # results = [variant…, control]. Flag when a variant flipped the denied status to 2xx AND
        # the canonical path is still denied. One grouped Detection per host, listing which tricks
        # worked.
        def detections_all(plan : Plan, results : Array(Repeater::Result), detail : Store::FlowDetail) : Array(Detection)
          control = results[plan.params.size]?
          # No usable control ⇒ no attribution. Refuse rather than fall back to the captured status:
          # that fallback IS the false positive this leg exists to remove.
          return [] of Detection unless control && control.ok?
          # The canonical path serves 2xx now too ⇒ the gate is simply open (a transient/rate-limited
          # 403 that cleared), and every variant "flip" below is that same clearing, not a bypass.
          return [] of Detection if (200..299).includes?(probe_status(control))
          orig = detail.row.status
          hits = [] of String
          plan.params.each_with_index do |param, i|
            r = results[i]?
            next unless r && r.ok?
            next unless (200..299).includes?(probe_status(r))
            hits << param.name
          end
          return [] of Detection if hits.empty?
          [Detection.new("path_normalization_bypass", Category::ACTIVE, detail.row.host, detail.row.url,
            "Possible access-control bypass via path normalization", Store::Severity::Medium,
            "#{orig} → 2xx via #{hits.join(", ")}; canonical path still denied"[0, 120],
            detail.row.id)]
        rescue
          [] of Detection
        end

        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          detections_all(plan, [result], detail)
        end

        # Shared gate for plan + dedup_key: {METHOD, path-no-query} for a safe-method 401/403 with a
        # non-root, non-degenerate path, else nil.
        private def gate(detail : Store::FlowDetail, opts : Options) : {String, String}?
          method, target, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          return nil if malformed
          method_up = method.upcase
          return nil unless method_allowed?(method_up, opts)
          status = detail.row.status
          return nil unless status == 401 || status == 403
          path = path_only(Active.origin_form(target))
          return nil unless path.starts_with?('/') && path.size > 1
          return nil if path.includes?("..") # already-traversing / degenerate
          {method_up, path}
        end

        # host:PORT + METHOD + path, plus an `|aggr` tag under aggressive opts: AGGRESSIVE adds a
        # variant (a wider probe SET, not just wider caps), so its key must differ from the ACTIVE key
        # or the ACTIVE↔AGGRESSIVE backfill re-arm would skip an already-seen surface and never send the
        # extra variant. Stays byte-identical to plan's key for the SAME opts (equivalence invariant).
        private def key_string(detail : Store::FlowDetail, method_upcase : String, path : String, opts : Options) : String
          "path_normalization_bypass|#{detail.row.host}:#{detail.row.port}|#{method_upcase}|#{path}#{opts.aggressive ? "|aggr" : ""}"
        end

        # Deterministic normalization variants of `path` (each {short label, rewritten path}). Every
        # one survives a naive proxy ACL yet collapses to the ORIGINAL `path` (never `path/`) on a
        # lenient backend — see the class comment for why `path/`-equivalents are excluded. Aggressive
        # adds the `;`-path-param variant (still ≤ 7 total).
        private def variants(path : String, aggressive : Bool) : Array({String, String})
          base = [
            {"..;", "#{path}/..;#{path}"},          # /admin/..;/admin -> /admin (Tomcat ;-param + ..)
            {"leading-dot-slash", "/.#{path}"},     # /./admin -> /admin
            {"leading-encoded-dot", "/%2e#{path}"}, # /%2e/admin -> /admin
            {"encoded-dot", "#{path}%2e"},          # /admin%2e -> /admin. (distinct literal, never /admin/)
            {"encoded-space", "#{path}%20"},        # /admin%20 -> trailing space stripped -> /admin
          ]
          base << {"semicolon", "#{path};"} if aggressive # /admin; -> /admin (empty path param)
          base
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

        # Rebuild the request with a new request-line target; headers/body untouched (no CL change).
        private def rebuild_target(head : Bytes, body : Bytes?, new_target : String) : Bytes
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
          unless lines.empty?
            parts = lines[0].split(' ')
            lines[0] = "#{parts[0]} #{new_target} #{parts[2]}" if parts.size == 3
          end
          io = IO::Memory.new
          io << lines.join(eol) << eol << eol
          io.write(bbytes) unless bbytes.empty?
          io.to_slice
        end
      end
    end
  end
end
