require "../../spec_helper"

# --- file-local harness (mirrors spec/probe_spec.cr's private with_store/capture_flow) ---

private def with_store(&)
  path = File.tempname("gori-sharedcache", ".db")
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

private def capture_flow(store, *, host = "api.acme.test", origin : String? = nil,
                         resp_headers : String = "", status = 200,
                         content_type : String? = "text/html") : Gori::Store::FlowDetail
  head = String.build do |io|
    io << "GET /me HTTP/1.1\r\nHost: " << host << "\r\n"
    io << "Origin: " << origin << "\r\n" if origin
    io << "\r\n"
  end
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: host, port: 443,
    method: "GET", target: "/me", http_version: "HTTP/1.1", head: head.to_slice, body: nil,
    source: Gori::FlowSource::Kind::Proxy)
  id = store.insert_flow(req)
  resp_head = "HTTP/1.1 #{status} OK\r\nContent-Type: #{content_type}\r\n#{resp_headers}\r\n"
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: resp_head.to_slice, body: "ok".to_slice,
    reason: "OK", content_type: content_type, duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

private def dets(store, code : String, **kw) : Array(Gori::Probe::Detection)
  Gori::Probe::Passive.analyze(capture_flow(store, **kw)).select { |d| d.code == code }
end

describe Gori::Probe::Passive::SharedCache do
  describe "cacheable_set_cookie" do
    it "flags a session cookie on a publicly cacheable response" do
      with_store do |store|
        found = dets(store, "cacheable_set_cookie",
          resp_headers: "Cache-Control: public, max-age=600\r\nSet-Cookie: sessionid=abc; Path=/\r\n")
        found.size.should eq(1)
        found[0].severity.should eq(Gori::Store::Severity::High)
        found[0].category.should eq(Gori::Probe::Category::HEADERS)
        found[0].evidence.should eq("sessionid (Cache-Control: public)")
      end
    end

    it "flags s-maxage, and drops to Medium for a non-session cookie" do
      with_store do |store|
        found = dets(store, "cacheable_set_cookie",
          resp_headers: "Cache-Control: s-maxage=60\r\nSet-Cookie: locale=ko; Path=/\r\n")
        found.size.should eq(1)
        found[0].severity.should eq(Gori::Store::Severity::Medium)
        found[0].evidence.should eq("locale (s-maxage=60)")
      end
    end

    it "stays silent when the server kept shared caches out" do
      with_store do |store|
        dets(store, "cacheable_set_cookie",
          resp_headers: "Cache-Control: private, max-age=600\r\nSet-Cookie: sessionid=abc\r\n").should be_empty
        dets(store, "cacheable_set_cookie",
          resp_headers: "Cache-Control: no-store\r\nSet-Cookie: sessionid=abc\r\n").should be_empty
        # No directives at all: the heuristic-cacheability guess this rule deliberately refuses.
        dets(store, "cacheable_set_cookie", resp_headers: "Set-Cookie: sessionid=abc\r\n").should be_empty
        # Publicly cacheable but nothing to leak.
        dets(store, "cacheable_set_cookie", resp_headers: "Cache-Control: public, max-age=600\r\n").should be_empty
      end
    end
  end

  describe "cors_no_vary_origin" do
    it "flags a reflected origin cached without Vary: Origin" do
      with_store do |store|
        found = dets(store, "cors_no_vary_origin", origin: "https://app.acme.test",
          resp_headers: "Access-Control-Allow-Origin: https://app.acme.test\r\nCache-Control: public, max-age=60\r\n")
        found.size.should eq(1)
        found[0].severity.should eq(Gori::Store::Severity::Low)
        found[0].category.should eq(Gori::Probe::Category::CORS)
      end
    end

    it "is satisfied by Vary: Origin, and by Vary: *" do
      with_store do |store|
        dets(store, "cors_no_vary_origin", origin: "https://app.acme.test",
          resp_headers: "Access-Control-Allow-Origin: https://app.acme.test\r\n" \
                        "Cache-Control: public, max-age=60\r\nVary: Accept-Encoding, Origin\r\n").should be_empty
        dets(store, "cors_no_vary_origin", origin: "https://app.acme.test",
          resp_headers: "Access-Control-Allow-Origin: https://app.acme.test\r\n" \
                        "Cache-Control: public, max-age=60\r\nVary: *\r\n").should be_empty
      end
    end

    it "ignores the constant ACAO values and an uncacheable response" do
      with_store do |store|
        dets(store, "cors_no_vary_origin", origin: "https://app.acme.test",
          resp_headers: "Access-Control-Allow-Origin: *\r\nCache-Control: public, max-age=60\r\n").should be_empty
        dets(store, "cors_no_vary_origin", origin: "https://app.acme.test",
          resp_headers: "Access-Control-Allow-Origin: null\r\nCache-Control: public, max-age=60\r\n").should be_empty
        dets(store, "cors_no_vary_origin", origin: "https://app.acme.test",
          resp_headers: "Access-Control-Allow-Origin: https://app.acme.test\r\nCache-Control: no-store\r\n").should be_empty
        # `private` is the shared-cache veto even with a positive max-age.
        dets(store, "cors_no_vary_origin", origin: "https://app.acme.test",
          resp_headers: "Access-Control-Allow-Origin: https://app.acme.test\r\nCache-Control: private, max-age=60\r\n").should be_empty
      end
    end

    it "still fires on max-age without public (a shared cache may honour it)" do
      with_store do |store|
        dets(store, "cors_no_vary_origin", origin: "https://app.acme.test",
          resp_headers: "Access-Control-Allow-Origin: https://app.acme.test\r\nCache-Control: max-age=60\r\n").size.should eq(1)
      end
    end

    it "needs the ACAO to demonstrably echo THIS request's Origin" do
      with_store do |store|
        # A constant, hard-coded allowlist entry that happens not to be the caller: nothing varies,
        # so a cache cannot mis-serve it.
        dets(store, "cors_no_vary_origin", origin: "https://other.acme.test",
          resp_headers: "Access-Control-Allow-Origin: https://app.acme.test\r\nCache-Control: public, max-age=60\r\n").should be_empty
      end
    end
  end
end
