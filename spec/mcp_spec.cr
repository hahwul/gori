require "./spec_helper"
require "compress/gzip"
require "socket"
require "digest/sha1"

# Drives Gori::MCP end-to-end with scripted JSON-RPC lines over IO::Memory, plus
# unit tests for the body serializer and the send_request byte builder.

private def with_store(&)
  path = File.tempname("gori-mcp", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# Runs the server over the given request lines and returns each emitted line as a
# parsed JSON::Any (also proves STDOUT purity — a non-JSON line would raise here).
private def drive(store, *lines, allow_actions = true, verify_upstream = true,
                  project_name : String? = nil, project_slug : String? = nil) : Array(JSON::Any)
  input = IO::Memory.new(lines.join('\n') + "\n")
  output = IO::Memory.new
  Gori::MCP::Server.new(store,
    allow_actions: allow_actions, verify_upstream: verify_upstream,
    project_name: project_name, project_slug: project_slug,
    input: input, output: output).run
  output.to_s.each_line.reject(&.strip.empty?).map { |l| JSON.parse(l) }.to_a
end

# Parses the JSON payload a tools/call result carries in content[0].text.
private def tool_payload(resp : JSON::Any) : JSON::Any
  JSON.parse(resp["result"]["content"][0]["text"].as_s)
end

private def seed_flow(store, host, method, target, status = nil,
                      resp_head = "HTTP/1.1 200 OK\r\n\r\n", resp_body : Bytes? = nil,
                      content_type = nil) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: host, port: 443,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil))
  if status
    store.update_response(Gori::Store::CapturedResponse.new(
      flow_id: id, status: status, head: resp_head.to_slice, body: resp_body, content_type: content_type))
  end
  id
end

private def gzip_bytes(text : String) : Bytes
  io = IO::Memory.new
  Compress::Gzip::Writer.open(io, &.print(text))
  io.to_slice
end

# Minimal WebSocket origin for the MCP glue test: upgrade, echo one client frame,
# then close normally so send_websocket returns without waiting for its idle timer.
private def start_mcp_ws_origin : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    head = Gori::Proxy::Codec::Http1.read_head(conn).not_nil!
    key = String.new(head).each_line
      .find(&.downcase.starts_with?("sec-websocket-key:"))
      .try { |line| line.split(':', 2)[1].strip } || ""
    accept = Base64.strict_encode(Digest::SHA1.digest(key + Gori::Repeater::WsEngine::GUID))
    conn << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
            "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
    conn.flush
    if (frame = Gori::Proxy::WS.read_frame(conn)) && frame.data?
      conn.write(Gori::Proxy::WS.encode(frame.opcode, frame.payload, mask: false))
    end
    conn.write(Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_CLOSE, Bytes[0x03, 0xE8], mask: false))
    conn.flush
    conn.close
    origin.close
  rescue
    origin.close rescue nil
  end
  port
end

# One-shot HTTP/1 origin used to verify send_request audit recording, response
# header redaction, and continuation reads for bodies larger than the MCP cap.
private def start_mcp_http_origin(body : String, extra_headers = "") : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Gori::Proxy::Codec::Http1.read_head(conn)
    conn << "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n" \
            "Content-Length: #{body.bytesize}\r\n#{extra_headers}\r\n#{body}"
    conn.flush
    conn.close
    origin.close
  rescue
    origin.close rescue nil
  end
  port
end

private INIT = %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}})

describe Gori::MCP::Server do
  describe "handshake" do
    it "answers initialize with capabilities + serverInfo" do
      with_store do |store|
        out = drive(store, INIT)
        out.size.should eq(1)
        res = out[0]["result"]
        res["protocolVersion"].as_s.should eq("2025-06-18")
        res["capabilities"]["tools"].as_h.should be_empty
        res["serverInfo"]["name"].as_s.should eq("gori")
        res["serverInfo"]["version"].as_s.should eq(Gori::VERSION)
        out[0]["id"].as_i.should eq(1)
      end
    end

    it "echoes the client's protocolVersion when it is a supported revision" do
      with_store do |store|
        line = %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}})
        drive(store, line)[0]["result"]["protocolVersion"].as_s.should eq("2024-11-05")
      end
    end

    it "falls back to our version for an unsupported/garbage protocolVersion" do
      with_store do |store|
        line = %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}})
        drive(store, line)[0]["result"]["protocolVersion"].as_s.should eq(Gori::MCP::Server::PROTOCOL_VERSION)
      end
    end

    it "preserves the id type (string stays string)" do
      with_store do |store|
        line = %({"jsonrpc":"2.0","id":"abc","method":"ping"})
        out = drive(store, line)
        out[0]["id"].as_s.should eq("abc")
        out[0]["result"].as_h.should be_empty
      end
    end

    it "treats a notification (no id) as silent — no response" do
      with_store do |store|
        out = drive(store, %({"jsonrpc":"2.0","method":"notifications/initialized"}))
        out.should be_empty
      end
    end
  end

  describe "tools/list" do
    it "lists read tools and gates action/write tools behind allow_actions" do
      with_store do |store|
        listing = %({"jsonrpc":"2.0","id":2,"method":"tools/list"})

        full = drive(store, listing, allow_actions: true)[0]["result"]["tools"].as_a
        names = full.map(&.["name"].as_s)
        names.should contain("list_history")
        names.should contain("get_flow")
        names.should contain("ql_reference")
        names.should contain("project_info")
        names.should contain("get_repeater_context")
        names.should contain("send_request")
        names.should contain("send_websocket")
        names.should contain("create_issue")
        names.should contain("update_issue")
        # every tool has a well-formed object schema
        full.each do |t|
          t["name"].as_s.should_not be_empty
          t["description"].as_s.should_not be_empty
          t["inputSchema"]["type"].as_s.should eq("object")
        end

        ro = drive(store, listing, allow_actions: false)[0]["result"]["tools"].as_a
        ro_names = ro.map(&.["name"].as_s)
        ro_names.should contain("list_history")
        ro_names.should_not contain("send_request")
        ro_names.should_not contain("create_issue")
        ro_names.should_not contain("update_issue")
      end
    end
  end

  describe "list_history" do
    it "rejects a QL query that compiles to nothing (not match-all)" do
      with_store do |store|
        seed_flow(store, "ex.test", "GET", "/", 200)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{"query":"status:>=foo"}}})
        resp = drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.should contain("invalid query")
        store.count.should eq(1) # didn't silently dump every flow
      end
    end

    it "paginates filtered results with before_id" do
      with_store do |store|
        a = seed_flow(store, "h.test", "GET", "/a", 500)
        b = seed_flow(store, "h.test", "GET", "/b", 500)
        c = seed_flow(store, "h.test", "GET", "/c", 200)

        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{"query":"status:500","limit":1}}})
        page1 = tool_payload(drive(store, call)[0]).as_a
        page1.map(&.["id"].as_i64).should eq([b])

        cur = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_history","arguments":{"query":"status:500","limit":1,"before_id":#{b}}}})
        page2 = tool_payload(drive(store, cur)[0]).as_a
        page2.map(&.["id"].as_i64).should eq([a])
      end
    end

    it "returns flows newest-first, filters by QL, and paginates by before_id" do
      with_store do |store|
        a = seed_flow(store, "alpha.test", "GET", "/a", 200)
        b = seed_flow(store, "beta.test", "POST", "/b", 500)
        c = seed_flow(store, "alpha.test", "GET", "/c", 200)

        call = %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_history","arguments":{}}})
        rows = tool_payload(drive(store, call)[0]).as_a
        rows.map(&.["id"].as_i64).should eq([c, b, a]) # newest first

        q = %({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_history","arguments":{"query":"host:beta"}}})
        only = tool_payload(drive(store, q)[0]).as_a
        only.map(&.["id"].as_i64).should eq([b])

        cur = %({"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_history","arguments":{"before_id":#{c}}}})
        page = tool_payload(drive(store, cur)[0]).as_a
        page.map(&.["id"].as_i64).should eq([b, a])
      end
    end
  end

  describe "get_flow" do
    it "decodes a gzip response body to text" do
      with_store do |store|
        id = seed_flow(store, "ex.test", "GET", "/", 200,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\n",
          resp_body: gzip_bytes("hello gzip world"), content_type: "text/plain")
        call = %({"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":#{id}}}})
        body = tool_payload(drive(store, call)[0])["response_body"]
        body["encoding"].as_s.should eq("text")
        body["text"].as_s.should eq("hello gzip world")
      end
    end

    it "continues paging in the decoded representation for compressed bodies" do
      with_store do |store|
        text = "z" * (Gori::MCP::Serialize::MAX_TEXT + 512)
        id = seed_flow(store, "ex.test", "GET", "/gzip-big", 200,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\n",
          resp_body: gzip_bytes(text), content_type: "text/plain")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_response_body_chunk","arguments":{"flow_id":#{id},"offset":#{Gori::MCP::Serialize::MAX_TEXT},"limit":512}}})
        chunk = tool_payload(drive(store, call)[0])
        chunk["representation"].as_s.should eq("decoded")
        chunk["text"].as_s.should eq("z" * 512)
        chunk["complete"].as_bool.should be_true
      end
    end

    it "summarises a binary body as base64" do
      with_store do |store|
        id = seed_flow(store, "ex.test", "GET", "/img", 200,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\n",
          resp_body: Bytes[0xff, 0xd8, 0xff, 0x00, 0x01], content_type: "image/png")
        call = %({"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":#{id}}}})
        body = tool_payload(drive(store, call)[0])["response_body"]
        body["encoding"].as_s.should eq("base64")
        body["binary"].as_bool.should be_true
        Base64.decode(body["base64"].as_s).should eq(Bytes[0xff, 0xd8, 0xff, 0x00, 0x01])
      end
    end

    it "parses a text/event-stream response into sse_events" do
      with_store do |store|
        id = seed_flow(store, "ex.test", "GET", "/stream", 200,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n",
          resp_body: "data: hi\n\nevent: tick\nid: 7\ndata: x\n\n".to_slice, content_type: "text/event-stream")
        call = %({"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":#{id}}}})
        sse = tool_payload(drive(store, call)[0])["sse_events"]
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
        id = seed_flow(store, "ws.test", "GET", "/socket", 101,
          resp_head: "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n")
        store.insert_ws_message(id, "out", 1, "hello".to_slice)
        store.insert_ws_message(id, "in", 1, "world".to_slice)
        store.insert_ws_message(id, "in", 2, Bytes[0x00, 0x01, 0xff]) # binary frame
        call = %({"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":#{id}}}})
        ws = tool_payload(drive(store, call)[0])["ws_messages"]
        ws["count"].as_i.should eq(3)
        ws["truncated"].as_bool.should be_false
        msgs = ws["messages"].as_a
        msgs[0]["direction"].as_s.should eq("out")
        msgs[0]["text"].as_s.should eq("hello")
        msgs[1]["direction"].as_s.should eq("in")
        msgs[1]["text"].as_s.should eq("world")
        msgs[2]["binary"].as_bool.should be_true
        msgs[2]["size"].as_i.should eq(3)
        msgs[2].as_h.has_key?("text").should be_false # binary frames never inline a payload
      end
    end

    it "omits ws_messages for a non-WebSocket flow" do
      with_store do |store|
        id = seed_flow(store, "ex.test", "GET", "/", 200)
        call = %({"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":#{id}}}})
        tool_payload(drive(store, call)[0]).as_h.has_key?("ws_messages").should be_false
      end
    end

    it "returns isError for an unknown flow id" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":9999}}})
        resp = drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true
      end
    end

    it "accepts an integer id sent as a JSON string (client compat)" do
      with_store do |store|
        id = seed_flow(store, "ex.test", "GET", "/", 200)
        call = %({"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":"#{id}"}}})
        resp = drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_false
        tool_payload(resp)["id"].as_i64.should eq(id)
      end
    end
  end

  describe "arg coercion" do
    it "honours a limit passed as a JSON string or integral float" do
      with_store do |store|
        3.times { |i| seed_flow(store, "h#{i}.test", "GET", "/", 200) }
        as_str = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{"limit":"2"}}})
        tool_payload(drive(store, as_str)[0]).as_a.size.should eq(2)
        as_float = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{"limit":2.0}}})
        tool_payload(drive(store, as_float)[0]).as_a.size.should eq(2)
      end
    end

    it "rejects a fractional float id rather than truncating it to the wrong flow" do
      with_store do |store|
        seed_flow(store, "ex.test", "GET", "/", 200) # id 1
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":1.9}}})
        resp = drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true # NOT a silent hit on flow 1
      end
    end

    it "does not crash on an out-of-Int64-range float (clamps the limit)" do
      with_store do |store|
        2.times { |i| seed_flow(store, "h#{i}.test", "GET", "/", 200) }
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{"limit":1e19}}})
        resp = drive(store, call)[0]
        resp["result"]["isError"]?.try(&.as_bool).should_not be_true # no OverflowError -> tool error
        tool_payload(resp).as_a.size.should eq(2)
      end
    end
  end

  describe "issues write tools" do
    it "creates then updates an issue (full mode)" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"SQLi in login","severity":"high","host":"app.test"}}})
        new_id = tool_payload(drive(store, create)[0])["id"].as_i64
        store.get_issue(new_id).not_nil!.severity.should eq(Gori::Store::Severity::High)

        update = %({"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"update_issue","arguments":{"id":#{new_id},"status":"confirmed","severity":"critical"}}})
        drive(store, update)[0]["result"]["isError"].as_bool.should be_false
        reloaded = store.get_issue(new_id).not_nil!
        reloaded.status.should eq(Gori::Store::Status::Confirmed)
        reloaded.severity.should eq(Gori::Store::Severity::Critical)
      end
    end

    it "links a repeater on create and on a link-only update" do
      with_store do |store|
        repeater_a = store.insert_repeater("https://ex.test", "GET /a HTTP/1.1\r\n\r\n", false, true, nil, 0)
        repeater_b = store.insert_repeater("https://ex.test", "GET /b HTTP/1.1\r\n\r\n", false, true, nil, 1)
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"linked","repeater_id":#{repeater_a}}}})
        issue_id = tool_payload(drive(store, create)[0])["id"].as_i64
        links = store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id)
        links.map(&.ref_id).should contain(repeater_a)

        update = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"update_issue","arguments":{"id":#{issue_id},"repeater_id":#{repeater_b}}}})
        drive(store, update)[0]["result"]["isError"].as_bool.should be_false
        links = store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id)
        links.map(&.ref_id).should contain(repeater_b)
      end
    end

    it "rejects an unknown repeater_id without creating an issue" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"x","repeater_id":999}}})
        resp = drive(store, create)[0]
        resp["result"]["isError"].as_bool.should be_true
        store.count_issues.should eq(0)
      end
    end

    it "rejects an invalid severity on create (not silently coerced to info)" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"x","severity":"ultra"}}})
        resp = drive(store, create)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.should contain("invalid severity")
        store.count_issues.should eq(0)
      end
    end

    it "defaults an absent severity to info on create" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"x"}}})
        new_id = tool_payload(drive(store, create)[0])["id"].as_i64
        store.get_issue(new_id).not_nil!.severity.should eq(Gori::Store::Severity::Info)
      end
    end

    it "rejects a present-but-invalid flow_id instead of silently unlinking" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"x","flow_id":1.9}}})
        resp = drive(store, create)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.should contain("invalid 'flow_id'")
        store.count_issues.should eq(0)
      end
    end

    it "distinguishes a fractional id (invalid) from a missing id" do
      with_store do |store|
        bad = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":1.9}}})
        drive(store, bad)[0]["result"]["content"][0]["text"].as_s.should contain("invalid 'id'")
        missing = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_flow","arguments":{}}})
        drive(store, missing)[0]["result"]["content"][0]["text"].as_s.should contain("missing required 'id'")
      end
    end

    it "reports an error (not updated:true) when update_issue has no fields" do
      with_store do |store|
        store.insert_issue("f", Gori::Store::Severity::Info, nil, nil)
        store.flush
        id = store.issues.first.id
        upd = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"update_issue","arguments":{"id":#{id}}}})
        resp = drive(store, upd)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.should contain("no fields to update")
      end
    end

    it "rejects write tools in read-only mode" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"x"}}})
        resp = drive(store, create, allow_actions: false)[0]
        resp["result"]["isError"].as_bool.should be_true
        store.count_issues.should eq(0)
      end
    end
  end

  describe "ql_reference" do
    it "returns the QL syntax reference" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ql_reference","arguments":{}}})
        ref = tool_payload(drive(store, call)[0])["reference"].as_s
        ref.should contain("host:example.com")
        ref.should contain("status:>=500")
      end
    end
  end

  describe "decoder" do
    it "runs a converter chain and returns the decoded output" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"decode","arguments":{"input":"aGVsbG8=","spec":"base64-decode"}}})
        payload = tool_payload(drive(store, call)[0])
        payload["output"].as_s.should eq("hello")
        payload["output_encoding"].as_s.should eq("text")
        payload["steps"].as_a.size.should eq(1)
      end
    end

    it "reports an unknown converter as an error and enumerates the registry" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"decode","arguments":{"input":"x","spec":"nope-bogus"}}})
        resp = drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true
        text = resp["result"]["content"][0]["text"].as_s
        text.should contain("unknown converter")
        text.should contain("base64-decode")
      end
    end

    it "is available in read-only mode (pure transform, no gating)" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"decode","arguments":{"input":"hi","spec":"sha256"}}})
        resp = drive(store, call, allow_actions: false)[0]
        resp["result"]["isError"]?.should_not eq(true)
        tool_payload(resp)["output"].as_s.size.should eq(64)
      end
    end

    it "rejects a separator-only spec instead of echoing the input as a phantom success" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"decode","arguments":{"input":"hello","spec":">"}}})
        resp = drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.should contain("no converter tokens")
      end
    end
  end

  describe "match&replace rules" do
    it "creates, lists, toggles, and deletes a rule" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_rule","arguments":{"pattern":"secret","replacement":"REDACTED","target":"response","part":"body"}}})
        id = tool_payload(drive(store, create)[0])["id"].as_i64
        id.should_not eq(0)

        listed = tool_payload(drive(store, %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_rules"}}))[0])
        listed["count"].as_i64.should eq(1)
        rule = listed["rules"][0]
        rule["pattern"].as_s.should eq("secret")
        rule["target"].as_s.should eq("response")
        rule["part"].as_s.should eq("body")
        rule["enabled"].as_bool.should be_true

        toggle = %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"set_rule_enabled","arguments":{"id":#{id},"enabled":false}}})
        tool_payload(drive(store, toggle)[0])["enabled"].as_bool.should be_false
        store.match_rules[0].enabled?.should be_false

        del = %({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"delete_rule","arguments":{"id":#{id}}}})
        tool_payload(drive(store, del)[0])["deleted"].as_bool.should be_true
        store.match_rules.should be_empty
      end
    end

    it "rejects an invalid target on create (persists nothing)" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_rule","arguments":{"pattern":"x","target":"sideways"}}})
        resp = drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true
        store.match_rules.should be_empty
      end
    end

    it "reports an error for delete/toggle of an unknown rule id" do
      with_store do |store|
        del = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"delete_rule","arguments":{"id":999}}})
        drive(store, del)[0]["result"]["isError"].as_bool.should be_true
      end
    end

    it "gates rule write tools in read-only mode but keeps list_rules" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_rule","arguments":{"pattern":"x"}}})
        drive(store, create, allow_actions: false)[0]["result"]["isError"].as_bool.should be_true
        store.match_rules.should be_empty

        listed = tool_payload(drive(store, %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_rules"}}), allow_actions: false)[0])
        listed["count"].as_i64.should eq(0)
      end
    end
  end

  describe "create_repeater and update_repeater" do
    it "creates a new repeater from raw payload and returns context fields" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_repeater","arguments":{"target":"https://api.test","request":"GET /x HTTP/1.1\\r\\nHost: api.test\\r\\n\\r\\n","name":"My Repeater Tab"}}})
        resp = drive(store, call)[0]
        resp["result"]["isError"]?.should_not eq(true)
        payload = tool_payload(resp)
        payload["id"].as_i64.should_not eq(0)
        payload["name"].as_s.should eq("My Repeater Tab")
        payload["target"].as_s.should eq("https://api.test")
        payload["summary"].as_s.should eq("GET /x")
        payload["position"].as_i64.should eq(0)

        # Let's test update_repeater
        id = payload["id"].as_i64
        upd_call = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"update_repeater","arguments":{"id":#{id},"target":"https://updated.test","name":"Updated Name"}}})
        resp2 = drive(store, upd_call)[0]
        resp2["result"]["isError"]?.should_not eq(true)
        payload2 = tool_payload(resp2)
        payload2["id"].as_i64.should eq(id)
        payload2["name"].as_s.should eq("Updated Name")
        payload2["target"].as_s.should eq("https://updated.test")
        payload2["summary"].as_s.should eq("GET /x")
      end
    end

    it "creates a new repeater from a flow_id" do
      with_store do |store|
        flow_id = seed_flow(store, "ex.test", "GET", "/flow-endpoint", 200)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_repeater","arguments":{"flow_id":#{flow_id}}}})
        payload = tool_payload(drive(store, call)[0])
        payload["target"].as_s.should eq("https://ex.test")
        payload["summary"].as_s.should eq("GET /flow-endpoint")
      end
    end

    it "creates a new repeater from a issue_id" do
      with_store do |store|
        flow_id = seed_flow(store, "ex.test", "POST", "/submit", 200)
        store.insert_issue("Vuln Title", Gori::Store::Severity::High, "ex.test", flow_id)
        store.flush
        issue_id = store.issues.first.id

        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_repeater","arguments":{"issue_id":#{issue_id}}}})
        payload = tool_payload(drive(store, call)[0])
        payload["target"].as_s.should eq("https://ex.test")
        payload["summary"].as_s.should eq("POST /submit")
        links = store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id)
        links.any? { |link| link.ref_kind.repeater? && link.ref_id == payload["id"].as_i64 }.should be_true
      end
    end
  end

  describe "get_repeater_context" do
    it "lists persisted repeater sessions with last response status" do
      with_store do |store|
        store.insert_repeater("https://ex.test", "GET /x HTTP/1.1\nHost: ex.test\n\n", false, true, nil, 0)
        id = store.repeaters_meta.last.id
        store.update_repeater_response(id, "HTTP/1.1 400 Bad\r\n\r\n".to_slice, "nope".to_slice, nil, 99_i64)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_repeater_context","arguments":{}}})
        payload = tool_payload(drive(store, call)[0])
        payload["sessions"].as_a.size.should eq(1)
        sess = payload["sessions"][0]
        sess["db_id"].as_i64.should eq(id)
        sess["last_status"].as_i64.should eq(400)
        sess.as_h.has_key?("request").should be_false
        sess.as_h.has_key?("last_response_head").should be_false
        payload["content_included"].as_bool.should be_false

        with_content = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_repeater_context","arguments":{"id":#{id},"include_content":true}}})
        detailed = tool_payload(drive(store, with_content)[0])
        detailed["sessions"].as_a.size.should eq(1)
        detailed["sessions"][0]["request"].as_s.should contain("GET /x")
        detailed["sessions"][0]["last_response_head"].as_s.should contain("400 Bad")
      end
    end

    it "base64-encodes a binary WebSocket frame (keeps the JSON-RPC stream valid UTF-8)" do
      with_store do |store|
        store.insert_repeater("wss://ex.test/ws",
          "GET /ws HTTP/1.1\r\nHost: ex.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n", false, true, nil, 0)
        id = store.repeaters_meta.last.id
        store.insert_ws_message(0_i64, "out", 1, "ping".to_slice, repeater_id: id)        # text frame
        store.insert_ws_message(0_i64, "in", 2, Bytes[0x00, 0xff, 0x80], repeater_id: id) # binary (invalid UTF-8)
        store.flush
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_repeater_context","arguments":{"include_content":true}}})
        msgs = tool_payload(drive(store, call)[0])["sessions"][0]["ws_messages"].as_a
        text = msgs.find { |m| m["opcode"].as_i == 1 }.not_nil!
        text["payload"].as_s.should eq("ping")
        bin = msgs.find { |m| m["opcode"].as_i == 2 }.not_nil!
        bin["binary"].as_bool.should be_true
        bin["payload_base64"].as_s.should eq(Base64.strict_encode(Bytes[0x00, 0xff, 0x80]))
        bin.as_h.has_key?("payload").should be_false # raw bytes never emitted as a string
      end
    end

    it "includes the live TUI repeater snapshot when ui_state carries it" do
      with_store do |store|
        ui = JSON.build do |j|
          j.object do
            j.field "active_tab", "repeater"
            j.field "focus_pane", "body"
            j.field "subtab", 0
            j.field "repeater" do
              j.object do
                j.field "count", 1
                j.field "active_subtab", 0
                j.field "active" do
                  j.object do
                    j.field "subtab", 0
                    j.field "db_id", 7
                    j.field "target", "https://ex.test"
                    j.field "http2", true
                    j.field "request", "GET /gw HTTP/2"
                  end
                end
              end
            end
          end
        end
        store.set_setting(Gori::Store::UI_STATE_KEY, ui)
        metadata = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_repeater_context","arguments":{}}})
        metadata_payload = tool_payload(drive(store, metadata, project_name: "demo", project_slug: "demo")[0])
        metadata_payload.as_h.has_key?("tui_repeater").should be_false
        metadata_payload["tui_repeater_available"].as_bool.should be_true

        call = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_repeater_context","arguments":{"include_content":true}}})
        payload = tool_payload(drive(store, call, project_name: "demo", project_slug: "demo")[0])
        payload["tui_on_repeater_tab"].as_bool.should be_true
        payload["tui_repeater"]["active"]["http2"].as_bool.should be_true
        payload["project_slug"].as_s.should eq("demo")
      end
    end
  end

  describe "get_current_context" do
    it "reports a non-object ui_state as unreadable, not a raw tool error" do
      with_store do |store|
        store.set_setting(Gori::Store::UI_STATE_KEY, "[1,2,3]") # valid JSON, wrong shape
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_current_context","arguments":{}}})
        resp = drive(store, call)[0]
        resp["result"]["isError"]?.try(&.as_bool?).should_not eq(true) # was: "tool error: Expected Hash…"
        payload = tool_payload(resp)
        payload["available"].as_bool.should be_false
        payload["note"].as_s.should contain("unreadable")
      end
    end

    it "reads a well-formed ui_state object" do
      with_store do |store|
        store.set_setting(Gori::Store::UI_STATE_KEY, %({"active_tab":"history","focus_pane":"body"}))
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_current_context","arguments":{}}})
        payload = tool_payload(drive(store, call)[0])
        payload["available"].as_bool.should be_true
        payload["active_tab"].as_s.should eq("history")
      end
    end
  end

  describe "project_info" do
    it "includes project metadata fields" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"project_info","arguments":{}}})
        response = drive(store, call, project_name: "demo", project_slug: "demo")[0]
        info = tool_payload(response)
        info["flows"].as_i.should eq(0)
        info["read_only"].as_bool.should be_false
        # Modern MCP clients get parsed data directly; content[0].text remains
        # for backward compatibility.
        response["result"]["structuredContent"]["project"].as_s.should eq("demo")
      end
    end
  end

  describe "send_request" do
    it "records a successful request in History by default and redacts sensitive response headers" do
      with_store do |store|
        port = start_mcp_http_origin("hello", "Set-Cookie: session=top-secret\r\n")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/audit"}}})
        resp = drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_false
        payload = tool_payload(resp)
        flow_id = payload["recorded_flow_id"].as_i64
        payload["headers"].as_a.find { |header| header["name"].as_s == "Set-Cookie" }.not_nil!["value"].as_s.should eq("[REDACTED]")
        payload["sensitive_headers_redacted"].as_bool.should be_true
        detail = store.get_flow(flow_id).not_nil!
        detail.row.target.should eq("/audit")
        detail.row.status.should eq(200)
        String.new(detail.response_body.not_nil!).should eq("hello")
      end
    end

    it "allows an explicit unaudited send and an explicit sensitive-header response" do
      with_store do |store|
        port = start_mcp_http_origin("ok", "Set-Cookie: session=visible\r\n")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/","record_history":false,"include_sensitive_headers":true}}})
        payload = tool_payload(drive(store, call, verify_upstream: false)[0])
        payload["recorded_flow_id"].raw.should be_nil
        payload["headers"].as_a.find { |header| header["name"].as_s == "Set-Cookie" }.not_nil!["value"].as_s.should eq("session=visible")
        store.count.should eq(0)
      end
    end

    it "pages the complete stored response after the inline body is truncated" do
      with_store do |store|
        body = "a" * (Gori::MCP::Serialize::MAX_TEXT + 4096)
        port = start_mcp_http_origin(body)
        send = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/big"}}})
        sent = tool_payload(drive(store, send, verify_upstream: false)[0])
        sent["body"]["truncated"].as_bool.should be_true
        flow_id = sent["recorded_flow_id"].as_i64

        chunk_call = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_response_body_chunk","arguments":{"flow_id":#{flow_id},"offset":#{Gori::MCP::Serialize::MAX_TEXT},"limit":4096}}})
        chunk = tool_payload(drive(store, chunk_call)[0])
        chunk["returned_bytes"].as_i.should eq(4096)
        chunk["complete"].as_bool.should be_true
        chunk["text"].as_s.should eq("a" * 4096)
      end
    end

    it "repeaters a captured flow via flow_id without a url" do
      with_store do |store|
        id = seed_flow(store, "ex.test", "GET", "/repeater-me", 200)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"flow_id":#{id}}}})
        resp = drive(store, call, verify_upstream: false)[0]
        # May fail to connect in CI, but must NOT error with 'url is required'.
        resp["result"]["content"][0]["text"].as_s.should_not contain("'url' is required")
      end
    end

    it "honors an explicit http2:false to downgrade an h2-captured flow to HTTP/1.1" do
      with_store do |store|
        port = start_mcp_http_origin("downgraded")
        # A flow captured over h2 (http_version HTTP/2). Sending it to this HTTP/1.1
        # origin only succeeds if http2:false actually downgrades the transport — the
        # bug was `http2 = bool(h,"http2") || flow.http2`, where an explicit false was
        # OR'd away and the send stayed h2 (h2c to an h1 origin, which fails).
        id = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "http", host: "127.0.0.1", port: port,
          method: "GET", target: "/h2flow", http_version: "HTTP/2",
          head: "GET /h2flow HTTP/2\r\nHost: 127.0.0.1:#{port}\r\n\r\n".to_slice, body: nil))
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"flow_id":#{id},"http2":false}}})
        resp = drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_false
        tool_payload(resp)["status"].as_i.should eq(200)
      end
    end

    it "returns isError on a connection failure (port 1)" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:1/"}}})
        resp = drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true
        payload = tool_payload(resp)
        payload["error"].as_s.downcase.should contain("fail")
        store.get_flow(payload["recorded_flow_id"].as_i64).not_nil!.row.state.error?.should be_true
      end
    end

    it "links a saved repeater to an issue even when the origin is unavailable" do
      with_store do |store|
        issue_id = store.insert_issue("evidence", Gori::Store::Severity::Low, nil, nil)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:1/","save_as_repeater":true,"issue_id":#{issue_id}}}})
        drive(store, call)[0]["result"]["isError"].as_bool.should be_true
        repeater_id = store.repeaters_meta.last.id
        links = store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id)
        links.any? { |link| link.ref_kind.repeater? && link.ref_id == repeater_id }.should be_true
      end
    end

    it "includes effective_request on a url send (no ignored fields)" do
      with_store do |store|
        port = start_mcp_http_origin("ok")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/path","method":"POST"}}})
        p = tool_payload(drive(store, call, verify_upstream: false)[0])
        er = p["effective_request"]
        er["scheme"].as_s.should eq("http")
        er["host"].as_s.should eq("127.0.0.1")
        er["port"].as_i.should eq(port)
        er["method"].as_s.should eq("POST")
        er["target"].as_s.should eq("/path")
        p.as_h.has_key?("ignored_fields").should be_false
      end
    end

    it "reports ignored_fields + effective_request when flow_id overrides url/method" do
      with_store do |store|
        id = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "http", host: "127.0.0.1", port: 1,
          method: "GET", target: "/seed", http_version: "HTTP/1.1",
          head: "GET /seed HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n".to_slice, body: nil))
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"flow_id":#{id},"url":"http://ignored.test/x","method":"POST"}}})
        p = tool_payload(drive(store, call)[0]) # send fails fast (127.0.0.1:1), payload still carries the fields
        p["effective_request"]["host"].as_s.should eq("127.0.0.1")
        p["effective_request"]["target"].as_s.should eq("/seed")
        p["effective_request"]["method"].as_s.should eq("GET") # from the flow, not the ignored POST
        ignored = p["ignored_fields"].as_a.map(&.as_s)
        ignored.should contain("url")
        ignored.should contain("method")
        p["precedence_warning"].as_s.should contain("flow_id")
      end
    end
  end

  describe "scope enforcement (active tools)" do
    it "flags an unscoped send but still sends when no scope is configured" do
      with_store do |store|
        port = start_mcp_http_origin("ok")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/"}}})
        p = tool_payload(drive(store, call, verify_upstream: false)[0])
        p["scope_decision"].as_s.should eq("unscoped")
        p["effective_host"].as_s.should eq("127.0.0.1")
      end
    end

    it "reports in_scope with the matched rule id when the host is included" do
      with_store do |store|
        store.add_scope_rule("include", "host", "127.0.0.1")
        port = start_mcp_http_origin("ok")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/"}}})
        p = tool_payload(drive(store, call, verify_upstream: false)[0])
        p["scope_decision"].as_s.should eq("in_scope")
        p["scope_rule_id"].as_i64.should be > 0
      end
    end

    it "blocks an out-of-scope send without sending or recording" do
      with_store do |store|
        store.add_scope_rule("include", "host", "example.com")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:1/"}}})
        resp = drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["error_code"].as_s.should eq("SCOPE_BLOCKED")
        store.count.should eq(0) # refused before any History write
      end
    end

    it "allows an out-of-scope send with allow_unscoped:true" do
      with_store do |store|
        store.add_scope_rule("include", "host", "example.com")
        port = start_mcp_http_origin("ok")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/","allow_unscoped":true}}})
        p = tool_payload(drive(store, call, verify_upstream: false)[0])
        p["scope_decision"].as_s.should eq("out_of_scope")
      end
    end
  end

  describe "send_websocket" do
    it "performs the upgrade and returns the inbound frame transcript" do
      with_store do |store|
        port = start_mcp_ws_origin
        request = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
        repeater_id = store.insert_repeater("ws://127.0.0.1:#{port}", request, false, true, nil, 0)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_websocket","arguments":{"repeater_id":#{repeater_id},"messages":["ping"],"idle_ms":100}}})
        resp = drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_false
        payload = tool_payload(resp)
        payload["upgraded"].as_bool.should be_true
        payload["handshake_status"].as_i.should eq(101)
        payload["close_code"].as_i.should eq(1000)
        payload["messages"].as_a.map { |message| {message["direction"].as_s, message["payload"].as_s} }
          .should eq([{"out", "ping"}, {"in", "ping"}])
        store.repeaters.find(&.id.==(repeater_id)).not_nil!.response_head.should_not be_nil
      end
    end

    it "rejects a non-WebSocket repeater before making a connection" do
      with_store do |store|
        repeater_id = store.insert_repeater("http://127.0.0.1:1", "GET / HTTP/1.1\r\nHost: x\r\n\r\n", false, true, nil, 0)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_websocket","arguments":{"repeater_id":#{repeater_id}}}})
        resp = drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.should contain("not a WebSocket")
      end
    end

    it "uses the WebSocket engine and returns a clean connection error" do
      with_store do |store|
        repeater_id = store.insert_repeater("ws://127.0.0.1:1", "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n", false, true, nil, 0)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_websocket","arguments":{"repeater_id":#{repeater_id},"messages":["ping"],"idle_ms":100}}})
        resp = drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_true
        payload = tool_payload(resp)
        payload["repeater_id"].as_i64.should eq(repeater_id)
        payload["upgraded"].as_bool.should be_false
        payload["error"].as_s.should contain("connect failed")
      end
    end
  end

  describe "list_issues" do
    it "returns a paginated object (not a bare array)" do
      with_store do |store|
        store.insert_issue("a", Gori::Store::Severity::Info, nil, nil)
        store.insert_issue("b", Gori::Store::Severity::High, nil, nil)
        store.flush
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_issues","arguments":{"limit":1,"offset":1}}})
        payload = tool_payload(drive(store, call)[0])
        payload.as_h.has_key?("issues").should be_true
        payload["returned"].as_i.should eq(1)
        payload["offset"].as_i.should eq(1)
        payload["total"].as_i.should eq(2)
      end
    end
  end

  describe "error channels" do
    it "returns -32600 with echoed id when method is missing" do
      with_store do |store|
        out = drive(store, %({"jsonrpc":"2.0","id":"req-1"}))
        out[0]["error"]["code"].as_i.should eq(-32600)
        out[0]["id"].as_s.should eq("req-1")
      end
    end

    it "answers a parse error with id null and keeps serving" do
      with_store do |store|
        out = drive(store, "{not json", %({"jsonrpc":"2.0","id":1,"method":"ping"}))
        out[0]["error"]["code"].as_i.should eq(-32700)
        out[0]["id"].raw.should be_nil
        out[1]["result"].as_h.should be_empty # loop recovered
      end
    end

    it "returns -32601 for an unknown method" do
      with_store do |store|
        out = drive(store, %({"jsonrpc":"2.0","id":1,"method":"bogus/method"}))
        out[0]["error"]["code"].as_i.should eq(-32601)
      end
    end

    it "returns isError (not a protocol error) for an unknown tool" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nope","arguments":{}}})
        resp = drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["error"]?.should be_nil
      end
    end
  end

  describe "structured error contract" do
    it "codes an unknown tool UNKNOWN_TOOL with a structured error object" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nope","arguments":{}}})
        err = drive(store, call)[0]["result"]["structuredContent"]
        err["error_code"].as_s.should eq("UNKNOWN_TOOL")
        err["message"].as_s.should contain("nope")
        err["retryable"].as_bool.should be_false
      end
    end

    it "codes a missing/invalid id INVALID_ARGUMENT (the residual default)" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_flow","arguments":{}}})
        err = drive(store, call)[0]["result"]["structuredContent"]
        err["error_code"].as_s.should eq("INVALID_ARGUMENT")
      end
    end

    it "codes a bad flow id NOT_FOUND" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":9999}}})
        err = drive(store, call)[0]["result"]["structuredContent"]
        err["error_code"].as_s.should eq("NOT_FOUND")
      end
    end

    it "codes a query that compiles to nothing QUERY_SYNTAX with field:query" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{"query":"status:>=foo"}}})
        err = drive(store, call)[0]["result"]["structuredContent"]
        err["error_code"].as_s.should eq("QUERY_SYNTAX")
        err["field"].as_s.should eq("query")
      end
    end

    it "codes a disabled action tool TOOL_DISABLED in read-only mode" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"x"}}})
        err = drive(store, call, allow_actions: false)[0]["result"]["structuredContent"]
        err["error_code"].as_s.should eq("TOOL_DISABLED")
      end
    end

    it "leaves a success payload's structuredContent unchanged (no error object)" do
      with_store do |store|
        seed_flow(store, "h.test", "GET", "/a", 200)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{}}})
        resp = drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_false
        resp["structuredContent"].as_h.has_key?("error_code").should be_false
      end
    end
  end

  describe "sensitive header redaction" do
    it "redacts auth headers in get_flow, reveals them with include_sensitive" do
      with_store do |store|
        id = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "https", host: "h.test", port: 443,
          method: "GET", target: "/", http_version: "HTTP/1.1",
          head: "GET / HTTP/1.1\r\nHost: h.test\r\nAuthorization: Bearer topsecret\r\nCookie: sid=abc\r\n\r\n".to_slice,
          body: nil))
        store.update_response(Gori::Store::CapturedResponse.new(
          flow_id: id, status: 200,
          head: "HTTP/1.1 200 OK\r\nSet-Cookie: sid=xyz\r\nContent-Type: text/plain\r\n\r\n".to_slice, body: nil))

        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":#{id}}}})
        p = tool_payload(drive(store, call)[0])
        p["request_head"].as_s.should contain("Authorization: [REDACTED]")
        p["request_head"].as_s.should contain("Cookie: [REDACTED]")
        p["request_head"].as_s.should_not contain("topsecret")
        p["request_head"].as_s.should_not contain("sid=abc")
        p["request_head"].as_s.should contain("Host: h.test") # non-sensitive kept
        p["response_head"].as_s.should contain("Set-Cookie: [REDACTED]")
        p["response_head"].as_s.should_not contain("sid=xyz")
        p["sensitive_headers_redacted"].as_bool.should be_true

        rawc = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":#{id},"include_sensitive":true}}})
        raw = tool_payload(drive(store, rawc)[0])
        raw["request_head"].as_s.should contain("Bearer topsecret")
        raw["request_head"].as_s.should contain("sid=abc")
        raw.as_h.has_key?("sensitive_headers_redacted").should be_false
      end
    end

    it "redacts auth headers in get_repeater_context content" do
      with_store do |store|
        rid = store.insert_repeater(target: "https://h.test",
          request: "GET / HTTP/1.1\r\nHost: h.test\r\nAuthorization: Bearer topsecret\r\n\r\n",
          http2: false, auto_cl: true, flow_id: nil, position: 0, sni: nil, mark_transform: false)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_repeater_context","arguments":{"id":#{rid},"include_content":true}}})
        p = tool_payload(drive(store, call)[0])
        p["sensitive_headers_redacted"].as_bool.should be_true
        sess = p["sessions"][0]
        sess["request"].as_s.should contain("Authorization: [REDACTED]")
        sess["request"].as_s.should_not contain("topsecret")

        rawc = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_repeater_context","arguments":{"id":#{rid},"include_content":true,"include_sensitive":true}}})
        raw = tool_payload(drive(store, rawc)[0])
        raw["sessions"][0]["request"].as_s.should contain("Bearer topsecret")
      end
    end
  end
end

describe Gori::MCP::Serialize do
  it "inlines short UTF-8 as text" do
    out = JSON.parse(JSON.build { |j| j.object { Gori::MCP::Serialize.emit_body(j, "body", nil, "hi".to_slice, false) } })
    out["body"]["encoding"].as_s.should eq("text")
    out["body"]["text"].as_s.should eq("hi")
    out["body"]["truncated"].as_bool.should be_false
  end

  it "truncates over-cap UTF-8 and flags it" do
    big = ("a" * (Gori::MCP::Serialize::MAX_TEXT + 100)).to_slice
    out = JSON.parse(JSON.build { |j| j.object { Gori::MCP::Serialize.emit_body(j, "body", nil, big, false) } })
    out["body"]["truncated"].as_bool.should be_true
    out["body"]["text"].as_s.bytesize.should eq(Gori::MCP::Serialize::MAX_TEXT)
  end

  it "emits null for an empty body" do
    out = JSON.parse(JSON.build { |j| j.object { Gori::MCP::Serialize.emit_body(j, "body", nil, nil, false) } })
    out["body"].raw.should be_nil
  end

  it "scrubs a malformed head to valid UTF-8 (no stream corruption)" do
    text = Gori::MCP::Serialize.head_text(Bytes[0xff, 0x41, 0xfe]).not_nil!
    text.valid_encoding?.should be_true
    text.should contain("A")
  end

  it "flags a repeater result as incomplete when the origin cut the body short" do
    head = "HTTP/1.1 200 OK\r\n\r\n".to_slice
    r = Gori::Repeater::Result.new(head, "hi".to_slice, nil, 1000_i64, incomplete: true)
    out = JSON.parse(Gori::MCP::Serialize.repeater_result_json(r))
    out["incomplete"].as_bool.should be_true
  end

  it "omits the incomplete field for a complete repeater result" do
    head = "HTTP/1.1 200 OK\r\n\r\n".to_slice
    r = Gori::Repeater::Result.new(head, "hi".to_slice, nil, 1000_i64)
    out = JSON.parse(Gori::MCP::Serialize.repeater_result_json(r))
    out["incomplete"]?.should be_nil
  end
end

describe Gori::MCP::RequestBuilder do
  it "builds exact request bytes with Host + Content-Length" do
    args = JSON.parse(%({"url":"https://h.test:8443/a?b=1","method":"post","headers":{"X-Test":"y"},"body":"hi"})).as_h
    built = Gori::MCP::RequestBuilder.build(args)
    built.scheme.should eq("https")
    built.host.should eq("h.test")
    built.port.should eq(8443)
    String.new(built.bytes).should eq("POST /a?b=1 HTTP/1.1\r\nX-Test: y\r\nHost: h.test:8443\r\nContent-Length: 2\r\n\r\nhi")
  end

  it "omits the port from Host when it is the scheme default" do
    args = JSON.parse(%({"url":"http://h.test/"})).as_h
    built = Gori::MCP::RequestBuilder.build(args)
    built.port.should eq(80)
    String.new(built.bytes).should eq("GET / HTTP/1.1\r\nHost: h.test\r\n\r\n")
  end

  it "defaults an empty path to /" do
    args = JSON.parse(%({"url":"https://h.test"})).as_h
    String.new(Gori::MCP::RequestBuilder.build(args).bytes).should start_with("GET / HTTP/1.1\r\n")
  end

  it "passes a raw request through, normalising the header block's LFs to CRLF" do
    raw = "GET /x HTTP/1.1\nHost: h.test\n\n" # real LFs, as a JSON-parsed raw value carries
    args = {"url" => JSON::Any.new("http://h.test/"), "raw" => JSON::Any.new(raw)}
    String.new(Gori::MCP::RequestBuilder.build(args).bytes).should eq("GET /x HTTP/1.1\r\nHost: h.test\r\n\r\n")
  end

  it "keeps the raw body byte-exact (bare LFs in the body are NOT rewritten)" do
    raw = "POST /x HTTP/1.1\nContent-Length: 5\n\na\nb\nc" # body 'a\nb\nc' = 5 bytes
    args = {"url" => JSON::Any.new("http://h.test/"), "raw" => JSON::Any.new(raw)}
    out = String.new(Gori::MCP::RequestBuilder.build(args).bytes)
    out.should eq("POST /x HTTP/1.1\r\nContent-Length: 5\r\n\r\na\nb\nc") # head CRLF, body LFs intact
  end

  it "raises when the url has no host" do
    args = JSON.parse(%({"url":"/relative"})).as_h
    expect_raises(Gori::Error) { Gori::MCP::RequestBuilder.build(args) }
  end

  it "raises a clean Gori::Error (not a leaked URI::Error) for a malformed authority" do
    args = JSON.parse(%({"url":"https://h.test:abc/"})).as_h
    expect_raises(Gori::Error, /invalid url/) { Gori::MCP::RequestBuilder.build(args) }
  end

  it "rejects an out-of-range port instead of dialing a doomed connect" do
    args = JSON.parse(%({"url":"https://h.test:99999/"})).as_h
    expect_raises(Gori::Error, /invalid port/) { Gori::MCP::RequestBuilder.build(args) }
  end

  describe "structured-path injection guards" do
    it "rejects CR/LF in a header value (header injection)" do
      args = {"url"     => JSON::Any.new("http://h.test/"),
              "headers" => JSON::Any.new({"X-Inj" => JSON::Any.new("a\r\nX-Evil: 1")})}
      expect_raises(Gori::Error, /header.*X-Inj/) { Gori::MCP::RequestBuilder.build(args) }
    end

    it "rejects a bare LF in a header value (lenient origins split on LF)" do
      args = {"url"     => JSON::Any.new("http://h.test/"),
              "headers" => JSON::Any.new({"X-LF" => JSON::Any.new("a\nX-Evil: 1")})}
      expect_raises(Gori::Error) { Gori::MCP::RequestBuilder.build(args) }
    end

    it "rejects CR/LF in a header name" do
      args = {"url"     => JSON::Any.new("http://h.test/"),
              "headers" => JSON::Any.new({"X-A\r\nX-S" => JSON::Any.new("1")})}
      expect_raises(Gori::Error, /header name/) { Gori::MCP::RequestBuilder.build(args) }
    end

    it "rejects an empty header name" do
      args = {"url"     => JSON::Any.new("http://h.test/"),
              "headers" => JSON::Any.new({"" => JSON::Any.new("v")})}
      expect_raises(Gori::Error, /empty/) { Gori::MCP::RequestBuilder.build(args) }
    end

    it "rejects a non-token char (':') in a header name (would emit a 2nd Content-Length)" do
      # "Content-Length:0" evades the case-insensitive dedup and is written as
      # `Content-Length:0: x` next to the auto Content-Length — two conflicting lines.
      args = {"url"     => JSON::Any.new("http://h.test/"),
              "method"  => JSON::Any.new("POST"),
              "body"    => JSON::Any.new("hi"),
              "headers" => JSON::Any.new({"Content-Length:0" => JSON::Any.new("x")})}
      expect_raises(Gori::Error, /header name/) { Gori::MCP::RequestBuilder.build(args) }
    end

    it "rejects whitespace/CRLF in the method (request-line forgery)" do
      args = {"url"    => JSON::Any.new("http://h.test/"),
              "method" => JSON::Any.new("GET /admin HTTP/1.1\r\nHost: a")}
      expect_raises(Gori::Error, /method/) { Gori::MCP::RequestBuilder.build(args) }
    end

    it "rejects a bare space in the request target (request-line forgery)" do
      # URI.parse keeps the literal space in the path; emitting it would forge
      # `GET /a b HTTP/1.1` — a lenient origin then reads target /a, version b.
      args = {"url" => JSON::Any.new("http://h.test/a b")}
      expect_raises(Gori::Error, /request target/) { Gori::MCP::RequestBuilder.build(args) }
    end

    it "rejects a whitespace-padded header name (framing-dedup evasion)" do
      # A leading space dodges the case-insensitive Content-Length dedup, so the
      # auto length would be appended too — two conflicting lengths on the wire.
      args = {"url"     => JSON::Any.new("http://h.test/"),
              "method"  => JSON::Any.new("POST"),
              "body"    => JSON::Any.new("abc"),
              "headers" => JSON::Any.new({" Content-Length" => JSON::Any.new("0")})}
      expect_raises(Gori::Error, /header name/) { Gori::MCP::RequestBuilder.build(args) }
    end

    it "still allows a custom method and internal spaces in a header VALUE" do
      args = {"url"     => JSON::Any.new("http://h.test/"),
              "method"  => JSON::Any.new("propfind"),
              "headers" => JSON::Any.new({"X-Note" => JSON::Any.new("hello world ok")})}
      out = String.new(Gori::MCP::RequestBuilder.build(args).bytes)
      out.should start_with("PROPFIND / HTTP/1.1\r\n")
      out.should contain("X-Note: hello world ok\r\n")
    end

    it "rejects a URL whose host carries a CR/LF (auto Host-header injection)" do
      # URI.parse keeps the CR/LF as part of the authority's host; left unchecked
      # it would be written verbatim into the generated Host header.
      args = {"url" => JSON::Any.new("http://h.com\r\nEvil:3/path")}
      expect_raises(Gori::Error, /host/) { Gori::MCP::RequestBuilder.build(args) }
    end

    it "leaves the raw path byte-exact (smuggling is the caller's explicit choice)" do
      raw = "GET /x HTTP/1.1\nX-Inj: a\r\nX-Evil: 1\n\n"
      args = {"url" => JSON::Any.new("http://h.test/"), "raw" => JSON::Any.new(raw)}
      # raw mode does NOT validate — it is byte-exact by contract.
      Gori::MCP::RequestBuilder.build(args).should_not be_nil
    end
  end
end
