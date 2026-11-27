require "../../spec_helper"

# get_repeater_context compiled `query` as an escaped regex with nothing around it, and PCRE2
# refuses a pattern past its size limit (~35k chars) with ArgumentError, which the blanket
# rescue in Tools#call coded INTERNAL. An oversized argument is the caller's to shorten.
describe "MCP get_repeater_context query" do
  it "refuses an oversized query as INVALID_ARGUMENT on field query" do
    with_store do |store|
      t = tools_for(store)
      t.call("create_repeater", JSON.parse(%({"target":"http://127.0.0.1:1","request":"GET /x HTTP/1.1\\r\\nHost: 127.0.0.1:1\\r\\n\\r\\n"}))).is_error.should be_false
      r = t.call("get_repeater_context", JSON::Any.new({"query" => JSON::Any.new("A" * 60_000)}))
      r.is_error.should be_true
      r.error_code.should eq("INVALID_ARGUMENT")
      r.text.should contain("query")
    end
  end

  it "still matches an ordinary query case-insensitively" do
    with_store do |store|
      t = tools_for(store)
      t.call("create_repeater", JSON.parse(%({"target":"http://127.0.0.1:1","request":"GET /Needle HTTP/1.1\\r\\nHost: 127.0.0.1:1\\r\\n\\r\\n"}))).is_error.should be_false
      t.call("create_repeater", JSON.parse(%({"target":"http://127.0.0.1:1","request":"GET /other HTTP/1.1\\r\\nHost: 127.0.0.1:1\\r\\n\\r\\n"}))).is_error.should be_false
      r = t.call("get_repeater_context", JSON.parse(%({"query":"needle"})))
      r.is_error.should be_false
      r.text.should contain("Needle")
      r.text.should_not contain("/other")
    end
  end
end

# get_current_context is Core and `requires:` get_repeater_context, which the MCP features
# sweep tolerates only because the hub adapts to `serves?`. Its description named the Repeater
# tool unconditionally, so with Repeater off it sent the agent to a tool tools/list lacks.
describe "MCP get_current_context description" do
  it "names get_repeater_context only while it is served" do
    with_store do |store|
      {Set(String).new, Set{"repeater"}}.each do |disabled|
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false,
          disabled_features: disabled)
        listed = JSON.parse(JSON.build { |j| tools.list(j) }).as_a
        desc = listed.find! { |t| t["name"] == "get_current_context" }["description"].as_s
        desc.should contain("marked_subtabs")
        if disabled.empty?
          desc.should contain("resolve via get_repeater_context")
        else
          listed.map(&.["name"].as_s).should_not contain("get_repeater_context")
          desc.should_not contain("get_repeater_context")
          desc.should contain("no tool on this server resolves them")
        end
      end
    end
  end
end
