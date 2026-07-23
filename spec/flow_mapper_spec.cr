require "./spec_helper"

describe Gori::FlowMapper do
  it "projects a RawRequest into a CapturedRequest, passing head bytes through" do
    raw = "POST /api/orders HTTP/1.1\r\nHost: shop.test\r\nContent-Length: 2\r\n\r\n".to_slice
    req = Gori::Proxy::Codec::Http1.parse_request_head(raw)
    body = "hi".to_slice

    cap = Gori::FlowMapper.request(req,
      scheme: "https", host: "shop.test", port: 443, created_at: 99_i64,
      body: body, sni: "shop.test", alpn: "http/1.1", tls_version: "TLSv1.3")

    cap.method.should eq("POST")
    cap.target.should eq("/api/orders")
    cap.http_version.should eq("HTTP/1.1")
    cap.scheme.should eq("https")
    cap.host.should eq("shop.test")
    cap.port.should eq(443)
    cap.head.should eq(raw) # truth passes through unchanged (P7)
    cap.body.should eq(body)
    cap.sni.should eq("shop.test")
    cap.tls_version.should eq("TLSv1.3")
  end

  it "stores the verbatim request-line and blanks the version for a malformed request-line (R1-4)" do
    # An unencoded space in the target => 5 tokens, so parse_request_head mis-slices
    # target='/search?q=raw' / version='proxy'. The stored projection must surface neither.
    raw = "GET /search?q=raw proxy test HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice
    req = Gori::Proxy::Codec::Http1.parse_request_head(raw)
    req.malformed?.should be_true
    req.target.should eq("/search?q=raw") # mis-sliced live field (left untouched)
    req.version.should eq("proxy")

    cap = Gori::FlowMapper.request(req,
      scheme: "http", host: "acme.test", port: 80, created_at: 1_i64)

    cap.method.should eq("GET")                                   # first token still correct
    cap.target.should eq("GET /search?q=raw proxy test HTTP/1.1") # verbatim request-line
    cap.http_version.should eq("")                                # not the garbage 'proxy'
    cap.head.should eq(raw)                                       # truth byte-exact (P7)
  end

  it "projects a RawResponse into a CapturedResponse with content_type" do
    raw = "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/html\r\n\r\n".to_slice
    resp = Gori::Proxy::Codec::Http1.parse_response_head(raw)

    cap = Gori::FlowMapper.response(resp, flow_id: 7_i64, duration_us: 1234_i64)

    cap.flow_id.should eq(7)
    cap.status.should eq(500)
    cap.reason.should eq("Internal Server Error")
    cap.content_type.should eq("text/html")
    cap.head.should eq(raw)
    cap.state.should eq(Gori::Store::FlowState::Complete)
  end

  it "builds an error response when the upstream never answered" do
    cap = Gori::FlowMapper.error_response(3_i64, "connection refused")
    cap.flow_id.should eq(3)
    cap.state.should eq(Gori::Store::FlowState::Error)
    cap.error.should eq("connection refused")
    cap.status.should eq(0)
  end
end
