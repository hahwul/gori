require "../spec_helper"

# src/gori/import/postman.cr — Postman Collection v2.0/v2.1 → response-less History flows.
# Inline temp files rather than fixtures, matching spec/import/import_spec.cr.

private def with_store(&)
  path = File.tempname("gori-postman", ".db")
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

private def with_collection(json : String, &)
  path = File.tempname("gori", ".postman_collection.json")
  File.write(path, json)
  begin
    yield path
  ensure
    File.delete?(path)
  end
end

private def parse(json : String) : Gori::Import::ParseResult
  with_collection(json) { |path| Gori::Import::Postman.parse_file(path) }
end

private def heads(result : Gori::Import::ParseResult) : Array(String)
  result.flows.map { |pair| String.new(pair.request.head) }
end

describe Gori::Import::Postman do
  it "walks nested folders, not just the top-level item array" do
    # A flat read of `collection.item` imports almost nothing from a real export: every
    # request lives inside at least one folder.
    result = parse(<<-JSON)
      {"info": {"name": "n"},
       "item": [
         {"name": "top", "request": {"method": "GET", "url": "https://a.test/0"}},
         {"name": "f1", "item": [
           {"name": "one", "request": {"method": "GET", "url": "https://a.test/1"}},
           {"name": "f2", "item": [
             {"name": "two", "request": {"method": "DELETE", "url": "https://a.test/2"}}]}]}]}
      JSON
    result.flows.size.should eq(3)
    result.flows.map(&.request.target).sort!.should eq(["/0", "/1", "/2"])
    result.flows.map(&.response).should eq([nil, nil, nil]) # request templates, never a response
  end

  it "reads url as a bare string, as {raw}, and as component parts" do
    result = parse(<<-JSON)
      {"info": {"name": "n"},
       "item": [
         {"request": "https://a.test/bare"},
         {"request": {"method": "GET", "url": {"raw": "https://a.test/raw?x=1"}}},
         {"request": {"method": "GET", "url": {
            "protocol": "https", "host": ["a", "test"], "port": "8443",
            "path": ["deep", "path"],
            "query": [{"key": "k", "value": "v"}, {"key": "off", "value": "no", "disabled": true}]}}}]}
      JSON
    result.flows.map(&.request.target).should eq(["/bare", "/raw?x=1", "/deep/path?k=v"])
    result.flows[2].request.port.should eq(8443)
  end

  it "expands {{variables}} from the collection and from folder scope" do
    result = parse(<<-JSON)
      {"info": {"name": "n"},
       "variable": [{"key": "baseUrl", "value": "https://root.test"}, {"key": "v", "value": "1"}],
       "item": [
         {"request": {"method": "GET", "url": "{{baseUrl}}/a?v={{v}}"}},
         {"name": "scoped", "variable": [{"key": "baseUrl", "value": "https://folder.test"}],
          "item": [{"request": {"method": "GET", "url": "{{baseUrl}}/b"}}]}]}
      JSON
    result.flows.map { |f| "#{f.request.host}#{f.request.target}" }
      .should eq(["root.test/a?v=1", "folder.test/b"])
  end

  it "resolves a variable whose value is itself templated" do
    # `baseUrl = "{{scheme}}://{{host}}/api"` is routine. A single substitution pass would
    # leave `{{scheme}}` behind and skip the entry as "variables not defined in the
    # collection" — naming variables that ARE defined.
    result = parse(<<-JSON)
      {"info": {"name": "n"},
       "variable": [{"key": "baseUrl", "value": "{{scheme}}://{{host}}/api"},
                    {"key": "scheme", "value": "https"},
                    {"key": "host", "value": "nested.test"}],
       "item": [{"request": {"method": "GET", "url": "{{baseUrl}}/x"}}]}
      JSON
    result.flows.first.request.host.should eq("nested.test")
    result.flows.first.request.target.should eq("/api/x")
  end

  it "gives up on a self-referential variable instead of spinning on it" do
    # `a -> {{b}} -> {{a}}` must terminate. It ends as an unresolvable entry, which is the
    # all-skipped path — the point of the example is that it RETURNS.
    expect_raises(Gori::Error, /variables not defined/) do
      parse(<<-JSON)
        {"info": {"name": "n"},
         "variable": [{"key": "a", "value": "https://{{b}}"}, {"key": "b", "value": "{{a}}"}],
         "item": [{"request": {"method": "GET", "url": "{{a}}/x"}}]}
        JSON
    end
  end

  it "skips a URL with a braced host but keeps a brace in the path" do
    # `Vars.unresolved` only sees `{{`, and `Builder::HOST_INVALID` does not reject `{`/`}`,
    # so a single-brace host (a template form this parser does not speak, or a variable whose
    # value was a JSON object) would be stored as a structurally impossible host. A brace in
    # the PATH is the operator's own data and stays verbatim.
    result = parse(<<-JSON)
      {"info": {"name": "n"},
       "variable": [{"key": "ok", "value": "good.test"}],
       "item": [
         {"request": {"method": "GET", "url": "https://{host}.test/x"}},
         {"request": {"method": "GET", "url": "https://{{ok}}/p/{literal}"}}]}
      JSON
    result.skipped.should eq(1)
    result.flows.size.should eq(1)
    result.flows.first.request.host.should eq("good.test")
    result.flows.first.request.target.should eq("/p/{literal}")
  end

  it "skips an entry whose URL still holds an unresolved variable" do
    # Builder::HOST_INVALID does not reject `{`/`}`, so without this guard the flow would be
    # STORED with a literal host of `{{baseUrl}}` — unsendable, and indistinguishable in
    # History from a real capture.
    result = parse(<<-JSON)
      {"info": {"name": "n"},
       "variable": [{"key": "ok", "value": "https://good.test"}],
       "item": [
         {"request": {"method": "GET", "url": "{{ok}}/yes"}},
         {"request": {"method": "GET", "url": "{{missing}}/no"}}]}
      JSON
    result.flows.size.should eq(1)
    result.skipped.should eq(1)
    result.flows.first.request.host.should eq("good.test")
  end

  it "names the missing variables when EVERY entry was skipped for one" do
    # The generic "all N entries were skipped as malformed" blames the file; a collection
    # whose {{baseUrl}} lives in a separate environment export is not malformed at all.
    ex = expect_raises(Gori::Error) do
      parse(<<-JSON)
        {"info": {"name": "n"},
         "item": [
           {"request": {"method": "GET", "url": "{{baseUrl}}/a"}},
           {"request": {"method": "GET", "url": "{{baseUrl}}/b?k={{apiKey}}"}}]}
        JSON
    end
    msg = ex.message.not_nil!
    msg.should contain("{{apiKey}}")
    msg.should contain("{{baseUrl}}")
    msg.should contain("2 entries reference")
    msg.should_not contain("malformed")
  end

  it "fills :pathVariable from url.variable" do
    result = parse(<<-JSON)
      {"info": {"name": "n"},
       "item": [{"request": {"method": "GET", "url": {
          "raw": "https://a.test:8443/users/:id/posts/:slug",
          "variable": [{"key": "id", "value": "42"}]}}}]}
      JSON
    # `id` is declared and substituted; `:slug` is not declared and passes through, and
    # neither `https://` nor the `:8443` port is touched.
    result.flows.first.request.target.should eq("/users/42/posts/:slug")
    result.flows.first.request.port.should eq(8443)
  end

  it "drops disabled headers and keeps duplicates in order" do
    result = parse(<<-JSON)
      {"info": {"name": "n"},
       "item": [{"request": {"method": "GET", "url": "https://a.test/h", "header": [
          {"key": "X-Keep", "value": "1"},
          {"key": "X-Drop", "value": "2", "disabled": true},
          {"key": "X-Keep", "value": "3"}]}}]}
      JSON
    head = heads(result).first
    head.should contain("X-Keep: 1\r\n")
    head.should contain("X-Keep: 3\r\n")
    head.should_not contain("X-Drop")
  end

  it "builds each supported body mode and its Content-Type" do
    result = parse(<<-JSON)
      {"info": {"name": "n"},
       "item": [
         {"request": {"method": "POST", "url": "https://a.test/raw",
           "body": {"mode": "raw", "raw": "{\\"a\\":1}", "options": {"raw": {"language": "json"}}}}},
         {"request": {"method": "POST", "url": "https://a.test/form",
           "body": {"mode": "urlencoded", "urlencoded": [
             {"key": "u", "value": "a b"}, {"key": "p", "value": "q&z"},
             {"key": "off", "value": "x", "disabled": true}]}}},
         {"request": {"method": "POST", "url": "https://a.test/multi",
           "body": {"mode": "formdata", "formdata": [
             {"key": "field", "value": "val"},
             {"key": "upload", "type": "file", "src": "/etc/passwd"}]}}},
         {"request": {"method": "POST", "url": "https://a.test/gql",
           "body": {"mode": "graphql", "graphql": {"query": "{ me }", "variables": "{\\"n\\":1}"}}}},
         {"request": {"method": "POST", "url": "https://a.test/file",
           "body": {"mode": "file", "file": {"src": "/etc/passwd"}}}}]}
      JSON
    bodies = result.flows.map { |f| f.request.body.try { |b| String.new(b) } }
    bodies[0].should eq(%({"a":1}))
    bodies[1].should eq("u=a+b&p=q%26z")
    bodies[2].not_nil!.should contain(%(Content-Disposition: form-data; name="field"))
    bodies[2].not_nil!.should_not contain("upload") # a `file` part names a path on the exporter's disk
    bodies[3].should eq(%({"query":"{ me }","variables":{"n":1}}))
    bodies[4].should be_nil # `file` mode reads nothing off the local filesystem

    head_types = heads(result).map do |h|
      h.lines.find(&.starts_with?("Content-Type")).try(&.chomp)
    end
    head_types[0].should eq("Content-Type: application/json")
    head_types[1].should eq("Content-Type: application/x-www-form-urlencoded")
    head_types[2].not_nil!.should start_with("Content-Type: multipart/form-data; boundary=")
    head_types[3].should eq("Content-Type: application/json")
    head_types[4].should be_nil
  end

  it "lets an explicit Content-Type header win over the body mode's" do
    result = parse(<<-JSON)
      {"info": {"name": "n"},
       "item": [{"request": {"method": "POST", "url": "https://a.test/x",
          "header": [{"key": "Content-Type", "value": "application/vnd.api+json"}],
          "body": {"mode": "raw", "raw": "{}", "options": {"raw": {"language": "json"}}}}}]}
      JSON
    head = heads(result).first
    head.should contain("Content-Type: application/vnd.api+json")
    head.should_not contain("Content-Type: application/json")
  end

  it "seeds bearer / basic / apikey-header auth and nothing else" do
    result = parse(<<-JSON)
      {"info": {"name": "n"},
       "item": [
         {"request": {"method": "GET", "url": "https://a.test/b",
           "auth": {"type": "bearer", "bearer": [{"key": "token", "value": "T"}]}}},
         {"request": {"method": "GET", "url": "https://a.test/basic",
           "auth": {"type": "basic", "basic": [
             {"key": "username", "value": "u"}, {"key": "password", "value": "p"}]}}},
         {"request": {"method": "GET", "url": "https://a.test/key",
           "auth": {"type": "apikey", "apikey": [
             {"key": "key", "value": "X-Token"}, {"key": "value", "value": "V"}]}}},
         {"request": {"method": "GET", "url": "https://a.test/oauth",
           "auth": {"type": "oauth2", "oauth2": [{"key": "accessToken", "value": "A"}]}}}]}
      JSON
    hs = heads(result)
    hs[0].should contain("Authorization: Bearer T")
    hs[1].should contain("Authorization: Basic dTpw") # base64("u:p")
    hs[2].should contain("X-Token: V")
    # oauth2/awsv4/ntlm/digest/hawk need a live exchange or a signing step; a fabricated
    # header would be worse than none.
    hs[3].should_not contain("Authorization")
  end

  it "inherits collection auth, lets a folder or request override it, and honours noauth" do
    result = parse(<<-JSON)
      {"info": {"name": "n"},
       "auth": {"type": "bearer", "bearer": [{"key": "token", "value": "ROOT"}]},
       "item": [
         {"request": {"method": "GET", "url": "https://a.test/inherit"}},
         {"name": "f", "auth": {"type": "bearer", "bearer": [{"key": "token", "value": "FOLDER"}]},
          "item": [{"request": {"method": "GET", "url": "https://a.test/folder"}}]},
         {"request": {"method": "GET", "url": "https://a.test/own",
           "auth": {"type": "bearer", "bearer": [{"key": "token", "value": "OWN"}]}}},
         {"request": {"method": "GET", "url": "https://a.test/none", "auth": {"type": "noauth"}}}]}
      JSON
    hs = heads(result)
    hs[0].should contain("Bearer ROOT")
    hs[1].should contain("Bearer FOLDER")
    hs[2].should contain("Bearer OWN")
    hs[3].should_not contain("Authorization")
  end

  it "rejects a v1 collection with an actionable message" do
    ex = expect_raises(Gori::Error) do
      parse(%({"id": "x", "name": "old", "requests": [{"url": "https://a.test/"}]}))
    end
    ex.message.not_nil!.should contain("v2.1")
  end

  it "raises a clean error on invalid JSON and on a wrong-shaped document" do
    expect_raises(Gori::Error, /not valid JSON/) { parse("{nope") }
    expect_raises(Gori::Error, /not a JSON object/) { parse("[]") }
    expect_raises(Gori::Error, /no `item` array/) { parse(%({"info": {"name": "n"}})) }
  end

  it "imports end to end through Import.import_file" do
    with_collection(<<-JSON) do |path|
      {"info": {"name": "n"},
       "variable": [{"key": "baseUrl", "value": "https://shop.test"}],
       "item": [{"name": "f", "item": [
         {"request": {"method": "POST", "url": "{{baseUrl}}/cart",
          "body": {"mode": "raw", "raw": "qty=1"}}}]}]}
      JSON
      with_store do |store|
        result = Gori::Import.import_file(store, :postman, path)
        result.count.should eq(1)
        row = store.search(Gori::QL::EMPTY, 10).first
        row.host.should eq("shop.test")
        row.method.should eq("POST")
        row.target.should eq("/cart")
        row.status.should be_nil # a template, never a fabricated response
        String.new(store.get_flow(row.id).not_nil!.request_body.not_nil!).should eq("qty=1")
      end
    end
  end
end
