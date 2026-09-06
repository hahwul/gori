# Shared harness for the spec/probe/*_spec.cr files split out of the former spec/probe_spec.cr.
# A helper used by one file only stayed private in that file. Names carry a probe_/Probe
# prefix (classes live under ProbeHarness) so they cannot shadow, or be shadowed by, the
# file-private helpers other specs keep.

# A key id shaped exactly like a real one and deliberately NOT one of AWS's published
# documentation placeholders (`AKIAIOSFODNN7EXAMPLE` and friends), which `Secrets::PATTERNS`
# screens out — so a fixture standing in for a LEAKED key has to avoid them. Assembled from two
# halves so secret-scanning push protection lets the fixture through.
PROBE_AWS_KEY_ID = "AKIA" + "3ZQF7XKPL2WVNB6D"

# Insert a flow + response and return its full FlowDetail (what the analyzer feeds Passive).
# `req_headers` is raw extra request-header lines (each ending \r\n); `req_body` the request body.
def probe_capture_flow(store, resp_head : String, *, scheme = "https", host = "acme.test",
                       target = "/", status = 200, content_type : String? = "text/html",
                       body : String? = nil, method = "GET", req_headers = "",
                       req_body : String? = nil) : Gori::Store::FlowDetail
  head = String.build do |io|
    io << method << " " << target << " HTTP/1.1\r\nHost: " << host << "\r\n" << req_headers << "\r\n"
  end
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: scheme, host: host, port: scheme == "https" ? 443 : 80,
    method: method, target: target, http_version: "HTTP/1.1",
    head: head.to_slice, body: req_body.try(&.to_slice), source: Gori::FlowSource::Kind::Proxy)
  id = store.insert_flow(req)
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: resp_head.to_slice, body: body.try(&.to_slice),
    reason: "OK", content_type: content_type, duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

# Run passive analysis on one flow and return the detections (ungrouped).
def probe_analyze(store, **kw) : Array(Gori::Probe::Detection)
  Gori::Probe::Passive.analyze(probe_capture_flow(store, **kw))
end

def probe_codes_of(dets : Array(Gori::Probe::Detection)) : Array(String)
  dets.map(&.code)
end

def probe_codes(store) : Array(String)
  store.probe_issues.map(&.code)
end

# A valid, long JWT used across several tests (all three segments well over the length gate).
PROBE_JWT = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"

def probe_analyze_html(store, body : String)
  probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
    content_type: "text/html", body: body)
end
