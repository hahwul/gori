require "../spec_helper"
require "../support/mcp_harness"

# An `update_*` call that names only its row used to get three answers: update_issue and
# update_retest_step refused, update_rule / update_extract_rule rewrote the row and said
# `updated:true`, the rest said ok. `Tools::UPDATE_SELECTORS` + `nothing_to_change` give it one.

private def schema_props(tools : Gori::MCP::Tools) : Hash(String, Array(String))
  JSON.parse(JSON.build { |j| tools.list(j) }).as_a.to_h do |t|
    {t["name"].as_s, t.dig("inputSchema", "properties").as_h.keys}
  end
end

describe "MCP update_* with nothing to change" do
  it "has a selector entry for every advertised update_* tool, naming declared arguments" do
    with_store do |store|
      props = schema_props(tools_for(store))
      updates = props.keys.select(&.starts_with?("update_"))
      updates.should_not be_empty
      updates.each do |name|
        selectors = Gori::MCP::Tools::UPDATE_SELECTORS[name]?
        fail "#{name} has no UPDATE_SELECTORS entry" unless selectors
        selectors.each { |s| props[name].should contain(s) }
      end
      (Gori::MCP::Tools::UPDATE_SELECTORS.keys - updates).should be_empty
    end
  end

  it "refuses a call that names only its row, and leaves the row alone" do
    with_store do |store|
      tools = tools_for(store)
      id = mcp_ok_json(tools, "create_rule", %({"pattern":"ORIGINAL","replacement":"x"}))["id"].as_i64
      r = tools.call("update_rule", JSON.parse(%({"id":#{id},"scope":"project"})))
      r.is_error.should be_true
      r.error_code.should eq("INVALID_ARGUMENT")
      r.text.should start_with("nothing to change — this call names only its row; the fields it takes: ")
      r.text.should contain("pattern")
      r.text.should_not contain("scope")

      # An alias of the selector is folded first, and is not offered as a field to change.
      rid = mcp_ok_json(tools, "create_repeater",
        %({"target":"https://acme.test","request":"GET / HTTP/1.1\\r\\nHost: acme.test\\r\\n\\r\\n"}))["id"].as_i64
      r = tools.call("update_repeater", JSON.parse(%({"repeater_id":#{rid}})))
      r.error_code.should eq("INVALID_ARGUMENT")
      r.text.should contain("nothing to change")
      r.text.should_not contain("repeater_id")
    end
  end

  it "lets a real change through, a null that clears included, and leaves a missing selector to the handler" do
    with_store do |store|
      tools = tools_for(store)
      id = mcp_ok_json(tools, "create_rule", %({"pattern":"ORIGINAL","replacement":"x"}))["id"].as_i64
      mcp_ok_json(tools, "update_rule", %({"id":#{id},"replacement":"y"}))
      issue = mcp_ok_json(tools, "create_issue", %({"title":"t"}))["id"].as_i64
      # `flow_id: null` clears the issue's flow link: a change, not an absent argument.
      tools.call("update_issue", JSON.parse(%({"id":#{issue},"flow_id":null}))).text.should_not contain("nothing to change")
      tools.call("update_rule", JSON.parse(%({}))).text.should_not contain("nothing to change")
    end
  end
end
