require "./spec_helper"

private def tmp_store(&)
  path = File.tempname("gori-ql", ".db")
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

private def capture(store, host, method, target, status = nil)
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: host, port: 80,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil))
  if status
    store.update_response(Gori::Store::CapturedResponse.new(
      flow_id: id, status: status, head: "HTTP/1.1 #{status} X\r\n\r\n".to_slice))
  end
  id
end

describe Gori::QL do
  it "compiles AND-ed terms with parameterised values" do
    f = Gori::QL.parse("host:acme status:>=500")
    f.sql.should eq("(lower(host) LIKE ? ESCAPE '\\' AND status >= ?)")
    f.args.should eq(["%acme%", 500])
  end

  it "compiles a status class to a range" do
    f = Gori::QL.parse("status:4xx")
    f.sql.should eq("((status >= ? AND status < ?))") # clause-wrap around the range term
    f.args.should eq([400, 500])
  end

  it "honours a comparison operator against a status class" do
    Gori::QL.parse("status:>=5xx").sql.should eq("(status >= ?)")
    Gori::QL.parse("status:>=5xx").args.should eq([500])
    Gori::QL.parse("status:<4xx").args.should eq([400])  # below the class floor
    Gori::QL.parse("status:>4xx").args.should eq([500])  # strictly above the 4xx class
    Gori::QL.parse("status:<=4xx").args.should eq([500]) # at or below the class (status < 500)
  end

  it "escapes LIKE metacharacters so % and _ match literally" do
    f = Gori::QL.parse("host:ac%e_")
    f.sql.should eq("(lower(host) LIKE ? ESCAPE '\\')")
    f.args.should eq(["%ac\\%e\\_%"]) # the user's % and _ are backslash-escaped
  end

  it "compiles OR groups and negation" do
    f = Gori::QL.parse("method:get OR -host:cdn")
    f.sql.should eq("(upper(method) = ?) OR (NOT (lower(host) LIKE ? ESCAPE '\\'))")
    f.args.should eq(["GET", "%cdn%"])
  end

  it "treats bare words as free text over method/host/path" do
    f = Gori::QL.parse("login")
    f.args.should eq(["%login%", "%login%", "%login%"])
  end

  it "matches everything for an empty query" do
    Gori::QL.parse("   ").sql.should eq("1")
  end

  it "compiles a body: term to an FTS substring (quoted-phrase) match" do
    f = Gori::QL.parse("body:token")
    f.sql.should eq("(id IN (SELECT rowid FROM flows_fts WHERE flows_fts MATCH ?))")
    f.args.should eq([%("token")])
  end

  it "falls back to a NULL-safe blob scan for a body: value below the 3-char trigram floor" do
    f = Gori::QL.parse("body:ab")
    f.sql.should eq("(((request_body IS NOT NULL AND lower(CAST(request_body AS TEXT)) LIKE ? ESCAPE '\\') " \
                    "OR (response_body IS NOT NULL AND lower(CAST(response_body AS TEXT)) LIKE ? ESCAPE '\\')))")
    f.args.should eq(["%ab%", "%ab%"])
  end
end

describe "Gori::Store#search (QL)" do
  it "filters flows by a compiled query" do
    tmp_store do |store|
      capture(store, "acme.test", "GET", "/", 200)
      capture(store, "acme.test", "POST", "/login", 500)
      capture(store, "other.test", "GET", "/", 200)

      by_host = store.search(Gori::QL.parse("host:acme"), 50)
      by_host.map(&.host).uniq.should eq(["acme.test"])

      errs = store.search(Gori::QL.parse("status:>=500"), 50)
      errs.map(&.status).should eq([500])

      post_login = store.search(Gori::QL.parse("method:post path:/login"), 50)
      post_login.size.should eq(1)
      post_login.first.target.should eq("/login")

      none = store.search(Gori::QL.parse("flag:reflected"), 50)
      none.should be_empty
    end
  end

  it "searches request and response bodies (body:)" do
    tmp_store do |store|
      req_match = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "acme.test", port: 80,
        method: "POST", target: "/login", http_version: "HTTP/1.1",
        head: "POST /login HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        body: "username=admin&csrf=SeCrEtToken".to_slice))

      resp_match = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 2_i64, scheme: "http", host: "acme.test", port: 80,
        method: "GET", target: "/", http_version: "HTTP/1.1",
        head: "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: resp_match, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice,
        body: "<input name=secrettoken value=1>".to_slice))

      store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 3_i64, scheme: "http", host: "acme.test", port: 80,
        method: "GET", target: "/about", http_version: "HTTP/1.1",
        head: "GET /about HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        body: "nothing here".to_slice))

      hits = store.search(Gori::QL.parse("body:secrettoken"), 50).map(&.id).sort
      hits.should eq([req_match, resp_match].sort) # case-insensitive, req + resp

      # substring match (not just prefix): body:token finds it INSIDE "secrettoken"
      store.search(Gori::QL.parse("body:token"), 50).map(&.id).sort.should eq([req_match, resp_match].sort)
      # and a leading fragment still works too
      store.search(Gori::QL.parse("body:secret"), 50).map(&.id).sort.should eq([req_match, resp_match].sort)

      # negation must KEEP bodyless flows (NULL-safe), not drop them
      neg = store.search(Gori::QL.parse("-body:secrettoken"), 50).map(&.id)
      neg.should_not contain(req_match)
      neg.should_not contain(resp_match)
      neg.size.should eq(1) # the "/about" flow (body "nothing here") survives
    end
  end
end
