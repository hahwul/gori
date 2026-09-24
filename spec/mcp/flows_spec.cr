require "../spec_helper"
require "../support/mcp_harness"
require "../../src/gori/tui/tab_controller"

# The zero-arg call every get_current_context example makes.
private CONTEXT_CALL = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_current_context","arguments":{}}})

private def mcp_drive_with_filter(store, filter : Gori::MCP::ToolFilter, *lines) : Array(JSON::Any)
  input = IO::Memory.new(lines.join('\n') + "\n")
  output = IO::Memory.new
  Gori::MCP::Server.new(store, allow_actions: true, verify_upstream: true,
    tool_filter: filter, input: input, output: output).run
  output.to_s.each_line.reject(&.strip.empty?).map { |line| JSON.parse(line) }.to_a
end

private def gzip_bytes(text : String) : Bytes
  io = IO::Memory.new
  Compress::Gzip::Writer.open(io, &.print(text))
  io.to_slice
end

describe Gori::MCP::Server do
  describe "list_history" do
    it "rejects a QL query that compiles to nothing (not match-all)" do
      with_store do |store|
        mcp_seed_flow(store, "ex.test", "GET", "/", 200)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{"query":"status:>=foo"}}})
        resp = mcp_drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.should contain("invalid query")
        store.count.should eq(1) # didn't silently dump every flow
      end
    end

    # `flows.id` is a REUSABLE rowid, so a clear restarts numbering and a forward cursor held
    # from before it is permanently ahead of every row. `since` then returned `[]` forever
    # while the rows sat right there — "no new flows" and "your cursor is stranded" were the
    # same answer, and an agent polling this feed simply went blind.
    it "names a stranded 'since' cursor instead of answering with an empty page forever" do
      with_store do |store|
        3.times { |i| mcp_seed_flow(store, "h.test", "GET", "/p#{i}", 200) }
        store.clear_flows
        fresh = mcp_seed_flow(store, "h.test", "GET", "/after-clear", 200)
        fresh.should eq(1) # ids really do restart — that is what strands the cursor

        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{"since":22}}})
        resp = mcp_drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true
        text = resp["result"]["content"][0]["text"].as_s
        text.should contain("ahead of the newest flow")
        text.should contain("since=0")
      end
    end

    it "rejects a nonzero 'since' cursor while history is empty after a clear" do
      with_store do |store|
        3.times { |i| mcp_seed_flow(store, "h.test", "GET", "/p#{i}", 200) }
        store.clear_flows.should be_true

        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{"since":22}}})
        resp = mcp_drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true
        text = resp["result"]["content"][0]["text"].as_s
        text.should contain("history was cleared")
        text.should contain("since=0")
      end
    end

    it "still answers an in-range 'since' cursor normally" do
      with_store do |store|
        a = mcp_seed_flow(store, "h.test", "GET", "/a", 200)
        b = mcp_seed_flow(store, "h.test", "GET", "/b", 200)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{"since":#{a}}}})
        mcp_tool_payload(mcp_drive(store, call)[0])["flows"].as_a.map(&.["id"].as_i64).should eq([b])
      end
    end

    it "paginates filtered results with before_id" do
      with_store do |store|
        a = mcp_seed_flow(store, "h.test", "GET", "/a", 500)
        b = mcp_seed_flow(store, "h.test", "GET", "/b", 500)
        mcp_seed_flow(store, "h.test", "GET", "/c", 200)

        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{"query":"status:500","limit":1}}})
        page1 = mcp_tool_payload(mcp_drive(store, call)[0])["flows"].as_a
        page1.map(&.["id"].as_i64).should eq([b])

        cur = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_history","arguments":{"query":"status:500","limit":1,"before_id":#{b}}}})
        page2 = mcp_tool_payload(mcp_drive(store, cur)[0])["flows"].as_a
        page2.map(&.["id"].as_i64).should eq([a])
      end
    end

    it "returns flows newest-first, filters by QL, and paginates by before_id" do
      with_store do |store|
        a = mcp_seed_flow(store, "alpha.test", "GET", "/a", 200)
        b = mcp_seed_flow(store, "beta.test", "POST", "/b", 500)
        c = mcp_seed_flow(store, "alpha.test", "GET", "/c", 200)

        call = %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_history","arguments":{}}})
        rows = mcp_tool_payload(mcp_drive(store, call)[0])["flows"].as_a
        rows.map(&.["id"].as_i64).should eq([c, b, a]) # newest first

        q = %({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_history","arguments":{"query":"host:beta"}}})
        only = mcp_tool_payload(mcp_drive(store, q)[0])["flows"].as_a
        only.map(&.["id"].as_i64).should eq([b])

        cur = %({"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_history","arguments":{"before_id":#{c}}}})
        page = mcp_tool_payload(mcp_drive(store, cur)[0])["flows"].as_a
        page.map(&.["id"].as_i64).should eq([b, a])
      end
    end

    it "in_scope narrows to configured scope even with the display lens off, capture intact" do
      with_store do |store|
        a = mcp_seed_flow(store, "alpha.test", "GET", "/a", 200)
        b = mcp_seed_flow(store, "beta.test", "GET", "/b", 200)
        store.add_scope_rule("include", "host", "alpha.test") # rule present, lens never enabled

        all = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{}}})
        mcp_tool_payload(mcp_drive(store, all)[0])["flows"].as_a.map(&.["id"].as_i64).should eq([b, a]) # everything captured

        scoped = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_history","arguments":{"in_scope":true}}})
        mcp_tool_payload(mcp_drive(store, scoped)[0])["flows"].as_a.map(&.["id"].as_i64).should eq([a]) # only in-scope
      end
    end

    it "hide_static leaves out images, fonts and media, and composes with the rest" do
      with_store do |store|
        api = mcp_seed_flow(store, "a.test", "GET", "/api/me", 200, content_type: "application/json")
        mcp_seed_flow(store, "a.test", "GET", "/logo", 200, content_type: "image/png")
        mcp_seed_flow(store, "a.test", "GET", "/f.woff2", 304) # no Content-Type: by extension
        gone = mcp_seed_flow(store, "a.test", "GET", "/gone.png", 404, content_type: "image/png")

        call = ->(args : String) {
          req = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":#{args}}})
          mcp_tool_payload(mcp_drive(store, req)[0])
        }
        call.call(%({})).["flows"].as_a.size.should eq(4)
        call.call(%({"hide_static":true})).["flows"].as_a.map(&.["id"].as_i64).should eq([gone, api])
        call.call(%({"hide_static":true,"query":"status:200"})).["flows"].as_a.map(&.["id"].as_i64).should eq([api])
        # An explicit id set is narrowed too, and says what did it.
        named = call.call(%({"hide_static":true,"ids":[#{api},#{api + 1}]}))
        named["filtered_out_ids"].as_a.map(&.as_i64).should eq([api + 1])
        named["filtered_out_note"].as_s.should contain("hide_static")
      end
    end

    it "in_scope composes with a QL query" do
      with_store do |store|
        mcp_seed_flow(store, "alpha.test", "GET", "/a", 200)
        b = mcp_seed_flow(store, "alpha.test", "GET", "/b", 500)
        mcp_seed_flow(store, "beta.test", "GET", "/c", 500)
        store.add_scope_rule("include", "host", "alpha.test")

        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{"in_scope":true,"query":"status:500"}}})
        mcp_tool_payload(mcp_drive(store, call)[0])["flows"].as_a.map(&.["id"].as_i64).should eq([b])
      end
    end

    it "in_scope with no scope rules configured returns empty (not everything)" do
      with_store do |store|
        mcp_seed_flow(store, "alpha.test", "GET", "/a", 200)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{"in_scope":true}}})
        mcp_tool_payload(mcp_drive(store, call)[0])["flows"].as_a.should be_empty
      end
    end
  end

  describe "get_flow" do
    it "decodes a gzip response body to text" do
      with_store do |store|
        id = mcp_seed_flow(store, "ex.test", "GET", "/", 200,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\n",
          resp_body: gzip_bytes("hello gzip world"), content_type: "text/plain")
        call = %({"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":#{id}}}})
        body = mcp_tool_payload(mcp_drive(store, call)[0])["response_body"]
        body["encoding"].as_s.should eq("text")
        body["text"].as_s.should eq("hello gzip world")
      end
    end

    it "continues paging in the decoded representation for compressed bodies" do
      with_store do |store|
        text = "z" * (Gori::MCP::Serialize::MAX_TEXT + 512)
        id = mcp_seed_flow(store, "ex.test", "GET", "/gzip-big", 200,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\n",
          resp_body: gzip_bytes(text), content_type: "text/plain")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_response_body_chunk","arguments":{"flow_id":#{id},"offset":#{Gori::MCP::Serialize::MAX_TEXT},"limit":512}}})
        chunk = mcp_tool_payload(mcp_drive(store, call)[0])
        chunk["representation"].as_s.should eq("decoded")
        chunk["text"].as_s.should eq("z" * 512)
        chunk["complete"].as_bool.should be_true
      end
    end

    it "summarises a binary body as base64" do
      with_store do |store|
        id = mcp_seed_flow(store, "ex.test", "GET", "/img", 200,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\n",
          resp_body: Bytes[0xff, 0xd8, 0xff, 0x00, 0x01], content_type: "image/png")
        call = %({"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":#{id}}}})
        body = mcp_tool_payload(mcp_drive(store, call)[0])["response_body"]
        body["encoding"].as_s.should eq("base64")
        body["binary"].as_bool.should be_true
        Base64.decode(body["base64"].as_s).should eq(Bytes[0xff, 0xd8, 0xff, 0x00, 0x01])
      end
    end

    it "parses a text/event-stream response into sse_events" do
      with_store do |store|
        id = mcp_seed_flow(store, "ex.test", "GET", "/stream", 200,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n",
          resp_body: "data: hi\n\nevent: tick\nid: 7\ndata: x\n\n".to_slice, content_type: "text/event-stream")
        call = %({"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":#{id}}}})
        sse = mcp_tool_payload(mcp_drive(store, call)[0])["sse_events"]
        sse["count"].as_i.should eq(2)
        sse["truncated"].as_bool.should be_false
        events = sse["events"].as_a
        events[0]["data"].as_s.should eq("hi")
        events[1]["type"].as_s.should eq("tick")
        events[1]["id"].as_s.should eq("7")
        events[1]["data"].as_s.should eq("x")
      end
    end

    it "includes WebSocket messages for a 101 flow (parity with `gori run show`)" do
      with_store do |store|
        id = mcp_seed_flow(store, "ws.test", "GET", "/socket", 101,
          resp_head: "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n")
        store.insert_ws_message(id, "out", 1, "hello".to_slice)
        store.insert_ws_message(id, "in", 1, "world".to_slice)
        store.insert_ws_message(id, "in", 2, Bytes[0x00, 0x01, 0xff]) # binary frame
        call = %({"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":#{id}}}})
        ws = mcp_tool_payload(mcp_drive(store, call)[0])["ws_messages"]
        ws["count"].as_i.should eq(3)
        ws["truncated"].as_bool.should be_false
        msgs = ws["messages"].as_a
        msgs[0]["direction"].as_s.should eq("out")
        msgs[0]["text"].as_s.should eq("hello")
        msgs[0]["type"].as_s.should eq("text")     # RFC 6455 opcode name
        msgs[0].as_h.has_key?("at").should be_true # per-frame timestamp
        msgs[1]["direction"].as_s.should eq("in")
        msgs[1]["text"].as_s.should eq("world")
        msgs[2]["binary"].as_bool.should be_true
        msgs[2]["type"].as_s.should eq("binary")
        msgs[2]["size"].as_i.should eq(3)
        msgs[2].as_h.has_key?("text").should be_false # binary frames never inline a payload
      end
    end

    it "omits ws_messages for a non-WebSocket flow" do
      with_store do |store|
        id = mcp_seed_flow(store, "ex.test", "GET", "/", 200)
        call = %({"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":#{id}}}})
        mcp_tool_payload(mcp_drive(store, call)[0]).as_h.has_key?("ws_messages").should be_false
      end
    end

    it "returns isError for an unknown flow id" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":9999}}})
        resp = mcp_drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true
      end
    end

    it "accepts an integer id sent as a JSON string (client compat)" do
      with_store do |store|
        id = mcp_seed_flow(store, "ex.test", "GET", "/", 200)
        call = %({"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":"#{id}"}}})
        resp = mcp_drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_false
        mcp_tool_payload(resp)["id"].as_i64.should eq(id)
      end
    end
  end

  describe "body_mode / max_body_bytes" do
    it "returns body shape only with body_mode:none" do
      with_store do |store|
        id = mcp_seed_flow(store, "h.test", "GET", "/b", 200,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n", resp_body: "hello".to_slice)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":#{id},"body_mode":"none"}}})
        body = mcp_tool_payload(mcp_drive(store, call)[0])["response_body"]
        body["omitted"].as_bool.should be_true
        body["size"].as_i.should eq(5)
        body.as_h.has_key?("text").should be_false
      end
    end

    it "caps the inlined body with max_body_bytes and flags truncation" do
      with_store do |store|
        id = mcp_seed_flow(store, "h.test", "GET", "/b", 200,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n", resp_body: "0123456789".to_slice)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":#{id},"max_body_bytes":4}}})
        body = mcp_tool_payload(mcp_drive(store, call)[0])["response_body"]
        body["text"].as_s.should eq("0123")
        body["truncated"].as_bool.should be_true
        body["size"].as_i.should eq(10)
      end
    end

    it "defaults to full body when unspecified" do
      with_store do |store|
        id = mcp_seed_flow(store, "h.test", "GET", "/b", 200,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n", resp_body: "hello".to_slice)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":#{id}}}})
        body = mcp_tool_payload(mcp_drive(store, call)[0])["response_body"]
        body["text"].as_s.should eq("hello")
        body["truncated"].as_bool.should be_false
      end
    end

    it "treats max_body_bytes:0 as the mode default, not a zero-byte cap" do
      with_store do |store|
        id = mcp_seed_flow(store, "h.test", "GET", "/b", 200,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n", resp_body: "hello".to_slice)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":#{id},"max_body_bytes":0}}})
        body = mcp_tool_payload(mcp_drive(store, call)[0])["response_body"]
        body["text"].as_s.should eq("hello") # full body — not clamped to 0 bytes
        body["truncated"].as_bool.should be_false
      end
    end
  end

  describe "get_response_body_chunk offset validation" do
    it "flags an out-of-range offset instead of silently clamping" do
      with_store do |store|
        id = mcp_seed_flow(store, "h.test", "GET", "/b", 200,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n", resp_body: "hello".to_slice)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_response_body_chunk","arguments":{"flow_id":#{id},"offset":9999}}})
        p = mcp_tool_payload(mcp_drive(store, call)[0])
        p["requested_offset"].as_i.should eq(9999)
        p["offset"].as_i.should eq(5) # clamped to the body end
        p["offset_out_of_range"].as_bool.should be_true
        p["warning"].as_s.should contain("past")
        p["returned_bytes"].as_i.should eq(0)
        p["complete"].as_bool.should be_true
      end
    end

    it "does not flag a legitimate final read at the body end" do
      with_store do |store|
        id = mcp_seed_flow(store, "h.test", "GET", "/b", 200,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n", resp_body: "hello".to_slice)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_response_body_chunk","arguments":{"flow_id":#{id},"offset":5}}})
        p = mcp_tool_payload(mcp_drive(store, call)[0])
        p.as_h.has_key?("offset_out_of_range").should be_false
        p.as_h.has_key?("warning").should be_false
        p["complete"].as_bool.should be_true
      end
    end
  end

  describe "arg coercion" do
    it "honours a limit passed as a JSON string or integral float" do
      with_store do |store|
        3.times { |i| mcp_seed_flow(store, "h#{i}.test", "GET", "/", 200) }
        as_str = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{"limit":"2"}}})
        mcp_tool_payload(mcp_drive(store, as_str)[0])["flows"].as_a.size.should eq(2)
        as_float = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{"limit":2.0}}})
        mcp_tool_payload(mcp_drive(store, as_float)[0])["flows"].as_a.size.should eq(2)
      end
    end

    it "rejects a fractional float id rather than truncating it to the wrong flow" do
      with_store do |store|
        mcp_seed_flow(store, "ex.test", "GET", "/", 200) # id 1
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":1.9}}})
        resp = mcp_drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true # NOT a silent hit on flow 1
      end
    end

    it "does not crash on an out-of-Int64-range float (clamps the limit)" do
      with_store do |store|
        2.times { |i| mcp_seed_flow(store, "h#{i}.test", "GET", "/", 200) }
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{"limit":1e19}}})
        resp = mcp_drive(store, call)[0]
        resp["result"]["isError"]?.try(&.as_bool).should_not be_true # no OverflowError -> tool error
        mcp_tool_payload(resp)["flows"].as_a.size.should eq(2)
      end
    end
  end

  describe "pagination transparency" do
    it "reports has_more and does not flag an in-range limit in list_issues" do
      with_store do |store|
        3.times { |i| store.insert_issue("issue #{i}", Gori::Store::Severity::Low, nil, nil) }
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_issues","arguments":{"limit":2}}})
        p = mcp_tool_payload(mcp_drive(store, call)[0])
        p["returned"].as_i.should eq(2)
        p["has_more"].as_bool.should be_true
        p.as_h.has_key?("requested_limit").should be_false # 2 is valid → not clamped
      end
    end

    it "echoes requested_limit + a warning when a limit is clamped (0 -> 1)" do
      with_store do |store|
        store.insert_issue("x", Gori::Store::Severity::Low, nil, nil)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_issues","arguments":{"limit":0}}})
        p = mcp_tool_payload(mcp_drive(store, call)[0])
        p["requested_limit"].as_i.should eq(0)
        p["limit"].as_i.should eq(1)
        p["pagination_warning"].as_s.should contain("clamped")
      end
    end
  end

  describe "list_sitemap transport" do
    it "keys endpoints by transport and reports status set + counts; collapse_transport merges" do
      with_store do |store|
        mk = ->(scheme : String, ver : String, status : Int32) do
          id = store.insert_flow(Gori::Store::CapturedRequest.new(
            created_at: 1_i64, scheme: scheme, host: "api.test", port: scheme == "https" ? 443 : 80,
            method: "GET", target: "/x", http_version: ver,
            head: "GET /x HTTP/1.1\r\nHost: api.test\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
          store.update_response(Gori::Store::CapturedResponse.new(
            flow_id: id, status: status, head: "HTTP/1.1 #{status}\r\n\r\n".to_slice, body: nil))
        end
        mk.call("http", "HTTP/1.1", 200)
        mk.call("https", "HTTP/1.1", 500)
        mk.call("https", "HTTP/2", 500)

        entries = mcp_tool_payload(mcp_drive(store, %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_sitemap","arguments":{}}}))[0])["entries"].as_a
        entries.size.should eq(3) # http/1.1, https/1.1, https/h2 kept separate
        http = entries.find { |e| e["scheme"].as_s == "http" }.not_nil!
        http["success_count"].as_i.should eq(1)
        http["error_count"].as_i.should eq(0)
        h2 = entries.find { |e| e["http_version"].as_s == "HTTP/2" }.not_nil!
        h2["error_count"].as_i.should eq(1)

        collapsed = mcp_tool_payload(mcp_drive(store, %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_sitemap","arguments":{"collapse_transport":true}}}))[0])["entries"].as_a
        collapsed.size.should eq(1) # merged to one host/method/target
        collapsed[0].as_h.has_key?("scheme").should be_false
      end
    end
  end

  it "list_sitemap hide_static leaves static endpoints out of the map" do
    with_store do |store|
      mcp_seed_flow(store, "a.test", "GET", "/api/me", 200, content_type: "application/json")
      mcp_seed_flow(store, "a.test", "GET", "/logo.png", 200, content_type: "image/png")
      req = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_sitemap","arguments":{"hide_static":true}}})
      entries = mcp_tool_payload(mcp_drive(store, req)[0])["entries"].as_a
      entries.map(&.["target"].as_s).should eq(["/api/me"])
    end
  end

  describe "list_sitemap query folding" do
    it "folds the query variants of one path into a single entry, summing their counts" do
      with_store do |store|
        mk = ->(target : String, status : Int32) do
          id = store.insert_flow(Gori::Store::CapturedRequest.new(
            created_at: 1_i64, scheme: "https", host: "shop.demo.test", port: 443,
            method: "GET", target: target, http_version: "HTTP/1.1",
            head: "GET #{target} HTTP/1.1\r\nHost: shop.demo.test\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
          store.update_response(Gori::Store::CapturedResponse.new(
            flow_id: id, status: status, head: "HTTP/1.1 #{status}\r\n\r\n".to_slice, body: nil))
        end
        mk.call("/search?q=widgets", 200)
        mk.call("/search?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E", 500)
        mk.call("/login", 200)

        entries = mcp_tool_payload(mcp_drive(store, %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_sitemap","arguments":{}}}))[0])["entries"].as_a
        entries.size.should eq(2) # /search once, /login once
        search = entries.find { |e| e["target"].as_s == "/search" }.not_nil!
        search["query_variants"].as_i.should eq(2)
        search["query_targets"].as_a.size.should eq(2)
        search["count"].as_i.should eq(2)         # summed over the variants
        search["success_count"].as_i.should eq(1) # ...as are the outcome buckets
        search["error_count"].as_i.should eq(1)
        search["statuses"].as_s.split(',').sort!.should eq(["200", "500"])
        # A path with no query is untouched: no fold fields, target verbatim.
        login = entries.find { |e| e["target"].as_s == "/login" }.not_nil!
        login.as_h.has_key?("query_variants").should be_false

        # ...and fold_query:false is the twin of the CLI's --no-fold-query.
        raw = mcp_tool_payload(mcp_drive(store, %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_sitemap","arguments":{"fold_query":false}}}))[0])["entries"].as_a
        raw.size.should eq(3)
        raw.map(&.["target"].as_s).should contain("/search?q=widgets")
      end
    end

    it "keeps a folded path separate per transport, as the unfolded list does" do
      with_store do |store|
        mk = ->(scheme : String, port : Int32, target : String) do
          store.insert_flow(Gori::Store::CapturedRequest.new(
            created_at: 1_i64, scheme: scheme, host: "api.test", port: port,
            method: "GET", target: target, http_version: "HTTP/1.1",
            head: "GET #{target} HTTP/1.1\r\nHost: api.test\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
        end
        mk.call("http", 80, "/x?a=1")
        mk.call("https", 443, "/x?a=2")

        entries = mcp_tool_payload(mcp_drive(store, %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_sitemap","arguments":{}}}))[0])["entries"].as_a
        entries.size.should eq(2) # http and https did not merge
        entries.map(&.["target"].as_s).should eq(["/x", "/x"])
        entries.map(&.["scheme"].as_s).sort!.should eq(["http", "https"])
      end
    end
  end

  describe "get_current_context" do
    it "reports a non-object ui_state as unreadable, not a raw tool error" do
      with_store do |store|
        store.set_setting(Gori::Store::UI_STATE_KEY, "[1,2,3]") # valid JSON, wrong shape
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_current_context","arguments":{}}})
        resp = mcp_drive(store, call)[0]
        resp["result"]["isError"]?.try(&.as_bool?).should_not be_true # was: "tool error: Expected Hash…"
        payload = mcp_tool_payload(resp)
        payload["available"].as_bool.should be_false
        payload["note"].as_s.should contain("unreadable")
      end
    end

    it "reads a well-formed ui_state object" do
      with_store do |store|
        store.set_setting(Gori::Store::UI_STATE_KEY, %({"active_tab":"history","focus_pane":"body"}))
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_current_context","arguments":{}}})
        payload = mcp_tool_payload(mcp_drive(store, call)[0])
        payload["available"].as_bool.should be_true
        payload["active_tab"].as_s.should eq("history")
      end
    end

    # The operator's selection (#1091). The TUI owns this schema and the tool relays it
    # verbatim, so these examples seed the row by hand — which is also how the read side gets
    # covered without a TUI process in the loop.
    it "relays the selection and names the call that turns it into data" do
      with_store do |store|
        store.set_setting(Gori::Store::UI_STATE_KEY, %({"active_tab":"history","selection":) +
                                                     %({"kind":"flow","ids":[7,9],"target_source":"marks","marked_count":2,"truncated":false}}))
        payload = mcp_tool_payload(mcp_drive(store, CONTEXT_CALL)[0])
        payload["selection"]["ids"].as_a.map(&.as_i64).should eq([7_i64, 9_i64])
        payload["selection"]["target_source"].as_s.should eq("marks")
        # Only History has a one-call form, and saying so beats an agent discovering it by
        # calling get_flow once per id.
        payload["selection_next_call"].as_s.should contain("list_history{ids")
      end
    end

    it "honors excluded intercept readers and does not suggest a hidden tool" do
      with_store do |store|
        store.set_setting(Gori::Store::UI_STATE_KEY, %({"active_tab":"intercept","selection":) +
                                                     %({"kind":"intercept_item","ids":[7],"target_source":"cursor","marked_count":0,"truncated":false}}))
        filter = Gori::MCP::ToolFilter.parse("get_current_context,-intercept_get,-intercept_list",
          Gori::MCP::Tools::TOOL_NAMES, Gori::MCP::Tools::TOOL_DEPENDENCIES).as(Gori::MCP::ToolFilter)
        responses = mcp_drive_with_filter(store, filter,
          %({"jsonrpc":"2.0","id":1,"method":"tools/list"}),
          %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_current_context","arguments":{}}}),
          %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"intercept_get","arguments":{"item_id":7,"include_sensitive":true}}}))

        listed = responses[0]["result"]["tools"].as_a.map(&.["name"].as_s)
        listed.should contain("get_current_context")
        listed.should_not contain("intercept_get")
        listed.should_not contain("intercept_list")

        context = mcp_tool_payload(responses[1])
        context["selection_next_call"].as_s.should contain("intercept_get is not exposed")
        context["selection_next_call"].as_s.should contain("cannot be read through MCP")

        responses[2]["error"]["message"].as_s.should contain("not served by this gori MCP server")
      end
    end

    it "points to list previews when full intercept detail is excluded" do
      with_store do |store|
        store.set_setting(Gori::Store::UI_STATE_KEY, %({"active_tab":"intercept","selection":) +
                                                     %({"kind":"intercept_item","ids":[7],"target_source":"cursor","marked_count":0,"truncated":false}}))
        filter = Gori::MCP::ToolFilter.parse("get_current_context,intercept_list,-intercept_get",
          Gori::MCP::Tools::TOOL_NAMES, Gori::MCP::Tools::TOOL_DEPENDENCIES).as(Gori::MCP::ToolFilter)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_current_context","arguments":{}}})
        payload = mcp_tool_payload(mcp_drive_with_filter(store, filter, call)[0])
        payload["selection_next_call"].as_s.should contain("intercept_list can show this item's preview and metadata")
        payload["selection_next_call"].as_s.should contain("full detail is unavailable")
      end
    end

    it "points a sitemap selection at the query that reaches its traffic" do
      with_store do |store|
        store.set_setting(Gori::Store::UI_STATE_KEY, %({"active_tab":"target","selection":) +
                                                     %({"kind":"sitemap_node","nodes":[{"host":"a.test","path":"/v1"}],"marked_count":1}}))
        payload = mcp_tool_payload(mcp_drive(store, CONTEXT_CALL)[0])
        # These are NOT flow ids and the payload must never let that be guessed.
        payload["selection"].as_h.has_key?("ids").should be_false
        payload["selection_next_call"].as_s.should contain("SITEMAP NODES")
      end
    end

    it "carries marks the operator left on a tab they are not looking at" do
      with_store do |store|
        store.set_setting(Gori::Store::UI_STATE_KEY, %({"active_tab":"repeater",) +
                                                     %("marks_elsewhere":[{"tab":"history","kind":"flow","marked_count":4}]}))
        payload = mcp_tool_payload(mcp_drive(store, CONTEXT_CALL)[0])
        row = payload["marks_elsewhere"].as_a.first
        row["tab"].as_s.should eq("history")
        row["marked_count"].as_i.should eq(4)
      end
    end

    it "says a row predating the selection channel has none, rather than inventing one" do
      with_store do |store|
        store.set_setting(Gori::Store::UI_STATE_KEY, %({"active_tab":"history","focus_pane":"body"}))
        payload = mcp_tool_payload(mcp_drive(store, CONTEXT_CALL)[0])
        payload["available"].as_bool.should be_true
        payload.as_h.has_key?("selection").should be_false
        payload.as_h.has_key?("selection_next_call").should be_false
      end
    end

    it "degrades a malformed selection instead of failing the whole call" do
      with_store do |store|
        # A row written by a future gori, a half-written one, or outside interference. Every
        # field here is read through `.try(&.as_*?)`, and the block is relayed as data — none
        # of it may reach a cast error.
        store.set_setting(Gori::Store::UI_STATE_KEY, %({"active_tab":"history","selection":[1,2,3]}))
        resp = mcp_drive(store, CONTEXT_CALL)[0]
        resp["result"]["isError"]?.try(&.as_bool?).should_not be_true
        mcp_tool_payload(resp)["available"].as_bool.should be_true

        store.set_setting(Gori::Store::UI_STATE_KEY, %({"active_tab":"history","selection":{"kind":42,"ids":"nope"}}))
        resp = mcp_drive(store, CONTEXT_CALL)[0]
        resp["result"]["isError"]?.try(&.as_bool?).should_not be_true
        # An unrecognised kind simply gets no next-call line; it never guesses one.
        mcp_tool_payload(resp).as_h.has_key?("selection_next_call").should be_false
      end
    end

    it "answers `unknown` rather than `false` when it cannot look for a window" do
      with_store do |store|
        # This harness binds no db_path, which is the shape a `--db :memory:` or an
        # unbound-then-bound server has. "I cannot see" and "nobody is there" are different
        # answers and only one of them is safe to act on — the same rule `holds_capture`
        # follows by being omitted rather than guessed.
        payload = mcp_tool_payload(mcp_drive(store, CONTEXT_CALL)[0])
        payload["tui"]["unknown"].as_bool.should be_true
        payload["tui"].as_h.has_key?("live").should be_false
      end
    end

    it "keeps a relayed History selection fetchable in ONE list_history call" do
      # The promise `selection_next_call` makes. Two constants in two files, and the wrong
      # drift turns "here is the set you marked" into "here is part of it".
      (Gori::Tui::TabController::SELECTION_ID_CAP <= Gori::MCP::Tools::MCP_HISTORY_IDS_MAX).should be_true
    end
  end

  describe "project_info" do
    it "includes project metadata fields" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"project_info","arguments":{}}})
        response = mcp_drive(store, call, project_name: "demo", project_slug: "demo")[0]
        info = mcp_tool_payload(response)
        info["flows"].as_i.should eq(0)
        info["read_only"].as_bool.should be_false
        info["bound"].as_bool.should be_true
        # Modern MCP clients get parsed data directly; content[0].text remains
        # for backward compatibility.
        response["result"]["structuredContent"]["project"].as_s.should eq("demo")
      end
    end
  end

  describe "import_flows" do
    it "imports a URL list into History" do
      with_store do |store|
        path = File.tempname("gori-mcp-import", ".txt")
        File.write(path, "https://a.test/\nhttps://b.test/x\n")
        begin
          call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"import_flows","arguments":{"kind":"urls","path":#{path.to_json}}}})
          payload = mcp_tool_payload(mcp_drive(store, call)[0])
          payload["count"].as_i.should eq(2)
          store.count.should eq(2)
        ensure
          File.delete?(path)
        end
      end
    end

    it "imports local OpenAPI refs through the shared importer" do
      with_store do |store|
        path = File.tempname("gori-mcp-import", ".json")
        File.write(path, <<-JSON)
          {
            "openapi": "3.0.3",
            "info": {"title": "t", "version": "1"},
            "servers": [{"url": "https://api.example.test"}],
            "components": {"parameters": {
              "UserId": {"name": "id", "in": "path", "required": true,
                         "schema": {"type": "integer"}}
            }},
            "paths": {"/users/{id}": {
              "parameters": [{"$ref": "#/components/parameters/UserId"}],
              "get": {"responses": {"200": {"description": "ok"}}}
            }}
          }
          JSON
        begin
          call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"import_flows","arguments":{"kind":"oas","path":#{path.to_json}}}})
          payload = mcp_tool_payload(mcp_drive(store, call)[0])
          payload["count"].as_i.should eq(1)
          detail = store.get_flow(store.recent_flows(1).first.id).not_nil!
          detail.row.target.should eq("/users/1")
        ensure
          File.delete?(path)
        end
      end
    end

    it "returns a clean error for a missing file" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"import_flows","arguments":{"kind":"urls","path":"/no/such/file.txt"}}})
        resp = mcp_drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["content"][0]["text"].as_s.should contain("not found")
      end
    end

    it "imports a Postman collection into History" do
      with_store do |store|
        path = File.tempname("gori-mcp-import", ".json")
        File.write(path, %({"info":{"name":"n"},"variable":[{"key":"b","value":"https://a.test"}],) +
                         %("item":[{"name":"f","item":[{"request":{"method":"GET","url":"{{b}}/x"}}]}]}))
        begin
          call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"import_flows","arguments":{"kind":"postman","path":#{path.to_json}}}})
          payload = mcp_tool_payload(mcp_drive(store, call)[0])
          payload["count"].as_i.should eq(1)
          store.search(Gori::QL::EMPTY, 1).first.host.should eq("a.test")
        ensure
          File.delete?(path)
        end
      end
    end

    it "rejects an invalid kind and lists the accepted ones" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"import_flows","arguments":{"kind":"csv","path":"/tmp/x"}}})
        resp = mcp_drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["field"].as_s.should eq("kind")
        # The message enumerates the kinds; an agent that guessed wrong gets the real list.
        resp["content"][0]["text"].as_s.should contain("postman")
        # …and it quotes back the value it refused, so the agent can see it was READ.
        resp["content"][0]["text"].as_s.should contain(%("csv"))
      end
    end

    # ABSENT and WRONG are two different mistakes, and only one of them has a value to look
    # at again. "invalid 'kind'" for an argument that was never sent reads as a rejected
    # value, which an agent answers by re-spelling the one it did send — `path` one line down
    # in the same handler has always said this correctly.
    it "says an omitted kind is MISSING, not invalid" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"import_flows","arguments":{"path":"/tmp/x"}}})
        resp = mcp_drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["field"].as_s.should eq("kind")
        text = resp["content"][0]["text"].as_s
        text.should contain("missing required 'kind'")
        text.should contain("har")
      end
    end

    # #1244 — an agent holds a copied curl command as a string; `text` takes it directly.
    it "imports curl text into History, one flow per request, with curl's meaning of -b" do
      with_store do |store|
        tools = tools_for(store)
        text = "curl 'https://a.test/p' -b 'sid=1' -k -d 'x=1' ;\ncurl https://a.test/q"
        payload = mcp_ok_json(tools, "import_flows", {kind: "curl", text: text}.to_json)
        payload["count"].as_i.should eq(2)
        payload.as_h.has_key?("path").should be_false
        payload["notes"].as_a.map(&.as_s).join.should contain("-k")
        flows = store.recent_flows(2).map { |f| store.get_flow(f.id).not_nil! }
        post = flows.find! { |f| f.row.method == "POST" }
        String.new(post.request_head).should contain("Cookie: sid=1\r\n")
        post.request_body.not_nil!.should eq("x=1".to_slice)
        post.row.host.should eq("a.test")
      end
    end

    it "imports a curl command from a file" do
      with_store do |store|
        path = File.tempname("gori-mcp-import", ".sh")
        File.write(path, "curl https://a.test/from-file\n")
        begin
          payload = mcp_ok_json(tools_for(store), "import_flows", {kind: "curl", path: path}.to_json)
          payload["count"].as_i.should eq(1)
        ensure
          File.delete?(path)
        end
      end
    end

    it "refuses curl text that cannot become a request, with the importer's reason" do
      with_store do |store|
        r = tools_for(store).call("import_flows", JSON.parse({kind: "curl", text: "curl -d @body.json https://a.test/"}.to_json))
        r.is_error.should be_true
        r.text.should contain("local file")
        store.count.should eq(0)
      end
    end

    it "takes 'text' for kind curl only, and not beside 'path'" do
      with_store do |store|
        tools = tools_for(store)
        r = tools.call("import_flows", JSON.parse({kind: "har", text: "x"}.to_json))
        r.is_error.should be_true
        r.text.should contain("\"curl\" only")
        r = tools.call("import_flows", JSON.parse({kind: "curl", text: "curl https://a.test/", path: "/tmp/x"}.to_json))
        r.is_error.should be_true
        r.text.should contain("not both")
        r = tools.call("import_flows", JSON.parse({kind: "curl"}.to_json))
        r.is_error.should be_true
        r.text.should contain("'path' or 'text'")
      end
    end

    it "accepts every kind Import.import_file dispatches on" do
      # The MCP whitelist (mcp/tools/import.cr) and the parser table are edited in different
      # files — a format added to one and not the other is invisible to agents.
      Gori::Import::LABELS.each_key do |kind|
        with_store do |store|
          call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"import_flows","arguments":{"kind":#{kind.to_s.to_json},"path":"/no/such/file"}}})
          resp = mcp_drive(store, call)[0]["result"]
          resp["isError"].as_bool.should be_true
          # It got past the kind check and failed on the path — which is the point.
          resp["content"][0]["text"].as_s.should contain("not found")
        end
      end
    end
  end
end

describe "MCP sitemap tags" do
  it "sets, lists, clears, and stamps a tag onto the matching list_sitemap entry" do
    with_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
        method: "GET", target: "/login?a=1", http_version: "HTTP/1.1",
        head: "GET /login?a=1 HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, source: Gori::FlowSource::Kind::Proxy))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
      tools = tools_for(store)

      res = mcp_ok_json(tools, "set_sitemap_tag", %({"host":"acme.test","path":"/login?a=1","tag":"auth entry"}))
      res["tag"].as_s.should eq("auth entry")

      tags = mcp_ok_json(tools, "list_sitemap_tags", "{}").as_a
      tags.size.should eq(1)
      tags.first["path"].as_s.should eq("/login?a=1")

      # list_sitemap folds query variants by default, and the folded row is synthetic: it
      # holds no tag of its own, but it does report the memo pinned on the variant.
      entry = mcp_ok_json(tools, "list_sitemap", "{}")["entries"].as_a.first
      entry["target"].as_s.should eq("/login")
      entry["query_variants"].as_i.should eq(1)
      entry["query_targets"].as_a.map(&.as_s).should eq(["/login?a=1"])
      entry["variant_tags"].as_a.first["tag"].as_s.should eq("auth entry")
      entry.as_h.has_key?("tag").should be_false

      unfolded = mcp_ok_json(tools, "list_sitemap", %({"fold_query":false}))["entries"].as_a.first
      unfolded["target"].as_s.should eq("/login?a=1")
      unfolded["tag"].as_s.should eq("auth entry")

      mcp_ok_json(tools, "set_sitemap_tag", %({"host":"acme.test","path":"/login?a=1"}))["cleared"].as_bool.should be_true
      mcp_ok_json(tools, "list_sitemap_tags", "{}").as_a.empty?.should be_true
    end
  end

  it "keys tags on the path INCLUDING the query, matching the Sitemap tree" do
    with_store do |store|
      tools = tools_for(store)
      mcp_ok_json(tools, "set_sitemap_tag", %({"host":"acme.test","path":"/login?a=1","tag":"with-query"}))
      mcp_ok_json(tools, "set_sitemap_tag", %({"host":"acme.test","path":"/login","tag":"bare"}))
      # Two DISTINCT nodes — stripping the query would collapse them and file the tag
      # under a key the tree never looks up.
      store.sitemap_tags[{"acme.test", "/login?a=1"}]?.should eq("with-query")
      store.sitemap_tags[{"acme.test", "/login"}]?.should eq("bare")
    end
  end
end

describe "MCP flow deletion" do
  it "deletes one flow by id" do
    with_store do |store|
      a = mcp_seed_flow(store, "/a")
      b = mcp_seed_flow(store, "/b")
      tools = tools_for(store)

      mcp_ok_json(tools, "delete_flow", %({"id":#{a}}))["deleted"].as_bool.should be_true
      store.get_flow(a).should be_nil
      store.get_flow(b).should_not be_nil
      tools.call("delete_flow", JSON.parse(%({"id":#{a}}))).is_error.should be_true # already gone
    end
  end

  it "refuses clear_history without confirm:true and reports the count it would destroy" do
    with_store do |store|
      mcp_seed_flow(store, "/a")
      mcp_seed_flow(store, "/b")
      tools = tools_for(store)

      r = tools.call("clear_history", JSON.parse("{}"))
      r.is_error.should be_true
      r.text.should contain("2")
      store.count.should eq(2) # nothing destroyed

      tools.call("clear_history", JSON.parse(%({"confirm":false}))).is_error.should be_true
      store.count.should eq(2)

      mcp_ok_json(tools, "clear_history", %({"confirm":true}))["deleted"].as_i.should eq(2)
      store.count.should eq(0)
    end
  end

  it "refuses both under --read-only" do
    with_store do |store|
      id = mcp_seed_flow(store)
      ro = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
      ro.call("delete_flow", JSON.parse(%({"id":#{id}}))).is_error.should be_true
      ro.call("clear_history", JSON.parse(%({"confirm":true}))).is_error.should be_true
      store.count.should eq(1)
    end
  end
end

describe "MCP get_current_context" do
  it "emits each key exactly once" do
    with_store do |store|
      store.set_setting(Gori::Store::UI_STATE_KEY, %({"active_tab":"history","focus_pane":"body"}))
      lines = mcp_drive(store, %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_current_context","arguments":{}}}),
        project_name: "acme")
      raw = lines[0]["result"]["content"][0]["text"].as_s
      # A duplicate key is first/last-wins by parser and rejected outright by strict ones,
      # so count the RAW text — JSON.parse would silently collapse it.
      raw.scan(/"project":/).size.should eq 1
      # The two keys #1091 added sit beside it and must not double either.
      raw.scan(/"selection":/).size.should eq 0 # this row carries none
      raw.scan(/"tui":/).size.should eq 1
      JSON.parse(raw)["project"].as_s.should eq "acme"
      JSON.parse(raw)["active_tab"].as_s.should eq "history"
    end
  end
end
