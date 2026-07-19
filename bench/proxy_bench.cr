# End-to-end proxy benchmark harness.
#
# Embeds the REAL Gori::Proxy::Server in-process with a NullSink (so we measure
# the proxy + HTTP/1.1 codec cost, NOT the SQLite writer), drives various
# test-data profiles (body sizes, request bodies, keep-alive) through it, and
# compares against a DIRECT baseline (client -> backend, no proxy) to isolate
# the per-request overhead the proxy itself adds.
#
# Build: crystal build bench/proxy_bench.cr -o bin/proxy_bench --release
# Run:   bin/proxy_bench
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

# Discards captures — isolates proxy+codec cost from the DB writer fiber.
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

# Minimal HTTP/1.1 keep-alive origin. Serves a fixed-size body (Content-Length
# or chunked), consuming any request body first so keep-alive stays framed.
class Backend
  getter port : Int32

  def initialize(@body_size : Int32, @chunked : Bool = false)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    @body = Bytes.new(@body_size) { |i| (65 + (i % 26)).to_u8 }
  end

  def start : Nil
    spawn do
      while client = @server.accept?
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
      cl = read_head_and_cl(sock)
      break if cl.nil? # EOF / closed
      consume(sock, cl)
      write_response(sock)
    end
  rescue
  ensure
    sock.close rescue nil
  end

  # Reads the request head; returns the request Content-Length (0 if none),
  # or nil on clean EOF.
  private def read_head_and_cl(sock : TCPSocket) : Int32?
    buf = IO::Memory.new
    cl = 0
    line = String.build do |io|
      while (b = sock.read_byte)
        io << b.unsafe_chr
        break if b == 0x0a_u8
      end
    end
    return nil if line.empty?
    loop do
      hline = String.build do |io|
        while (b = sock.read_byte)
          io << b.unsafe_chr
          break if b == 0x0a_u8
        end
      end
      break if hline == "\r\n" || hline.empty?
      lower = hline.downcase
      if lower.starts_with?("content-length:")
        cl = hline.split(':', 2)[1].strip.to_i? || 0
      end
    end
    cl
  end

  private def consume(sock : TCPSocket, n : Int32) : Nil
    return if n <= 0
    buf = Bytes.new(Math.min(n, 64 * 1024))
    remaining = n
    while remaining > 0
      want = Math.min(remaining, buf.size)
      read = sock.read(buf[0, want])
      break if read == 0
      remaining -= read
    end
  end

  private def write_response(sock : TCPSocket) : Nil
    if @chunked
      sock << "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
      # split body into 16KB chunks
      off = 0
      while off < @body.size
        n = Math.min(16 * 1024, @body.size - off)
        sock << n.to_s(16) << "\r\n"
        sock.write(@body[off, n])
        sock << "\r\n"
        off += n
      end
      sock << "0\r\n\r\n"
    else
      sock << "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: " << @body.size << "\r\n\r\n"
      sock.write(@body) if @body.size > 0
    end
    sock.flush
  end
end

# Reads a full HTTP/1.1 response (head + body per Content-Length/chunked) so the
# keep-alive connection stays framed. Returns total body bytes read.
def read_full_response(sock : IO) : Int32
  cl = nil.as(Int32?)
  chunked = false
  # status line
  read_line(sock)
  loop do
    line = read_line(sock)
    break if line.nil? || line == "\r\n" || line == "\n" || line.empty?
    lower = line.downcase
    if lower.starts_with?("content-length:")
      cl = line.split(':', 2)[1].strip.to_i? || 0
    elsif lower.starts_with?("transfer-encoding:") && lower.includes?("chunked")
      chunked = true
    end
  end
  if chunked
    total = 0
    loop do
      size_line = read_line(sock) || break
      size = size_line.strip.to_i?(base: 16) || 0
      break if size == 0
      buf = Bytes.new(size)
      sock.read_fully(buf)
      total += size
      read_line(sock) # trailing CRLF
    end
    read_line(sock) # final CRLF after 0-chunk
    total
  elsif c = cl
    if c > 0
      buf = Bytes.new(c)
      sock.read_fully(buf)
    end
    c
  else
    0
  end
end

def read_line(sock : IO) : String?
  s = String.build do |io|
    while (b = sock.read_byte)
      io << b.unsafe_chr
      break if b == 0x0a_u8
    end
  end
  s.empty? ? nil : s
end

def build_request(target : String, host : String, body : Bytes? = nil) : Bytes
  io = IO::Memory.new
  if body && body.size > 0
    io << "POST " << target << " HTTP/1.1\r\nHost: " << host << "\r\nContent-Length: " << body.size << "\r\nAccept: */*\r\n\r\n"
    io.write(body)
  else
    io << "GET " << target << " HTTP/1.1\r\nHost: " << host << "\r\nAccept: */*\r\nUser-Agent: gori-bench/1.0\r\n\r\n"
  end
  io.to_slice
end

# Drives `n` requests over `conc` keep-alive connections; returns {wall_seconds, sorted_latencies_us}.
def drive(host : String, port : Int32, target : String, req_host : String,
          n : Int32, conc : Int32, req_body : Bytes? = nil) : {Float64, Array(Float64)}
  per = n // conc
  results = Channel(Array(Float64)).new(conc)
  req = build_request(target, req_host, req_body)
  t0 = Time.instant
  conc.times do
    spawn do
      lat = Array(Float64).new(per)
      begin
        sock = TCPSocket.new(host, port)
        sock.sync = true
        sock.tcp_nodelay = true
        per.times do
          s = Time.instant
          sock.write(req)
          sock.flush
          read_full_response(sock)
          lat << (Time.instant - s).total_microseconds
        end
        sock.close rescue nil
      rescue ex
        STDERR.puts "client error: #{ex.message}"
      end
      results.send(lat)
    end
  end
  all = Array(Float64).new(n)
  conc.times { all.concat(results.receive) }
  wall = (Time.instant - t0).total_seconds
  all.sort!
  {wall, all}
end

def pct(sorted : Array(Float64), p : Float64) : Float64
  return 0.0 if sorted.empty?
  idx = ((sorted.size - 1) * p).round.to_i
  sorted[idx]
end

def report(label : String, wall : Float64, lat : Array(Float64), n : Int32) : Nil
  if lat.empty?
    printf("  %-28s  (no successful requests — likely port exhaustion)\n", label)
    return
  end
  rps = lat.size / wall
  mean = lat.sum / lat.size
  printf("  %-28s  %8.0f req/s  mean %7.1fµs  p50 %7.1fµs  p99 %8.1fµs  max %8.1fµs  (ok=%d)\n",
    label, rps, mean, pct(lat, 0.50), pct(lat, 0.99), lat.last, lat.size)
end

def mean_of(lat : Array(Float64)) : Float64
  lat.empty? ? 0.0 : lat.sum / lat.size
end

# ---- run ----------------------------------------------------------------

# Default modest so per-request upstream connect/close (no pooling) doesn't
# exhaust the ~16K macOS ephemeral ports within one TIME_WAIT window. After
# pooling lands, high N stays stable — the before/after is the point.
REQUESTS = (ENV["BENCH_N"]? || "5000").to_i
WARMUP   = 500

sink = NullSink.new
# Proxy with NO TLS MITM, NO rewriter, NO interceptor — pure forward path.
proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
proxy.start
proxy_port = proxy.port
puts "proxy listening on 127.0.0.1:#{proxy_port}"

profiles = [
  {name: "0B body", size: 0, chunked: false, conc: 1},
  {name: "1KB body", size: 1024, chunked: false, conc: 1},
  {name: "64KB body", size: 64 * 1024, chunked: false, conc: 1},
  {name: "1MB body", size: 1024 * 1024, chunked: false, conc: 1},
  {name: "64KB chunked", size: 64 * 1024, chunked: true, conc: 1},
  {name: "1KB body c=8", size: 1024, chunked: false, conc: 8},
  {name: "1KB body c=32", size: 1024, chunked: false, conc: 32},
  {name: "64KB body c=8", size: 64 * 1024, chunked: false, conc: 8},
]

profiles.each do |pr|
  backend = Backend.new(pr[:size], pr[:chunked])
  backend.start
  bport = backend.port
  abs = "http://127.0.0.1:#{bport}/"
  reqhost = "127.0.0.1:#{bport}"

  # warmup both paths
  drive("127.0.0.1", bport, "/", reqhost, WARMUP, 1)
  drive("127.0.0.1", proxy_port, abs, reqhost, WARMUP, 1)

  n = pr[:size] >= 1024 * 1024 ? REQUESTS // 10 : REQUESTS
  conc = pr[:conc]

  puts "\n== #{pr[:name]} (n=#{n}, conc=#{conc}) =="
  dw, dl = drive("127.0.0.1", bport, "/", reqhost, n, conc)
  report("direct", dw, dl, n)
  pw, pl = drive("127.0.0.1", proxy_port, abs, reqhost, n, conc)
  report("proxy", pw, pl, n)
  overhead = mean_of(pl) - mean_of(dl)
  dr = dl.empty? ? 0.0 : dl.size / dw
  prps = pl.empty? ? 0.0 : pl.size / pw
  printf("  -> proxy adds %.1fµs/req mean latency (%.1f%% throughput vs direct)\n",
    overhead, (dr == 0 ? 0.0 : prps / dr * 100))

  backend.stop
  sleep 2.seconds # let TIME_WAIT sockets drain before the next profile
end

# Request-body upload profile (POST)
puts "\n== POST 64KB request body =="
backend = Backend.new(0, false)
backend.start
bport = backend.port
abs = "http://127.0.0.1:#{bport}/"
reqhost = "127.0.0.1:#{bport}"
body = Bytes.new(64 * 1024) { |i| (i % 256).to_u8 }
drive("127.0.0.1", bport, "/", reqhost, WARMUP, 1, body)
drive("127.0.0.1", proxy_port, abs, reqhost, WARMUP, 1, body)
dw, dl = drive("127.0.0.1", bport, "/", reqhost, REQUESTS, 1, body)
report("direct", dw, dl, REQUESTS)
pw, pl = drive("127.0.0.1", proxy_port, abs, reqhost, REQUESTS, 1, body)
report("proxy", pw, pl, REQUESTS)
backend.stop

proxy.stop
puts "\ndone"
