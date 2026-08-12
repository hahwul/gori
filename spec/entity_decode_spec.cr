require "./spec_helper"
require "compress/gzip"

# gori stores the WIRE form of every body and nothing else (P7): chunk framing intact, still
# gzip/br/deflate/zstd compressed. Every DISPLAY-time decoder therefore has to ask for the
# ENTITY first, and the four decode panes did not — each failing in its own way on the same
# flow, while the `p` toggle two keystrokes away pretty-printed the decoded bytes.
private def gzipped(s : String) : Bytes
  io = IO::Memory.new
  Compress::Gzip::Writer.open(io) { |g| g << s }
  io.to_slice
end

private def chunked(s : String) : Bytes
  "#{s.bytesize.to_s(16)}\r\n#{s}\r\n0\r\n\r\n".to_slice
end

private def req_head(*lines : String) : Bytes
  (["POST /graphql HTTP/1.1", "Host: api.test"] + lines.to_a + ["", ""]).join("\r\n").to_slice
end

describe Gori::Entity do
  it "returns an ordinary body unchanged, and says nothing was decoded" do
    body = %({"a":1}).to_slice
    bytes, projected = Gori::Entity.of(req_head("Content-Type: application/json"), body)
    bytes.should eq(body)
    projected.should be_false
  end

  it "returns the raw bytes (not nil) when a declared coding will not decode" do
    head = req_head("Content-Type: application/json", "Content-Encoding: gzip")
    bytes, projected = Gori::Entity.of(head, "not gzip at all".to_slice)
    bytes.should eq("not gzip at all".to_slice)
    projected.should be_false # nothing claims a faithful round-trip over bytes it could not decode
  end

  # The cap is what the JWT pane relies on: it decodes at most `MAX_SCAN + 1` bytes, because
  # `scan_body` refuses a body over `MAX_SCAN` anyway and inflating further only pulls a
  # decompression bomb into memory to throw away. So a tiny gzip that would balloon to
  # megabytes must stop at the cap, not the 32 MiB default.
  it "honours max_out — a bomb inflates only to the cap, not its full size" do
    huge = "A" * (4 * 1024 * 1024)
    io = IO::Memory.new
    Compress::Gzip::Writer.open(io) { |g| g << huge }
    head = req_head("Content-Type: text/plain", "Content-Encoding: gzip")
    bytes, decoded = Gori::Entity.of(head, io.to_slice, 64 * 1024)
    decoded.should be_true
    bytes.not_nil!.size.should be <= 64 * 1024 # stopped at the cap, did not inflate to 4 MiB
  end
end

describe "the decode panes over an encoded body" do
  envelope = %({"operationName":"Me","query":"query Me { me { id } }"})

  describe "GraphQL" do
    it "finds the operation in a gzip'd POST body" do
      head = req_head("Content-Type: application/json", "Content-Encoding: gzip")
      op = Gori::Graphql.from_flow("/graphql", head, gzipped(envelope)).not_nil!
      op.operation.should eq("Me")
      op.query.should eq("query Me { me { id } }")
    end

    it "finds the operation in a chunked POST body" do
      head = req_head("Content-Type: application/json", "Transfer-Encoding: chunked")
      Gori::Graphql.from_flow("/graphql", head, chunked(envelope)).not_nil!.operation.should eq("Me")
    end

    # The pane is a projection of bytes the ENVELOPE still holds compressed, so re-encoding an
    # edit into it would send plain JSON under a head that declares gzip — a request the origin
    # cannot read and the operator never wrote.
    it "marks the projection read-only and re-encodes nothing" do
      head = req_head("Content-Type: application/json", "Content-Encoding: gzip")
      body = gzipped(envelope)
      op = Gori::Graphql.from_flow("/graphql", head, body).not_nil!
      op.projected.should be_true
      op.editable?.should be_false
      Gori::Graphql.location(body, head).should eq(:none)
    end

    it "leaves an unencoded body fully editable" do
      head = req_head("Content-Type: application/json")
      op = Gori::Graphql.from_flow("/graphql", head, envelope.to_slice).not_nil!
      op.projected.should be_false
      op.editable?.should be_true
      Gori::Graphql.location(envelope.to_slice, head).should eq(:body)
    end
  end

  describe "PARAMS" do
    # This one did not merely go missing — it came back WRONG: the chunk-size line fused onto
    # the first key, so the pane listed a field literally named "9\r\na".
    it "does not fuse the chunk-size line onto the first field name" do
      head = req_head("Content-Type: application/x-www-form-urlencoded", "Transfer-Encoding: chunked")
      fields = Gori::FormData.from_flow("/x", head, chunked("a=1&b=22")).not_nil!
      fields.map(&.name).should eq(["a", "b"])
      fields.map(&.value).should eq(["1", "22"])
    end

    it "reads the fields of a gzip'd form body" do
      head = req_head("Content-Type: application/x-www-form-urlencoded", "Content-Encoding: gzip")
      fields = Gori::FormData.from_flow("/x", head, gzipped("user=alice&role=admin")).not_nil!
      fields.map(&.name).should eq(["user", "role"])
    end
  end

  describe "JWT" do
    # The response side is the point: real API responses are compressed essentially always, so
    # the pane whose whole job is finding tokens was off for most responses that carry one.
    it "finds a token in a gzip'd RESPONSE body" do
      header = Base64.urlsafe_encode(%({"alg":"HS256","typ":"JWT"}), padding: false)
      payload = Base64.urlsafe_encode(%({"sub":"1","role":"admin"}), padding: false)
      token = "#{header}.#{payload}.c2ln"
      resp_head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\n\r\n".to_slice
      found = Gori::Jwt.from_flow("/login", nil, nil, resp_head, gzipped(%({"token":"#{token}"})))
      found.map(&.token).should contain(token)
      found.first.location.should contain("response body")
    end
  end

  describe "SAML" do
    it "finds the assertion in a gzip'd IdP auto-POST form" do
      assertion = Base64.strict_encode(%(<samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol"><x/></samlp:Response>))
      html = %(<html><body><form method="post" action="https://sp.test/acs">) +
             %(<input type="hidden" name="SAMLResponse" value="#{assertion}"/></form></body></html>)
      resp_head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Encoding: gzip\r\n\r\n".to_slice
      doc = Gori::Saml.from_flow("/sso", nil, nil, resp_head, gzipped(html)).not_nil!
      doc.param.should eq("SAMLResponse")
      doc.location.should eq(:response)
      doc.xml.should contain("samlp:Response")
    end

    # Same re-encode gate as GraphQL's: a decoded REQUEST body is display-only, because the
    # Repeater would otherwise splice a re-encoded assertion into an envelope holding the wire
    # form. (`RepeaterController#saml_request_doc` refuses a projected doc.)
    it "marks a decoded REQUEST-side message as a projection" do
      assertion = Base64.strict_encode(%(<samlp:AuthnRequest xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol"><x/></samlp:AuthnRequest>))
      head = req_head("Content-Type: application/x-www-form-urlencoded", "Transfer-Encoding: chunked")
      body = chunked("SAMLRequest=#{URI.encode_www_form(assertion)}")
      doc = Gori::Saml.from_flow("/sso", head, body, nil, nil).not_nil!
      doc.location.should eq(:body)
      doc.projected.should be_true
    end
  end
end
