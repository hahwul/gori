# Focused concurrency diagnostic: isolates the concurrent proxy path (fresh
# proxy + backend, no preceding profiles) with client errors VISIBLE, to tell a
# proxy concurrency bug apart from a harness/TIME_WAIT artifact.
require "socket"

module Gori
  class Error < Exception; end

  # client_conn stamps this into the CONNECT-failure page; the real value lives in
  # src/gori.cr, which these benches deliberately do not require (they pull only the
  # proxy, not the whole app).
  VERSION = "0.0.0-bench"
end

require "../src/gori/proxy/server"
require "../src/gori/proxy/sink"

class NullSink < Gori::Proxy::FlowSink
  @id = Atomic(Int64).new(0)

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    @id.add(1) + 1
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes) : Nil
  end
end

class Backend
  getter port : Int32

  def initialize(@body_size : Int32)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    @body = Bytes.new(@body_size) { |i| (65 + (i % 26)).to_u8 }
    @conns = Atomic(Int32).new(0)
  end

  def conns : Int32
    @conns.get
  end

  def start : Nil
    spawn do
      while client = @server.accept?
        @conns.add(1)
        spawn handle(client)
      end
    end
  end

  def stop : Nil
    @server.close rescue nil
  end

  private def handle(sock : TCPSocket) : Nil
    sock.sync = true
    sock.tcp_nodelay = true
    loop do
      line = String.build do |io|
        while (b = sock.read_byte)
          io << b.unsafe_chr
          break if b == 0x0a_u8
        end
      end
      break if line.empty?
      loop do
        h = String.build do |io|
          while (b = sock.read_byte)
            io << b.unsafe_chr
            break if b == 0x0a_u8
          end
        end
        break if h == "\r\n" || h.empty?
      end
      sock << "HTTP/1.1 200 OK\r\nContent-Length: " << @body.size << "\r\n\r\n"
      sock.write(@body) if @body.size > 0
      sock.flush
    end
  rescue
  ensure
    sock.close rescue nil
  end
end

def read_full_response(sock : IO) : Nil
  cl = 0
  while (line = gets_line(sock))
    break if line == "\r\n" || line == "\n"
    if line.downcase.starts_with?("content-length:")
      cl = line.split(':', 2)[1].strip.to_i? || 0
    end
  end
  if cl > 0
    buf = Bytes.new(cl)
    sock.read_fully(buf)
  end
end

def gets_line(sock : IO) : String?
  s = String.build do |io|
    while (b = sock.read_byte)
      io << b.unsafe_chr
      break if b == 0x0a_u8
    end
  end
  s.empty? ? nil : s
end

def drive(port : Int32, target : String, host : String, n : Int32, conc : Int32) : Int32
  per = n // conc
  done = Channel(Int32).new(conc)
  errors = Atomic(Int32).new(0)
  req = "GET #{target} HTTP/1.1\r\nHost: #{host}\r\nAccept: */*\r\n\r\n".to_slice
  conc.times do |i|
    spawn do
      ok = 0
      begin
        sock = TCPSocket.new("127.0.0.1", port)
        sock.sync = true
        sock.tcp_nodelay = true
        per.times do
          sock.write(req)
          sock.flush
          read_full_response(sock)
          ok += 1
        end
        sock.close rescue nil
      rescue ex
        errors.add(1)
        STDERR.puts "  [fiber #{i}] error after #{ok} reqs: #{ex.class}: #{ex.message}"
      end
      done.send(ok)
    end
  end
  total = 0
  conc.times { total += done.receive }
  STDERR.puts "  errored fibers: #{errors.get}/#{conc}" if errors.get > 0
  total
end

sink = NullSink.new
proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
proxy.start

N = (ENV["N"]? || "8000").to_i

[1, 8, 32].each do |conc|
  backend = Backend.new(1024)
  backend.start
  abs = "http://127.0.0.1:#{backend.port}/"
  reqhost = "127.0.0.1:#{backend.port}"
  t = Time.instant
  ok = drive(proxy.port, abs, reqhost, N, conc)
  wall = (Time.instant - t).total_seconds
  printf("conc=%-3d  ok=%d/%d  %.0f req/s  backend_conns=%d\n", conc, ok, N, ok / wall, backend.conns)
  backend.stop
  sleep 1.seconds
end
proxy.stop
