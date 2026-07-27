require "../spec_helper"

# src/gori/import/insomnia.cr — Insomnia v4 JSON export → response-less History flows.

private def with_store(&)
  path = File.tempname("gori-insomnia", ".db")
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

private def with_export(json : String, ext = ".json", &)
  path = File.tempname("gori-insomnia", ext)
  File.write(path, json)
  begin
    yield path
  ensure
    File.delete?(path)
  end
end

private def parse(json : String) : Gori::Import::ParseResult
  with_export(json) { |path| Gori::Import::Insomnia.parse_file(path) }
end

private def heads(result : Gori::Import::ParseResult) : Array(String)
  result.flows.map { |pair| String.new(pair.request.head) }
end

describe Gori::Import::Insomnia do
  it "imports request resources and ignores workspaces, folders and non-HTTP requests" do
    result = parse(<<-JSON)
      {"_type": "export", "__export_format": 4, "resources": [
        {"_id": "wrk_1", "_type": "workspace", "name": "W"},
        {"_id": "fld_1", "_type": "request_group", "parentId": "wrk_1", "name": "F"},
        {"_id": "req_1", "_type": "request", "parentId": "fld_1",
         "method": "GET", "url": "https://a.test/one"},
        {"_id": "req_2", "_type": "request", "parentId": "wrk_1",
         "method": "DELETE", "url": "https://a.test/two"},
        {"_id": "ws_1", "_type": "websocket_request", "parentId": "wrk_1", "url": "wss://a.test/ws"},
        {"_id": "grpc_1", "_type": "grpc_request", "parentId": "wrk_1", "url": "grpc://a.test"}]}
      JSON
    result.flows.map(&.request.target).should eq(["/one", "/two"])
    result.flows.map(&.request.method).should eq(["GET", "DELETE"])
    result.flows.map(&.response).should eq([nil, nil])
  end

  it "expands {{ _.var }} from the base environment merged with the first sub-environment" do
    result = parse(<<-JSON)
      {"_type": "export", "__export_format": 4, "resources": [
        {"_id": "wrk_1", "_type": "workspace"},
        {"_id": "env_base", "_type": "environment", "parentId": "wrk_1",
         "data": {"base_url": "https://base.test", "token": "BASE"}},
        {"_id": "env_dev", "_type": "environment", "parentId": "env_base",
         "data": {"token": "DEV"}},
        {"_id": "req_1", "_type": "request", "parentId": "wrk_1", "method": "GET",
         "url": "{{ _.base_url }}/x",
         "headers": [{"name": "Authorization", "value": "Bearer {{ _.token }}"}]}]}
      JSON
    result.flows.first.request.host.should eq("base.test")
    heads(result).first.should contain("Authorization: Bearer DEV") # sub-environment wins
  end

  it "also expands the legacy brace form without the _. prefix" do
    result = parse(<<-JSON)
      {"_type": "export", "__export_format": 4, "resources": [
        {"_id": "wrk_1", "_type": "workspace"},
        {"_id": "env_base", "_type": "environment", "parentId": "wrk_1",
         "data": {"base_url": "https://legacy.test"}},
        {"_id": "req_1", "_type": "request", "parentId": "wrk_1",
         "method": "GET", "url": "{{ base_url }}/x"}]}
      JSON
    result.flows.first.request.host.should eq("legacy.test")
  end

  it "appends the parameters array as query, skipping disabled rows" do
    result = parse(<<-JSON)
      {"_type": "export", "__export_format": 4, "resources": [
        {"_id": "req_1", "_type": "request", "method": "GET", "url": "https://a.test/s?pre=0",
         "parameters": [{"name": "page", "value": "2"},
                        {"name": "off", "value": "x", "disabled": true},
                        {"name": "q", "value": "a b"}]}]}
      JSON
    result.flows.first.request.target.should eq("/s?pre=0&page=2&q=a+b")
  end

  it "resolves an environment value that is itself templated" do
    result = parse(<<-JSON)
      {"_type": "export", "__export_format": 4, "resources": [
        {"_id": "env_base", "_type": "environment",
         "data": {"base_url": "{{ _.scheme }}://{{ _.host }}", "scheme": "https", "host": "nested.test"}},
        {"_id": "req_1", "_type": "request", "method": "GET", "url": "{{ _.base_url }}/x"}]}
      JSON
    result.flows.first.request.host.should eq("nested.test")
  end

  it "skips a URL with a braced host" do
    result = parse(<<-JSON)
      {"_type": "export", "__export_format": 4, "resources": [
        {"_id": "env_base", "_type": "environment", "data": {"ok": "good.test"}},
        {"_id": "req_1", "_type": "request", "method": "GET", "url": "https://{host}.test/x"},
        {"_id": "req_2", "_type": "request", "method": "GET", "url": "https://{{ _.ok }}/y"}]}
      JSON
    result.skipped.should eq(1)
    result.flows.map(&.request.host).should eq(["good.test"])
  end

  it "skips a request whose URL still holds an unresolved variable" do
    result = parse(<<-JSON)
      {"_type": "export", "__export_format": 4, "resources": [
        {"_id": "env_base", "_type": "environment", "data": {"ok": "https://good.test"}},
        {"_id": "req_1", "_type": "request", "method": "GET", "url": "{{ _.ok }}/yes"},
        {"_id": "req_2", "_type": "request", "method": "GET", "url": "{{ _.nope }}/no"}]}
      JSON
    result.flows.size.should eq(1)
    result.skipped.should eq(1)
    result.flows.first.request.host.should eq("good.test")
  end

  it "names the missing variables when every request was skipped for one" do
    ex = expect_raises(Gori::Error) do
      parse(<<-JSON)
        {"_type": "export", "__export_format": 4, "resources": [
          {"_id": "req_1", "_type": "request", "method": "GET", "url": "{{ _.base_url }}/a"}]}
        JSON
    end
    msg = ex.message.not_nil!
    msg.should contain("{{base_url}}")
    msg.should contain("1 request references")
    msg.should_not contain("malformed")
  end

  it "builds urlencoded, multipart and text bodies" do
    result = parse(<<-JSON)
      {"_type": "export", "__export_format": 4, "resources": [
        {"_id": "r1", "_type": "request", "method": "POST", "url": "https://a.test/form",
         "body": {"mimeType": "application/x-www-form-urlencoded",
                  "params": [{"name": "u", "value": "a b"}, {"name": "off", "value": "x", "disabled": true}]}},
        {"_id": "r2", "_type": "request", "method": "POST", "url": "https://a.test/multi",
         "body": {"mimeType": "multipart/form-data",
                  "params": [{"name": "field", "value": "val"},
                             {"name": "upload", "type": "file", "fileName": "/etc/passwd"}]}},
        {"_id": "r3", "_type": "request", "method": "POST", "url": "https://a.test/json",
         "body": {"mimeType": "application/json", "text": "{\\"a\\":1}"}},
        {"_id": "r4", "_type": "request", "method": "POST", "url": "https://a.test/bin",
         "body": {"mimeType": "application/octet-stream", "fileName": "/etc/passwd"}}]}
      JSON
    bodies = result.flows.map { |f| f.request.body.try { |b| String.new(b) } }
    bodies[0].should eq("u=a+b")
    bodies[1].not_nil!.should contain(%(Content-Disposition: form-data; name="field"))
    bodies[1].not_nil!.should_not contain("upload")
    bodies[2].should eq(%({"a":1}))
    bodies[3].should be_nil # a `fileName`-only body names a path on the exporter's disk
    heads(result)[2].should contain("Content-Type: application/json")
  end

  it "seeds bearer / basic / apikey-header auth and nothing else" do
    result = parse(<<-JSON)
      {"_type": "export", "__export_format": 4, "resources": [
        {"_id": "r1", "_type": "request", "method": "GET", "url": "https://a.test/b",
         "authentication": {"type": "bearer", "token": "T"}},
        {"_id": "r2", "_type": "request", "method": "GET", "url": "https://a.test/basic",
         "authentication": {"type": "basic", "username": "u", "password": "p"}},
        {"_id": "r3", "_type": "request", "method": "GET", "url": "https://a.test/key",
         "authentication": {"type": "apikey", "key": "X-Token", "value": "V", "addTo": "header"}},
        {"_id": "r4", "_type": "request", "method": "GET", "url": "https://a.test/query",
         "authentication": {"type": "apikey", "key": "k", "value": "V", "addTo": "queryParams"}},
        {"_id": "r5", "_type": "request", "method": "GET", "url": "https://a.test/off",
         "authentication": {"type": "bearer", "token": "T", "disabled": true}},
        {"_id": "r6", "_type": "request", "method": "GET", "url": "https://a.test/oauth",
         "authentication": {"type": "oauth2", "accessTokenUrl": "https://a.test/t"}}]}
      JSON
    hs = heads(result)
    hs[0].should contain("Authorization: Bearer T")
    hs[1].should contain("Authorization: Basic dTpw")
    hs[2].should contain("X-Token: V")
    hs[3].should_not contain("k: V") # apikey-in-query would have to be spliced into a URL already built
    hs[4].should_not contain("Authorization")
    hs[5].should_not contain("Authorization")
  end

  it "points a v5 export at the right export option instead of failing to parse" do
    ex = expect_raises(Gori::Error) do
      with_export("type: collection.insomnia.rest/5.0\nname: W\n", ".yaml") do |path|
        Gori::Import::Insomnia.parse_file(path)
      end
    end
    ex.message.not_nil!.should contain("v4")
  end

  it "raises a clean error on invalid JSON and on a wrong-shaped document" do
    expect_raises(Gori::Error, /not valid JSON/) { parse("{nope") }
    expect_raises(Gori::Error, /not a JSON object/) { parse("[]") }
    expect_raises(Gori::Error, /no `resources` array/) { parse(%({"_type": "export"})) }
    expect_raises(Gori::Error, /no request resources/) do
      parse(%({"_type": "export", "resources": [{"_id": "w", "_type": "workspace"}]}))
    end
  end

  it "imports end to end through Import.import_file" do
    with_export(<<-JSON) do |path|
      {"_type": "export", "__export_format": 4, "resources": [
        {"_id": "env_base", "_type": "environment", "data": {"base_url": "https://shop.test"}},
        {"_id": "req_1", "_type": "request", "method": "POST", "url": "{{ _.base_url }}/cart",
         "body": {"mimeType": "text/plain", "text": "qty=1"}}]}
      JSON
      with_store do |store|
        result = Gori::Import.import_file(store, :insomnia, path)
        result.count.should eq(1)
        row = store.search(Gori::QL::EMPTY, 10).first
        row.host.should eq("shop.test")
        row.target.should eq("/cart")
        row.status.should be_nil
        String.new(store.get_flow(row.id).not_nil!.request_body.not_nil!).should eq("qty=1")
      end
    end
  end
end
