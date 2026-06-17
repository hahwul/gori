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

    def initialize(@host : String, @port : Int32, @sink : FlowSink, @tls : TlsMitm? = nil,
                   @rewriter : HeadRewriter? = nil, @interceptor : Gori::Interceptor? = nil)
      @server = nil.as(TCPServer?)
      @running = false
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
        client.sync = true # immediate writes (P6)
        client.tcp_nodelay = true
        spawn { ClientConn.new(client, "http", @sink, @tls, rewriter: @rewriter, interceptor: @interceptor).run }
      end
    end
  end
end
