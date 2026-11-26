require "../../spec_helper"

# update_repeater parsed `tags` AFTER the request and name writes had committed, so a tag list
# sent as a JSON array came back INVALID_ARGUMENT over a row that already held the new request
# bytes and name. The refusal must come before the first write, as create_repeater's does.
describe "MCP update_repeater tags" do
  [%(["auth","idor"]), %({"a":1}), %([null])].each do |tags_json|
    it "refuses tags=#{tags_json} without touching the row" do
      with_store do |store|
        t = tools_for(store)
        r = t.call("create_repeater", JSON.parse(%({"target":"http://127.0.0.1:1","request":"GET /orig HTTP/1.1\\r\\nHost: 127.0.0.1:1\\r\\n\\r\\n","name":"orig","tags":"keep"})))
        r.is_error.should be_false
        id = JSON.parse(r.text)["id"].as_i64
        r = t.call("update_repeater", JSON.parse(%({"id":#{id},"request":"GET /changed HTTP/1.1\\r\\nHost: 127.0.0.1:1\\r\\n\\r\\n","name":"renamed","tags":#{tags_json}})))
        r.is_error.should be_true
        r.error_code.should eq("INVALID_ARGUMENT")
        after = store.get_repeater(id).not_nil!
        String.new(after.request).should contain("/orig")
        after.name.should eq("orig")
        store.repeaters_mcp.find! { |row| row.id == id }.tags.should eq("keep")
      end
    end
  end

  it "still writes string tags with the rest of the update" do
    with_store do |store|
      t = tools_for(store)
      r = t.call("create_repeater", JSON.parse(%({"target":"http://127.0.0.1:1","request":"GET /orig HTTP/1.1\\r\\nHost: 127.0.0.1:1\\r\\n\\r\\n","tags":"keep"})))
      id = JSON.parse(r.text)["id"].as_i64
      r = t.call("update_repeater", JSON.parse(%({"id":#{id},"name":"renamed","tags":"auth idor"})))
      r.is_error.should be_false
      after = store.get_repeater(id).not_nil!
      after.name.should eq("renamed")
      store.repeaters_mcp.find! { |row| row.id == id }.tags.should eq("auth idor")
    end
  end
end
