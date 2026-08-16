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

  describe "persistence" do
    it "round-trips a set of identities" do
      ids = [
        Identity.as_captured("as-captured"),
        Identity.new("admin", set_headers: [{"Cookie", "session=ADMIN"}, {"X-Role", "admin"}]),
        Identity.new("anonymous", remove_headers: ["Cookie", "Authorization"]),
      ]
      back = Gori::Authorize.parse_json(Gori::Authorize.serialize(ids))
      back.size.should eq(3)
      back[0].name.should eq("as-captured")
      back[0].baseline?.should be_true
      back[1].set_headers.should eq([{"Cookie", "session=ADMIN"}, {"X-Role", "admin"}])
      back[1].baseline?.should be_false
      back[2].remove_headers.should eq(["Cookie", "Authorization"])
    end

    # This is the whole reason the reader is written the way it is: identities are read on the
    # project-open path, so a raise here would fail the project open over one settings row.
    it "returns an empty list for unparseable JSON instead of raising" do
      Gori::Authorize.parse_json("{not json at all").should be_empty
      Gori::Authorize.parse_json("").should be_empty
      Gori::Authorize.parse_json(nil).should be_empty
      Gori::Authorize.parse_json(%({"an":"object, not an array"})).should be_empty
    end

    it "skips a malformed entry and keeps the rest" do
      raw = %([{"nope":1},{"name":""},{"name":"good","set":[],"remove":[]}])
      ids = Gori::Authorize.parse_json(raw)
      ids.map(&.name).should eq(["good"])
    end

    it "skips malformed header rows inside an otherwise good identity" do
      raw = %([{"name":"x","set":[{"name":"A","value":"1"},{"name":"B"},"junk"],"remove":["C","",7]}])
      id = Gori::Authorize.parse_json(raw).first
      id.set_headers.should eq([{"A", "1"}])
      id.remove_headers.should eq(["C"])
    end

    it "defaults a missing baseline flag to false" do
      Gori::Authorize.parse_json(%([{"name":"x"}])).first.baseline?.should be_false
    end
  end

  describe Identity do
    it "summarises by header NAME, never by value (a list must not paint credentials)" do
      id = Identity.new("admin", set_headers: [{"Cookie", "session=SECRET"}])
      id.summary.should eq("sets Cookie")
      id.summary.should_not contain("SECRET")

      Identity.new("anon", remove_headers: ["Cookie", "Authorization"]).summary
        .should eq("drops Cookie, Authorization")
      Identity.as_captured.summary.should eq("as captured")
    end

    it "moves the baseline flag without touching anything else" do
      id = Identity.new("admin", set_headers: [{"Cookie", "x"}])
      promoted = id.with_baseline(true)
      promoted.baseline?.should be_true
      promoted.name.should eq("admin")
      promoted.set_headers.should eq(id.set_headers)
      id.baseline?.should be_false # the original is untouched (a struct)
    end

    it "as_captured is a passthrough baseline" do
      id = Identity.as_captured
      id.passthrough?.should be_true
      id.baseline?.should be_true
    end
  end
end
