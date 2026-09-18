require "../spec_helper"
require "../support/mcp_harness"

# `list_history{ids}` — fetch an EXACT named set in one call (#1091).
#
# It exists because gori QL has no `id:` field, so the four rows an operator marked in the TUI
# could only be read back one `get_flow` at a time. The whole design question here is what a
# SHORT answer means: a set can come back short because a row is gone, because a filter
# excluded it, or because the caller paged — and the three must never be confused for one
# another, which is why none of them is a silent drop.
private def seed(store, n : Int32, host = "acme.test") : Array(Int64)
  (1..n).map do |i|
    id = store.insert_flow(Gori::Store::CapturedRequest.new(
      created_at: i.to_i64, scheme: "https", host: host, port: 443,
      method: "GET", target: "/#{i}", http_version: "HTTP/1.1",
      head: "GET /#{i} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice,
      source: Gori::FlowSource::Kind::Proxy))
    store.update_response(Gori::Store::CapturedResponse.new(
      flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
    id
  end
end

private def history(store, args : String) : JSON::Any
  call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":#{args}}})
  mcp_tool_payload(mcp_drive(store, call)[0])
end

private def history_resp(store, args : String) : JSON::Any
  call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":#{args}}})
  mcp_drive(store, call)[0]
end

describe "list_history{ids}" do
  it "returns exactly the named rows, in the order they were asked for" do
    with_store do |store|
      ids = seed(store, 4)
      # Scrambled on purpose: a caller zips the reply against the id list it holds, and
      # newest-first would silently misalign every pair.
      wanted = [ids[2], ids[0], ids[3]]
      payload = history(store, %({"ids":#{wanted.to_json}}))
      payload["order"].as_s.should eq("as_requested")
      payload["flows"].as_a.map(&.["id"].as_i64).should eq(wanted)
      payload["returned"].as_i.should eq(3)
      payload["requested_ids"].as_i.should eq(3)
      payload["has_more"].as_bool.should be_false
      payload.as_h.has_key?("next_before_id").should be_false
    end
  end

  it "NAMES an id with no row rather than dropping it, and still returns the rest" do
    with_store do |store|
      ids = seed(store, 2)
      payload = history(store, %({"ids":[#{ids[0]},9999,#{ids[1]}]}))
      payload["flows"].as_a.map(&.["id"].as_i64).should eq(ids)
      payload["missing_ids"].as_a.map(&.as_i64).should eq([9999_i64])
      # flow ids are REUSABLE rowids, so "gone" and "now somebody else" are the same symptom.
      payload["missing_ids_note"].as_s.should contain("reusable")
    end
  end

  it "keeps 'excluded by the filter' apart from 'no such row'" do
    with_store do |store|
      keep = seed(store, 1, host: "keep.test")
      drop = seed(store, 1, host: "drop.test")
      payload = history(store, %({"ids":[#{keep[0]},#{drop[0]},9999],"query":"host:keep.test"}))
      payload["flows"].as_a.map(&.["id"].as_i64).should eq(keep)
      # Two kinds of short answer, two fields. Folding them together would tell an agent a
      # flow it can still see in the TUI had been deleted.
      payload["filtered_out_ids"].as_a.map(&.as_i64).should eq(drop)
      payload["missing_ids"].as_a.map(&.as_i64).should eq([9999_i64])
    end
  end

  it "returns filtered_out_ids in the CALLER's order, like the other two lists" do
    with_store do |store|
      # `flows` is `order:"as_requested"` and `missing_ids` follows the request too, so a
      # third list in SQLite rowid order would misalign an agent zipping it against its own
      # marked list — the very workflow that ordering exists to enable.
      keep = seed(store, 1, host: "keep.test")
      a = seed(store, 1, host: "a.test")
      b = seed(store, 1, host: "b.test")
      asked = [b[0], keep[0], a[0]]
      payload = history(store, %({"ids":#{asked.to_json},"query":"host:keep.test"}))
      payload["filtered_out_ids"].as_a.map(&.as_i64).should eq([b[0], a[0]])
    end
  end

  it "refuses a cursor beside the set — the list IS the page" do
    with_store do |store|
      ids = seed(store, 2)
      %w[before_id since].each do |cursor|
        resp = history_resp(store, %({"ids":[#{ids[0]}],"#{cursor}":1}))
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.should contain("do not apply")
      end
    end
  end

  it "refuses an explicitly empty selection instead of answering the recent-flow firehose" do
    with_store do |store|
      seed(store, 3)
      resp = history_resp(store, %({"ids":[]}))
      # A caller that named an empty selection getting every recent flow back, with no error
      # on it, is a wrong answer wearing a correct one's clothes.
      resp["result"]["isError"].as_bool.should be_true
      resp["result"]["content"][0]["text"].as_s.should contain("names no flow")
    end
  end

  it "does not apply `limit` to a named set, and says it ignored it" do
    with_store do |store|
      ids = seed(store, 3)
      payload = history(store, %({"ids":#{ids.to_json},"limit":1}))
      payload["flows"].as_a.size.should eq(3)
      payload["limit_ignored"].as_bool.should be_true
    end
  end

  it "refuses more ids than one call may name" do
    with_store do |store|
      seed(store, 1)
      over = (1..(Gori::MCP::Tools::MCP_HISTORY_IDS_MAX + 1)).map(&.to_i64)
      resp = history_resp(store, %({"ids":#{over.to_json}}))
      resp["result"]["isError"].as_bool.should be_true
      resp["result"]["content"][0]["text"].as_s.should contain("cap for one call")
    end
  end

  it "takes the same three shapes `id_list_arg` reads everywhere else" do
    with_store do |store|
      ids = seed(store, 2)
      history(store, %({"ids":#{ids[0]}}))["flows"].as_a.size.should eq(1)
      history(store, %({"ids":"#{ids[0]},#{ids[1]}"}))["flows"].as_a.size.should eq(2)
      # Duplicates collapse to the first occurrence: one id named twice is one row.
      history(store, %({"ids":[#{ids[0]},#{ids[0]}]}))["flows"].as_a.size.should eq(1)
    end
  end

  it "reports a non-integer entry as a bad argument, not an internal error" do
    with_store do |store|
      seed(store, 1)
      resp = history_resp(store, %({"ids":"7,nope"}))
      resp["result"]["isError"].as_bool.should be_true
      resp["result"]["content"][0]["text"].as_s.should contain("expected an integer id")
    end
  end

  it "still carries user columns per row" do
    with_store do |store|
      ids = seed(store, 1)
      payload = history(store, %({"ids":#{ids.to_json},"columns":["header:content-type"]}))
      payload["flows"].as_a.first.as_h.has_key?("columns").should be_true
    end
  end

  it "calls in_scope-with-no-rules a filter exclusion, not a set of missing rows" do
    with_store do |store|
      ids = seed(store, 2)
      payload = history(store, %({"ids":#{ids.to_json},"in_scope":true}))
      payload["flows"].as_a.should be_empty
      payload["filtered_out_ids"].as_a.map(&.as_i64).should eq(ids)
      payload.as_h.has_key?("missing_ids").should be_false
    end
  end
end
