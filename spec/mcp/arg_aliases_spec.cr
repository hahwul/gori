require "../spec_helper"
require "../support/mcp_harness"

# #1393: one object, two spellings. `get_flow` says `id` where nine tools say `flow_id`, the
# repeater tools say `id` where `send_request` says `repeater_id`, `intercept_toggle` says
# `enable` where fourteen tools say `enabled` — and an agent's first call used to spend a turn
# on INVALID_ARGUMENT. `Tools::ARG_ALIASES` is the one table: `tool` advertises each alias,
# `call` folds it into the real name before dispatch.

private def schema_of(tools : Gori::MCP::Tools, name : String) : JSON::Any
  JSON.parse(JSON.build { |j| tools.list(j) }).as_a.find { |t| t["name"].as_s == name }.not_nil!["inputSchema"]
end

describe "MCP argument aliases" do
  it "advertises every alias as a property and drops the aliased argument from required" do
    with_store do |store|
      tools = tools_for(store)
      Gori::MCP::Tools::ARG_ALIASES.each do |name, aliases|
        schema = schema_of(tools, name)
        props = schema["properties"].as_h
        required = schema["required"].as_a.map(&.as_s)
        aliases.each do |alias_name, canonical|
          props.has_key?(alias_name).should be_true, "#{name} does not advertise '#{alias_name}'"
          props[alias_name]["type"].should eq(props[canonical]["type"])
          required.should_not contain(canonical)
          required.should_not contain(alias_name)
        end
      end
    end
  end

  it "reads get_flow / delete_flow's id as flow_id" do
    with_store do |store|
      tools = tools_for(store)
      a = mcp_seed_flow(store, "/a")
      b = mcp_seed_flow(store, "/b")
      mcp_ok_json(tools, "get_flow", %({"flow_id":#{a}}))["id"].as_i64.should eq(a)
      mcp_ok_json(tools, "delete_flow", %({"flow_id":#{b}}))
      store.flow_row(b).should be_nil
      store.flow_row(a).should_not be_nil
    end
  end

  it "reads the repeater tools' id as repeater_id, and minimize_repeater's repeater_id as id" do
    with_store do |store|
      tools = tools_for(store)
      id = mcp_ok_json(tools, "create_repeater",
        %({"target":"https://acme.test","request":"GET / HTTP/1.1\\r\\nHost: acme.test\\r\\n\\r\\n"}))["id"].as_i64
      row = mcp_ok_json(tools, "get_repeater_context", %({"repeater_id":#{id}}))["sessions"].as_a.first
      row["id"].as_i64.should eq(id)
      row["db_id"].as_i64.should eq(id)
      mcp_ok_json(tools, "update_repeater", %({"repeater_id":#{id},"name":"renamed"}))
      store.get_repeater(id).not_nil!.name.should eq("renamed")
      mcp_ok_json(tools, "delete_repeater", %({"repeater_id":#{id}}))
      store.get_repeater(id).should be_nil
      # …and the other direction: `id` reaches minimize_repeater's handler as `repeater_id`.
      r = tools.call("minimize_repeater", JSON.parse(%({"id":#{id}})))
      r.error_code.should eq("NOT_FOUND")
      r.text.should contain("no repeater with id #{id}")
    end
  end

  it "accepts both spellings when they agree, and refuses them when they disagree" do
    with_store do |store|
      tools = tools_for(store)
      a = mcp_seed_flow(store, "/a")
      b = mcp_seed_flow(store, "/b")
      mcp_ok_json(tools, "get_flow", %({"id":#{a},"flow_id":#{a}}))["id"].as_i64.should eq(a)
      r = tools.call("get_flow", JSON.parse(%({"id":#{a},"flow_id":#{b}})))
      r.is_error.should be_true
      r.error_code.should eq("INVALID_ARGUMENT")
      r.field.should eq("flow_id")
      # A JSON null is absent, as everywhere else: it neither conflicts nor stands in — and so is
      # an empty value a client filled in for every property it was shown.
      mcp_ok_json(tools, "get_flow", %({"id":#{a},"flow_id":null}))["id"].as_i64.should eq(a)
      mcp_ok_json(tools, "get_flow", %({"id":#{a},"flow_id":""}))["id"].as_i64.should eq(a)
    end
  end

  it "still requires the argument, naming both spellings, when neither is given" do
    with_store do |store|
      r = tools_for(store).call("get_flow", JSON.parse("{}"))
      r.is_error.should be_true
      r.field.should eq("id")
      r.text.should contain("'id'")
      r.text.should contain("'flow_id'")
    end
  end

  it "keeps an optional aliased argument optional" do
    with_store do |store|
      # get_repeater_context's `id` narrows to one session; with neither spelling it lists all.
      tools_for(store).call("get_repeater_context", JSON.parse("{}")).is_error.should be_false
    end
  end
end
