require "openssl"
require "../connect"
require "../head_rewriter"
require "../../interceptor"
require "../conn/client_conn"
require "../upstream"
require "../socket_tuning"
require "../h2/relay"
require "../codec/message"
require "../../host_overrides"
require "../../flow_mapper"
require "./cert_authority"

module Gori::Proxy::Tls
  # The concrete TLS-MITM handoff. After the proxy answered 200 to a CONNECT,
  # `intercept` wraps the client socket as a TLS server using the per-host leaf
  # cert (so the client speaks TLS to us), then runs the normal HTTP/1.1 request
  # loop with the upstream pinned to the CONNECT target over a TLS client
  # connection — so the same codec/capture path serves decrypted traffic.
  class Tunnel < Proxy::TlsMitm
    # Live-mutable so the TUI's settings:network toggle (Session#set_verify_upstream) can
    # flip upstream TLS verification without a restart; read per-CONNECT in `intercept`, so
    # the next tunnelled connection picks up the change.
    property? verify_upstream : Bool

    # Live-mutable too: Session#set_serve_landing flips whether a direct browser hit to the
    # listener gets the gori welcome + CA-download page (vs the 502 self-loop refusal). Read
    # per-request in ClientConn via the TlsMitm seam below, so the next request picks it up.
    property? serve_landing : Bool

    def initialize(@ca : CertAuthority, @verify_upstream : Bool = true,
                   @rewriter : Proxy::HeadRewriter? = nil,
                   @interceptor : Gori::Interceptor? = nil,
                   @host_overrides : Gori::HostOverrides? = nil,
                   @serve_landing : Bool = true)
    end

    # TlsMitm seam: hand the connection loop the root CA (for the self-serve download
    # page) without coupling it to the FFI CertAuthority type.
    def ca_cert_pem : String?
      @ca.ca_cert_pem
    end

    def ca_cert_der : Bytes?
      @ca.ca_cert_der
    end

    def ca_cert_path : String?
      @ca.ca_cert_path
    end

    def ca_spki_sha256 : String?
      @ca.spki_sha256_base64
    end

    def intercept(host : String, port : Int32, client : IO, sink : Proxy::FlowSink) : Nil
      # Don't advertise h2 — forcing the client to HTTP/1.1, the ClientConn path —
      # when the sandbox is on, OR intercept is on for this host, OR Match&Replace rules
      # are live. h2's HPACK-encoded heads never reach the HeadRewriter/interceptor seams
      # (nor ClientConn's sandbox block), so the fast h2 relay would silently skip all of
      # them. Sandbox forces h1 for EVERY MITM'd host so the per-request block always runs;
      # out-of-scope, sandbox-off, intercept-off, rule-less hosts keep the fast h2 relay.
      advertise_h2 = !(@interceptor.try(&.sandbox_enabled?) ||
                       @interceptor.try(&.intercepts_host?(host)) || @rewriter.try(&.active?))
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
          host_overrides: @host_overrides,
        ).run
      end
    rescue
      # Client refused our cert (CA not trusted) or handshake failed: there's
      # nothing decrypted to capture. The outer connection is torn down.
    ensure
      client_tls.try(&.close) rescue nil
    end

    # End-to-end h2: dial the origin offering h2. A tunnel we can't build is
    # recorded as a visible error flow (see record_h2_error) rather than dropped
    # silently — most browsers negotiate h2 by default, so a silent drop here left
    # the user with a blank page and an empty History and no hint of the cause (#323).
    private def intercept_h2(host : String, port : Int32, client_tls : IO, sink : Proxy::FlowSink) : Nil
      upstream = Proxy::Upstream.dial_tls(host, port, verify: @verify_upstream, alpn: "h2", overrides: @host_overrides)
      if upstream.nil?
        # Couldn't reach or TLS-verify the origin — no h2 tunnel to build. The most common
        # cause behind #323: upstream-cert verification failing when the (statically-linked)
        # binary can't resolve a system trust store. The h1 path already surfaces this via
        # ClientConn#record_error; bring h2 to parity instead of dropping the connection.
        record_h2_error(host, port, sink, "upstream connect/TLS-verify failed: #{host}:#{port}")
        return
      end
      unless upstream.alpn_protocol == "h2"
        # Origin won't speak h2; v1 does not translate h2↔h1 (a translated flow would be
        # corrupted, P7). Record WHY rather than dropping silently — an Error flow is an
        # honest projection, not a corrupted one.
        record_h2_error(host, port, sink, "origin did not negotiate HTTP/2 (h2↔h1 not supported): #{host}:#{port}")
        return
      end
      upstream.sync = true
      # Long-lived end-to-end h2 relay: relax both legs so an idle h2 connection isn't reaped
      # (keepalive on both underlying sockets reaps a dead peer). Resolves through the TLS wrap.
      Proxy::SocketTuning.relax(client_tls)
      Proxy::SocketTuning.relax(upstream)
      Proxy::H2::Relay.run(client_tls, upstream, host, port, sink)
    ensure
      upstream.try(&.close) rescue nil
    end

    # Record a VISIBLE error flow for an h2 tunnel we could not establish, mirroring the
    # h1 path's ClientConn#record_error. `head` is a synthesized marker: the real h2 request
    # frames were never relayed or decoded (the failure is before the relay), so there is no
    # wire request to capture — the raw-frame log stays the truth for real h2 flows (P7).
    # Best-effort: a store error here must not take down the tunnel teardown.
    private def record_h2_error(host : String, port : Int32, sink : Proxy::FlowSink, message : String) : Nil
      created_at = (Time.utc - Time::UNIX_EPOCH).total_microseconds.to_i64
      head = "GET / HTTP/2\r\nHost: #{host}\r\n\r\n".to_slice
      req = Proxy::Codec::RawRequest.new(head, "GET", "/", "HTTP/2",
        Proxy::Codec::HeaderList.new([Proxy::Codec::Header.new("Host", host)]))
      flow_id = sink.on_request(FlowMapper.request(req,
        scheme: "https", host: host, port: port, created_at: created_at, alpn: "h2"))
      sink.on_response(FlowMapper.error_response(flow_id, message))
    rescue
      # never let error-recording take down the tunnel teardown path
    end
  end
end
