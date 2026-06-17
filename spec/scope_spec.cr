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

private def capture(store, host)
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: host, port: 80,
    method: "GET", target: "/", http_version: "HTTP/1.1",
    head: "GET / HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil))
end

describe Gori::Scope do
  it "is inactive (matches all) until enabled with patterns" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.active?.should be_false
      scope.filter.sql.should eq("1")

      scope.add("acme.test")
      scope.active?.should be_false # patterns but disabled
      scope.enable
      scope.active?.should be_true
    end
  end

  it "builds an OR filter (exact + subdomain + glob)" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("acme.test")
      scope.add("*.shop.test")
      scope.enable

      f = scope.filter
      f.sql.should contain("lower(host) = ?")
      f.sql.should contain("lower(host) LIKE ?")
      f.sql.should contain("lower(host) GLOB ?")
      f.args.should contain("acme.test")
      f.args.should contain("%.acme.test") # subdomain match
      f.args.should contain("*.shop.test")
    end
  end

  it "persists rules + enabled across reload" do
    with_store do |store|
      s1 = Gori::Scope.load(store)
      s1.add("acme.test")
      s1.enable
      s2 = Gori::Scope.load(store)
      s2.patterns.should eq(["acme.test"])
      s2.enabled?.should be_true
    end
  end

  it "filters Store#search to in-scope hosts (incl. subdomains)" do
    with_store do |store|
      capture(store, "acme.test")
      capture(store, "api.acme.test")
      capture(store, "cdn.example.com")

      scope = Gori::Scope.load(store)
      scope.add("acme.test")
      scope.enable

      hosts = store.search(scope.filter, 50).map(&.host).sort
      hosts.should eq(["acme.test", "api.acme.test"]) # cdn.example.com excluded
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
