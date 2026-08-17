require "../spec_helper"

# The MCP half of "resume a listener". `oast_start` mints an ad-hoc registration that dies with
# the process; these tools reach the sessions the PROJECT persists — the same rows the TUI's
# RESUME LISTENER picker shows — so an agent can pick up a payload planted yesterday.
#
# Helpers are file-local (Crystal's top-level `private def` is file-scoped).
private def with_store(&)
  path = File.tempname("gori-mcp-oast-sessions", ".db")
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

private def tools_for(store, allow_actions = true) : Gori::MCP::Tools
  Gori::MCP::Tools.new(store, allow_actions: allow_actions, verify_upstream: false)
end

private def ok_json(tools, name, args : String) : JSON::Any
  r = tools.call(name, JSON.parse(args))
  fail "tool #{name} errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

# A custom-http session: its `resume` is a documented no-op, so an agent can re-arm one with
# no network at all — which is exactly what makes it the fixture here.
private def custom_http_session(store, host = "https://oob.example/hits") : Int64
  id = store.insert_oast_session(nil, "custom-http", host, "corr-#{host.size}", "", nil, nil)
  store.flush
  id
end

describe "MCP OAST sessions" do
  it "lists the persisted sessions with their hits, and no secrets" do
    with_store do |store|
      pid = store.insert_oast_provider("lab", "interactsh", "https://oast.lab", "PROVTOKEN", true, 0)
      id = store.insert_oast_session(pid, "interactsh", "https://oast.lab", "corr20", "SECRET13",
        "-----BEGIN PRIVATE KEY-----\nPRIVKEY\n-----END PRIVATE KEY-----", "SESSTOKEN")
      store.insert_oast_callback(id, "u1", "dns", nil, "198.51.100.4", "a.oast.lab",
        "q".to_slice, nil, Time.utc.to_unix_ms * 1000)
      store.flush

      tools = tools_for(store)
      r = tools.call("list_oast_sessions", JSON.parse("{}"))
      r.is_error.should be_false
      # A session list is printed and handed to an agent; what decrypts its callbacks stays
      # in the row (same stance as list_oast_providers' [REDACTED] tokens).
      r.text.should_not contain("SECRET13")
      r.text.should_not contain("PRIVKEY")
      r.text.should_not contain("SESSTOKEN")
      r.text.should_not contain("PROVTOKEN")

      row = JSON.parse(r.text)["sessions"].as_a.first
      row["id"].as_i64.should eq(id)
      row["provider"].as_s.should eq("lab")
      row["provider_id"].as_s.should eq("p_#{pid}")
      row["payload_host"].as_s.should eq("oast.lab")
      row["hits"].as_i.should eq(1)
      row["session_id"].raw.should be_nil # not being polled by this server
    end
  end

  it "resumes a session, hands back a pollable handle, and names it in the list" do
    with_store do |store|
      id = custom_http_session(store)
      tools = tools_for(store)
      res = ok_json(tools, "oast_resume", %({"id":#{id}}))
      res["store_session_id"].as_i64.should eq(id)
      res["resumed"].as_bool.should be_true
      handle = res["session_id"].as_s
      res["payload_url"].as_s.should contain("oid=")

      # The handle is a first-class oast_* session: payloads mint off it locally.
      ok_json(tools, "oast_payload", %({"session_id":#{handle.to_json}}))["payload_url"]
        .as_s.should contain("oid=")
      # Resuming again is idempotent — one poller per correlation id, not two.
      again = ok_json(tools, "oast_resume", %({"id":#{id}}))
      again["session_id"].as_s.should eq(handle)
      again["resumed"].as_bool.should be_false

      listed = ok_json(tools, "list_oast_sessions", "{}")["sessions"].as_a.first
      listed["session_id"].as_s.should eq(handle)
      # Resuming stamps last_poll_at: the liveness signal probe payload minting keys on.
      store.get_oast_session(id).not_nil!.last_poll_at.should_not be_nil
    end
  end

  it "oast_stop KEEPS a resumed registration; oast_release drops it and keeps the callbacks" do
    with_store do |store|
      id = custom_http_session(store)
      store.insert_oast_callback(id, "u1", "http", "GET", "203.0.113.7", "oob.example",
        "GET /".to_slice, nil, Time.utc.to_unix_ms * 1000)
      store.flush
      tools = tools_for(store)
      handle = ok_json(tools, "oast_resume", %({"id":#{id}}))["session_id"].as_s

      # ^X in the TUI: stop polling, keep the session resumable. The payloads are planted out
      # in the world right now — closing a poller must not kill them.
      stopped = ok_json(tools, "oast_stop", %({"session_id":#{handle.to_json}}))
      stopped["registration"].as_s.should eq("kept")
      store.oast_sessions.map(&.id).should contain(id)
      ok_json(tools, "list_oast_sessions", "{}")["sessions"].as_a.first["session_id"].raw
        .should be_nil

      released = ok_json(tools, "oast_release", %({"id":#{id}}))
      released["released"].as_i64.should eq(id)
      # This releases the LISTENER, not the evidence.
      released["callbacks_kept"].as_i.should eq(1)
      store.oast_sessions.map(&.id).should contain(id)
      store.oast_callback_count(id).should eq(1)
    end
  end

  it "releasing a live session drops its handle too (its correlation id is dead)" do
    with_store do |store|
      id = custom_http_session(store)
      tools = tools_for(store)
      handle = ok_json(tools, "oast_resume", %({"id":#{id}}))["session_id"].as_s
      ok_json(tools, "oast_release", %({"id":#{id}}))
      tools.call("oast_poll", JSON.parse(%({"session_id":#{handle.to_json}}))).is_error.should be_true
    end
  end

  it "refuses a session that is not there, or one this build cannot bind" do
    with_store do |store|
      bogus = store.insert_oast_session(nil, "not-a-kind", "https://x.example", "c", "s", nil, nil)
      store.flush
      tools = tools_for(store)

      missing = tools.call("oast_resume", JSON.parse(%({"id":4242})))
      missing.is_error.should be_true
      missing.error_code.should eq("NOT_FOUND")

      unknown = tools.call("oast_resume", JSON.parse(%({"id":#{bogus}})))
      unknown.is_error.should be_true
      unknown.error_code.should eq("INVALID_ARGUMENT")

      no_id = tools.call("oast_release", JSON.parse("{}"))
      no_id.is_error.should be_true
      no_id.error_code.should eq("INVALID_ARGUMENT")
      no_id.field.should eq("id")
    end
  end

  it "accepts the id as the number or the '#7' the tables print" do
    with_store do |store|
      id = custom_http_session(store)
      tools = tools_for(store)
      ok_json(tools, "oast_resume", %({"id":"##{id}"}))["store_session_id"].as_i64.should eq(id)
    end
  end

  it "exposes the read tool but gates resume/release behind --read-only" do
    with_store do |store|
      tools = tools_for(store, allow_actions: false)
      names = JSON.parse(JSON.build { |j| tools.list(j) }).as_a.map(&.["name"].as_s)
      names.should contain("list_oast_sessions")
      names.should_not contain("oast_resume")
      names.should_not contain("oast_release")
      r = tools.call("oast_resume", JSON.parse(%({"id":1})))
      r.is_error.should be_true
      r.error_code.should eq("TOOL_DISABLED")
    end
  end

  it "declares both action tools in tools/list when actions are allowed" do
    with_store do |store|
      names = JSON.parse(JSON.build { |j| tools_for(store).list(j) }).as_a.map(&.["name"].as_s)
      names.should contain("oast_resume")
      names.should contain("oast_release")
    end
  end
end
