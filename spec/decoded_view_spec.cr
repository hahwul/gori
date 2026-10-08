require "./spec_helper"
require "compress/gzip"

private def decoded_json(req_head : String?, req_body : Bytes?, resp_head : String?, resp_body : Bytes?) : String
  JSON.build do |j|
    j.object do
      Gori::DecodedView.emit_json(j, target: "/",
        req_head: req_head.try(&.to_slice), req_body: req_body,
        resp_head: resp_head.try(&.to_slice), resp_body: resp_body)
    end
  end
end

describe Gori::DecodedView do
  # The store holds the WIRE body. The detail pane decodes it before rendering, so a gzip or
  # chunked MessagePack response was a document there and absent from `gori run show --format
  # json` and MCP `get_flow`.
  it "renders a binary document from the entity, not the encoded wire body" do
    msgpack = Bytes[0x81, 0xa1, 0x61, 0x01] # {"a":1}
    io = IO::Memory.new
    Compress::Gzip::Writer.open(io, &.write(msgpack))
    head = "HTTP/1.1 200 OK\r\nContent-Type: application/msgpack\r\nContent-Encoding: gzip\r\n\r\n"
    doc = JSON.parse(decoded_json(nil, nil, head, io.to_slice))["binary_documents"].as_a
    doc[0]["format"].as_s.should eq("msgpack")
    doc[0]["json"].as_s.should eq(%({"a":1}))

    chunked = "HTTP/1.1 200 OK\r\nContent-Type: application/msgpack\r\nTransfer-Encoding: chunked\r\n\r\n"
    body = "4\r\n".to_slice + msgpack + "\r\n0\r\n\r\n".to_slice
    JSON.parse(decoded_json(nil, nil, chunked, body))["binary_documents"][0]["json"].as_s.should eq(%({"a":1}))
  end

  # JSON::Builder passes bytes >= 0x80 through, so an unscrubbed captured string made the whole
  # document invalid UTF-8 — which jq, Python's json and every JSON-RPC client reject.
  it "emits valid UTF-8 for captured strings that are not" do
    saml = decoded_json("POST / HTTP/1.1\r\nHost: h\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\n",
      "SAMLResponse=PHNhbWw%2BPC9zYW1sPg%3D%3D&RelayState=%FF".to_slice, nil, nil)
    saml.valid_encoding?.should be_true
    JSON.parse(saml)["saml"]["relay_state"].as_s.should eq("�")

    jwt = decoded_json("GET / HTTP/1.1\r\nHost: h\r\nCookie: \xFFsid=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig\r\n\r\n",
      nil, nil, nil)
    jwt.valid_encoding?.should be_true
    JSON.parse(jwt)["jwt"][0]["location"].as_s.should eq("Cookie �sid")
  end
end
