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

private def export(details : Array(Gori::Store::FlowDetail)) : {String, Gori::Export::Har::Report}
  io = IO::Memory.new
  report = Gori::Export::Har.log(io, details)
  {io.to_s, report}
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
          "request"  => {"method" => "POST", "url" => "https://a.test/x", "httpVersion" => "HTTP/1.1",
                         "headers"  => [{"name" => "Transfer-Encoding", "value" => "chunked"}],
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

  describe "flows with no HAR representation" do
    it "skips a WebSocket flow and says so, rather than emitting the handshake alone" do
      with_store do |store|
        detail = capture_flow(store, status: 101, reason: "Switching Protocols",
          resp_head: "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n",
          resp_body: nil, content_type: nil)
        Gori::Export::Har.skip_reason(detail).should eq(Gori::Export::Har::Skip::WebSocket)

        har, report = export([detail])
        report.websocket.should eq(1)
        report.written.should eq(0)
        JSON.parse(har)["log"]["entries"].as_a.should be_empty
        report.notes.join(" ").should contain("WebSocket")
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
        ws = capture_flow(store, status: 101, reason: "Switching Protocols",
          resp_head: "HTTP/1.1 101 Switching Protocols\r\n\r\n", resp_body: nil, content_type: nil)
        har, report = export([ok, ws, pending_flow(store)])
        report.written.should eq(1)
        report.websocket.should eq(1)
        report.no_response.should eq(1)
        JSON.parse(har)["log"]["entries"].as_a.size.should eq(1)
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
