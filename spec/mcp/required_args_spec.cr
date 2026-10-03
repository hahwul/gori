require "../spec_helper"

# `required_id` / `required_str` raise rather than return, so `Tools#call` is what turns the
# raise into the refusal a handler's own early return used to give: INVALID_ARGUMENT, the
# same sentence, the argument named in `field`, and an agent action recorded as failed.
describe "MCP required arguments" do
  it "refuses a missing or non-integer id by name and records the failed action" do
    with_store do |store|
      tools = tools_for(store)
      r = tools.call("delete_note", JSON.parse("{}"))
      r.is_error.should be_true
      r.error_code.should eq("INVALID_ARGUMENT")
      r.text.should eq("missing required 'id'")
      r.field.should eq("id")

      r = tools.call("delete_note", JSON.parse(%({"id":"oops"})))
      r.text.should eq("invalid 'id' (expected an integer)")
      r.field.should eq("id")

      store.events_after(0_i64, 50).count { |e| e.kind == "agent_action" && e.message == "delete_note failed (INVALID_ARGUMENT)" }.should eq(2)
    end
  end

  it "refuses a blank required string, keeps a hint, and passes an empty value where blank is allowed" do
    with_store do |store|
      tools = tools_for(store)
      r = tools.call("set_env_var", JSON.parse(%({"key":"  ","value":"v"})))
      r.error_code.should eq("INVALID_ARGUMENT")
      r.text.should eq("missing required 'key'")
      r.field.should eq("key")

      r = tools.call("delete_probe_rule", JSON.parse("{}"))
      r.text.should eq("missing required 'id' (see list_probe_rules)")
      r.field.should eq("id")

      tools.call("intercept_set_filter", JSON.parse("{}")).field.should eq("query")
      tools.call("intercept_set_filter", JSON.parse(%({"query":""}))).text.should_not contain("missing required")
    end
  end
end
