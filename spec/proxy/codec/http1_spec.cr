require "../../spec_helper"

include Gori::Proxy::Codec

private def bytes(str : String) : Bytes
  str.to_slice
end

describe Gori::Proxy::Codec::Http1 do
  describe ".parse_request_head" do
    it "parses request-line and headers as projections" do
      raw = bytes("GET /search?q=test HTTP/1.1\r\nHost: acme.test\r\nAccept: */*\r\n\r\n")
      req = Http1.parse_request_head(raw)

      req.method.should eq("GET")
      req.target.should eq("/search?q=test")
      req.version.should eq("HTTP/1.1")
      req.host?.should eq("acme.test")
      req.headers.get?("accept").should eq("*/*") # case-insensitive lookup
      req.malformed?.should be_false
    end

    it "preserves byte-exact raw_head (P7) so serialize == original" do
      raw = bytes("POST /api HTTP/1.1\r\nHost: x\r\nX-Weird:  spaced  \r\nContent-Length: 0\r\n\r\n")
      req = Http1.parse_request_head(raw)

      req.raw_head.should eq(raw)
      Http1.serialize_head(req).should eq(raw)
    end

    it "preserves header order and original casing in the projection" do
      raw = bytes("GET / HTTP/1.1\r\nHost: a\r\nX-Foo: 1\r\nx-foo: 2\r\n\r\n")
      req = Http1.parse_request_head(raw)

      names = req.headers.entries.map(&.name)
      names.should eq(["Host", "X-Foo", "x-foo"])
      req.headers.get_all("X-Foo").should eq(["1", "2"]) # both, wire order
      req.headers.get?("x-foo").should eq("2")           # last wins
    end

    it "captures-not-rejects a malformed request-line (P7)" do
      raw = bytes("GET\r\nHost: a\r\n\r\n") # only one token on the start line
      req = Http1.parse_request_head(raw)

      req.malformed?.should be_true
      req.raw_head.should eq(raw) # truth preserved regardless
    end
  end

  describe ".parse_response_head" do
    it "parses status-line and headers" do
      raw = bytes("HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\n")
      resp = Http1.parse_response_head(raw)

      resp.version.should eq("HTTP/1.1")
      resp.status.should eq(404)
      resp.reason.should eq("Not Found")
      resp.headers.get?("content-length").should eq("9")
      resp.malformed?.should be_false
    end

    it "handles an empty reason phrase" do
      raw = bytes("HTTP/1.1 204 \r\n\r\n")
      resp = Http1.parse_response_head(raw)
      resp.status.should eq(204)
      resp.reason.should eq("")
    end
  end

  describe ".read_head" do
    it "reads exactly up to and including CRLFCRLF, leaving the body unread" do
      io = IO::Memory.new("GET / HTTP/1.1\r\nHost: a\r\n\r\nBODYBYTES")
      head = Http1.read_head(io).not_nil!

      String.new(head).should eq("GET / HTTP/1.1\r\nHost: a\r\n\r\n")
      io.gets_to_end.should eq("BODYBYTES") # nothing over-read
    end

    it "returns nil on clean EOF" do
      Http1.read_head(IO::Memory.new("")).should be_nil
    end
  end
end
