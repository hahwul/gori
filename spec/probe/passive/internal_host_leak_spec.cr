require "../../spec_helper"

# --- file-local harness (mirrors spec/probe_spec.cr's private with_store/capture_flow) ---

private def capture_flow(store, resp_headers : String = "") : Gori::Store::FlowDetail
  head = "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n"
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: "/", http_version: "HTTP/1.1", head: head.to_slice, body: nil,
    source: Gori::FlowSource::Kind::Proxy)
  id = store.insert_flow(req)
  resp_head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n#{resp_headers}\r\n"
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: resp_head.to_slice, body: "ok".to_slice,
    reason: "OK", content_type: "text/plain", duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

private def leaks(store, resp_headers : String) : Array(Gori::Probe::Detection)
  Gori::Probe::Passive.analyze(capture_flow(store, resp_headers)).select { |d| d.code == "internal_host_leak" }
end

describe Gori::Probe::Passive::InternalHostLeak do
  it "flags a private IP in a response header" do
    with_store do |store|
      found = leaks(store, "X-Backend-Server: 10.2.0.7\r\n")
      found.size.should eq(1)
      found[0].severity.should eq(Gori::Store::Severity::Low)
      found[0].category.should eq(Gori::Probe::Category::INFOLEAK)
      found[0].evidence.should eq("X-Backend-Server: 10.2.0.7")
    end
  end

  it "flags an internal-only hostname" do
    with_store do |store|
      leaks(store, "Via: 1.1 cache01.internal\r\n")[0].evidence.should eq("Via: cache01.internal")
      leaks(store, "X-Served-By: web03.corp\r\n").size.should eq(1)
      leaks(store, "Location: http://app01.local/next\r\n").size.should eq(1)
    end
  end

  it "does not read a public name that merely starts with an internal label" do
    with_store do |store|
      # `\\b` would be satisfied by the hyphen here; the rule uses (?![\\w.-]) instead.
      leaks(store, "X-Served-By: api.internal-tools.example.com\r\n").should be_empty
      leaks(store, "X-Served-By: x.corp.example.com\r\n").should be_empty
      leaks(store, "Server: localhost-proxy\r\n").should be_empty
    end
  end

  it "leaves public addresses and version strings alone" do
    with_store do |store|
      leaks(store, "X-Served-By: 203.0.113.9\r\nServer: nginx/1.10.1.2\r\n").should be_empty
      # Loopback is excluded upstream in BodyLeaks::PRIVATE_IP and stays excluded here.
      leaks(store, "X-Debug: 127.0.0.1\r\n").should be_empty
    end
  end

  it "reports each distinct header once, capped per response" do
    with_store do |store|
      found = leaks(store, "Via: 1.1 10.0.0.1\r\nX-A: 10.0.0.2\r\nX-B: 10.0.0.3\r\nX-C: 10.0.0.4\r\n")
      found.size.should eq(3)
      found.map(&.evidence).should eq(["Via: 10.0.0.1", "X-A: 10.0.0.2", "X-B: 10.0.0.3"])
    end
  end

  it "does not report gori's own X-Gori-* marker lines" do
    with_store do |store|
      leaks(store, "X-Gori-Discover: 192.168.1.5\r\n").should be_empty
    end
  end

  it "does not report client-identifying forwarding headers" do
    with_store do |store|
      leaks(store, "X-Forwarded-For: 10.0.0.9\r\n").should be_empty
      leaks(store, "X-Real-IP: 192.168.1.4\r\n").should be_empty
      leaks(store, "Forwarded: for=10.1.1.1\r\n").should be_empty
      # A neighbour header on the same response is still a leak.
      leaks(store, "X-Forwarded-For: 10.0.0.9\r\nX-Backend-Server: web03.corp\r\n").size.should eq(1)
    end
  end
end
