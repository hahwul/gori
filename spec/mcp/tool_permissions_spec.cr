require "../spec_helper"
require "../support/mcp_harness"

# Preferences › AI › MCP permissions: coarse switches over groups of `gori mcp` tools
# (`Settings::MCP_PERMISSIONS`), declared per tool as `@[Tool(permission:)]`. A switched-off
# group leaves `tools/list` and is refused with TOOL_DISABLED; reading is never switched.

# The writers that are deliberately NOT behind a switch, and why. A new writer without a
# `permission:` fails the sweep below until it is classified or named here.
private UNSWITCHED_WRITERS = {
  # The operator's own channel: "Tell the agent…" and its answer are gori's feature, not an
  # agent capability the operator is fencing.
  "operator_messages" => "operator channel",
  "reply_to_operator" => "operator channel",
  "ask_operator"      => "operator channel",
}

private def denied_tools(store, *keys : String) : Gori::MCP::Tools
  Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false,
    denied_permissions: keys.to_set)
end

private def listed(tools : Gori::MCP::Tools) : Set(String)
  JSON.parse(JSON.build { |j| tools.list(j) }).as_a.map(&.["name"].as_s).to_set
end

private def instructions_of(store, denied : Set(String)) : String
  input = IO::Memory.new(
    %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}) + "\n")
  output = IO::Memory.new
  Gori::MCP::Server.new(store, allow_actions: true, verify_upstream: false,
    denied_permissions: denied, input: input, output: output).run
  line = output.to_s.each_line.reject(&.strip.empty?).map { |l| JSON.parse(l) }.find { |l| l["id"]? == 1 }
  line.not_nil!["result"]["instructions"].as_s
end

describe "MCP tool permissions" do
  it "keeps the Settings key literal the registry macro reads in step with the groups" do
    Gori::Settings::MCP_PERMISSIONS.map(&.key).should eq(Gori::Settings::MCP_PERMISSION_KEYS)
  end

  it "puts every writer behind a switch, apart from the named exceptions" do
    Gori::MCP::Tools::TOOL_NAMES.each do |name|
      next if Gori::MCP::Tools::READ_ONLY_TOOLS.includes?(name)
      next if UNSWITCHED_WRITERS.has_key?(name)
      Gori::MCP::Tools::TOOL_PERMISSIONS.has_key?(name).should be_true,
        "#{name} writes or sends but has no @[Tool] permission:"
    end
    UNSWITCHED_WRITERS.each_key do |name|
      Gori::MCP::Tools::TOOL_PERMISSIONS.has_key?(name).should be_false
    end
  end

  # A switched-off group must not leave a served tool whose workflow names one of its tools:
  # `fuzz_start` without `fuzz_stop` is the broken shape `--tools` refuses at start-up.
  it "never splits a declared workflow across two groups" do
    Gori::MCP::Tools::TOOL_DEPENDENCIES.each do |name, deps|
      mine = Gori::MCP::Tools::TOOL_PERMISSIONS[name]?
      deps.each do |dep|
        theirs = Gori::MCP::Tools::TOOL_PERMISSIONS[dep]?
        (theirs.nil? || theirs == mine).should be_true,
          "#{name} (#{mine || "unswitched"}) requires #{dep} (#{theirs})"
      end
    end
  end

  it "serves the whole catalogue when nothing is switched off" do
    with_store do |store|
      listed(tools_for(store)).size.should eq(Gori::MCP::Tools::TOOL_NAMES.size)
    end
  end

  it "leaves a switched-off group out of tools/list and keeps everything else" do
    with_store do |store|
      names = listed(denied_tools(store, "send"))
      names.should_not contain("send_request")
      names.should_not contain("fuzz_start")
      names.should_not contain("fuzz_status")
      names.should_not contain("oast_poll")
      names.should contain("list_history")
      names.should contain("create_note")
      names.should contain("intercept_forward")
      names.should contain("probe_scan")
      names.size.should eq(Gori::MCP::Tools.served_names(nil, true, Set{"send"}).size)
    end
  end

  it "refuses a switched-off tool with TOOL_DISABLED and runs nothing" do
    with_store do |store|
      tools = denied_tools(store, "write")
      r = tools.call("create_note", JSON.parse(%({"title":"t","body":"b"})))
      r.is_error.should be_true
      r.error_code.should eq("TOOL_DISABLED")
      r.text.should contain("Edit project data")
      JSON.parse(tools.call("list_notes", JSON.parse("{}")).text).to_s.should_not contain(%("t"))
      store.events_after(0_i64, 50).none? { |e| e.kind == "agent_action" }.should be_true
    end
  end

  it "switches off the projects group, including the unbound binders" do
    with_store do |store|
      tools = denied_tools(store, "projects")
      tools.serves?("switch_project").should be_false
      tools.call("switch_project", JSON.parse(%({"name":"x"}))).error_code.should eq("TOOL_DISABLED")
      tools.serves?("list_projects").should be_true
    end
  end

  it "refuses only the active mode of probe_scan when Send traffic is off" do
    with_store do |store|
      tools = denied_tools(store, "send")
      active = tools.call("probe_scan", JSON.parse(%({"active":true})))
      active.error_code.should eq("TOOL_DISABLED")
      active.text.should contain("Send traffic")
      tools.call("probe_scan", JSON.parse("{}")).is_error.should be_false
    end
  end

  # A passive scan records what it finds, so it is a project write.
  it "switches probe_scan off with Edit project data" do
    with_store do |store|
      denied_tools(store, "write").call("probe_scan", JSON.parse("{}")).error_code.should eq("TOOL_DISABLED")
    end
  end

  # It reads captured JS and stores what it finds; it dials nothing. It sat under Send traffic,
  # so "Edit project data" off did not stop its writes and "Send traffic" off hid it.
  it "switches scan_js_endpoints with Edit project data, not Send traffic" do
    with_store do |store|
      denied_tools(store, "write").call("scan_js_endpoints", JSON.parse("{}")).error_code.should eq("TOOL_DISABLED")
      denied_tools(store, "send").call("scan_js_endpoints", JSON.parse("{}")).is_error.should be_false
    end
  end

  # Scope and the sandbox are the fence around what an agent may reach, so they have their own
  # switch: an operator can let an agent record issues without letting it move the fence.
  it "switches the scope and sandbox writers with Change scope & sandbox, not Edit project data" do
    with_store do |store|
      tools = denied_tools(store, "scope")
      %w[add_scope_rule update_scope_rule delete_scope_rule set_scope_enabled set_sandbox].each do |name|
        tools.serves?(name).should be_false
      end
      tools.serves?("list_scope").should be_true
      tools.serves?("create_note").should be_true
      r = tools.call("set_sandbox", JSON.parse(%({"enabled":true})))
      r.error_code.should eq("TOOL_DISABLED")
      r.text.should contain("Change scope & sandbox")
      tools.call("add_scope_rule", JSON.parse(%({"pattern":"example.com"}))).error_code.should eq("TOOL_DISABLED")
      scope = Gori::Scope.load(store)
      scope.sandbox?.should be_false
      scope.rules.should be_empty

      # Sandbox's own refusal names the operator, not two tools the agent cannot call.
      scope.enable_sandbox.should be_true
      blocked = tools.call("send_request", JSON.parse(%({"url":"http://out.test/","allow_unscoped":true})))
      blocked.error_code.should eq("SCOPE_BLOCKED")
      blocked.text.should contain("ask the operator to turn Sandbox off")
      scope.disable_sandbox.should be_true

      writes_off = denied_tools(store, "write")
      writes_off.call("add_scope_rule", JSON.parse(%({"pattern":"example.com"}))).is_error.should be_false
      writes_off.call("set_sandbox", JSON.parse(%({"enabled":true}))).is_error.should be_false
      Gori::Scope.load(store).sandbox?.should be_true
    end
  end

  # A hint naming add_scope_rule on a server that does not serve it sends the agent at a
  # TOOL_DISABLED; it names the operator instead.
  it "points the scope hints at the operator when the scope writers are switched off" do
    with_store do |store|
      id = mcp_seed_flow(store, "ex.test", "GET", "/", 200)
      notes = ->(t : Gori::MCP::Tools) {
        [
          JSON.parse(t.call("list_scope", JSON.parse("{}")).text)["active_send_gate_note"].as_s,
          JSON.parse(t.call("ql_explain", JSON.parse(%({"query":"scope:in"}))).text)["warnings"].as_a.join(" "),
          JSON.parse(t.call("list_history", JSON.parse(%({"in_scope":true,"ids":[#{id}]}))).text)["filtered_out_note"].as_s,
        ]
      }
      notes.call(tools_for(store)).each(&.should(contain("add_scope_rule")))
      notes.call(denied_tools(store, "scope")).each do |off|
        off.should_not contain("add_scope_rule")
        off.should contain("ask the operator")
      end
    end
  end

  # SCOPE_BLOCKED's own remedy is two scope writes. With them switched off, "add an include"
  # is the operator's to do, and "delete the EXCLUDE rule" is the only fix at all.
  it "names the operator in a SCOPE_BLOCKED remedy when the scope writers are switched off" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "in.test").should be_true
      scope.add("exclude", "host", "ex.in.test").should be_true
      off = denied_tools(store, "scope")

      out = off.call("send_request", JSON.parse(%({"url":"http://out.test/"})))
      out.error_code.should eq("SCOPE_BLOCKED")
      out.text.should contain("pass allow_unscoped:true, or ask the operator to add a scope include rule")
      tools_for(store).call("send_request", JSON.parse(%({"url":"http://out.test/"})))
        .text.should contain("add a scope include rule or pass allow_unscoped:true")

      excluded = off.call("send_request", JSON.parse(%({"url":"http://ex.in.test/"})))
      excluded.error_code.should eq("SCOPE_BLOCKED")
      excluded.text.should contain("ask the operator to delete or narrow the scope EXCLUDE rule")

      # minimize's refusal takes the same remedy, and reports the decision it was given
      # rather than calling every configured-scope miss "unscoped".
      id = store.insert_repeater("http://out.test/", "GET / HTTP/1.1\r\nHost: out.test\r\n\r\n".to_slice,
        false, true, nil, 1)
      mini = off.call("minimize_repeater", JSON.parse(%({"id":#{id}})))
      mini.error_code.should eq("SCOPE_BLOCKED")
      mini.text.should contain("ask the operator to add a scope include rule")
      mini.details.not_nil!["scope_decision"].as_s.should eq("out_of_scope")

      flow = mcp_seed_flow(store, "out.test", "GET", "/", 200)
      authz = off.call("authorize_start", JSON.parse(
        %({"flow_ids":[#{flow}],"identities":[{"name":"anon","set":[{"name":"X-Id","value":"1"}]}]})))
      authz.error_code.should eq("SCOPE_BLOCKED")
      authz.text.should contain("ask the operator to add a scope include rule")

      # A refusal a core engine phrases (here a session-slot refresh) reads the same
      # spelling off the Outbound the server built for it.
      rid = store.insert_repeater("http://out.test/", "GET / HTTP/1.1\r\nHost: out.test\r\n\r\n".to_slice,
        false, true, nil, 1)
      tools_for(store).call("create_session_slot", JSON.parse(%({"name":"s","refresh":[#{rid}]}))).is_error.should be_false
      refresh = JSON.parse(off.call("refresh_session_slot", JSON.parse(%({"name":"s"}))).text).to_json
      refresh.should contain("pass allow_unscoped:true, or ask the operator to add a scope include rule")

      # …and so does a retest step, which the retest engine refuses on the run's behalf.
      iid = store.insert_issue("idor", Gori::Store::Severity::High, "out.test", nil)
      tools_for(store).call("add_retest_step", JSON.parse(
        %({"issue_id":#{iid},"repeater_id":#{rid},"assertion":"status:403"}))).is_error.should be_false
      off.call("run_retest", JSON.parse(%({"issue_id":#{iid}})))
        .text.should contain("pass allow_unscoped:true, or ask the operator to add a scope include rule")
    end
  end

  it "names the operator in export_openapi's in_scope refusal when the scope writers are switched off" do
    with_store do |store|
      text = denied_tools(store, "scope").call("export_openapi", JSON.parse(%({"in_scope":true}))).text
      text.should contain("ask the operator to add a scope rule")
      tools_for(store).call("export_openapi", JSON.parse(%({"in_scope":true}))).text.should contain("add_scope_rule")
    end
  end

  # Raising the scan mode arms the capture pipeline's automatic active probes: a send by proxy.
  it "refuses raising the probe mode to an active one when Send traffic is off, not lowering it" do
    with_store do |store|
      tools = denied_tools(store, "send")
      %w[active aggressive].each do |mode|
        r = tools.call("set_probe_mode", JSON.parse(%({"mode":"#{mode}"})))
        r.error_code.should eq("TOOL_DISABLED")
        r.text.should contain("Send traffic")
      end
      store.probe_mode.probes_actively?.should be_false
      tools.call("set_probe_mode", JSON.parse(%({"mode":"off"}))).is_error.should be_false
    end
  end

  it "points an unbound server at the switch that removed its binders" do
    tools = Gori::MCP::Tools.new(nil, allow_actions: true, verify_upstream: false,
      denied_permissions: Set{"projects"})
    tools.no_binder_recovery.should contain("Manage projects")
    tools.no_binder_recovery.should_not contain("--tools")
    Gori::MCP::Tools.new(nil, allow_actions: true, verify_upstream: false)
      .no_binder_recovery.should eq(Gori::MCP::Tools::NO_BINDER_RECOVERY)
  end

  it "keeps its own copy of the denied set" do
    with_store do |store|
      denied = Set{"send"}
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false,
        denied_permissions: denied)
      denied.add("write")
      tools.serves?("create_note").should be_true
    end
  end

  it "does not promise a switched-off tool back after a restart without --read-only" do
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false,
        denied_permissions: Set{"send"})
      tools.advertises?("send_request").should be_false
      tools.advertises?("create_note").should be_true
    end
  end

  it "tells the agent which groups the operator switched off, and names none of their tools" do
    with_store do |store|
      text = instructions_of(store, Set{"send", "intercept"})
      text.should contain("switched off Send traffic, Intercept control")
      text.should_not match(/\bsend_request\b/)
      instructions_of(store, Set(String).new).should_not contain("switched off")
    end
  end
end
