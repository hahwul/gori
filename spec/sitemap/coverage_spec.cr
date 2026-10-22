require "../spec_helper"

private def cov_flow(store : Gori::Store, target : String, source : Gori::FlowSource::Kind,
                     method = "GET", scheme = "https", port = 443) : Nil
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: scheme, host: "acme.test", port: port, method: method,
    target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, source: source))
end

describe Gori::Sitemap::Coverage do
  it "keys an endpoint on its path without the query, as the tree draws it" do
    Gori::Sitemap::Coverage.path_of("/search?q=1").should eq("/search")
    Gori::Sitemap::Coverage.path_of("/api/users/").should eq("/api/users")
    Gori::Sitemap::Coverage.path_of("https://acme.test/x?a=1").should eq("/x")
    Gori::Sitemap::Coverage.path_of("/?a=1").should eq("/")
  end

  it "counts active tools per origin endpoint, and nothing else" do
    with_store do |store|
      3.times { |i| cov_flow(store, "/search?q=payload#{i}", Gori::FlowSource::Kind::Fuzzer) }
      cov_flow(store, "/search", Gori::FlowSource::Kind::Repeater)
      cov_flow(store, "/search?q=test", Gori::FlowSource::Kind::Proxy)
      cov_flow(store, "/crawled", Gori::FlowSource::Kind::Discover)
      cov_flow(store, "/login", Gori::FlowSource::Kind::Refresh)
      store.flush

      cov = Gori::Sitemap::Coverage.load(store)
      # The captured request a sweep started from is tested by the sweep.
      cov.touched_by("https", "acme.test", 443, "GET", "/search?q=test").should eq({"fuzzer" => 3_i64, "repeater" => 1_i64})
      cov.touched?("https", "acme.test", 443, "POST", "/search").should be_false
      cov.touched?("http", "acme.test", 80, "GET", "/search").should be_false
      cov.touched?("https", "acme.test", 443, "GET", "/crawled").should be_false
      cov.touched?("https", "acme.test", 443, "GET", "/login").should be_false
      cov.touched_by("https", "acme.test", 443, "GET", "/login").should be_nil
    end
  end

  it "counts a saved fuzz run's results, never twice when the sweep was also recorded" do
    with_store do |store|
      run = store.insert_fuzz_run(nil, "https://acme.test:443", "sniper", 3_i64)
      3.times do |i|
        store.insert_fuzz_result(run, i.to_i64, "p#{i}", 200, 0_i64, 0, 0, 0_i64, nil, false, nil,
          request: "GET /search?q=p#{i} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice)
      end
      # Recorded too: the same three sends are in History.
      3.times { |i| cov_flow(store, "/search?q=p#{i}", Gori::FlowSource::Kind::Fuzzer) }
      # A compacted result names no endpoint.
      store.insert_fuzz_result(run, 9_i64, "x", 200, 0_i64, 0, 0, 0_i64, nil, false, nil)
      ws = store.insert_fuzz_run(nil, "https://acme.test:443", "sniper", 1_i64, websocket: true)
      store.insert_fuzz_result(ws, 0_i64, "w", 101, 0_i64, 0, 0, 0_i64, nil, false, nil, request: "GET /ws HTTP/1.1\r\n".to_slice)
      store.flush

      cov = Gori::Sitemap::Coverage.load(store)
      cov.touched_by("https", "acme.test", 443, "GET", "/search?q=test").should eq({"fuzzer" => 3_i64})
      cov.touched?("https", "acme.test", 443, "GET", "/ws").should be_false
    end
  end

  it "keys a saved result on the bytes it sent, as History records it" do
    with_store do |store|
      run = store.insert_fuzz_run(nil, "https://acme.test:443", "sniper", 1_i64)
      store.insert_fuzz_results(run, [Gori::Store::FuzzResultWrite.new(0_i64, "p", nil, 200, 0_i64, 0, 0, 0_i64,
        nil, false, false, nil, "GET /api/$VER/users HTTP/1.1\r\n\r\n".to_slice,
        wire: "GET /api/v2/users HTTP/1.1\r\n\r\n".to_slice)])
      cov_flow(store, "/api/v2/users", Gori::FlowSource::Kind::Fuzzer)
      store.flush

      cov = Gori::Sitemap::Coverage.load(store)
      cov.touched_by("https", "acme.test", 443, "GET", "/api/v2/users").should eq({"fuzzer" => 1_i64})
      cov.touched?("https", "acme.test", 443, "GET", "/api/$VER/users").should be_false
    end
  end

  it "cuts a saved request line at its own query, not at a header's '?'" do
    with_store do |store|
      run = store.insert_fuzz_run(nil, "https://acme.test:443", "sniper", 1_i64)
      store.insert_fuzz_result(run, 0_i64, "p", 200, 0_i64, 0, 0, 0_i64, nil, false, nil,
        request: "GET /a HTTP/1.1\r\nReferer: /x?y\r\n\r\n".to_slice)
      store.flush

      Gori::Sitemap::Coverage.load(store).touched_by("https", "acme.test", 443, "GET", "/a").should eq({"fuzzer" => 1_i64})
    end
  end

  it "reads a saved run's origin and request line, and refuses what is neither" do
    # As the store hands it over: cut at the query, or whole with its version when none.
    Gori::Sitemap::Coverage.run_key("http://::1:8080", "POST /a/".to_slice)
      .should eq({"http", "::1", 8080, "POST", "/a"})
    Gori::Sitemap::Coverage.run_key("https://acme.test:443", "GET /b/c HTTP/2\r\n".to_slice)
      .should eq({"https", "acme.test", 443, "GET", "/b/c"})
    Gori::Sitemap::Coverage.run_key("https://acme.test:443", "garbage\n".to_slice).should be_nil
    Gori::Sitemap::Coverage.run_key("acme.test", "GET / HTTP/1.1\n".to_slice).should be_nil
  end

  it "stamps endpoint and query-fold nodes, never an id fold" do
    with_store do |store|
      cov_flow(store, "/search?q=1", Gori::FlowSource::Kind::Proxy)
      cov_flow(store, "/search?q=2", Gori::FlowSource::Kind::Fuzzer)
      cov_flow(store, "/a", Gori::FlowSource::Kind::Proxy)
      cov_flow(store, "/a", Gori::FlowSource::Kind::Probe, method: "POST")
      ids = %w[3f2a1b4c-0000-4000-8000-000000000001 3f2a1b4c-0000-4000-8000-000000000002 3f2a1b4c-0000-4000-8000-000000000003]
      ids.each { |u| cov_flow(store, "/u/#{u}", Gori::FlowSource::Kind::Repeater) }
      store.flush

      hosts = Gori::Sitemap.build(store.sitemap_origin_entries)
      hosts.each { |h| Gori::Sitemap.fold_templates!(h) }
      hosts.each { |h| Gori::Sitemap.fold_queries!(h) }
      Gori::Sitemap::Coverage.load(store).stamp!(hosts)
      root = hosts.first
      root.touched_by.should be_nil
      root.children.find! { |n| n.label == "a" }.touched_by.should eq({"probe" => 1_i64})
      fold = root.children.find!(&.query_fold)
      fold.touched_by.should eq({"fuzzer" => 1_i64})
      id_fold = root.children.find! { |n| n.label == "u" }.children.first
      id_fold.template?.should be_true
      id_fold.touched_by.should be_nil
      id_fold.children.first.touched_by.should eq({"repeater" => 1_i64})
    end
  end
end
