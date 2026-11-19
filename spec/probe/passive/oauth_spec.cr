require "../../spec_helper"
require "../../support/probe_harness"

private def oauth_dets(store, target : String, method = "GET", req_headers = "", req_body : String? = nil)
  probe_analyze(store, resp_head: "HTTP/1.1 302 Found\r\n\r\n", target: target,
    method: method, req_headers: req_headers, req_body: req_body)
end

private def oauth_codes(store, target : String, **opts)
  probe_codes_of(oauth_dets(store, target, **opts)).select(&.starts_with?("oauth_"))
end

OAUTH_AUTHZ = "/authorize?response_type=code&client_id=app&redirect_uri=https%3A%2F%2Fapp.test%2Fcb"

private OAUTH_TOKEN_JSON = %({"token_type":"Bearer","access_token":"TOKEN_FIXTURE"})

private def oauth_exchange(store, form : String, *,
                           body : String = OAUTH_TOKEN_JSON, status : Int32 = 200,
                           headers : String = "", req_headers : String = "",
                           form_type : String = "application/x-www-form-urlencoded",
                           disabled : Set(String) = Gori::Probe::Passive::NO_DISABLED)
  detail = probe_capture_flow(store, target: "/exchange", method: "POST",
    req_headers: "Content-Type: #{form_type}\r\n#{req_headers}", req_body: form,
    resp_head: "HTTP/1.1 #{status} Response\r\nContent-Type: application/json\r\n#{headers}\r\n",
    status: status, content_type: "application/json", body: body)
  Gori::Probe::Passive.analyze(detail, disabled: disabled)
end

describe Gori::Probe::Passive::OAuthAuthorization do
  it "flags a code request with no PKCE, state or nonce as Medium" do
    with_store do |store|
      det = oauth_dets(store, OAUTH_AUTHZ).find(&.code.==("oauth_no_csrf_protection")).not_nil!
      det.severity.should eq(Gori::Store::Severity::Medium)
      det.evidence.should eq("response_type=code")
      oauth_codes(store, OAUTH_AUTHZ).should eq(["oauth_no_csrf_protection"])
    end
  end

  it "downgrades to an Info no-PKCE note when state or nonce is present" do
    with_store do |store|
      oauth_codes(store, OAUTH_AUTHZ + "&state=xyz").should eq(["oauth_no_pkce"])
      oauth_codes(store, OAUTH_AUTHZ + "&nonce=n1").should eq(["oauth_no_pkce"])
      oauth_dets(store, OAUTH_AUTHZ + "&state=xyz").find(&.code.==("oauth_no_pkce")).not_nil!
        .severity.should eq(Gori::Store::Severity::Info)
      # An empty value is absent; a malformed escape is still a value.
      oauth_codes(store, OAUTH_AUTHZ + "&state=").should eq(["oauth_no_csrf_protection"])
      oauth_codes(store, OAUTH_AUTHZ + "&state=&state=%zz%80").should eq(["oauth_no_pkce"])
    end
  end

  it "accepts S256 PKCE and flags plain or a missing method" do
    with_store do |store|
      oauth_codes(store, OAUTH_AUTHZ + "&code_challenge=abc&code_challenge_method=S256").should be_empty
      oauth_codes(store, OAUTH_AUTHZ + "&code_challenge=abc&code_challenge_method=plain").should eq(["oauth_pkce_plain"])
      oauth_codes(store, OAUTH_AUTHZ + "&code_challenge=abc").should eq(["oauth_pkce_plain"])
    end
  end

  it "flags the implicit grant but not a bare OIDC id_token request" do
    with_store do |store|
      base = "/authorize?client_id=app&state=s&nonce=n&response_type="
      oauth_codes(store, base + "token").should eq(["oauth_implicit_flow"])
      oauth_codes(store, base + "id_token%20token").should eq(["oauth_implicit_flow"])
      oauth_codes(store, base + "id_token+token").should eq(["oauth_implicit_flow"])
      oauth_codes(store, base + "token,signed_request").should eq(["oauth_implicit_flow"])
      oauth_codes(store, base + "token%2Csigned_request").should eq(["oauth_implicit_flow"])
      oauth_codes(store, base + "id_token").should be_empty
    end
  end

  it "skips PAR and JAR requests, whose real parameters are elsewhere" do
    with_store do |store|
      oauth_codes(store, OAUTH_AUTHZ + "&request_uri=urn%3Aietf%3Aparams%3Aoauth%3Arequest_uri%3Aabc").should be_empty
      oauth_codes(store, OAUTH_AUTHZ + "&request=eyJhbGciOiJub25lIn0.e30.").should be_empty
    end
  end

  it "reads a form-encoded POST authorization request from the body" do
    with_store do |store|
      oauth_codes(store, "/authorize", method: "POST",
        req_headers: "Content-Type: application/x-www-form-urlencoded\r\n",
        req_body: "response_type=code&client_id=app&redirect_uri=x").should eq(["oauth_no_csrf_protection"])
      # Part of it in the query: the body still decides.
      oauth_codes(store, "/authorize?response_type=code", method: "POST",
        req_headers: "Content-Type: application/x-www-form-urlencoded\r\n",
        req_body: "response_type=code&client_id=app&state=s").should eq(["oauth_no_pkce"])
    end
  end

  it "ignores requests that are not authorization requests" do
    with_store do |store|
      oauth_codes(store, "/token?client_id=app&grant_type=authorization_code").should be_empty
      oauth_codes(store, "/x?response_type=code").should be_empty
      oauth_codes(store, "/authorize").should be_empty
      # `;` is not a separator: this has no state.
      oauth_codes(store, OAUTH_AUTHZ + "%3Bx;state=1").should eq(["oauth_no_csrf_protection"])
    end
  end

  it "never puts state, nonce, code_challenge or client_id values in evidence" do
    with_store do |store|
      dets = oauth_dets(store, "/authorize?response_type=code%20token&client_id=CLIENTSECRETID" \
                               "&state=STATEVAL&nonce=NONCEVAL&code_challenge=CHALLENGEVAL")
      dets.count(&.code.starts_with?("oauth_")).should eq(2)
      dets.each do |d|
        ev = d.evidence.to_s
        %w[CLIENTSECRETID STATEVAL NONCEVAL CHALLENGEVAL].each { |v| ev.should_not contain(v) }
      end
    end
  end

  it "flags a successful password grant with only the grant type as evidence" do
    with_store do |store|
      findings = oauth_exchange(store, "grant_type=p%61ssword&username=USER_FIXTURE&password=PASSWORD_FIXTURE",
        headers: "Cache-Control: no-store\r\n")
      findings.find!(&.code.==("oauth_password_grant")).evidence.should eq("grant_type=password")
      probe_codes_of(findings).should_not contain("oauth_token_no_store")
    end
  end

  it "flags an OAuth token response without no-store regardless of client authentication" do
    with_store do |store|
      ["", "Authorization: Basic CLIENT_FIXTURE\r\n"].each do |req_headers|
        findings = oauth_exchange(store, "grant_type=authorization_code&code=CODE_FIXTURE",
          req_headers: req_headers, headers: "Cache-Control: public, max-age=60\r\n")
        cache = findings.select(&.code.==("oauth_token_no_store"))
        cache.size.should eq(1)
        cache.first.evidence.should eq("OAuth token response lacks Cache-Control: no-store")
        probe_codes_of(findings).should_not contain("cacheable_json")
        probe_codes_of(findings).should_not contain("oauth_password_grant")
      end
    end
  end

  it "requires a successful OAuth exchange with a real form grant and top-level token fields" do
    with_store do |store|
      password = "grant_type=password&username=USER_FIXTURE&password=PASSWORD_FIXTURE"
      [
        oauth_exchange(store, password, status: 400),
        oauth_exchange(store, password, body: %({"error":"invalid_grant"})),
        oauth_exchange(store, password, body: %({"access_token":123,"token_type":"Bearer"})),
        oauth_exchange(store, password, body: %({"result":#{OAUTH_TOKEN_JSON}})),
        oauth_exchange(store, password, form_type: "text/plain; format=application/x-www-form-urlencoded"),
        oauth_exchange(store, "ordinary=1;#{password}"),
        oauth_exchange(store, "grant_type=password&grant_type=client_credentials"),
        oauth_exchange(store, "ordinary=1"),
      ].each do |findings|
        codes = probe_codes_of(findings)
        codes.should_not contain("oauth_password_grant")
        codes.should_not contain("oauth_token_no_store")
      end
    end
  end

  it "reads a standalone no-store directive from repeated Cache-Control fields" do
    with_store do |store|
      form = "gr%61nt_type=client_credentials"
      ignored = oauth_exchange(store, form, headers: "Cache-Control: note=\"private, no-store\"\r\n")
      probe_codes_of(ignored).should contain("oauth_token_no_store")
      protected_response = oauth_exchange(store, form,
        headers: "Cache-Control: No-Store\r\nCache-Control: max-age=0\r\n")
      probe_codes_of(protected_response).should_not contain("oauth_token_no_store")
    end
  end

  it "keeps the OAuth and cache policy rule toggles independent" do
    with_store do |store|
      form = "grant_type=password&username=USER_FIXTURE&password=PASSWORD_FIXTURE"
      probe_codes_of(oauth_exchange(store, form, disabled: Set{"oauth"}))
        .select(&.starts_with?("oauth_")).should eq(["oauth_token_no_store"])
      probe_codes_of(oauth_exchange(store, form, disabled: Set{"cacheable_api"}))
        .select(&.starts_with?("oauth_")).should eq(["oauth_password_grant"])
    end
  end
end
