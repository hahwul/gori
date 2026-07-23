require "base64"
require "../spec_helper"

private def with_store(&)
  path = File.tempname("gori-import", ".db")
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

describe Gori::Import do
  it "imports flows from a HAR file into History" do
    har = File.tempname("gori", ".har")
    begin
      File.write(har, <<-JSON)
        {
          "log": {
            "entries": [
              {
                "startedDateTime": "2026-06-01T12:00:00.000Z",
                "time": 42,
                "request": {
                  "method": "GET",
                  "url": "https://shop.test/items",
                  "httpVersion": "HTTP/1.1",
                  "headers": [{"name": "Accept", "value": "*/*"}]
                },
                "response": {
                  "status": 200,
                  "statusText": "OK",
                  "httpVersion": "HTTP/1.1",
                  "headers": [{"name": "Content-Type", "value": "text/html"}],
                  "content": {"mimeType": "text/html", "text": "<p>ok</p>"}
                }
              }
            ]
          }
        }
        JSON

      with_store do |store|
        result = Gori::Import.import_file(store, :har, har)
        result.count.should eq(1)
        store.count.should eq(1)
        row = store.search(Gori::QL::EMPTY, 10).first
        row.host.should eq("shop.test")
        row.method.should eq("GET")
        row.target.should eq("/items")
        row.status.should eq(200)
      end
    ensure
      File.delete?(har)
    end
  end

  it "indexes the imported request body for FTS body: search (response-bearing entry)" do
    har = File.tempname("gori", ".har")
    begin
      # A response is present, so the import writer takes the update_one path (which reuses
      # the request FTS text computed at insert time instead of reading the row back). The
      # distinctive token lives ONLY in the REQUEST body, so a body: hit proves the request
      # FTS column was populated correctly through that path.
      File.write(har, <<-JSON)
        {
          "log": {
            "entries": [{
              "startedDateTime": "2026-06-01T12:00:00+00:00",
              "request": {
                "method": "POST",
                "url": "https://api.test/submit",
                "httpVersion": "HTTP/1.1",
                "postData": {"mimeType": "text/plain", "text": "hello zephyrquux world"}
              },
              "response": {
                "status": 200, "statusText": "OK", "httpVersion": "HTTP/1.1",
                "headers": [{"name": "Content-Type", "value": "text/html"}],
                "content": {"mimeType": "text/html", "text": "<p>ok</p>"}
              }
            }]
          }
        }
        JSON

      with_store do |store|
        Gori::Import.import_file(store, :har, har).count.should eq(1)
        hits = store.search(Gori::QL.parse("body:zephyrquux"), 10)
        hits.size.should eq(1)
        hits.first.target.should eq("/submit")
        # A token that appears in neither body must not match (guards a bogus index).
        store.search(Gori::QL.parse("body:nonesuchtoken"), 10).size.should eq(0)
      end
    ensure
      File.delete?(har)
    end
  end

  it "preserves duplicate response headers (multiple Set-Cookie) on HAR import" do
    har = File.tempname("gori", ".har")
    begin
      File.write(har, <<-JSON)
        {
          "log": {
            "entries": [
              {
                "startedDateTime": "2026-06-01T12:00:00.000Z", "time": 1,
                "request": {"method": "GET", "url": "https://shop.test/x", "httpVersion": "HTTP/1.1", "headers": []},
                "response": {
                  "status": 200, "statusText": "OK", "httpVersion": "HTTP/1.1",
                  "headers": [
                    {"name": "Set-Cookie", "value": "session=abc"},
                    {"name": "Set-Cookie", "value": "csrf=def"}
                  ],
                  "content": {"mimeType": "text/html", "text": "ok"}
                }
              }
            ]
          }
        }
        JSON

      with_store do |store|
        Gori::Import.import_file(store, :har, har)
        row = store.search(Gori::QL::EMPTY, 10).first
        head = String.new(store.get_flow(row.id).not_nil!.response_head.not_nil!)
        head.scan(/^set-cookie:/im).size.should eq(2) # both cookies survive, not collapsed to the last
      end
    ensure
      File.delete?(har)
    end
  end

  it "imports pending flows from a URL list file" do
    urls = File.tempname("gori", ".txt")
    begin
      File.write(urls, "https://api.test/v1/ping\n# comment\n\nhttp://legacy.test/\n")

      with_store do |store|
        result = Gori::Import.import_file(store, :urls, urls)
        result.count.should eq(2)
        store.count.should eq(2)
        hosts = store.sitemap_entries.map(&.[0]).uniq.sort
        hosts.should eq(["api.test", "legacy.test"])
      end
    ensure
      File.delete?(urls)
    end
  end

  it "imports request templates from an OpenAPI JSON spec" do
    oas = File.tempname("gori", ".json")
    begin
      File.write(oas, <<-JSON)
        {
          "openapi": "3.0.0",
          "servers": [{"url": "https://api.test/v1"}],
          "paths": {
            "/users": {
              "get": {"summary": "list"},
              "post": {
                "summary": "create",
                "requestBody": {
                  "content": {"application/json": {"schema": {"type": "object"}}}
                }
              }
            },
            "/users/{id}": {
              "get": {"summary": "read"}
            }
          }
        }
        JSON

      with_store do |store|
        result = Gori::Import.import_file(store, :oas, oas)
        result.count.should eq(3)
        entries = store.sitemap_entries
        entries.map(&.[1]).sort.should eq(["GET", "GET", "POST"])
        entries.map(&.[2]).sort.should eq(["/v1/users", "/v1/users", "/v1/users/{id}"])
      end
    ensure
      File.delete?(oas)
    end
  end

  it "raises when the import file does not exist" do
    with_store do |store|
      expect_raises(Gori::Error, /file not found/) do
        Gori::Import.import_file(store, :har, "/no/such/file.har")
      end
    end
  end

  it "decodes base64-encoded HAR request bodies" do
    har = File.tempname("gori", ".har")
    begin
      body = Base64.strict_encode("payload")
      File.write(har, <<-JSON)
        {
          "log": {
            "entries": [{
              "startedDateTime": "2026-06-01T12:00:00+00:00",
              "request": {
                "method": "POST",
                "url": "https://api.test/submit",
                "httpVersion": "HTTP/1.1",
                "postData": {"mimeType": "application/octet-stream", "text": "#{body}", "encoding": "base64"}
              }
            }]
          }
        }
        JSON

      with_store do |store|
        result = Gori::Import.import_file(store, :har, har)
        result.count.should eq(1)
        detail = store.get_flow(store.search(Gori::QL::EMPTY, 1).first.id).not_nil!
        detail.request_body.should eq("payload".to_slice)
      end
    ensure
      File.delete?(har)
    end
  end

  it "reconstructs a form body from HAR postData.params when there is no text (Firefox/Safari shape)" do
    har = File.tempname("gori", ".har")
    begin
      File.write(har, <<-JSON)
        {
          "log": {
            "entries": [{
              "startedDateTime": "2026-06-01T12:00:00+00:00",
              "request": {
                "method": "POST",
                "url": "https://api.test/login",
                "httpVersion": "HTTP/1.1",
                "postData": {
                  "mimeType": "application/x-www-form-urlencoded",
                  "params": [{"name": "user", "value": "a b"}, {"name": "pw", "value": "s&t"}]
                }
              }
            }]
          }
        }
        JSON

      with_store do |store|
        result = Gori::Import.import_file(store, :har, har)
        result.count.should eq(1)
        detail = store.get_flow(store.search(Gori::QL::EMPTY, 1).first.id).not_nil!
        String.new(detail.request_body.not_nil!).should eq("user=a+b&pw=s%26t")
      end
    ensure
      File.delete?(har)
    end
  end

  it "overwrites a stale Content-Length to match a HAR params-only reconstructed body (R2-8)" do
    har = File.tempname("gori", ".har")
    begin
      # The original request advertised a large Content-Length (a multipart upload), but the
      # HAR recorded only postData.params (no text), so we rebuild a SHORTER urlencoded body.
      # The stored head must carry a single Content-Length matching the rebuilt body, not the
      # stale 9999.
      File.write(har, <<-JSON)
        {
          "log": {
            "entries": [{
              "startedDateTime": "2026-06-01T12:00:00+00:00",
              "request": {
                "method": "POST",
                "url": "https://api.test/upload",
                "httpVersion": "HTTP/1.1",
                "headers": [{"name": "Content-Length", "value": "9999"}],
                "postData": {
                  "mimeType": "application/x-www-form-urlencoded",
                  "params": [{"name": "secret_field", "value": "x"}]
                }
              }
            }]
          }
        }
        JSON

      with_store do |store|
        Gori::Import.import_file(store, :har, har).count.should eq(1)
        detail = store.get_flow(store.search(Gori::QL::EMPTY, 1).first.id).not_nil!
        body = String.new(detail.request_body.not_nil!)
        body.should eq("secret_field=x") # 14 bytes
        head = String.new(detail.request_head)
        head.scan(/Content-Length:/i).size.should eq(1)         # exactly one CL, no stale duplicate
        head.should contain("Content-Length: #{body.bytesize}") # matches the rebuilt body
        head.should_not contain("9999")
      end
    ensure
      File.delete?(har)
    end
  end

  it "prepends https:// to scheme-less URL list lines" do
    urls = File.tempname("gori", ".txt")
    begin
      File.write(urls, "api.test/v1/ping\n")

      with_store do |store|
        result = Gori::Import.import_file(store, :urls, urls)
        result.count.should eq(1)
        row = store.search(Gori::QL::EMPTY, 1).first
        row.host.should eq("api.test")
        row.target.should eq("/v1/ping")
      end
    ensure
      File.delete?(urls)
    end
  end

  it "raises when OpenAPI spec has no servers block" do
    oas = File.tempname("gori", ".json")
    begin
      File.write(oas, %({"openapi":"3.0.0","paths":{"/x":{"get":{}}}}))

      with_store do |store|
        expect_raises(Gori::Error, /servers/) do
          Gori::Import.import_file(store, :oas, oas)
        end
      end
    ensure
      File.delete?(oas)
    end
  end

  it "raises an actionable error when OpenAPI servers[0].url is relative (not the opaque 'no flows found')" do
    oas = File.tempname("gori", ".json")
    begin
      File.write(oas, %({"servers":[{"url":"/v3"}],"paths":{"/users":{"get":{}}}}))
      with_store do |store|
        expect_raises(Gori::Error, /relative.*\/v3.*absolute server URL/) do
          Gori::Import.import_file(store, :oas, oas)
        end
      end
    ensure
      File.delete?(oas)
    end
  end

  it "raises the same actionable error for a dot-relative OpenAPI servers[0].url (./v3, ../v3)" do
    ["./v3", "../v3", "v3"].each do |url|
      oas = File.tempname("gori", ".json")
      begin
        File.write(oas, %({"servers":[{"url":"#{url}"}],"paths":{"/users":{"get":{}}}}))
        with_store do |store|
          expect_raises(Gori::Error, /relative.*absolute server URL/) do
            Gori::Import.import_file(store, :oas, oas)
          end
        end
      ensure
        File.delete?(oas)
      end
    end
  end

  it "reports the skipped count (not the opaque 'no flows found') when every OpenAPI operation is malformed" do
    oas = File.tempname("gori", ".json")
    begin
      File.write(oas, %({"servers":[{"url":"https://api.test"}],"paths":{"/bad":{"post":{"requestBody":{"content":"notanobject"}}}}}))
      with_store do |store|
        expect_raises(Gori::Error, /all 1 entry was skipped as malformed/) do
          Gori::Import.import_file(store, :oas, oas)
        end
      end
    ensure
      File.delete?(oas)
    end
  end

  it "fills declared path params, appends required query params, and seeds an apiKey header from an OpenAPI operation" do
    oas = File.tempname("gori", ".json")
    begin
      File.write(oas, <<-JSON)
        {
          "openapi": "3.0.0",
          "servers": [{"url": "https://api.test/v1"}],
          "components": {
            "securitySchemes": {
              "ApiKeyAuth": {"type": "apiKey", "in": "header", "name": "X-API-Key"}
            }
          },
          "security": [{"ApiKeyAuth": []}],
          "paths": {
            "/users/{id}": {
              "parameters": [
                {"name": "id", "in": "path", "required": true, "schema": {"type": "integer"}}
              ],
              "get": {
                "summary": "read",
                "parameters": [
                  {"name": "verbose", "in": "query", "required": true, "schema": {"type": "boolean"}},
                  {"name": "fields", "in": "query", "required": false}
                ]
              }
            }
          }
        }
        JSON
      with_store do |store|
        result = Gori::Import.import_file(store, :oas, oas)
        result.count.should eq(1)
        row = store.search(Gori::QL::EMPTY, 1).first
        # {id} filled from the path-ITEM-level declaration (integer -> "1"); required query
        # param appended; optional one omitted.
        row.target.should eq("/v1/users/1?verbose=true")
        detail = store.get_flow(row.id).not_nil!
        String.new(detail.request_head).should contain("X-API-Key: ") # apiKey security header seeded
      end
    ensure
      File.delete?(oas)
    end
  end

  it "skips a malformed HAR entry (invalid base64 body) instead of aborting the whole import" do
    har = File.tempname("gori", ".har")
    begin
      File.write(har, <<-JSON)
        {"log":{"entries":[
          {"request":{"method":"GET","url":"https://a.test/1"},"response":{"status":200,"content":{"text":"!!!notbase64!!!","encoding":"base64"}}},
          {"request":{"method":"GET","url":"https://a.test/2"},"response":{"status":200,"content":{"text":"ok"}}}
        ]}}
        JSON
      with_store do |store|
        result = Gori::Import.import_file(store, :har, har)
        result.count.should eq(1)   # the valid entry imported (was: whole import aborted)
        result.skipped.should eq(1) # the bad-base64 entry skipped
      end
    ensure
      File.delete?(har)
    end
  end

  it "skips a non-http(s) URL line instead of discarding the whole list" do
    urls = File.tempname("gori", ".txt")
    begin
      File.write(urls, "https://a.test/1\nftp://bad.test/x\nhttps://a.test/2\n")
      with_store do |store|
        result = Gori::Import.import_file(store, :urls, urls)
        result.count.should eq(2)   # both valid URLs imported (was: all lost to one bad line)
        result.skipped.should eq(1) # the ftp:// line skipped
      end
    ensure
      File.delete?(urls)
    end
  end

  it "skips a malformed OpenAPI operation instead of aborting the spec import" do
    oas = File.tempname("gori", ".json")
    begin
      File.write(oas, <<-JSON)
        {"servers":[{"url":"https://api.test"}],"paths":{
          "/ok":{"get":{}},
          "/bad":{"post":{"requestBody":{"content":"notanobject"}}}
        }}
        JSON
      with_store do |store|
        result = Gori::Import.import_file(store, :oas, oas)
        result.count.should eq(1)   # /ok get imported
        result.skipped.should eq(1) # the /bad post (content not an object) skipped
      end
    ensure
      File.delete?(oas)
    end
  end

  it "raises a clean error when OpenAPI `paths` is not an object" do
    oas = File.tempname("gori", ".json")
    begin
      File.write(oas, %({"servers":[{"url":"https://api.test"}],"paths":"nope"}))
      with_store do |store|
        expect_raises(Gori::Error, /not an object/) { Gori::Import.import_file(store, :oas, oas) }
      end
    ensure
      File.delete?(oas)
    end
  end

  it "caps an oversized imported body at the capture limit (true size + truncated flag)" do
    max = Gori::Proxy::Codec::Body::CAPTURE_MAX
    big = "A" * (max + 1000)
    har = File.tempname("gori", ".har")
    begin
      File.write(har, {log: {entries: [
        {request:  {method: "GET", url: "https://a.test/big"},
         response: {status: 200, content: {text: big}}},
      ]}}.to_json)
      with_store do |store|
        Gori::Import.import_file(store, :har, har)
        row = store.search(Gori::QL::EMPTY, 10).first
        detail = store.get_flow(row.id).not_nil!
        detail.response_body.not_nil!.size.should eq(max) # stored blob capped, was unbounded
        detail.response_body_truncated?.should be_true
      end
    ensure
      File.delete?(har)
    end
  end

  it "imports a HAR entry whose startedDateTime has fractional seconds AND a numeric offset" do
    har = File.tempname("gori", ".har")
    begin
      # Firefox/Safari-style timestamp (numeric offset + fraction) — the old
      # strptime-only parser dropped this entry entirely.
      File.write(har, <<-JSON)
        {"log":{"entries":[
          {"startedDateTime":"2024-06-01T10:20:30.123-07:00","time":1,
           "request":{"method":"GET","url":"https://tz.test/x"},
           "response":{"status":200,"content":{"text":"ok"}}}
        ]}}
        JSON
      with_store do |store|
        result = Gori::Import.import_file(store, :har, har)
        result.count.should eq(1) # imported, not silently skipped
        row = store.search(Gori::QL::EMPTY, 1).first
        row.host.should eq("tz.test")
        row.created_at.should eq(1_717_262_430_000_000_i64) # parsed absolute time, not "now"
      end
    ensure
      File.delete?(har)
    end
  end

  it "imports a scheme-less URL whose query contains :// (not treated as a bad scheme)" do
    urls = File.tempname("gori", ".txt")
    begin
      File.write(urls, "example.test/redirect?next=http://inner.test/x\n")
      with_store do |store|
        result = Gori::Import.import_file(store, :urls, urls)
        result.count.should eq(1) # was rejected as "missing scheme" by a naive :// check
        row = store.search(Gori::QL::EMPTY, 1).first
        row.host.should eq("example.test")
        row.target.should eq("/redirect?next=http://inner.test/x")
      end
    ensure
      File.delete?(urls)
    end
  end

  it "skips a HAR entry whose URL carries a CRLF injection instead of importing a fabricated request" do
    har = File.tempname("gori", ".har")
    begin
      # The malicious entry's URL smuggles a second fake request via literal CRLFs. Left
      # unchecked this used to land straight in the stored request line/History row.
      File.write(har, {log: {entries: [
        {request: {method: "GET", url: "https://a.test/1"}, response: {status: 200, content: {text: "ok"}}},
        {request:  {method: "GET", url: "https://evil.test/path\r\nX-Injected: pwn\r\n\r\nGET /second HTTP/1.1"},
         response: {status: 200, content: {text: "ok"}}},
        {request: {method: "GET", url: "https://a.test/2"}, response: {status: 200, content: {text: "ok"}}},
      ]}}.to_json)
      with_store do |store|
        result = Gori::Import.import_file(store, :har, har)
        result.count.should eq(2)   # the two clean entries imported
        result.skipped.should eq(1) # the CRLF-injected entry skipped, not fabricated
        store.count.should eq(2)
        rows = store.search(Gori::QL::EMPTY, 10)
        rows.each { |r| r.target.should_not match(/[\r\n]/) }
        rows.map(&.host).sort.should eq(["a.test", "a.test"])
      end
    ensure
      File.delete?(har)
    end
  end

  it "skips a URL-list line with a raw control character in the path" do
    urls = File.tempname("gori", ".txt")
    begin
      File.write(urls, "https://a.test/1\nhttp://a.test/\x01\x02control\nhttps://a.test/2\n")
      with_store do |store|
        result = Gori::Import.import_file(store, :urls, urls)
        result.count.should eq(2)   # the two clean lines imported
        result.skipped.should eq(1) # the control-char line skipped
        store.count.should eq(2)
      end
    ensure
      File.delete?(urls)
    end
  end

  it "raises a clean Gori::Error for a HAR file that is not valid JSON" do
    har = File.tempname("gori", ".har")
    begin
      File.write(har, "not json at all {{{")
      with_store do |store|
        expect_raises(Gori::Error, /not valid JSON/) do
          Gori::Import.import_file(store, :har, har)
        end
      end
    ensure
      File.delete?(har)
    end
  end

  it "raises a clean Gori::Error for an OpenAPI .yaml file that is not valid YAML" do
    oas = File.tempname("gori", ".yaml")
    begin
      File.write(oas, "paths: [unclosed")
      with_store do |store|
        expect_raises(Gori::Error, /not valid YAML/) do
          Gori::Import.import_file(store, :oas, oas)
        end
      end
    ensure
      File.delete?(oas)
    end
  end

  it "raises a clean Gori::Error for a .json-named OpenAPI file with YAML-only (non-JSON) syntax" do
    oas = File.tempname("gori", ".json")
    begin
      File.write(oas, "paths:\n  /x:\n    get: {}\n")
      with_store do |store|
        expect_raises(Gori::Error, /not valid JSON/) do
          Gori::Import.import_file(store, :oas, oas)
        end
      end
    ensure
      File.delete?(oas)
    end
  end
end
