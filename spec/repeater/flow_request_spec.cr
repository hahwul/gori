require "../spec_helper"

describe Gori::Repeater::FlowRequest do
  describe ".build_target / .parse_target" do
    it "omits the default port and round-trips a normal host" do
      t = Gori::Repeater::FlowRequest.build_target("https", "api.test", 443)
      t.should eq("https://api.test")
      Gori::Repeater::FlowRequest.parse_target(t).should eq({"https", "api.test", 443})
    end

    it "keeps a non-default port" do
      t = Gori::Repeater::FlowRequest.build_target("http", "api.test", 8080)
      t.should eq("http://api.test:8080")
      Gori::Repeater::FlowRequest.parse_target(t).should eq({"http", "api.test", 8080})
    end

    it "uses the standard ports for ws and wss targets" do
      Gori::Repeater::FlowRequest.parse_target("ws://api.test/socket").should eq({"ws", "api.test", 80})
      Gori::Repeater::FlowRequest.parse_target("wss://api.test/socket").should eq({"wss", "api.test", 443})
      Gori::Repeater::FlowRequest.build_target("wss", "api.test", 443).should eq("wss://api.test")
    end

    it "brackets an IPv6 literal host so it round-trips (was dropped to host=\"\")" do
      t = Gori::Repeater::FlowRequest.build_target("http", "::1", 80)
      t.should eq("http://[::1]")
      Gori::Repeater::FlowRequest.parse_target(t).should eq({"http", "::1", 80})
    end

    it "brackets an IPv6 literal host with a non-default port" do
      t = Gori::Repeater::FlowRequest.build_target("https", "2001:db8::1", 8443)
      t.should eq("https://[2001:db8::1]:8443")
      Gori::Repeater::FlowRequest.parse_target(t).should eq({"https", "2001:db8::1", 8443})
    end
  end

  describe ".resync_content_length" do
    it "rewrites an existing Content-Length to the actual body length" do
      # body is 10 bytes ("ABCDEFGHIJ") but the header claims 3 — resync corrects it
      wire = "POST /x HTTP/1.1\r\nContent-Length: 3\r\n\r\nABCDEFGHIJ".to_slice
      out = String.new(Gori::Repeater::FlowRequest.resync_content_length(wire))
      out.should eq("POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\nABCDEFGHIJ")
    end

    it "matches the byte length after env expansion grows the body" do
      # a $KEY expands to a longer value → CL must follow
      expanded = Gori::Env.expand_wire("POST /x HTTP/1.1\nContent-Length: 5\n\nvalue-here",
        {"K" => "value-here"}, "$")
      out = String.new(Gori::Repeater::FlowRequest.resync_content_length(expanded))
      out.should contain("Content-Length: 10\r\n")
    end

    it "never adds a header (a GET with no Content-Length is untouched)" do
      wire = "GET /x HTTP/1.1\r\nHost: t\r\n\r\n".to_slice
      Gori::Repeater::FlowRequest.resync_content_length(wire).should eq(wire)
    end

    it "leaves bytes without a CRLFCRLF separator untouched" do
      wire = "GET /x HTTP/1.1\r\nHost: t\r\n".to_slice
      Gori::Repeater::FlowRequest.resync_content_length(wire).should eq(wire)
    end
  end

  describe ".retarget_version_line" do
    it "downgrades an h2-captured request line to HTTP/1.1 for the verbatim h1 send" do
      Gori::Repeater::FlowRequest.retarget_version_line("GET /a HTTP/2", false).should eq("GET /a HTTP/1.1")
    end

    it "upgrades an h1 request line to HTTP/2" do
      Gori::Repeater::FlowRequest.retarget_version_line("POST /a HTTP/1.1", true).should eq("POST /a HTTP/2")
    end

    it "no-ops (nil) when the version already matches the transport" do
      Gori::Repeater::FlowRequest.retarget_version_line("GET /a HTTP/1.1", false).should be_nil
      Gori::Repeater::FlowRequest.retarget_version_line("GET /a HTTP/2", true).should be_nil
    end

    it "bounds the version by the LAST space, tolerating a raw space in the target" do
      Gori::Repeater::FlowRequest.retarget_version_line("GET /a b HTTP/2", false).should eq("GET /a b HTTP/1.1")
    end

    it "leaves a line that isn't a recognizable request line alone (nil)" do
      Gori::Repeater::FlowRequest.retarget_version_line("not a request line", false).should be_nil
      Gori::Repeater::FlowRequest.retarget_version_line("GET /a", false).should be_nil
    end
  end

  describe ".downgrade_version_line" do
    it "rewrites a version an HTTP/1.x connection cannot carry" do
      Gori::Repeater::FlowRequest.downgrade_version_line("GET /a HTTP/2").should eq("GET /a HTTP/1.1")
      Gori::Repeater::FlowRequest.downgrade_version_line("POST /a HTTP/2.0").should eq("POST /a HTTP/1.1")
      Gori::Repeater::FlowRequest.downgrade_version_line("GET /a HTTP/3").should eq("GET /a HTTP/1.1")
    end

    # It runs unasked on every send, so — unlike `retarget_version_line`, which backs the
    # explicit ^V toggle — it must leave a version the operator meant alone.
    it "leaves every other version alone (nil)" do
      ["GET /a HTTP/1.1", "GET /a HTTP/1.0", "GET /a HTTP/0.9", "GET /a HTTP/9.9",
       "GET /a", "not a request line", "GET /a http/2"].each do |line|
        Gori::Repeater::FlowRequest.downgrade_version_line(line).should be_nil
      end
    end

    it "bounds the version by the LAST space, tolerating a raw space in the target" do
      Gori::Repeater::FlowRequest.downgrade_version_line("GET /a b HTTP/2").should eq("GET /a b HTTP/1.1")
    end
  end

  describe ".normalize_multipart_body" do
    it "restores the CRLF delimiters a multipart body needs" do
      raw = "POST /u HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=B\r\n\r\n--B\nX: 1\n\nhi\n--B--\n".to_slice
      String.new(Gori::Repeater::FlowRequest.normalize_multipart_body(raw))
        .should eq("POST /u HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=B\r\n\r\n--B\r\nX: 1\r\n\r\nhi\r\n--B--\r\n")
    end

    it "is idempotent on a body that already has CRLF" do
      raw = "POST /u HTTP/1.1\r\nContent-Type: multipart/mixed; boundary=B\r\n\r\n--B\r\n\r\nhi\r\n--B--\r\n".to_slice
      Gori::Repeater::FlowRequest.normalize_multipart_body(raw).should eq(raw)
    end

    it "matches the header name and media type case-insensitively" do
      raw = "POST /u HTTP/1.1\r\ncontent-type: MULTIPART/Form-Data; boundary=B\r\n\r\n--B\n--B--\n".to_slice
      String.new(Gori::Repeater::FlowRequest.normalize_multipart_body(raw)).should end_with("--B\r\n--B--\r\n")
    end

    # A bare 0x0A in any other body is a BYTE, not a line ending — this is the one media
    # type that opts out of `Env.expand_wire`'s head-only rule.
    it "leaves every other body untouched" do
      [
        "POST /x HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{\n\"a\":1\n}",
        "POST /x HTTP/1.1\r\nContent-Type: application/octet-stream\r\n\r\n\x01\n\x02",
        "POST /x HTTP/1.1\r\n\r\nno content-type\nhere",
        "GET /x HTTP/1.1\r\nContent-Type: multipart/form-data\r\n\r\n", # head-only: no body to touch
        "GET /x HTTP/1.1\r\nContent-Type: multipart/form-data",         # not even a separator
      ].each do |text|
        raw = text.to_slice
        Gori::Repeater::FlowRequest.normalize_multipart_body(raw).should eq(raw)
      end
    end

    # A header VALUE that merely mentions multipart doesn't make the body one.
    it "keys on the Content-Type header, not on the text anywhere" do
      raw = "POST /x HTTP/1.1\r\nX-Note: multipart/form-data\r\n\r\na\nb".to_slice
      Gori::Repeater::FlowRequest.normalize_multipart_body(raw).should eq(raw)
    end
  end
end
