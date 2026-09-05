require "../spec_helper"
require "../support/mcp_harness"

describe Gori::MCP::Server do
  describe "scope rule tools" do
    it "adds, lists (with enabled), and deletes a scope rule" do
      with_store do |store|
        add = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add_scope_rule","arguments":{"kind":"include","match_type":"host","pattern":"api.example.com"}}})
        id = mcp_tool_payload(mcp_drive(store, add)[0])["id"].as_i64
        id.should be > 0

        listed = mcp_tool_payload(mcp_drive(store, %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_scope"}}))[0])
        listed["rules"].as_a.size.should eq(1)
        listed["rules"][0]["pattern"].as_s.should eq("api.example.com")

        del = %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"delete_scope_rule","arguments":{"id":#{id}}}})
        deleted = mcp_tool_payload(mcp_drive(store, del)[0])
        deleted["deleted"].as_bool.should be_true
        deleted["blocks_all"].as_bool.should be_false # sandbox is off here
        store.scope_rules.should be_empty
      end
    end

    it "reports blocks_all when the delete leaves Sandbox holding an empty allowlist" do
      # set_sandbox already returns blocks_all for exactly this state, but a delete that
      # CAUSES it returned a bare {id, deleted:true} — so an agent could black-hole the
      # proxy and read the write as ordinary success. Same question, both edges.
      with_store do |store|
        add = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add_scope_rule","arguments":{"kind":"include","match_type":"host","pattern":"api.example.com"}}})
        id = mcp_tool_payload(mcp_drive(store, add)[0])["id"].as_i64
        sandbox = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"set_sandbox","arguments":{"enabled":true}}})
        mcp_tool_payload(mcp_drive(store, sandbox)[0])["blocks_all"].as_bool.should be_false # an include still stands

        del = %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"delete_scope_rule","arguments":{"id":#{id}}}})
        deleted = mcp_tool_payload(mcp_drive(store, del)[0])
        deleted["deleted"].as_bool.should be_true
        deleted["blocks_all"].as_bool.should be_true
      end
    end

    it "rejects an invalid pattern (persists nothing)" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add_scope_rule","arguments":{"match_type":"regex","pattern":"[invalid\(regex"}}})
        resp = mcp_drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        store.scope_rules.should be_empty
      end
    end

    # #414: a duplicate rule is a deterministic rejection — reporting it retryable made an agent
    # that trusts `retryable` loop forever. It must be a non-retryable INVALID_ARGUMENT.
    it "rejects a duplicate rule as a non-retryable error" do
      with_store do |store|
        add = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add_scope_rule","arguments":{"kind":"include","match_type":"host","pattern":"dup.example.com"}}})
        mcp_drive(store, add)
        dup = mcp_drive(store, add)[0]["result"]
        dup["isError"].as_bool.should be_true
        dup["structuredContent"]["error_code"].as_s.should eq("INVALID_ARGUMENT")
        dup["structuredContent"]["retryable"].as_bool.should be_false
        store.scope_rules.size.should eq(1) # not duplicated
      end
    end

    it "toggles the scope lens on/off and reflects it in list_scope" do
      with_store do |store|
        listed0 = mcp_tool_payload(mcp_drive(store, %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_scope"}}))[0])
        listed0["enabled"].as_bool.should be_false

        on = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"set_scope_enabled","arguments":{"enabled":true}}})
        mcp_tool_payload(mcp_drive(store, on)[0])["enabled"].as_bool.should be_true

        listed1 = mcp_tool_payload(mcp_drive(store, %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_scope"}}))[0])
        listed1["enabled"].as_bool.should be_true
      end
    end

    it "reports NOT_FOUND deleting an unknown scope rule id" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"delete_scope_rule","arguments":{"id":999}}})
        resp = mcp_drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["error_code"].as_s.should eq("NOT_FOUND")
      end
    end

    it "toggles the sandbox gate on/off, flags block-all, and reflects it in list_scope" do
      with_store do |store|
        listed0 = mcp_tool_payload(mcp_drive(store, %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_scope"}}))[0])
        listed0["sandbox"].as_bool.should be_false

        on = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"set_sandbox","arguments":{"enabled":true}}})
        payload = mcp_tool_payload(mcp_drive(store, on)[0])
        payload["sandbox"].as_bool.should be_true
        payload["blocks_all"].as_bool.should be_true # no include rules yet ⇒ blocks everything
        store.setting(Gori::Scope::SETTING_SANDBOX).should eq("1")

        listed1 = mcp_tool_payload(mcp_drive(store, %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_scope"}}))[0])
        listed1["sandbox"].as_bool.should be_true

        off = %({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"set_sandbox","arguments":{"enabled":false}}})
        mcp_tool_payload(mcp_drive(store, off)[0])["sandbox"].as_bool.should be_false
        store.setting(Gori::Scope::SETTING_SANDBOX).should eq("0")
      end
    end
  end

  describe "env var tools" do
    it "sets, lists (redacted by default), and deletes an env var" do
      with_store do |store|
        set = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"set_env_var","arguments":{"key":"TOKEN","value":"secret123"}}})
        mcp_tool_payload(mcp_drive(store, set)[0])["set"].as_bool.should be_true

        listed = mcp_tool_payload(mcp_drive(store, %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_env"}}))[0]).as_a
        listed.size.should eq(1)
        listed[0]["key"].as_s.should eq("TOKEN")
        listed[0]["value"].as_s.should eq("[REDACTED]")

        sensitive = mcp_tool_payload(mcp_drive(store, %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_env","arguments":{"include_sensitive":true}}}))[0]).as_a
        sensitive[0]["value"].as_s.should eq("secret123")

        del = %({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"delete_env_var","arguments":{"key":"TOKEN"}}})
        mcp_tool_payload(mcp_drive(store, del)[0])["deleted"].as_bool.should be_true
        Gori::Settings.project_env_vars.should be_empty
      ensure
        Gori::Settings.project_env_vars = [] of {String, String}
      end
    end

    it "rejects an invalid key" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"set_env_var","arguments":{"key":"bad key!","value":"x"}}})
        resp = mcp_drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
      ensure
        Gori::Settings.project_env_vars = [] of {String, String}
      end
    end

    it "reports NOT_FOUND deleting an unknown key" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"delete_env_var","arguments":{"key":"NOPE"}}})
        resp = mcp_drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["error_code"].as_s.should eq("NOT_FOUND")
      ensure
        Gori::Settings.project_env_vars = [] of {String, String}
      end
    end
  end

  describe "host override tools" do
    it "adds, lists, updates, and deletes a host override" do
      with_store do |store|
        add = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add_host_override","arguments":{"host":"api.example.com","ip":"10.0.0.1"}}})
        id = mcp_tool_payload(mcp_drive(store, add)[0])["id"].as_i64
        id.should be > 0

        listed = mcp_tool_payload(mcp_drive(store, %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_host_overrides"}}))[0]).as_a
        listed.size.should eq(1)
        listed[0]["ip"].as_s.should eq("10.0.0.1")

        upd = %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"update_host_override","arguments":{"id":#{id},"host":"api.example.com","ip":"10.0.0.2"}}})
        mcp_tool_payload(mcp_drive(store, upd)[0])["ip"].as_s.should eq("10.0.0.2")

        del = %({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"delete_host_override","arguments":{"id":#{id}}}})
        mcp_tool_payload(mcp_drive(store, del)[0])["deleted"].as_bool.should be_true
        Gori::HostOverrides.load(store).entries.should be_empty
      end
    end

    it "rejects an invalid ip literal" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add_host_override","arguments":{"host":"api.example.com","ip":"not-an-ip"}}})
        resp = mcp_drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
      end
    end

    it "reports NOT_FOUND updating an unknown id" do
      with_store do |store|
        upd = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"update_host_override","arguments":{"id":999,"host":"x.test","ip":"1.2.3.4"}}})
        resp = mcp_drive(store, upd)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["error_code"].as_s.should eq("NOT_FOUND")
      end
    end
  end
end

describe "MCP env reload (R2-3)" do
  it "reloads project env vars from the store before an active tool call" do
    with_store do |store|
      store.set_setting(Gori::Env::PROJECT_VARS_KEY,
        Gori::Env.serialize_vars([{"APIHOST", "old.test"}]))
      tools = tools_for(store)
      begin
        # initialize -> Env.load_project seeded the old value.
        Gori::Settings.project_env_vars.should eq([{"APIHOST", "old.test"}])

        # Simulate `gori run project env set APIHOST new.test` from the CLI while the
        # MCP server keeps running (writes straight to the shared DB).
        store.set_setting(Gori::Env::PROJECT_VARS_KEY,
          Gori::Env.serialize_vars([{"APIHOST", "new.test"}]))
        Gori::Settings.project_env_vars.should eq([{"APIHOST", "old.test"}]) # still stale in-process

        # Any active/outbound tool reloads first. This fuzz_start fails arg validation
        # (no template/url) and never touches the network, but the reload in `call` runs
        # BEFORE dispatch regardless — deterministic.
        tools.call("fuzz_start", JSON.parse("{}"))
        Gori::Settings.project_env_vars.should eq([{"APIHOST", "new.test"}])
      ensure
        Gori::Settings.project_env_vars = [] of {String, String}
      end
    end
  end

  it "does not reload for a read-only tool" do
    with_store do |store|
      store.set_setting(Gori::Env::PROJECT_VARS_KEY,
        Gori::Env.serialize_vars([{"APIHOST", "old.test"}]))
      tools = tools_for(store)
      begin
        store.set_setting(Gori::Env::PROJECT_VARS_KEY,
          Gori::Env.serialize_vars([{"APIHOST", "new.test"}]))
        tools.call("list_scope", JSON.parse("{}"))
        Gori::Settings.project_env_vars.should eq([{"APIHOST", "old.test"}]) # read tool: no churn
      ensure
        Gori::Settings.project_env_vars = [] of {String, String}
      end
    end
  end
end

describe "MCP update_scope_rule" do
  it "edits a rule in place, keeping its id and defaulting unspecified fields" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "old.test")
      id = Gori::Scope.load(store).rules.first.id
      tools = tools_for(store)

      res = mcp_ok_json(tools, "update_scope_rule", %({"id":#{id},"pattern":"new.test"}))
      res["id"].as_i64.should eq(id) # same rule, not delete + re-add
      res["kind"].as_s.should eq("include")
      res["match_type"].as_s.should eq("host")

      rule = Gori::Scope.load(store).rules.first
      rule.id.should eq(id)
      rule.pattern.should eq("new.test")
      rule.kind.should eq("include")
    end
  end

  it "rejects an unknown id and an invalid field" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "a.test")
      id = Gori::Scope.load(store).rules.first.id
      tools = tools_for(store)
      tools.call("update_scope_rule", JSON.parse(%({"id":9999,"pattern":"x"}))).is_error.should be_true
      tools.call("update_scope_rule", JSON.parse(%({"id":#{id},"kind":"bogus"}))).is_error.should be_true
      # An invalid regex must not land in the gate.
      tools.call("update_scope_rule", JSON.parse(%({"id":#{id},"match_type":"regex","pattern":"[bad"}))).is_error.should be_true
      Gori::Scope.load(store).rules.first.pattern.should eq("a.test")
    end
  end

  # `ConfigLog` is recorded at the MODEL so that one site covers TUI, CLI and MCP (see its
  # header). These two tools wrote straight at the store instead, so an agent could rewrite or
  # delete the include rule that gates every active send and the config feed said nothing —
  # `scope_update` was an event no headless surface emitted at all.
  it "records the VALUE of an edit and a delete in the config feed, like every other surface" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "old.test")
      id = Gori::Scope.load(store).rules.first.id
      tools = tools_for(store)

      mcp_ok_json(tools, "update_scope_rule", %({"id":#{id},"pattern":"new.test"}))
      mcp_ok_json(tools, "delete_scope_rule", %({"id":#{id}}))

      store.flush
      rows = store.events_recent(100, source: Gori::ConfigLog::SOURCE).rows.reverse
      rows.map(&.kind).should eq(["scope_add", "scope_update", "scope_remove"])
      rows[1].message.should contain("new.test")
      rows[2].message.should contain("new.test") # the rule that GOES, named before it is gone
    end
  end

  # An edit can black-hole the proxy exactly as a delete can: flip the last include to an
  # exclude and the sandbox holds an empty allowlist. `delete_scope_rule` reported that; the
  # edit changed it silently.
  it "reports blocks_all when an edit leaves the sandbox holding an empty allowlist" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")
      scope.enable_sandbox
      id = Gori::Scope.load(store).rules.first.id
      tools = tools_for(store)

      mcp_ok_json(tools, "update_scope_rule", %({"id":#{id},"kind":"exclude"}))["blocks_all"].as_bool.should be_true
      mcp_ok_json(tools, "list_scope", "{}")["blocks_all"].as_bool.should be_true
    end
  end
end

describe "MCP project env vars" do
  it "reports an out-of-band env change instead of a stale in-process copy" do
    with_store do |store|
      tools = tools_for(store)
      mcp_ok_json(tools, "list_env", "{}").as_a.should be_empty

      # Another process (`gori run project env set`) writes to the same project DB.
      store.set_setting(Gori::Env::PROJECT_VARS_KEY, %([{"key":"CLI_TOKEN","value":"abc"}]))

      listed = mcp_ok_json(tools, "list_env", %({"include_sensitive":true}))
      listed.as_a.map(&.["key"].as_s).should eq ["CLI_TOKEN"]
    end
  end

  it "does not clobber an out-of-band env var when setting another" do
    with_store do |store|
      tools = tools_for(store)
      mcp_ok_json(tools, "list_env", "{}") # bind with an empty set, as a long-lived server would

      store.set_setting(Gori::Env::PROJECT_VARS_KEY, %([{"key":"CLI_TOKEN","value":"abc"}]))
      mcp_ok_json(tools, "set_env_var", %({"key":"MCP_KEY","value":"v"}))

      # set_env_var read-modify-WRITES the whole array; on a stale copy CLI_TOKEN vanished.
      keys = mcp_ok_json(tools, "list_env", "{}").as_a.map(&.["key"].as_s)
      keys.should contain "CLI_TOKEN"
      keys.should contain "MCP_KEY"
    end
  end

  it "does not resurrect a var another process deleted when deleting one" do
    with_store do |store|
      tools = tools_for(store)
      mcp_ok_json(tools, "set_env_var", %({"key":"A","value":"1"}))
      mcp_ok_json(tools, "set_env_var", %({"key":"B","value":"2"}))

      store.set_setting(Gori::Env::PROJECT_VARS_KEY, %([{"key":"B","value":"2"}])) # CLI removed A
      mcp_ok_json(tools, "delete_env_var", %({"key":"B"}))

      mcp_ok_json(tools, "list_env", "{}").as_a.should be_empty
    end
  end
end

describe "MCP host overrides" do
  it "reports a duplicate host as a permanent error, not a retryable one" do
    with_store do |store|
      tools = tools_for(store)
      mcp_ok_json(tools, "add_host_override", %({"host":"acme.test","ip":"127.0.0.1"}))

      dup = tools.call("add_host_override", JSON.parse(%({"host":"acme.test","ip":"127.0.0.2"})))
      dup.is_error.should be_true
      # PROJECT_BUSY/retryable:true made an agent that trusts `retryable` loop forever (#414).
      dup.error_code.should eq "INVALID_ARGUMENT"
      dup.retryable.should be_false
      dup.text.should contain("already exists")
    end
  end

  it "reports a collision on update as a permanent error too" do
    with_store do |store|
      tools = tools_for(store)
      mcp_ok_json(tools, "add_host_override", %({"host":"a.test","ip":"127.0.0.1"}))
      second = mcp_ok_json(tools, "add_host_override", %({"host":"b.test","ip":"127.0.0.2"}))

      clash = tools.call("update_host_override", JSON.parse(%({"id":#{second["id"]},"host":"a.test","ip":"127.0.0.3"})))
      clash.error_code.should eq "INVALID_ARGUMENT"
      clash.retryable.should be_false
    end
  end

  it "still allows editing an entry's ip without renaming it" do
    with_store do |store|
      tools = tools_for(store)
      added = mcp_ok_json(tools, "add_host_override", %({"host":"a.test","ip":"127.0.0.1"}))
      edited = mcp_ok_json(tools, "update_host_override", %({"id":#{added["id"]},"host":"a.test","ip":"10.0.0.1"}))
      edited["ip"].as_s.should eq "10.0.0.1"
    end
  end

  # A fully-qualified argument is the spelling that separates `OverrideHost.key` from a plain
  # `downcase`, and every answer this tool gives is looked up by the key it thinks was stored.
  # Reading it the other way put BOTH answers back to the shapes their own comments say were
  # bugs: `{"id": null}` on success, and the deterministic duplicate reported as retryable.
  it "answers a fully-qualified host by the key it actually stores" do
    with_store do |store|
      tools = tools_for(store)
      added = mcp_ok_json(tools, "add_host_override", %({"host":"api.test.","ip":"10.0.0.1"}))
      added["id"].as_i64?.should_not be_nil # not the id-less "success" #414 left behind
      added["host"].as_s.should eq "api.test"

      dup = tools.call("add_host_override", JSON.parse(%({"host":"api.test.","ip":"10.0.0.2"})))
      dup.error_code.should eq "INVALID_ARGUMENT"
      dup.retryable.should be_false

      other = mcp_ok_json(tools, "add_host_override", %({"host":"b.test","ip":"127.0.0.2"}))
      clash = tools.call("update_host_override", JSON.parse(%({"id":#{other["id"]},"host":"api.test.","ip":"127.0.0.3"})))
      clash.error_code.should eq "INVALID_ARGUMENT"
      clash.retryable.should be_false

      renamed = mcp_ok_json(tools, "update_host_override", %({"id":#{other["id"]},"host":"c.test.","ip":"127.0.0.4"}))
      renamed["host"].as_s.should eq "c.test" # echoes the stored key, not the typed spelling
    end
  end
end

describe "MCP update_scope_rule" do
  it "refuses a blank pattern instead of silently keeping the old one" do
    with_store do |store|
      tools = tools_for(store)
      added = mcp_ok_json(tools, "add_scope_rule", %({"kind":"include","match_type":"host","pattern":"acme.test"}))
      r = tools.call("update_scope_rule", JSON.parse(%({"id":#{added["id"]},"pattern":"   "})))
      r.error_code.should eq "INVALID_ARGUMENT"
      r.field.should eq "pattern"
      # Unchanged, and still gating traffic.
      Gori::Scope.load(store).rules.first.pattern.should eq "acme.test"
    end
  end

  it "still keeps the current pattern when it is omitted entirely" do
    with_store do |store|
      tools = tools_for(store)
      added = mcp_ok_json(tools, "add_scope_rule", %({"kind":"include","match_type":"host","pattern":"acme.test"}))
      mcp_ok_json(tools, "update_scope_rule", %({"id":#{added["id"]},"kind":"exclude"}))["pattern"].as_s.should eq "acme.test"
    end
  end
end

# #538 — the MCP server is the third caller of Settings.load_project_network. It never opens
# a listening socket (OAST polls a remote collector), so it binds the outbound/capture
# keys and none of the bind pair.
describe "MCP per-project network overrides" do
  it "installs the project's upstream/timeouts/capture cap at bind time, and no bind address" do
    with_store do |store|
      store.set_setting(Gori::Settings::PROJECT_BIND_HOST_KEY, "0.0.0.0")
      store.set_setting(Gori::Settings::PROJECT_BIND_PORT_KEY, "9100")
      store.set_setting(Gori::Settings::PROJECT_UPSTREAM_KEY, "jump:8888")
      store.set_setting(Gori::Settings::PROJECT_UPSTREAM_DESTINATION_KEY, "*.example.com")
      store.set_setting(Gori::Settings::PROJECT_UPSTREAM_AUTH_KEY,
        Gori::Settings::ProjectProxyAuth.new("basic", "agent", "secret").to_json)
      store.set_setting(Gori::Settings::PROJECT_CONNECT_TIMEOUT_KEY, "7")
      store.set_setting(Gori::Settings::PROJECT_IO_TIMEOUT_KEY, "9")
      store.set_setting(Gori::Settings::PROJECT_CAPTURE_MAX_KEY, "16")

      tools_for(store)

      Gori::Settings.project_upstream_proxy.should eq("jump:8888")
      Gori::Settings.project_upstream_destination.should eq("*.example.com")
      Gori::Settings.project_connect_timeout_secs.should eq(7)
      Gori::Settings.project_io_timeout_secs.should eq(9)
      Gori::Settings.project_capture_max_mib.should eq(16)
      # The dial decision Upstream.dial consults — the actual defect in #538 was `send_request`
      # and `fuzz_start` reaching a pinned project's targets DIRECT.
      route = Gori::Settings.upstream_route("example.com")
      route.direct?.should be_true
      route = Gori::Settings.upstream_route("api.example.com")
      {route.kind, route.host, route.port}.should eq({"http", "jump", 8888})
      {route.username, route.password}.should eq({"agent", "secret"})
      # Nothing on this surface listens, so the bind pin must not be installed.
      Gori::Settings.project_bind_host.should be_nil
      Gori::Settings.project_bind_port.should be_nil
    ensure
      Gori::Settings.project_upstream_proxy = nil
      Gori::Settings.project_upstream_destination = nil
      Gori::Settings.project_upstream_auth = nil
      Gori::Settings.project_upstream_auth_error = nil
      Gori::Settings.project_connect_timeout_secs = nil
      Gori::Settings.project_io_timeout_secs = nil
      Gori::Settings.project_capture_max_mib = nil
    end
  end

  it "clears a previous project's pins when it binds an unpinned project" do
    with_store do |store|
      Gori::Settings.project_upstream_proxy = "stale:8888"
      Gori::Settings.project_upstream_destination = "stale.test"
      Gori::Settings.project_upstream_auth = Gori::Settings::ProjectProxyAuth.new("basic", "stale", "old")
      Gori::Settings.project_capture_max_mib = 64

      tools_for(store)

      Gori::Settings.project_upstream_proxy.should be_nil
      Gori::Settings.project_upstream_destination.should be_nil
      Gori::Settings.project_upstream_auth.should be_nil
      Gori::Settings.project_capture_max_mib.should be_nil
    ensure
      Gori::Settings.project_upstream_proxy = nil
      Gori::Settings.project_upstream_destination = nil
      Gori::Settings.project_upstream_auth = nil
      Gori::Settings.project_upstream_auth_error = nil
      Gori::Settings.project_capture_max_mib = nil
    end
  end
end
