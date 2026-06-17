require "socket"
require "openssl"

module Gori::Proxy
  # Dials origin servers and parses authorities. Plaintext only this step; the
  # TLS-upstream variant is added with the MITM layer (Step 6). We open one
  # upstream per flow and close it after the response (no pooling — correctness
  # first; pooling is a deferred optimization).
  module Upstream
    CONNECT_TIMEOUT = 30.seconds
    IO_TIMEOUT      = 30.seconds

    def self.dial(host : String, port : Int32) : TCPSocket?
      sock = TCPSocket.new(host, port, connect_timeout: CONNECT_TIMEOUT)
      sock.sync = true # flush writes immediately (P6)
      sock.tcp_nodelay = true
      sock.read_timeout = IO_TIMEOUT
      sock.write_timeout = IO_TIMEOUT
      sock
    rescue
      nil
    end

    # Dials and wraps an origin in TLS (post-CONNECT MITM upstream). `host` is
    # used for SNI and (when verifying) hostname validation. `verify: false`
    # lets the proxy reach origins with self-signed/broken certs (pentest use).
    # `alpn` offers an ALPN protocol (e.g. "h2"); nil leaves it unset so the
    # origin answers HTTP/1.1. The caller checks `ssl.alpn_protocol` for what was
    # actually negotiated.
    def self.dial_tls(host : String, port : Int32, verify : Bool, alpn : String? = nil) : OpenSSL::SSL::Socket::Client?
      tcp = dial(host, port)
      return nil unless tcp
      ctx = OpenSSL::SSL::Context::Client.new
      ctx.verify_mode = OpenSSL::SSL::VerifyMode::NONE unless verify
      ctx.alpn_protocol = alpn if alpn
      ssl = OpenSSL::SSL::Socket::Client.new(tcp, context: ctx, sync_close: true, hostname: host)
      ssl.sync = true
      ssl
    rescue
      nil
    end

    # Splits an "host:port" / "host" authority. Falls back to default_port.
    # IPv6 literals without brackets are treated as a bare host (skeleton; a
    # bracketed-IPv6 parser is a later refinement).
    def self.split_host_port(authority : String, default_port : Int32) : {String, Int32}
      idx = authority.rindex(':')
      return {authority, default_port} unless idx
      host = authority[0...idx]
      return {authority, default_port} if host.includes?(':') # unbracketed IPv6
      port = authority[(idx + 1)..].to_i? || default_port
      {host, port}
    end
  end
end
