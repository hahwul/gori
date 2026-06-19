require "socket"
require "./sink"
require "./connect"
require "./head_rewriter"
require "../interceptor"
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
                   max_connections : Int32 = MAX_CONNECTIONS)
      @server = nil.as(TCPServer?)
      @running = false
      @slots = Channel(Nil).new(max_connections) # counting semaphore: send=acquire, receive=release
    end

    # Binds and starts the accept loop in its own fiber. Returns once listening.
    def start : Nil
      server = TCPServer.new(@host, @port)
      @port = server.local_address.port # resolve ephemeral (port 0) to the real one
      @server = server
      @running = true
      spawn(name: "gori-proxy-accept") { accept_loop(server) }
    end

    def stop : Nil
      @running = false
      @server.try(&.close) rescue nil
      @server = nil
    end

    def listening? : Bool
      @running
    end

    private def accept_loop(server : TCPServer) : Nil
      while @running
        client = server.accept? || break
        @slots.send(nil) # acquire a slot — blocks (pausing accept) when MAX_CONNECTIONS are in flight
        # Socket setup + handling run INSIDE the fiber so a hostile peer that RSTs
        # between accept and setsockopt can't raise on the accept loop itself
        # (which would silently stop the whole proxy); the `ensure` frees the slot.
        spawn do
          client.sync = true # immediate writes (P6)
          client.tcp_nodelay = true
          ClientConn.new(client, "http", @sink, @tls, rewriter: @rewriter, interceptor: @interceptor).run
        ensure
          @slots.receive # release the slot (even on error) so a new connection can be accepted
        end
      end
    end
  end
end
