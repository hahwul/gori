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

    def initialize(@host : String, @port : Int32, @sink : FlowSink, @tls : TlsMitm? = nil,
                   @rewriter : HeadRewriter? = nil, @interceptor : Gori::Interceptor? = nil,
                   @host_overrides : Gori::HostOverrides? = nil,
                   max_connections : Int32 = MAX_CONNECTIONS,
                   @transparent : Bool = false, @target_port : Int32 = 0)
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
        if @transparent
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
