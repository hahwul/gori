require "../spec_helper"

# `oast_start`'s `provider` and the saved-provider tools' `kind` are ONE closed set — both
# readers run the value through `Oast::ProviderKind.parse?`. Only `provider` declared it as
# `enum`. `create_oast_provider`/`update_oast_provider` shipped `"type":"string"` with the set
# spelled in the CREATE tool's prose and nowhere at all on UPDATE ("same fields as
# create_oast_provider"), and the refusal named the rejected value without naming the legal
# ones — so a model that guessed wrong learned nothing from either half and guessed again.

private def enum_of(tools, tool_name : String, arg : String) : Array(String)?
  listing = JSON.parse(JSON.build { |j| tools.list(j) }).as_a
  t = listing.find { |x| x["name"] == tool_name }.not_nil!
  t["inputSchema"]["properties"][arg].as_h["enum"]?.try(&.as_a.map(&.as_s))
end

describe "MCP OAST provider kind" do
  it "declares the same enum on every tool that reads it" do
    with_store do |store|
      tools = tools_for(store)
      kinds = Gori::Oast::ProviderKind.values.map(&.label)
      enum_of(tools, "oast_start", "provider").should eq(kinds)
      enum_of(tools, "create_oast_provider", "kind").should eq(kinds)
      enum_of(tools, "update_oast_provider", "kind").should eq(kinds)
    end
  end

  it "names the legal set when it refuses one" do
    with_store do |store|
      tools = tools_for(store)
      r = tools.call("create_oast_provider", JSON.parse(
        %({"name":"p","kind":"zzz-not-a-kind","host":"https://x.test"})))
      r.is_error.should be_true
      Gori::Oast::ProviderKind.values.each { |k| r.text.should contain(k.label) }
    end
  end

  it "names it on update too" do
    with_store do |store|
      tools = tools_for(store)
      created = tools.call("create_oast_provider", JSON.parse(%({"name":"p","kind":"interactsh"})))
      created.is_error.should be_false
      id = JSON.parse(created.text)["id"].as_s
      r = tools.call("update_oast_provider", JSON.parse(
        %({"id":#{id.to_json},"kind":"zzz-not-a-kind"})))
      r.is_error.should be_true
      Gori::Oast::ProviderKind.values.each { |k| r.text.should contain(k.label) }
    end
  end
end
