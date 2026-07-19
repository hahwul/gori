require "json"
require "./rule"
require "../../ascii_bytes"
require "../../proxy/h2/grpc"
require "../../sse"

module Gori
  module Probe
    module Passive
      # Technology / protocol fingerprints (category "tech", Info). These also feed the
      # project's "representative technologies" summary. Runs on every flow (not response-gated):
      # several signals live on the request side or on a 101 upgrade.
      class Tech < Rule
        # Lowercase needles for the allocation-free byte gates in graphql? (AsciiBytes.contains_ci?
        # requires an already-lowercase needle). Held as constants so the slices are built once
        # for the process, not per flow.
        private GRAPHQL_PATH = "/graphql".to_slice
        private JSON_CT      = "json".to_slice
        private QUERY_KEY    = %("query").to_slice

        def info : RuleInfo
          RuleInfo.new("tech", "Technology fingerprints",
            "Identifies server software, frameworks, and protocols (WebSocket, gRPC, GraphQL, SSE, HTTP/2) from headers and bodies.",
            Category::TECH)
        end

        def check(ctx : Context, acc : Array(Detection)) : Nil
          check_protocols(ctx, acc)
          check_tech_headers(ctx, acc)
          check_frameworks(ctx, acc)
        end

        private def check_protocols(ctx : Context, acc : Array(Detection)) : Nil
          detail = ctx.detail
          req_ct = ctx.req.headers.get?("Content-Type")
          resp_ct = ctx.content_type
          resp = ctx.raw_response
          if websocket?(ctx, resp)
            path = websocket_path(ctx.req.target)
            proto = ctx.req.headers.get?("Sec-WebSocket-Protocol").try(&.strip).presence
            evidence = String.build do |io|
              io << "WebSocket"
              io << " " << path unless path.empty? || path == "/"
              io << " (" << proto << ")" if proto
            end
            title = path.empty? || path == "/" ? "WebSocket endpoint" : "WebSocket endpoint #{path}"
            acc << tech(ctx, "tech_websocket", title, evidence)
          end
          if Proxy::H2::Grpc.grpc?(req_ct) || Proxy::H2::Grpc.grpc?(resp_ct)
            acc << tech(ctx, "tech_grpc", "gRPC service")
          end
          acc << tech(ctx, "tech_graphql", "GraphQL endpoint") if graphql?(ctx, req_ct)
          # `resp_ct` is the response Content-Type the capture already parsed out of the head
          # (the same value grpc? consumes above), so ask Sse directly instead of re-parsing the
          # raw head bytes: event_stream? would copy the whole head to a String and split it into
          # per-header Strings on EVERY flow just to read a header we are already holding.
          acc << tech(ctx, "tech_sse", "Server-Sent Events stream") if Sse.sse?(resp_ct)
          if detail.http_version.starts_with?("HTTP/2") || !detail.h2_conn_id.nil?
            acc << tech(ctx, "tech_http2", "HTTP/2")
          end
        end

        # 101 Switching Protocols with Upgrade: websocket, or a request that asked for WS and
        # got a matching upgrade response (covers slightly messy origins that omit/case-fold).
        private def websocket?(ctx : Context, resp : Proxy::Codec::RawResponse?) : Bool
          req_ws = ctx.req.headers.get?("Upgrade").try(&.downcase) == "websocket"
          resp_ws = resp.try(&.headers.get?("Upgrade").try(&.downcase)) == "websocket"
          status_ok = ctx.row.status == 101
          (status_ok && (resp_ws || req_ws)) || (req_ws && resp_ws)
        end

        # Path-only form of the request target (strip query / absolute-form origin).
        private def websocket_path(target : String) : String
          t = target
          if t.starts_with?("http://") || t.starts_with?("https://")
            # absolute-form: keep path+query after authority
            if slash = t.index('/', t.index("://").try(&.+(3)) || 0)
              t = t[slash..]
            else
              t = "/"
            end
          end
          qi = t.index('?')
          qi ? t[0...qi] : t
        end

        # Response headers that name a framework/runtime (often with an exact version → a
        # CVE-matching aid) and serve no client purpose. Each is recorded as a project tech fact
        # like Server/X-Powered-By, so an analyst sees the stack without opening a flow.
        FRAMEWORK_HEADERS = {
          "X-AspNet-Version"       => "tech_aspnet",
          "X-AspNetMvc-Version"    => "tech_aspnetmvc",
          "X-Generator"            => "tech_generator",
          "X-Drupal-Dynamic-Cache" => "tech_drupal",
        }

        private def check_tech_headers(ctx : Context, acc : Array(Detection)) : Nil
          return unless r = ctx.raw_response
          if (server = r.headers.get?("Server")) && !server.blank?
            acc << tech(ctx, "tech_server", "Server: #{server.strip}", server.strip)
          end
          if (pb = r.headers.get?("X-Powered-By")) && !pb.blank?
            acc << tech(ctx, "tech_powered_by", "X-Powered-By: #{pb.strip}", pb.strip)
          end
          FRAMEWORK_HEADERS.each do |header, code|
            if (v = r.headers.get?(header)) && !v.blank?
              acc << tech(ctx, code, "#{header}: #{v.strip}", v.strip)
            end
          end
        end

        # GraphQL is identified by the path, or by a JSON request body whose `query` field is a
        # STRING holding a GraphQL document. Requiring a string value keeps Elasticsearch /
        # OpenSearch query DSL bodies (where `query` is an OBJECT) out of the match.
        private def graphql?(ctx : Context, req_ct : String?) : Bool
          # Byte scans over the borrowed slices (String#to_slice is a view): the target can carry
          # a multi-KB query string, and downcasing it — plus the Content-Type — allocated a full
          # copy of each on every flow just to run two case-insensitive substring tests.
          return true if AsciiBytes.contains_ci?(ctx.req.target.to_slice, GRAPHQL_PATH)
          return false unless req_ct && AsciiBytes.contains_ci?(req_ct.to_slice, JSON_CT)
          body = ctx.detail.request_body
          return false unless body
          # 8 KB truncated mid-JSON on real GraphQL requests (a sizeable `variables` object),
          # which then fails JSON.parse and mis-classified them as non-GraphQL; allow up to 256 KB.
          capped = body[0, {body.size, 256 * 1024}.min]
          # A GraphQL request body always carries a top-level `"query"` key; a cheap substring
          # check lets the overwhelming majority of non-GraphQL JSON POSTs skip the full
          # JSON.parse (a tree build over ≤256 KB) on the shared passive-scan fiber. Conservative:
          # a `"query"` appearing only inside a value still parses, then the as_h?/as_s? guards reject.
          #
          # Scan the RAW BYTES, before materialising `text`. The gate was already here, but it ran
          # against a String that had just been copied+scrubbed out of those same ≤256 KB — so an
          # ordinary JSON API POST still paid a full-body copy and a UTF-8 validation pass to be
          # told "not GraphQL". Gating first makes the common case allocation-free. Byte-scanning
          # is case-insensitive where `includes?` was exact, which only ever opens the gate wider
          # (scrub cannot create or destroy an ASCII `"query"`), and the as_h?/as_s? guards below
          # still decide the outcome — so no detection is lost.
          return false unless AsciiBytes.contains_ci?(capped, QUERY_KEY)
          text = String.new(capped).scrub
          q = begin
            JSON.parse(text).as_h?.try(&.["query"]?).try(&.as_s?)
          rescue JSON::ParseException
            nil
          end
          return false unless q
          doc = q.lstrip
          doc.starts_with?('{') || doc.starts_with?("query") || doc.starts_with?("mutation") ||
            doc.starts_with?("subscription") || doc.starts_with?("fragment")
        end

        # Client-side framework/library fingerprints from the response BODY (headers rarely
        # name these). Each {marker, code, label, has_version}: has_version marks a pattern that
        # defines capture group 1 (a version we surface in evidence — a CVE aid and the scope
        # for prototype-pollution / clobbering findings). Info, and each doubles as a project
        # tech fact via FIXED_TECH_LABELS. Nuxt implies Vue and Next implies React by design —
        # both are reported when both markers are present.
        FRAMEWORK_MARKERS = [
          {/\bdata-reactroot\b|__REACT_DEVTOOLS_GLOBAL_HOOK__|\breact-dom(?:[.-][\w.]*)?\.js\b/, "tech_react", "React", false},
          {/\b__NEXT_DATA__\b|\/_next\/static\//, "tech_nextjs", "Next.js", false},
          {/\bwindow\.__NUXT__\b|\/_nuxt\//, "tech_nuxt", "Nuxt", false},
          {/\bdata-v-[0-9a-f]{6,10}\b|\b__VUE__\b|\bVue\.createApp\b/, "tech_vue", "Vue", false},
          {/\bng-version\s*=\s*"([^"]+)"|\bng-app\b|\[ng-version\]/, "tech_angular", "Angular", true},
          {/\bjquery[-.](\d+\.\d+(?:\.\d+)?)(?:\.min)?\.js\b|\bjQuery\.fn\.jquery\b|\/jquery(?:\.min)?\.js\b/, "tech_jquery", "jQuery", true},
        ] of {Regex, String, String, Bool}

        private def check_frameworks(ctx : Context, acc : Array(Detection)) : Nil
          return unless ctx.html? || ctx.js?
          text = ctx.body_text
          return if text.nil? || text.empty?
          FRAMEWORK_MARKERS.each do |(re, code, label, has_version)|
            next unless m = re.match(text)
            ver = has_version ? m[1]? : nil
            title = ver ? "#{label} #{ver}" : label
            acc << tech(ctx, code, title, ver)
          end
        end

        private def tech(ctx : Context, code : String, title : String, evidence : String? = nil) : Detection
          Detection.new(code, Category::TECH, ctx.host, ctx.url, title, Store::Severity::Info, evidence, ctx.fid)
        end
      end
    end
  end
end
