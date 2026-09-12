# `Codec::Http1.read_head` — the proxy's one IO boundary, measured on BOTH of its paths.
#
# codec_bench covers the plain path only, and the plain path is not the one real traffic
# takes: `ClientConn#read_client_head` and `#safe_read_head` both pass a `deadline` and a
# `timeout_sock`, so every proxied request head and every response head goes through
# `read_head_deadlined`. Its extra per-iteration work (re-arming the drip-feed deadline)
# is invisible from codec_bench, which is why this harness exists.
#
# `timeout_sock` only ever has `read_timeout=` called on it, so it does NOT have to be the
# socket `io` reads from: feeding the loop an `IO::Memory` while handing it a real (idle)
# socket to arm isolates the codec's own per-head cost from kernel and scheduler noise,
# the same trick capture_bench uses to get stable bytes/op out of the body path.
#
# Build: crystal build bench/head_read_bench.cr -o bin/head_read_bench --release
# Run:   bin/head_read_bench
require "benchmark"
require "socket"

module Gori
  class Error < Exception; end
end

require "../src/gori/proxy/codec/http1"

include Gori::Proxy::Codec

REQ_HEAD = ("GET /api/v1/users/12345/profile?include=avatar,bio&fmt=json HTTP/1.1\r\n" +
            "Host: api.example.com\r\n" +
            "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36\r\n" +
            "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8\r\n" +
            "Accept-Language: en-US,en;q=0.9\r\n" +
            "Accept-Encoding: gzip, deflate, br\r\n" +
            "Cookie: session=abc123def456; csrf=xyz789; theme=dark; lang=en\r\n" +
            "Referer: https://www.example.com/dashboard\r\n" +
            "Connection: keep-alive\r\n\r\n").to_slice

RESP_HEAD = ("HTTP/1.1 200 OK\r\n" +
             "Content-Type: application/json; charset=utf-8\r\n" +
             "Content-Length: 4096\r\n" +
             "Cache-Control: no-cache, no-store, must-revalidate\r\n" +
             "Date: Mon, 23 Jun 2026 12:00:00 GMT\r\n" +
             "Server: nginx/1.25.0\r\n" +
             "Vary: Accept-Encoding\r\n" +
             "X-Request-Id: 7f3a9b2c-1d4e-4f5a-8b6c-9d0e1f2a3b4c\r\n" +
             "Connection: keep-alive\r\n\r\n").to_slice

# A 2 KiB head: a browser carrying a fat cookie jar, still well under the 256 KiB cap.
BIG_HEAD = begin
  io = IO::Memory.new
  io << "GET /app HTTP/1.1\r\nHost: api.example.com\r\n"
  12.times { |i| io << "X-Pad-" << i << ": " << "z" * 140 << "\r\n" }
  io << "\r\n"
  io.to_slice
end

# A head that arrives in TWO reads, with the terminator's CRLFCRLF STRADDLING the split —
# the one shape a bulk scan can get wrong and a byte-at-a-time loop cannot. `peek` has to
# stop at the split for that to be what is measured: without one the base `IO#peek` returns
# nil, `read_head` takes the byte-at-a-time fallback, and this exercises the old loop under
# a label that reads as the new one.
SPLIT_AT = REQ_HEAD.size - 2

class TwoChunkIO < IO
  getter pos = 0

  def initialize(@head : Bytes, @split : Int32)
  end

  def peek : Bytes
    stop = @pos < @split ? @split : @head.size
    @head[@pos, stop - @pos]
  end

  def skip(bytes_count : Int) : Nil
    @pos += bytes_count
  end

  def read(slice : Bytes) : Int32
    stop = @pos < @split ? @split : @head.size
    n = Math.min(slice.size, stop - @pos)
    return 0 if n <= 0
    @head[@pos, n].copy_to(slice[0, n])
    @pos += n
    n
  end

  def write(slice : Bytes) : Nil
    raise NotImplementedError.new("write")
  end
end

# The same two chunks with NO `peek`, so `read_head` falls back to `consume_byte`. Both are
# reported: the pair is what says the fallback still answers and what the bulk scan is worth.
class NoPeekIO < IO
  getter pos = 0

  def initialize(@head : Bytes)
  end

  def read(slice : Bytes) : Int32
    n = Math.min(slice.size, @head.size - @pos)
    return 0 if n <= 0
    @head[@pos, n].copy_to(slice[0, n])
    @pos += n
    n
  end

  def write(slice : Bytes) : Nil
    raise NotImplementedError.new("write")
  end
end

# An idle socket to arm. Never read from; the pair's other end just keeps it open.
SOCK_PAIR = UNIXSocket.pair
SOCK_A    = SOCK_PAIR[0]
DEADLINE  = 30.seconds

def deadlined(head : Bytes, detect : Bool = false)
  Http1.read_head(IO::Memory.new(head), deadline: DEADLINE, timeout_sock: SOCK_A, detect_non_http: detect)
end

# Sanity: every path returns the whole head and nothing more.
{REQ_HEAD, RESP_HEAD, BIG_HEAD}.each do |h|
  raise "plain path mismatch" unless Http1.read_head(IO::Memory.new(h)) == h
  raise "deadlined path mismatch" unless deadlined(h) == h
  raise "detect path mismatch" unless deadlined(h, true) == h
end
# The straddle, at every split that cuts the terminator, on BOTH paths. The head is followed
# by a BODY here and the check is on the CONSUMED count, not only the bytes returned: with
# nothing after the head a reader that misses the terminator still ends up with the right
# bytes (EOF stops it in the same place), so a corpus that stops at the boundary cannot fail.
# (`spec/proxy/codec/http1_spec.cr` pins this; here it keeps the two reports below honest
# about which loop each one is timing.)
WITH_BODY = begin
  io = IO::Memory.new
  io.write(REQ_HEAD)
  io << "BODYBYTES"
  io.to_slice
end

(1..4).each do |back|
  at = REQ_HEAD.size - back
  chunked = TwoChunkIO.new(WITH_BODY, at)
  raise "two-chunk mismatch at #{at}" unless Http1.read_head(chunked) == REQ_HEAD
  raise "two-chunk over-read at #{at}" unless chunked.pos == REQ_HEAD.size
  plain = NoPeekIO.new(WITH_BODY)
  raise "no-peek mismatch" unless Http1.read_head(plain) == REQ_HEAD
  raise "no-peek over-read" unless plain.pos == REQ_HEAD.size
end

puts "request head = #{REQ_HEAD.size} bytes, response head = #{RESP_HEAD.size} bytes, big head = #{BIG_HEAD.size} bytes\n\n"

Benchmark.ips do |x|
  x.report("plain    read_head (req 471B)") { Http1.read_head(IO::Memory.new(REQ_HEAD)) }
  x.report("deadline read_head (req 471B)") { deadlined(REQ_HEAD) }
  x.report("deadline read_head +detect   ") { deadlined(REQ_HEAD, true) }
  x.report("deadline read_head (resp 298B)") { deadlined(RESP_HEAD) }
  x.report("deadline read_head (big 1.9KB)") { deadlined(BIG_HEAD) }
  x.report("two-chunk read_head (req 471B)") { Http1.read_head(TwoChunkIO.new(REQ_HEAD, SPLIT_AT)) }
  x.report("no-peek  read_head (req 471B)") { Http1.read_head(NoPeekIO.new(REQ_HEAD)) }
end
