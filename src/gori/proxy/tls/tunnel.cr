require "openssl"
require "../connect"
require "../head_rewriter"
require "../../interceptor"
require "../conn/client_conn"
require "../upstream"
require "../h2/relay"
require "./cert_authority"

module Gori::Proxy::Tls
  # The concrete TLS-MITM handoff. After the proxy answered 200 to a CONNECT,
  # `intercept` wraps the client socket as a TLS server using the per-host leaf
  # cert (so the client speaks TLS to us), then runs the normal HTTP/1.1 request
  # loop with the upstream pinned to the CONNECT target over a TLS client
  # connection — so the same codec/capture path serves decrypted traffic.
  class Tunnel < Proxy::TlsMitm
    def initialize(@ca : CertAuthority, @verify_upstream : Bool = true,
                   @rewriter : Proxy::HeadRewriter? = nil,
                   @interceptor : Gori::Interceptor? = nil)
    end

    def intercept(host : String, port : Int32, client : IO, sink : Proxy::FlowSink) : Nil
      # When intercept is on for THIS host, don't advertise h2 — the client falls
      # back to HTTP/1.1, taking the interceptable ClientConn path. Out-of-scope
      # (and intercept-off) hosts keep the fast h2 relay.
      advertise_h2 = !(@interceptor.try(&.intercepts_host?(host)))
      server_ctx = @ca.context_for(host, advertise_h2: advertise_h2)
      # sync_close: true is REQUIRED, not cosmetic. The h2/ws relays tear down by
      # closing the socket the *other* pump fiber is mid-read on, to unblock it.
      # With sync_close: false, OpenSSL::SSL::Socket#close does a *bidirectional*
      # SSL_shutdown that READS the peer's close_notify — that read races the other
      # fiber's SSL_read on the same SSL object and corrupts OpenSSL's read buffer
      # (SIGSEGV in tls_get_more_records, seen under a browser's many h2 conns).
      # sync_close: true makes shutdown write-only (it stops at the first 0 return)
      # and closes the underlying transport, which unblocks the peer with no racing
      # read. `client` (a PrefixIO over the raw socket) is then closed here; the
      # ClientConn/​server close paths are all `rescue`-guarded, so the double close
      # is a safe no-op.
      client_tls = OpenSSL::SSL::Socket::Server.new(client, server_ctx, sync_close: true, accept: true)
      client_tls.sync = true

      # ALPN routing: if the client negotiated h2 with us, run the h2 relay
      # (end-to-end h2, raw-frame capture); otherwise the normal h1 path.
      if client_tls.alpn_protocol == "h2"
        intercept_h2(host, port, client_tls, sink)
      else
        Proxy::ClientConn.new(
          client_tls, "https", sink,
          fixed_host: host, fixed_port: port,
          tls_upstream: true, verify_upstream: @verify_upstream,
          rewriter: @rewriter, interceptor: @interceptor,
        ).run
      end
    rescue
      # Client refused our cert (CA not trusted) or handshake failed: there's
      # nothing decrypted to capture. The outer connection is torn down.
    ensure
      client_tls.try(&.close) rescue nil
    end

    # End-to-end h2: dial the origin offering h2. If the origin won't speak h2,
    # v1 does not translate h2↔h1 — the connection is dropped (the human sees no
    # flow rather than a corrupted one, P7).
    private def intercept_h2(host : String, port : Int32, client_tls : IO, sink : Proxy::FlowSink) : Nil
      upstream = Proxy::Upstream.dial_tls(host, port, verify: @verify_upstream, alpn: "h2")
      if upstream && upstream.alpn_protocol == "h2"
        upstream.sync = true
        Proxy::H2::Relay.run(client_tls, upstream, host, port, sink)
      end
    ensure
      upstream.try(&.close) rescue nil
    end
  end
end
