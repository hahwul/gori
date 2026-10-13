require "../spec_helper"

describe "Store#setting_is?" do
  it "answers whether the key holds exactly the value, with nil meaning no row" do
    with_store do |store|
      store.setting_is?("k", nil).should be_true
      store.setting_is?("k", "").should be_false

      store.set_setting("k", "abc")
      store.setting_is?("k", "abc").should be_true
      store.setting_is?("k", nil).should be_false
      store.setting_is?("k", "abd").should be_false
      store.setting_is?("k", "abc ").should be_false
      store.setting_is?("k", "ABC").should be_false # byte equality, not a collation

      store.set_setting("k", "")
      store.setting_is?("k", "").should be_true
      store.setting_is?("k", nil).should be_false
    end
  end

  it "compares a large value byte for byte" do
    with_store do |store|
      big = "x" * 1_000_000 + "é\r\n"
      store.set_setting("big", big)
      store.setting_is?("big", big).should be_true
      store.setting_is?("big", big.rchop).should be_false
      store.setting_is?("big", "#{big[0, big.size - 1]}\r").should be_false
    end
  end
end

describe "Store#mcp_host_grants (#1585)" do
  it "adds a grant once and reads the list back" do
    with_store do |store|
      store.mcp_host_grants.should be_empty
      store.add_mcp_host_grant("acme.test").should be_true
      store.add_mcp_host_grant("acme.test:8443").should be_true
      store.add_mcp_host_grant("acme.test").should be_true
      store.mcp_host_grants.should eq(["acme.test", "acme.test:8443"])
    end
  end

  it "drops a host's grants, bare or with any port, in the override key form" do
    with_store do |store|
      %w[acme.test ACME.test.:8443 acme.test:443 acme.testx other.test:443].each { |g| store.add_mcp_host_grant(g).should be_true }
      store.drop_mcp_host_grants("Acme.Test")
      store.mcp_host_grants.should eq(["acme.testx", "other.test:443"])
      store.drop_mcp_host_grants("none.test")
      store.mcp_host_grants.should eq(["acme.testx", "other.test:443"])
    end
  end

  it "reads a row that is not a list of strings as no grants" do
    with_store do |store|
      store.set_setting(Gori::Store::MCP_HOST_GRANTS_KEY, %({"acme.test":true})).should be_true
      store.mcp_host_grants.should be_empty
    end
  end
end
