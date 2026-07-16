require "socket"
require "./sink"
require "./connect"
require "./head_rewriter"
require "../interceptor"
require "../host_overrides"
require "./socket_tuning"
require "./conn/client_conn"

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

    def initialize(@host : String, @port : Int32, @sink : FlowSink, @tls : TlsMitm? = nil,
                   @rewriter : HeadRewriter? = nil, @interceptor : Gori::Interceptor? = nil,
                   @host_overrides : Gori::HostOverrides? = nil,
                   max_connections : Int32 = MAX_CONNECTIONS)
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
        ClientConn.new(client, "http", @sink, @tls, rewriter: @rewriter, interceptor: @interceptor,
          host_overrides: @host_overrides, self_addr: {@host, @port}).run
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
  end
end
