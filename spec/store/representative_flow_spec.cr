require "../spec_helper"

private def rf_store(&)
  path = File.tempname("gori-rf", ".db")
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

private def rf_insert(store, target : String, status : Int32? = 200, *, scheme = "http", port = 19501) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: scheme, host: "127.0.0.1", port: port,
    method: "POST", target: target, http_version: "HTTP/1.1",
    head: "POST #{target} HTTP/1.1\r\nHost: 127.0.0.1:19501\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
  if status
    store.update_response(Gori::Store::CapturedResponse.new(
      flow_id: id, status: status, head: "HTTP/1.1 #{status} OK\r\n\r\n".to_slice))
  end
  id
end

# The Sitemap tree is built from a NORMALIZED path (`Sitemap.normalize_path` turns an
# absolute-form `flows.target` into a bare path) and was resolved back with exact equality
# against the UN-normalized column — so the two only agreed when the capture happened to
# store origin-form: HTTPS inside a CONNECT tunnel, or a request gori itself rewrote. A
# proxy client sends absolute-form for plaintext HTTP, so on every ordinary `http://`
# capture "Open flow" / "Send to Repeater" / "Send to Sequencer" answered
# "no captured request for this path — capture it" for a path the tree was displaying.
describe "Store#representative_flow_id" do
  it "resolves a node path against an absolute-form target" do
    rf_store do |store|
      id = rf_insert(store, "http://127.0.0.1:19501/crtest")
      Gori::Sitemap.normalize_path("http://127.0.0.1:19501/crtest").should eq("/crtest")
      store.representative_flow_id("127.0.0.1", "POST", "/crtest").should eq(id)
    end
  end

  it "still resolves an origin-form target by exact match" do
    rf_store do |store|
      id = rf_insert(store, "/held")
      store.representative_flow_id("127.0.0.1", "POST", "/held").should eq(id)
    end
  end

  # #1371: a Sitemap root is one origin, so the lookup behind it must stay on that scheme and
  # port — on both statements, origin-form and absolute-form.
  it "narrows to one origin when given a scheme and port" do
    rf_store do |store|
      a = rf_insert(store, "/x", port: 19021)
      b = rf_insert(store, "/x", port: 19022)
      c = rf_insert(store, "/x", scheme: "https", port: 8443)
      d = rf_insert(store, "http://127.0.0.1:19021/abs", port: 19021)
      rf_insert(store, "http://127.0.0.1:19022/abs", port: 19022)
      store.representative_flow_id("127.0.0.1", "POST", "/x", "http", 19021).should eq(a)
      store.representative_flow_id("127.0.0.1", "POST", "/x", "http", 19022).should eq(b)
      store.representative_flow_id("127.0.0.1", "POST", "/x", "https", 8443).should eq(c)
      store.representative_flow_id("127.0.0.1", "POST", "/x", "https", 19021).should be_nil
      store.representative_flow_id("127.0.0.1", "POST", "/abs", "http", 19021).should eq(d)
      store.representative_flow_id("127.0.0.1", "POST", "/x").should eq(c) # no origin: any, newest
    end
  end

  it "keeps the query string part of the endpoint identity" do
    rf_store do |store|
      a = rf_insert(store, "http://127.0.0.1:19501/s?q=1")
      b = rf_insert(store, "http://127.0.0.1:19501/s?q=2")
      store.representative_flow_id("127.0.0.1", "POST", "/s?q=1").should eq(a)
      store.representative_flow_id("127.0.0.1", "POST", "/s?q=2").should eq(b)
      store.representative_flow_id("127.0.0.1", "POST", "/s?q=3").should be_nil
    end
  end

  it "does not resolve a path that only happens to be a suffix of another target" do
    rf_store do |store|
      rf_insert(store, "http://127.0.0.1:19501/admin/panel")
      store.representative_flow_id("127.0.0.1", "POST", "/panel").should be_nil
    end
  end

  it "prefers a completed flow, newest first, across both target forms" do
    rf_store do |store|
      rf_insert(store, "http://127.0.0.1:19501/mix", status: nil) # in flight
      done = rf_insert(store, "http://127.0.0.1:19501/mix", status: 200)
      rf_insert(store, "http://127.0.0.1:19501/mix", status: nil)
      store.representative_flow_id("127.0.0.1", "POST", "/mix").should eq(done)
    end
  end

  it "reports nothing when the path really was never captured" do
    rf_store do |store|
      rf_insert(store, "http://127.0.0.1:19501/crtest")
      store.representative_flow_id("127.0.0.1", "POST", "/nope").should be_nil
      store.representative_flow_id("other.test", "POST", "/crtest").should be_nil
      store.representative_flow_id("127.0.0.1", "GET", "/crtest").should be_nil
    end
  end
end
