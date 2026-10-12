require "../spec_helper"

# Two MCP clients on one project both write `actor: mcp`, so the label is what tells their
# actions apart in Activity and `list_events` (#1587).
describe "agent event actor_label" do
  it "names the client on each agent action, and list_events carries it" do
    with_store do |store|
      claude = tools_for(store)
      claude.client_seen("claude-code", "2.1.0")
      codex = tools_for(store)
      codex.client_seen("codex", "0.9")
      claude.call("delete_note", JSON.parse("{}"))
      codex.call("delete_note", JSON.parse("{}"))
      store.flush

      rows = store.events_after(0_i64, 50).select { |e| e.kind == "agent_action" }
      rows.map(&.actor_label).should eq(["claude-code pid #{Process.pid}", "codex pid #{Process.pid}"])

      claude.call("list_events", JSON.parse("{}")).text.should contain("codex pid #{Process.pid}")
    end
  end

  it "leaves an engine's own event unlabeled" do
    with_store do |store|
      store.insert_event("probe", "alt_svc_h3", "info", "advertised HTTP/3")
      store.flush
      store.events_after(0_i64, 50).first.actor_label.should be_nil
    end
  end
end
