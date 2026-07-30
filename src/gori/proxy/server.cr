require "socket"
require "./sink"
require "./connect"
require "./head_rewriter"
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
                   @origin : {String, String, Int32}? = nil, @rewrite_host : Bool = false)
      @server = nil.as(TCPServer?)
      @running = false
      @slots = Channel(Nil).new(max_connections) # counting semaphore: send=acquire, receive=release
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
            host_overrides: @host_overrides, self_addr: {@host, @port}, local_host: local_host).run
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
      ClientConn.new(client, scheme, @sink,
        fixed_host: host, fixed_port: port, tls_upstream: scheme == "https",
        rewriter: @rewriter, interceptor: @interceptor, host_overrides: @host_overrides,
        self_addr: {@host, @port}, rewrite_fixed_host: @rewrite_host).run
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
      tls.intercept(host, port, client, @sink, tls_upstream: scheme == "https")
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
      if first && !first.empty? && first[0] == 0x16_u8
        serve_transparent_tls(client)
      else
        ClientConn.new(client, "http", @sink, rewriter: @rewriter, interceptor: @interceptor,
          host_overrides: @host_overrides,
          default_port: Settings.listener_target_port(@target_port, tls: false)).run
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
    private def serve_transparent_tls(client : TCPSocket) : Nil
      tls = @tls
      return close_client(client) unless tls
      sni, consumed = Tls::ClientHello.peek_sni(client)
      stream = PrefixIO.new(consumed, client)
      unless sni
        # No name: nothing to mint a certificate for and nothing to gate on. Relaying blind would
        # send an unidentified connection to an unknown origin, so drop it — and say so once,
        # because a client that mysteriously fails otherwise leaves no trace anywhere.
        log_missing_sni
        return close_client(client)
      end
      port = Settings.listener_target_port(@target_port, tls: true)
      # The sandbox refuses a host that CANNOT be in scope before any handshake, matching the
      # CONNECT path's gate (ClientConn#connect_answered_locally?). There is no way to answer
      # with a 403 here — the client expects TLS, not HTTP — so the connection is dropped.
      return close_client(client) if (ic = @interceptor) && ic.sandbox_blocks_host?(sni)
      if Settings.tls_passthrough?(sni)
        return if relay_transparent_passthrough(sni, port, stream, client)
        # The origin was unreachable, so nothing was relayed. Fall through and MITM instead of
        # dropping: the operator asked not to decrypt this host, not to lose the connection, and
        # the handshake failure they then see names the real problem.
      end
      tls.intercept(sni, port, stream, @sink)
    end

    # A passthrough host reached through a transparent listener: dial the origin and pipe bytes,
    # never minting a leaf. False when the origin could not be reached AND nothing was consumed,
    # so the caller can still fall through.
    private def relay_transparent_passthrough(host : String, port : Int32, stream : IO,
                                              client : TCPSocket) : Bool
      upstream = Upstream.dial(host, port, overrides: @host_overrides)
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
      ::Log.info { "transparent listener: dropped a TLS connection with no SNI (no destination to derive) — this is logged once" }
    end
  end
end
