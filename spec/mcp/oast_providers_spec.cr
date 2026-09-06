require "../spec_helper"
require "../support/mcp_harness"

describe "MCP saved OAST providers" do
  it "CRUDs a project provider and redacts its token by default" do
    with_store do |store|
      tools = tools_for(store)
      mcp_ok_json(tools, "list_oast_providers", "{}")["total"].as_i.should eq(0)

      created = mcp_ok_json(tools, "create_oast_provider",
        %({"name":"private","kind":"interactsh","host":"https://oast.internal","token":"SECRET"}))
      id = created["id"].as_s
      id.should start_with("p_")

      listed = mcp_ok_json(tools, "list_oast_providers", "{}")["providers"].as_a.first
      listed["name"].as_s.should eq("private")
      listed["scope"].as_s.should eq("project")
      listed["enabled"].as_bool.should be_true
      listed["token"].as_s.should eq("[REDACTED]") # a provider token is a credential

      mcp_ok_json(tools, "list_oast_providers", %({"include_sensitive":true}))["providers"]
        .as_a.first["token"].as_s.should eq("SECRET")

      mcp_ok_json(tools, "set_oast_provider_enabled", %({"id":"#{id}","enabled":false}))
      mcp_ok_json(tools, "list_oast_providers", "{}")["providers"].as_a.first["enabled"].as_bool.should be_false

      mcp_ok_json(tools, "delete_oast_provider", %({"id":"#{id}"}))["deleted"].as_i.should eq(1)
      store.oast_providers.empty?.should be_true
    end
  end

  it "keeps unmentioned fields on update — editing the name must not drop the token" do
    with_store do |store|
      tools = tools_for(store)
      id = mcp_ok_json(tools, "create_oast_provider",
        %({"name":"private","host":"https://oast.internal","token":"SECRET"}))["id"].as_s

      mcp_ok_json(tools, "update_oast_provider", %({"id":"#{id}","name":"renamed"}))
      row = store.oast_providers.first
      row.name.should eq("renamed")
      row.token.should eq("SECRET") # survived
      row.host.should eq("https://oast.internal")
      row.enabled?.should be_true
    end
  end

  it "refuses an unknown kind rather than storing one that can never fire" do
    with_store do |store|
      tools = tools_for(store)
      tools.call("create_oast_provider", JSON.parse(%({"name":"x","kind":"bogus"}))).is_error.should be_true
      store.oast_providers.empty?.should be_true
    end
  end

  it "refuses to touch a GLOBAL provider or an unknown id" do
    with_store do |store|
      tools = tools_for(store)
      tools.call("delete_oast_provider", JSON.parse(%({"id":"g_abc"}))).is_error.should be_true
      tools.call("update_oast_provider", JSON.parse(%({"id":"p_999","name":"x"}))).is_error.should be_true
      tools.call("delete_oast_provider", JSON.parse(%({"id":"nonsense"}))).is_error.should be_true
    end
  end

  it "refuses mutation under --read-only but still lists" do
    with_store do |store|
      store.insert_oast_provider("p", "interactsh", "https://x.test", "T", true, 0)
      ro = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
      ro.call("create_oast_provider", JSON.parse(%({"name":"x"}))).is_error.should be_true
      ro.call("delete_oast_provider", JSON.parse(%({"id":"p_1"}))).is_error.should be_true
      mcp_ok_json(ro, "list_oast_providers", "{}")["total"].as_i.should eq(1)
    end
  end
end
