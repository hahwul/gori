require "../spec_helper"

private def call_json(tools : Gori::MCP::Tools, args : String) : JSON::Any
  r = tools.call("list_sitemap", JSON.parse(args))
  fail "list_sitemap errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

private def seed(store : Gori::Store, target : String, source : Gori::FlowSource::Kind) : Nil
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "acme.test", port: 80, method: "GET",
    target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, source: source))
end

describe "MCP list_sitemap coverage" do
  it "carries touched_by on a tested entry and omits it on an untested one" do
    with_store do |store|
      seed(store, "/search?q=test", Gori::FlowSource::Kind::Proxy)
      2.times { |i| seed(store, "/search?q=p#{i}", Gori::FlowSource::Kind::Fuzzer) }
      seed(store, "/about", Gori::FlowSource::Kind::Proxy)
      seed(store, "/about", Gori::FlowSource::Kind::Discover)
      store.flush
      tools = tools_for(store)

      rows = call_json(tools, "{}")["entries"].as_a
      rows.find! { |r| r["target"] == "/search" }["touched_by"].should eq(JSON.parse(%({"fuzzer":2})))
      rows.find! { |r| r["target"] == "/about" }["touched_by"]?.should be_nil

      # Unfolded, the captured variant the sweep started from is tested too.
      raw = call_json(tools, %({"fold_query":false}))["entries"].as_a
      raw.find! { |r| r["target"] == "/search?q=test" }["touched_by"]["fuzzer"].should eq(2)
    end
  end

  it "counts a saved fuzz run that recorded nothing in History" do
    with_store do |store|
      seed(store, "/search?q=test", Gori::FlowSource::Kind::Proxy)
      run = store.insert_fuzz_run(nil, "http://acme.test:80", "sniper", 1_i64)
      store.insert_fuzz_result(run, 0_i64, "p", 200, 0_i64, 0, 0, 0_i64, nil, false, nil,
        request: "GET /search?q=p HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice)
      store.flush
      tools = tools_for(store)

      call_json(tools, "{}")["entries"][0]["touched_by"].should eq(JSON.parse(%({"fuzzer":1})))
      call_json(tools, %({"untested":true}))["entries"].as_a.should be_empty
    end
  end

  it "keeps only untested endpoints under untested, paging what survives" do
    with_store do |store|
      seed(store, "/a", Gori::FlowSource::Kind::Proxy)
      seed(store, "/a", Gori::FlowSource::Kind::Repeater)
      %w[/b /c /d].each { |t| seed(store, t, Gori::FlowSource::Kind::Proxy) }
      store.flush
      tools = tools_for(store)

      first = call_json(tools, %({"untested":true,"limit":2}))
      first["entries"].as_a.map(&.["target"].as_s).should eq(%w[/b /c])
      first["has_more"].should be_true
      rest = call_json(tools, %({"untested":true,"limit":2,"offset":2}))
      rest["entries"].as_a.map(&.["target"].as_s).should eq(%w[/d])
      rest["has_more"].should be_false
    end
  end

  it "refuses untested with collapse_transport instead of dropping it" do
    with_store do |store|
      res = tools_for(store).call("list_sitemap", JSON.parse(%({"collapse_transport":true,"untested":true})))
      res.is_error.should be_true
      res.text.should contain("untested")
    end
  end
end
