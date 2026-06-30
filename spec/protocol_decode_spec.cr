require "./spec_helper"
require "base64"
require "compress/deflate"
require "json"
require "uri"

# Builds an HTTP head Bytes from a request line + header pairs.
private def head(line : String, *headers) : Bytes
  String.build do |io|
    io << line << "\r\n"
    headers.each { |h| io << h << "\r\n" }
    io << "\r\n"
  end.to_slice
end

private def b64_deflate(xml : String) : String
  io = IO::Memory.new
  Compress::Deflate::Writer.open(io, &.write(xml.to_slice))
  Base64.strict_encode(io.to_slice)
end

private def jwt(header : String, payload : String) : String
  h = Base64.urlsafe_encode(header, padding: false)
  p = Base64.urlsafe_encode(payload, padding: false)
  "#{h}.#{p}.sIgNaTuRe"
end

SAML_XML = %(<samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" ID="_x"><saml:Issuer xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion">https://idp.test/meta</saml:Issuer></samlp:Response>)

describe Gori::Saml do
  describe ".from_flow (HTTP-POST binding)" do
    it "decodes a SAMLResponse form POST with RelayState" do
      body = "SAMLResponse=#{URI.encode_www_form(Base64.strict_encode(SAML_XML))}&RelayState=#{URI.encode_www_form("/dashboard")}"
      doc = Gori::Saml.from_flow("/saml/acs",
        head("POST /saml/acs HTTP/1.1", "Content-Type: application/x-www-form-urlencoded"),
        body.to_slice, nil, nil)
      doc.should_not be_nil
      doc = doc.not_nil!
      doc.param.should eq("SAMLResponse")
      doc.binding.should eq(:post)
      doc.location.should eq(:body)
      doc.relay_state.should eq("/dashboard")
      doc.xml.should eq(SAML_XML)
    end
  end

  describe ".from_flow (HTTP-Redirect binding)" do
    it "decodes a deflated SAMLRequest query param" do
      target = "/sso?SAMLRequest=#{URI.encode_www_form(b64_deflate(SAML_XML))}&RelayState=abc"
      doc = Gori::Saml.from_flow(target, head("GET #{target} HTTP/1.1"), nil, nil, nil)
      doc.should_not be_nil
      doc = doc.not_nil!
      doc.param.should eq("SAMLRequest")
      doc.binding.should eq(:redirect)
      doc.location.should eq(:query)
      doc.xml.should eq(SAML_XML)
    end
  end

  describe ".from_flow (response auto-POST form)" do
    it "extracts SAMLResponse from a hidden HTML input" do
      html = %(<html><body><form method="post"><input type="hidden" name="SAMLResponse" value="#{Base64.strict_encode(SAML_XML)}"/></form></body></html>)
      doc = Gori::Saml.from_flow("/", head("GET / HTTP/1.1"), nil,
        head("HTTP/1.1 200 OK", "Content-Type: text/html"), html.to_slice)
      doc.should_not be_nil
      doc.not_nil!.location.should eq(:response)
      doc.not_nil!.xml.should eq(SAML_XML)
    end
  end

  it "returns nil for a non-SAML flow" do
    Gori::Saml.from_flow("/api?x=1", head("POST /api HTTP/1.1"), %({"a":1}).to_slice, nil, nil).should be_nil
  end

  describe "encode/decode round-trip" do
    it "round-trips POST binding" do
      v = Gori::Saml.encode_value(SAML_XML, :post)
      dec = Gori::Saml.decode_value(URI.decode_www_form(v)).not_nil!
      dec[0].should eq(SAML_XML)
      dec[1].should eq(:post)
    end

    it "round-trips Redirect binding (raw deflate)" do
      v = Gori::Saml.encode_value(SAML_XML, :redirect)
      dec = Gori::Saml.decode_value(URI.decode_www_form(v)).not_nil!
      dec[0].should eq(SAML_XML)
      dec[1].should eq(:redirect)
    end
  end

  describe ".replace_param" do
    it "replaces only the target param, byte-for-byte on the rest" do
      Gori::Saml.replace_param("SAMLResponse=OLD&RelayState=keep%2Dme", "SAMLResponse", "NEW")
        .should eq("SAMLResponse=NEW&RelayState=keep%2Dme")
    end

    it "appends when the param is absent" do
      Gori::Saml.replace_param("RelayState=x", "SAMLResponse", "NEW")
        .should eq("RelayState=x&SAMLResponse=NEW")
    end
  end

  # Mirrors the Replay split-decode send path (saml_splice): re-encode the edited XML
  # into the param, leaving sibling form fields (RelayState, the envelope edits) intact.
  it "splices an edited payload into the form body, preserving siblings" do
    body = "SAMLResponse=#{URI.encode_www_form(Base64.strict_encode(SAML_XML))}&RelayState=#{URI.encode_www_form("/dashboard")}"
    edited = SAML_XML.sub("idp.test", "attacker.test")
    edited.should contain("attacker.test") # sanity: the edit actually changed the XML
    spliced = Gori::Saml.replace_param(body, "SAMLResponse", Gori::Saml.encode_value(edited, :post))
    spliced.should contain("RelayState=#{URI.encode_www_form("/dashboard")}") # sibling survives
    doc = Gori::Saml.from_flow("/acs", head("POST /acs HTTP/1.1", "Content-Type: application/x-www-form-urlencoded"), spliced.to_slice, nil, nil)
    doc.not_nil!.xml.should contain("attacker.test") # the edit reached the re-encoded param
    doc.not_nil!.relay_state.should eq("/dashboard")
  end

  it "pretty-prints decoded XML" do
    Gori::Saml.pretty_xml(SAML_XML).should contain("\n")
  end
end

describe Gori::Jwt do
  token = jwt(%({"alg":"HS256","typ":"JWT"}), %({"sub":"alice","exp":1782000000}))

  describe ".jwt?" do
    it "accepts a structurally-valid token" do
      Gori::Jwt.jwt?(token).should be_true
    end

    it "rejects a dotted non-token" do
      Gori::Jwt.jwt?("a.b.c").should be_false
      Gori::Jwt.jwt?("not-a-jwt").should be_false
    end
  end

  describe ".from_flow" do
    it "finds a token in the Authorization header" do
      found = Gori::Jwt.from_flow("/", head("GET / HTTP/1.1", "Authorization: Bearer #{token}"), nil, nil, nil)
      found.size.should eq(1)
      found[0].location.should eq("Authorization")
      found[0].decoded.should contain("\"alice\"")
      found[0].brief.not_nil!.should contain("alg HS256")
      found[0].brief.not_nil!.should contain("exp ")
    end

    it "finds a token embedded in a JSON response body" do
      found = Gori::Jwt.from_flow("/", head("GET / HTTP/1.1"), nil,
        head("HTTP/1.1 200 OK"), %({"access_token":"#{token}"}).to_slice)
      found.size.should eq(1)
      found[0].location.should eq("response body")
    end

    it "finds a token in a cookie and the query, deduping repeats" do
      found = Gori::Jwt.from_flow("/cb?id_token=#{token}",
        head("GET /cb HTTP/1.1", "Cookie: sid=#{token}; theme=dark"), nil, nil, nil)
      found.size.should eq(1) # same token in cookie + query → one entry
    end

    it "returns empty when no token is present" do
      Gori::Jwt.from_flow("/", head("GET / HTTP/1.1", "Authorization: Basic abc"), nil, nil, nil).should be_empty
    end

    it "does not crash on a crafted exp outside Time's range" do
      crafted = jwt(%({"alg":"none"}), %({"exp":99999999999999}))
      found = Gori::Jwt.from_flow("/", head("GET / HTTP/1.1", "Authorization: Bearer #{crafted}"), nil, nil, nil)
      found.size.should eq(1)
      found[0].brief.not_nil!.should contain("99999999999999") # raw fallback, not a raise
    end
  end
end

describe Gori::Graphql do
  describe ".from_flow (POST JSON)" do
    it "parses operationName, query and variables" do
      body = %({"operationName":"Me","query":"query Me { me { id } }","variables":{"x":1}})
      op = Gori::Graphql.from_flow("/graphql", head("POST /graphql HTTP/1.1", "Content-Type: application/json"), body.to_slice)
      op.should_not be_nil
      op = op.not_nil!
      op.operation.should eq("Me")
      op.query.should contain("me { id }")
      op.variables.not_nil!.should contain("\"x\": 1")
    end

    it "ignores a REST body whose query field is not a document" do
      Gori::Graphql.from_flow("/api", head("POST /api HTTP/1.1", "Content-Type: application/json"),
        %({"query":"shoes","page":2}).to_slice).should be_nil
    end
  end

  describe ".from_flow (GET)" do
    it "parses a query-string operation" do
      q = URI.encode_www_form("{ ping }")
      op = Gori::Graphql.from_flow("/graphql?query=#{q}", head("GET /graphql HTTP/1.1"), nil)
      op.not_nil!.query.should eq("{ ping }")
    end
  end

  it "renders display text" do
    op = Gori::Graphql::Op.new("Me", "query Me { id }", %({\n  "x": 1\n}))
    text = Gori::Graphql.display(op)
    text.should contain("# operationName: Me")
    text.should contain("# variables")
  end

  describe ".parse_display" do
    it "round-trips display → parse for op + query + variables" do
      op = Gori::Graphql::Op.new("Me", "query Me {\n  me { id }\n}", %({\n  "x": 1\n}))
      o, q, v = Gori::Graphql.parse_display(Gori::Graphql.display(op))
      o.should eq("Me")
      q.should eq("query Me {\n  me { id }\n}")
      v.should eq(%({\n  "x": 1\n}))
    end

    it "handles a bare query (no op, no variables)" do
      o, q, v = Gori::Graphql.parse_display("{ ping }")
      o.should be_nil
      q.should eq("{ ping }")
      v.should be_nil
    end
  end

  describe ".recompose" do
    it "overlays edited query/variables onto the original body, preserving extensions" do
      envelope = %({"operationName":"Me","query":"old","variables":{"x":1},"extensions":{"persisted":true}})
      decoded = "# operationName: Me2\n\nquery Me2 { y }\n\n# variables\n{\"z\":2}"
      body = Gori::Graphql.recompose(envelope, decoded)
      j = JSON.parse(body)
      j["operationName"].as_s.should eq("Me2")
      j["query"].as_s.should eq("query Me2 { y }")
      j["variables"]["z"].as_i.should eq(2)
      j["extensions"]["persisted"].as_bool.should be_true # extensions survive
    end

    it "keeps the original variables when the decoded pane omits them" do
      envelope = %({"query":"old","variables":{"keep":1}})
      body = Gori::Graphql.recompose(envelope, "query New { z }")
      j = JSON.parse(body)
      j["query"].as_s.should eq("query New { z }")
      j["variables"]["keep"].as_i.should eq(1)
    end
  end
end

describe Gori::FormData do
  describe ".from_flow" do
    it "decodes a urlencoded body and query string with sources" do
      fields = Gori::FormData.from_flow("/login?next=%2Fhome",
        head("POST /login HTTP/1.1", "Content-Type: application/x-www-form-urlencoded"),
        "user=alice&pass=p%40ss".to_slice)
      fields.should_not be_nil
      fields = fields.not_nil!
      fields.any? { |f| f.name == "next" && f.value == "/home" && f.source == :query }.should be_true
      fields.any? { |f| f.name == "pass" && f.value == "p@ss" && f.source == :body }.should be_true
    end

    it "summarises multipart parts including a file" do
      boundary = "BND"
      body = String.build do |io|
        io << "--#{boundary}\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nHello\r\n"
        io << "--#{boundary}\r\nContent-Disposition: form-data; name=\"avatar\"; filename=\"a.png\"\r\n"
        io << "Content-Type: image/png\r\n\r\n\x89PNG\r\n"
        io << "--#{boundary}--\r\n"
      end
      fields = Gori::FormData.from_flow("/upload",
        head("POST /upload HTTP/1.1", "Content-Type: multipart/form-data; boundary=#{boundary}"),
        body.to_slice)
      fields.should_not be_nil
      fields = fields.not_nil!
      fields.any? { |f| f.name == "title" && f.value == "Hello" }.should be_true
      fields.any? { |f| f.name == "avatar" && f.note.try(&.includes?("a.png")) }.should be_true
    end

    it "returns nil when the request carries no form data" do
      Gori::FormData.from_flow("/api", head("POST /api HTTP/1.1", "Content-Type: application/json"),
        %({"a":1}).to_slice).should be_nil
    end
  end
end
