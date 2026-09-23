require "../spec_helper"

# `Repeater::UrlRequest` — the typed half of the URL-built send, shared by MCP `send_request`
# and `gori run send` (#1116). The MCP argument shapes around it are pinned in
# spec/mcp/request_builder_spec.cr; this pins what the CLI reaches directly.
describe Gori::Repeater::UrlRequest do
  it "builds the request line from the URL's path and query, with Host and Content-Length" do
    t = Gori::Repeater::UrlRequest.target("https://api.example.test:8443/v1/items/42?lang=en")
    {t.scheme, t.host, t.port}.should eq({"https", "api.example.test", 8443})
    built = Gori::Repeater::UrlRequest.structured(t, "post", [{"Accept", "application/json"}], %({"a":1}).to_slice)
    String.new(built.bytes).should eq(
      "POST /v1/items/42?lang=en HTTP/1.1\r\nAccept: application/json\r\nHost: api.example.test:8443\r\n" \
      "Content-Length: 7\r\n\r\n{\"a\":1}")
  end

  # `gori run send --verbatim`: a token the operator typed in a header value is the payload.
  it "leaves a header value's $ENV token literal with expand: false" do
    t = Gori::Repeater::UrlRequest.target("http://h.test/")
    built = Gori::Repeater::UrlRequest.structured(t, nil, [{"X-T", "$ENV.NOT_A_VAR"}], nil, expand: false)
    String.new(built.bytes).should contain("X-T: $ENV.NOT_A_VAR\r\n")
  end

  it "refuses a header that would split into two, and a URL with no host" do
    t = Gori::Repeater::UrlRequest.target("http://h.test/")
    expect_raises(Gori::Error, /CR\/LF\/NUL/) do
      Gori::Repeater::UrlRequest.structured(t, nil, [{"X", "a\r\nY: b"}], nil)
    end
    expect_raises(Gori::Error, /include a scheme/) { Gori::Repeater::UrlRequest.target("h.test:80/x") }
    expect_raises(Gori::Error, /only http\/https/) { Gori::Repeater::UrlRequest.target("ftp://h.test/") }
  end

  it "sends a raw request byte-exact under verbatim, and CRLF-promotes only its head otherwise" do
    t = Gori::Repeater::UrlRequest.target("http://h.test/")
    raw = "GET / HTTP/1.1\nHost: h\n\nbody\nline"
    String.new(Gori::Repeater::UrlRequest.raw(t, raw, true).bytes).should eq(raw)
    String.new(Gori::Repeater::UrlRequest.raw(t, raw, false).bytes).should eq("GET / HTTP/1.1\r\nHost: h\r\n\r\nbody\nline")
  end
end
