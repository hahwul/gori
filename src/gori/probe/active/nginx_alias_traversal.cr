require "./types"
require "../../miner/inject"
require "../../proxy/codec/http1"
require "../../proxy/codec/content_decode"

module Gori
  module Probe
    module Active
      # Active NGINX alias-traversal probe. A classic NGINX misconfiguration serves a static
      # directory with an off-by-one `location` prefix:
      #
      #     location /static { alias /var/www/app/static/; }   # NOTE: no trailing slash on `location`
      #
      # Because the `location` prefix lacks a trailing slash, a URI like `/static../` is still a
      # prefix match and resolves to `/var/www/app/static/../` — one directory ABOVE the alias
      # root — letting an attacker read files outside the intended tree (Orange Tsai, BlackHat
      # USA 2018; PortSwigger BApp "NGINX Alias Traversal").
      #
      # For one in-scope flow whose captured response was a successful (2xx) NON-HTML asset, this
      # re-fetches THE SAME resource through the alias boundary: `/static/main.css` is re-requested
      # as `/static../static/main.css`. On a correctly-configured server that path 404s — the `..`
      # is part of a literal segment `static..`, not a collapsed `../`, so no `location` matches and
      # nothing is served. On the vulnerable config it resolves right back to the very same file and
      # returns byte-identical content. That byte-for-byte match against the CAPTURED baseline is
      # the confirmation, so a normal 404/redirect/different-page can't produce a false positive.
      #
      # Gated hard to stay quiet and low-FP:
      #   * GET by default — the confirmation compares response BODIES, and HEAD returns none (a
      #     safe, idempotent re-read of a resource the browser already fetched). An explicit opt-in
      #     (Options#allow_unsafe: manual per-flow scan / AGGRESSIVE) widens to other body-bearing
      #     methods; HEAD stays out regardless.
      #   * 2xx captured status — there must be a real served resource to re-fetch.
      #   * Non-HTML content type — a SPA / framework catch-all returns the SAME index.html for
      #     ANY path, so an HTML baseline could byte-match the traversal path WITHOUT any alias
      #     bug. Alias directives serve static file trees (css/js/images/fonts/…) anyway, so
      #     restricting to non-HTML kills that dominant false positive at negligible coverage cost.
      #   * A path shaped `/<seg>/<more>` — we need a leading location segment to fold `..` after,
      #     plus a real resource under it to re-fetch.
      #
      # The fold has to land on the `location` prefix EXACTLY, so which prefix a config used
      # decides which probe finds it — and a one-segment guess only ever tested `location /assets`.
      # `location /assets/js`, `location /media/uploads`, `location /files/docs` are just as
      # ordinary, and against those the single probe asked a question the server was always going
      # to answer "404" to: not a clean result, a question never asked. So the deeper boundary is
      # probed too, as a FOLLOW-UP request, when the path has a segment to spare
      # (`/assets/js/app.js` → `/assets../assets/js/app.js` AND `/assets/js../assets/js/app.js`).
      # Two boundaries is where it stops: `alias` roots three levels down are rare enough not to
      # be worth a third request on every static asset in a browse, and the confirmation below is
      # per-probe anyway, so an extra leg can only add coverage, never a false positive.
      class NginxAliasTraversal < Rule
        def info : RuleInfo
          RuleInfo.new("nginx_alias_traversal", "NGINX alias traversal",
            "Re-fetches a static asset through a folded `..` (/static../static/…) and flags a byte-identical hit.",
            Category::ACTIVE)
        end

        # The dedup key WITHOUT rebuilding the probe — same gates as `plan`, same key (nil in
        # exactly the same cases). Both funnel through `gate`, so the two paths cannot drift.
        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          g = gate(detail, opts) || return nil
          key_string(detail, g[0], g[1])
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          g = gate(detail, opts) || return nil
          method_up, path_key = g
          # Rebuild from the ORIGIN-FORM target (query kept, so we re-fetch the exact resource);
          # `traversal_targets` re-derives the same leading segment `gate` validated, plus the deeper one.
          _, target, _ = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          origin_target = Active.origin_form(target)
          targets = traversal_targets(origin_target)
          return nil if targets.empty?
          primary = rebuild(detail.request_head, detail.request_body, targets[0])
          followups = targets[1..].map { |t| rebuild(detail.request_head, detail.request_body, t) }
          Plan.new(primary, [] of Param, key_string(detail, method_up, path_key), followups: followups)
        end

        # One probe per candidate boundary, interpreted independently: the FIRST leg whose body is
        # byte-identical to the capture is the boundary that resolved back to the file, and the
        # rest are ordinary 404s. Reported once — the finding is "this path is reachable through a
        # folded `..`", not "…through N of them" — with the winning target named in the evidence so
        # the operator can replay the exact request. Results arrive primary-first in the order
        # `plan` built them, which is the order `traversal_targets` returns.
        def detections_all(plan : Plan, results : Array(Repeater::Result),
                           detail : Store::FlowDetail) : Array(Detection)
          _, target, _ = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          origin_target = Active.origin_form(target)
          targets = traversal_targets(origin_target)
          base = decoded_body(detail.response_head, detail.response_body)
          return [] of Detection if base.nil? || base.empty?
          results.each_with_index do |result, i|
            tt = targets[i]? || next
            next unless confirmed?(result, base)
            return [Detection.new("nginx_alias_traversal", Category::ACTIVE, detail.row.host, detail.row.url,
              "NGINX alias traversal (path normalization)", Store::Severity::High,
              "#{path_only(origin_target)} also served via #{tt} (byte-identical) — `location` prefix lacks a trailing slash",
              detail.row.id)]
          end
          [] of Detection
        rescue
          [] of Detection
        end

        # One probe leg's verdict: a 2xx whose decoded body is byte-identical to the captured one.
        # A normal server answers the folded path with 404 (literal `static..` segment) or a
        # redirect, and a catch-all's body differs — so neither can confirm.
        private def confirmed?(result : Repeater::Result, base : Bytes) : Bool
          return false unless result.ok?
          return false unless (200..299).includes?(probe_status(result))
          probe = decoded_body(result.head, result.body)
          !probe.nil? && base == probe
        end

        # Two legs at most (see the class comment), so a static-asset-heavy browse spends at most
        # one extra request per distinct path.
        def requests_per_flow : Range(Int32, Int32)
          1..2
        end

        # Single-response fallback for the base-class contract; `detections_all` above is what the
        # analyzer actually calls, and it interprets every leg. Kept in terms of the same
        # `confirmed?` predicate so the two can't drift on what counts as a hit.
        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          detections_all(plan, [result], detail)
        end

        # The shared gate both `plan` and `dedup_key` funnel through, returning
        # {method_upcase, path-without-query} or nil. Cheap: only the start line + FlowRow fields
        # (status / content_type), no header re-parse.
        private def gate(detail : Store::FlowDetail, opts : Options) : {String, String}?
          method, target, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          return nil if malformed
          method_up = method.upcase
          # Body-differential: need a body to byte-compare, so HEAD is always out. By default GET
          # only; opts.allow_unsafe (manual per-flow scan / AGGRESSIVE) widens to any body-bearing
          # method — a static asset gated behind POST/etc. can still leak via the alias boundary.
          return nil unless diff_method_allowed?(method_up, opts)
          status = detail.row.status
          return nil unless status && (200..299).includes?(status)
          ct = detail.row.content_type
          # Non-HTML only — a SPA/framework catch-all returns the same index.html for any path and
          # would byte-match the traversal probe with no alias bug. nil type → treat as ineligible.
          return nil unless ct && !ct.downcase.includes?("html")
          path = path_only(Active.origin_form(target))
          return nil unless first_segment(path) # path must be /<seg>/<more>
          {method_up, path}
        end

        # rule + host:PORT + METHOD + PATH (no query — alias resolution is per-path, not per-value),
        # so the same host on another port/service is a distinct surface. One probe per path.
        private def key_string(detail : Store::FlowDetail, method_upcase : String, path : String) : String
          "nginx_alias_traversal|#{detail.row.host}:#{detail.row.port}|#{method_upcase}|#{path}"
        end

        # The leading path segment to fold `..` after, or nil unless the path is `/<seg>/<more>`:
        # a non-empty first segment AND at least one character under it (the resource to re-fetch).
        # A `.`/`..`/`..`-bearing segment is rejected (degenerate / already-traversing traffic).
        private def first_segment(path : String) : String?
          return nil unless path.starts_with?('/')
          rest = path[1..]
          slash = rest.index('/')
          return nil unless slash && slash > 0
          seg = rest[0...slash]
          return nil if rest[(slash + 1)..].empty?
          return nil if seg == "." || seg == ".." || seg.includes?("..")
          seg
        end

        # The candidate `location` boundaries to fold `..` after, outermost first: `/a/b/c.png`
        # → [`/a../a/b/c.png`, `/a/b../a/b/c.png`]. Any query is preserved so the SAME resource is
        # re-fetched. Empty when the path doesn't qualify (mirrors `first_segment`); the deeper
        # entry is only added when a segment remains UNDER it, so the probe always re-requests a
        # real resource rather than a directory.
        private def traversal_targets(origin_target : String) : Array(String)
          # NOT named `out`: that is a Crystal keyword (C-binding output params), and using it as
          # a local parses fine until the first `return … unless`, whose error then points at the
          # NEXT method.
          targets = [] of String
          qi = origin_target.index('?')
          path = qi ? origin_target[0...qi] : origin_target
          query = qi ? origin_target[qi..] : ""
          seg = first_segment(path)
          return targets unless seg
          targets << "/#{seg}..#{path}#{query}"
          if second = second_prefix(path)
            targets << "#{second}..#{path}#{query}"
          end
          targets
        end

        # `/a/b/c.png` → `/a/b`, the two-segment `location` prefix — nil unless a THIRD segment
        # carries the resource under it, and nil on the same degenerate dot segments
        # `first_segment` rejects (a `..` already in the traffic is not a boundary we introduced).
        private def second_prefix(path : String) : String?
          first = first_segment(path) || return nil
          rest = path[(first.size + 2)..]
          slash = rest.index('/')
          return nil unless slash && slash > 0
          seg = rest[0...slash]
          return nil if rest[(slash + 1)..].empty?
          return nil if seg == "." || seg == ".." || seg.includes?("..")
          "/#{first}/#{seg}"
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

        # Inflate (Content-Encoding) and cap at BODY_CAP for a byte-comparable buffer. Capping BOTH
        # sides at the same bound sidesteps capture-truncation skew: only the first BODY_CAP bytes
        # are ever compared. nil when there is no body.
        private def decoded_body(head : Bytes?, body : Bytes?) : Bytes?
          return nil if body.nil? || body.empty?
          decoded, _ = Proxy::Codec::ContentDecode.decode(head, body, BODY_CAP)
          b = decoded || body
          b[0, {b.size, BODY_CAP}.min]
        end

        # Rebuild the request with the traversal target in the request line; headers and body are
        # untouched (GET carries no Content-Length-affecting change), so no resync is needed. The
        # target is already origin-form (built from `Active.origin_form`), so a forward-proxy
        # absolute-form flow is sent DIRECT to the origin like the other active probes.
        private def rebuild(head : Bytes, body : Bytes?, new_target : String) : Bytes
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
