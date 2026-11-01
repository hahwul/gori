require "../../spec_helper"
require "../../support/mcp_harness"

private def seed_note_texts(store, texts : Array(String)) : Nil
  entries = texts.map_with_index { |t, i| {id: i + 1, text: t} }
  store.set_setting("notes.docs", {cur: 0, notes: entries, next_id: texts.size + 1}.to_json)
end

describe "MCP list_notes paging" do
  it "pages by offset/limit with has_more and clips a long first line" do
    with_store do |store|
      seed_note_texts(store, ["x" * 20_000] + (2..5).map { |i| "note #{i}" })
      tools = tools_for(store, allow_actions: false)
      j = mcp_ok_json(tools, "list_notes", %({"limit":2}))
      j["notes"].as_a.map(&.["id"].as_i).should eq([1, 2])
      j["notes"][0]["title"].as_s.size.should eq(Gori::MCP::Tools::NOTE_TITLE_MAX)
      j["total"].as_i.should eq(5)
      j["has_more"].as_bool.should be_true
      j = mcp_ok_json(tools, "list_notes", %({"offset":4}))
      j["notes"].as_a.map(&.["id"].as_i).should eq([5])
      j["has_more"].as_bool.should be_false
    end
  end

  it "holds a reply to the row budget" do
    with_store do |store|
      seed_note_texts(store, (1..500).map { |i| "#{"t" * 150} #{i}\n" + "body\n" * 3 })
      j = mcp_ok_json(tools_for(store, allow_actions: false), "list_notes", %({"limit":500}))
      j["cut_by"].as_s.should eq("bytes")
      j["has_more"].as_bool.should be_true
      j["notes"].as_a.size.should be < 500
    end
  end
end

# The refusal names what a tool takes; a tool that takes nothing said "Accepted: " and stopped.
describe "MCP unknown-argument refusal" do
  it "says (none) for a tool with no arguments" do
    with_store do |store|
      r = tools_for(store, allow_actions: false).call("ql_reference", JSON.parse(%({"limit":5})))
      r.is_error.should be_true
      r.text.should contain("Accepted: (none)")
    end
  end
end
