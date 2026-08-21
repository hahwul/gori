require "../spec_helper"

private def fu_store(&)
  path = File.tempname("gori-flowurl", ".db")
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

private def fu_insert(store, target : String, *, scheme = "http", host = "127.0.0.1",
                      port = 19501, method = "GET", status : Int32? = 200) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: scheme, host: host, port: port,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}:#{port}\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
  if status
    store.update_response(Gori::Store::CapturedResponse.new(
      flow_id: id, status: status, head: "HTTP/1.1 #{status} OK\r\n\r\n".to_slice))
  end
  id
end

# The inverse of FlowRow#url: a Probe issue's AFFECTED list holds URL STRINGS (upsert_probe_issue
# accumulates Detection#url and keeps no per-URL flow id), so ↵ on one of those rows can only get
# back to the exchange through this lookup.
describe "Store#flow_id_for_url" do
  it "resolves a URL captured in absolute form (the plaintext forward-proxy shape)" do
    fu_store do |store|
      id = fu_insert(store, "http://127.0.0.1:19501/crtest")
      store.flow_row(id).not_nil!.url.should eq("http://127.0.0.1:19501/crtest")
      store.flow_id_for_url("http://127.0.0.1:19501/crtest", "127.0.0.1").should eq(id)
    end
  end

  it "resolves a URL captured in origin form (the CONNECT/h2 shape), rebuilding the authority" do
    fu_store do |store|
      id = fu_insert(store, "/panel", scheme: "https", host: "a.test", port: 443)
      store.flow_row(id).not_nil!.url.should eq("https://a.test/panel")
      store.flow_id_for_url("https://a.test/panel", "a.test").should eq(id)
    end
  end

  it "keeps a non-default port out of the match" do
    fu_store do |store|
      id = fu_insert(store, "/panel", scheme: "https", host: "a.test", port: 8443)
      store.flow_id_for_url("https://a.test:8443/panel", "a.test").should eq(id)
      # Same target, same host — only the rebuilt authority tells them apart, which is why the
      # SQL predicate's survivors go back through FlowRow.url_of instead of being trusted.
      store.flow_id_for_url("https://a.test/panel", "a.test").should be_nil
    end
  end

  it "does not confuse two schemes sharing one origin-form target" do
    fu_store do |store|
      plain = fu_insert(store, "/x", scheme: "http", host: "a.test", port: 80)
      tls = fu_insert(store, "/x", scheme: "https", host: "a.test", port: 443)
      store.flow_id_for_url("http://a.test/x", "a.test").should eq(plain)
      store.flow_id_for_url("https://a.test/x", "a.test").should eq(tls)
    end
  end

  it "prefers a completed flow, newest first" do
    fu_store do |store|
      fu_insert(store, "http://127.0.0.1:19501/mix", status: nil) # in flight
      done = fu_insert(store, "http://127.0.0.1:19501/mix", status: 200)
      fu_insert(store, "http://127.0.0.1:19501/mix", status: nil)
      store.flow_id_for_url("http://127.0.0.1:19501/mix", "127.0.0.1").should eq(done)
    end
  end

  # A URL is not an endpoint. `GET /v1/me` and `POST /v1/me` are one (host, target) pair and
  # two different exchanges, and a finding that fired on one must not open the other — which
  # "newest with a response" alone would do on any endpoint the app later POSTs to.
  it "prefers the method the finding was seen with over a newer same-URL sibling" do
    fu_store do |store|
      got = fu_insert(store, "http://127.0.0.1:19501/v1/me", method: "GET")
      posted = fu_insert(store, "http://127.0.0.1:19501/v1/me", method: "POST") # newer
      url = "http://127.0.0.1:19501/v1/me"
      store.flow_id_for_url(url, "127.0.0.1", "GET").should eq(got)
      store.flow_id_for_url(url, "127.0.0.1", "POST").should eq(posted)
      # No hint (a finding whose sample flow is gone) still resolves — newest-with-response.
      store.flow_id_for_url(url, "127.0.0.1").should eq(posted)
      # A method that never touched this URL is a preference, not a filter: still an answer.
      store.flow_id_for_url(url, "127.0.0.1", "DELETE").should eq(posted)
    end
  end

  it "keeps the response-bearing preference under an unmatched method hint" do
    fu_store do |store|
      done = fu_insert(store, "http://127.0.0.1:19501/mix", method: "GET", status: 200)
      fu_insert(store, "http://127.0.0.1:19501/mix", method: "GET", status: nil) # newer, in flight
      store.flow_id_for_url("http://127.0.0.1:19501/mix", "127.0.0.1", "PUT").should eq(done)
    end
  end

  it "reports nothing for a URL this project never captured" do
    fu_store do |store|
      fu_insert(store, "http://127.0.0.1:19501/crtest")
      store.flow_id_for_url("http://127.0.0.1:19501/nope", "127.0.0.1").should be_nil
      store.flow_id_for_url("http://other.test/crtest", "other.test").should be_nil
      # A path that only happens to be the suffix of another target is not a match.
      store.flow_id_for_url("http://127.0.0.1:19501/test", "127.0.0.1").should be_nil
    end
  end
end
