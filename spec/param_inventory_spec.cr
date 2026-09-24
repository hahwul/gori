require "./spec_helper"
require "compress/gzip"

private alias PI = Gori::ParamInventory
private alias PL = Gori::Miner::Location

private CLOCK = [1_700_000_000_000_000_i64]

# One captured exchange. `req_headers` go into the request head after Host; `resp_headers`
# into the response head.
private def pi_flow(store : Gori::Store, target : String, *, host = "shop.test", method = "GET",
                    req_headers = "", body : (String | Bytes)? = nil,
                    resp_body : String | Bytes = "", resp_headers = "") : Int64
  CLOCK[0] += 1000
  b = body.is_a?(String) ? body.to_slice : body
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: CLOCK[0], scheme: "https", host: host, port: 443,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n#{req_headers}\r\n".to_slice,
    body: b, source: Gori::FlowSource::Kind::Proxy))
  rb = resp_body.is_a?(String) ? resp_body.to_slice : resp_body
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n#{resp_headers}\r\n".to_slice, body: rb))
  id
end

private def row(report : PI::Report, name : String, path : String? = nil) : PI::Row
  report.rows.find { |r| r.name == name && (path.nil? || r.path == path) } ||
    raise "no row #{name.inspect} in #{report.rows.map { |r| {r.path, r.name} }}"
end

describe Gori::ParamInventory do
  it "groups by the Sitemap node path with the query cut, counting flows" do
    with_store do |store|
      a = pi_flow(store, "/search?q=shoes&page=1")
      b = pi_flow(store, "https://shop.test/search?q=hats")
      pi_flow(store, "/cart?id=9")
      report = PI.build(store)
      q = row(report, "q")
      q.path.should eq("/search")
      q.method.should eq("GET")
      q.location.should eq(PL::Query)
      q.count.should eq(2)
      q.samples.sort.should eq(["hats", "shoes"])
      {q.first_flow_id, q.last_flow_id}.should eq({a, b})
      row(report, "page").count.should eq(1)
      row(report, "id").path.should eq("/cart")
      report.flows_scanned.should eq(3)
      report.truncated.should be_false
    end
  end

  it "counts a name once per flow however often the body repeats it" do
    with_store do |store|
      pi_flow(store, "/api/items", method: "POST", req_headers: "Content-Type: application/json\r\n",
        body: %({"items":[{"id":1},{"id":2},{"id":3}]}))
      r = row(PI.build(store), "items[].id")
      r.count.should eq(1)
      r.samples.should eq(["1", "2", "3"])
    end
  end

  it "caps distinct samples and says it did" do
    with_store do |store|
      7.times { |i| pi_flow(store, "/s?q=value#{i}") }
      r = row(PI.build(store, PI::Options.new(samples: 3)), "q")
      r.count.should eq(7)
      r.samples.size.should eq(3)
      r.samples_truncated.should be_true
    end
  end

  it "marks a value reflected in the response body, and not a short one" do
    with_store do |store|
      id = pi_flow(store, "/s?q=needle&n=ab", resp_body: "<p>results for needle ab</p>")
      pi_flow(store, "/s?miss=haystack", resp_body: "<p>nothing</p>")
      report = PI.build(store)
      q = row(report, "q")
      q.reflected.should be_true
      q.reflected_flow_id.should eq(id)
      row(report, "n").reflected.should be_false # 2 bytes: under min_reflect
      row(report, "miss").reflected.should be_false
    end
  end

  # `true` / `3600` are how JSON SPELLS a value and turn up in nearly any JSON response, so a
  # literal is never called reflected; a string the client chose is.
  it "does not call a JSON number/bool literal reflected" do
    with_store do |store|
      pi_flow(store, "/p", method: "POST", req_headers: "Content-Type: application/json\r\n",
        body: %({"newsletter":true,"ttl":36000,"name":"Alice"}),
        resp_body: %({"newsletter":true,"ttl":36000,"name":"Alice"}))
      report = PI.build(store)
      row(report, "newsletter").reflected.should be_false
      row(report, "ttl").reflected.should be_false
      row(report, "name").reflected.should be_true
    end
  end

  # The search is budgeted (REFLECT_WINDOW): a value only past the window reads
  # not-reflected rather than costing a scan of the whole response on every flow.
  it "searches only the head of a large response" do
    with_store do |store|
      filler = "x" * (PI::REFLECT_WINDOW + 10)
      pi_flow(store, "/s?early=needle1&late=needle2", resp_body: "needle1 #{filler} needle2")
      report = PI.build(store, PI::Options.new(body_max: 2 * PI::REFLECT_WINDOW))
      row(report, "early").reflected.should be_true
      row(report, "late").reflected.should be_false
    end
  end

  it "searches the DECODED response entity for a reflection" do
    with_store do |store|
      io = IO::Memory.new
      Compress::Gzip::Writer.open(io) { |gz| gz << "echo: canary123" }
      pi_flow(store, "/s?q=canary123", resp_body: io.to_slice, resp_headers: "Content-Encoding: gzip\r\n")
      row(PI.build(store), "q").reflected.should be_true
    end
  end

  it "flags credential material and masks it unless asked" do
    with_store do |store|
      pi_flow(store, "/login", method: "POST",
        req_headers: "Content-Type: application/x-www-form-urlencoded\r\nAuthorization: Bearer abc\r\nCookie: sid=s3cret\r\n",
        body: "user=jay&password=hunter2")
      report = PI.build(store)
      %w[password authorization sid].each do |n|
        r = row(report, n)
        r.sensitive.should be_true
        PI.masked(r, include_sensitive: false).should eq(["[REDACTED]"])
        PI.masked(r, include_sensitive: true).should_not eq(["[REDACTED]"])
      end
      user = row(report, "user")
      user.sensitive.should be_false
      PI.masked(user, include_sensitive: false).should eq(["jay"])
    end
  end

  it "flags a JWT-shaped value under an innocuous name" do
    with_store do |store|
      jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.sig"
      pi_flow(store, "/s?state=#{jwt}")
      row(PI.build(store), "state").sensitive.should be_true
    end
  end

  it "stops at max_flows, newest first, and reports the cut" do
    with_store do |store|
      5.times { |i| pi_flow(store, "/p#{i}?x=1") }
      report = PI.build(store, PI::Options.new(max_flows: 2))
      report.flows_scanned.should eq(2)
      report.truncated.should be_true
      report.rows.map(&.path).sort!.should eq(["/p3", "/p4"])
    end
  end

  # A narrow prefix must not be starved by newer flows elsewhere: rows outside it are judged
  # before their bodies are read and do not count against max_flows.
  it "does not spend max_flows on flows outside the path prefix" do
    with_store do |store|
      pi_flow(store, "/admin?role=1")
      3.times { pi_flow(store, "/static/app.js?v=1") }
      report = PI.build(store, PI::Options.new(path_prefix: "/admin", max_flows: 1))
      report.rows.map(&.name).should eq(["role"])
      report.flows_scanned.should eq(1)
      report.truncated.should be_false
    end
  end

  # The project's own redaction profile is what `get_flow` masks with; a field it names must
  # not come back from the inventory as an ordinary sample.
  it "honours the project's configured redaction profile" do
    with_store do |store|
      profile = Gori::Redact::Profile.new("engagement", json_fields: ["email"], patterns: ["acct-\\d+"])
      Gori::Redact::Policy.write_project_scope(store,
        Gori::Redact::Policy::ProjectScope.new(active: "engagement", profiles: [profile]))
      pi_flow(store, "/u", method: "POST", req_headers: "Content-Type: application/json\r\n",
        body: %({"email":"a@b.c","ref":"acct-12345","name":"Al"}))
      report = PI.build(store)
      row(report, "email").sensitive.should be_true
      row(report, "ref").sensitive.should be_true
      row(report, "name").sensitive.should be_false
    end
  end

  # The stored body is read whole: a cap on the WIRE bytes would cut a JSON body before it
  # could parse.
  it "reads a JSON body larger than the old 256 KiB cut" do
    with_store do |store|
      big = %({"pad":"#{"x" * (300 * 1024)}","late":"v"})
      pi_flow(store, "/j", method: "POST", req_headers: "Content-Type: application/json\r\n", body: big)
      row(PI.build(store), "late").samples.should eq(["v"])
    end
  end

  it "narrows by exact host, path prefix, and location" do
    with_store do |store|
      pi_flow(store, "/api/a?k=1", host: "api.test", req_headers: "X-Tenant: acme\r\n")
      pi_flow(store, "/web/b?k=2", host: "api.test")
      pi_flow(store, "/api/a?k=3", host: "other.api.test")
      rows = PI.build(store, PI::Options.new(host: "API.test", path_prefix: "/api",
        locations: [PL::Query])).rows
      rows.map { |r| {r.host, r.path, r.name} }.should eq([{"api.test", "/api/a", "k"}])
    end
  end

  it "applies the caller's QL filter" do
    with_store do |store|
      pi_flow(store, "/a?x=1", method: "POST")
      pi_flow(store, "/b?y=1")
      rows = PI.build(store, PI::Options.new(filter: Gori::QL.parse("method:POST"))).rows
      rows.map(&.name).should eq(["x"])
    end
  end

  it "stops early when asked and flags the partial result" do
    with_store do |store|
      3.times { pi_flow(store, "/a?x=1") }
      calls = 0
      report = PI.build(store, stop: -> { (calls += 1) > 1 })
      report.flows_scanned.should eq(1)
      report.truncated.should be_true
    end
  end

  describe ".wordlist" do
    it "yields distinct names with JSON leaves, leaving headers out by default" do
      with_store do |store|
        pi_flow(store, "/a?q=1", method: "POST",
          req_headers: "Content-Type: application/json\r\nX-Tenant: t\r\n",
          body: %({"user":{"email":"e","q":"dup"},"tags":["x"]}))
        rows = PI.build(store).rows
        PI.wordlist(rows).sort.should eq(["email", "q"])
        PI.wordlist(rows, headers: true).should contain("x-tenant")
      end
    end

    # One name per line is the format: a name it cannot carry is left out, not split in two.
    it "leaves out names a line-oriented wordlist cannot carry" do
      with_store do |store|
        pi_flow(store, "/a?ok=1&a%0Ab=2&%23hash=3", method: "POST",
          req_headers: "Content-Type: application/json\r\n", body: %({"":1,"fine":2}))
        PI.wordlist(PI.build(store).rows).sort!.should eq(["fine", "ok"])
      end
    end
  end

  describe ".neighbor_names" do
    # Miner skips a name already in the base request, so the endpoint's own names are no seed.
    it "is the host's other endpoints' names minus this endpoint's own" do
      with_store do |store|
        pi_flow(store, "/orders?tenant=1&page=2")
        pi_flow(store, "/invoices?page=1")
        pi_flow(store, "/x?elsewhere=1", host: "other.test")
        rows = PI.build(store).rows
        PI.neighbor_names(rows, "shop.test", "/invoices").should eq(["tenant"])
      end
    end
  end

  it "masks bracket-nested sensitive names" do
    with_store do |store|
      pi_flow(store, "/login", method: "POST", req_headers: "Content-Type: application/x-www-form-urlencoded\r\n",
        body: "user%5Bemail%5D=a%40b.c&user%5Bpassword%5D=hunter2&password=hunter3")
      rep = PI.build(store)
      pwd = row(rep, "user[password]")
      pwd.sensitive.should be_true
      PI.masked(pwd, false).should eq(["[REDACTED]"])
      email = row(rep, "user[email]")
      email.sensitive.should be_false
      PI.masked(email, false).should eq(["a@b.c"])
    end
  end

  it "groups mixed-case hosts under lowercase host without splitting" do
    with_store do |store|
      pi_flow(store, "/a?x=1", host: "Shop.test")
      pi_flow(store, "/a?x=2", host: "shop.test")
      rep = PI.build(store)
      rep.rows.size.should eq(1)
      r = rep.rows.first
      r.host.should eq("shop.test")
      r.count.should eq(2)
      r.samples.sort.should eq(["1", "2"])
    end
  end

  it "matches the host filter case-insensitively against hosts stored as captured" do
    with_store do |store|
      pi_flow(store, "/a?x=1", host: "shop.test")
      pi_flow(store, "/a?x=2", host: "Shop.Test")
      pi_flow(store, "/a?x=3", host: "sub.shop.test")
      rep = PI.build(store, PI::Options.new(host: "SHOP.test"))
      rep.rows.size.should eq(1)
      rep.rows.first.host.should eq("shop.test")
      rep.rows.first.samples.sort.should eq(["1", "2"])
    end
  end

  it "bounds accumulators by max_rows and flags truncated" do
    with_store do |store|
      10.times do |i|
        m = (0...20).map { |k| %("#{i}-#{k}":{"qty":1}) }.join(",")
        pi_flow(store, "/cart", method: "POST", req_headers: "Content-Type: application/json\r\n",
          body: %({"items":{#{m}}}))
      end
      rep = PI.build(store, PI::Options.new(max_rows: 50))
      rep.rows.size.should eq(50)
      rep.truncated.should be_true
      rep.rows_capped.should be_true
      PI.build(store).rows_capped.should be_false
    end
  end
end
