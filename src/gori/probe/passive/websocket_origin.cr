require "socket"
require "../../url"
require "../../proxy/ws/handshake"
require "./rule"

module Gori
  module Probe
    module Passive
      class WebSocketOrigin < Rule
        class_getter origin : Regex { %r{\A(https?)://(\[[0-9a-f:.]+\]|[a-z0-9.-]+)(?::([0-9]{1,5}))?\z}i }
        class_getter key : Regex { %r{\A[A-Za-z0-9+/]{22}==\z} }

        def info : RuleInfo
          RuleInfo.new("websocket_origin", "Cross-site WebSocket handshakes",
            "Reports accepted cross-site WebSocket handshakes that carry cookies.", Category::HEADERS)
        end

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless unmodified_socket?(ctx)
          headers = ctx.req.headers
          # Fetch Metadata supplies the same-site calculation, including public suffixes.
          return unless headers.get_all("Sec-Fetch-Site") == ["cross-site"]
          return unless headers.get_all("Sec-Fetch-Mode") == ["websocket"]
          origins = headers.get_all("Origin")
          return unless origins.size == 1 && origin_differs?(origins.first, ctx)
          return unless headers.get_all("Cookie").any? { |value| cookie_present?(value) }
          return if ctx.row.status == 101 && !accepted_upgrade?(ctx, headers)

          path = Url.origin_path(ctx.row.target).partition('?')[0].partition('#')[0]
          url = Url.request_url(ctx.scheme, ctx.host, path, ctx.row.port)
          acc << Detection.new("ws_cross_site_cookie", Category::HEADERS, ctx.host, url,
            "Cross-site WebSocket handshake accepted with cookies", Store::Severity::Info,
            "Sec-Fetch-Site: cross-site; Cookie header present", ctx.fid)
        end

        private def unmodified_socket?(ctx : Context) : Bool
          ctx.websocket? && !ctx.fid.nil? && !ctx.row.sent_by_gori? &&
            !ctx.row.intercept_edited? && !ctx.row.rewritten?
        end

        private def accepted_upgrade?(ctx : Context, headers : Proxy::Codec::HeaderList) : Bool
          return false unless (response = ctx.raw_response) && response.status == 101 && ctx.req.method == "GET"
          return false unless headers.lists?("Connection", "Upgrade") && response.headers.lists?("Connection", "Upgrade")
          return false unless Proxy::WS::Handshake.upgrades_to_websocket?(response.headers)
          keys = headers.get_all("Sec-WebSocket-Key")
          return false unless keys.size == 1
          key = keys.first
          return false unless key.bytesize == 24 && key.ascii_only? && WebSocketOrigin.key.matches?(key)
          response.headers.get_all("Sec-WebSocket-Accept") == [Proxy::WS::Handshake.accept_value(key)]
        end

        private def origin_differs?(value : String, ctx : Context) : Bool
          return false unless value.ascii_only? && (origin = WebSocketOrigin.origin.match(value))
          return false if (port = origin[3]?) && !(1..65535).includes?(port.to_i)
          # An otherwise identical origin cannot become cross-site by changing only its port.
          host = origin[2]
          if host.starts_with?('[')
            ip = host.lchop('[').rchop(']')
            return false unless Socket::IPAddress.valid_v6?(ip)
            host = Socket::IPAddress.new(ip, 0).address
          end
          host.compare(ctx.host, case_insensitive: true) != 0 ||
            origin[1].compare(ctx.scheme, case_insensitive: true) != 0
        end

        private def cookie_present?(value : String) : Bool
          value.split(';') do |pair|
            name, sep, data = pair.partition('=')
            return true unless name.strip.empty? || sep.empty? || data.strip.empty?
          end
          false
        end
      end
    end
  end
end
