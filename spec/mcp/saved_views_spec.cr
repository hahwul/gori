require "../spec_helper"
require "json"

# The MCP half of History views (#776): the CRUD tools, and `list_history{view}` — the one place
# a view actually changes what another tool returns.
#
# Driven through a real `Gori::MCP::Tools` rather than the JSON-RPC server, the same harness
# spec/mcp/session_slots_spec.cr uses. Helpers are file-local (Crystal's top-level `private def`
# is file-scoped).

# The global library is process-wide (Settings) and is re-read from settings.json by every
# global CRUD, so an example that writes it needs both halves restored — see
# spec/saved_views_spec.cr's `with_globals` for the full reasoning.
private def with_globals(&)
  before = Gori::Settings.saved_views
  counter = Gori::Settings.saved_views_next_id
  prev_home = ENV["GORI_HOME"]?
  dir = File.tempname("gori-mcpviews-globals")
  Dir.mkdir_p(dir)
  begin
    ENV["GORI_HOME"] = dir
    Gori::Settings.saved_views = [] of Gori::Settings::SavedView
    Gori::Settings.saved_views_next_id = 1_i64
    yield
  ensure
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    Gori::Settings.saved_views = before
    Gori::Settings.saved_views_next_id = counter
    FileUtils.rm_rf(dir)
  end
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

private def add_flow(store, source : Gori::FlowSource::Kind, host : String)
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: host, port: 443,
    method: "GET", target: "/", http_version: "HTTP/1.1",
    head: "GET / HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, source: source))
end

describe "MCP saved views" do
  it "lists the built-ins, then the global library, then this project's own" do
    with_globals do
      with_store do |store|
        t = tools_for(store)
        call_json(t, "create_view", %({"name":"everywhere","query":"src:proxy","scope":"global"}))
        call_json(t, "create_view", %({"name":"here","query":"host:acme.test"}))
        views = call_json(t, "list_views", "{}")["views"].as_a
        views.map { |v| {v["scope"].as_s, v["name"].as_s} }
          .should eq(Gori::SavedViews::BUILTINS.map { |v| {"builtin", v.name} } +
                     [{"global", "everywhere"}, {"project", "here"}])
        # `active` marks the view a list_history result was narrowed by, so a short answer can
        # be told from a filtered one; `editable` says which rows the write tools accept.
        views.find { |v| v["name"] == "History + Repeater" }.not_nil!["active"].as_bool.should be_true
        views.first["editable"].as_bool.should be_false
        views.last["editable"].as_bool.should be_true
      end
    end
  end

  it "ANDs a view over the query rather than replacing it" do
    with_globals do
      with_store do |store|
        add_flow(store, Gori::FlowSource::Kind::Proxy, "keep.test")
        add_flow(store, Gori::FlowSource::Kind::Proxy, "other.test")
        add_flow(store, Gori::FlowSource::Kind::Repeater, "keep.test")
        t = tools_for(store)

        call_json(t, "list_history", "{}").as_a.size.should eq(3)
        call_json(t, "list_history", %({"view":"History"})).as_a.size.should eq(2)
        # Both terms held.
        rows = call_json(t, "list_history", %({"view":"History","query":"host:keep.test"})).as_a
        rows.size.should eq(1)
        rows.first["host"].as_s.should eq("keep.test")
      end
    end
  end

  it "refuses an unknown view instead of silently returning everything" do
    # THE failure mode: the row query is gated on "is there a query or in_scope", so a `view`
    # that fell through would list the whole project while the call named a filter.
    with_globals do
      with_store do |store|
        add_flow(store, Gori::FlowSource::Kind::Repeater, "resent.test")
        text, err = call_raw(tools_for(store), "list_history", %({"view":"nope"}))
        err.should be_true
        text.should contain("no view named")
        text.should contain("History") # names what IS available, so the caller can act
      end
    end
  end

  it "refuses a view whose stored query would narrow nothing" do
    with_globals do
      with_store do |store|
        add_flow(store, Gori::FlowSource::Kind::Proxy, "would-leak.test")
        store.insert_saved_view("broken", "src:nope") # a hand edit / a peer's write
        text, err = call_raw(tools_for(store), "list_history", %({"view":"broken"}))
        err.should be_true
        text.should contain("not a usable query")
      end
    end
  end

  it "validates a view's query on the way IN, at the surface that writes it" do
    with_globals do
      with_store do |store|
        t = tools_for(store)
        text, err = call_raw(t, "create_view", %({"name":"bad","query":"bogus:x"}))
        err.should be_true
        text.should contain("unknown field")

        text, err = call_raw(t, "create_view", %({"name":"bad","query":"src:nope"}))
        err.should be_true
        text.should contain("narrow nothing")

        text, err = call_raw(t, "create_view", %({"name":"All","query":"src:proxy"}))
        err.should be_true
        text.should contain("built-in")
      end
    end
  end

  it "renames, re-queries and re-homes through one update tool" do
    with_globals do
      with_store do |store|
        t = tools_for(store)
        call_json(t, "create_view", %({"name":"mine","query":"status:>=500"}))

        o = call_json(t, "update_view", %({"name":"mine","new_name":"acme 5xx","query":"status:5xx"}))
        o["name"].as_s.should eq("acme 5xx")
        o["query"].as_s.should eq("status:5xx")
        o["scope"].as_s.should eq("project")

        moved = call_json(t, "update_view", %({"name":"acme 5xx","new_scope":"global"}))
        moved["scope"].as_s.should eq("global")
        call_json(t, "list_views", %({"scope":"project"}))["count"].as_i.should eq(0)
        call_json(t, "list_views", %({"scope":"global"}))["count"].as_i.should eq(1)
      end
    end
  end

  it "refuses a rename onto a built-in's name, which --view could never reach again" do
    with_globals do
      with_store do |store|
        t = tools_for(store)
        call_json(t, "create_view", %({"name":"mine","query":"status:5xx"}))
        text, err = call_raw(t, "update_view", %({"name":"mine","new_name":"Errors"}))
        err.should be_true
        text.should contain("built-in")
      end
    end
  end

  it "moves and renames in one write, leaving nothing behind under the old name" do
    # The move inserts into the destination; doing the rename as a follow-up EDIT would insert
    # under the old name — checked for availability under one name, written under another.
    with_globals do
      with_store do |store|
        t = tools_for(store)
        call_json(t, "create_view", %({"name":"here","query":"status:404"}))
        o = call_json(t, "update_view",
          %({"name":"here","new_name":"everywhere","query":"status:500","new_scope":"global"}))
        o["scope"].as_s.should eq("global")
        o["name"].as_s.should eq("everywhere")
        o["query"].as_s.should eq("status:500")

        listed = call_json(t, "list_views", "{}")["views"].as_a
          .reject { |v| v["scope"] == "builtin" }
        listed.map { |v| {v["scope"].as_s, v["name"].as_s, v["query"].as_s} }
          .should eq([{"global", "everywhere", "status:500"}])
      end
    end
  end

  it "refuses a move onto a name the destination already holds, under EITHER name" do
    with_globals do
      with_store do |store|
        t = tools_for(store)
        call_json(t, "create_view", %({"name":"clash","query":"status:404","scope":"global"}))
        call_json(t, "create_view", %({"name":"clash","query":"status:500"}))
        # Same name in both scopes is legal; moving one onto the other is not.
        text, err = call_raw(t, "update_view", %({"name":"clash","new_scope":"global"}))
        err.should be_true
        text.should contain("already exists")
        # Both survive, untouched.
        call_json(t, "list_views", "{}")["views"].as_a
          .count { |v| v["name"] == "clash" }.should eq(2)
      end
    end
  end

  it "says a built-in is a built-in, rather than sending the caller at a scope it cannot pass" do
    # `scope: builtin` is refused by the write tools — nothing can edit a view that ships in
    # code — so the cross-scope hint would be a dead end here.
    with_globals do
      with_store do |store|
        t = tools_for(store)
        text, err = call_raw(t, "update_view", %({"name":"History","new_name":"x"}))
        err.should be_true
        text.should contain("built-in")
        text, err = call_raw(t, "delete_view", %({"name":"History"}))
        err.should be_true
        text.should contain("built-in")
        text, err = call_raw(t, "create_view", %({"name":"x","query":"src:proxy","scope":"builtin"}))
        err.should be_true
        text.should contain("built-in")
        text, err = call_raw(t, "create_view", %({"name":"x","query":"src:proxy","scope":"globl"}))
        err.should be_true
        text.should contain("invalid scope")
      end
    end
  end

  it "drops this project back to All when the view it was looking through is deleted" do
    with_globals do
      with_store do |store|
        t = tools_for(store)
        call_json(t, "create_view", %({"name":"mine","query":"src:proxy"}))
        view = Gori::SavedViews.merged(store).find(&.project?).not_nil!
        Gori::SavedViews.set_active(store, view)

        call_json(t, "delete_view", %({"name":"mine"}))
        # Cleared, not left dangling: a pointer that survives could be re-pointed by a future
        # view landing on the same id, which is what the never-reused counters exist to stop.
        Gori::SavedViews.active(store).not_nil!.name.should eq("All")
      end
    end
  end

  it "is declared in tools/list and gated behind allow_actions" do
    with_globals do
      with_store do |store|
        writes = {"create_view", "update_view", "delete_view"}
        listed = JSON.parse(JSON.build { |j| tools_for(store).list(j) }).as_a.map(&.["name"].as_s)
        listed.should contain("list_views")
        writes.each { |n| listed.should contain(n) }

        ro = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
        ro_listed = JSON.parse(JSON.build { |j| ro.list(j) }).as_a.map(&.["name"].as_s)
        ro_listed.should contain("list_views")
        writes.each { |n| ro_listed.should_not contain(n) }
      end
    end
  end

  it "declares `view` on list_history, or `call` would refuse the argument outright" do
    with_globals do
      with_store do |store|
        listed = JSON.parse(JSON.build { |j| tools_for(store).list(j) }).as_a
        schema = listed.find { |t| t["name"].as_s == "list_history" }.not_nil!
        schema["inputSchema"]["properties"].as_h.keys.should contain("view")
      end
    end
  end

  it "records every view write in the agent action feed" do
    # A view write changes what a later list_history returns for every caller of this project,
    # so it belongs in the audit set beside the other in-project side effects.
    {"create_view", "update_view", "delete_view"}.each do |name|
      Gori::MCP::Tools::AGENT_ACTION_TOOLS.should contain(name)
    end
  end
end
