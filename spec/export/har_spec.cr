require "../spec_helper"
require "json"
require "base64"
require "compress/gzip"

# `Gori::Export::Har` — the inverse of `Gori::Import::Har` (#495).
#
# The load-bearing example here is the ROUND TRIP: a HAR gori writes must import back into
# gori as the same flow, byte-exact heads and bodies included, and exporting the re-imported
# flow must reproduce the identical document. Everything else in this file exists to pin one
# decision the issue called out — a capped body must be marked, a WebSocket flow has no HAR
# representation, a flow with no response never becomes a response-less entry.

private def with_store(&)
  path = File.tempname("gori-export-har", ".db")
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

# A real captured flow, written through the real Store writer: the export reads
# `request_size`/`response_size` back out to recover the true wire body size, so a
# hand-built FlowDetail would not exercise that path honestly.
private def capture_flow(store,
                         req_head : String = "GET /items?a=1&b HTTP/1.1\r\nHost: shop.test\r\nAccept: */*\r\nCookie: sid=abc; theme=dark\r\n\r\n",
                         resp_head : String = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nSet-Cookie: sid=xyz; Path=/; HttpOnly\r\nContent-Length: 9\r\n\r\n",
                         req_body : Bytes? = nil,
                         resp_body : Bytes? = "<p>ok</p>".to_slice,
                         status : Int32 = 200,
                         reason : String = "OK",
                         content_type : String? = "text/html",
                         http_version : String = "HTTP/1.1",
                         method : String = "GET",
                         target : String = "/items?a=1&b",
                         host : String = "shop.test",
                         scheme : String = "https",
                         port : Int32 = 443,
                         created_at : Int64 = 1_780_000_000_123_000_i64,
                         duration_us : Int64? = 42_500_i64,
                         req_body_truncated = false, req_body_size : Int64? = nil,
                         resp_body_truncated = false, resp_body_size : Int64? = nil) : Gori::Store::FlowDetail
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: created_at, scheme: scheme, host: host, port: port, method: method,
    target: target, http_version: http_version, head: req_head.to_slice, body: req_body,
    body_truncated: req_body_truncated, body_size: req_body_size))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: resp_head.to_slice, body: resp_body, reason: reason,
    content_type: content_type, duration_us: duration_us,
    body_truncated: resp_body_truncated, body_size: resp_body_size))
  store.get_flow(id).not_nil!
end

private def pending_flow(store) : Gori::Store::FlowDetail
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_780_000_000_000_000_i64, scheme: "https", host: "shop.test", port: 443,
    method: "GET", target: "/slow", http_version: "HTTP/1.1",
    head: "GET /slow HTTP/1.1\r\nHost: shop.test\r\n\r\n".to_slice, body: nil))
  store.get_flow(id).not_nil!
end

# A request gori REFUSED to send (`Codec::Body.request_framing` on a CL+TE message, say).
# The response side is persisted as an EMPTY head with the cause in `error` — NOT as a NULL
# head, which is only the Pending shape.
private def refused_flow(store) : Gori::Store::FlowDetail
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_780_000_000_000_000_i64, scheme: "http", host: "shop.test", port: 80,
    method: "POST", target: "/clte", http_version: "HTTP/1.1",
    head: "POST /clte HTTP/1.1\r\nHost: shop.test\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n".to_slice,
    body: "5\r\nhello\r\n0\r\n\r\n".to_slice))
  # Built by the SAME producer the proxy uses, because the empty-vs-NULL distinction this
  # example turns on is exactly what a hand-rolled DTO would get wrong.
  store.update_response(Gori::FlowMapper.error_response(
    id, "request framing rejected: Transfer-Encoding and Content-Length both present"))
  store.get_flow(id).not_nil!
end

# A response that started arriving and never finished: a REAL head, a partial body, and
# `state = Aborted`.
private def aborted_flow(store) : Gori::Store::FlowDetail
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_780_000_000_000_000_i64, scheme: "https", host: "shop.test", port: 443,
    method: "GET", target: "/chunked", http_version: "HTTP/1.1",
    head: "GET /chunked HTTP/1.1\r\nHost: shop.test\r\n\r\n".to_slice))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, reason: "OK", content_type: "text/plain",
    head: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n".to_slice,
    body: "5\r\nhel\nlo\r\n".to_slice, state: Gori::Store::FlowState::Aborted,
    error: "upstream closed before response body complete"))
  store.get_flow(id).not_nil!
end

private def export(details : Array(Gori::Store::FlowDetail),
                   ws : Gori::Export::Har::WsLookup? = nil) : {String, Gori::Export::Har::Report}
  io = IO::Memory.new
  report = Gori::Export::Har.log(io, details, ws: ws)
  {io.to_s, report}
end

# A captured WebSocket flow: the real 101 handshake plus a transcript written through the real
# Store writer, so the export reads back exactly what capture stored (`created_at` included).
private def ws_flow(store, messages : Array({String, Int32, Bytes})) : Gori::Store::FlowDetail
  detail = capture_flow(store,
    req_head: "GET /chat HTTP/1.1\r\nHost: shop.test\r\nUpgrade: websocket\r\n" \
              "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" \
              "Sec-WebSocket-Version: 13\r\n\r\n",
    resp_head: "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
               "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n",
    resp_body: nil, status: 101, reason: "Switching Protocols", content_type: nil,
    target: "/chat")
  messages.each do |(direction, opcode, payload)|
    store.insert_ws_message(detail.row.id, direction, opcode, payload)
  end
  store.get_flow(detail.row.id).not_nil!
end

# The transcript lookup a real caller passes (`gori run history --format har` builds the same
# closure over its open store).
private def ws_lookup(store) : Gori::Export::Har::WsLookup
  ->(id : Int64) { store.ws_messages(id) }
end

# `reimport`, plus the WebSocket transcript the import restored for that flow — read while the
# store is still open, since that is the only place it exists.
private def reimport_ws(har : String) : {Gori::Store::FlowDetail, Array(Gori::Store::WsMessage)}
  path = File.tempname("gori-export-har", ".har")
  File.write(path, har)
  begin
    result = nil
    with_store do |store|
      Gori::Import.import_file(store, :har, path)
      row = store.recent_flows(2).first
      result = {store.get_flow(row.id).not_nil!, store.ws_messages(row.id)}
    end
    result.not_nil!
  ensure
    File.delete?(path)
  end
end

# Write `har` to a temp file and import it into a fresh store, returning the one flow back.
private def reimport(har : String) : Gori::Store::FlowDetail
  path = File.tempname("gori-export-har", ".har")
  File.write(path, har)
  begin
    detail = nil
    with_store do |store|
      Gori::Import.import_file(store, :har, path)
      row = store.recent_flows(2).first
      detail = store.get_flow(row.id)
    end
    detail.not_nil!
  ensure
    File.delete?(path)
  end
end

describe Gori::Export::Har do
  it "writes a HAR 1.2 log with the fields a reader needs" do
    with_store do |store|
      har, report = export([capture_flow(store)])
      report.written.should eq(1)
      report.skipped.should eq(0)

      log = JSON.parse(har)["log"]
      log["version"].as_s.should eq("1.2")
      log["creator"]["name"].as_s.should eq("gori")

      entry = log["entries"][0]
      entry["startedDateTime"].as_s.should eq("2026-05-28T20:26:40.123Z")
      entry["time"].as_f.should eq(42.5)

      req = entry["request"]
      req["method"].as_s.should eq("GET")
      req["url"].as_s.should eq("https://shop.test/items?a=1&b")
      req["httpVersion"].as_s.should eq("HTTP/1.1")
      req["headers"].as_a.map(&.["name"].as_s).should eq(["Host", "Accept", "Cookie"])
      # headersSize is the real byte count of the captured head, not the spec's -1 escape.
      req["headersSize"].as_i.should eq(88)
      req["bodySize"].as_i.should eq(0)
      # postData is ABSENT (not an empty object) when the request carried no body — an
      # empty one would import back as a zero-length body.
      req["postData"]?.should be_nil

      resp = entry["response"]
      resp["status"].as_i.should eq(200)
      resp["statusText"].as_s.should eq("OK")
      resp["redirectURL"].as_s.should eq("")
      resp["bodySize"].as_i.should eq(9)
      resp["content"]["size"].as_i.should eq(9)
      resp["content"]["mimeType"].as_s.should eq("text/html")
      resp["content"]["text"].as_s.should eq("<p>ok</p>")
      resp["content"]["encoding"]?.should be_nil

      # `cache` and `timings` are required members; send/receive are the spec's "not
      # applicable" rather than a fabricated 0.
      entry["cache"].as_h.should be_empty
      entry["timings"]["wait"].as_f.should eq(42.5)
      entry["timings"]["send"].as_i.should eq(-1)
    end
  end

  it "emits the query and cookies as derived views over the wire bytes" do
    with_store do |store|
      entry = JSON.parse(export([capture_flow(store)])[0])["log"]["entries"][0]

      # NOT percent-decoded, and a bare flag keeps an empty value rather than vanishing.
      entry["request"]["queryString"].as_a.map { |q| {q["name"].as_s, q["value"].as_s} }
        .should eq([{"a", "1"}, {"b", ""}])

      entry["request"]["cookies"].as_a.map { |c| {c["name"].as_s, c["value"].as_s} }
        .should eq([{"sid", "abc"}, {"theme", "dark"}])

      cookie = entry["response"]["cookies"][0]
      cookie["name"].as_s.should eq("sid")
      cookie["value"].as_s.should eq("xyz")
      cookie["path"].as_s.should eq("/")
      cookie["httpOnly"].as_bool.should be_true
      cookie["secure"]?.should be_nil
    end
  end

  it "round-trips: a HAR gori writes imports back as the same flow" do
    with_store do |store|
      detail = capture_flow(store,
        req_head: "POST /submit HTTP/1.1\r\nHost: shop.test\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n",
        req_body: %({"id":"a\\/b"}).to_slice,
        method: "POST", target: "/submit")
      har, _ = export([detail])

      back = reimport(har)
      # The heads survive BYTE-EXACT: `Builder.request_head` re-emits Content-Length last,
      # which is where the captured head already had it, and it keeps the recorded Host.
      String.new(back.request_head).should eq(String.new(detail.request_head))
      String.new(back.response_head.not_nil!).should eq(String.new(detail.response_head.not_nil!))
      back.request_body.should eq(detail.request_body)
      back.response_body.should eq(detail.response_body)
      back.row.url.should eq(detail.row.url)
      back.row.method.should eq(detail.row.method)
      back.row.status.should eq(detail.row.status)
      back.row.content_type.should eq(detail.row.content_type)
      back.http_version.should eq(detail.http_version)
      # Milliseconds and the round-trip duration survive; a whole-second `created_at`
      # truncation would silently collapse a burst of flows onto one timestamp.
      back.row.created_at.should eq(detail.row.created_at)
      back.row.duration_us.should eq(detail.row.duration_us)

      # …and exporting the re-imported flow reproduces the identical document.
      export([back])[0].should eq(har)
    end
  end

  # A chunked message is stored RAW-chunked, so the byte count in the HAR is not the entity
  # length — and re-emitting it as a Content-Length manufactured the CL+TE shape gori's own
  # `Codec::Body.request_framing` REJECTS as illegal, out of a flow that had been captured
  # legally and is replayable through the Repeater. It also broke the fixed-point invariant
  # this file states: re-export was no longer byte-identical.
  it "round-trips a chunked message without inventing a Content-Length beside it" do
    with_store do |store|
      detail = capture_flow(store,
        req_head: "POST /u HTTP/1.1\r\nHost: shop.test\r\nTransfer-Encoding: chunked\r\n\r\n",
        req_body: "a\r\nfirst-part\r\n0\r\n\r\n".to_slice,
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n",
        resp_body: "4\r\ndone\r\n0\r\n\r\n".to_slice,
        method: "POST", target: "/u", content_type: "text/plain")
      har, _ = export([detail])
      back = reimport(har)

      req = String.new(back.request_head)
      req.should contain("Transfer-Encoding: chunked")
      req.should_not contain("Content-Length")
      resp = String.new(back.response_head.not_nil!)
      resp.should contain("Transfer-Encoding: chunked")
      resp.should_not contain("Content-Length")
      # Which is what makes the round trip a fixed point again.
      export([back])[0].should eq(har)
    end
  end

  # The other source these builders serve. A browser / Charles / Postman HAR passes
  # `transfer-encoding: chunked` through verbatim while `content.text` is the DECODED body —
  # so trusting the header alone stored a head declaring Chunked over a body that is not,
  # which every consumer then misframes SILENTLY. (The pre-fix CL+TE at least got refused
  # loudly by `Codec::Body.response_framing`.) The body decides, and the head is made to
  # describe what is actually stored.
  it "drops a Transfer-Encoding a third-party HAR's decoded body does not back" do
    har = {
      "log" => {
        "version" => "1.2", "creator" => {"name" => "some-browser", "version" => "1"},
        "entries" => [{
          "startedDateTime" => "2026-07-31T00:00:00.000Z", "time" => 1.0,
          "request" => {"method" => "POST", "url" => "https://a.test/x", "httpVersion" => "HTTP/1.1",
                        "headers" => [{"name" => "Transfer-Encoding", "value" => "chunked"}],
                        "postData" => {"mimeType" => "application/json", "text" => %({"a":1})},
                        "queryString" => [] of String, "cookies" => [] of String,
                        "headersSize" => -1, "bodySize" => -1},
          "response" => {"status" => 200, "statusText" => "OK", "httpVersion" => "HTTP/1.1",
                         "headers" => [{"name" => "Transfer-Encoding", "value" => "chunked"}],
                         "content" => {"size" => 11, "mimeType" => "text/plain", "text" => "hello world"},
                         "cookies" => [] of String, "redirectURL" => "",
                         "headersSize" => -1, "bodySize" => -1},
          "cache" => {} of String => String,
          "timings" => {"send" => 0.0, "wait" => 1.0, "receive" => 0.0},
        }],
      },
    }.to_json

    detail = reimport(har)
    req = String.new(detail.request_head)
    resp = String.new(detail.response_head.not_nil!)
    req.should_not contain("Transfer-Encoding")
    resp.should_not contain("Transfer-Encoding")
    # …and the head now states the length of the body it really has, so the framing the codec
    # derives matches the bytes instead of contradicting them.
    req.should contain("Content-Length: 7")
    resp.should contain("Content-Length: 11")
  end

  it "writes the WIRE body, not the decompressed view, so it stays in sync with Content-Encoding" do
    # Chrome writes the decoded text here. That is fine for a debugging view and wrong for a
    # capture artifact: `Content-Encoding: gzip` stays in `headers` either way, so a decoded
    # `text` would describe a message that never existed and would not import back.
    with_store do |store|
      gz = IO::Memory.new
      Compress::Gzip::Writer.open(gz, &.print("hello hello hello"))
      body = gz.to_slice
      detail = capture_flow(store,
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Encoding: gzip\r\nContent-Length: #{body.size}\r\n\r\n",
        resp_body: body, content_type: "text/plain")
      har, _ = export([detail])

      content = JSON.parse(har)["log"]["entries"][0]["response"]["content"]
      content["encoding"].as_s.should eq("base64")
      content["size"].as_i.should eq(body.size) # the compressed size, matching Content-Length
      Base64.decode(content["text"].as_s).should eq(body)

      reimport(har).response_body.should eq(body)
    end
  end

  it "keeps an absolute-form capture importable, at the cost of the request line's form" do
    # A plain-HTTP forward-proxy request is captured absolute-form; HAR has only `url`, so
    # the re-import lands origin-form. Pinned here so the one thing that does NOT survive
    # the round trip is a known property rather than a surprise.
    with_store do |store|
      detail = capture_flow(store,
        req_head: "GET http://api.test:8080/ping HTTP/1.1\r\nHost: api.test:8080\r\n\r\n",
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\n",
        resp_body: "ok".to_slice, content_type: "text/plain",
        scheme: "http", host: "api.test", port: 8080, target: "http://api.test:8080/ping")
      har, _ = export([detail])
      JSON.parse(har)["log"]["entries"][0]["request"]["url"].as_s.should eq("http://api.test:8080/ping")

      back = reimport(har)
      back.row.url.should eq(detail.row.url)
      String.new(back.request_head).should eq("GET /ping HTTP/1.1\r\nHost: api.test:8080\r\n\r\n")
    end
  end

  it "base64-encodes a body that is not valid UTF-8 and round-trips it byte-exact" do
    with_store do |store|
      body = Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x00, 0xff, 0xfe]
      detail = capture_flow(store,
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 9\r\n\r\n",
        resp_body: body, content_type: "image/png")
      har, _ = export([detail])

      content = JSON.parse(har)["log"]["entries"][0]["response"]["content"]
      content["encoding"].as_s.should eq("base64")
      content["size"].as_i.should eq(9)

      reimport(har).response_body.should eq(body)
    end
  end

  describe "a body capped at capture time" do
    # HAR has no truncation field. The decision (see TRUNCATED_MARK) is that `bodySize` /
    # `content.size` stay the TRUE wire size while `text` carries only what gori captured,
    # plus an explicit marker comment — never a capped body presented as a complete one.
    it "marks it in the HAR instead of presenting it as complete" do
      with_store do |store|
        detail = capture_flow(store,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5000\r\n\r\n",
          resp_body: "PARTIAL".to_slice, content_type: "text/plain",
          resp_body_truncated: true, resp_body_size: 5_000_i64)
        har, report = export([detail])
        report.truncated.should eq(1)
        report.notes.join(" ").should contain("truncated at the capture cap")

        resp = JSON.parse(har)["log"]["entries"][0]["response"]
        resp["bodySize"].as_i.should eq(5000)
        resp["content"]["size"].as_i.should eq(5000)
        resp["content"]["text"].as_s.should eq("PARTIAL")
        resp["content"]["comment"].as_s.should start_with(Gori::Export::Har::TRUNCATED_MARK)
        resp["content"]["comment"].as_s.should contain("7 of 5000 bytes")
      end
    end

    it "stays truncated on re-import rather than becoming a complete short body" do
      with_store do |store|
        detail = capture_flow(store,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5000\r\n\r\n",
          resp_body: "PARTIAL".to_slice, content_type: "text/plain",
          resp_body_truncated: true, resp_body_size: 5_000_i64)
        har, _ = export([detail])

        back = reimport(har)
        back.response_body_truncated?.should be_true
        back.response_body.should eq("PARTIAL".to_slice)
        back.row.response_size.should eq(detail.row.response_size)
        # The marking survives the round trip, so a second export says the same thing.
        export([back])[0].should eq(har)
      end
    end

    it "marks a capped REQUEST body too, and keeps the origin's Content-Length on re-import" do
      with_store do |store|
        detail = capture_flow(store,
          req_head: "POST /upload HTTP/1.1\r\nHost: shop.test\r\nContent-Length: 9000\r\n\r\n",
          req_body: "PARTIAL".to_slice, method: "POST", target: "/upload",
          req_body_truncated: true, req_body_size: 9_000_i64)
        har, report = export([detail])
        report.truncated.should eq(1)

        req = JSON.parse(har)["log"]["entries"][0]["request"]
        req["bodySize"].as_i.should eq(9000)
        req["postData"]["text"].as_s.should eq("PARTIAL")
        req["postData"]["comment"].as_s.should start_with(Gori::Export::Har::TRUNCATED_MARK)

        back = reimport(har)
        back.request_body_truncated?.should be_true
        # 9000, not 7: a live capture stores the origin's Content-Length beside a capped
        # BLOB, and a re-import must not re-advertise the prefix length as the whole entity.
        String.new(back.request_head).should contain("Content-Length: 9000")
      end
    end
  end

  # R4. An exported entry has to carry what gori has to SAY about the exchange — HAR 1.2
  # gives `entry.comment` for exactly this. The pushed case matters most: a HAR reader has no
  # other way to tell a request the ORIGIN invented from one the client sent.
  it "carries the flow advisory as the entry comment, and omits it otherwise" do
    with_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "shop.test", port: 443, method: "GET",
        target: "/pushed", http_version: "HTTP/2",
        head: "GET /pushed HTTP/2\r\nHost: shop.test\r\n\r\n".to_slice,
        advisory: "server push: this request was invented by the origin"))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200, head: "HTTP/2 200\r\nContent-Length: 0\r\n\r\n".to_slice,
        advisory: "server push: this request was invented by the origin"))
      har, _ = export([store.get_flow(id).not_nil!])
      entry = JSON.parse(har)["log"]["entries"][0]
      entry["comment"].as_s.should contain("invented by the origin")

      plain, _ = export([capture_flow(store)])
      JSON.parse(plain)["log"]["entries"][0].as_h.has_key?("comment").should be_false
    end
  end

  # A captured HEAD is not UTF-8: RFC 7230's field-value is VCHAR / obs-text (%x80-FF), and a
  # Latin-1 filename in a `Content-Disposition` is the everyday source of one. Written straight
  # through, those octets produced a document jq / Python / DevTools all reject — and one gori
  # could not read back either: `Import::Builder`'s guard ran PCRE2 over the invalid value,
  # raised, and `Import::Har`'s per-entry rescue dropped the WHOLE flow as "skipped". Unlike a
  # body there is no base64 escape for a head, so the substitution is made and NAMED.
  describe "a head carrying obs-text" do
    obs_req = "GET /items?a=1&b HTTP/1.1\r\nHost: shop.test\r\nX-Note: caf\xe9\r\n\r\n"
    obs_resp = "HTTP/1.1 200 caf\xe9\r\nContent-Type: text/html\r\n" \
               "Content-Disposition: attachment; filename=\"caf\xe9.pdf\"\r\nContent-Length: 9\r\n\r\n"

    it "writes a valid-UTF-8 document and says the head was scrubbed" do
      with_store do |store|
        har, report = export([capture_flow(store, req_head: obs_req, resp_head: obs_resp)])
        har.valid_encoding?.should be_true
        report.written.should eq(1)
        report.scrubbed.should eq(1)
        report.notes.any?(&.includes?("U+FFFD")).should be_true

        entry = JSON.parse(har)["log"]["entries"][0]
        entry["comment"].as_s.should contain(Gori::Export::Har::SCRUBBED_MARK)
        entry["response"]["statusText"].as_s.should eq("caf\uFFFD")
        cd = entry["response"]["headers"].as_a
          .find { |h| h["name"].as_s == "Content-Disposition" }.not_nil!
        cd["value"].as_s.should contain("caf\uFFFD.pdf")
      end
    end

    it "still imports back as one flow instead of vanishing into the skipped count" do
      with_store do |store|
        har, _ = export([capture_flow(store, req_head: obs_req, resp_head: obs_resp)])
        back = reimport(har)
        back.row.status.should eq(200)
        String.new(back.request_head).should contain("X-Note: caf\uFFFD\r\n")
      end
    end

    it "leaves a clean head alone — no substitution, no count, no comment" do
      with_store do |store|
        # A VALID multi-byte value is not obs-text and must survive byte-exact; only the
        # `valid_encoding?` check runs on it (scrub is ~130µs on a valid 40 KB string).
        har, report = export([capture_flow(store,
          req_head: "GET /items?a=1&b HTTP/1.1\r\nHost: shop.test\r\nX-Note: café\r\n\r\n")])
        report.scrubbed.should eq(0)
        har.should contain("café")
        JSON.parse(har)["log"]["entries"][0].as_h.has_key?("comment").should be_false
      end
    end
  end

  # A 101 used to be skipped by its status alone, which threw away the whole point of having
  # captured the socket. The handshake IS a real exchange, so it is written as itself and the
  # transcript rides beside it in Chrome's `_webSocketMessages` — never folded into a
  # fabricated HTTP body, which would import back as an exchange that never happened.
  describe "a WebSocket flow's messages" do
    it "writes the transcript as Chrome's _webSocketMessages beside the real handshake" do
      with_store do |store|
        detail = ws_flow(store, [
          {"out", 1, %({"op":"subscribe"}).to_slice},
          {"in", 1, "ack".to_slice},
        ])
        har, report = export([detail], ws_lookup(store))
        report.written.should eq(1)
        report.websocket.should eq(0)
        report.skipped.should eq(0)

        entry = JSON.parse(har)["log"]["entries"][0]
        # The handshake, unfabricated: the request and response really happened.
        entry["request"]["url"].as_s.should eq("https://shop.test/chat")
        entry["response"]["status"].as_i.should eq(101)
        entry["response"]["statusText"].as_s.should eq("Switching Protocols")
        entry["_resourceType"].as_s.should eq("websocket")

        msgs = entry["_webSocketMessages"].as_a
        msgs.size.should eq(2)
        msgs.map(&.["type"].as_s).should eq(["send", "receive"])
        msgs.map(&.["opcode"].as_i).should eq([1, 1])
        msgs[0]["data"].as_s.should eq(%({"op":"subscribe"}))
        msgs[1]["data"].as_s.should eq("ack")
        # `time` is a Unix timestamp in SECONDS, the unit Chrome writes — not gori's micros
        # and not an offset from the entry's start.
        stored = store.ws_messages(detail.row.id)
        msgs[0]["time"].as_f.should eq((stored[0].created_at // 1000) / 1000.0)
        msgs[0]["time"].as_f.should be > 1_000_000_000.0
      end
    end

    it "round-trips the transcript back into ws_messages, and re-exports identically" do
      with_store do |store|
        detail = ws_flow(store, [
          {"out", 1, "one".to_slice},
          {"in", 1, "two".to_slice},
          {"out", 2, Bytes[0x00, 0xff, 0xfe]},
          {"in", 8, Bytes[0x03, 0xe8] + "bye".to_slice},
        ])
        har, _ = export([detail], ws_lookup(store))
        captured = store.ws_messages(detail.row.id)

        back, restored = reimport_ws(har)
        back.row.status.should eq(101)
        back.row.state.should eq(Gori::Store::FlowState::Complete)
        String.new(back.request_head).should eq(String.new(detail.request_head))
        String.new(back.response_head.not_nil!).should eq(String.new(detail.response_head.not_nil!))

        # Direction, opcode, payload BYTES and order all survive — a binary frame and a CLOSE
        # frame included, which is what the base64 escape hatch and the raw opcode are for.
        restored.map(&.direction).should eq(captured.map(&.direction))
        restored.map(&.opcode).should eq(captured.map(&.opcode))
        restored.map(&.payload).should eq(captured.map(&.payload))
        restored[3].close_code.should eq(1000)
        String.new(restored[3].close_reason.not_nil!).should eq("bye")
        # Millisecond fidelity, the same commitment `startedDateTime` makes.
        restored.map(&.created_at).should eq(captured.map { |m| (m.created_at // 1000) * 1000 })

        # …and the fixed point: exporting the re-imported flow reproduces the identical bytes.
        export([back], ->(_id : Int64) { restored })[0].should eq(har)
      end
    end

    it "base64s a payload that is not valid UTF-8 and keeps a text frame as text" do
      with_store do |store|
        detail = ws_flow(store, [
          {"out", 1, "\xff\xfe not utf-8".to_slice},
          {"in", 1, "plain".to_slice},
        ])
        har, _ = export([detail], ws_lookup(store))
        msgs = JSON.parse(har)["log"]["entries"][0]["_webSocketMessages"].as_a

        # An invalid-UTF-8 TEXT frame is a standard RFC 6455 §8.1/§5.6 test case; scrubbing it
        # to U+FFFD would rewrite the operator's evidence into a different message (P7).
        msgs[0]["encoding"].as_s.should eq("base64")
        Base64.decode(msgs[0]["data"].as_s).should eq("\xff\xfe not utf-8".to_slice)
        msgs[1]["data"].as_s.should eq("plain")
        msgs[1]["encoding"]?.should be_nil

        _, restored = reimport_ws(har)
        restored[0].payload.should eq("\xff\xfe not utf-8".to_slice)
        restored[1].payload.should eq("plain".to_slice)
      end
    end

    # `[gori] …` rows are positioned IN the stream and their position names the frames they
    # apply to, so dropping them would delete gori's own statements about the socket from the
    # artifact. The prefix survives byte-exact, which is what every seed reader's guard reads.
    it "carries the relay's own notice rows, and they still read as notices afterwards" do
      with_store do |store|
        detail = ws_flow(store, [
          {"in", 1, "[gori] the handshake's Sec-WebSocket-Extensions was stripped".to_slice},
          {"out", 1, "hello".to_slice},
        ])
        har, _ = export([detail], ws_lookup(store))
        JSON.parse(har)["log"]["entries"][0]["_webSocketMessages"][0]["data"].as_s
          .should start_with("[gori] ")

        _, restored = reimport_ws(har)
        restored[0].notice?.should be_true
        restored[1].notice?.should be_false
      end
    end

    # An empty payload is a legal zero-length frame (RFC 6455 — an empty heartbeat), and it is
    # the shape that binds SQL NULL against a NOT NULL BLOB column and rolls back the batch.
    it "round-trips a zero-length frame instead of losing the whole transcript to it" do
      with_store do |store|
        detail = ws_flow(store, [{"out", 1, Bytes.empty}, {"in", 9, Bytes.empty}])
        har, _ = export([detail], ws_lookup(store))
        JSON.parse(har)["log"]["entries"][0]["_webSocketMessages"].as_a
          .map(&.["data"].as_s).should eq(["", ""])

        _, restored = reimport_ws(har)
        restored.size.should eq(2)
        restored.map(&.payload.size).should eq([0, 0])
        restored.map(&.opcode).should eq([1, 9])
      end
    end
  end

  describe "flows with no HAR representation" do
    it "skips a WebSocket flow with an EMPTY transcript, rather than emitting the handshake alone" do
      with_store do |store|
        detail = ws_flow(store, [] of {String, Int32, Bytes})
        Gori::Export::Har.skip_reason(detail).should eq(Gori::Export::Har::Skip::WebSocket)

        har, report = export([detail], ws_lookup(store))
        report.websocket.should eq(1)
        report.written.should eq(0)
        JSON.parse(har)["log"]["entries"].as_a.should be_empty
        report.notes.join(" ").should contain("WebSocket")
        report.notes.join(" ").should contain("no captured messages")
      end
    end

    # The lookup is how a socket's messages reach the writer at all. A caller that omits it is
    # saying "no transcripts are available", and every 101 then lands in the skipped COUNT
    # rather than silently exporting as a handshake with nothing behind it.
    it "skips a socket WITH messages when the caller passed no transcript lookup" do
      with_store do |store|
        detail = ws_flow(store, [{"out", 1, "hello".to_slice}])
        har, report = export([detail])
        report.websocket.should eq(1)
        report.written.should eq(0)
        JSON.parse(har)["log"]["entries"].as_a.should be_empty
      end
    end

    it "skips a flow with no captured response instead of writing a response-less entry" do
      with_store do |store|
        detail = pending_flow(store)
        Gori::Export::Har.skip_reason(detail).should eq(Gori::Export::Har::Skip::NoResponse)

        har, report = export([detail])
        report.no_response.should eq(1)
        report.written.should eq(0)
        JSON.parse(har)["log"]["entries"].as_a.should be_empty
        report.notes.join(" ").should contain("no captured response")
      end
    end

    it "still writes the exportable flows around a skipped one" do
      with_store do |store|
        ok = capture_flow(store)
        ws = ws_flow(store, [] of {String, Int32, Bytes})
        har, report = export([ok, ws, pending_flow(store)], ws_lookup(store))
        report.written.should eq(1)
        report.websocket.should eq(1)
        report.no_response.should eq(1)
        JSON.parse(har)["log"]["entries"].as_a.size.should eq(1)
      end
    end

    # R4-F3. `response_head.nil?` was written against the PENDING shape and never re-tested
    # against Error/Aborted, which persist an EMPTY head instead. A request gori refused to
    # send therefore fell through to `entry` as `"status": 0` and came back in as a COMPLETE
    # flow — the outcome `skip_reason`'s own comment says it exists to prevent.
    it "skips a request gori REFUSED to send, rather than writing it as a status-0 entry" do
      with_store do |store|
        detail = refused_flow(store)
        # The shape that fooled the old predicate: not NULL, empty.
        detail.response_head.should_not be_nil
        detail.response_head.not_nil!.empty?.should be_true
        detail.row.state.should eq(Gori::Store::FlowState::Error)

        Gori::Export::Har.skip_reason(detail).should eq(Gori::Export::Har::Skip::NoResponse)
        har, report = export([detail])
        report.no_response.should eq(1)
        report.written.should eq(0)
        JSON.parse(har)["log"]["entries"].as_a.should be_empty
      end
    end

    # …and the reason that matters: what the fabricated entry did on the way back in.
    it "never lets a refused flow re-import as a successful exchange" do
      with_store do |store|
        har, _ = export([refused_flow(store), capture_flow(store)])
        entries = JSON.parse(har)["log"]["entries"].as_a
        entries.size.should eq(1)
        entries.none? { |e| e["response"]["status"].as_i == 0 }.should be_true
        # The one entry that IS written is the flow that genuinely succeeded, and it comes
        # back Complete — the complement, so the skip is not just "export nothing".
        back = reimport(har)
        back.row.status.should eq(200)
        back.row.state.should eq(Gori::Store::FlowState::Complete)
      end
    end

    it "skips an ABORTED flow by its own name: a partial response is not a response" do
      with_store do |store|
        detail = aborted_flow(store)
        # Unlike the refused flow, this one HAS a head — the nullity/emptiness of the head
        # cannot tell them apart, only the state can.
        detail.response_head.not_nil!.empty?.should be_false
        Gori::Export::Har.skip_reason(detail).should eq(Gori::Export::Har::Skip::Incomplete)

        har, report = export([detail])
        report.incomplete.should eq(1)
        report.no_response.should eq(0)
        report.skipped.should eq(1)
        report.written.should eq(0)
        JSON.parse(har)["log"]["entries"].as_a.should be_empty
        report.notes.join(" ").should contain("did not complete")
      end
    end
  end
end

# The import side of the round trip. These three read HAR fields that only became
# load-bearing once gori started WRITING them, so they live beside the export spec.
describe Gori::Import::Har do
  it "keeps the milliseconds of startedDateTime" do
    detail = reimport(<<-JSON)
      {"log":{"entries":[{"startedDateTime":"2026-05-28T20:26:40.123Z","time":1.5,
        "request":{"method":"GET","url":"https://h.test/p","httpVersion":"HTTP/1.1","headers":[]},
        "response":{"status":200,"statusText":"OK","httpVersion":"HTTP/1.1","headers":[],
          "content":{"size":0,"mimeType":"text/plain"}}}]}}
      JSON
    detail.row.created_at.should eq(1_780_000_000_123_000_i64)
    detail.row.duration_us.should eq(1_500_i64)
  end

  it "accepts either JSON number shape for time" do
    # gori writes `time` as a float so its fraction survives; plenty of other generators
    # write a bare integer. Both must land as a real duration.
    reimport(<<-JSON).row.duration_us.should eq(0_i64)
      {"log":{"entries":[{"startedDateTime":"2026-05-28T20:26:40.000Z","time":0,
        "request":{"method":"GET","url":"https://h.test/p","httpVersion":"HTTP/1.1","headers":[]},
        "response":{"status":200,"statusText":"OK","httpVersion":"HTTP/1.1","headers":[],
          "content":{"size":0,"mimeType":"text/plain"}}}]}}
      JSON
  end

  it "reads a NEGATIVE time as the spec's not-available, not as a negative duration" do
    reimport(<<-JSON).row.duration_us.should be_nil
      {"log":{"entries":[{"startedDateTime":"2026-05-28T20:26:40.000Z","time":-1,
        "request":{"method":"GET","url":"https://h.test/p","httpVersion":"HTTP/1.1","headers":[]},
        "response":{"status":200,"statusText":"OK","httpVersion":"HTTP/1.1","headers":[],
          "content":{"size":0,"mimeType":"text/plain"}}}]}}
      JSON
  end
end
