require "../spec_helper"

# `env_headers` and the inlined last response body on `get_repeater_context` (#904).
#
# `redact_head` cannot tell `Authorization: Bearer $AUTH` from `Authorization: Bearer <token>`
# — both are blanked — so the operator could not confirm which env key a saved request was
# wired to without asking for the secret. These pin the shape projection: a reference and a
# scheme survive, everything else collapses.

private def with_store(&)
  path = File.tempname("gori-envheaders", ".db")
  store = Gori::Store.open(path)
  prev_env = Gori::Settings.project_env_vars
  begin
    yield store
  ensure
    Gori::Settings.project_env_vars = prev_env
    Gori::Env.bump_highlight_rev
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def tools(store)
  Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
end

private def call_json(store, name, args : String) : JSON::Any
  r = tools(store).call(name, JSON.parse(args))
  fail "#{name} errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

private def seeded_500(store) : Int64
  id = store.insert_repeater("https://api.test", "GET /a HTTP/1.1\r\nHost: h\r\n\r\n".to_slice,
    false, true, nil, 0)
  store.update_repeater_response(id,
    "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\n\r\n".to_slice,
    %({"error":"boom"}).to_slice, nil, 42_i64)
  id
end

private def shapes_for(store, request : String) : Hash(String, String)
  id = store.insert_repeater("https://api.test", request.to_slice, false, true, nil, 0)
  got = call_json(store, "get_repeater_context", %({"id":#{id},"include_content":true}))
  h = {} of String => String
  got["sessions"][0]["env_headers"]?.try(&.as_a.each { |e| h[e["name"].as_s] = e["shape"].as_s })
  h
end

describe "MCP repeater env_headers" do
  it "keeps an env reference and its scheme readable" do
    with_store do |store|
      shapes_for(store, "GET /a HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer $AUTH\r\n\r\n")
        .should eq({"Authorization" => "Bearer $AUTH"})
    end
  end

  it "collapses a literal credential to the scheme alone" do
    with_store do |store|
      shapes_for(store, "GET /a HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer eyJhbGciOi.J9.sig\r\n\r\n")
        .should eq({"Authorization" => "Bearer …"})
    end
  end

  it "collapses a bare token that carries no scheme at all" do
    with_store do |store|
      shapes_for(store, "GET /a HTTP/1.1\r\nHost: h\r\nX-Api-Key: abcdef0123456789\r\n\r\n")
        .should eq({"X-Api-Key" => "…"})
    end
  end

  it "keeps cookie NAMES and only the values that are references" do
    with_store do |store|
      shapes_for(store, "GET /a HTTP/1.1\r\nHost: h\r\nCookie: _test=$TEST; sid=abc123; csrf=$CSRF\r\n\r\n")
        .should eq({"Cookie" => "_test=$TEST; sid=…; csrf=$CSRF"})
    end
  end

  it "does not treat the $$ escape as a reference" do
    with_store do |store|
      shapes_for(store, "GET /a HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer $$NOTAREF\r\n\r\n")
        .should eq({"Authorization" => "Bearer …"})
    end
  end

  it "names a LIVE value that matches a registered env var, rather than printing it" do
    with_store do |store|
      call_json(store, "set_env_var", %({"key":"AUTH","value":"s3cr3t-token-value"}))
      shapes_for(store, "GET /a HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer s3cr3t-token-value\r\n\r\n")
        .should eq({"Authorization" => "Bearer $AUTH"})
    end
  end

  it "reports nothing for a request with no credential header" do
    with_store do |store|
      shapes_for(store, "GET /a HTTP/1.1\r\nHost: h\r\nAccept: */*\r\n\r\n").should be_empty
    end
  end

  it "never emits env_headers without include_content" do
    with_store do |store|
      id = store.insert_repeater("https://api.test",
        "GET /a HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer $AUTH\r\n\r\n".to_slice, false, true, nil, 0)
      call_json(store, "get_repeater_context", %({"id":#{id}}))["sessions"][0]["env_headers"]?.should be_nil
    end
  end

  it "leaves the redacted request head itself unchanged" do
    with_store do |store|
      id = store.insert_repeater("https://api.test",
        "GET /a HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer $AUTH\r\n\r\n".to_slice, false, true, nil, 0)
      got = call_json(store, "get_repeater_context", %({"id":#{id},"include_content":true}))
      got["sessions"][0]["request"].as_s.should contain("[REDACTED]")
      got["sessions"][0]["request"].as_s.should_not contain("$AUTH")
    end
  end
end

describe "MCP list_env value shape" do
  it "reports length and the scheme a value already carries, never the value" do
    with_store do |store|
      call_json(store, "set_env_var", %({"key":"AUTH","value":"Bearer eyJhbGciOiJ9"}))
      call_json(store, "set_env_var", %({"key":"RAW","value":"eyJhbGciOiJ9"}))
      rows = call_json(store, "list_env", "{}").as_a
      auth = rows.find! { |r| r["key"].as_s == "AUTH" }
      raw = rows.find! { |r| r["key"].as_s == "RAW" }
      auth["value"].as_s.should eq("[REDACTED]")
      auth["scheme"].as_s.should eq("Bearer")
      auth["length"].as_i.should eq(19)
      raw["scheme"]?.should be_nil
      raw["length"].as_i.should eq(12)
      rows.to_json.should_not contain("eyJhbGciOiJ9")
    end
  end
end

describe "MCP repeater last_response_body" do
  it "is absent unless asked for, so a listing never pulls body BLOBs by default" do
    with_store do |store|
      id = seeded_500(store)
      got = call_json(store, "get_repeater_context", %({"id":#{id},"include_content":true}))
      got["sessions"][0]["last_response_head"].as_s.should contain("500")
      got["sessions"][0]["last_response_body"]?.should be_nil
    end
  end

  it "inlines the stored body when include_response_body is set" do
    with_store do |store|
      id = seeded_500(store)
      s = call_json(store, "get_repeater_context",
        %({"id":#{id},"include_response_body":true}))["sessions"][0]
      s["last_response_body"].as_s.should eq(%({"error":"boom"}))
      s["last_response_body_representation"].as_s.should eq("raw")
    end
  end

  it "caps the body and names the cursor that serves the rest" do
    with_store do |store|
      id = store.insert_repeater("https://api.test", "GET /a HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 0)
      store.update_repeater_response(id, "HTTP/1.1 200 OK\r\n\r\n".to_slice, ("x" * 5000).to_slice, nil, 1_i64)
      s = call_json(store, "get_repeater_context",
        %({"id":#{id},"include_response_body":true,"max_body_bytes":100}))["sessions"][0]
      s["last_response_body"].as_s.size.should eq(100)
      s["last_response_body_truncated"].as_bool.should be_true
      s["last_response_body_total_bytes"].as_i.should eq(5000)
      s["last_response_body_read_more"].as_s.should contain("get_response_body_chunk")
    end
  end

  it "distinguishes a session with no stored body from one that was omitted" do
    with_store do |store|
      id = store.insert_repeater("https://api.test", "GET /a HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 0)
      call_json(store, "get_repeater_context",
        %({"id":#{id},"include_response_body":true}))["sessions"][0]["last_response_body_absent"].as_bool.should be_true
    end
  end

  it "hydrates a bounded head of a wide page and NAMES what it skipped" do
    with_store do |store|
      12.times do |i|
        rid = store.insert_repeater("https://api.test/#{i}", "GET /#{i} HTTP/1.1\r\n\r\n".to_slice,
          false, true, nil, i)
        store.update_repeater_response(rid, "HTTP/1.1 200 OK\r\n\r\n".to_slice, "body".to_slice, nil, 1_i64)
      end
      got = call_json(store, "get_repeater_context", %({"include_response_body":true}))
      got["sessions"].as_a.count { |s| s["last_response_body"]? }.should eq(10)
      got["response_bodies_omitted"].as_i.should eq(2)
      got["response_bodies_omitted_note"].as_s.should contain("narrow")
    end
  end
end
