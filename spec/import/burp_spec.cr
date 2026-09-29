require "base64"
require "../spec_helper"

# src/gori/import/burp.cr — Burp Suite "Save items" XML → BYTE-EXACT request/response flows.
# The point of this format (versus HAR/Postman/OpenAPI) is that the wire bytes survive
# unchanged, so most of these examples compare stored head bytes to the source bytes.

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
  # A legal wall-clock date whose offset carries it past year 9999 stored a `created_at` that
  # raised in every later `Time.unix`; an impossible date raised ArgumentError, not the
  # `Time::Format::Error` the parser rescued. Both read as an unparseable stamp: "now".
  it "stamps an out-of-range or impossible time as now instead of storing or raising it" do
    req = "GET / HTTP/1.1\r\nHost: target.test\r\n\r\n"
    before = Time.utc.to_unix * 1_000_000
    {"9999-12-31T23:59:59-23:59", "2024-02-31T00:00:00Z"}.each do |t|
      result = parse(items(item("https://target.test/", req, time: t)))
      result.flows.size.should eq(1)
      result.flows.first.request.created_at.should be >= before
    end
  end

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

  it "decodes a base64 message wrapped in CDATA, the shape Burp actually writes" do
    req = "POST /c HTTP/1.1\r\nHost: target.test\r\nContent-Length: 3\r\n\r\n\xFFab"
    resp = "HTTP/1.1 201 Created\r\nContent-Type: text/plain\r\n\r\ncreated"
    xml = items(<<-XML)
      <item>
        <url><![CDATA[https://target.test/c]]></url>
        <request base64="true"><![CDATA[#{Base64.strict_encode(req)}]]></request>
        <response base64="true"><![CDATA[#{Base64.strict_encode(resp)}]]></response>
      </item>
      XML
    result = parse(xml)
    result.skipped.should eq(0)
    pair = result.flows.first
    (pair.request.head.to_a + pair.request.body.not_nil!.to_a).should eq(req.to_slice.to_a)
    pair.response.not_nil!.status.should eq(201)
    String.new(pair.response.not_nil!.body.not_nil!).should eq("created")
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

  # PROVENANCE, at the one seam where a corrupted read is PERMANENT: the store IS the
  # evidence, so a byte lost here is lost for every surface, forever, with the import
  # reporting `count: 1, skipped: 0` over it.
  #
  # `parse_file` used to `.scrub` the WHOLE FILE before the `<request>` bytes were cut out
  # of it, on the theory that "scrubbing keeps the scanner's ASCII needles working". The
  # scanner never needed it — its needles are ASCII and it cuts with `byte_slice`, which
  # copies bytes — but a `base64="false"` item, which carries its message
  # inline rather than encoded, went through that scrub with everything else. Measured
  # through `gori run import --burp` into a real SQLite store, source body
  # `a=1&bin=<ff fe 01 02>&b=2`:
  #
  #   stored request_body  61 3d 31 26 62 69 6e 3d ef bf bd ef bf bd 01 02 26 62 3d 32
  #
  # …20 bytes under a stored head still declaring `Content-Length: 16`.
  describe "a non-base64 item whose message is not valid UTF-8" do
    bin = Bytes[0xFF, 0xFE, 0x01, 0x02]
    body = String.build do |io|
      io << "a=1&bin="
      io.write(bin)
      io << "&b=2"
    end
    req = "POST /p?q=1 HTTP/1.1\r\nHost: target.test\r\n" \
          "Content-Type: application/x-www-form-urlencoded\r\n" \
          "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
    xml = items(<<-XML)
      <item>
        <url><![CDATA[https://target.test/p?q=1]]></url>
        <request base64="false"><![CDATA[#{req}]]></request>
        <response base64="false"></response>
      </item>
      XML

    it "stores the message byte for byte" do
      pair = parse(xml).flows.first
      stored = pair.request.head.to_a + (pair.request.body.try(&.to_a) || [] of UInt8)
      stored.should eq(req.to_slice.to_a) # byte-wise; the fixture is not valid UTF-8
      stored_body = pair.request.body.not_nil!
      (0..(stored_body.size - bin.size)).any? { |i| stored_body[i, bin.size] == bin }.should be_true
      # `.scrub` grew the body by 4 while the head kept declaring the original length.
      stored_body.size.should eq(body.bytesize)
    end

    it "keeps the bytes through the STORE, which is where the loss became permanent" do
      with_xml(xml) do |path|
        with_store do |store|
          Gori::Import.import_file(store, :burp, path).count.should eq(1)
          row = store.search(Gori::QL::EMPTY, 10).first
          detail = store.get_flow(row.id).not_nil!
          read_back = detail.request_body.not_nil!
          read_back.to_a.should eq(body.to_slice.to_a)
          String.new(detail.request_head).should contain("Content-Length: #{read_back.size}")
        end
      end
    end

    # …and the surrounding TEXT elements of the same item still read correctly, because the
    # invalid bytes sit in a sibling element and the scanner walks past them.
    it "still reads <url>, <host> and <time> out of the same file" do
      pair = parse(xml).flows.first
      pair.request.host.should eq("target.test")
      pair.request.target.should eq("/p?q=1")
      pair.request.scheme.should eq("https")
    end
  end

  # The scanner walks BYTE offsets (it walked chars, which made every item O(file) on any
  # export that is not pure ASCII). A mixed export — non-ASCII text between the tags, inline
  # messages with Korean text AND invalid bytes, base64 items after them — must come out as
  # the same flows, in order, with every message byte for byte.
  it "imports a mixed non-ASCII / invalid UTF-8 export item by item, byte for byte" do
    bin = Bytes[0xFF, 0xFE, 0xC3, 0x28, 0xE2, 0x82] # stray, overlong-ish and truncated sequences
    raw_body = String.build { |io| io << "이름=홍길동&bin="; io.write(bin); io << "&끝=1" }
    inline_req = "POST /한글 HTTP/1.1\r\nHost: target.test\r\nContent-Length: #{raw_body.bytesize}\r\n\r\n#{raw_body}"
    inline_resp = String.build { |io| io << "HTTP/1.1 200 OK\r\n\r\n응답 "; io.write(bin) }
    b64_req = "GET /ascii HTTP/1.1\r\nHost: target.test\r\n\r\n"
    b64_resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n본문 😀"
    non_cdata_req = String.build { |io| io << "PUT /n HTTP/1.1\r\nHost: target.test\r\n\r\n값 "; io.write(bin) }
    xml = items(
      item("https://target.test/ascii", b64_req, b64_resp),
      <<-XML,
        <item>
          <time>Tue Mar 05 12:34:56 GMT 2024</time>
          <url><![CDATA[https://target.test/%ED%95%9C%EA%B8%80]]></url>
          <comment>메모 ─ 비고</comment>
          <request base64="false"><![CDATA[#{inline_req}]]></request>
          <responselength>99</responselength>
          <response base64="false"><![CDATA[#{inline_resp}]]></response>
        </item>
        XML
      <<-XML,
        <item>
          <url><![CDATA[https://target.test/n]]></url>
          <request base64="false">#{non_cdata_req}</request>
        </item>
        XML
      item("https://target.test/ascii", b64_req, b64_resp),
    )
    result = parse(xml)
    result.skipped.should eq(0)
    result.flows.size.should eq(4)

    whole = ->(req : Gori::Store::CapturedRequest) { req.head.to_a + (req.body.try(&.to_a) || [] of UInt8) }
    [0, 3].each do |i|
      whole.call(result.flows[i].request).should eq(b64_req.to_slice.to_a)
      resp = result.flows[i].response.not_nil!
      String.new(resp.body.not_nil!).should eq("본문 😀")
    end
    whole.call(result.flows[1].request).should eq(inline_req.to_slice.to_a)
    result.flows[1].request.target.should eq("/한글") # the request line, verbatim
    result.flows[1].response.not_nil!.body.not_nil!.to_a.should eq(("응답 ".to_slice.to_a + bin.to_a))
    whole.call(result.flows[2].request).should eq(non_cdata_req.to_slice.to_a)
  end

  # COMPLEMENT: an ordinary base64 export — the shape Burp writes by default — is untouched
  # by any of this, including when its DECODED message is not valid UTF-8.
  it "is unchanged for a base64 export carrying binary bytes" do
    bin = Bytes[0xFF, 0xFE, 0x01, 0x02]
    body = String.build do |io|
      io << "a=1&bin="
      io.write(bin)
      io << "&b=2"
    end
    req = "POST /p HTTP/1.1\r\nHost: target.test\r\n" \
          "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
    pair = parse(items(item("https://target.test/p", req))).flows.first
    (pair.request.head.to_a + pair.request.body.not_nil!.to_a).should eq(req.to_slice.to_a)
  end

  # COMPLEMENT: entity decoding, which `bytes_of` reaches for a non-base64 item that is NOT
  # CDATA-wrapped. Named, decimal, hex and unknown entities must resolve exactly as before —
  # and now do so without walking the message as chars.
  it "unescapes entities in an inline non-CDATA message, and leaves unknown ones verbatim" do
    inline = "GET /e?a=1&amp;b=2&amp;c=&#65;&#x42;&amp;d=&bogus; HTTP/1.1&#13;&#10;" \
             "Host: target.test&#13;&#10;&#13;&#10;"
    xml = items(<<-XML)
      <item>
        <url><![CDATA[https://target.test/e]]></url>
        <request base64="false">#{inline}</request>
      </item>
      XML
    head = String.new(parse(xml).flows.first.request.head)
    head.should eq("GET /e?a=1&b=2&c=AB&d=&bogus; HTTP/1.1\r\nHost: target.test\r\n\r\n")
  end
end
