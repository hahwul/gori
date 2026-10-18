require "../spec_helper"
require "../support/mcp_harness"

# #1649: list replies are held to `Tools::REPLY_ROWS_BUDGET` serialized bytes, because a row
# COUNT does not bound a reply and the advertised `limit` maximums produced replies a client
# refused to hand the model. Every cursor shape must still reach every row exactly once.

private BUDGET = Gori::MCP::Tools::REPLY_ROWS_BUDGET

private def call(store, tool : String, args : String) : JSON::Any
  line = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"#{tool}","arguments":#{args}}})
  mcp_tool_payload(mcp_drive(store, line)[0])
end

# A path long enough that a few hundred rows overflow the budget.
private def long_path(i : Int32) : String
  "/api/v1/items/#{i}/#{"x" * 900}"
end

describe "MCP reply budget" do
  it "cuts a list_history page by bytes and pages every flow exactly once by its cursor" do
    with_store do |store|
      ids = (0...300).map { |i| mcp_seed_flow(store, "a.test", "GET", long_path(i), 200) }
      seen = [] of Int64
      cursor = nil
      first = true
      loop do
        args = cursor ? %({"limit":500,"before_id":#{cursor}}) : %({"limit":500})
        page = call(store, "list_history", args)
        if first
          page["cut_by"].as_s.should eq("bytes")
          page["has_more"].as_bool.should be_true
          page.to_json.bytesize.should be < BUDGET + 4096
          first = false
        end
        seen.concat(page["flows"].as_a.map(&.["id"].as_i64))
        break unless page["has_more"].as_bool
        cursor = page["next_before_id"].as_i64
      end
      seen.sort.should eq(ids.sort)
      seen.uniq.size.should eq(ids.size)
    end
  end

  it "returns what does not fit of an ids set as remaining_ids, in the order asked" do
    with_store do |store|
      ids = (0...200).map { |i| mcp_seed_flow(store, "a.test", "GET", long_path(i), 200) }.reverse!
      page = call(store, "list_history", %({"ids":#{ids.to_json}}))
      page["cut_by"].as_s.should eq("bytes")
      got = page["flows"].as_a.map(&.["id"].as_i64)
      rest = page["remaining_ids"].as_a.map(&.as_i64)
      (got + rest).should eq(ids)
      page2 = call(store, "list_history", %({"ids":#{rest.to_json}}))
      page2["flows"].as_a.size.should be > 0
    end
  end

  it "cuts list_sitemap in raw rows, so offset += scanned reaches every endpoint once" do
    with_store do |store|
      120.times { |i| mcp_seed_flow(store, "a.test", "GET", long_path(i), 200) }
      targets = [] of String
      offset = 0
      cut_seen = false
      loop do
        page = call(store, "list_sitemap", %({"limit":5000,"offset":#{offset},"fold_query":false}))
        cut_seen ||= page["cut_by"]? == "bytes"
        targets.concat(page["entries"].as_a.map(&.["target"].as_s))
        break unless page["has_more"].as_bool
        offset += page["scanned"].as_i
      end
      cut_seen.should be_true
      targets.size.should eq(120)
      targets.uniq.size.should eq(120)
    end
  end

  it "cuts an offset-paged tool and keeps total/has_more honest" do
    with_store do |store|
      80.times { |i| store.insert_issue("issue #{i} #{"y" * 1500}", Gori::Store::Severity::Low, "a.test", nil) }
      seen = 0
      offset = 0
      page = call(store, "list_issues", %({"limit":500}))
      page["cut_by"].as_s.should eq("bytes")
      page["total"].as_i.should eq(80)
      loop do
        page = call(store, "list_issues", %({"limit":500,"offset":#{offset}}))
        n = page["returned"].as_i
        seen += n
        break unless page["has_more"].as_bool
        offset += n
      end
      seen.should eq(80)
    end
  end

  it "always carries one row, even one larger than the whole budget" do
    with_store do |store|
      mcp_seed_flow(store, "a.test", "GET", "/#{"z" * (BUDGET + 1000)}", 200)
      mcp_seed_flow(store, "a.test", "GET", "/#{"z" * (BUDGET + 1000)}", 200)
      page = call(store, "list_history", %({"limit":50}))
      page["returned"].as_i.should eq(1)
      page["has_more"].as_bool.should be_true
    end
  end

  it "cuts list_events and resumes after the last event it carried, filtered or not" do
    with_store do |store|
      ids = (0...200).map { |i| store.insert_event("probe", i.even? ? "a" : "b", :info, "event #{i} #{"m" * 1200}") }
      want = ids.each_slice(2).map(&.first).to_a
      seen = [] of Int64
      cursor = 0_i64
      cut_seen = false
      loop do
        page = call(store, "list_events", %({"since":#{cursor},"limit":500,"kind":"a"}))
        cut_seen ||= page["cut_by"]? == "bytes"
        got = page["events"].as_a.map(&.["id"].as_i64)
        seen.concat(got)
        nxt = page["next_cursor"].as_i64
        break if nxt == cursor
        cursor = nxt
      end
      cut_seen.should be_true
      seen.should eq(want)
    end
  end

  it "sends text that JSON-escapes past the budget as budgeted base64" do
    with_store do |store|
      id = mcp_seed_flow(store, "a.test", "GET", "/nul", 200, resp_body: Bytes.new(60_000, 0_u8))
      page = call(store, "get_response_body_chunk", %({"flow_id":#{id},"raw":true}))
      page["encoding"].as_s.should eq("base64")
      page["returned_bytes"].as_i.should eq(Gori::MCP::Tools::BASE64_CHUNK_MAX)
    end
  end

  it "holds a binary body chunk to the budget once base64-encoded" do
    with_store do |store|
      body = Bytes.new(100_000) { |i| (i % 256).to_u8 }
      id = mcp_seed_flow(store, "a.test", "GET", "/bin", 200, resp_body: body)
      page = call(store, "get_response_body_chunk", %({"flow_id":#{id},"raw":true}))
      page["encoding"].as_s.should eq("base64")
      page["returned_bytes"].as_i.should eq(Gori::MCP::Tools::BASE64_CHUNK_MAX)
      page["cut_by"].as_s.should eq("bytes")
      page["next_offset"].as_i.should eq(Gori::MCP::Tools::BASE64_CHUNK_MAX)
    end
  end
end
