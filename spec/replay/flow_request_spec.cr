require "../spec_helper"

describe Gori::Replay::FlowRequest do
  describe ".build_target / .parse_target" do
    it "omits the default port and round-trips a normal host" do
      t = Gori::Replay::FlowRequest.build_target("https", "api.test", 443)
      t.should eq("https://api.test")
      Gori::Replay::FlowRequest.parse_target(t).should eq({"https", "api.test", 443})
    end

    it "keeps a non-default port" do
      t = Gori::Replay::FlowRequest.build_target("http", "api.test", 8080)
      t.should eq("http://api.test:8080")
      Gori::Replay::FlowRequest.parse_target(t).should eq({"http", "api.test", 8080})
    end

    it "brackets an IPv6 literal host so it round-trips (was dropped to host=\"\")" do
      t = Gori::Replay::FlowRequest.build_target("http", "::1", 80)
      t.should eq("http://[::1]")
      Gori::Replay::FlowRequest.parse_target(t).should eq({"http", "::1", 80})
    end

    it "brackets an IPv6 literal host with a non-default port" do
      t = Gori::Replay::FlowRequest.build_target("https", "2001:db8::1", 8443)
      t.should eq("https://[2001:db8::1]:8443")
      Gori::Replay::FlowRequest.parse_target(t).should eq({"https", "2001:db8::1", 8443})
    end
  end

  describe ".resync_content_length" do
    it "rewrites an existing Content-Length to the actual body length" do
      # body is 10 bytes ("ABCDEFGHIJ") but the header claims 3 — resync corrects it
      wire = "POST /x HTTP/1.1\r\nContent-Length: 3\r\n\r\nABCDEFGHIJ".to_slice
      out = String.new(Gori::Replay::FlowRequest.resync_content_length(wire))
      out.should eq("POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\nABCDEFGHIJ")
    end

    it "matches the byte length after env expansion grows the body" do
      # a $KEY expands to a longer value → CL must follow
      expanded = Gori::Env.expand_wire("POST /x HTTP/1.1\nContent-Length: 5\n\nvalue-here",
        {"K" => "value-here"}, "$")
      out = String.new(Gori::Replay::FlowRequest.resync_content_length(expanded))
      out.should contain("Content-Length: 10\r\n")
    end

    it "never adds a header (a GET with no Content-Length is untouched)" do
      wire = "GET /x HTTP/1.1\r\nHost: t\r\n\r\n".to_slice
      Gori::Replay::FlowRequest.resync_content_length(wire).should eq(wire)
    end

    it "leaves bytes without a CRLFCRLF separator untouched" do
      wire = "GET /x HTTP/1.1\r\nHost: t\r\n".to_slice
      Gori::Replay::FlowRequest.resync_content_length(wire).should eq(wire)
    end
  end
end
