require "../spec_helper"
require "json"

# The MCP half of the session-slot surfaces (PR #10): the list CRUD, and `set_active_session_slot`
# — the one tool that changes what every OTHER tool's sends go out as.
#
# Driven through a real `Gori::MCP::Tools` rather than the JSON-RPC server, the same harness
# spec/mcp/wiring_spec.cr uses. Helpers are file-local (Crystal's top-level `private def` is
# file-scoped).

private alias Slot = Gori::SessionSlot

private def with_store(&)
  path = File.tempname("gori-mcpslots", ".db")
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

private def tools_for(store) : Gori::MCP::Tools
  Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
end

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
