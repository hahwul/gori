require "../spec_helper"

private alias H = Gori::Discover::Headers

describe Gori::Discover::Headers do
  describe ".parse_lines" do
    it "parses Name: Value lines and strips whitespace" do
      H.parse_lines(["Authorization: Bearer t", "X-Env:  staging  "]).should eq(
        [{"Authorization", "Bearer t"}, {"X-Env", "staging"}])
    end

    it "keeps colons in the value (splits on the first one only)" do
      H.parse_lines(["X-Time: 10:30:00"]).should eq([{"X-Time", "10:30:00"}])
    end

    it "drops lines without a colon, an empty name, or an illegal token name" do
      H.parse_lines(["nope", ": value", "Bad Name: v", "X-Ok: y"]).should eq([{"X-Ok", "y"}])
    end

    it "drops a value carrying CR/LF (header-injection guard)" do
      H.parse_lines(["X-Inject: a\r\nEvil: y"]).should be_empty
    end
  end

  describe ".merge" do
    it "emits the Accept/User-Agent defaults with no user headers" do
      H.merge([] of {String, String}).should eq([{"Accept", "*/*"}, {"User-Agent", "gori-discover"}])
    end

    it "replaces a default in place (case-insensitive), keeping the default's casing" do
      H.merge([{"user-agent", "mycrawler"}]).should eq(
        [{"Accept", "*/*"}, {"User-Agent", "mycrawler"}])
    end

    it "appends an extra user header after the defaults" do
      H.merge([{"Authorization", "Bearer t"}]).should eq(
        [{"Accept", "*/*"}, {"User-Agent", "gori-discover"}, {"Authorization", "Bearer t"}])
    end

    it "ignores forced Host/Connection headers from the user" do
      H.merge([{"Host", "evil"}, {"Connection", "keep-alive"}]).should eq(
        [{"Accept", "*/*"}, {"User-Agent", "gori-discover"}])
    end
  end

  describe ".from_flow" do
    it "keeps auth/cookie/UA headers and drops Host + framing headers" do
      head = "GET /x HTTP/1.1\r\n" \
             "Host: h.example\r\n" \
             "Cookie: sid=1\r\n" \
             "Authorization: Bearer t\r\n" \
             "User-Agent: curl/8\r\n" \
             "Content-Length: 5\r\n" \
             "Connection: keep-alive\r\n\r\n"
      H.from_flow(head.to_slice).should eq(
        [{"Cookie", "sid=1"}, {"Authorization", "Bearer t"}, {"User-Agent", "curl/8"}])
    end

    it "returns no headers when the flow carries only framing headers" do
      head = "GET / HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n"
      H.from_flow(head.to_slice).should be_empty
    end
  end
end
