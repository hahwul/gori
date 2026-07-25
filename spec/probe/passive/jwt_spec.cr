require "../../spec_helper"
require "base64"

# --- file-local harness (mirrors spec/probe_spec.cr's private with_store/capture_flow) ---

private def with_store(&)
  path = File.tempname("gori-jwt-rule", ".db")
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

private def capture_flow(store, resp_head : String = "HTTP/1.1 200 OK\r\n\r\n", *,
                         scheme = "https", host = "acme.test", target = "/", status = 200,
                         content_type : String? = "text/html", body : String? = nil,
                         method = "GET", req_headers = "") : Gori::Store::FlowDetail
  head = String.build do |io|
    io << method << " " << target << " HTTP/1.1\r\nHost: " << host << "\r\n" << req_headers << "\r\n"
  end
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: scheme, host: host, port: scheme == "https" ? 443 : 80,
    method: method, target: target, http_version: "HTTP/1.1", head: head.to_slice, body: nil)
  id = store.insert_flow(req)
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: resp_head.to_slice, body: body.try(&.to_slice),
    reason: "OK", content_type: content_type, duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

# Only the JWT rule's detections.
private def jwt(store, **kw) : Array(Gori::Probe::Detection)
  Gori::Probe::Passive.analyze(capture_flow(store, **kw)).select(&.code.starts_with?("jwt_"))
end

private def codes(dets) : Array(String)
  dets.map(&.code)
end

# Build a token from raw header/payload JSON (unpadded base64url, as on the wire).
private def token(header : String, payload : String, sig : String = "c2ln") : String
  b64 = ->(s : String) { Base64.urlsafe_encode(s, padding: false) }
  "#{b64.call(header)}.#{b64.call(payload)}.#{sig}"
end

describe Gori::Probe::Passive::JwtWeaknesses do
  it "flags alg:none in a Bearer token (signature stripped)" do
    with_store do |store|
      tok = token(%({"alg":"none","typ":"JWT"}), %({"sub":"1","exp":9999999999}), "")
      dets = jwt(store, req_headers: "Authorization: Bearer #{tok}\r\n")
      codes(dets).should contain("jwt_alg_none")
      d = dets.find { |x| x.code == "jwt_alg_none" }.not_nil!
      d.severity.should eq(Gori::Store::Severity::High)
      d.category.should eq(Gori::Probe::Category::HEADERS)
      d.evidence.should eq("Authorization: alg=none")
    end
  end

  it "flags alg:none case-insensitively" do
    with_store do |store|
      tok = token(%({"alg":"NoNe"}), %({"sub":"1","exp":9999999999}), "")
      codes(jwt(store, req_headers: "Authorization: Bearer #{tok}\r\n")).should contain("jwt_alg_none")
    end
  end

  it "does not flag a standard HS256 token with an exp and no sensitive claims" do
    with_store do |store|
      tok = token(%({"alg":"HS256","typ":"JWT"}), %({"sub":"1","exp":9999999999}))
      jwt(store, req_headers: "Authorization: Bearer #{tok}\r\n").should be_empty
    end
  end

  it "flags a non-standard algorithm, sanitizing the alg for evidence" do
    with_store do |store|
      tok = token(%({"alg":"HS1<script>"}), %({"sub":"1","exp":9999999999}))
      dets = jwt(store, req_headers: "Authorization: Bearer #{tok}\r\n")
      d = dets.find { |x| x.code == "jwt_weak_alg" }.not_nil!
      d.severity.should eq(Gori::Store::Severity::Low)
      d.evidence.should eq("Authorization: alg=HS1script")
    end
  end

  it "flags a token with no exp claim" do
    with_store do |store|
      tok = token(%({"alg":"RS256"}), %({"sub":"1"}))
      dets = jwt(store, req_headers: "Authorization: Bearer #{tok}\r\n")
      d = dets.find { |x| x.code == "jwt_no_expiry" }.not_nil!
      d.severity.should eq(Gori::Store::Severity::Low)
      d.evidence.should eq("Authorization")
    end
  end

  it "reports sensitive claim NAMES only, never their values" do
    with_store do |store|
      tok = token(%({"alg":"HS256"}),
        %({"sub":"1","exp":9999999999,"role":"admin","email":"ceo@acme.test"}))
      dets = jwt(store, req_headers: "Authorization: Bearer #{tok}\r\n")
      d = dets.find { |x| x.code == "jwt_sensitive_claims" }.not_nil!
      d.severity.should eq(Gori::Store::Severity::Info)
      d.category.should eq(Gori::Probe::Category::INFOLEAK)
      d.evidence.should eq("role, email")
      dets.each(&.evidence.to_s.should_not(contain("ceo@acme.test")))
      dets.each(&.evidence.to_s.should_not(contain(tok)))
    end
  end

  it "decodes a token carried in a request Cookie and names the cookie" do
    with_store do |store|
      tok = token(%({"alg":"none"}), %({"sub":"1","exp":9999999999}), "")
      dets = jwt(store, req_headers: "Cookie: theme=dark; session=#{tok}\r\n")
      dets.find { |x| x.code == "jwt_alg_none" }.not_nil!.evidence.should eq("Cookie session: alg=none")
    end
  end

  it "decodes a token issued in a response Set-Cookie" do
    with_store do |store|
      tok = token(%({"alg":"none"}), %({"sub":"1","exp":9999999999}), "")
      head = "HTTP/1.1 200 OK\r\nSet-Cookie: auth=#{tok}; Path=/; HttpOnly\r\n\r\n"
      dets = jwt(store, resp_head: head)
      dets.find { |x| x.code == "jwt_alg_none" }.not_nil!.evidence.should eq("Set-Cookie auth: alg=none")
    end
  end

  it "ignores a non-JWT dotted value and an undecodable header" do
    with_store do |store|
      jwt(store, req_headers: "Authorization: Bearer abc.def.ghi\r\n").should be_empty
      jwt(store, req_headers: "Cookie: sid=eyJnot-base64!!.xx.yy\r\n").should be_empty
    end
  end

  it "does not raise on a header carrying invalid UTF-8" do
    with_store do |store|
      # \xff is not valid UTF-8; the scan must scrub rather than let PCRE raise.
      tok = token(%({"alg":"none"}), %({"sub":"1","exp":9999999999}), "")
      dets = jwt(store, req_headers: "Cookie: junk=\xff; sid=#{tok}\r\n")
      codes(dets).should contain("jwt_alg_none")
    end
  end
end
