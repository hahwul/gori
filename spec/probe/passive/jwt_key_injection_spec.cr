require "../../spec_helper"
require "base64"

# --- file-local harness (mirrors spec/probe/passive/jwt_spec.cr) -------------------------

private def with_store(&)
  path = File.tempname("gori-jwt-keyinj-rule", ".db")
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
    method: method, target: target, http_version: "HTTP/1.1", head: head.to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy)
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

# The one detection under test, or nil.
private def key_inj(dets) : Gori::Probe::Detection?
  dets.find { |d| d.code == "jwt_key_injection_header" }
end

describe Gori::Probe::Passive::JwtWeaknesses do
  describe "jwt_key_injection_header" do
    it "flags a header carrying jku (a JWKS URL the token chose itself)" do
      with_store do |store|
        tok = token(%({"alg":"RS256","jku":"https://evil.test/keys"}),
          %({"sub":"1","exp":9999999999}))
        dets = jwt(store, req_headers: "Authorization: Bearer #{tok}\r\n")
        codes(dets).should contain("jwt_key_injection_header")
        d = key_inj(dets).not_nil!
        d.severity.should eq(Gori::Store::Severity::Medium)
        d.category.should eq(Gori::Probe::Category::HEADERS)
        d.title.should eq("JWT header carries a key-injection parameter (jku/x5u/jwk)")
        d.evidence.should eq("Authorization: header has jku")
        # The URL is attacker content; evidence names the PARAMETER, never its value.
        d.evidence.to_s.should_not contain("evil.test")
      end
    end

    it "flags a header carrying x5u" do
      with_store do |store|
        tok = token(%({"alg":"RS256","x5u":"https://evil.test/chain.pem"}),
          %({"sub":"1","exp":9999999999}))
        d = key_inj(jwt(store, req_headers: "Authorization: Bearer #{tok}\r\n")).not_nil!
        d.severity.should eq(Gori::Store::Severity::Medium)
        d.evidence.should eq("Authorization: header has x5u")
      end
    end

    it "flags a header embedding a jwk public key" do
      with_store do |store|
        tok = token(%({"alg":"RS256","jwk":{"kty":"RSA","n":"AQAB","e":"AQAB"}}),
          %({"sub":"1","exp":9999999999}))
        d = key_inj(jwt(store, req_headers: "Authorization: Bearer #{tok}\r\n")).not_nil!
        d.evidence.should eq("Authorization: header has jwk")
      end
    end

    it "emits ONE detection naming both params, in jku/x5u/jwk order" do
      with_store do |store|
        # Declared jwk-first on the wire; the evidence order is the fixed registry order.
        tok = token(%({"alg":"RS256","jwk":{"kty":"RSA"},"jku":"https://evil.test/keys"}),
          %({"sub":"1","exp":9999999999}))
        dets = jwt(store, req_headers: "Authorization: Bearer #{tok}\r\n")
        codes(dets).count("jwt_key_injection_header").should eq(1)
        key_inj(dets).not_nil!.evidence.should eq("Authorization: header has jku/jwk")
      end
    end

    it "does NOT flag kid, which is ubiquitous and not itself a weakness" do
      with_store do |store|
        tok = token(%({"alg":"HS256","kid":"abc","typ":"JWT"}), %({"sub":"1","exp":9999999999}))
        dets = jwt(store, req_headers: "Authorization: Bearer #{tok}\r\n")
        codes(dets).should_not contain("jwt_key_injection_header")
        dets.should be_empty # kid alone is a clean token
      end
    end

    it "flags a token carried in a request Cookie and names the cookie" do
      with_store do |store|
        tok = token(%({"alg":"RS256","jku":"https://evil.test/keys"}),
          %({"sub":"1","exp":9999999999}))
        dets = jwt(store, req_headers: "Cookie: theme=dark; session=#{tok}\r\n")
        codes(dets).should contain("jwt_key_injection_header")
        key_inj(dets).not_nil!.evidence.should eq("Cookie session: header has jku")
      end
    end

    it "flags a token issued in a response Set-Cookie" do
      with_store do |store|
        tok = token(%({"alg":"RS256","x5u":"https://evil.test/c.pem"}),
          %({"sub":"1","exp":9999999999}))
        head = "HTTP/1.1 200 OK\r\nSet-Cookie: auth=#{tok}; Path=/; HttpOnly\r\n\r\n"
        key_inj(jwt(store, resp_head: head)).not_nil!.evidence.should eq("Set-Cookie auth: header has x5u")
      end
    end

    it "matches the param names case-insensitively" do
      with_store do |store|
        tok = token(%({"alg":"RS256","JKU":"https://evil.test/keys"}),
          %({"sub":"1","exp":9999999999}))
        key_inj(jwt(store, req_headers: "Authorization: Bearer #{tok}\r\n")).not_nil!
          .evidence.should eq("Authorization: header has jku")
      end
    end

    it "leaves the existing checks unchanged on a token without these params" do
      with_store do |store|
        tok = token(%({"alg":"none","typ":"JWT"}), %({"sub":"1","exp":9999999999}), "")
        dets = jwt(store, req_headers: "Authorization: Bearer #{tok}\r\n")
        codes(dets).should contain("jwt_alg_none")
        codes(dets).should_not contain("jwt_key_injection_header")
      end
    end

    it "still reports alg:none alongside the key-injection param" do
      with_store do |store|
        tok = token(%({"alg":"none","jku":"https://evil.test/keys"}),
          %({"sub":"1","exp":9999999999}), "")
        codes(jwt(store, req_headers: "Authorization: Bearer #{tok}\r\n"))
          .should contain("jwt_alg_none")
        codes(jwt(store, req_headers: "Authorization: Bearer #{tok}\r\n"))
          .should contain("jwt_key_injection_header")
      end
    end

    it "does not raise on an undecodable or non-object header" do
      with_store do |store|
        jwt(store, req_headers: "Cookie: sid=eyJnot-base64!!.xx.yy\r\n").should be_empty
        jwt(store, req_headers: "Authorization: Bearer abc.def.ghi\r\n").should be_empty
      end
    end
  end
end
