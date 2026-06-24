require "./spec_helper"

private def with_store(&)
  path = File.tempname("gori-scope", ".db")
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

private def capture(store, host, target = "/", scheme = "http")
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: scheme, host: host, port: scheme == "https" ? 443 : 80,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil))
end

# The URL the Scope filter + in_scope_url? both build: scheme://host + stored target.
private def url_of(scheme, host, target)
  "#{scheme}://#{host}#{target}"
end

describe Gori::Scope do
  it "is inactive (matches all) until enabled with at least one rule" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.active?.should be_false
      scope.filter.sql.should eq("1") # QL::EMPTY

      scope.add("include", "host", "acme.test")
      scope.active?.should be_false # has a rule but disabled
      scope.enable
      scope.active?.should be_true
    end
  end

  it "active? counts ANY rule and excludes-only emits (1 AND NOT (...)), never NOT ()" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("exclude", "host", "cdn.test")
      scope.enable
      scope.active?.should be_true # an exclude alone is active (Burp excludes-only)
      f = scope.filter
      f.sql.should start_with("(1 AND NOT (")
      f.sql.should_not contain("NOT ()")
    end
  end

  it "host include matches host + subdomain; a host exclude carves out" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")
      scope.add("exclude", "host", "internal.acme.test")
      scope.enable
      scope.in_scope_url?(url_of("https", "acme.test", "/"), "acme.test").should be_true
      scope.in_scope_url?(url_of("https", "api.acme.test", "/x"), "api.acme.test").should be_true
      scope.in_scope_url?(url_of("https", "internal.acme.test", "/x"), "internal.acme.test").should be_false
      scope.in_scope_url?(url_of("https", "other.test", "/"), "other.test").should be_false
    end
  end

  it "empty includes + one exclude ⇒ everything except the excluded (Burp excludes-only)" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("exclude", "host", "cdn.test")
      scope.enable
      scope.in_scope_url?(url_of("https", "api.acme.test", "/x"), "api.acme.test").should be_true
      scope.in_scope_url?(url_of("https", "cdn.test", "/y"), "cdn.test").should be_false
    end
  end

  it "string include matches the FULL url (case-insensitive), not just the host" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("include", "string", "/ADMIN")
      scope.enable
      scope.in_scope_url?(url_of("https", "x.test", "/admin/users"), "x.test").should be_true
      scope.in_scope_url?(url_of("https", "x.test", "/public"), "x.test").should be_false
    end
  end

  it "regex include is case-SENSITIVE by default; inline (?i) opts in" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("include", "regex", "/API/v\\d")
      scope.enable
      scope.in_scope_url?(url_of("https", "x.test", "/API/v2"), "x.test").should be_true
      scope.in_scope_url?(url_of("https", "x.test", "/api/v2"), "x.test").should be_false

      scope2 = Gori::Scope.load(store) # fresh
      scope2.add("include", "regex", "(?i)/api/v\\d")
      scope2.enable
      scope2.in_scope_url?(url_of("https", "x.test", "/API/v2"), "x.test").should be_true
    end
  end

  it "rejects an invalid regex at add (never persisted) and never raises while matching" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("include", "regex", "(unterminated").should be_false
      store.scope_rules.should be_empty
      # A Rule built directly from a bad pattern degrades to never-match, no raise.
      bad = Gori::Scope::Rule.new(1_i64, "include", "regex", "(unterminated")
      bad.matches?("https://x.test/y", "x.test").should be_false
    end
  end

  it "treats LIKE metacharacters in a string rule as literal (ESCAPE)" do
    with_store do |store|
      capture(store, "x.test", "/a%b")
      capture(store, "x.test", "/axxb")
      scope = Gori::Scope.load(store)
      scope.add("include", "string", "/a%b")
      scope.enable
      hosts_targets = store.search(scope.filter, 50).map { |r| r.target }
      hosts_targets.should contain("/a%b")
      hosts_targets.should_not contain("/axxb") # % is literal, not a wildcard
    end
  end

  it "escapes LIKE metacharacters in a host subdomain rule (parity with literal in-memory match)" do
    with_store do |store|
      capture(store, "sub.a_b.test", "/") # literal underscore host
      capture(store, "sub.aYb.test", "/") # would match if `_` were a wildcard
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "a_b.test")
      scope.enable
      store.search(scope.filter, 50).map(&.host).sort.should eq(["sub.a_b.test"]) # `_` literal, not wildcard
      scope.in_scope_url?(url_of("https", "sub.aYb.test", "/"), "sub.aYb.test").should be_false
    end
  end

  it "SQL filter agrees with in_scope_url? over Store#search (host/string/regex, incl/excl)" do
    with_store do |store|
      flows = [
        {"https", "api.acme.test", "/v1/users"},
        {"https", "api.acme.test", "/static/app.js"},
        {"https", "www.acme.test", "/login"},
        {"http", "cdn.acme.test", "/img/a.png"},
        {"https", "other.test", "/v1/users"},
      ]
      flows.each { |(sc, h, t)| capture(store, h, t, sc) }

      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")  # the *.acme.test family
      scope.add("exclude", "string", "/static/") # carve out static
      scope.add("exclude", "regex", "\\.png$")   # carve out images
      scope.enable

      sql_set = store.search(scope.filter, 50).map { |r| {r.scheme, r.host, r.target} }.to_set
      mem_set = flows.select { |(sc, h, t)| scope.in_scope_url?(url_of(sc, h, t), h) }
        .map { |(sc, h, t)| {sc, h, t} }.to_set
      sql_set.should eq(mem_set)
      # sanity: the /v1/users + /login under acme.test survive; static/png/other.test don't
      mem_set.should eq([
        {"https", "api.acme.test", "/v1/users"},
        {"https", "www.acme.test", "/login"},
      ].to_set)
    end
  end

  it "may_match_host? is conservative for the Tunnel (host gate, pre-request)" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")
      scope.add("include", "regex", "/secret") # a url-level include
      scope.add("exclude", "host", "cdn.acme.test")
      scope.add("exclude", "regex", "/private") # a url-level exclude
      scope.enable

      # a matching host exclude fully removes the host even though a url-include exists
      scope.may_match_host?("cdn.acme.test").should be_false
      # a host-include matches → in
      scope.may_match_host?("api.acme.test").should be_true
      # a url-level include exists, so even a non-host-include host can't be ruled out
      scope.may_match_host?("random.test").should be_true
      # url-level excludes never remove a whole host
      scope.may_match_host?("acme.test").should be_true
    end
  end

  it "tolerates a malformed glob instead of raising (would drop proxy connections)" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "*.acme[.test") # unterminated set — File.match? would raise
      scope.add("include", "host", "good.test")
      scope.enable
      scope.in_scope_url?(url_of("https", "x.acme.test", "/"), "x.acme.test").should be_false
      scope.in_scope_url?(url_of("https", "good.test", "/"), "good.test").should be_true
    end
  end

  it "persists rules (kind/type/pattern) + enabled across reload, dedupes the triple" do
    with_store do |store|
      s1 = Gori::Scope.load(store)
      s1.add("include", "host", "acme.test")
      s1.add("exclude", "regex", "\\.png$")
      s1.add("include", "host", "acme.test").should be_false # duplicate triple
      s1.enable
      s2 = Gori::Scope.load(store)
      s2.rules.map { |r| {r.kind, r.match_type, r.pattern} }.should eq([
        {"include", "host", "acme.test"},
        {"exclude", "regex", "\\.png$"},
      ])
      s2.enabled?.should be_true

      # remove by id
      first = s2.rules.first.id
      s2.remove(first)
      Gori::Scope.load(store).rules.map(&.pattern).should eq(["\\.png$"])
    end
  end

  it "migrates pre-V13 bare host patterns to include/host rows" do
    with_store do |store|
      store.add_scope_rule("include", "host", "legacy.test")
      Gori::Scope.load(store).rules.map { |r| {r.kind, r.match_type, r.pattern} }
        .should eq([{"include", "host", "legacy.test"}])
    end
  end
end

describe Gori::QL do
  it "ANDs two filters and absorbs the empty filter" do
    a = Gori::QL::Filter.new("host = ?", ["x"] of DB::Any)
    b = Gori::QL::Filter.new("status = ?", [200] of DB::Any)
    Gori::QL.and(a, b).sql.should eq("(host = ?) AND (status = ?)")
    Gori::QL.and(a, b).args.should eq(["x", 200])
    Gori::QL.and(Gori::QL::EMPTY, b).sql.should eq("status = ?")
    Gori::QL.and(a, Gori::QL::EMPTY).sql.should eq("host = ?")
  end
end
