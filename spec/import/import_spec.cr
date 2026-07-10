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
end
