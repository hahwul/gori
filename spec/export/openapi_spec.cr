require "../spec_helper"
require "compress/gzip"

# `Gori::Export::OpenApi` (#1241) — an OpenAPI 3.0.3 document from captured traffic.

private alias OA = Gori::Export::OpenApi

private OA_CLOCK = [1_780_000_000_000_000_i64]

# One captured exchange, through the real Store writer. `req_headers` / `resp_headers` are
# "Name: value\r\n" lines after Host / the status line.
private def oa_flow(store : Gori::Store, target : String, *, host = "api.test", scheme = "https",
                    port = 443, method = "GET", req_headers = "", body : (String | Bytes)? = nil,
                    status = 200, resp_headers = "", resp_body : (String | Bytes)? = nil,
                    content_type : String? = nil, complete = true) : Int64
  OA_CLOCK[0] += 1000
  b = body.is_a?(String) ? body.to_slice : body
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: OA_CLOCK[0], scheme: scheme, host: host, port: port, method: method,
    target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n#{req_headers}\r\n".to_slice,
    body: b, source: Gori::FlowSource::Kind::Proxy))
  return id unless complete
  rb = resp_body.is_a?(String) ? resp_body.to_slice : resp_body
  ct_line = content_type ? "Content-Type: #{content_type}\r\n" : ""
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, reason: "X", content_type: content_type,
    head: "HTTP/1.1 #{status} X\r\n#{ct_line}#{resp_headers}\r\n".to_slice, body: rb))
  id
end

private def json_post(store, target, body : String, **opts)
  oa_flow(store, target, **opts, method: "POST", body: body,
    req_headers: "Content-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n")
end

private def op(doc : JSON::Any, path : String, method : String) : JSON::Any
  doc["paths"][path]?.try(&.[method]?) ||
    raise "no #{method} #{path} in #{doc["paths"].as_h.keys}"
end

private def param(o : JSON::Any, name : String, loc : String) : JSON::Any?
  o["parameters"]?.try(&.as_a.find { |p| p["name"] == name && p["in"] == loc })
end

private def with_salt(&)
  before = Gori::Redact.salt
  Gori::Redact.salt = "spec-salt"
  begin
    yield
  ensure
    Gori::Redact.salt = before
  end
end

describe Gori::Export::OpenApi do
  it "templates numeric ids and merges endpoints whose templates collide" do
    with_store do |store|
      oa_flow(store, "/users/1", content_type: "application/json", resp_body: %({"id":1}))
      oa_flow(store, "/users/2?expand=true", content_type: "application/json", resp_body: %({"id":2}))
      oa_flow(store, "/users/7/orders/9f1c2b7d0a4e", content_type: "application/json", resp_body: "[]")
      result = OA.build(store)
      doc = result.doc
      doc["openapi"].should eq("3.0.3")
      doc["paths"].as_h.keys.should eq(["/users/{userId}", "/users/{userId}/orders/{orderId}"])
      get = op(doc, "/users/{userId}", "get")
      get["operationId"].should eq("getUsersByUserId")
      id = param(get, "userId", "path").not_nil!
      id["required"].should be_true
      id["schema"].should eq(JSON.parse(%({"type":"integer"})))
      id["example"]?.should be_nil # no examples unless asked
      # `expand` was on one of the two samples, so it is optional.
      param(get, "expand", "query").not_nil!["required"]?.should be_nil
      nested = op(doc, "/users/{userId}/orders/{orderId}", "get")
      param(nested, "orderId", "path").not_nil!["schema"]["type"].should eq("string")
      result.report.operations.should eq(2)
      result.report.flows_read.should eq(3)
    end
  end

  it "keeps a date and a number at one path position as ONE path, typed as a string" do
    with_store do |store|
      oa_flow(store, "/reports/2026-07-19")
      oa_flow(store, "/reports/123")
      doc = OA.build(store).doc
      doc["paths"].as_h.keys.should eq(["/reports/{reportId}"])
      param(op(doc, "/reports/{reportId}", "get"), "reportId", "path").not_nil!["schema"]
        .should eq(JSON.parse(%({"type":"string"})))
    end
  end

  it "never writes a token that sat in a path, examples or not" do
    with_store do |store|
      jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJlLXBhcnQ"
      oa_flow(store, "/reset/#{jwt}")
      oa_flow(store, "/login;jsessionid=ABCDEF0123456789XYZ")
      text = OA.to_json(OA.build(store).doc)
      text.should_not contain("eyJ")
      text.should_not contain("ABCDEF0123456789XYZ")
      text.should contain(%("/login"))
    end
  end

  it "survives a host and names that are not UTF-8, in both formats" do
    with_store do |store|
      raw = String.new(Bytes[0x61, 0xff])
      oa_flow(store, "/x?#{raw}=1", host: "h#{raw}.test")
      doc = OA.build(store).doc
      OA.to_yaml(doc).should contain("openapi")
      OA.to_json(doc).valid_encoding?.should be_true
    end
  end

  it "marks a parameter required only when every sample of its operation carried it" do
    with_store do |store|
      oa_flow(store, "/search?q=a&page=1", req_headers: "X-Tenant: acme\r\n")
      oa_flow(store, "/search?q=b", req_headers: "X-Tenant: acme\r\nUser-Agent: curl\r\n")
      doc = OA.build(store).doc
      get = op(doc, "/search", "get")
      param(get, "q", "query").not_nil!["required"].should be_true
      param(get, "page", "query").not_nil!["required"]?.should be_nil
      param(get, "page", "query").not_nil!["schema"]["type"].should eq("integer")
      param(get, "x-tenant", "header").not_nil!["required"].should be_true
      # Standard browser headers are not parameters.
      param(get, "user-agent", "header").should be_nil
      param(get, "host", "header").should be_nil
    end
  end

  it "reads a repeated query key as an array" do
    with_store do |store|
      oa_flow(store, "/filter?tag=a&tag=b")
      p = param(op(OA.build(store).doc, "/filter", "get"), "tag", "query").not_nil!
      p["schema"].should eq(JSON.parse(%({"type":"array","items":{"type":"string"}})))
    end
  end

  it "infers and merges JSON request and response schemas" do
    with_store do |store|
      json_post(store, "/orders", %({"sku":"a1","qty":1,"note":"x"}),
        status: 201, content_type: "application/json", resp_body: %({"id":10,"items":[{"sku":"a1"}]}))
      json_post(store, "/orders", %({"sku":"b2","qty":2.5,"tags":["x"]}),
        status: 201, content_type: "application/json", resp_body: %({"id":11,"items":[]}))
      oa_flow(store, "/orders", method: "POST", body: "nope", status: 400,
        req_headers: "Content-Type: text/plain\r\nContent-Length: 4\r\n",
        content_type: "text/html", resp_body: "<b>bad</b>")
      post = op(OA.build(store).doc, "/orders", "post")
      rb = post["requestBody"]
      # Two of three samples were JSON, one was text: the body is always present, so required.
      rb["required"].should be_true
      schema = rb["content"]["application/json"]["schema"]
      schema["type"].should eq("object")
      schema["required"].should eq(JSON.parse(%(["qty","sku"])))
      schema["properties"]["qty"].should eq(JSON.parse(%({"type":"number"}))) # integer + number widens
      schema["properties"]["tags"].should eq(JSON.parse(%({"type":"array","items":{"type":"string"}})))
      rb["content"]["text/plain"]["schema"].should eq(JSON.parse(%({"type":"string"})))
      post["responses"].as_h.keys.should eq(["201", "400"])
      post["responses"]["201"]["description"].should eq("Created")
      created = post["responses"]["201"]["content"]["application/json"]["schema"]
      created["properties"]["items"]["items"]["properties"]["sku"]["type"].should eq("string")
      post["responses"]["400"]["content"]["text/html"]["schema"]["type"].should eq("string")
    end
  end

  it "keys a status OpenAPI cannot hold under `default`, naming it" do
    with_store do |store|
      oa_flow(store, "/li", status: 999, content_type: "text/html", resp_body: "<p>no</p>")
      oa_flow(store, "/li", status: 200)
      responses = op(OA.build(store).doc, "/li", "get")["responses"]
      responses.as_h.keys.should eq(["200", "default"])
      responses["default"]["description"].should eq("Non-standard status 999")
      responses["default"]["content"]["text/html"]["schema"]["type"].should eq("string")
    end
  end

  it "decodes a gzip'd JSON response before inferring its schema" do
    with_store do |store|
      io = IO::Memory.new
      Compress::Gzip::Writer.open(io) { |gz| gz << %({"ok":true}) }
      oa_flow(store, "/ping", content_type: "application/json",
        resp_headers: "Content-Encoding: gzip\r\n", resp_body: io.to_slice)
      schema = op(OA.build(store).doc, "/ping", "get")["responses"]["200"]["content"]["application/json"]["schema"]
      schema["properties"]["ok"]["type"].should eq("boolean")
    end
  end

  it "describes urlencoded and multipart forms as object schemas" do
    with_store do |store|
      oa_flow(store, "/login", method: "POST", body: "user=ada&remember=true",
        req_headers: "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: 22\r\n")
      mp = "--B\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nhi\r\n" \
           "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.png\"\r\n" \
           "Content-Type: image/png\r\n\r\n\x89PNG\r\n--B--\r\n"
      oa_flow(store, "/upload", method: "POST", body: mp,
        req_headers: "Content-Type: multipart/form-data; boundary=B\r\nContent-Length: #{mp.bytesize}\r\n")
      doc = OA.build(store).doc
      form = op(doc, "/login", "post")["requestBody"]["content"]["application/x-www-form-urlencoded"]["schema"]
      form["properties"]["remember"]["type"].should eq("boolean")
      form["required"].should eq(JSON.parse(%(["remember","user"])))
      multi = op(doc, "/upload", "post")["requestBody"]["content"]["multipart/form-data"]["schema"]
      multi["properties"]["file"].should eq(JSON.parse(%({"type":"string","format":"binary"})))
      multi["properties"]["title"]["type"].should eq("string")
    end
  end

  it "skips sockets, streams, gRPC and incomplete flows, and counts them" do
    with_store do |store|
      oa_flow(store, "/ok")
      oa_flow(store, "/ws", status: 101, req_headers: "Upgrade: websocket\r\nConnection: Upgrade\r\n")
      oa_flow(store, "/feed", content_type: "text/event-stream")
      oa_flow(store, "/svc.Greeter/Hello", method: "POST", content_type: "application/grpc")
      oa_flow(store, "/pending", complete: false)
      oa_flow(store, "/dav", method: "PROPFIND")
      result = OA.build(store)
      result.doc["paths"].as_h.keys.should eq(["/ok"])
      skipped = result.report.skipped
      skipped[OA::Skip::WebSocket].should eq(1)
      skipped[OA::Skip::Sse].should eq(1)
      skipped[OA::Skip::Grpc].should eq(1)
      skipped[OA::Skip::Incomplete].should eq(1)
      skipped[OA::Skip::Method].should eq(1)
      result.report.notes.first.should contain("skipped")
    end
  end

  it "turns credentials into security schemes and never emits their values" do
    with_store do |store|
      oa_flow(store, "/me", req_headers: "Authorization: Bearer s3cr3t-bearer\r\nCookie: sid=s3cr3t-sid; theme=dark\r\n")
      oa_flow(store, "/me", req_headers: "X-Api-Key: s3cr3t-key\r\n")
      oa_flow(store, "/me")
      result = OA.build(store)
      text = OA.to_json(result.doc)
      text.should_not contain("s3cr3t")
      schemes = result.doc["components"]["securitySchemes"]
      schemes["bearerAuth"].should eq(JSON.parse(%({"type":"http","scheme":"bearer"})))
      schemes["cookie.sid"].should eq(JSON.parse(%({"type":"apiKey","in":"cookie","name":"sid"})))
      schemes["header.x-api-key"]["name"].should eq("x-api-key")
      get = op(result.doc, "/me", "get")
      param(get, "authorization", "header").should be_nil
      param(get, "sid", "cookie").should be_nil
      param(get, "theme", "cookie").not_nil!["required"]?.should be_nil
      # One requirement per set of schemes seen together, and `{}` for the anonymous sample.
      get["security"].should eq(JSON.parse(%([{"bearerAuth":[],"cookie.sid":[]},{"header.x-api-key":[]},{}])))
    end
  end

  it "redacts example values through the profile, and keeps credentials out entirely" do
    with_salt do
      with_store do |store|
        oa_flow(store, "/login?token=qs-secret&lang=en", method: "POST",
          body: %({"user":"ada","password":"pw-secret"}),
          req_headers: "Content-Type: application/json\r\nAuthorization: Bearer hdr-secret\r\n" \
                       "Cookie: theme=cookie-secret\r\n",
          content_type: "application/json", resp_body: %({"access_token":"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig-part","ok":true}))
        plain = OA.to_json(OA.build(store).doc)
        {"qs-secret", "pw-secret", "hdr-secret", "cookie-secret", "eyJ"}.each { |s| plain.should_not contain(s) }
        plain.should_not contain("\"example\"")

        oa_flow(store, "/keys?key=AIzaSyA-goog&api-key=dash-secret&sig=sas-secret&page=2",
          req_headers: "X-Access-Token: xat-secret\r\nPrivate-Token: glpat-secret\r\nX-Trace: t1\r\n")
        oa_flow(store, "/otp/482913")
        oa_flow(store, "/accounts/9876543210")
        result = OA.build(store, OA::Options.new(examples: true))
        text = OA.to_json(result.doc)
        {"AIzaSyA-goog", "dash-secret", "sas-secret", "xat-secret", "glpat-secret", "482913", "9876543210"}.each do |s|
          text.should_not contain(s)
        end
        keys = op(result.doc, "/keys", "get")
        param(keys, "page", "query").not_nil!["example"].should eq("2")
        param(keys, "x-trace", "header").not_nil!["example"].should eq("t1")
        {"qs-secret", "pw-secret", "hdr-secret", "cookie-secret", "eyJhbGci"}.each { |s| text.should_not contain(s) }
        post = op(result.doc, "/login", "post")
        param(post, "lang", "query").not_nil!["example"].should eq("en")
        param(post, "token", "query").not_nil!["example"].as_s.should start_with("[REDACTED:")
        param(post, "theme", "cookie").not_nil!["example"].as_s.should start_with("[REDACTED:")
        ex = post["requestBody"]["content"]["application/json"]["example"]
        ex["user"].should eq("ada")
        ex["password"].as_s.should start_with("[REDACTED:")
        post["responses"]["200"]["content"]["application/json"]["example"]["ok"].should be_true
        # token, cookie, password, access_token; key, api-key, sig, x-access-token, private-token
        result.report.redacted.should eq(9)
      end
    end
  end

  it "never gives an opaque path id an example" do
    with_salt do
      with_store do |store|
        oa_flow(store, "/reset/3f1c9ab4-0000-4000-8000-00000000abcd")
        oa_flow(store, "/items/42")
        doc = OA.build(store, OA::Options.new(examples: true)).doc
        param(op(doc, "/reset/{resetId}", "get"), "resetId", "path").not_nil!["example"]?.should be_nil
        param(op(doc, "/items/{itemId}", "get"), "itemId", "path").not_nil!["example"].should eq("42")
      end
    end
  end

  # Insertion order is what a Hash iterates in, so a determinism check that builds twice from
  # ONE store would pass with every sort removed. Two stores, same flows, opposite order.
  it "exports the same flows captured in a different order to the same bytes" do
    seeds = [
      ->(s : Gori::Store) { json_post(s, "/b/1", %({"z":1,"a":[1,"x"]}), content_type: "application/json", resp_body: %({"k":null})); nil },
      ->(s : Gori::Store) { oa_flow(s, "/a?y=1&x=2", req_headers: "Cookie: b=1; a=2\r\nX-B: 1\r\nX-A: 2\r\n"); nil },
      ->(s : Gori::Store) { oa_flow(s, "/a", method: "DELETE", status: 204); nil },
      ->(s : Gori::Store) { oa_flow(s, "/a", host: "z.test", status: 404, content_type: "text/html", resp_body: "x"); nil },
      ->(s : Gori::Store) { oa_flow(s, "/c", req_headers: "Authorization: Bearer x\r\nX-Api-Key: k\r\n"); nil },
    ]
    one = with_store { |s| seeds.each(&.call(s)); OA.to_json(OA.build(s).doc) }
    two = with_store { |s| seeds.reverse_each(&.call(s)); OA.to_json(OA.build(s).doc) }
    one.should eq(two)
  end

  it "is deterministic: the same flow set exports to the same bytes" do
    with_store do |store|
      json_post(store, "/b/1", %({"z":1,"a":[1,"x"]}), content_type: "application/json", resp_body: %({"k":null}))
      oa_flow(store, "/a?y=1&x=2", req_headers: "Cookie: b=1; a=2\r\n")
      oa_flow(store, "/a", method: "DELETE", status: 204)
      one = OA.to_json(OA.build(store).doc)
      two = OA.to_json(OA.build(store).doc)
      one.should eq(two)
      OA.to_yaml(OA.build(store).doc).should eq(OA.to_yaml(OA.build(store).doc))
      one.should_not match(/\d{4}-\d{2}-\d{2}T/)                            # no timestamps
      JSON.parse(one)["paths"]["/a"].as_h.keys.should eq(["get", "delete"]) # the spec's method order
    end
  end

  it "lists every origin, and scopes servers per path only when hosts differ" do
    with_store do |store|
      oa_flow(store, "/x", host: "api.test")
      oa_flow(store, "/x", host: "api.test", scheme: "http", port: 8080)
      single = OA.build(store).doc
      single["servers"].should eq(JSON.parse(%([{"url":"http://api.test:8080"},{"url":"https://api.test"}])))
      single["paths"]["/x"]["servers"]?.should be_nil
      single["info"]["title"].should eq("api.test")

      oa_flow(store, "/y", host: "cdn.test")
      multi = OA.build(store).doc
      multi["paths"]["/y"]["servers"].should eq(JSON.parse(%([{"url":"https://cdn.test"}])))
      multi["info"]["title"].should eq("Captured API")
      OA.build(store, OA::Options.new(host: "CDN.test")).doc["paths"].as_h.keys.should eq(["/y"])
    end
  end

  it "honours the sample and endpoint caps, and says so" do
    with_store do |store|
      5.times { |i| oa_flow(store, "/a/#{i}") }
      oa_flow(store, "/b")
      oa_flow(store, "/c")
      result = OA.build(store, OA::Options.new(max_samples: 2, max_endpoints: 2))
      # Newest first: /c and /b claim the two operations, /a is dropped.
      result.doc["paths"].as_h.keys.should eq(["/b", "/c"])
      result.report.endpoints_dropped.should eq(1)
      result.report.truncated?.should be_true

      capped = OA.build(store, OA::Options.new(max_samples: 2))
      capped.report.samples_capped.should eq(3)
      capped.report.flows_read.should eq(4)
    end
  end

  it "narrows to a TUI target set: whole hosts, or endpoint paths under one" do
    with_store do |store|
      oa_flow(store, "/a", host: "one.test")
      oa_flow(store, "/b", host: "one.test")
      oa_flow(store, "/c", host: "two.test")
      targets = {"one.test" => Set{"/b"}.as(Set(String)?), "two.test" => nil.as(Set(String)?)}
      doc = OA.build(store, OA::Options.new(targets: targets)).doc
      doc["paths"].as_h.keys.should eq(["/b", "/c"])
    end
  end

  it "percent-encodes literal braces so a captured `{x}` is not read back as a template" do
    with_store do |store|
      oa_flow(store, "/tpl/%7Bid%7D")
      oa_flow(store, "/raw/{id}")
      doc = OA.build(store).doc
      doc["paths"].as_h.keys.sort!.should eq(["/raw/%7Bid%7D", "/tpl/%7Bid%7D"])
    end
  end

  describe ".fit" do
    it "drops whole paths from the end until the document fits" do
      with_store do |store|
        %w[/a /b /c /d].each { |p| oa_flow(store, p) }
        doc = OA.build(store).doc
        full = doc.to_json.bytesize
        cut, dropped = OA.fit(doc, full - 10)
        dropped.should eq(1)
        cut["paths"].as_h.keys.should eq(["/a", "/b", "/c"])
        cut.to_json.bytesize.should be <= full - 10
        OA.fit(doc, full).should eq({doc, 0})
      end
    end
  end

  # The export's portability claim, checked against gori's own importer: every operation
  # comes back as the same method on the same template, with the required query and header
  # names and the body media type the capture proved. Values are NOT compared — the importer
  # stubs them (`sample_value`), which is its known limit.
  {"json", "yaml"}.each do |format|
    it "round-trips through Import::Oas (#{format})" do
      with_store do |store|
        oa_flow(store, "/users/1?fields=name", req_headers: "X-Tenant: acme\r\n")
        oa_flow(store, "/users/2?fields=id&debug=1", req_headers: "X-Tenant: acme\r\n")
        json_post(store, "/users/3/notes", %({"text":"hi"}), status: 201)
        oa_flow(store, "/users/3/notes/9", method: "DELETE", status: 204, req_headers: "X-Api-Key: k\r\n")
        doc = OA.build(store).doc
        path = File.tempname("gori-oas", ".#{format}")
        begin
          File.write(path, format == "json" ? OA.to_json(doc) : OA.to_yaml(doc))
          parsed = Gori::Import::Oas.parse_file(path)
          parsed.skipped.should eq(0)
          got = parsed.flows.map do |pair|
            req = pair.request
            path_only, _, query = req.target.partition('?')
            head = String.new(req.head)
            headers = head.lines[1..].compact_map { |l| l.partition(':')[0].strip.downcase.presence }
            {
              req.method,
              OA::Template.of(path_only).path,
              URI::Params.parse(query).map { |k, _| k }.sort!,
              (headers - ["host", "content-type", "content-length"]).sort,
              head.lines.find(&.downcase.starts_with?("content-type:")).try(&.partition(':')[2].strip),
            }
          end
          got.sort_by { |g| {g[1], g[0]} }.should eq([
            {"GET", "/users/{userId}", ["fields"], ["x-tenant"], nil},
            {"POST", "/users/{userId}/notes", [] of String, [] of String, "application/json"},
            {"DELETE", "/users/{userId}/notes/{noteId}", [] of String, ["x-api-key"], nil},
          ])
        ensure
          File.delete?(path)
        end
      end
    end
  end
end
