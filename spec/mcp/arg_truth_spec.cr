require "../spec_helper"
require "../support/mcp_harness"

# What a write tool reports has to be what it did: a refused call changes nothing, an absent
# argument keeps what is there, and an error names the argument that is actually wrong.

private def call_raw(tools, name, args : String) : {JSON::Any?, Gori::MCP::Tools::Result}
  r = tools.call(name, JSON.parse(args))
  parsed = JSON.parse(r.text) rescue nil
  {parsed, r}
end

describe "MCP write tools: arguments and their answers" do
  it "reads a null or blank list argument on update_session_slot as absent, not as a clear" do
    with_store do |store|
      t = tools_for(store)
      mcp_ok_json(t, "create_session_slot",
        %({"name":"admin","set_headers":["Authorization: Bearer A"],"remove_headers":["X-Debug"],"rules":["TOKEN"]}))
      mcp_ok_json(t, "update_session_slot",
        %({"name":"admin","set_headers":null,"rules":null,"remove_headers":"","refresh":null,"refresh_before":""}))
      slot = Gori::SessionSlots.load(store).find("admin").not_nil!
      slot.set_headers.should eq([{"Authorization", "Bearer A"}])
      slot.remove_headers.should eq(["X-Debug"])
      slot.rules.should eq(["TOKEN"])
    end
  end

  it "refuses a bad 'enabled' on update_rule before writing anything" do
    with_store do |store|
      t = tools_for(store)
      id = mcp_ok_json(t, "create_rule", %({"pattern":"ORIGINAL","replacement":"x"}))["id"].as_i64
      _, r = call_raw(t, "update_rule", %({"id":#{id},"pattern":"CHANGED","enabled":"yes"}))
      r.is_error.should be_true
      store.match_rules.find! { |rule| rule.id == id }.pattern.should eq("ORIGINAL")
    end
  end

  it "switches a dir stub to another op without blaming a body_file nobody passed" do
    with_store do |store|
      t = tools_for(store)
      id = mcp_ok_json(t, "create_rule", %({"op":"short_circuit","pattern":"GET /static/","dir":"/srv/js"}))["id"].as_i64
      mcp_ok_json(t, "update_rule", %({"id":#{id},"op":"replace","pattern":"a","replacement":"b"}))
      rule = store.match_rules.find! { |r| r.id == id }
      rule.op.replace?.should be_true
      rule.body_file.should eq("")
    end
  end

  it "labels an extract rule's selector refusal with field 'selector'" do
    with_store do |store|
      t = tools_for(store)
      _, r = call_raw(t, "create_extract_rule", {"name" => "zz1", "kind" => "regex", "selector" => "("}.to_json)
      r.is_error.should be_true
      r.text.should contain("does not compile")
      r.field.should eq("selector")
      _, r = call_raw(t, "create_extract_rule", %({"name":"zz2","kind":"cookie"}))
      r.field.should eq("selector")
    end
  end

  it "reads a blank scope kind / match_type as the default" do
    with_store do |store|
      res = mcp_ok_json(tools_for(store), "add_scope_rule", %({"kind":"","match_type":"","pattern":"x.example"}))
      res.to_json.should contain("x.example")
      Gori::Scope.load(store).rules.find! { |r| r.pattern == "x.example" }.kind.should eq("include")
    end
  end

  it "names the STORED provider kind when an update passes none" do
    with_store do |store|
      row = store.insert_oast_provider("future", "future-kind", "https://o.test", nil, true, 0)
      _, r = call_raw(tools_for(store), "update_oast_provider", %({"id":"p_#{row}","name":"renamed"}))
      r.is_error.should be_true
      r.text.should contain("'future-kind'")
      r.text.should_not contain("kind ''")
    end
  end

  it "refuses create_repeater seeded from an issue AND a different flow" do
    with_store do |store|
      linked = mcp_seed_flow(store, "/linked")
      other = mcp_seed_flow(store, "/other")
      iid = store.insert_issue("x", Gori::Store::Severity::Low, "acme.test", linked)
      t = tools_for(store)
      _, r = call_raw(t, "create_repeater", %({"issue_id":#{iid},"flow_id":#{other}}))
      r.is_error.should be_true
      r.field.should eq("flow_id")
      mcp_ok_json(t, "create_repeater", %({"issue_id":#{iid},"flow_id":#{linked}}))["id"].as_i64.should be > 0
    end
  end

  it "seeds from the caller's flow_id when the issue has no flow of its own" do
    with_store do |store|
      fid = mcp_seed_flow(store, "/a")
      iid = store.insert_issue("x", Gori::Store::Severity::Low, nil, nil)
      rid = mcp_ok_json(tools_for(store), "create_repeater", %({"issue_id":#{iid},"flow_id":#{fid}}))["id"].as_i64
      store.link_id(Gori::Store::LinkOwnerKind::Issue, iid, Gori::Store::LinkRefKind::Repeater, rid).should_not be_nil
    end
  end
end
