require "../../spec_helper"

include Gori::Proxy::Codec

describe Gori::Proxy::Codec::CaptureBuffer do
  it "stores everything and stays untruncated under the cap" do
    cap = CaptureBuffer.new(16)
    cap.write("hello".to_slice)
    cap.write(" world".to_slice)
    cap.truncated?.should be_false
    cap.total.should eq(11)
    String.new(cap.to_slice).should eq("hello world")
  end

  it "stores at most `limit` bytes, flags truncation, and counts the TRUE total" do
    cap = CaptureBuffer.new(8)
    cap.write("abcdef".to_slice) # 6 stored
    cap.write("ghijkl".to_slice) # only "gh" fits; the rest is dropped
    cap.write("mno".to_slice)    # all dropped
    cap.truncated?.should be_true
    cap.total.should eq(15)                        # true wire size preserved
    String.new(cap.to_slice).should eq("abcdefgh") # stored bytes capped at 8
  end

  it "tees through Body.stream while bounding the capture (forward stays complete)" do
    body = "X" * 5000
    src = IO::Memory.new(body)
    dst = IO::Memory.new
    cap = CaptureBuffer.new(1000)
    Body.stream(src, dst, BodyFraming::Length, body.bytesize.to_i64, cap).should be_true
    dst.to_slice.size.should eq(5000) # forwarded byte-exact, not capped
    cap.to_slice.size.should eq(1000) # capture bounded
    cap.truncated?.should be_true
    cap.total.should eq(5000)
  end

  it "captures nothing (no backing store) for a bodyless message" do
    cap = CaptureBuffer.new(16)
    cap.total.should eq(0)
    cap.truncated?.should be_false
    cap.to_slice.size.should eq(0) # empty, never allocated
  end

  it "is byte-exact whether or not a length hint presizes the store" do
    body = Bytes.new(300 * 1024) { |i| (i % 251).to_u8 } # exceeds PRESIZE_CAP so growth still runs
    hinted = CaptureBuffer.new(Body::CAPTURE_MAX, body.size.to_i64)
    plain = CaptureBuffer.new(Body::CAPTURE_MAX)
    hinted.write(body)
    plain.write(body)
    hinted.to_slice.should eq(body)
    plain.to_slice.should eq(plain.to_slice) # stable
    hinted.to_slice.should eq(plain.to_slice)
    hinted.truncated?.should be_false
  end

  it "an over-large length hint does not force an over-large allocation, still correct" do
    cap = CaptureBuffer.new(Body::CAPTURE_MAX, 8_i64 * 1024 * 1024) # lies: 8 MiB claimed
    cap.write("tiny".to_slice)
    String.new(cap.to_slice).should eq("tiny")
    cap.total.should eq(4)
  end

  it "keeps an already-returned slice stable across a later write (copy-on-write)" do
    cap = CaptureBuffer.new(64)
    cap.write("first".to_slice)
    published = cap.to_slice
    String.new(published).should eq("first")
    cap.write("-more".to_slice)                      # write after the read
    String.new(published).should eq("first")         # the handed-out slice is untouched
    String.new(cap.to_slice).should eq("first-more") # the live capture kept growing
  end
end

describe "Gori::Proxy::Codec::Body.read_complete" do
  it "reports complete for a fully-delivered Content-Length body" do
    src = IO::Memory.new("hello")
    bytes, complete = Body.read_complete(src, BodyFraming::Length, 5_i64)
    complete.should be_true
    String.new(bytes.not_nil!).should eq("hello")
  end

  it "reports INCOMPLETE for a Content-Length body cut short" do
    src = IO::Memory.new("hi") # only 2 of the framed 10 bytes
    bytes, complete = Body.read_complete(src, BodyFraming::Length, 10_i64)
    complete.should be_false
    String.new(bytes.not_nil!).should eq("hi") # captured what arrived
  end

  it "reports INCOMPLETE for a chunked body missing its 0-terminator" do
    src = IO::Memory.new("5\r\nhello\r\n") # one chunk, no terminating 0-chunk
    _, complete = Body.read_complete(src, BodyFraming::Chunked, 0_i64)
    complete.should be_false
  end

  it "reports complete for a close-delimited body (EOF is the framing)" do
    src = IO::Memory.new("whatever")
    _, complete = Body.read_complete(src, BodyFraming::CloseDelimited, 0_i64)
    complete.should be_true
  end

  it "reports complete with a nil body for None framing" do
    bytes, complete = Body.read_complete(IO::Memory.new(""), BodyFraming::None, 0_i64)
    bytes.should be_nil
    complete.should be_true
  end
end

describe Gori::Proxy::Codec::Body do
  describe "framing detection" do
    it "detects Content-Length on a request" do
      req = Http1.parse_request_head("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\n".to_slice)
      Body.request_framing(req).should eq({BodyFraming::Length, 5_i64})
    end

    it "detects chunked on a request" do
      req = Http1.parse_request_head("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".to_slice)
      Body.request_framing(req).should eq({BodyFraming::Chunked, 0_i64})
    end

    it "treats a bare GET as having no body" do
      req = Http1.parse_request_head("GET / HTTP/1.1\r\nHost: a\r\n\r\n".to_slice)
      Body.request_framing(req).should eq({BodyFraming::None, 0_i64})
    end

    it "treats 204/304/HEAD responses as bodiless" do
      r204 = Http1.parse_response_head("HTTP/1.1 204 No Content\r\n\r\n".to_slice)
      Body.response_framing(r204, "GET").should eq({BodyFraming::None, 0_i64})

      ok = Http1.parse_response_head("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n".to_slice)
      Body.response_framing(ok, "HEAD").should eq({BodyFraming::None, 0_i64})
    end

    it "falls back to close-delimited when a response has neither CL nor chunked" do
      resp = Http1.parse_response_head("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice)
      Body.response_framing(resp, "GET").should eq({BodyFraming::CloseDelimited, 0_i64})
    end

    it "rejects conflicting Content-Length values (request smuggling)" do
      req = Http1.parse_request_head("POST / HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n".to_slice)
      expect_raises(Gori::Error) { Body.request_framing(req) }
    end

    it "collapses repeated identical Content-Length" do
      req = Http1.parse_request_head("POST / HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\n".to_slice)
      Body.request_framing(req).should eq({BodyFraming::Length, 5_i64})
    end

    it "rejects a negative Content-Length" do
      req = Http1.parse_request_head("POST / HTTP/1.1\r\nContent-Length: -5\r\n\r\n".to_slice)
      expect_raises(Gori::Error) { Body.request_framing(req) }
    end

    it "rejects a Content-Length with a leading + sign (CL desync)" do
      # RFC 7230 §3.3.3: Content-Length is 1*DIGIT. `+5` must be rejected (not framed as 5)
      # — a stricter downstream peer would interpret it differently, a smuggling primitive.
      req = Http1.parse_request_head("POST / HTTP/1.1\r\nContent-Length: +5\r\n\r\n".to_slice)
      expect_raises(Gori::Error) { Body.request_framing(req) }
    end

    it "rejects Transfer-Encoding + Content-Length coexistence (CL.TE/TE.CL smuggling)" do
      req = Http1.parse_request_head("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n".to_slice)
      expect_raises(Gori::Error) { Body.request_framing(req) }
    end

    it "rejects a non-final chunked transfer-coding (TE obfuscation desync)" do
      req = Http1.parse_request_head("POST / HTTP/1.1\r\nTransfer-Encoding: chunked, gzip\r\n\r\n".to_slice)
      expect_raises(Gori::Error) { Body.request_framing(req) }
    end

    it "accepts chunked as the final transfer-coding after another" do
      req = Http1.parse_request_head("POST / HTTP/1.1\r\nTransfer-Encoding: gzip, chunked\r\n\r\n".to_slice)
      Body.request_framing(req).should eq({BodyFraming::Chunked, 0_i64})
    end

    it "rejects a request with a non-chunked Transfer-Encoding (unframeable → TE desync)" do
      # `Transfer-Encoding: gzip` (final coding not chunked) has no reliable body length.
      # A bare fall-through to None would strand the body as the next pipelined request.
      req = Http1.parse_request_head("POST / HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n".to_slice)
      expect_raises(Gori::Error) { Body.request_framing(req) }
    end

    it "rejects a non-chunked TE request even with a Content-Length (no CL fallback)" do
      # TE outranks CL (RFC 7230 §3.3.3); a non-chunked TE must not silently be framed by CL.
      req = Http1.parse_request_head("POST / HTTP/1.1\r\nTransfer-Encoding: gzip\r\nContent-Length: 5\r\n\r\n".to_slice)
      expect_raises(Gori::Error) { Body.request_framing(req) }
    end

    it "rejects a request with whitespace before a header colon (TE hidden from framing → smuggling)" do
      # `Transfer-Encoding : chunked` (space before colon) is invisible to the exact-match TE
      # lookup, so the proxy would frame by CL and forward the head to a lenient backend that
      # reads chunked — a CL.TE desync. Reject it like an explicit CL+TE conflict.
      req = Http1.parse_request_head(
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding : chunked\r\n\r\n".to_slice)
      expect_raises(Gori::Error) { Body.request_framing(req) }
    end

    it "rejects a request using an obs-fold header continuation line" do
      # An obs-folded `Transfer-Encoding:\r\n chunked` hides the value from the framing lookup
      # while a lenient backend unfolds it — RFC 7230 §3.2.4 forbids obs-fold in requests.
      req = Http1.parse_request_head(
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding:\r\n chunked\r\n\r\n".to_slice)
      expect_raises(Gori::Error) { Body.request_framing(req) }
    end

    it "accepts an ordinary request whose header value contains a colon or spaces" do
      # The rejection targets whitespace BEFORE the colon / obs-fold only — a normal header
      # (colon in the value, spaces after the colon) must still frame cleanly.
      req = Http1.parse_request_head(
        "GET / HTTP/1.1\r\nHost: example.com:443\r\nUser-Agent: Mozilla/5.0 (X)\r\n\r\n".to_slice)
      Body.request_framing(req).should eq({BodyFraming::None, 0_i64})
      Http1.obfuscated_header?("GET / HTTP/1.1\r\nHost: example.com:443\r\n\r\n".to_slice).should be_false
      Http1.obfuscated_header?("GET / HTTP/1.1\r\nX : y\r\n\r\n".to_slice).should be_true
    end

    it "rejects a bare LF used to hide a header from the CRLF-only framing scan" do
      # `Foo: bar\nTransfer-Encoding: chunked` folds into one header for the CRLF-only
      # parser, but an LF-lenient backend still reads the hidden TE — a smuggling vector.
      Http1.obfuscated_header?(
        "GET / HTTP/1.1\r\nHost: h\r\nFoo: bar\nTransfer-Encoding: chunked\r\n\r\n".to_slice).should be_true
      req = Http1.parse_request_head(
        "POST / HTTP/1.1\r\nHost: h\r\nFoo: bar\nTransfer-Encoding: chunked\r\n\r\n".to_slice)
      expect_raises(Gori::Error) { Body.request_framing(req) }
    end

    it "leaves a response with a non-chunked Transfer-Encoding as close-delimited (not rejected)" do
      # Responses may legitimately be close-delimited under a non-chunked TE — only the
      # request path (which must know the body boundary to keep-alive) rejects.
      resp = Http1.parse_response_head("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n".to_slice)
      Body.response_framing(resp, "GET").should eq({BodyFraming::CloseDelimited, 0_i64})
    end

    it "frames a response with a non-chunked TE AND a Content-Length as close-delimited, NOT by CL" do
      # RFC 7230 §3.3.3 rule 3: TE outranks CL. Framing by CL would read only CL bytes and
      # leave the rest on the wire to misframe the next response on a reused upstream (desync).
      resp = Http1.parse_response_head("HTTP/1.1 200 OK\r\nTransfer-Encoding: identity\r\nContent-Length: 3\r\n\r\n".to_slice)
      Body.response_framing(resp, "GET").should eq({BodyFraming::CloseDelimited, 0_i64})
    end
  end

  describe ".stream" do
    it "aborts a chunked body on a malformed chunk size (no fabricated terminator → desync)" do
      src = IO::Memory.new("zz\r\ndata") # "zz" is not valid hex
      dst = IO::Memory.new
      Body.stream(src, dst, BodyFraming::Chunked, 0_i64, IO::Memory.new).should be_false
    end

    it "aborts a chunked body whose size line overruns the cap without an LF (desync)" do
      # A chunk-size line of >MAX_LINE_BYTES hex digits and no terminating LF: read_crlf_line
      # caps at 64 KiB and used to hand the partial to parse_chunk_size, which read an all-'0'
      # prefix as a 0-length terminating chunk — completing the body while the line remainder
      # stayed on the wire to misframe the next keep-alive message. An unterminated size line
      # must abort (→ close) instead.
      src = IO::Memory.new("#{"0" * (65 * 1024)}\r\n\r\nNEXT")
      dst = IO::Memory.new
      Body.stream(src, dst, BodyFraming::Chunked, 0_i64, IO::Memory.new).should be_false
    end

    it "copies a Content-Length body byte-exact to both dst and tee" do
      src = IO::Memory.new("hello world!!") # 13 bytes, but only 5 are the body
      dst = IO::Memory.new
      tee = IO::Memory.new

      Body.stream(src, dst, BodyFraming::Length, 5_i64, tee)

      dst.to_s.should eq("hello")
      tee.to_s.should eq("hello")
      src.gets_to_end.should eq(" world!!") # remainder left for the next read
    end

    it "passes chunked bodies through preserving wire framing (P7), and stops at terminator" do
      wire = "4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\nNEXT"
      src = IO::Memory.new(wire)
      dst = IO::Memory.new
      tee = IO::Memory.new

      Body.stream(src, dst, BodyFraming::Chunked, 0_i64, tee)

      expected = "4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n"
      dst.to_s.should eq(expected) # exact chunk framing preserved
      tee.to_s.should eq(expected)
      src.gets_to_end.should eq("NEXT") # next request not consumed
    end

    it "forwards a real chunked trailer and stops at the blank line" do
      wire = "0\r\nX-Checksum: abc\r\n\r\nNEXT"
      src = IO::Memory.new(wire)
      dst = IO::Memory.new
      Body.stream(src, dst, BodyFraming::Chunked, 0_i64, IO::Memory.new).should be_true
      dst.to_s.should eq("0\r\nX-Checksum: abc\r\n\r\n") # trailer preserved, blank line ends it
      src.gets_to_end.should eq("NEXT")
    end

    it "does NOT mistake a 1-char bare-LF trailer line for the terminating blank line (keep-alive desync)" do
      # "A\n" is 2 bytes like "\r\n" but is NOT blank — a size-only blank check used
      # to stop here, leaving the REAL blank line on the wire to desync the next
      # keep-alive request. Must consume through the real blank line instead.
      wire = "0\r\nA\n\r\nNEXT"
      src = IO::Memory.new(wire)
      dst = IO::Memory.new
      Body.stream(src, dst, BodyFraming::Chunked, 0_i64, IO::Memory.new).should be_true
      dst.to_s.should eq("0\r\nA\n\r\n") # forwarded through the genuine blank line
      src.gets_to_end.should eq("NEXT")  # next message starts clean — no orphaned CRLF
    end

    it "aborts a chunked body whose trailer section overruns the cap (memory/CPU DoS guard)" do
      # terminating 0-chunk, then an unbounded trailer that never sends the blank line
      src = IO::Memory.new("0\r\n#{"a" * (300 * 1024)}")
      dst = IO::Memory.new
      Body.stream(src, dst, BodyFraming::Chunked, 0_i64, IO::Memory.new).should be_false
    end

    it "copies a close-delimited body until EOF" do
      src = IO::Memory.new("streamed-to-the-end")
      dst = IO::Memory.new
      tee = IO::Memory.new

      Body.stream(src, dst, BodyFraming::CloseDelimited, 0_i64, tee)

      dst.to_s.should eq("streamed-to-the-end")
      tee.to_s.should eq("streamed-to-the-end")
    end

    it "tolerates premature EOF on a Content-Length body (captures what arrived)" do
      src = IO::Memory.new("abc") # claims 10 but only 3 arrive
      dst = IO::Memory.new
      tee = IO::Memory.new

      Body.stream(src, dst, BodyFraming::Length, 10_i64, tee)

      tee.to_s.should eq("abc")
    end
  end
end

describe "Body.stream reused buffers (perf: per-connection copy buffer + chunked size-line scratch)" do
  it "streams two sequential bodies through ONE shared copy buffer byte-exactly" do
    # The connection-lifetime buffer ClientConn threads in is reused across the request body
    # then the response body; they run sequentially, so reuse must not corrupt either.
    buf = Bytes.new(Body::BUFSIZE)
    a = "A" * 200_000 # larger than BUFSIZE → multiple copy iterations
    src_a, dst_a, tee_a = IO::Memory.new(a), IO::Memory.new, IO::Memory.new
    Body.stream(src_a, dst_a, BodyFraming::Length, a.bytesize.to_i64, tee_a, buf).should be_true
    b = "B" * 130_000
    src_b, dst_b, tee_b = IO::Memory.new(b), IO::Memory.new, IO::Memory.new
    Body.stream(src_b, dst_b, BodyFraming::Length, b.bytesize.to_i64, tee_b, buf).should be_true
    dst_a.to_s.should eq(a); tee_a.to_s.should eq(a)
    dst_b.to_s.should eq(b); tee_b.to_s.should eq(b)
  end

  it "forwards a MANY-chunk body byte-exactly with the reused size-line scratch + copy buffer" do
    wire = String.build do |s|
      500.times { s << "5\r\nhello\r\n" } # 500 size-line reads share one scratch IO::Memory
      s << "0\r\nX-Sum: z\r\n\r\nNEXT"
    end
    src, dst, tee = IO::Memory.new(wire), IO::Memory.new, IO::Memory.new
    Body.stream(src, dst, BodyFraming::Chunked, 0_i64, tee, Bytes.new(Body::BUFSIZE)).should be_true
    expected = wire[0, wire.size - "NEXT".size]
    dst.to_s.should eq(expected) # wire form forwarded byte-exact (framing + trailer intact)
    tee.to_s.should eq(expected)
    src.gets_to_end.should eq("NEXT") # next keep-alive message not consumed
  end
end

describe Gori::Proxy::Codec::ContentDecode do
  head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".to_slice

  it "de-chunks a conformant CRLF chunked body" do
    body = "5\r\nHELLO\r\n6\r\n WORLD\r\n0\r\n\r\n".to_slice
    decoded, _ = ContentDecode.decode(head, body)
    String.new(decoded.not_nil!).should eq("HELLO WORLD")
  end

  it "de-chunks a bare-LF chunked body without misaligning later chunks" do
    # Non-conformant lone-LF delimiters: the old blind 2-byte skip ate the first byte
    # of the next chunk-size line, dropping/garbling every chunk after the first.
    body = "5\nHELLO\n6\n WORLD\n0\n\n".to_slice
    decoded, _ = ContentDecode.decode(head, body)
    String.new(decoded.not_nil!).should eq("HELLO WORLD")
  end
end
