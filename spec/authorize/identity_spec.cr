require "../spec_helper"
require "../../src/gori/authorize/identity"

private alias Identity = Gori::Authorize::Identity

private def head(*lines : String) : Bytes
  (lines.join("\r\n") + "\r\n\r\n").to_slice
end

describe Gori::Authorize do
  describe ".overlay_head" do
    it "sets a header that is absent by appending it (upsert)" do
      h = head("GET /admin HTTP/1.1", "Host: api.example.com")
      id = Identity.new("admin", set_headers: [{"Cookie", "session=AAA"}])
      out = String.new(Gori::Authorize.overlay_head(h, id))
      out.should eq("GET /admin HTTP/1.1\r\nHost: api.example.com\r\nCookie: session=AAA\r\n\r\n")
    end

    it "replaces an existing header case-insensitively, keeping its original casing" do
      h = head("GET / HTTP/1.1", "Host: x", "cookie: session=OLD")
      id = Identity.new("admin", set_headers: [{"Cookie", "session=NEW"}])
      out = String.new(Gori::Authorize.overlay_head(h, id))
      out.should eq("GET / HTTP/1.1\r\nHost: x\r\ncookie: session=NEW\r\n\r\n")
    end

    it "removes every matching header, case-insensitively" do
      h = head("GET / HTTP/1.1", "Host: x", "Cookie: a", "Authorization: Bearer t")
      id = Identity.new("anon", remove_headers: ["cookie", "authorization"])
      out = String.new(Gori::Authorize.overlay_head(h, id))
      out.should eq("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
    end

    it "runs removes before sets, so set wins when an identity does both" do
      h = head("GET / HTTP/1.1", "Host: x", "Cookie: old")
      id = Identity.new("swap", remove_headers: ["Cookie"], set_headers: [{"Cookie", "new"}])
      out = String.new(Gori::Authorize.overlay_head(h, id))
      out.should eq("GET / HTTP/1.1\r\nHost: x\r\nCookie: new\r\n\r\n")
    end

    it "leaves the head byte-exact for a passthrough identity" do
      h = head("GET / HTTP/1.1", "Host: x", "Cookie: keep")
      Gori::Authorize.overlay_head(h, Identity.as_captured).should eq(h)
    end

    it "does not refuse operator-authored CR/LF-free values (verbatim, provenance rule)" do
      h = head("GET / HTTP/1.1", "Host: x")
      id = Identity.new("odd", set_headers: [{"X-Role", "admin superuser"}])
      out = String.new(Gori::Authorize.overlay_head(h, id))
      out.includes?("X-Role: admin superuser").should be_true
    end
  end

  describe ".overlay_request" do
    it "keeps the body untouched and appends it after the overlaid head" do
      h = head("POST /x HTTP/1.1", "Host: x", "Content-Length: 5")
      body = "hello".to_slice
      id = Identity.new("u", set_headers: [{"Cookie", "s=1"}])
      out = String.new(Gori::Authorize.overlay_request(h, body, id))
      out.should eq("POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nCookie: s=1\r\n\r\nhello")
    end

    it "handles a nil body" do
      h = head("GET / HTTP/1.1", "Host: x")
      id = Identity.new("u", remove_headers: ["Cookie"])
      res_bytes = Gori::Authorize.overlay_request(h, nil, id)
      String.new(res_bytes).should eq("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
    end
  end

  describe ".overlay_wire" do
    it "overlays the head of a wire request and leaves the body byte-exact" do
      wire = "POST /x HTTP/1.1\r\nHost: x\r\nCookie: old\r\n\r\nbody-bytes".to_slice
      id = Identity.new("u", remove_headers: ["Cookie"])
      String.new(Gori::Authorize.overlay_wire(wire, id))
        .should eq("POST /x HTTP/1.1\r\nHost: x\r\n\r\nbody-bytes")
    end

    it "does NOT let a CRLFCRLF inside the body move the head boundary" do
      # The earliest blank line wins — a multipart/captured body carrying its own CRLFCRLF
      # would otherwise put the header ops inside the body.
      wire = "POST /x HTTP/1.1\r\nHost: x\r\n\r\npart\r\n\r\nmore".to_slice
      id = Identity.new("u", set_headers: [{"X-Id", "user"}])
      res = String.new(Gori::Authorize.overlay_wire(wire, id))
      res.should eq("POST /x HTTP/1.1\r\nHost: x\r\nX-Id: user\r\n\r\npart\r\n\r\nmore")
    end

    it "treats a terminator-less buffer as all head" do
      wire = "GET / HTTP/1.1\r\nHost: x".to_slice
      id = Identity.new("u", set_headers: [{"A", "b"}])
      String.new(Gori::Authorize.overlay_wire(wire, id)).should contain("A: b")
    end

    it "leaves a passthrough identity's bytes identical" do
      wire = "GET / HTTP/1.1\r\nHost: x\r\n\r\n".to_slice
      Gori::Authorize.overlay_wire(wire, Identity.as_captured).should eq(wire)
    end

    it "keeps an origin-form request line intact (the replay path's rewrite survives)" do
      # Regression: the engine used to overlay `FlowDetail#request_head` directly, so a
      # proxy-captured absolute-form line ("GET http://h/p") reached the origin as a path of
      # its own and every identity got the catch-all page.
      wire = "GET /orders HTTP/1.1\r\nHost: h\r\nCookie: s=1\r\n\r\n".to_slice
      id = Identity.new("anon", remove_headers: ["Cookie"])
      String.new(Gori::Authorize.overlay_wire(wire, id)).lines.first.should eq("GET /orders HTTP/1.1")
    end
  end

  describe Identity do
    it "as_captured is a passthrough baseline" do
      id = Identity.as_captured
      id.passthrough?.should be_true
      id.baseline?.should be_true
    end
  end
end
