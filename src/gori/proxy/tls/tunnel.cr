require "openssl"
require "../connect"
require "../head_rewriter"
require "../extractor"
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

    # Cap on the once-per-host h2→h1 downgrade notice (see notice_downgrade). Same number and
    # same reason as `Settings::PASSTHROUGH_NOTICE_MAX`: a bound on unbounded operator-controlled
    # input, without a log line per reconnect from a chatty client.
    DOWNGRADE_NOTICE_MAX = 1024

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
                   @serve_landing : Bool = true,
                   @extractor : Proxy::ResponseExtract? = nil)
      # Origins that definitively negotiated HTTP/1.1 (not h2) on a prior probe — a repeat
      # CONNECT skips the throwaway ALPN-reflection probe for these. See reflect_origin_h2.
      # Bare Set, no mutex: single-threaded fibers, and the read/add don't yield (the yielding
      # dial happens before the add), so a concurrent double-probe just re-adds idempotently.
      @h1_only_origins = Set({String, Int32, String?}).new
      # {host, reason} pairs already announced by notice_downgrade. Same no-mutex argument as
      # above: the read and the add happen together with no yield between them.
      @downgrade_noticed = Set({String, String}).new
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

    # `dial_addr` is the seam #529 needed: `host` names the connection, `dial_addr` reaches it.
    # Everything in here that identifies the connection — the leaf `@ca.context_for` mints, the
    # `h2_candidate?`/`notice_downgrade` host, the `@h1_only_origins` key, the relay's scope
    # authority, the `ClientConn` `fixed_host` and so the whole capture record — keeps using
    # `host`. Only the two dials (the ALPN probe here, and `ClientConn#open_upstream` below)
    # take the pin, and each does so through `Upstream.connect_target`, which is the one place
    # that decides "given this name, which address". nil means resolve the name, i.e. every
    # pre-#529 caller is unchanged.
    def intercept(host : String, port : Int32, client : IO, sink : Proxy::FlowSink,
                  tls_upstream : Bool = true, dial_addr : String? = nil) : Nil
      # ALPN reflection (#323): advertise h2 to the client only when the ORIGIN speaks it. A
      # non-nil result is a live upstream already confirmed h2 (reflect_origin_h2 dials it and
      # keeps it for reuse); nil means fall the client back to the h1 path. See that helper.
      #
      # Skipped entirely for a CLEARTEXT origin: reflection is an ALPN probe, and ALPN only
      # exists inside a TLS handshake. gori has no h2c support to reflect instead, so the
      # client is kept on h1 — which is what the nil path already means.
      upstream = tls_upstream ? reflect_origin_h2(host, port, dial_addr) : nil

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
          host_overrides: @host_overrides, extractor: @extractor,
          # The name/port halves of `origin_dst` are inert here — `resolve_forward`
          # short-circuits on `fixed_host` before either is consulted — so what this actually
          # hands over is the DIAL PIN, which `ClientConn#dial_pin` reads back off it.
          origin_dst: dial_addr.try { |a| {a, port} },
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
    #
    # `dial_addr` pins where the probe connects (#529) without touching what it asks for: the
    # SNI and the verified name stay `host`, so a reflected "this origin speaks h2" is still a
    # statement about the name. It IS part of the cache key, though, because the observation is
    # about the machine that answered: the same name reached at two different pinned addresses
    # is two origins, and sharing one entry between them would deny h2 to the second on
    # evidence gathered from the first.
    private def reflect_origin_h2(host : String, port : Int32,
                                  dial_addr : String? = nil) : OpenSSL::SSL::Socket::Client?
      return nil unless h2_candidate?(host)
      return nil if @h1_only_origins.includes?({host, port, dial_addr}) # known h1-only: skip the probe
      # Cap the connect wait so an unreachable origin doesn't burn the full timeout here before
      # the h1 fallback re-dials and waits again (never longer than the configured timeout).
      timeout = {Gori::Settings.connect_timeout, H2_PROBE_CONNECT_TIMEOUT}.min
      upstream = Proxy::Upstream.dial_tls(host, port, verify: @verify_upstream, alpn: "h2",
        connect_timeout: timeout, overrides: @host_overrides, pin: dial_addr)
      return upstream if upstream && upstream.alpn_protocol == "h2"
      # Remember a DEFINITIVE h1 negotiation (handshake completed, ALPN != h2) so repeat visits
      # skip the probe. Never cache a nil dial — that's a transient reach/verify failure, not a
      # statement about the origin's ALPN; caching it would wrongly pin a briefly-down origin.
      @h1_only_origins << {host, port, dial_addr} if upstream && @h1_only_origins.size < H1_ONLY_CACHE_MAX
      upstream.try(&.close) rescue nil
      nil
    end

    # Whether this host may take the fast h2 relay at all. FALSE — forcing HTTP/1.1, the
    # ClientConn path — when HTTP/2 is switched off, or a Match&Replace BODY or SHORT-CIRCUIT
    # rule is live FOR THIS HOST, or a session-binding extract rule reads the response BODY for
    # it. Anything else is a candidate, subject to the origin actually speaking h2 (see
    # reflect_origin_h2). Placing the check here also means a downgrade skips the origin ALPN
    # probe entirely: reflect_origin_h2 consults this before dialing.
    #
    # A downgrade is never free, which is why what remains is only what is still REQUIRED.
    # An h2-only client — every gRPC client — cannot take it: a modern grpc-go dies at ALPN
    # enforcement ("missing selected ALPN property") because we no longer offer h2, and an older
    # or hand-rolled one gets one step further and has its preface refused
    # (`conn/client_conn.cr`). So each remaining term is announced once per host (see
    # notice_downgrade); before #492 step 4 this file logged nothing at all.
    #
    # ## What came out, and what each removal had to prove
    #
    # The rewriter gate used to be `active?`, and #492 step 2 NARROWED it rather than removing
    # it: HEAD rules reach h2 now (`H2::HeadRewrite`), but `Rules#active?` is true for a
    # BODY-only rule set too (`rules.cr:48-50` counts any enabled rule regardless of part), and
    # a body rule works today PRECISELY because this gate downgrades — the h1 path is where the
    # buffered-body rewrite lives. Dropping it outright would have regressed body rules from
    # working to silently not working. Body rewriting on h2 is #492 step 5; until then a body
    # rule still earns the downgrade, and only that.
    #
    # The INTERCEPT gate came out in step 3, which made the hold reachable per stream
    # (`H2::StreamGate`). `intercepts_host?` is not consulted by
    # `intercepts_request?`/`intercepts_response?` (`interceptor.cr` — they take their own
    # snapshot), so removing it weakened no gate. What it DID change is that a held h2 message
    # is the head only, because DATA streams past untouched until step 5.
    #
    # The SANDBOX gate came out in step 4, and it is the one removal that had to answer a
    # different question, because the sandbox is not a seam: an unreachable seam silently does
    # nothing, an unreachable BLOCKING gate lets traffic through. It was reachable only through
    # this downgrade — `ClientConn#handle_request`'s per-request `sandbox_blocks?` — and the
    # relay had no per-request URL check at all. The pre-handshake host gate is no substitute
    # and never was: `sandbox_blocks_host?` deliberately passes a host that MIGHT be in scope,
    # and with any url-level include in the scope that is EVERY host (`host_allowlisted_unlocked?`
    # treats one url rule as "the path might match here"), so path-scoped rules did their whole
    # job per request. Removing the term without replacing it would have made a scope of
    # `https://acme.test/api/*` forward `/admin` to the origin unexamined. It is replaced by a
    # per-stream refusal in `H2::StreamGate` — which also covers something h1 never had to face,
    # a coalesced stream whose `:authority` is not the CONNECT host (§9.1.1).
    #
    # ## What #526 narrowed, and what that costs
    #
    # Both remaining rewriter terms were HOST-BLIND: they read a global atomic count, so ONE
    # rule scoped to `alpha.test` downgraded every h2 host on the proxy, including hosts its
    # own glob can never match. That is the same shape step 2 fixed for head rules — a gate
    # true for something it is not protecting — and it took the same remedy: narrow, don't
    # remove. `rewrites_body_for_host?` / `short_circuits_for_host?` (`rules.cr`) keep the
    # atomic counts as a lock-free fast path and then ask the host glob. An UNSCOPED rule
    # matches every host and still downgrades everything, exactly as before.
    #
    # The cost is a stream whose `:authority` is NOT the CONNECT host (§9.1.1 coalescing):
    # such a stream can now carry a rule this per-connection gate never saw, where the blanket
    # downgrade caught it. gori's leaf certs carry a SAN of exactly the requested host
    # (`cert_builder.cr`), so a conformant client cannot coalesce onto one and the case needs a
    # hand-rolled peer — but it is not impossible, so it is not left silent: `H2::HeadRewrite`
    # already computes the per-stream authority for rule scoping and logs once per connection
    # when a stream's authority differs from this host AND a body/stub rule matches it.
    private def h2_candidate?(host : String) : Bool
      if Gori::Settings.http2_disabled?
        notice_downgrade(host, "HTTP/2 is switched off (settings network.http2; set it back to " \
                               "\"auto\" to keep h2)")
        return false
      end
      if @rewriter.try(&.rewrites_body_for_host?(host))
        notice_downgrade(host, "a Match&Replace BODY rule is live and body rewriting on HTTP/2 " \
                               "is not implemented yet (disable the body rule to keep h2)")
        return false
      end
      # A SHORT-CIRCUIT rule (#511) earns the downgrade for the same reason a body rule does:
      # `HeadRewriter#short_circuit` is consulted in `ClientConn#handle_request`, and the h2
      # relay never asks. Unlike the sandbox this IS a seam, so an unreachable one lets traffic
      # through rather than blocking it — but that is precisely the failure, because the rule's
      # whole purpose is that the request must NOT reach the origin. Left ungated, an operator
      # who stubbed an endpoint would watch an h2 host send the request anyway, with nothing
      # anywhere saying why.
      if @rewriter.try(&.short_circuits_for_host?(host))
        notice_downgrade(host, "a Match&Replace short-circuit rule is live and the h2 relay " \
                               "cannot answer a request locally (disable the stub rule to keep h2)")
        return false
      end
      # A BODY-scoped session-binding extract rule (#501 slice 2) earns the downgrade for
      # exactly the reason a body rewrite rule does: it needs the response ENTITY, and DATA
      # frames stream past this relay untouched. Head-scoped extraction (cookie / header) does
      # NOT appear here — it reads the response head, which `H2::Extract` reaches on the relay,
      # so a `$SESSION` bound off a `Set-Cookie` costs an h2 host nothing.
      #
      # Host-scoped, per #526 and #531: the gate costs a host its protocol, so it must be asked
      # about THIS host. A rule scoped to `alpha.test` downgrading `127.0.0.1` is the regression
      # #531 fixed, and re-introducing it through a second gate would be the same bug wearing a
      # different rule table.
      if @extractor.try(&.extracts_body_for_host?(host))
        notice_downgrade(host, "a session-binding extract rule reads the response BODY and body " \
                               "extraction on HTTP/2 is not implemented yet (a cookie / header " \
                               "descriptor works on h2 and costs nothing)")
        return false
      end
      true
    end

    # One gori.log line per host per reason, the discipline `Settings::PASSTHROUGH_NOTICE_MAX`
    # set for the other invisible-by-default decision this proxy makes. Keyed on the reason as
    # well as the host so a host that downgrades for a second reason is not silenced by the
    # first. Per Tunnel instance, i.e. per proxy listener.
    private def notice_downgrade(host : String, reason : String) : Nil
      key = {host, reason}
      return if @downgrade_noticed.includes?(key) || @downgrade_noticed.size >= DOWNGRADE_NOTICE_MAX
      @downgrade_noticed << key
      ::Log.info { "h2 downgrade: #{host} forced to HTTP/1.1 because #{reason}. An HTTP/2-only client (any gRPC client) cannot connect to this host while it applies." }
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
      Proxy::H2::Relay.run(client_tls, upstream, host, port, sink, @rewriter, @interceptor, @extractor)
    ensure
      upstream.close rescue nil
    end
  end
end
