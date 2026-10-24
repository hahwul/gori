require "./spec_helper"

# One executable copy of a check an audit otherwise does by hand each round: a request the
# operator asks gori to send as written reaches the socket byte-for-byte, through the seam all
# three surfaces share (`Repeater::Plan.build` + `Sender`, the bytes `gori run send --verbatim`,
# MCP `send_request{raw}` and a verbatim Repeater tab all build). Malformed input IS the
# payload (AGENTS.md P7): the day gori "corrects" one of these is the day it stops being a
# proxy for the test the operator wrote.
#
# The corpus is ordinary requests AND the unusual-but-legal shapes a security test turns on —
# each reduced to the one property that matters, its bytes. A byte that differs on the wire is
# the whole failure; there is nothing else to assert.

# Records the FULL request — head plus whatever body framing carried — then answers and closes.
private class ByteOrigin
  getter port : Int32
  getter requests = [] of Bytes

  def initialize(@server : TCPServer = TCPServer.new("127.0.0.1", 0))
    @port = @server.local_address.port
  end

  def serve(count : Int32) : Nil
    spawn do
      count.times do
        break unless conn = @server.accept?
        @requests << drain(conn)
        conn << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        conn.flush
        conn.close
      rescue
      end
    rescue
    ensure
      @server.close rescue nil
    end
  end

  # Everything the client wrote, read as raw bytes until it stops (a short idle, since the
  # client holds the socket for our reply). No parsing: the point is to capture framing gori
  # might otherwise normalize, not to understand it.
  private def drain(conn : TCPSocket) : Bytes
    conn.read_timeout = 300.milliseconds
    buf = IO::Memory.new
    chunk = Bytes.new(4096)
    loop do
      n = conn.read(chunk)
      break if n == 0
      buf.write(chunk[0, n])
    rescue IO::TimeoutError
      break
    end
    buf.to_slice
  end

  def close : Nil
    @server.close rescue nil
  end
end

# The verbatim Repeater plan, exactly as `gori run send --verbatim` / MCP `send_request{raw}`
# build it: the surface already expanded (nothing here does), no auto Content-Length, field
# case kept. `plan.send` dials the origin and writes these bytes.
private def send_verbatim(bytes : Bytes, port : Int32) : Nil
  plan = Gori::Repeater::Plan.build(
    Gori::Repeater::PlanOptions.new([bytes],
      expand_request: false, expand_bindings: false, auto_content_length: false,
      preserve_field_case: true, target: "http://127.0.0.1:#{port}"),
    ungated_outbound)
  plan.send.error.should be_nil
end

# head + body, LF-authored, with the separator spelled as asked. Origin-form target on every
# entry so the plan builds; the shape under test lives in the header block and the body.
private CORPUS = {
  "ordinary GET"                                            => "GET /x HTTP/1.1\r\nHost: h.test\r\nAccept: */*\r\n\r\n",
  "ordinary POST with a body"                               => "POST /x HTTP/1.1\r\nHost: h.test\r\nContent-Length: 5\r\n\r\nhello",
  "two Content-Length headers"                              => "POST /x HTTP/1.1\r\nHost: h.test\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello!",
  "Content-Length beside Transfer-Encoding"                 => "POST /x HTTP/1.1\r\nHost: h.test\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
  "a Transfer-Encoding value with a space before the colon" => "POST /x HTTP/1.1\r\nHost: h.test\r\nTransfer-Encoding : chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
  "a Content-Length disagreeing with the body"              => "POST /x HTTP/1.1\r\nHost: h.test\r\nContent-Length: 2\r\n\r\nhello",
  "a bare-LF header line in a CRLF head"                    => "GET /x HTTP/1.1\r\nHost: h.test\nX-A: 1\r\n\r\n",
  "a header line with no colon"                             => "GET /x HTTP/1.1\r\nHost: h.test\r\nX-broken\r\n\r\n",
  "a space before a header colon"                           => "GET /x HTTP/1.1\r\nHost: h.test\r\nX-A : 1\r\n\r\n",
  "two Host headers"                                        => "GET /x HTTP/1.1\r\nHost: a.test\r\nHost: b.test\r\n\r\n",
  "a high byte in a header value"                           => "GET /x HTTP/1.1\r\nHost: h.test\r\nX-A: \xff\xfe\r\n\r\n",
  "a NUL in a header value"                                 => "GET /x HTTP/1.1\r\nHost: h.test\r\nX-A: a\x00b\r\n\r\n",
  "an unframed body (no CL, no TE)"                         => "POST /x HTTP/1.1\r\nHost: h.test\r\n\r\nhello",
  "a lowercase method"                                      => "get /x HTTP/1.1\r\nHost: h.test\r\n\r\n",
  "bytes after a chunked terminator"                        => "POST /x HTTP/1.1\r\nHost: h.test\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\nGET /y HTTP/1.1\r\n\r\n",
}

describe "a verbatim send reaches the socket byte-for-byte" do
  CORPUS.each do |name, raw|
    it name do
      origin = ByteOrigin.new
      origin.serve(1)
      begin
        send_verbatim(raw.to_slice, origin.port)
        origin.requests.size.should eq(1)
        String.new(origin.requests[0]).should eq(raw)
      ensure
        origin.close
      end
    end
  end
end

# The Fuzzer's own verbatim route (`gori run fuzz --verbatim`, MCP `fuzz_start{verbatim}`): the
# template's fixed bytes are the baseline the sweep sends, unchanged. No network: the baseline
# request is the byte assertion.
describe "a verbatim Fuzzer template keeps its bytes" do
  CORPUS.each do |name, raw|
    next if raw.includes?('\u0000') # a NUL ends a C string in the §-marker path; not a framing shape
    it name do
      tmpl = raw.sub("/x ", "/x?q=§a§ ") # one marker so it is a valid sweep
      opts = Gori::Fuzz::PlanOptions.new(tmpl, target: "http://h.test",
        sources: [Gori::Fuzz::InlineList.new(["v"]).as(Gori::Fuzz::PayloadSource)], verbatim: true)
      plan = Gori::Fuzz::Plan.build(opts, ungated_outbound)
      # The baseline is the template with the marker rendered to its default; its fixed bytes
      # (everything but the §…§ span) are untouched — no CRLF promotion, no CL resync.
      baseline = String.new(plan.generator.baseline_request)
      baseline.should eq(tmpl.sub("§a§", "a"))
    end
  end
end
