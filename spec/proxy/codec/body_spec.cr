require "../../spec_helper"

include Gori::Proxy::Codec

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
  end

  describe ".stream" do
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
