require "../spec_helper"

# `list_notes` published `Notes::Doc#cur` — a 0-based INDEX — as a bare top-level `cur`, in a
# payload where every other number is an id and where every note tool (`get_note`,
# `update_note`, `delete_note`) is addressed BY id. On a five-note document whose fourth entry
# is open that read `{"cur":3, …}` while the open note was `id:4` — and `id:3` was a different
# note `get_note` would happily return. `Notes.merge` reached the same conclusion internally
# ("the active note arrives as `cur_id`, a STABLE ID, not as an index"); this projection was
# the last place still handing out the index. The CLI twin never had the ambiguity: `gori run
# notes --format json` names `id` and `index` on every row.

private def seed_notes(store, cur : Int32) : Nil
  entries = (1..5).map { |i| %({"id":#{i},"text":"note #{i}"}) }
  store.set_setting("notes.docs", %({"cur":#{cur},"notes":[#{entries.join(",")}],"next_id":6}))
end

private def call_json(store, name, args : String) : JSON::Any
  tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
  r = tools.call(name, JSON.parse(args))
  fail "#{name} errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

describe "MCP list_notes current note" do
  it "names the open note by the id get_note takes, not by its position" do
    with_store do |store|
      seed_notes(store, 3)
      j = call_json(store, "list_notes", "{}")
      j["current_id"].as_i64.should eq(4)
      j["notes"].as_a.find { |n| n["current"].as_bool }.not_nil!["id"].as_i64.should eq(4)
      # The number the old field published addressed a real, DIFFERENT note.
      call_json(store, "get_note", %({"id":3}))["current"].as_bool.should be_false
      j.as_h.has_key?("cur").should be_false
    end
  end

  it "answers null when no note is open" do
    with_store do |store|
      call_json(store, "list_notes", "{}")["current_id"].raw.should be_nil
    end
  end
end
