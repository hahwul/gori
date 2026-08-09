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

    # Hard ceiling on a single response body we will buffer. OAST talks to third-party interaction
    # servers whose content the rest of the engine already treats as adversarial (an interactsh-
    # class domain collects unsolicited scanner traffic); a hostile or broken one answering a poll
    # with a multi-gigabyte body would exhaust memory before any per-row cap applies, since TIMEOUT
    # bounds only time, not bytes. A poll response is base64 callback records — real ones are
    # kilobytes — so 16 MiB is orders past legitimate and still safe to hold.
    MAX_BODY = 16 * 1024 * 1024

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
        # Stream the body so an over-cap response is refused as it arrives — the non-streaming
        # `resp.body` would buffer the whole thing into memory first, which is the exhaustion this
        # guards against.
        status = 0
        payload = ""
        client.exec(method.upcase, request_target(uri), headers: hdrs, body: body) do |resp|
          status = resp.status_code
          payload = read_capped(resp.body_io, host)
        end
        Response.new(status, payload)
      ensure
        client.close
      end
    end

    # Read `io` fully into a String, raising once it would exceed MAX_BODY. A clean engine error
    # (the poller / CLI / MCP already surface it as a poll error) beats an out-of-memory kill.
    private def read_capped(io : IO, host : String) : String
      mem = IO::Memory.new
      buf = Bytes.new(64 * 1024)
      total = 0_i64
      loop do
        n = io.read(buf)
        break if n == 0
        total += n
        if total > MAX_BODY
          raise Gori::Error.new("OAST: response body from #{host} exceeded #{MAX_BODY // (1024 * 1024)} MiB — refusing to buffer it")
        end
        mem.write(buf[0, n])
      end
      mem.to_s
    end

    private def request_target(uri : URI) : String
      rt = uri.request_target
      rt.empty? ? "/" : rt
    end
  end
end
