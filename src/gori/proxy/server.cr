require "socket"
require "./sink"
require "./connect"
require "./head_rewriter"
require "./extractor"
require "../interceptor"
require "../host_overrides"
require "./socket_tuning"
require "./conn/client_conn"
require "../settings"
require "log"
require "./tls/client_hello"
require "./pump"
require "./upstream"
require "./prefix_io"
require "./orig_dst"
require "./h2/frame"

module Gori::Proxy
  # The listening proxy. Accepts client connections and spawns one ClientConn
  # fiber per connection. TLS interception is injected as an optional TlsMitm
  # (nil => HTTPS CONNECT requests are blind-tunnelled).
  class Server
    getter host : String
    getter port : Int32

    # Ceiling on simultaneously-handled client connections. A connection flood or
    # many slow/keep-alive clients otherwise spawns unbounded fibers (each with a
    # stack + capture buffers + possibly blocked on the store writer), which can
    # exhaust memory. Past the cap, accept() simply pauses — the kernel's TCP
    # backlog applies natural backpressure instead.
    MAX_CONNECTIONS = 2048

    # A TRANSPARENT server serves clients that believe they are talking to the origin: there is
    # no CONNECT and no absolute-form target, so the destination is derived per connection (Host
    # header for cleartext, TLS SNI for HTTPS). `target_port` is the upstream port to use when
    # the derived host names none — see Settings::Listener for why it is configured rather than
    # read off the socket.
    getter? transparent : Bool

    # A REVERSE server serves clients that believe they are talking to the origin, like a
    # transparent one — but the origin is DECLARED, not derived. `origin` is {scheme, host,
    # port} from the listener's configuration, so there is no Host header to trust, no SNI to
    # read, and none of the derivation failure modes those two carry. Nil for every other mode.
    getter origin : {String, String, Int32}?

    # Rewrite the forwarded `Host` header to the declared origin's authority. OFF by default,
    # and that is a P7 decision rather than a convenience one: the client's bytes go upstream
    # byte-exact unless the operator declares otherwise. A conventional reverse proxy does this
    # implicitly; doing it implicitly here would mutate operator-supplied bytes on the live
    # path, which is the one thing the provenance rule forbids.
    getter? rewrite_host : Bool

    def initialize(@host : String, @port : Int32, @sink : FlowSink, @tls : TlsMitm? = nil,
                   @rewriter : HeadRewriter? = nil, @interceptor : Gori::Interceptor? = nil,
                   @host_overrides : Gori::HostOverrides? = nil,
                   max_connections : Int32 = MAX_CONNECTIONS,
                   @transparent : Bool = false, @target_port : Int32 = 0,
                   @origin : {String, String, Int32}? = nil, @rewrite_host : Bool = false,
                   @extractor : ResponseExtract? = nil)
      @server = nil.as(TCPServer?)
      @running = false
      @slots = Channel(Nil).new(max_connections) # counting semaphore: send=acquire, receive=release
      # Per-LISTENER, not per-process: two transparent listeners on one host can legitimately get
      # different answers (one behind a redirect rule, one dialled directly), and folding them
      # into one class-level latch would silence the second one's line.
      @socket_dst_logged = false
      @derived_dst_logged = false
      @missing_h2c_dst_logged = false
    end

    # How many ports past the requested one to probe before giving up to ephemeral.
    FALLBACK_TRIES = 16

    # Binds and starts the accept loop in its own fiber. Returns once listening.
    # With `fallback`, a taken port falls back to the next few ports then an
    # ephemeral one, so a second gori instance binds its own port instead of
    # failing (the caller reports the resolved `port`).
    def start(fallback : Bool = false) : Nil
      server = bind_listener(fallback)
      @port = server.local_address.port # resolve ephemeral (port 0) to the real one
      @server = server
      @running = true
      spawn(name: "gori-proxy-accept") { accept_loop(server) }
    end

    private def bind_listener(fallback : Bool) : TCPServer
      return TCPServer.new(@host, @port) unless fallback && @port > 0
      candidates = [@port]
      (1..FALLBACK_TRIES).each { |i| candidates << @port + i if @port + i <= 65535 }
      candidates << 0 # ephemeral last resort (the OS picks any free port)
      last_err = nil.as(Exception?)
      candidates.each do |p|
        return TCPServer.new(@host, p)
      rescue ex : Socket::BindError
        last_err = ex # port taken — try the next candidate
      end
      raise last_err || Gori::Error.new("could not bind #{@host}")
    end

    def stop : Nil
      @running = false
      @server.try(&.close) rescue nil
      @server = nil
    end

    # Move the listener to a new host:port WITHOUT dropping in-flight connections
    # (only the accept socket is swapped; existing ClientConn fibers run on their
    # own accepted sockets). The new socket is bound FIRST, so a failure (port in
    # use / bad address) raises and leaves the current listener intact. When the
    # proxy isn't currently listening (capture off) it just records the new bind so
    # the next `start` uses it.
    def rebind(host : String, port : Int32) : Nil
      unless @running
        @host = host
        @port = port
        return
      end
      new_server = TCPServer.new(host, port) # raises before we touch the old listener
      @server.try(&.close) rescue nil        # old accept loop's accept? returns nil → it exits
      @host = host
      @port = new_server.local_address.port
      @server = new_server
      spawn(name: "gori-proxy-accept") { accept_loop(new_server) }
    end

    def listening? : Bool
      @running
    end

    private def accept_loop(server : TCPServer) : Nil
      while @running
        client =
          begin
            server.accept?
          rescue IO::Error
            # A transient accept error must NOT kill the accept loop and wedge the whole proxy
            # (an unrescued raise silently stops the only fiber that accepts new connections, and
            # nothing restarts it — @running stays true but no connection is ever accepted again).
            # Reachable without an attacker: EMFILE/ENFILE once open fds near the OS limit (gori
            # sets no RLIMIT_NOFILE, and the @slots cap of MAX_CONNECTIONS sits far above the
            # default ~256/1024), or a hostile connect-then-RST → ECONNABORTED. On persistent
            # EMFILE the pending connection stays in the backlog and accept keeps raising at once,
            # so back off briefly (else a bare retry busy-spins) then retry — the loop self-recovers
            # once fds free / the flood subsides. A clean close (stop/rebind) still surfaces as nil.
            sleep 10.milliseconds
            next
          end
        break unless client # nil ⇒ listener closed (stop / rebind) ⇒ exit the loop cleanly
        @slots.send(nil)    # acquire a slot — blocks (pausing accept) when MAX_CONNECTIONS are in flight
        # Hand the socket to a per-connection method so the spawned fiber closes
        # over that method's `client` PARAMETER (a fresh binding per call), NOT
        # the `client` loop variable. The loop variable is reassigned by the next
        # `accept?`; under a burst of simultaneous connections (a browser opening
        # its parallel sockets) the next accept returns from the backlog before
        # the spawned fiber is scheduled, so a `spawn do … client … end` block
        # here would capture the LATER socket — multiple fibers racing one socket
        # while the earlier connections are abandoned and reset. (P-correctness.)
        serve_connection(client)
      end
    end

    private def serve_connection(client : TCPSocket) : Nil
      # Socket setup + handling run INSIDE the fiber so a hostile peer that RSTs
      # between accept and setsockopt can't raise on the accept loop itself
      # (which would silently stop the whole proxy); the `ensure` frees the slot.
      spawn do
        client.sync = true # immediate writes (P6)
        client.tcp_nodelay = true
        # Baseline read/write timeout (defeats silent slowloris + RUDY on the client leg) and
        # keepalive (reaps a dead peer on a later relaxed tunnel). ClientConn re-arms per request
        # and relaxes both on entering a WS/SSE/CONNECT/h2 tunnel.
        SocketTuning.enable_keepalive(client)
        SocketTuning.arm(client, SocketTuning::CLIENT_IO_TIMEOUT)
        # The concrete address this client reached us on. Under a wildcard bind
        # (0.0.0.0 / ::) it's the LAN/interface IP the device connected through —
        # the signal that lets addresses_self?/loops_to_self? recognise a Host that
        # names that IP as the proxy itself (self-page + loop refusal). Best-effort:
        # a peer that RST'd between accept and here makes local_address raise, which
        # the rescue below turns into a clean close.
        local_host = (client.local_address.address rescue nil)
        if org = @origin
          serve_reverse(client, org)
        elsif @transparent
          serve_transparent(client)
        else
          ClientConn.new(client, "http", @sink, @tls, rewriter: @rewriter, interceptor: @interceptor,
            host_overrides: @host_overrides, self_addr: {@host, @port}, local_host: local_host,
            extractor: @extractor).run
        end
      rescue
        # Setup (setsockopt) can raise if the peer RST'd between accept and here;
        # ClientConn never took ownership, so close the accepted fd ourselves or
        # it leaks. (ClientConn#run closes its own @io and doesn't raise out, so
        # this only fires for pre-run setup failures.)
        client.close rescue nil
      ensure
        @slots.receive # release the slot (even on error) so a new connection can be accepted
      end
    end

    # A reverse connection. Routed on the same first-byte discriminator as the transparent and
    # CONNECT paths, so one reverse listener serves a cleartext client and a TLS one without the
    # operator declaring which they will send.
    #
    # `self_addr:` IS passed here, and that is the one place reverse deliberately parts company
    # with transparent (`serve_transparent` below omits it). Both guards it arms behave
    # correctly for a declared origin:
    #
    #   - The self-PAGE cannot fire, because no `tls:` is passed and the guard at
    #     `client_conn.cr:188` requires one. That is the same outcome transparent gets, for the
    #     same reason — an origin-form request here means the client thinks it reached the
    #     origin, not gori.
    #   - The self-LOOP refusal SHOULD fire. Transparent can do without it (its destination
    #     comes from the client, so a loop needs an odd client); a reverse origin is
    #     configuration, so `Settings.listener_error` refuses the loop at save time and this is
    #     the backstop for what a save-time string comparison cannot see — a hostname that
    #     resolves to our own port, or a host override added after the save.
    #
    # SCOPE. Layer 2 (Sandbox + EXCLUDE) applies unchanged and is not optional: `@interceptor`
    # is threaded in, so `ClientConn#handle_request`'s `sandbox_blocks?` gate runs per request
    # exactly as it does for the forward proxy, and `serve_reverse_tls` adds the same
    # pre-handshake host gate the CONNECT and transparent paths use.
    #
    # Layer 1 (include) is INHERITED UNCHANGED, and that is a decision rather than an
    # oversight. "The operator configured this listener to point here" is a strong Layer-1
    # argument — but only on a surface where Layer 1 AUTHORISES AN OUTBOUND SEND gori
    # originates (the Repeater, fuzz, discover). A reverse listener originates nothing: it
    # forwards a request a client made, and on the capture path Layer 1 is a LENS over what
    # was captured, not a gate on what may be sent. There is no send here to authorise, so the
    # argument has nothing to attach to, and giving this listener its own Layer-1 answer would
    # only make the History lens treat identical traffic differently depending on which socket
    # it arrived through.
    private def serve_reverse(client : TCPSocket, origin : {String, String, Int32}) : Nil
      scheme, host, port = origin
      first = client.peek
      if first && !first.empty? && first[0] == 0x16_u8
        return serve_reverse_tls(client, origin)
      end
      # h2c prior knowledge (#737). A reverse listener IS the origin — the authority is
      # declared, not derived — so RFC 9113 §3.4 is as well defined here as it is for gori's own
      # h2c senders, and none of the `:authority` routing the forward proxy would need applies.
      # Only for a CLEARTEXT origin: `serve_h2c`'s relay dials the origin in the clear, so an
      # `https` origin would need an h2-over-TLS leg that does not exist on this path.
      if h2c_preface?(first)
        unless scheme == "http"
          ::Log.warn do
            "reverse listener #{BindAddress.authority(@host, @port)}: refused an HTTP/2 " \
            "prior-knowledge connection — the declared origin #{scheme}://#{host}:#{port} is " \
            "TLS, and gori's h2c relay dials the origin in the clear. Declare an http:// " \
            "origin to serve h2c here"
          end
          return close_client(client)
        end
        return serve_h2c(client, host, port, origin_dst: nil)
      end
      ClientConn.new(client, scheme, @sink,
        fixed_host: host, fixed_port: port, tls_upstream: scheme == "https",
        rewriter: @rewriter, interceptor: @interceptor, host_overrides: @host_overrides,
        self_addr: {@host, @port}, rewrite_fixed_host: @rewrite_host, extractor: @extractor).run
    end

    # TLS terminated by a reverse listener. The leaf is minted for the CONFIGURED origin host,
    # never for the client's SNI — that is the whole point of the mode, and preferring SNI here
    # would quietly reintroduce the derivation this mode exists to remove (a client offering a
    # name we do not forward to would get a certificate for a host gori never contacts).
    # Practically it means the client must reach this socket under the origin's name, which is
    # the ordinary reverse-proxy arrangement: a hosts entry, or a DNS record, pointing at it.
    #
    # From `intercept` onward this is byte-for-byte the CONNECT path, so ALPN reflection and
    # capture behave identically. Every DROP path closes the client socket explicitly, for the
    # reason spelled out on `serve_transparent_tls`.
    private def serve_reverse_tls(client : TCPSocket, origin : {String, String, Int32}) : Nil
      scheme, host, port = origin
      tls = @tls
      return close_client(client) unless tls
      # Same pre-handshake sandbox gate as the transparent and CONNECT paths. The host is
      # configured rather than derived, so this can only fire on a listener the operator
      # pointed at a host their own sandbox excludes — but Layer 2 is the layer that must be
      # identical on every surface, so it is applied here exactly as everywhere else.
      return close_client(client) if (ic = @interceptor) && ic.sandbox_blocks_host?(host)
      # No PrefixIO: `peek` above did not consume, so the ClientHello is still in the socket's
      # buffer for OpenSSL to read. (The transparent path needs one only because peek_sni does
      # consume what it parses.)
      tls.intercept(host, port, client, @sink, tls_upstream: scheme == "https",
        rewrite_host: @rewrite_host)
    end

    # How few bytes of the preface are still enough to decide. Four is `"PRI "` — the method,
    # which is the discriminating part; below that a segment holding only `"P"` decides nothing.
    H2C_PREFACE_FLOOR = 4

    # Does this connection open with the HTTP/2 client preface (RFC 9113 §3.4)?
    #
    # Deliberately NOT the single-byte test the CONNECT path uses. After a CONNECT's `200`
    # reply, `0x50` IS the preface: the only two things a client sends there are a TLS
    # ClientHello or `PRI * HTTP/2.0`. On a LISTENER the same byte opens `POST`, `PUT` and
    # `PATCH`, so a first-byte branch would divert every form submission into the h2 relay, and
    # each one would die at `Frame.read_preface` with the connection already committed. So as
    # much of the real preface as the peek holds is compared, with a floor.
    #
    # `peek` CONSUMES NOTHING, which is what keeps the existing routing byte-exact: a false
    # answer leaves the socket untouched for `ClientConn`, and a true one leaves the whole
    # 24-octet preface in the buffer for `Frame.read_preface` to read. That is why neither
    # listener needs a `PrefixIO` here, and it is the one way this differs from the CONNECT
    # site, which peeks by READING a byte and therefore has to push it back.
    private def h2c_preface?(peeked : Bytes?) : Bool
      return false unless peeked
      n = Math.min(peeked.size, H2::Frame::PREFACE.size)
      return false if n < H2C_PREFACE_FLOOR
      peeked[0, n] == H2::Frame::PREFACE[0, n]
    end

    # Serve an h2c prior-knowledge connection that arrived DIRECTLY on a listener (#737).
    #
    # The relay itself is `ClientConn`'s — see `ClientConn#serve_h2c_prior_knowledge` at the
    # foot of this file for why the entry point is spelled there and not here. What belongs to
    # the LISTENER is which gates apply, and they are not the CONNECT path's:
    #
    #   * `http2_disabled?` — applies, verbatim. The client committed to HTTP/2 by sending the
    #     preface, so there is nothing to downgrade to; relaying anyway would make "force
    #     HTTP/1.1" quietly untrue on this socket, which is worse than a visible refusal.
    #   * the SANDBOX — the host gate (`sandbox_blocks_host?`), which is what this listener's
    #     own TLS branch already applies (`serve_reverse_tls`, `serve_transparent_tls`), NOT
    #     `handle_connect`'s blanket "sandbox on ⇒ refuse the tunnel". Two reasons, and neither
    #     depends on how the CONNECT-path gate is settled elsewhere. First, `H2::StreamGate`
    #     has carried a hard PER-STREAM sandbox gate since #492 step 4, so the h2 relay is not
    #     the ungated path the blanket refusal was written against. Second, h2-over-TLS on
    #     THESE listeners already runs behind exactly this host gate and nothing more — an
    #     ALPN-negotiated h2 stream on the same reverse listener reaches `relay_h2` with only
    #     the pre-handshake host test in front of it — so h2c here is precisely as gated as the
    #     h2 the listener serves today, and no new hole is opened.
    #   * the three rule gates (`h2c_refusal`) — apply, for the reason they apply on
    #     CONNECT: they live on `ClientConn`'s h1 path, the relay cannot run them, and with the
    #     preface already sent the only honest answers are refuse or lie.
    #
    # Every refusal CLOSES the socket. Nothing else will: ownership never passes to a
    # `ClientConn#run` on this path, and the accept fiber's rescue only covers pre-run setup —
    # the same reasoning `serve_transparent_tls` spells out.
    private def serve_h2c(client : TCPSocket, host : String, port : Int32,
                          origin_dst : {String, Int32}?) : Nil
      if Settings.http2_disabled?
        ::Log.warn do
          "listener #{BindAddress.authority(@host, @port)}: refused an HTTP/2 prior-knowledge " \
          "connection to #{host}:#{port} because HTTP/2 is switched off (settings " \
          "network.http2) — the client already sent the preface, so there is nothing to " \
          "downgrade to HTTP/1.1"
        end
        return close_client(client)
      end
      return close_client(client) if (ic = @interceptor) && ic.sandbox_blocks_host?(host)
      # Built for its four lenses and its dial: `origin_dst` is what arms `dial_pin`, so a
      # transparent h2c connection is dialled at the address the kernel named, exactly as the
      # cleartext and TLS branches are (#529).
      conn = ClientConn.new(client, "http", @sink, rewriter: @rewriter, interceptor: @interceptor,
        host_overrides: @host_overrides, origin_dst: origin_dst, extractor: @extractor)
      begin
        conn.serve_h2c_prior_knowledge(host, port, client)
      ensure
        close_client(client)
      end
    end

    # A transparent connection. Route on the first byte, the same discriminator the CONNECT path
    # uses: 0x16 is a TLS ClientHello, anything else is cleartext HTTP.
    #
    # No `self_addr:` and no `tls:` are passed to ClientConn on the cleartext branch, and that is
    # deliberate. Those two arm the self-page and self-loop guards, which exist for a client
    # talking TO gori — but here an origin-form request means the client thinks it is talking to
    # the ORIGIN, which is exactly the shape those guards would misread. Without them,
    # `resolve_forward` already resolves origin-form from the Host header, which IS transparent
    # forwarding; nothing further is needed for cleartext.
    private def serve_transparent(client : TCPSocket) : Nil
      first = client.peek
      tls = !!(first && !first.empty? && first[0] == 0x16_u8)
      # Read the original destination ONCE, before the branch, and hand the same answer to both
      # halves. That is the property `Settings::Listener#effective_target_port(tls)` existed to
      # hold — the cleartext and TLS branches cannot disagree about the destination — now
      # covering the address as well as the port.
      dst = transparent_dst(client, tls)
      if tls
        serve_transparent_tls(client, dst)
      elsif h2c_preface?(first)
        serve_transparent_h2c(client, dst)
      else
        ClientConn.new(client, "http", @sink, rewriter: @rewriter, interceptor: @interceptor,
          host_overrides: @host_overrides,
          default_port: Settings.listener_target_port(@target_port, tls: false),
          origin_dst: dst, extractor: @extractor).run
      end
    end

    # The kernel's original destination for this connection as {host, port}, or nil when there
    # is none and the `Host`/SNI derivation has to answer instead.
    private def transparent_dst(client : TCPSocket, tls : Bool) : {String, Int32}?
      found = OrigDst.lookup(client)
      if found
        log_dst_source(true, "#{OrigDst.dial_host(found)}:#{found.port}")
        {OrigDst.dial_host(found), found.port}
      else
        log_dst_source(false, "port #{Settings.listener_target_port(@target_port, tls: tls)}")
        nil
      end
    end

    # Transparent h2c (#737). The kernel's answer is the ONLY destination this branch can have,
    # and that is a property of the protocol rather than a gap in the lookup.
    #
    # Every other transparent branch has a second source when `SO_ORIGINAL_DST`/pf has none: the
    # cleartext branch derives the host from `Host` and the port from the listener's
    # `target_port`, and the TLS branch derives it from the SNI. h2c has neither. The name a
    # client is asking for lives in the `:authority` pseudo-header of the first HEADERS frame,
    # which is HPACK state the relay owns — reading it here would mean decoding a header block
    # outside the connection's decoder and then handing a desynchronised table to the relay, and
    # even then the SECOND stream on the same connection may name a different authority, which
    # is precisely why prior knowledge is only well defined against a known origin.
    #
    # So with no kernel answer there is no destination at all, and the connection is dropped
    # rather than dialled somewhere invented — with a line, because a client that mysteriously
    # fails otherwise leaves no trace anywhere. `log_missing_sni`'s reasoning, applied to the
    # branch that has one fewer fallback than the branch that comment was written for.
    private def serve_transparent_h2c(client : TCPSocket, dst : {String, Int32}?) : Nil
      unless dst
        log_missing_h2c_dst
        return close_client(client)
      end
      serve_h2c(client, dst[0], dst[1], origin_dst: dst)
    end

    # #493's discipline, applied to the destination: an operator looking at a flow that went
    # somewhere unexpected must be able to READ which of the two sources decided it, not infer
    # it from the shape of the mistake. The two are not interchangeable — the kernel's answer is
    # the address the client actually dialled, the derived one is a name the client typed into a
    # header it controls.
    #
    # Logged once per source per listener, following `@@missing_sni_logged` and
    # `PASSTHROUGH_NOTICE_MAX`: the answer changes when the deployment changes, not per
    # connection, so a line per connection would be noise an operator learns to ignore. Both
    # states are announced, and a listener that later starts answering the other way says so
    # too — the transition is exactly the moment worth hearing about.
    private def log_dst_source(from_socket : Bool, detail : String) : Nil
      return if from_socket ? @socket_dst_logged : @derived_dst_logged
      if from_socket
        @socket_dst_logged = true
        ::Log.info { "transparent listener #{BindAddress.authority(@host, @port)}: original destination read from the socket via #{OrigDst.mechanism} (#{detail}) — this is logged once" }
      else
        @derived_dst_logged = true
        why = OrigDst.unavailable_reason || "the kernel has no original destination for this connection (nothing redirected it here?)"
        ::Log.info { "transparent listener #{BindAddress.authority(@host, @port)}: destination DERIVED from the client's Host header / TLS SNI — #{why}; #{detail} — this is logged once" }
      end
    end

    # Transparent HTTPS: read the destination out of the ClientHello, then hand the stream to the
    # normal TLS-MITM seam with the bytes replayed. From `intercept` onward this is byte-for-byte
    # the CONNECT path, so ALPN reflection, the passthrough list and capture all behave
    # identically — the only difference is where the hostname came from.
    # Every DROP path here closes the client socket explicitly. Nothing else will: the accept
    # fiber's rescue only covers pre-run setup, and on the normal paths ownership passes to
    # ClientConn or to the TLS socket (whose sync_close tears down the transport). A path that
    # merely returned would leave the client blocked until its own timeout and leak the fd —
    # one per connection, so a client that always fails the gate would exhaust them.
    private def serve_transparent_tls(client : TCPSocket, dst : {String, Int32}?) : Nil
      tls = @tls
      return close_client(client) unless tls
      sni, consumed = Tls::ClientHello.peek_sni(client)
      stream = PrefixIO.new(consumed, client)
      # The SNI is the NAME the client asked for, so it stays the destination whenever it is
      # there: it is what the leaf has to be minted for, what the sandbox and the passthrough
      # list are written against, and what History shows. The kernel's address answers the case
      # the SNI cannot — a ClientHello that carries no server_name at all, which until now had
      # no destination and was dropped.
      #
      # The name is no longer what gets DIALLED, though (#529): `dial_addr` below carries the
      # kernel's address down to the two origin dials, so an SNI that names one host while the
      # connection went to another reaches the host it went to. When the SNI IS absent both
      # values are the kernel's address and the pin is a no-op, which is why #528's no-name
      # behaviour is untouched.
      host = sni || dst.try(&.[0])
      unless host
        # No name and no kernel answer: nothing to mint a certificate for and nothing to gate on.
        # Relaying blind would send an unidentified connection to an unknown origin, so drop it —
        # and say so once, because a client that mysteriously fails otherwise leaves no trace
        # anywhere.
        log_missing_sni
        return close_client(client)
      end
      port = dst.try(&.[1]) || Settings.listener_target_port(@target_port, tls: true)
      # The sandbox refuses a host that CANNOT be in scope before any handshake, matching the
      # CONNECT path's gate (ClientConn#connect_answered_locally?). There is no way to answer
      # with a 403 here — the client expects TLS, not HTTP — so the connection is dropped.
      return close_client(client) if (ic = @interceptor) && ic.sandbox_blocks_host?(host)
      if Settings.tls_passthrough?(host)
        return if relay_transparent_passthrough(host, port, stream, client, dst.try(&.[0]))
        # The origin was unreachable, so nothing was relayed. Fall through and MITM instead of
        # dropping: the operator asked not to decrypt this host, not to lose the connection, and
        # the handshake failure they then see names the real problem.
      end
      tls.intercept(host, port, stream, @sink, dial_addr: dst.try(&.[0]))
    end

    # A passthrough host reached through a transparent listener: dial the origin and pipe bytes,
    # never minting a leaf. False when the origin could not be reached AND nothing was consumed,
    # so the caller can still fall through.
    #
    # `pin` applies here for the same reason it applies to the MITM branch, and matters MORE:
    # this connection is relayed undecrypted, so the address gori dials is the only thing that
    # decides where the client's session actually terminates. The passthrough LIST is still
    # matched on the name (`Settings.tls_passthrough?` above) — the operator wrote it against
    # names — which is exactly the split #529 is.
    private def relay_transparent_passthrough(host : String, port : Int32, stream : IO,
                                              client : TCPSocket, pin : String? = nil) : Bool
      upstream = Upstream.dial(host, port, overrides: @host_overrides, pin: pin)
      return false unless upstream
      begin
        SocketTuning.relax(stream)
        SocketTuning.relax(upstream)
        Pump.blind_tunnel(stream, upstream)
      ensure
        upstream.close rescue nil
        close_client(client)
      end
      true
    end

    private def close_client(client : TCPSocket) : Nil
      client.close rescue nil
    end

    @@missing_sni_logged = false

    private def log_missing_sni : Nil
      return if @@missing_sni_logged
      @@missing_sni_logged = true
      ::Log.info { "transparent listener: dropped a TLS connection with no SNI and no original destination from the socket (nothing to derive a destination from) — this is logged once" }
    end

    # Per LISTENER rather than per process, unlike `@@missing_sni_logged` above: the answer this
    # announces is `OrigDst`'s, and two transparent listeners on one host can legitimately get
    # different ones — the same reason `@socket_dst_logged`/`@derived_dst_logged` are instance
    # state. Folding them would silence the second listener's line.
    private def log_missing_h2c_dst : Nil
      return if @missing_h2c_dst_logged
      @missing_h2c_dst_logged = true
      why = OrigDst.unavailable_reason ||
            "the kernel has no original destination for this connection (nothing redirected it here?)"
      ::Log.info do
        "transparent listener #{BindAddress.authority(@host, @port)}: dropped an HTTP/2 " \
        "prior-knowledge connection — #{why}, and h2c carries no Host header or SNI to derive " \
        "a destination from (the `:authority` lives inside the connection's HPACK state). " \
        "Redirect this listener with iptables/pf so the original destination is readable, or " \
        "use a reverse listener with the origin declared — this is logged once"
      end
    end
  end
end
