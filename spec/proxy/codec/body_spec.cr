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
  end

  describe ".stream" do
    it "aborts a chunked body on a malformed chunk size (no fabricated terminator → desync)" do
      src = IO::Memory.new("zz\r\ndata") # "zz" is not valid hex
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
