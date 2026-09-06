require "../../spec_helper"
require "../../support/probe_harness"

describe Gori::Probe::Passive::Auth do
  it "detects opaque Bearer tokens over HTTP even behind a duplicate header and redacts evidence" do
    with_store do |store|
      detections = probe_analyze(store, scheme: "http",
        req_headers: "Authorization: bEaReR opaque-secret\r\nAuthorization: Digest example\r\n",
        resp_head: "HTTP/1.1 401 Unauthorized\r\n\r\n", status: 401)
      hit = detections.find(&.code.==("insecure_bearer_auth")).not_nil!
      hit.severity.should eq(Gori::Store::Severity::High)
      hit.evidence.to_s.should_not contain("opaque-secret")
    end
  end

  it "ignores empty tokens, scheme lookalikes, challenges and TLS-protected submissions" do
    with_store do |store|
      ["Bearer", "Bearer   ", "BearerExtra secret", "Digest secret"].each do |auth|
        probe_codes_of(probe_analyze(store, scheme: "http", req_headers: "Authorization: #{auth}\r\n",
          resp_head: "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer\r\n\r\n")).should_not contain("insecure_bearer_auth")
      end
      probe_codes_of(probe_analyze(store, req_headers: "Authorization: Bearer secret\r\n",
        resp_head: "HTTP/1.1 200 OK\r\n\r\n")).should_not contain("insecure_bearer_auth")
    end
  end
end
