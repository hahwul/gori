require "../../spec_helper"

# --- file-local harness (mirrors spec/probe_spec.cr's private with_store/capture_flow) ---

private def capture_flow(store, *, scheme = "http", host = "shop.acme.test",
                         method = "POST", target = "/login",
                         req_content_type : String? = "application/x-www-form-urlencoded",
                         req_body : String? = nil,
                         content_type : String? = "text/html",
                         status : Int32 = 200,
                         state = Gori::Store::FlowState::Complete,
                         body : String? = nil) : Gori::Store::FlowDetail
  head = String.build do |io|
    io << method << " " << target << " HTTP/1.1\r\nHost: " << host << "\r\n"
    io << "Content-Type: " << req_content_type << "\r\n" if req_content_type
    io << "\r\n"
  end
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: scheme, host: host, port: scheme == "http" ? 80 : 443,
    method: method, target: target, http_version: "HTTP/1.1", head: head.to_slice,
    body: req_body.try(&.to_slice), source: Gori::FlowSource::Kind::Proxy)
  id = store.insert_flow(req)
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status,
    head: "HTTP/1.1 #{status}\r\nContent-Type: #{content_type}\r\n\r\n".to_slice,
    body: body.try(&.to_slice), reason: "OK", content_type: content_type, duration_us: 1_i64, state: state))
  store.get_flow(id).not_nil!
end

private def dets(store, **kw) : Array(Gori::Probe::Detection)
  Gori::Probe::Passive.analyze(capture_flow(store, **kw))
    .select { |d| d.code.in?("cleartext_credentials", "cleartext_password_form", "cleartext_saml_assertion") }
end

private SAML_BEARER = <<-XML
  <sp:Response xmlns:sp="urn:oasis:names:tc:SAML:2.0:protocol" Version="2.0" ID="_response"
               IssueInstant="2026-11-19T00:00:00Z">
    <sp:Status><sp:StatusCode Value="urn:oasis:names:tc:SAML:2.0:status:Success"/></sp:Status>
    <Assertion xmlns="urn:oasis:names:tc:SAML:2.0:assertion" Version="2.0" ID="_assertion"
               IssueInstant="2026-11-19T00:00:00Z">
      <Issuer>https://issuer.example.test/metadata</Issuer>
      <Subject>
        <NameID>example-identity</NameID>
        <SubjectConfirmation Method="urn:oasis:names:tc:SAML:2.0:cm:bearer"/>
      </Subject>
    </Assertion>
  </sp:Response>
  XML

private def saml_form(xml : String = SAML_BEARER, *, name = "SAMLResponse", binding = :post) : String
  "#{name}=#{Gori::Saml.encode_value(xml, binding)}"
end

describe Gori::Probe::Passive::CleartextCredentials do
  it "flags a form-encoded password submitted over http" do
    with_store do |store|
      found = dets(store, req_body: "user=alice&password=hunter2&remember=1")
      creds = found.select { |d| d.code == "cleartext_credentials" }
      creds.size.should eq(1)
      creds[0].severity.should eq(Gori::Store::Severity::High)
      creds[0].category.should eq(Gori::Probe::Category::HEADERS)
      creds[0].evidence.should eq("password") # the NAME, never the value
    end
  end

  # The per-byte `(?:[^"\\]|\\.)+` value pattern hit PCRE2's JIT stack limit near 60 KB,
  # inside the passive body cap, and the finding was lost to a debug log line.
  it "flags a JSON password member with a ~60 KB value" do
    with_store do |store|
      found = dets(store, req_content_type: "application/json",
        req_body: %({"password":"#{"a" * 60_000}"}))
      found.count { |d| d.code == "cleartext_credentials" }.should eq(1)
    end
  end

  it "normalises punctuated and suffixed parameter names" do
    with_store do |store|
      dets(store, req_body: "user%5Bpassword%5D=hunter2").any?(&.code.== "cleartext_credentials").should be_true
      dets(store, req_body: "confirm-password=hunter2").any?(&.code.== "cleartext_credentials").should be_true
      dets(store, req_body: "client_secret=s3cr3t").any?(&.code.== "cleartext_credentials").should be_true
    end
  end

  it "flags a JSON password member" do
    with_store do |store|
      found = dets(store, req_content_type: "application/json",
        req_body: %({"email":"a@b.test","password":"hunter2"}))
      found.count { |d| d.code == "cleartext_credentials" }.should eq(1)
    end
  end

  it "continues past JSON UI state and covers exact client-secret names" do
    with_store do |store|
      dets(store, req_content_type: "application/json",
        req_body: %({"showPassword":"false","password":"hunter2"}))
        .count(&.code.== "cleartext_credentials").should eq(1)
      dets(store, req_content_type: "application/json",
        req_body: %({"client_secret":"s3cr3t"}))
        .count(&.code.== "cleartext_credentials").should eq(1)
      dets(store, req_content_type: "application/json",
        req_body: %({"apiKey":"s3cr3t"}))
        .count(&.code.== "cleartext_credentials").should eq(1)
    end
  end

  it "does not flag UI state carried under a password-ish name" do
    with_store do |store|
      dets(store, req_body: "showPassword=false&password=").should be_empty
      # An unquoted JSON boolean never matches the "…" value pattern to begin with.
      dets(store, req_content_type: "application/json",
        req_body: %({"showPassword":false})).should be_empty
      # A boolean a serialiser wrote as a QUOTED string is screened by NON_SECRET_VALUES, the
      # same as the form-encoded path — otherwise `"showPassword":"false"` reads as a High
      # cleartext password.
      dets(store, req_content_type: "application/json",
        req_body: %({"showPassword":"false"})).should be_empty
      # …but a real quoted secret under the very same key is still flagged (the screen is the
      # value, not the name).
      dets(store, req_content_type: "application/json",
        req_body: %({"showPassword":"hunter2"})).any?(&.code.== "cleartext_credentials").should be_true
    end
  end

  it "does not flag a password_hint field" do
    with_store do |store|
      dets(store, req_body: "password_hint=my+first+pet").should be_empty
    end
  end

  it "leaves HTTPS alone" do
    with_store do |store|
      dets(store, scheme: "https", req_body: "password=hunter2",
        body: %(<form><input type="password" name="password"></form>)).should be_empty
    end
  end

  it "leaves a loopback origin alone (a browser trusts it)" do
    with_store do |store|
      dets(store, host: "localhost", req_body: "password=hunter2").should be_empty
      dets(store, host: "127.0.0.1", req_body: "password=hunter2").should be_empty
    end
  end

  it "flags a password input served over http" do
    with_store do |store|
      found = dets(store, method: "GET", target: "/login", req_content_type: nil,
        body: %(<form action="https://shop.acme.test/login"><input type="password" name="pw"></form>))
      form = found.select { |d| d.code == "cleartext_password_form" }
      form.size.should eq(1)
      form[0].severity.should eq(Gori::Store::Severity::Medium)
    end
  end

  it "does not read a data-type attribute as an input type" do
    with_store do |store|
      dets(store, method: "GET", req_content_type: nil,
        body: %(<div data-type="password">enter your password</div>)).should be_empty
    end
  end

  it "does not parse multipart bodies (an empty field is not a transmitted password)" do
    with_store do |store|
      body = "--x\r\nContent-Disposition: form-data; name=\"password\"\r\n\r\n\r\n--x--\r\n"
      dets(store, req_content_type: "multipart/form-data; boundary=x", req_body: body).should be_empty
    end
  end

  it "reports the SAML assertion crossing cleartext without asserting authentication succeeded" do
    with_store do |store|
      detail = capture_flow(store, status: 403,
        target: "http://shop.acme.test/sso/acs/path-secret?flag=query-secret",
        req_body: "RelayState=relay-secret&#{saml_form(name: "SAML%52esponse")}",
        req_content_type: "Application/X-WWW-Form-Urlencoded; charset=UTF-8")
      hit = Gori::Probe::Passive.analyze(detail).find!(&.code.==("cleartext_saml_assertion"))
      hit.severity.should eq(Gori::Store::Severity::High)
      hit.category.should eq(Gori::Probe::Category::HEADERS)
      hit.flow_id.should eq(detail.row.id)
      hit.url.should eq("http://shop.acme.test/")
      hit.evidence.should eq("SAMLResponse (HTTP-POST, bearer subject confirmation)")
    end
  end

  it "requires the captured POST's form field over non-loopback cleartext HTTP" do
    with_store do |store|
      form = saml_form
      dets(store, req_body: form).count(&.code.==("cleartext_saml_assertion")).should eq(1)
      dets(store, req_body: form, scheme: "https").should be_empty
      dets(store, req_body: form, host: "127.0.0.1").should be_empty
      dets(store, req_body: form, host: "local.localhost").should be_empty
      dets(store, req_body: form, method: "GET").should be_empty
      dets(store, req_body: form, req_content_type: "application/json").should be_empty
      dets(store, req_body: form, status: 0, state: Gori::Store::FlowState::Aborted).should be_empty
      dets(store, target: "/sso/acs?#{form}").should be_empty
      dets(store, req_body: saml_form(name: "SAMLRequest")).should be_empty
      dets(store, req_body: "note=#{form}").should be_empty
      dets(store, req_body: saml_form(binding: :redirect)).should be_empty
    end
  end

  it "requires a namespaced assertion and bearer method within a SAML protocol response" do
    with_store do |store|
      [
        "<sample>#{SAML_BEARER}</sample>",
        SAML_BEARER.sub("SAML:2.0:protocol", "SAML:1.0:protocol"),
        SAML_BEARER.sub("SAML:2.0:assertion", "SAML:1.0:assertion"),
        SAML_BEARER.sub(%( ID="_response"), ""),
        SAML_BEARER.sub(%( ID="_assertion"), ""),
        SAML_BEARER.sub("<Issuer>https://issuer.example.test/metadata</Issuer>", ""),
        SAML_BEARER.sub("cm:bearer", "cm:holder-of-key"),
        SAML_BEARER.sub(%(Method="), %(sp:Method=")),
        SAML_BEARER.sub("<Subject>", "<Advice><Subject>").sub("</Subject>", "</Subject></Advice>"),
        SAML_BEARER.gsub("Assertion", "EncryptedAssertion"),
        SAML_BEARER.sub("</sp:Response>", ""),
        "<!DOCTYPE sp:Response>#{SAML_BEARER}",
      ].each do |xml|
        dets(store, req_body: saml_form(xml)).should be_empty
      end
      dets(store, req_body: "SAMLResponse=%21invalid").should be_empty
    end
  end

  it "skips a form beyond the passive body budget" do
    with_store do |store|
      body = "#{saml_form}&padding=#{"x" * 65_536}"
      dets(store, req_body: body).should be_empty
    end
  end
end
