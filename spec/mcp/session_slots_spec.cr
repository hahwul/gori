require "../spec_helper"
require "json"

# The MCP half of the session-slot surfaces (PR #10): the list CRUD, and `set_active_session_slot`
# — the one tool that changes what every OTHER tool's sends go out as.
#
# Driven through a real `Gori::MCP::Tools` rather than the JSON-RPC server, the same harness
# spec/mcp/wiring_spec.cr uses. Helpers are file-local (Crystal's top-level `private def` is
# file-scoped).

private alias Slot = Gori::SessionSlot

private def call_raw(tools, name, args : String) : {String, Bool}
  r = tools.call(name, JSON.parse(args))
  {r.text, r.is_error}
end

private def call_json(tools, name, args : String) : JSON::Any
  text, err = call_raw(tools, name, args)
  fail "tool #{name} errored: #{text}" if err
  JSON.parse(text)
end

describe "MCP session slots" do
  it "creates, lists, updates and deletes, and persists to the project" do
    with_store do |store|
      t = tools_for(store)
      created = call_json(t, "create_session_slot",
        %({"name":"admin","set_headers":[{"name":"Cookie","value":"session=SUPERSECRET"}],"rules":["SESSION"]}))
      created["name"].as_s.should eq("admin")
      # The first slot inherits the baseline — a set judged against nothing is a run with no
      # verdict, and the engine owns that rule for all three surfaces.
      created["baseline"].as_bool.should be_true
      created["set_headers"][0]["value"].as_s.should eq("[REDACTED]")

      call_json(t, "create_session_slot", %({"name":"anonymous","remove_headers":["Cookie","Authorization"]}))
      listed = call_json(t, "list_session_slots", "{}")
      listed["active"].raw.should be_nil
      listed["slots"].as_a.map(&.["name"].as_s).should eq(["admin", "anonymous"])
      listed["slots"][1]["summary"].as_s.should contain("drops Cookie")

      # It reached the settings row the TUI and `gori run session` read.
      Gori::SessionSlots.load(store).slots.map(&.name).should eq(["admin", "anonymous"])

      call_json(t, "update_session_slot", %({"name":"anonymous","new_name":"anon","baseline":true}))
      after = Gori::SessionSlots.load(store).slots
      after.map(&.name).should eq(["admin", "anon"])
      after.select(&.baseline?).map(&.name).should eq(["anon"])
      # An update must not reorder: the list order is the order an authorize run replays in.
      after.first.name.should eq("admin")

      call_json(t, "delete_session_slot", %({"name":"anon"}))
      Gori::SessionSlots.load(store).slots.map(&.name).should eq(["admin"])
    end
  end

  it "shows header values only under include_sensitive" do
    with_store do |store|
      t = tools_for(store)
      call_json(t, "create_session_slot", %({"name":"admin","set_headers":["Cookie: session=SUPERSECRET"]}))
      plain = call_json(t, "list_session_slots", "{}")
      plain.to_json.should_not contain("SUPERSECRET")
      shown = call_json(t, "list_session_slots", %({"include_sensitive":true}))
      shown["slots"][0]["set_headers"][0]["value"].as_s.should eq("session=SUPERSECRET")
    end
  end

  it "keeps a field the caller did not send" do
    with_store do |store|
      t = tools_for(store)
      call_json(t, "create_session_slot",
        %({"name":"admin","set_headers":["Cookie: a=1"],"remove_headers":["X-Debug"],"rules":["SESSION"]}))
      # Rotate ONE cookie. An agent that never read `rules` must not blank them.
      call_json(t, "update_session_slot", %({"name":"admin","set_headers":["Cookie: a=2"]}))
      slot = Gori::SessionSlots.load(store).find("admin").not_nil!
      slot.set_headers.should eq([{"Cookie", "a=2"}])
      slot.remove_headers.should eq(["X-Debug"])
      slot.rules.should eq(["SESSION"])
      # An explicit empty array IS a clear.
      call_json(t, "update_session_slot", %({"name":"admin","rules":[]}))
      Gori::SessionSlots.load(store).find("admin").not_nil!.rules.should be_empty
    end
  end

  it "refuses a duplicate name deterministically, not as a retryable busy" do
    with_store do |store|
      t = tools_for(store)
      call_json(t, "create_session_slot", %({"name":"admin"}))
      text, err = call_raw(t, "create_session_slot", %({"name":"admin"}))
      err.should be_true
      text.should contain("already exists")
      # An agent that trusts `retryable` would loop forever on a PROJECT_BUSY here (#414).
      text.should_not contain("PROJECT_BUSY")
    end
  end

  it "refuses a set_headers entry that would forge a header boundary" do
    with_store do |store|
      t = tools_for(store)
      text, err = call_raw(t, "create_session_slot",
        %({"name":"evil","set_headers":["Cookie: a\\r\\nX-Admin: true"]}))
      err.should be_true
      text.should contain("CR or LF")
      # Refused, not partially applied.
      Gori::SessionSlots.load(store).slots.should be_empty
    end
  end

  it "reports a missing slot as NOT_FOUND rather than creating one" do
    with_store do |store|
      t = tools_for(store)
      _, err = call_raw(t, "update_session_slot", %({"name":"ghost"}))
      err.should be_true
      _, err2 = call_raw(t, "delete_session_slot", %({"name":"ghost"}))
      err2.should be_true
      Gori::SessionSlots.load(store).slots.should be_empty
    end
  end
end

describe "MCP set_active_session_slot" do
  it "selects the send context, and the overlay follows on Env.overlay_slot" do
    with_store do |store|
      previous = Gori::Env.layer
      begin
        t = tools_for(store)
        call_json(t, "create_session_slot", %({"name":"admin","set_headers":["X-Who: admin"]}))
        wire = "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
        # Nothing active: the same slice back, byte for byte.
        Gori::Env.overlay_slot(wire).to_unsafe.should eq(wire.to_unsafe)

        res = call_json(t, "set_active_session_slot", %({"name":"admin"}))
        res["active"].as_s.should eq("admin")
        res["note"].as_s.should contain("never")
        call_json(t, "list_session_slots", "{}")["active"].as_s.should eq("admin")
        # THE point of the tool: the next send's bytes change.
        String.new(Gori::Env.overlay_slot(wire)).should contain("X-Who: admin")

        # null deactivates, back to as-captured.
        call_json(t, "set_active_session_slot", %({"name":null}))["active"].raw.should be_nil
        Gori::Env.overlay_slot(wire).to_unsafe.should eq(wire.to_unsafe)
      ensure
        Gori::Env.layer = previous
      end
    end
  end

  it "refuses an unknown name instead of silently keeping the previous identity" do
    with_store do |store|
      previous = Gori::Env.layer
      begin
        t = tools_for(store)
        call_json(t, "create_session_slot", %({"name":"admin","set_headers":["X-Who: admin"]}))
        call_json(t, "set_active_session_slot", %({"name":"admin"}))
        text, err = call_raw(t, "set_active_session_slot", %({"name":"adm1n"}))
        err.should be_true
        text.should contain("admin") # names what IS there
        call_json(t, "list_session_slots", "{}")["active"].as_s.should eq("admin")
      ensure
        Gori::Env.layer = previous
      end
    end
  end

  it "deactivates when the active slot is deleted, and says so" do
    with_store do |store|
      previous = Gori::Env.layer
      begin
        t = tools_for(store)
        call_json(t, "create_session_slot", %({"name":"admin","set_headers":["X-Who: admin"]}))
        call_json(t, "set_active_session_slot", %({"name":"admin"}))
        call_json(t, "delete_session_slot", %({"name":"admin"}))["active"].raw.should be_nil
        wire = "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
        Gori::Env.overlay_slot(wire).to_unsafe.should eq(wire.to_unsafe)
      ensure
        Gori::Env.layer = previous
      end
    end
  end

  it "is declared in tools/list and gated behind allow_actions" do
    with_store do |store|
      writes = {"create_session_slot", "update_session_slot", "delete_session_slot", "set_active_session_slot"}
      listed = JSON.parse(JSON.build { |j| tools_for(store).list(j) }).as_a.map(&.["name"].as_s)
      listed.should contain("list_session_slots")
      writes.each { |n| listed.should contain(n) }

      ro = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
      ro_listed = JSON.parse(JSON.build { |j| ro.list(j) }).as_a.map(&.["name"].as_s)
      ro_listed.should contain("list_session_slots")
      writes.each { |n| ro_listed.should_not contain(n) }
    end
  end

  it "records every slot write in the agent action feed" do
    # A slot write changes what later sends carry — an overlay applied to bytes the human
    # never saw — so it belongs in the audit set beside the other in-project side effects.
    {"create_session_slot", "update_session_slot", "delete_session_slot",
     "set_active_session_slot"}.each do |name|
      Gori::MCP::Tools::AGENT_ACTION_TOOLS.should contain(name)
    end
  end
end

# `create_session_slot{flow_id}` — the MCP half of "turn a captured login into a slot". The
# reading is `Gori::SessionFromFlow` (pinned in spec/session_from_flow_spec.cr); what is pinned
# here is that this surface calls it, exposes the same refusal codes, and refuses the one
# ambiguous call shape.
private def seed_login_flow(store, resp_head : String, resp_body : String? = nil,
                            req_head : String = "POST /login HTTP/1.1\r\nHost: h.test\r\n\r\n") : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "h.test", port: 443,
    method: "POST", target: "/login", http_version: "HTTP/1.1",
    head: req_head.to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: resp_head.to_slice, body: resp_body.try(&.to_slice),
    content_type: "application/json"))
  id
end

describe "MCP create_session_slot from a captured flow" do
  it "builds the overlay from the login response and names its sources" do
    with_store do |store|
      t = tools_for(store)
      id = seed_login_flow(store,
        "HTTP/1.1 200 OK\r\nSet-Cookie: sessionid=SUPERSECRET; Path=/; HttpOnly\r\n\r\n",
        %({"access_token":"TOK"}))
      created = call_json(t, "create_session_slot", %({"name":"admin","flow_id":#{id}}))
      created["name"].as_s.should eq("admin")
      created["set_headers"].as_a.map(&.["name"].as_s).should eq(["Cookie", "Authorization"])
      # Redacted like every other reply on this surface — a slot's whole job is carrying a
      # credential and this text can flow through a hosted LLM.
      created["set_headers"][0]["value"].as_s.should eq("[REDACTED]")
      created["sources"].as_a.size.should eq(2)
      created["sources"].as_a.join(" ").should_not contain("SUPERSECRET")

      # It reached the same settings row every other surface reads, with real values.
      slot = Gori::SessionSlots.load(store).find("admin").not_nil!
      slot.set_headers.to_h["Cookie"].should eq("sessionid=SUPERSECRET")
      slot.set_headers.to_h["Authorization"].should eq("Bearer TOK")
      slot.rules.should be_empty
    end
  end

  it "refuses a flow that is not a login, deterministically and by name" do
    with_store do |store|
      t = tools_for(store)
      id = seed_login_flow(store, "HTTP/1.1 200 OK\r\n\r\n", "<html>hi</html>")
      r = t.call("create_session_slot", JSON.parse(%({"name":"admin","flow_id":#{id}})))
      r.is_error.should be_true
      r.error_code.should eq(Gori::SessionFromFlow::NO_CREDENTIAL)
      # Un-retryable: the same flow refuses the same way next time, and an agent that trusts
      # `retryable` would loop on it (the #414 shape).
      r.retryable.should be_false
      Gori::SessionSlots.load(store).slots.should be_empty
    end
  end

  it "reports an unknown flow as NOT_FOUND" do
    with_store do |store|
      r = tools_for(store).call("create_session_slot", JSON.parse(%({"name":"admin","flow_id":9999})))
      r.is_error.should be_true
      r.error_code.should eq("NOT_FOUND")
    end
  end

  # An agent that sent both had ONE of them in mind; picking either silently is how it sends a
  # credential it did not choose.
  it "refuses flow_id and set_headers together rather than merging them" do
    with_store do |store|
      t = tools_for(store)
      id = seed_login_flow(store, "HTTP/1.1 200 OK\r\nSet-Cookie: sessionid=abc\r\n\r\n")
      r = t.call("create_session_slot",
        JSON.parse(%({"name":"admin","flow_id":#{id},"set_headers":["Cookie: mine=1"]})))
      r.is_error.should be_true
      r.field.should eq("set_headers")
      Gori::SessionSlots.load(store).slots.should be_empty
    end
  end

  # The integer contract every other MCP argument follows (#724): a value the client SUPPLIED
  # but gori cannot read is refused BY NAME, never fallen back from.
  it "refuses an unreadable flow_id instead of ignoring it" do
    with_store do |store|
      r = tools_for(store).call("create_session_slot", JSON.parse(%({"name":"admin","flow_id":"latest"})))
      r.is_error.should be_true
      r.text.should contain("flow_id")
      Gori::SessionSlots.load(store).slots.should be_empty
    end
  end

  it "declares flow_id in tools/list, with the literal-overlay caveat" do
    with_store do |store|
      listed = JSON.parse(JSON.build { |j| tools_for(store).list(j) }).as_a
      tool = listed.find { |x| x["name"].as_s == "create_session_slot" }.not_nil!
      tool["inputSchema"]["properties"]["flow_id"]?.should_not be_nil
      desc = tool["description"].as_s
      desc.should contain("LITERAL")
      desc.should contain("ROTATES")
      desc.should contain("create_extract_rule")
    end
  end
end
