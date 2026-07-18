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
      #   * GET only — the confirmation compares response BODIES, and HEAD returns none. (A safe,
      #     idempotent re-read of a resource the browser already fetched — never a mutation.)
      #   * 2xx captured status — there must be a real served resource to re-fetch.
      #   * Non-HTML content type — a SPA / framework catch-all returns the SAME index.html for
      #     ANY path, so an HTML baseline could byte-match the traversal path WITHOUT any alias
      #     bug. Alias directives serve static file trees (css/js/images/fonts/…) anyway, so
      #     restricting to non-HTML kills that dominant false positive at negligible coverage cost.
      #   * A path shaped `/<seg>/<more>` — we need a leading location segment to fold `..` after,
      #     plus a real resource under it to re-fetch.
      class NginxAliasTraversal < Rule
        def info : RuleInfo
          RuleInfo.new("nginx_alias_traversal", "NGINX alias traversal",
            "Re-fetches a static asset through a folded `..` (/static../static/…) and flags a byte-identical hit.",
            Category::ACTIVE)
        end

        # The dedup key WITHOUT rebuilding the probe — same gates as `plan`, same key (nil in
        # exactly the same cases). Both funnel through `gate`, so the two paths cannot drift.
        def dedup_key(detail : Store::FlowDetail) : String?
          g = gate(detail) || return nil
          key_string(detail, g[0], g[1])
        end

        def plan(detail : Store::FlowDetail) : Plan?
          g = gate(detail) || return nil
          method_up, path_key = g
          # Rebuild from the ORIGIN-FORM target (query kept, so we re-fetch the exact resource);
          # `traversal_target` re-derives the same leading segment `gate` validated.
          _, target, _ = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          tt = traversal_target(Active.origin_form(target)) || return nil
          request = rebuild(detail.request_head, detail.request_body, tt)
          Plan.new(request, [] of Param, key_string(detail, method_up, path_key))
        end

        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          return [] of Detection unless result.ok?
          # Only a 2xx traversal hit matters — a normal server answers the folded path with 404
          # (literal `static..` segment) or a redirect; either is "not vulnerable".
          return [] of Detection unless (200..299).includes?(probe_status(result))
          base = decoded_body(detail.response_head, detail.response_body)
          # No baseline body to compare against (empty / HEAD-like) → nothing to confirm.
          return [] of Detection if base.nil? || base.empty?
          probe = decoded_body(result.head, result.body)
          # Byte-identical content proves the folded path resolved back to the SAME file — the
          # alias boundary was crossed. A catch-all/normal 404 body differs, so it never matches.
          return [] of Detection unless probe && base == probe

          _, target, _ = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          tt = traversal_target(Active.origin_form(target))
          orig_path = path_only(Active.origin_form(target))
          [Detection.new("nginx_alias_traversal", Category::ACTIVE, detail.row.host, detail.row.url,
            "NGINX alias traversal (path normalization)", Store::Severity::High,
            "#{orig_path} also served via #{tt || "folded .."} (byte-identical) — `location` prefix lacks a trailing slash",
            detail.row.id)]
        rescue
          [] of Detection
        end

        # The shared gate both `plan` and `dedup_key` funnel through, returning
        # {method_upcase, path-without-query} or nil. Cheap: only the start line + FlowRow fields
        # (status / content_type), no header re-parse.
        private def gate(detail : Store::FlowDetail) : {String, String}?
          method, target, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          return nil if malformed
          method_up = method.upcase
          return nil unless method_up == "GET" # need a body to byte-compare; HEAD has none
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

        # `/static/main.css` → `/static../static/main.css`, preserving any query so the SAME
        # resource is re-fetched. nil when the path doesn't qualify (mirrors `first_segment`).
        private def traversal_target(origin_target : String) : String?
          qi = origin_target.index('?')
          path = qi ? origin_target[0...qi] : origin_target
          query = qi ? origin_target[qi..] : ""
          seg = first_segment(path) || return nil
          "/#{seg}..#{path}#{query}"
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
