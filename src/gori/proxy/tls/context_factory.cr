require "./key_pair"

module Gori::Proxy::Tls
  # Builds a stdlib SSL server context with an in-memory leaf cert/key injected
  # via FFI (no temp files, validated in SPIKE 1). We advertise ALPN "h2": the
  # stdlib select callback picks h2 when the client offers it and otherwise
  # returns NOACK, so non-h2 clients transparently fall back to HTTP/1.1. The
  # negotiated protocol (`socket.alpn_protocol`) routes the connection to the h2
  # relay or the h1 ClientConn.
  module ContextFactory
    def self.server_context(cert : Cert, key : KeyPair, ca_cert : Cert? = nil,
                            advertise_h2 : Bool = true) : OpenSSL::SSL::Context::Server
      ctx = lean_server
      if LibSSL.ssl_ctx_use_certificate(ctx.to_unsafe, cert.handle) != 1
        raise Gori::Error.new("SSL_CTX_use_certificate failed")
      end
      if LibSSL.ssl_ctx_use_privatekey(ctx.to_unsafe, key.handle) != 1
        raise Gori::Error.new("SSL_CTX_use_PrivateKey failed")
      end
      add_chain_cert(ctx, ca_cert) if ca_cert
      # Advertise h2 only when allowed; when unset the stdlib select callback
      # NOACKs and the client falls back to HTTP/1.1 (the interceptable path).
      ctx.alpn_protocol = "h2" if advertise_h2
      ctx
    end

    # `OpenSSL::SSL::Context::Server.new` minus its `set_default_verify_paths`. That call loads
    # the system CA bundle into the context's X509 store, which a server context only consults
    # to verify a CLIENT certificate — and no gori server context asks for one (none sets
    # `verify_mode`). Per leaf it cost ~3 ms of parsing on the scheduler thread and ~1.1 MB of
    # RSS, times every cached leaf (measured at 58-61% of busy time under many distinct
    # HTTPS hosts). Everything else `Server.new` sets is re-applied here, from the Crystal 1.21
    # stdlib (`openssl/ssl/context.cr`); spec/proxy/tls/context_factory_spec.cr compares the
    # result against a stdlib context so a stdlib change shows up as a failing spec.
    def self.lean_server : OpenSSL::SSL::Context::Server
      ctx = OpenSSL::SSL::Context::Server.insecure
      ctx.add_options(OpenSSL::SSL::Options.flags(
        ALL,
        NO_TLS_V1,
        NO_TLS_V1_1,
        NO_SESSION_RESUMPTION_ON_RENEGOTIATION,
        NO_RENEGOTIATION,
      ))
      {% if OpenSSL.has_constant?(:KTLS) %}
        ctx.remove_options(OpenSSL::SSL::Options::ENABLE_KTLS)
      {% end %}
      ctx.add_modes(OpenSSL::SSL::Modes.flags(AUTO_RETRY, RELEASE_BUFFERS))
      ctx.default_verify_param = "ssl_client"
      ctx
    end

    # Append the root CA to the served chain so the leaf arrives as [leaf, root].
    # Harmless for clients that already trust the root; required so a browser
    # opened with `--ignore-certificate-errors-spki-list=<root SPKI>` sees the
    # pinned key in the presented chain (the flag only inspects served certs).
    #
    # SSL_CTX_add_extra_chain_cert takes ownership of one X509 reference (freed on
    # ctx free), so up-ref first — the CA cert is shared across every cached
    # context and must outlive them all.
    private def self.add_chain_cert(ctx : OpenSSL::SSL::Context::Server, ca_cert : Cert) : Nil
      LibCrypto.x509_up_ref(ca_cert.handle)
      ok = LibSSL.ssl_ctx_ctrl(ctx.to_unsafe, SSL_CTRL_EXTRA_CHAIN_CERT, 0_u64, ca_cert.handle.as(Void*))
      if ok != 1
        LibCrypto.x509_free(ca_cert.handle) # undo the up-ref; ownership wasn't taken
        raise Gori::Error.new("SSL_CTX_add_extra_chain_cert failed")
      end
    end
  end
end
