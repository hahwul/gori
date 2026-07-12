require "./spec_helper"
require "compress/gzip"

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
        names.should contain("get_replay_context")
        names.should contain("send_request")
        names.should contain("create_finding")
        names.should contain("update_finding")
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
        ro_names.should_not contain("create_finding")
        ro_names.should_not contain("update_finding")
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

  describe "findings write tools" do
    it "creates then updates a finding (full mode)" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"create_finding","arguments":{"title":"SQLi in login","severity":"high","host":"app.test"}}})
        new_id = tool_payload(drive(store, create)[0])["id"].as_i64
        store.get_finding(new_id).not_nil!.severity.should eq(Gori::Store::Severity::High)

        update = %({"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"update_finding","arguments":{"id":#{new_id},"status":"confirmed","severity":"critical"}}})
        drive(store, update)[0]["result"]["isError"].as_bool.should be_false
        reloaded = store.get_finding(new_id).not_nil!
        reloaded.status.should eq(Gori::Store::Status::Confirmed)
        reloaded.severity.should eq(Gori::Store::Severity::Critical)
      end
    end

    it "rejects an invalid severity on create (not silently coerced to info)" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_finding","arguments":{"title":"x","severity":"ultra"}}})
        resp = drive(store, create)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.should contain("invalid severity")
        store.count_findings.should eq(0)
      end
    end

    it "defaults an absent severity to info on create" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_finding","arguments":{"title":"x"}}})
        new_id = tool_payload(drive(store, create)[0])["id"].as_i64
        store.get_finding(new_id).not_nil!.severity.should eq(Gori::Store::Severity::Info)
      end
    end

    it "rejects a present-but-invalid flow_id instead of silently unlinking" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_finding","arguments":{"title":"x","flow_id":1.9}}})
        resp = drive(store, create)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.should contain("invalid 'flow_id'")
        store.count_findings.should eq(0)
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

    it "reports an error (not updated:true) when update_finding has no fields" do
      with_store do |store|
        store.insert_finding("f", Gori::Store::Severity::Info, nil, nil)
        store.flush
        id = store.findings.first.id
        upd = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"update_finding","arguments":{"id":#{id}}}})
        resp = drive(store, upd)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.should contain("no fields to update")
      end
    end

    it "rejects write tools in read-only mode" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"create_finding","arguments":{"title":"x"}}})
        resp = drive(store, create, allow_actions: false)[0]
        resp["result"]["isError"].as_bool.should be_true
        store.count_findings.should eq(0)
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

  describe "convert" do
    it "runs a converter chain and returns the decoded output" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"convert","arguments":{"input":"aGVsbG8=","spec":"base64-decode"}}})
        payload = tool_payload(drive(store, call)[0])
        payload["output"].as_s.should eq("hello")
        payload["output_encoding"].as_s.should eq("text")
        payload["steps"].as_a.size.should eq(1)
      end
    end

    it "reports an unknown converter as an error and enumerates the registry" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"convert","arguments":{"input":"x","spec":"nope-bogus"}}})
        resp = drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true
        text = resp["result"]["content"][0]["text"].as_s
        text.should contain("unknown converter")
        text.should contain("base64-decode")
      end
    end

    it "is available in read-only mode (pure transform, no gating)" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"convert","arguments":{"input":"hi","spec":"sha256"}}})
        resp = drive(store, call, allow_actions: false)[0]
        resp["result"]["isError"]?.should_not eq(true)
        tool_payload(resp)["output"].as_s.size.should eq(64)
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

  describe "create_replay and update_replay" do
    it "creates a new replay from raw payload and returns context fields" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_replay","arguments":{"target":"https://api.test","request":"GET /x HTTP/1.1\\r\\nHost: api.test\\r\\n\\r\\n","name":"My Replay Tab"}}})
        resp = drive(store, call)[0]
        resp["result"]["isError"]?.should_not eq(true)
        payload = tool_payload(resp)
        payload["id"].as_i64.should_not eq(0)
        payload["name"].as_s.should eq("My Replay Tab")
        payload["target"].as_s.should eq("https://api.test")
        payload["summary"].as_s.should eq("GET /x")
        payload["position"].as_i64.should eq(0)

        # Let's test update_replay
        id = payload["id"].as_i64
        upd_call = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"update_replay","arguments":{"id":#{id},"target":"https://updated.test","name":"Updated Name"}}})
        resp2 = drive(store, upd_call)[0]
        resp2["result"]["isError"]?.should_not eq(true)
        payload2 = tool_payload(resp2)
        payload2["id"].as_i64.should eq(id)
        payload2["name"].as_s.should eq("Updated Name")
        payload2["target"].as_s.should eq("https://updated.test")
        payload2["summary"].as_s.should eq("GET /x")
      end
    end

    it "creates a new replay from a flow_id" do
      with_store do |store|
        flow_id = seed_flow(store, "ex.test", "GET", "/flow-endpoint", 200)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_replay","arguments":{"flow_id":#{flow_id}}}})
        payload = tool_payload(drive(store, call)[0])
        payload["target"].as_s.should eq("https://ex.test")
        payload["summary"].as_s.should eq("GET /flow-endpoint")
      end
    end

    it "creates a new replay from a finding_id" do
      with_store do |store|
        flow_id = seed_flow(store, "ex.test", "POST", "/submit", 200)
        store.insert_finding("Vuln Title", Gori::Store::Severity::High, "ex.test", flow_id)
        store.flush
        finding_id = store.findings.first.id

        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_replay","arguments":{"finding_id":#{finding_id}}}})
        payload = tool_payload(drive(store, call)[0])
        payload["target"].as_s.should eq("https://ex.test")
        payload["summary"].as_s.should eq("POST /submit")
      end
    end
  end

  describe "get_replay_context" do
    it "lists persisted replay sessions with last response status" do
      with_store do |store|
        store.insert_replay("https://ex.test", "GET /x HTTP/1.1\nHost: ex.test\n\n", false, true, nil, 0)
        id = store.replays_meta.last.id
        store.update_replay_response(id, "HTTP/1.1 400 Bad\r\n\r\n".to_slice, "nope".to_slice, nil, 99_i64)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_replay_context","arguments":{}}})
        payload = tool_payload(drive(store, call)[0])
        payload["sessions"].as_a.size.should eq(1)
        sess = payload["sessions"][0]
        sess["db_id"].as_i64.should eq(id)
        sess["last_status"].as_i64.should eq(400)
        sess["request"].as_s.should contain("GET /x")
      end
    end

    it "base64-encodes a binary WebSocket frame (keeps the JSON-RPC stream valid UTF-8)" do
      with_store do |store|
        store.insert_replay("wss://ex.test/ws",
          "GET /ws HTTP/1.1\r\nHost: ex.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n", false, true, nil, 0)
        id = store.replays_meta.last.id
        store.insert_ws_message(0_i64, "out", 1, "ping".to_slice, replay_id: id)        # text frame
        store.insert_ws_message(0_i64, "in", 2, Bytes[0x00, 0xff, 0x80], replay_id: id) # binary (invalid UTF-8)
        store.flush
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_replay_context","arguments":{}}})
        msgs = tool_payload(drive(store, call)[0])["sessions"][0]["ws_messages"].as_a
        text = msgs.find { |m| m["opcode"].as_i == 1 }.not_nil!
        text["payload"].as_s.should eq("ping")
        bin = msgs.find { |m| m["opcode"].as_i == 2 }.not_nil!
        bin["binary"].as_bool.should be_true
        bin["payload_base64"].as_s.should eq(Base64.strict_encode(Bytes[0x00, 0xff, 0x80]))
        bin.as_h.has_key?("payload").should be_false # raw bytes never emitted as a string
      end
    end

    it "includes the live TUI replay snapshot when ui_state carries it" do
      with_store do |store|
        ui = JSON.build do |j|
          j.object do
            j.field "active_tab", "replay"
            j.field "focus_pane", "body"
            j.field "subtab", 0
            j.field "replay" do
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
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_replay_context","arguments":{}}})
        payload = tool_payload(drive(store, call, project_name: "demo", project_slug: "demo")[0])
        payload["tui_on_replay_tab"].as_bool.should be_true
        payload["tui_replay"]["active"]["http2"].as_bool.should be_true
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
        info = tool_payload(drive(store, call)[0])
        info["flows"].as_i.should eq(0)
        info["read_only"].as_bool.should be_false
      end
    end
  end

  describe "send_request" do
    it "replays a captured flow via flow_id without a url" do
      with_store do |store|
        id = seed_flow(store, "ex.test", "GET", "/replay-me", 200)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"flow_id":#{id}}}})
        resp = drive(store, call, verify_upstream: false)[0]
        # May fail to connect in CI, but must NOT error with 'url is required'.
        resp["result"]["content"][0]["text"].as_s.should_not contain("'url' is required")
      end
    end

    it "returns isError on a connection failure (port 1)" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:1/"}}})
        resp = drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.downcase.should contain("fail")
      end
    end
  end

  describe "list_findings" do
    it "returns a paginated object (not a bare array)" do
      with_store do |store|
        store.insert_finding("a", Gori::Store::Severity::Info, nil, nil)
        store.insert_finding("b", Gori::Store::Severity::High, nil, nil)
        store.flush
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_findings","arguments":{"limit":1,"offset":1}}})
        payload = tool_payload(drive(store, call)[0])
        payload.as_h.has_key?("findings").should be_true
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

  it "flags a replay result as incomplete when the origin cut the body short" do
    head = "HTTP/1.1 200 OK\r\n\r\n".to_slice
    r = Gori::Replay::Result.new(head, "hi".to_slice, nil, 1000_i64, incomplete: true)
    out = JSON.parse(Gori::MCP::Serialize.replay_result_json(r))
    out["incomplete"].as_bool.should be_true
  end

  it "omits the incomplete field for a complete replay result" do
    head = "HTTP/1.1 200 OK\r\n\r\n".to_slice
    r = Gori::Replay::Result.new(head, "hi".to_slice, nil, 1000_i64)
    out = JSON.parse(Gori::MCP::Serialize.replay_result_json(r))
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
