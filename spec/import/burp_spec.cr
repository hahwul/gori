require "base64"
require "../spec_helper"

# src/gori/import/burp.cr — Burp Suite "Save items" XML → BYTE-EXACT request/response flows.
# The point of this format (versus HAR/Postman/OpenAPI) is that the wire bytes survive
# unchanged, so most of these examples compare stored head bytes to the source bytes.

private def with_store(&)
  path = File.tempname("gori-burp", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def with_xml(xml : String, &)
  path = File.tempname("gori-burp", ".xml")
  File.write(path, xml)
  begin
    yield path
  ensure
    File.delete?(path)
  end
end

private def parse(xml : String) : Gori::Import::ParseResult
  with_xml(xml) { |path| Gori::Import::Burp.parse_file(path) }
end

# One <item> in Burp's shape. `request`/`response` are base64 like a real export.
private def item(url : String, request : String, response : String? = nil,
                 time : String = "Tue Mar 05 12:34:56 GMT 2024",
                 host : String = "target.test", port : String = "443",
                 protocol : String = "https") : String
  resp = response ? Base64.strict_encode(response) : ""
  <<-XML
    <item>
      <time>#{time}</time>
      <url><![CDATA[#{url}]]></url>
      <host ip="1.2.3.4">#{host}</host>
      <port>#{port}</port>
      <protocol>#{protocol}</protocol>
      <method><![CDATA[GET]]></method>
      <path><![CDATA[/]]></path>
      <request base64="true">#{Base64.strict_encode(request)}</request>
      <status>200</status>
      <responselength>#{response.try(&.bytesize) || 0}</responselength>
      <mimetype>JSON</mimetype>
      <response base64="true">#{resp}</response>
      <comment>a &amp; b</comment>
    </item>
    XML
end

private def items(*body : String) : String
  %(<?xml version="1.0"?>\n<!DOCTYPE items [\n<!ELEMENT items (item*)>\n]>\n) +
    %(<items burpVersion="2024.1" exportTime="Tue Mar 05 12:34:56 GMT 2024">\n) +
    body.join('\n') + "\n</items>\n"
end

describe Gori::Import::Burp do
  it "imports the request AND response of a saved item" do
    req = "POST /api/x?q=1 HTTP/1.1\r\nHost: target.test\r\nContent-Length: 9\r\n\r\nhello=abc"
    resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"ok\":true}"
    result = parse(items(item("https://target.test/api/x?q=1", req, resp)))
    result.flows.size.should eq(1)
    pair = result.flows.first
    pair.request.method.should eq("POST")
    pair.request.target.should eq("/api/x?q=1")
    pair.request.host.should eq("target.test")
    pair.request.port.should eq(443)
    String.new(pair.request.body.not_nil!).should eq("hello=abc")

    response = pair.response.not_nil!
    response.status.should eq(200)
    response.reason.should eq("OK")
    response.content_type.should eq("application/json")
    String.new(response.body.not_nil!).should eq(%({"ok":true}))
  end

  it "stores the head BYTE-EXACT rather than re-serializing it" do
    # A saved Burp item is frequently a hand-forged request. Rebuilding the head through
    # Builder would re-emit Content-Length, reorder nothing but normalize spacing, and
    # reject the entry on HEADER_INJECT — destroying exactly what makes the item worth
    # keeping. Odd spacing, a duplicate header and a deliberately WRONG Content-Length all
    # have to survive.
    req = "POST /x HTTP/1.1\r\nHost: target.test\r\nX-Odd:  spaced \r\nX-Dup: 1\r\nX-Dup: 2\r\n" \
          "Content-Length: 999\r\n\r\nshort"
    resp = "HTTP/1.1 302 Moved\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\n"
    result = parse(items(item("https://target.test/x", req, resp)))
    pair = result.flows.first
    String.new(pair.request.head).should eq(req[0, req.index("\r\n\r\n").not_nil! + 4])
    String.new(pair.response.not_nil!.head).should eq(resp)
  end

  it "keeps a control character in the request target verbatim (P7)" do
    # The imported TARGET is deliberately not sanitised — a raw CR/LF there is the
    # operator's own smuggling payload, and it has to replay byte-exact.
    req = "GET /x\rHTTP/1.1\r\nHost: target.test\r\n\r\n"
    result = parse(items(item("https://target.test/x", req)))
    String.new(result.flows.first.request.head).should eq(req)
  end

  it "normalizes an LF-only head so its headers actually parse" do
    # Http1.parse_headers scans for CRLF only and returns an EMPTY header list for an
    # LF-only head, so a Unix-normalized item would otherwise import with no headers.
    req = "GET /lf HTTP/1.1\nHost: target.test\nA: b\n\nbody"
    result = parse(items(item("https://target.test/lf", req)))
    pair = result.flows.first
    String.new(pair.request.head).should eq("GET /lf HTTP/1.1\r\nHost: target.test\r\nA: b\r\n\r\n")
    String.new(pair.request.body.not_nil!).should eq("body")
  end

  it "terminates a head that was saved without its trailing blank line" do
    result = parse(items(item("https://target.test/t", "GET /t HTTP/1.1\r\nHost: target.test")))
    String.new(result.flows.first.request.head).should end_with("\r\n\r\n")
  end

  it "leaves the flow response-less when the item has no response" do
    result = parse(items(item("https://target.test/pending", "GET /pending HTTP/1.1\r\nHost: target.test\r\n\r\n")))
    result.flows.first.response.should be_nil
  end

  it "imports an item whose <time> cannot be parsed" do
    # A timestamp surprise must never drop the item (same rule as har.cr#parse_started).
    before = Time.utc.to_unix
    result = parse(items(item("https://target.test/t", "GET /t HTTP/1.1\r\nHost: target.test\r\n\r\n",
      time: "not a timestamp at all")))
    result.flows.size.should eq(1)
    result.skipped.should eq(0)
    (result.flows.first.request.created_at // 1_000_000).should be >= before
  end

  it "reads Burp's Java Date.toString() timestamp" do
    result = parse(items(item("https://target.test/t", "GET /t HTTP/1.1\r\nHost: target.test\r\n\r\n",
      time: "Tue Mar 05 12:34:56 GMT 2024")))
    at = Time.unix(result.flows.first.request.created_at // 1_000_000)
    at.year.should eq(2024)
    at.month.should eq(3)
    at.day.should eq(5)
  end

  it "does not confuse <response> with <responselength>" do
    # `<response` is a prefix of `<responselength`; a naive scan reads the length element
    # as the message and base64-decodes a number.
    resp = "HTTP/1.1 204 No Content\r\n\r\n"
    result = parse(items(item("https://target.test/x", "GET /x HTTP/1.1\r\nHost: target.test\r\n\r\n", resp)))
    result.flows.first.response.not_nil!.status.should eq(204)
  end

  it "accepts an inline (non-base64) CDATA message" do
    req = "GET /cdata HTTP/1.1\r\nHost: target.test\r\n\r\n"
    xml = items(<<-XML)
      <item>
        <url><![CDATA[https://target.test/cdata]]></url>
        <request base64="false"><![CDATA[#{req}]]></request>
        <response base64="false"></response>
      </item>
      XML
    result = parse(xml)
    String.new(result.flows.first.request.head).should eq(req)
  end

  it "falls back to protocol/host/port when the item has no <url>" do
    xml = items(<<-XML)
      <item>
        <host ip="1.2.3.4">fallback.test</host>
        <port>8443</port>
        <protocol>http</protocol>
        <request base64="true">#{Base64.strict_encode("GET /f HTTP/1.1\r\nHost: fallback.test\r\n\r\n")}</request>
      </item>
      XML
    pair = parse(xml).flows.first
    pair.request.scheme.should eq("http")
    pair.request.host.should eq("fallback.test")
    pair.request.port.should eq(8443)
  end

  it "skips one broken item instead of discarding the export" do
    good = item("https://target.test/ok", "GET /ok HTTP/1.1\r\nHost: target.test\r\n\r\n")
    no_request = "<item><url><![CDATA[https://target.test/x]]></url></item>"
    bad_url = item("ftp://target.test/nope", "GET /nope HTTP/1.1\r\nHost: target.test\r\n\r\n")
    result = parse(items(good, no_request, bad_url))
    result.flows.size.should eq(1)
    result.skipped.should eq(2)
  end

  it "raises a clean error on a non-Burp file and on an empty export" do
    expect_raises(Gori::Error, /no <items> root/) { parse("<html><body>nope</body></html>") }
    expect_raises(Gori::Error, /no <item> entries/) do
      parse(%(<?xml version="1.0"?>\n<items burpVersion="2024.1"></items>\n))
    end
  end

  it "imports end to end through Import.import_file" do
    req = "GET /shop HTTP/1.1\r\nHost: shop.test\r\nAccept: */*\r\n\r\n"
    resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<p>ok</p>"
    with_xml(items(item("https://shop.test/shop", req, resp, host: "shop.test"))) do |path|
      with_store do |store|
        result = Gori::Import.import_file(store, :burp, path)
        result.count.should eq(1)
        row = store.search(Gori::QL::EMPTY, 10).first
        row.host.should eq("shop.test")
        row.target.should eq("/shop")
        row.status.should eq(200)
        detail = store.get_flow(row.id).not_nil!
        String.new(detail.request_head).should eq(req)
        String.new(detail.response_body.not_nil!).should eq("<p>ok</p>")
      end
    end
  end
end
