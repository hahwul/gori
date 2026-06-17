require "./key_pair"

module Gori::Proxy::Tls
  # Builds a stdlib SSL server context with an in-memory leaf cert/key injected
  # via FFI (no temp files, validated in SPIKE 1). We advertise ALPN "h2": the
  # stdlib select callback picks h2 when the client offers it and otherwise
  # returns NOACK, so non-h2 clients transparently fall back to HTTP/1.1. The
  # negotiated protocol (`socket.alpn_protocol`) routes the connection to the h2
  # relay or the h1 ClientConn.
  module ContextFactory
    def self.server_context(cert : Cert, key : KeyPair, advertise_h2 : Bool = true) : OpenSSL::SSL::Context::Server
      ctx = OpenSSL::SSL::Context::Server.new
      if LibSSL.ssl_ctx_use_certificate(ctx.to_unsafe, cert.handle) != 1
        raise Gori::Error.new("SSL_CTX_use_certificate failed")
      end
      if LibSSL.ssl_ctx_use_privatekey(ctx.to_unsafe, key.handle) != 1
        raise Gori::Error.new("SSL_CTX_use_PrivateKey failed")
      end
      # Advertise h2 only when allowed; when unset the stdlib select callback
      # NOACKs and the client falls back to HTTP/1.1 (the interceptable path).
      ctx.alpn_protocol = "h2" if advertise_h2
      ctx
    end
  end
end
