require "openssl"
require "../connect"
require "../head_rewriter"
require "../../interceptor"
require "../conn/client_conn"
require "../upstream"
require "../socket_tuning"
require "../h2/relay"
require "../../host_overrides"
require "./cert_authority"
require "./client_hello"

module Gori::Proxy::Tls
  # The concrete TLS-MITM handoff. After the proxy answered 200 to a CONNECT,
  # `intercept` wraps the client socket as a TLS server using the per-host leaf
  # cert (so the client speaks TLS to us), then runs the normal HTTP/1.1 request
  # loop with the upstream pinned to the CONNECT target over a TLS client
  # connection — so the same codec/capture path serves decrypted traffic.
  class Tunnel < Proxy::TlsMitm
    # Connect timeout for the ALPN-reflection probe (see reflect_origin_h2). Capped well below
    # the full connect timeout: the probe only CLASSIFIES the origin's ALPN, and an unreachable
    # origin would otherwise burn the full timeout here AND again when the h1 fallback re-dials
    # — doubling the wait a browser sees before its 502. 5s is generous for any reachable
    # origin's TCP connect; a slower one simply reflects h1 (loads over h1, just not the relay).
    H2_PROBE_CONNECT_TIMEOUT = 5.seconds

    # Cap on the negative ALPN cache (see @h1_only_origins) so a proxy left running against many
    # distinct h1-only hosts can't grow it without bound. A pentest run touches at most dozens
    # to hundreds of hosts, so the common origins are all cached long before this.
    H1_ONLY_CACHE_MAX = 4096

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
      # Origins that definitively negotiated HTTP/1.1 (not h2) on a prior probe — a repeat
      # CONNECT skips the throwaway ALPN-reflection probe for these. See reflect_origin_h2.
      # Bare Set, no mutex: single-threaded fibers, and the read/add don't yield (the yielding
      # dial happens before the add), so a concurrent double-probe just re-adds idempotently.
      @h1_only_origins = Set({String, Int32}).new
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

    # `https://gori.proxy/` — a CONNECT to a reserved host, answered entirely locally.
    # Deliberately NOT `intercept`: there is no origin here, so no ALPN-reflection probe
    # (which would burn H2_PROBE_CONNECT_TIMEOUT dialing a name that cannot resolve), no
    # upstream, no ClientConn, and nothing captured. advertise_h2: false keeps the client on
    # HTTP/1.1 so the one-shot serve below is the whole protocol.
    #
    # The handshake FAILING is the expected common path: the client is here precisely
    # because it does not trust this CA yet. Rescued and closed like `intercept`.
    def intercept_self_page(host : String, client : IO, listen : {String, Int32}) : Nil
      server_ctx = @ca.context_for(host, advertise_h2: false)
      # sync_close: true for a different reason than in `intercept` (no relay, so no
      # cross-fiber close race): it keeps shutdown write-only instead of blocking on a
      # close_notify from a browser that hit "back" at the certificate warning.
      client_tls = OpenSSL::SSL::Socket::Server.new(client, server_ctx, sync_close: true, accept: true)
      client_tls.sync = true
      serve_self_page_once(client_tls, listen)
    rescue
      # Client refused our cert (the untrusted-CA warning) — nothing to serve.
    ensure
      client_tls.try(&.close) rescue nil
    end

    def intercept(host : String, port : Int32, client : IO, sink : Proxy::FlowSink,
                  tls_upstream : Bool = true) : Nil
      # ALPN reflection (#323): advertise h2 to the client only when the ORIGIN speaks it. A
      # non-nil result is a live upstream already confirmed h2 (reflect_origin_h2 dials it and
      # keeps it for reuse); nil means fall the client back to the h1 path. See that helper.
      #
      # Skipped entirely for a CLEARTEXT origin: reflection is an ALPN probe, and ALPN only
      # exists inside a TLS handshake. gori has no h2c support to reflect instead, so the
      # client is kept on h1 — which is what the nil path already means.
      upstream = tls_upstream ? reflect_origin_h2(host, port) : nil

      server_ctx = @ca.context_for(host, advertise_h2: !upstream.nil?)
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

      # ALPN routing: if the client negotiated h2 with us, run the h2 relay (end-to-end h2,
      # raw-frame capture) over the upstream we already confirmed speaks h2; otherwise the
      # normal h1 path. A non-nil `upstream` is guaranteed whenever the client could have picked
      # h2 (we only advertised h2 in that case).
      if client_tls.alpn_protocol == "h2" && (up = upstream)
        upstream = nil # ownership transfers to relay_h2 (its ensure closes it)
        relay_h2(host, port, client_tls, up, sink)
      else
        upstream.try(&.close) rescue nil # client took h1: an h2 probe socket can't serve it
        upstream = nil
        # NOTE: no `tls:`, no `self_addr:`, no `local_host:` — deliberately. Those three are
        # what arm the self-page / self-loop guards in ClientConn, and inside a tunnel every
        # request resolves to the pinned CONNECT authority (resolve_forward short-circuits on
        # @fixed_host), so arming them here would test the wrong host on every request.
        Proxy::ClientConn.new(
          client_tls, tls_upstream ? "https" : "http", sink,
          fixed_host: host, fixed_port: port,
          tls_upstream: tls_upstream, verify_upstream: @verify_upstream,
          rewriter: @rewriter, interceptor: @interceptor,
          host_overrides: @host_overrides,
        ).run
      end
    rescue
      # Client refused our cert (CA not trusted) or handshake failed: there's
      # nothing decrypted to capture. The outer connection is torn down.
    ensure
      upstream.try(&.close) rescue nil # a probe orphaned by a failed client handshake
      client_tls.try(&.close) rescue nil
    end

    # ALPN reflection probe (#323). When this host is an h2 candidate, pre-dial the origin
    # offering h2 BEFORE the client handshake and return the socket ONLY if the origin
    # negotiated h2 — the caller then advertises h2 to the client and hands this same socket to
    # the relay (reused, not re-dialed), so the common browser→h2-origin path adds no extra
    # origin connection: the dial just moves ahead of the client handshake. Returns nil for a
    # non-candidate, an h1-only origin, or an unreachable origin — v1 has no h2↔h1 translation,
    # so advertising h2 for any of those stranded the client on a dead h2 tunnel (a blank page,
    # empty History). Nil falls the client back to the h1 ClientConn path, which loads normally
    # and records its own upstream errors. The cost: an h1-only origin, or a client that
    # declines h2 (e.g. curl), spends one throwaway probe connection, closed here — but a repeat
    # visit to a KNOWN h1-only origin skips the probe entirely (see @h1_only_origins). This
    # caching does NOT help the non-h2-client → h2-origin case (a curl to an h2 target still
    # probes every connection: the probe negotiates h2, the client then takes h1, and the h2
    # probe can't serve it) — a positive "this host is h2" cache WOULD, but a stale positive
    # entry (origin since dropped to h1/down) would re-strand the client on a dead h2 tunnel,
    # the exact #323 failure, so only the benign negative direction is cached.
    private def reflect_origin_h2(host : String, port : Int32) : OpenSSL::SSL::Socket::Client?
      return nil unless h2_candidate?
      return nil if @h1_only_origins.includes?({host, port}) # known h1-only: skip the probe
      # Cap the connect wait so an unreachable origin doesn't burn the full timeout here before
      # the h1 fallback re-dials and waits again (never longer than the configured timeout).
      timeout = {Gori::Settings.connect_timeout, H2_PROBE_CONNECT_TIMEOUT}.min
      upstream = Proxy::Upstream.dial_tls(host, port, verify: @verify_upstream, alpn: "h2",
        connect_timeout: timeout, overrides: @host_overrides)
      return upstream if upstream && upstream.alpn_protocol == "h2"
      # Remember a DEFINITIVE h1 negotiation (handshake completed, ALPN != h2) so repeat visits
      # skip the probe. Never cache a nil dial — that's a transient reach/verify failure, not a
      # statement about the origin's ALPN; caching it would wrongly pin a briefly-down origin.
      @h1_only_origins << {host, port} if upstream && @h1_only_origins.size < H1_ONLY_CACHE_MAX
      upstream.try(&.close) rescue nil
      nil
    end

    # Whether this host may take the fast h2 relay at all. FALSE — forcing HTTP/1.1, the
    # ClientConn path — when HTTP/2 is switched off, the sandbox is on, OR a Match&Replace BODY
    # rule is live: those seams are not reachable from the h2 relay, so it would silently skip
    # them. Sandbox-off hosts with no body rule are candidates (subject to the origin actually
    # speaking h2 — see reflect_origin_h2).
    #
    # The rewriter gate used to be `active?`, and #492 step 2 narrowed it rather than removing
    # it. HEAD rules now reach h2 (`H2::HeadRewrite`), which is the whole point of that step —
    # a single Match&Replace rule no longer kills every gRPC client on the host by forcing a
    # downgrade the client cannot take (`conn/client_conn.cr:158`). But `Rules#active?` is
    # true for a BODY-only rule set too (`rules.cr:48-50` counts any enabled rule regardless of
    # part), and a body rule works today PRECISELY because this gate downgrades: the h1 path is
    # where `rewrites_request_body?`/`rewrites_response_body?` and the buffered-body rewrite
    # live. Dropping the gate outright would have regressed body rules from working to silently
    # not working — the exact failure this epic exists to remove. Body rewriting on h2 is #492
    # step 5; until then a body rule still earns the downgrade, and only that.
    #
    # The INTERCEPT gate came out in #492 step 3, which made the hold reachable per stream
    # (`H2::StreamGate`). Checked the same way step 2 checked the rewriter, since the lesson
    # there was that the obvious predicate protected more than it looked like: `intercepts_host?`
    # is not consulted by `intercepts_request?`/`intercepts_response?` (`interceptor.cr:204-222`
    # take their own snapshot), and `sandbox_enabled?` is a separate term on the same object, so
    # removing it weakens no gate — it removes a downgrade. What it DOES change is that a held
    # h2 message is the head only: the body is not shown and not editable, because DATA streams
    # past untouched until step 5. Unlike step 2 there is no narrower predicate that saves it —
    # nothing can know before the request exists whether the operator will want to edit a body —
    # so it is stated in `docs/content/guide/proxy.md` instead of being fixed.
    #
    # `http2_disabled?` is one MORE reason to downgrade, deliberately not a way to override the
    # others: those two are correctness requirements, not preferences, so no setting may turn
    # them off. Placing the check here also means "off" skips the origin ALPN probe entirely —
    # reflect_origin_h2 consults this before dialing.
    private def h2_candidate? : Bool
      !(Gori::Settings.http2_disabled? ||
        @interceptor.try(&.sandbox_enabled?) ||
        @rewriter.try { |rw| rw.rewrites_request_body? || rw.rewrites_response_body? })
    end

    # End-to-end h2 relay over an upstream ALREADY dialed (and confirmed h2) by `intercept`.
    # Reusing that socket is what keeps the common browser→h2-origin path at a single origin
    # connection. Owns `upstream` — closes it on teardown.
    private def relay_h2(host : String, port : Int32, client_tls : IO,
                         upstream : OpenSSL::SSL::Socket::Client, sink : Proxy::FlowSink) : Nil
      upstream.sync = true
      # Long-lived end-to-end h2 relay: relax both legs so an idle h2 connection isn't reaped
      # (keepalive on both underlying sockets reaps a dead peer). Resolves through the TLS wrap.
      Proxy::SocketTuning.relax(client_tls)
      Proxy::SocketTuning.relax(upstream)
      Proxy::H2::Relay.run(client_tls, upstream, host, port, sink, @rewriter, @interceptor)
    ensure
      upstream.close rescue nil
    end
  end
end
