require "json"
require "./rule"
require "../../proxy/h2/grpc"
require "../../sse"

module Gori
  module Prism
    module Passive
      # Technology / protocol fingerprints (category "tech", Info). These also feed the
      # project's "representative technologies" summary. Runs on every flow (not response-gated):
      # several signals live on the request side or on a 101 upgrade.
      class Tech < Rule
        def check(ctx : Context, acc : Array(Detection)) : Nil
          check_protocols(ctx, acc)
          check_tech_headers(ctx, acc)
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
          acc << tech(ctx, "tech_sse", "Server-Sent Events stream") if Sse.event_stream?(detail.response_head)
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
          return true if ctx.req.target.downcase.includes?("/graphql")
          return false unless req_ct.try(&.downcase.includes?("json"))
          body = ctx.detail.request_body
          return false unless body
          # 8 KB truncated mid-JSON on real GraphQL requests (a sizeable `variables` object),
          # which then fails JSON.parse and mis-classified them as non-GraphQL; allow up to 256 KB.
          text = String.new(body[0, {body.size, 256 * 1024}.min]).scrub
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

        private def tech(ctx : Context, code : String, title : String, evidence : String? = nil) : Detection
          Detection.new(code, Category::TECH, ctx.host, ctx.url, title, Store::Severity::Info, evidence, ctx.fid)
        end
      end
    end
  end
end
