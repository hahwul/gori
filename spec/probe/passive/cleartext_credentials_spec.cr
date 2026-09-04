require "../../spec_helper"

# --- file-local harness (mirrors spec/probe_spec.cr's private with_store/capture_flow) ---

private def with_store(&)
  path = File.tempname("gori-cleartext", ".db")
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

private def capture_flow(store, *, scheme = "http", host = "shop.acme.test",
                         method = "POST", target = "/login",
                         req_content_type : String? = "application/x-www-form-urlencoded",
                         req_body : String? = nil,
                         content_type : String? = "text/html",
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
    flow_id: id, status: 200,
    head: "HTTP/1.1 200 OK\r\nContent-Type: #{content_type}\r\n\r\n".to_slice,
    body: body.try(&.to_slice), reason: "OK", content_type: content_type, duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

private def dets(store, **kw) : Array(Gori::Probe::Detection)
  Gori::Probe::Passive.analyze(capture_flow(store, **kw))
    .select { |d| d.code == "cleartext_credentials" || d.code == "cleartext_password_form" }
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
end
