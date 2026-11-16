require "../spec_helper"
require "../support/mcp_harness"

describe "list_history field projection" do
  it "keeps provenance, errors and redacted columns while dropping unrequested metadata" do
    with_store do |store|
      id = mcp_seed_flow(store, "a.test", "GET", "/secret", 200,
        "HTTP/1.1 200 OK\r\nSet-Cookie: sid=secret; HttpOnly\r\n\r\n")
      tools = tools_for(store)
      full = mcp_ok_json(tools, "list_history", %({"columns":["header:set-cookie"]}))["flows"][0]
      full["url"].as_s.should eq("https://a.test/secret")
      full.as_h.has_key?("host").should be_true
      full.as_h.has_key?("duration_us").should be_true
      nullable = mcp_ok_json(tools, "list_history", %({"fields":null,"columns":["header:set-cookie"]}))["flows"][0]
      nullable.should eq(full)
      row = mcp_ok_json(tools, "list_history", %({"fields":[],"columns":["header:set-cookie"]}))["flows"][0]
      row["id"].as_i64.should eq(id)
      row.as_h.has_key?("url").should be_false
      row.as_h.has_key?("created_at").should be_false
      Gori::MCP::Tools::HISTORY_CONTEXT_FIELDS.each { |key| row[key]?.should eq(full[key]?) }
      row["columns"].to_json.should_not contain("secret")
      (full.as_h.keys - Gori::MCP::Tools::HISTORY_FIELDS).should be_empty
      selected = mcp_ok_json(tools, "list_history", %({"fields":["url","status"]}))["flows"][0]
      selected["url"].as_s.should eq("https://a.test/secret")
      selected["status"].as_i.should eq(200)
      selected.as_h.has_key?("host").should be_false
    end
  end

  it "budgets projected rows and keeps requested ids, missing ids and row order" do
    with_store do |store|
      ids = Array.new(3) { |i| mcp_seed_flow(store, "a.test", "GET", "/#{i}" + "x" * 20_000, 200) }
      filter = Gori::MCP::ToolFilter.parse("@analysis", Gori::MCP::Tools::TOOL_NAMES,
        Gori::MCP::Tools::TOOL_DEPENDENCIES).as(Gori::MCP::ToolFilter)
      tools = Gori::MCP::Tools.new(store, true, false, tool_filter: filter)
      full = mcp_ok_json(tools, "list_history", %({"ids":#{ids.to_json}}))
      full["has_more"].as_bool.should be_true
      requested = ids.reverse + [999_i64]
      projected = mcp_ok_json(tools, "list_history", %({"ids":#{requested.to_json},"fields":[]}))
      projected["flows"].as_a.map(&.["id"].as_i64).should eq(ids.reverse)
      projected["missing_ids"].as_a.map(&.as_i64).should eq([999_i64])
      projected["has_more"].as_bool.should be_false
      projected["missing_ids_note"].as_s.should_not contain("get_current_context")
      projected.as_h.has_key?("remaining_ids").should be_false
    end
  end

  it "preserves forward cursors and errors independently of selected fields" do
    with_store do |store|
      ids = Array.new(3) { |i| mcp_seed_flow(store, "a.test", "GET", "/#{i}", 200) }
      store.update_response(Gori::Store::CapturedResponse.new(flow_id: ids[1], status: 0,
        head: Bytes.empty, state: Gori::Store::FlowState::Error, error: "upstream failed"))
      tools = tools_for(store)
      page = mcp_ok_json(tools, "list_history", %({"since":0,"limit":2,"fields":[]}))
      page["flows"].as_a.map(&.["id"].as_i64).should eq(ids.first(2))
      page["flows"][1]["error"].as_s.should eq("upstream failed")
      page["has_more"].as_bool.should be_true
      page["next_since"].as_i64.should eq(ids[1])
      last = mcp_ok_json(tools, "list_history", %({"since":#{page["next_since"]},"limit":2,"fields":[]}))
      last["flows"][0]["id"].as_i64.should eq(ids[2])
      last["has_more"].as_bool.should be_false
    end
  end

  it "refuses unknown fields and projection with count_only" do
    with_store do |store|
      mcp_seed_flow(store, "a.test", "GET", "/", 200)
      tools = tools_for(store)
      [%({"fields":["statuz"]}), %({"count_only":true,"fields":["status"]})].each do |args|
        result = tools.call("list_history", JSON.parse(args))
        result.error_code.should eq("INVALID_ARGUMENT")
        result.text.should contain("fields")
      end
    end
  end
end
