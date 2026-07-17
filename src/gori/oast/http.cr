require "http/client"
require "uri"

module Gori::Oast
  # The outbound-HTTP seam every provider talks through. Abstracting it lets specs drive
  # register/poll with a scripted fake (no sockets) while production dials real servers.
  # OAST talks to THIRD-PARTY interaction servers directly (not through gori's proxy /
  # host-override machinery) — same stance as the self-updater.
  abstract class Http
    record Response, status : Int32, body : String

    abstract def request(method : String, url : String,
                         headers : Hash(String, String) = {} of String => String,
                         body : String? = nil) : Response
  end

  # Production client over stdlib HTTP::Client (template: Gori::Update#fetch_latest_release_json).
  # A fresh client per call, keyed on the URL's own origin — the poll cadence is seconds,
  # not a hot path, and each provider may hit a different host.
  class HttpClient < Http
    TIMEOUT = 20.seconds

    def initialize(@verify_tls : Bool = true)
    end

    def request(method : String, url : String,
                headers : Hash(String, String) = {} of String => String,
                body : String? = nil) : Response
      uri = URI.parse(url)
      host = uri.host
      raise Gori::Error.new("OAST: invalid URL #{url}") unless host
      tls = uri.scheme == "https"
      port = uri.port || (tls ? 443 : 80)

      client = HTTP::Client.new(host, port, tls)
      client.connect_timeout = TIMEOUT
      client.read_timeout = TIMEOUT
      # A public interactsh/webhook host we don't (and can't) pin; the callback content is
      # decrypted/verified out of band, so an unverified transport is acceptable here.
      client.tls.try(&.verify_mode = OpenSSL::SSL::VerifyMode::NONE) unless @verify_tls

      hdrs = HTTP::Headers.new
      headers.each { |k, v| hdrs[k] = v }
      begin
        resp = client.exec(method.upcase, request_target(uri), headers: hdrs, body: body)
        Response.new(resp.status_code, resp.body)
      ensure
        client.close
      end
    end

    private def request_target(uri : URI) : String
      rt = uri.request_target
      rt.empty? ? "/" : rt
    end
  end
end
