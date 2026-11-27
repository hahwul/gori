require "../spec_helper"
require "../support/mcp_harness"

# Preferences › AI › MCP features: per-tab on/off switches over `gori mcp` toolsets
# (`Settings::MCP_FEATURES`), declared per tool as `@[Tool(feature:)]`. Turning a feature
# off hides both its reads and its writes from `tools/list` and refuses them with
# TOOL_DISABLED; Core capture, project, scope, env, shared job and operator-channel tools
# stay exposed.

# Core tools deliberately NOT behind a tab feature switch. A new tool without `feature:` fails
# the sweep below until it is either assigned to a tab feature or explicitly listed here.
private CORE_TOOLS = Set{
  # Capture / History / QL / Saved views
  "list_history", "list_events", "get_flow", "get_response_body_chunk",
  "delete_flow", "clear_history", "import_flows",
  "ql_reference", "ql_explain",
  "list_views", "create_view", "update_view", "delete_view",
  # Project / TUI context / Scope
  "project_info", "get_current_context",
  "list_projects", "switch_project", "create_project", "delete_project",
  "export_project", "import_project", "diff_projects",
  "list_scope", "add_scope_rule", "update_scope_rule", "delete_scope_rule",
  "set_scope_enabled", "set_sandbox",
  # Env / Host overrides / Session slots / Wordlists / Protocol schemas
  "list_env", "set_env_var", "delete_env_var",
  "list_host_overrides", "add_host_override", "update_host_override", "delete_host_override",
  "list_session_slots", "create_session_slot", "update_session_slot",
  "delete_session_slot", "set_active_session_slot", "refresh_session_slot",
  "list_wordlists", "get_wordlist", "save_wordlist", "rename_wordlist", "delete_wordlist",
  "graphql_schema", "grpc_reflect", "grpc_schema", "grpc_forget",
  # Shared async job controls, cross-entity links and operator channel
  "list_jobs", "get_job", "stop_job",
  "list_links", "add_link", "remove_link",
  "operator_messages", "reply_to_operator", "ask_operator",
}

private def feature_tools(store, *keys : String, allow_actions : Bool = true,
                          denied : Set(String)? = nil,
                          filter : Gori::MCP::ToolFilter? = nil) : Gori::MCP::Tools
  Gori::MCP::Tools.new(store, allow_actions: allow_actions, verify_upstream: false,
    tool_filter: filter, denied_permissions: denied, disabled_features: keys.to_set)
end

private def feature_listed(tools : Gori::MCP::Tools) : Set(String)
  JSON.parse(JSON.build { |j| tools.list(j) }).as_a.map(&.["name"].as_s).to_set
end

private def feature_instructions(store, disabled : Set(String), allow_actions : Bool = true) : {String, Set(String)}
  input = IO::Memory.new(
    %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}) + "\n" +
    %({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}) + "\n")
  output = IO::Memory.new
  Gori::MCP::Server.new(store, allow_actions: allow_actions, verify_upstream: false,
    disabled_features: disabled, input: input, output: output).run
  lines = output.to_s.each_line.reject(&.strip.empty?).map { |l| JSON.parse(l) }.to_a
  text = lines.find { |l| l["id"]? == 1 }.not_nil!["result"]["instructions"].as_s
  names = lines.find { |l| l["id"]? == 2 }.not_nil!["result"]["tools"].as_a.map(&.["name"].as_s).to_set
  {text, names}
end

describe "MCP tool features" do
  it "keeps the Settings key literal the registry macro reads in step with the features" do
    Gori::Settings::MCP_FEATURES.map(&.key).should eq(Gori::Settings::MCP_FEATURE_KEYS)
  end

  it "classifies every tool as either a tab feature or an explicit Core tool" do
    Gori::MCP::Tools::TOOL_NAMES.each do |name|
      in_feature = Gori::MCP::Tools::TOOL_FEATURES.has_key?(name)
      in_core = CORE_TOOLS.includes?(name)
      (in_feature ^ in_core).should be_true,
        in_feature ? "#{name} is in both TOOL_FEATURES and CORE_TOOLS" : "#{name} has no @[Tool] feature: and is not listed in CORE_TOOLS"
    end
    CORE_TOOLS.each do |name|
      Gori::MCP::Tools::TOOL_NAMES.includes?(name).should be_true, "CORE_TOOLS lists unknown tool #{name}"
    end
    Gori::Settings::MCP_FEATURE_KEYS.each do |key|
      Gori::MCP::Tools::TOOL_FEATURES.values.includes?(key).should be_true, "MCP feature #{key} has no tools"
    end
  end

  # A turned-off feature must not leave a served tool whose workflow depends on one of its
  # tools. `get_current_context` is the one Core hub that points at whatever tab the TUI is
  # viewing and adapts its `selection_next_call` to `serves?`.
  it "never splits a declared workflow across two features" do
    Gori::MCP::Tools::TOOL_DEPENDENCIES.each do |name, deps|
      next if name == "get_current_context"
      mine = Gori::MCP::Tools::TOOL_FEATURES[name]?
      deps.each do |dep|
        theirs = Gori::MCP::Tools::TOOL_FEATURES[dep]?
        (theirs.nil? || theirs == mine).should be_true,
          "#{name} (#{mine || "core"}) requires #{dep} (#{theirs})"
      end
    end
  end

  it "hides disabled features from tools/list and keeps Core and enabled features" do
    with_store do |store|
      names = feature_listed(feature_tools(store, "issues", "jwt"))
      %w[list_issues get_issue create_issue update_issue delete_issue run_retest
        jwt_decode jwt_encode jwt_attacks jwt_verify jwt_crack].each do |hidden|
        names.should_not contain(hidden)
      end
      names.should contain("list_history")
      names.should contain("decode")
      names.should contain("cookie_decode")
      names.should contain("list_notes")
      names.size.should eq(Gori::MCP::Tools.served_names(nil, true, nil, Set{"issues", "jwt"}).size)
    end
  end

  it "refuses calls to disabled feature tools with TOOL_DISABLED and runs nothing" do
    with_store do |store|
      tools = feature_tools(store, "issues", "jwt")
      jwt_res = tools.call("jwt_decode", JSON.parse(%({"token":"a.b.c"})))
      jwt_res.is_error.should be_true
      jwt_res.error_code.should eq("TOOL_DISABLED")
      jwt_res.text.should contain("JWT")
      jwt_res.text.should contain("MCP features")

      issue_res = tools.call("create_issue", JSON.parse(%({"title":"xss","severity":"high"})))
      issue_res.is_error.should be_true
      issue_res.error_code.should eq("TOOL_DISABLED")
      issue_res.text.should contain("Issues")
      store.issues.should be_empty
    end
  end

  it "composes with --read-only, --tools and MCP permissions" do
    with_store do |store|
      filter = Gori::MCP::ToolFilter.parse("@recon", Gori::MCP::Tools::TOOL_NAMES,
        Gori::MCP::Tools::TOOL_DEPENDENCIES).as(Gori::MCP::ToolFilter)
      tools = feature_tools(store, "jwt", allow_actions: false, denied: Set{"write"}, filter: filter)
      tools.serves?("jwt_decode").should be_false
      tools.advertises?("jwt_decode").should be_false
      tools.serves?("decode").should be_true
      tools.serves?("create_note").should be_false
      tools.serves?("list_notes").should be_true
    end
  end

  it "keeps its own copy of disabled_features" do
    with_store do |store|
      disabled = Set{"jwt"}
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false,
        disabled_features: disabled)
      disabled.add("notes")
      tools.serves?("jwt_decode").should be_false
      tools.serves?("list_notes").should be_true
    end
  end

  it "does not promise get_issue or list_sitemap in get_current_context when their features are off" do
    with_store do |store|
      store.set_setting(Gori::Store::UI_STATE_KEY, {
        active_tab: "issues",
        selection:  {kind: "issue", ids: [1]},
      }.to_json)
      issue_ctx = JSON.parse(feature_tools(store, "issues").call("get_current_context", JSON.parse("{}")).text)
      issue_ctx["selection_next_call"].as_s.should contain("not exposed")

      store.set_setting(Gori::Store::UI_STATE_KEY, {
        active_tab: "target",
        selection:  {kind: "sitemap_node", nodes: [{host: "ex.test", path: "/"}]},
      }.to_json)
      sitemap_ctx = JSON.parse(feature_tools(store, "target").call("get_current_context", JSON.parse("{}")).text)
      sitemap_ctx["selection_next_call"].as_s.should contain("list_sitemap is not exposed")
    end
  end

  it "reports turned-off features in instructions and leaks none of their tool names" do
    with_store do |store|
      text, names = feature_instructions(store, Set{"issues", "jwt", "decoder", "repeater", "authorize"})
      text.should contain("turned off Repeater, Decoder, JWT, Authorize, Issues")
      text.should contain("AI › MCP features")
      %w[send_request send_websocket create_issue update_issue decode jwt_decode cache_deception_check].each do |tool_name|
        names.should_not contain(tool_name)
        text.should_not match(/\b#{Regex.escape(tool_name)}\b/)
      end
      default_text, _ = feature_instructions(store, Set(String).new)
      default_text.should_not contain("AI › MCP features")
    end
  end

  it "keeps catalogue_json in lockstep with a bound server when features are disabled" do
    with_store_env do |store|
      disabled = Set{"fuzzer", "miner", "jwt", "issues"}
      bound = feature_tools(store, "fuzzer", "miner", "jwt", "issues")
      sent = JSON.build { |j| bound.list(j) }
      Gori::MCP::Tools.catalogue_json(nil, true, nil, disabled).should eq(sent)
    end
  end

  it "records disabled_features in UsageLog and excludes them from never_called" do
    dir = File.tempname("gori-mcp-feature-usage")
    Dir.mkdir_p(dir)
    path = File.join(dir, "usage.jsonl")
    begin
      log = Gori::MCP::UsageLog.new(path)
      log.session(Gori::MCP::UsageLog::Session.new("claude", "1.0", nil, 100, false,
        [] of String, ["jwt", "issues"]))
      log.call("list_history", [] of String, 0, "ok", nil, 64, 5, true)
      summary = Gori::MCP::UsageLog::Summary.read(path)
      advertised = Gori::CLI.mcp_usage_advertised(summary)
      advertised.should_not contain("jwt_decode")
      advertised.should_not contain("list_issues")
      advertised.should contain("list_history")
      Gori::CLI.mcp_usage_text(summary, "7d", true).should contain("features off: issues, jwt")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
