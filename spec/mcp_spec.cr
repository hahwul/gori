require "./spec_helper"
require "compress/gzip"
require "socket"
require "digest/sha1"
require "base64"
require "openssl/hmac"

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

# Output pipe that dies on the first write (client process vanished). Counts write
# attempts so a test can prove the run loop STOPPED after the broken write rather
# than continuing to process further requests.
private class BrokenOutput < IO
  getter writes = 0

  def read(slice : Bytes) : Int32
    0
  end

  def write(slice : Bytes) : Nil
    @writes += 1
    raise IO::Error.new("broken pipe")
  end
end

# Input pipe that yields one chunk then raises mid-read (connection reset), to
# prove the run loop treats a broken transport as a clean end of session.
private class BrokenInput < IO
  def initialize(@chunk : Bytes)
    @pos = 0
  end

  def read(slice : Bytes) : Int32
    # Serve the whole chunk (across as many reads as gets needs), then blow up on
    # the read that would fetch the NEXT line — the transport died mid-session.
    raise IO::Error.new("connection reset") if @pos >= @chunk.size
    n = Math.min(slice.size, @chunk.size - @pos)
    slice.copy_from(@chunk[@pos, n])
    @pos += n
    n
  end

  def write(slice : Bytes) : Nil
  end
end

describe Gori::MCP::Server do
  describe "transport resilience" do
    it "shuts down cleanly (no unhandled error) when the output pipe breaks mid-write" do
      with_store do |store|
        # Two requests queued; the first response write breaks the pipe. The loop
        # must stop — the second request is never processed (writes stays at 1).
        input = IO::Memory.new("#{INIT}\n#{INIT}\n")
        sink = BrokenOutput.new
        Gori::MCP::Server.new(store,
          allow_actions: true, verify_upstream: false,
          input: input, output: sink).run
        sink.writes.should eq(1)
      end
    end

    it "ends the session cleanly when the input stream raises mid-read" do
      with_store do |store|
        sink = IO::Memory.new
        Gori::MCP::Server.new(store,
          allow_actions: true, verify_upstream: false,
          input: BrokenInput.new("#{INIT}\n".to_slice), output: sink).run
        # The one complete request before the read error was still answered.
        lines = sink.to_s.each_line.reject(&.strip.empty?).to_a
        lines.size.should eq(1)
        JSON.parse(lines[0])["result"]["serverInfo"]["name"].should eq(JSON::Any.new("gori"))
      end
    end
  end

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

  describe "body_mode / max_body_bytes" do
    it "returns body shape only with body_mode:none" do
      with_store do |store|
        id = seed_flow(store, "h.test", "GET", "/b", 200,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n", resp_body: "hello".to_slice)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":#{id},"body_mode":"none"}}})
        body = tool_payload(drive(store, call)[0])["response_body"]
        body["omitted"].as_bool.should be_true
        body["size"].as_i.should eq(5)
        body.as_h.has_key?("text").should be_false
      end
    end

    it "caps the inlined body with max_body_bytes and flags truncation" do
      with_store do |store|
        id = seed_flow(store, "h.test", "GET", "/b", 200,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n", resp_body: "0123456789".to_slice)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":#{id},"max_body_bytes":4}}})
        body = tool_payload(drive(store, call)[0])["response_body"]
        body["text"].as_s.should eq("0123")
        body["truncated"].as_bool.should be_true
        body["size"].as_i.should eq(10)
      end
    end

    it "defaults to full body when unspecified" do
      with_store do |store|
        id = seed_flow(store, "h.test", "GET", "/b", 200,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n", resp_body: "hello".to_slice)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":#{id}}}})
        body = tool_payload(drive(store, call)[0])["response_body"]
        body["text"].as_s.should eq("hello")
        body["truncated"].as_bool.should be_false
      end
    end

    it "treats max_body_bytes:0 as the mode default, not a zero-byte cap" do
      with_store do |store|
        id = seed_flow(store, "h.test", "GET", "/b", 200,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n", resp_body: "hello".to_slice)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":#{id},"max_body_bytes":0}}})
        body = tool_payload(drive(store, call)[0])["response_body"]
        body["text"].as_s.should eq("hello") # full body — not clamped to 0 bytes
        body["truncated"].as_bool.should be_false
      end
    end
  end

  describe "get_response_body_chunk offset validation" do
    it "flags an out-of-range offset instead of silently clamping" do
      with_store do |store|
        id = seed_flow(store, "h.test", "GET", "/b", 200,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n", resp_body: "hello".to_slice)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_response_body_chunk","arguments":{"flow_id":#{id},"offset":9999}}})
        p = tool_payload(drive(store, call)[0])
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
        id = seed_flow(store, "h.test", "GET", "/b", 200,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n", resp_body: "hello".to_slice)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_response_body_chunk","arguments":{"flow_id":#{id},"offset":5}}})
        p = tool_payload(drive(store, call)[0])
        p.as_h.has_key?("offset_out_of_range").should be_false
        p.as_h.has_key?("warning").should be_false
        p["complete"].as_bool.should be_true
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
        repeater_a = store.insert_repeater("https://ex.test", "GET /a HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 0)
        repeater_b = store.insert_repeater("https://ex.test", "GET /b HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 1)
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

  describe "pagination transparency" do
    it "reports has_more and does not flag an in-range limit in list_issues" do
      with_store do |store|
        3.times { |i| store.insert_issue("issue #{i}", Gori::Store::Severity::Low, nil, nil) }
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_issues","arguments":{"limit":2}}})
        p = tool_payload(drive(store, call)[0])
        p["returned"].as_i.should eq(2)
        p["has_more"].as_bool.should be_true
        p.as_h.has_key?("requested_limit").should be_false # 2 is valid → not clamped
      end
    end

    it "echoes requested_limit + a warning when a limit is clamped (0 -> 1)" do
      with_store do |store|
        store.insert_issue("x", Gori::Store::Severity::Low, nil, nil)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_issues","arguments":{"limit":0}}})
        p = tool_payload(drive(store, call)[0])
        p["requested_limit"].as_i.should eq(0)
        p["limit"].as_i.should eq(1)
        p["pagination_warning"].as_s.should contain("clamped")
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

  describe "list_sitemap transport" do
    it "keys endpoints by transport and reports status set + counts; collapse_transport merges" do
      with_store do |store|
        mk = ->(scheme : String, ver : String, status : Int32) do
          id = store.insert_flow(Gori::Store::CapturedRequest.new(
            created_at: 1_i64, scheme: scheme, host: "api.test", port: scheme == "https" ? 443 : 80,
            method: "GET", target: "/x", http_version: ver,
            head: "GET /x HTTP/1.1\r\nHost: api.test\r\n\r\n".to_slice, body: nil))
          store.update_response(Gori::Store::CapturedResponse.new(
            flow_id: id, status: status, head: "HTTP/1.1 #{status}\r\n\r\n".to_slice, body: nil))
        end
        mk.call("http", "HTTP/1.1", 200)
        mk.call("https", "HTTP/1.1", 500)
        mk.call("https", "HTTP/2", 500)

        entries = tool_payload(drive(store, %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_sitemap","arguments":{}}}))[0]).as_a
        entries.size.should eq(3) # http/1.1, https/1.1, https/h2 kept separate
        http = entries.find { |e| e["scheme"].as_s == "http" }.not_nil!
        http["success_count"].as_i.should eq(1)
        http["error_count"].as_i.should eq(0)
        h2 = entries.find { |e| e["http_version"].as_s == "HTTP/2" }.not_nil!
        h2["error_count"].as_i.should eq(1)

        collapsed = tool_payload(drive(store, %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_sitemap","arguments":{"collapse_transport":true}}}))[0]).as_a
        collapsed.size.should eq(1) # merged to one host/method/target
        collapsed[0].as_h.has_key?("scheme").should be_false
      end
    end
  end

  describe "QL strict mode + ql_explain" do
    it "strict:true rejects a query with a silently-dropped term" do
      with_store do |store|
        seed_flow(store, "ex.test", "GET", "/", 200)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{"query":"host:ex.test status:>=foo","strict":true}}})
        resp = drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["error_code"].as_s.should eq("QUERY_SYNTAX")
      end
    end

    it "lenient (default) drops the bad term and still runs the good one" do
      with_store do |store|
        seed_flow(store, "ex.test", "GET", "/", 200)
        seed_flow(store, "other.test", "GET", "/", 200)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{"query":"host:ex.test status:>=foo"}}})
        rows = tool_payload(drive(store, call)[0]).as_a
        rows.size.should eq(1) # host:ex.test applied, bad status term dropped
      end
    end

    it "ql_explain reports applied vs ignored terms without running" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ql_explain","arguments":{"query":"host:ex.test status:>=foo"}}})
        p = tool_payload(drive(store, call)[0])
        p["applied_terms"].as_a.map(&.as_s).should contain("host:ex.test")
        p["ignored_terms"].as_a.map(&.as_s).should contain("status:>=foo")
        p["warnings"].as_a.size.should be > 0
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

  describe "jwt tools" do
    # header {"alg":"HS256","typ":"JWT"}, payload {"sub":"1","admin":false}, key "secret".
    jwt = begin
      h = Base64.urlsafe_encode(%({"alg":"HS256","typ":"JWT"}), padding: false)
      p = Base64.urlsafe_encode(%({"sub":"1","admin":false}), padding: false)
      sig = Base64.urlsafe_encode(OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, "secret", "#{h}.#{p}"), padding: false)
      "#{h}.#{p}.#{sig}"
    end

    it "jwt_decode returns header/payload/signature (read-only, no gating)" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jwt_decode","arguments":{"token":"#{jwt}"}}})
        resp = drive(store, call, allow_actions: false)[0]
        resp["result"]["isError"]?.should_not eq(true)
        payload = tool_payload(resp)
        payload["alg"].as_s.should eq("HS256")
        payload["header"]["typ"].as_s.should eq("JWT")
        payload["payload"]["sub"].as_s.should eq("1")
        payload["signed"].as_bool.should be_true
      end
    end

    it "jwt_encode re-signs and the signature verifies with the given secret" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jwt_encode","arguments":{"token":"#{jwt}","alg":"HS256","secret":"hunter2"}}})
        token = tool_payload(drive(store, call)[0])["token"].as_s
        header, body, sig = token.split('.')
        Gori::Jwt.sign("#{header}.#{body}", "HS256", "hunter2").should eq(sig)
      end
    end

    it "jwt_encode signs a payload-only request (no token/header) instead of erroring" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jwt_encode","arguments":{"payload":"{\\"user\\":\\"admin\\"}","secret":"test"}}})
        resp = drive(store, call)[0]
        resp["result"]["isError"]?.try(&.as_bool).should_not be_true # was a misleading "invalid header JSON"
        token = tool_payload(resp)["token"].as_s
        header, body, sig = token.split('.')
        # a well-formed, verifiable token was produced from the defaulted ({}) header
        Gori::Jwt.sign("#{header}.#{body}", "HS256", "test").should eq(sig)
      end
    end

    it "jwt_encode still rejects a call with no token, header, or payload" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jwt_encode","arguments":{"secret":"test"}}})
        drive(store, call)[0]["result"]["isError"].as_bool.should be_true
      end
    end

    it "jwt_attacks lists none/weak-secret/header-inject payloads" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jwt_attacks","arguments":{"token":"#{jwt}"}}})
        cats = tool_payload(drive(store, call, allow_actions: false)[0]).as_a.map { |a| a["category"].as_s }.uniq
        cats.should contain("none")
        cats.should contain("weak-secret")
        cats.should contain("header-inject")
      end
    end

    it "all three jwt tools are listed even in read-only mode" do
      with_store do |store|
        names = drive(store, %({"jsonrpc":"2.0","id":1,"method":"tools/list"}), allow_actions: false)[0]["result"]["tools"].as_a.map { |t| t["name"].as_s }
        names.should contain("jwt_decode")
        names.should contain("jwt_encode")
        names.should contain("jwt_attacks")
      end
    end

    it "jwt_decode errors cleanly on a non-JWT" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jwt_decode","arguments":{"token":"plainstring"}}})
        drive(store, call)[0]["result"]["isError"].as_bool.should be_true
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

    # The same "persists nothing" contract, on the EXTRACT tools. It did not hold: the rule
    # was written first and `enabled` was read after, so a rejected call left a live, ENABLED
    # extract rule behind — already observing every matching response and binding its name for
    # Match&Replace injection. `bool_arg` raises on a non-boolean, and clients that stringify
    # booleans (`"enabled": "yes"`) are exactly what its own comment warns about.
    it "rejects a non-boolean 'enabled' on extract create WITHOUT leaving the rule behind" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_extract_rule",) +
               %("arguments":{"name":"SESSION","kind":"cookie","selector":"sid","enabled":"yes"}}})
        resp = drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        # The caller's argument, so INVALID_ARGUMENT — not the catch-all's INTERNAL.
        resp["structuredContent"]["error_code"].as_s.should eq("INVALID_ARGUMENT")
        store.extract_rules.should be_empty
      end
    end

    it "rejects a non-boolean 'enabled' on extract update WITHOUT committing the other fields" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_extract_rule",) +
                 %("arguments":{"name":"SESSION","kind":"cookie","selector":"sid"}}})
        id = tool_payload(drive(store, create)[0])["id"].as_i64
        call = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"update_extract_rule",) +
               %("arguments":{"id":#{id},"selector":"other","enabled":"nope"}}})
        resp = drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["error_code"].as_s.should eq("INVALID_ARGUMENT")
        store.extract_rules.first.selector.should eq("sid") # unchanged
      end
    end

    it "rejects an unrecognized match kind instead of silently coercing to literal" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_rule","arguments":{"pattern":"x","match":"regex-ignorecase"}}})
        resp = drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["error_code"].as_s.should eq("INVALID_ARGUMENT")
        resp["structuredContent"]["field"].as_s.should eq("match")
        store.match_rules.should be_empty # not coerced into a stray literal rule
      end
    end

    it "still accepts the valid regex/literal match kinds" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_rule","arguments":{"pattern":"a\\\\d+","replacement":"x","match":"regex"}}})
        tool_payload(drive(store, call)[0])["match"].as_s.should eq("regex")
        store.match_rules[0].match_kind.regex?.should be_true
      end
    end

    it "creates a rule already disabled (atomic) with enabled:false" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_rule","arguments":{"pattern":"x","enabled":false}}})
        tool_payload(drive(store, create)[0])["enabled"].as_bool.should be_false
        store.match_rules[0].enabled?.should be_false # never live between create and disable
      end
    end

    it "updates an existing rule's pattern/part in place" do
      with_store do |store|
        id = store.insert_rule(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "old", "")
        upd = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"update_rule","arguments":{"id":#{id},"pattern":"new","part":"body"}}})
        tool_payload(drive(store, upd)[0])["updated"].as_bool.should be_true
        r = store.match_rules[0]
        r.pattern.should eq("new")
        r.part.body?.should be_true
        r.target.request?.should be_true # unchanged field preserved
      end
    end

    it "previews a rule's match count without creating it" do
      with_store do |store|
        seed_flow(store, "auth.test", "GET", "/x", 200) # request head has "auth.test"
        seed_flow(store, "other.test", "GET", "/y", 200)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"preview_rule","arguments":{"pattern":"auth.test","target":"request","part":"head"}}})
        p = tool_payload(drive(store, call)[0])
        p["would_match"].as_i.should eq(1)
        p["scanned"].as_i.should eq(2)
        store.match_rules.should be_empty # preview creates nothing
      end
    end

    it "rejects an uncompilable regex in preview_rule instead of a fake 0-match result" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"preview_rule","arguments":{"pattern":"[invalid\(regex","match":"regex"}}})
        resp = drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["error_code"].as_s.should eq("INVALID_ARGUMENT")
        resp["structuredContent"]["field"].as_s.should eq("pattern")
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
        store.insert_repeater("https://ex.test", "GET /x HTTP/1.1\nHost: ex.test\n\n".to_slice, false, true, nil, 0)
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
          "GET /ws HTTP/1.1\r\nHost: ex.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".to_slice, false, true, nil, 0)
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

    it "redacts sensitive headers in the nested tui_repeater snapshot unless include_sensitive" do
      with_store do |store|
        req = "GET / HTTP/1.1\r\nHost: ex.test\r\nAuthorization: Bearer s3cr3t\r\nCookie: sid=abc\r\n\r\n"
        ui = JSON.build do |j|
          j.object do
            j.field "active_tab", "repeater"
            j.field "repeater" do
              j.object do
                j.field "count", 1
                j.field "active" do
                  j.object do
                    j.field "http2", false
                    j.field "request", req # NESTED under "active" — the real TUI shape
                  end
                end
              end
            end
          end
        end
        store.set_setting(Gori::Store::UI_STATE_KEY, ui)

        # Default (include_sensitive:false): the nested request's credential values must be redacted.
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_repeater_context","arguments":{"include_content":true}}})
        redacted = tool_payload(drive(store, call, project_name: "demo", project_slug: "demo")[0])
        text = redacted["tui_repeater"]["active"]["request"].as_s
        text.should_not contain("s3cr3t")
        text.should_not contain("sid=abc")
        text.should contain("[REDACTED]")
        redacted["sensitive_headers_redacted"].as_bool.should be_true

        # include_sensitive:true passes the raw request through (matches the sessions[] policy).
        call2 = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_repeater_context","arguments":{"include_content":true,"include_sensitive":true}}})
        raw = tool_payload(drive(store, call2, project_name: "demo", project_slug: "demo")[0])
        raw["tui_repeater"]["active"]["request"].as_s.should contain("s3cr3t")
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
        info["bound"].as_bool.should be_true
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
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/audit","allow_unscoped":true}}})
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

    it "applies request-side Match & Replace rules only when apply_rules:true (R2-2)" do
      with_store do |store|
        port = start_mcp_http_origin("ok")
        Gori::Rules.load(store).add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
          "X-Rewritten", "gori-rewritten", op: Gori::Store::RuleOp::SetHeader)

        # apply_rules:true → the rule rewrites the OUTGOING request (and the recorded flow).
        on = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/","apply_rules":true,"allow_unscoped":true}}})
        payload = tool_payload(drive(store, on, verify_upstream: false)[0])
        payload["match_replace_applied"].as_bool.should be_true
        detail = store.get_flow(payload["recorded_flow_id"].as_i64).not_nil!
        String.new(detail.request_head).should contain("gori-rewritten")

        # default (no apply_rules) → byte-exact, rule NOT applied, flag absent.
        off = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/","allow_unscoped":true}}})
        p2 = tool_payload(drive(store, off, verify_upstream: false)[0])
        p2["match_replace_applied"]?.should be_nil
        d2 = store.get_flow(p2["recorded_flow_id"].as_i64).not_nil!
        String.new(d2.request_head).should_not contain("gori-rewritten")
      end
    end

    it "allows an explicit unaudited send and an explicit sensitive-header response" do
      with_store do |store|
        port = start_mcp_http_origin("ok", "Set-Cookie: session=visible\r\n")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/","record_history":false,"include_sensitive_headers":true,"allow_unscoped":true}}})
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
        send = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/big","allow_unscoped":true}}})
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
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"flow_id":#{id},"allow_unscoped":true}}})
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
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"flow_id":#{id},"http2":false,"allow_unscoped":true}}})
        resp = drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_false
        tool_payload(resp)["status"].as_i.should eq(200)
      end
    end

    it "bounds a hung read with timeout_ms and returns a network-error result" do
      with_store do |store|
        origin = TCPServer.new("127.0.0.1", 0)
        port = origin.local_address.port
        spawn do
          if conn = origin.accept? # accept, then never respond so the read idles out
            sleep 5.seconds
            conn.close rescue nil
          end
        rescue
        end
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/","timeout_ms":200,"allow_unscoped":true}}})
        resp = drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_true
        tool_payload(resp)["error"].as_s.empty?.should be_false
        origin.close rescue nil
      end
    end

    it "returns isError on a connection failure (port 1)" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:1/","allow_unscoped":true}}})
        resp = drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true
        payload = tool_payload(resp)
        payload["error"].as_s.downcase.should contain("fail")
        payload["error_kind"].as_s.should eq("connect")       # classified network error
        payload["error_code"].as_s.should eq("NETWORK_ERROR") # structured-error contract (criterion #4)
        payload["retryable"].as_bool.should be_true
        store.get_flow(payload["recorded_flow_id"].as_i64).not_nil!.row.state.error?.should be_true
      end
    end

    it "preserves the attempt duration on a failed send's History flow" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:1/","allow_unscoped":true}}})
        payload = tool_payload(drive(store, call)[0])
        detail = store.get_flow(payload["recorded_flow_id"].as_i64).not_nil!
        detail.row.state.error?.should be_true
        detail.row.duration_us.should_not be_nil # was null before — the attempt time is kept
      end
    end

    it "links a saved repeater to an issue even when the origin is unavailable" do
      with_store do |store|
        issue_id = store.insert_issue("evidence", Gori::Store::Severity::Low, nil, nil)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:1/","save_as_repeater":true,"issue_id":#{issue_id},"allow_unscoped":true}}})
        drive(store, call)[0]["result"]["isError"].as_bool.should be_true
        repeater_id = store.repeaters_meta.last.id
        links = store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id)
        links.any? { |link| link.ref_kind.repeater? && link.ref_id == repeater_id }.should be_true
      end
    end

    it "includes effective_request on a url send (no ignored fields)" do
      with_store do |store|
        port = start_mcp_http_origin("ok")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/path","method":"POST","allow_unscoped":true}}})
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
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"flow_id":#{id},"url":"http://ignored.test/x","method":"POST","allow_unscoped":true}}})
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

    it "executes a saved HTTP repeater by repeater_id" do
      with_store do |store|
        port = start_mcp_http_origin("repeater-ok")
        rid = store.insert_repeater(target: "http://127.0.0.1:#{port}",
          request: "GET /rep HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n".to_slice,
          http2: false, auto_cl: true, flow_id: nil, position: 0, sni: nil)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"repeater_id":#{rid},"allow_unscoped":true}}})
        p = tool_payload(drive(store, call, verify_upstream: false)[0])
        p["status"].as_i.should eq(200)
        p["effective_request"]["target"].as_s.should eq("/rep")
        p["effective_request"]["host"].as_s.should eq("127.0.0.1")
      end
    end

    it "rejects send_request on a WebSocket repeater and points to send_websocket" do
      with_store do |store|
        rid = store.insert_repeater(target: "http://127.0.0.1:9",
          request: "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:9\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: x\r\nSec-WebSocket-Version: 13\r\n\r\n".to_slice,
          http2: false, auto_cl: true, flow_id: nil, position: 0, sni: nil)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"repeater_id":#{rid},"allow_unscoped":true}}})
        resp = drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["content"][0]["text"].as_s.should contain("send_websocket")
      end
    end
  end

  describe "scope enforcement (active tools)" do
    it "blocks an unscoped send by default when no scope is configured" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:1/"}}})
        resp = drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["error_code"].as_s.should eq("SCOPE_BLOCKED")
        resp["structuredContent"]["details"]["scope_decision"].as_s.should eq("unscoped")
        store.count.should eq(0) # refused before any History write
      end
    end

    it "allows an unscoped send with allow_unscoped:true, flagged unscoped" do
      with_store do |store|
        port = start_mcp_http_origin("ok")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/","allow_unscoped":true}}})
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

    # A `raw` template's request line is taken VERBATIM (request_target in send.cr),
    # so it can be ABSOLUTE-FORM (`GET http://host/path HTTP/1.1`). The scope check
    # anchors on the DIAL host (built.host) reduced to origin-form, so an absolute-form
    # line whose host matches `url` still resolves in-scope (no URL doubling, host keyed
    # without port to match Scope.request_url's origin-form convention).
    it "reports in_scope for a raw request whose line is already ABSOLUTE-FORM" do
      with_store do |store|
        port = start_mcp_http_origin("ok")
        store.add_scope_rule("include", "regex", "^http://127\\.0\\.0\\.1/")
        raw = "GET http://127.0.0.1:#{port}/ HTTP/1.1\\r\\nHost: 127.0.0.1:#{port}\\r\\n\\r\\n"
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/","raw":"#{raw}"}}})
        p = tool_payload(drive(store, call, verify_upstream: false)[0])
        p["scope_decision"].as_s.should eq("in_scope")
        p["scope_rule_id"].as_i64.should be > 0
      end
    end

    # Host-header attack / cache-poisoning / SSRF-via-absolute-form: the caller DELIBERATELY
    # spoofs the request-line host to a DIFFERENT (here out-of-scope) host while dialing the
    # in-scope `url`. gori must ALLOW this and scope on the host it actually dials, so the
    # test proceeds against the in-scope origin and the spoofed line rides along verbatim.
    it "allows a deliberately spoofed request-line host, scoping on the dialed host" do
      with_store do |store|
        port = start_mcp_http_origin("ok")
        store.add_scope_rule("include", "regex", "^http://127\\.0\\.0\\.1/")
        raw = "GET http://evil.example/ HTTP/1.1\\r\\nHost: evil.example\\r\\n\\r\\n"
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/","raw":"#{raw}"}}})
        p = tool_payload(drive(store, call, verify_upstream: false)[0])
        p["scope_decision"].as_s.should eq("in_scope") # scoped on the dialed 127.0.0.1, not the spoofed line
      end
    end

    # The converse (the bypass this closes): dialing an OUT-of-scope host while the
    # absolute-form line names the in-scope host must NOT report in_scope — the scope
    # decision follows the dialed host, so this is blocked without allow_unscoped.
    it "scopes a raw absolute-form send on the dialed host, not the request-line host (no bypass)" do
      with_store do |store|
        port = start_mcp_http_origin("ok")
        store.add_scope_rule("include", "string", "127.0.0.1")
        # Absolute-form line names the in-scope 127.0.0.1, but `url` dials the out-of-scope
        # 10.99.99.99. The gate follows the DIALED host → blocked (no allow_unscoped), and
        # nothing is sent (so the unroutable IP is never actually dialed).
        raw = "GET http://127.0.0.1:#{port}/ HTTP/1.1\\r\\nHost: 127.0.0.1:#{port}\\r\\n\\r\\n"
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://10.99.99.99:#{port}/","raw":"#{raw}"}}})
        resp = drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_true
        sc = resp["result"]["structuredContent"]
        sc["error_code"].as_s.should eq("SCOPE_BLOCKED")
        sc["details"]["scope_decision"].as_s.should eq("out_of_scope")
      end
    end
  end

  describe "send_websocket" do
    it "performs the upgrade and returns the inbound frame transcript" do
      with_store do |store|
        port = start_mcp_ws_origin
        request = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
        repeater_id = store.insert_repeater("ws://127.0.0.1:#{port}", request.to_slice, false, true, nil, 0)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_websocket","arguments":{"repeater_id":#{repeater_id},"messages":["ping"],"idle_ms":100,"allow_unscoped":true}}})
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
        repeater_id = store.insert_repeater("http://127.0.0.1:1", "GET / HTTP/1.1\r\nHost: x\r\n\r\n".to_slice, false, true, nil, 0)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_websocket","arguments":{"repeater_id":#{repeater_id},"allow_unscoped":true}}})
        resp = drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.should contain("not a WebSocket")
      end
    end

    it "uses the WebSocket engine and returns a clean connection error" do
      with_store do |store|
        repeater_id = store.insert_repeater("ws://127.0.0.1:1", "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".to_slice, false, true, nil, 0)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_websocket","arguments":{"repeater_id":#{repeater_id},"messages":["ping"],"idle_ms":100,"allow_unscoped":true}}})
        resp = drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_true
        payload = tool_payload(resp)
        payload["repeater_id"].as_i64.should eq(repeater_id)
        payload["upgraded"].as_bool.should be_false
        payload["error"].as_s.should contain("connect failed")
      end
    end

    it "does not link the issue when a WebSocket send is scope-blocked" do
      with_store do |store|
        store.add_scope_rule("include", "host", "example.com") # blocks 127.0.0.1
        issue_id = store.insert_issue("ev", Gori::Store::Severity::Low, nil, nil)
        rid = store.insert_repeater("ws://127.0.0.1:1",
          "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".to_slice,
          false, true, nil, 0)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_websocket","arguments":{"repeater_id":#{rid},"issue_id":#{issue_id}}}})
        resp = drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["error_code"].as_s.should eq("SCOPE_BLOCKED")
        # the refused send must NOT have persisted the issue→repeater link
        store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id).empty?.should be_true
      end
    end
  end

  describe "compare_flows" do
    it "diffs two flows' response bodies line by line" do
      with_store do |store|
        a = seed_flow(store, "a.test", "GET", "/x", 200, resp_body: "line1\nline2\nline3".to_slice)
        b = seed_flow(store, "a.test", "GET", "/x", 200, resp_body: "line1\nCHANGED\nline3".to_slice)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"compare_flows","arguments":{"flow_id_a":#{a},"flow_id_b":#{b}}}})
        payload = tool_payload(drive(store, call)[0])
        payload["pane"].as_s.should eq("response")
        payload["identical"].as_bool.should be_false
        payload["changed_lines"].as_i.should be > 0
        kinds = payload["diff"].as_a.map(&.["kind"].as_s)
        kinds.should contain("add")
        kinds.should contain("del")
      end
    end

    it "reports identical:true and zero changed_lines for identical flows" do
      with_store do |store|
        a = seed_flow(store, "a.test", "GET", "/x", 200, resp_body: "same".to_slice)
        b = seed_flow(store, "a.test", "GET", "/x", 200, resp_body: "same".to_slice)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"compare_flows","arguments":{"flow_id_a":#{a},"flow_id_b":#{b}}}})
        payload = tool_payload(drive(store, call)[0])
        payload["identical"].as_bool.should be_true
        payload["changed_lines"].as_i.should eq(0)
      end
    end

    it "diffs the request pane when pane:request" do
      with_store do |store|
        a = seed_flow(store, "a.test", "GET", "/x", 200)
        b = seed_flow(store, "a.test", "POST", "/y", 200)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"compare_flows","arguments":{"flow_id_a":#{a},"flow_id_b":#{b},"pane":"request"}}})
        payload = tool_payload(drive(store, call)[0])
        payload["pane"].as_s.should eq("request")
        payload["identical"].as_bool.should be_false
      end
    end

    it "redacts auth headers in the request-pane diff, reveals them with include_sensitive" do
      with_store do |store|
        a = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "https", host: "a.test", port: 443,
          method: "GET", target: "/x", http_version: "HTTP/1.1",
          head: "GET /x HTTP/1.1\r\nHost: a.test\r\nAuthorization: Bearer topsecret\r\n\r\n".to_slice,
          body: nil))
        b = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 2_i64, scheme: "https", host: "a.test", port: 443,
          method: "GET", target: "/y", http_version: "HTTP/1.1",
          head: "GET /y HTTP/1.1\r\nHost: a.test\r\nAuthorization: Bearer topsecret\r\n\r\n".to_slice,
          body: nil))

        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"compare_flows","arguments":{"flow_id_a":#{a},"flow_id_b":#{b},"pane":"request"}}})
        payload = tool_payload(drive(store, call)[0])
        texts = payload["diff"].as_a.map(&.["text"].as_s)
        texts.any?(&.includes?("Authorization: [REDACTED]")).should be_true
        texts.any?(&.includes?("topsecret")).should be_false

        sensitive_call = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"compare_flows","arguments":{"flow_id_a":#{a},"flow_id_b":#{b},"pane":"request","include_sensitive":true}}})
        sensitive_payload = tool_payload(drive(store, sensitive_call)[0])
        sensitive_texts = sensitive_payload["diff"].as_a.map(&.["text"].as_s)
        sensitive_texts.any?(&.includes?("Bearer topsecret")).should be_true
      end
    end

    it "changes_only omits unchanged (same) lines from the diff" do
      with_store do |store|
        a = seed_flow(store, "a.test", "GET", "/x", 200, resp_body: "line1\nline2\nline3".to_slice)
        b = seed_flow(store, "a.test", "GET", "/x", 200, resp_body: "line1\nCHANGED\nline3".to_slice)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"compare_flows","arguments":{"flow_id_a":#{a},"flow_id_b":#{b},"changes_only":true}}})
        payload = tool_payload(drive(store, call)[0])
        payload["diff"].as_a.map(&.["kind"].as_s).should_not contain("same")
      end
    end

    it "returns NOT_FOUND for a missing flow id" do
      with_store do |store|
        a = seed_flow(store, "a.test", "GET", "/x", 200)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"compare_flows","arguments":{"flow_id_a":#{a},"flow_id_b":999999}}})
        resp = drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["error_code"].as_s.should eq("NOT_FOUND")
      end
    end
  end

  describe "scope rule tools" do
    it "adds, lists (with enabled), and deletes a scope rule" do
      with_store do |store|
        add = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add_scope_rule","arguments":{"kind":"include","match_type":"host","pattern":"api.example.com"}}})
        id = tool_payload(drive(store, add)[0])["id"].as_i64
        id.should be > 0

        listed = tool_payload(drive(store, %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_scope"}}))[0])
        listed["rules"].as_a.size.should eq(1)
        listed["rules"][0]["pattern"].as_s.should eq("api.example.com")

        del = %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"delete_scope_rule","arguments":{"id":#{id}}}})
        deleted = tool_payload(drive(store, del)[0])
        deleted["deleted"].as_bool.should be_true
        deleted["blocks_all"].as_bool.should be_false # sandbox is off here
        store.scope_rules.should be_empty
      end
    end

    it "reports blocks_all when the delete leaves Sandbox holding an empty allowlist" do
      # set_sandbox already returns blocks_all for exactly this state, but a delete that
      # CAUSES it returned a bare {id, deleted:true} — so an agent could black-hole the
      # proxy and read the write as ordinary success. Same question, both edges.
      with_store do |store|
        add = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add_scope_rule","arguments":{"kind":"include","match_type":"host","pattern":"api.example.com"}}})
        id = tool_payload(drive(store, add)[0])["id"].as_i64
        sandbox = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"set_sandbox","arguments":{"enabled":true}}})
        tool_payload(drive(store, sandbox)[0])["blocks_all"].as_bool.should be_false # an include still stands

        del = %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"delete_scope_rule","arguments":{"id":#{id}}}})
        deleted = tool_payload(drive(store, del)[0])
        deleted["deleted"].as_bool.should be_true
        deleted["blocks_all"].as_bool.should be_true
      end
    end

    it "rejects an invalid pattern (persists nothing)" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add_scope_rule","arguments":{"match_type":"regex","pattern":"[invalid\(regex"}}})
        resp = drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        store.scope_rules.should be_empty
      end
    end

    # #414: a duplicate rule is a deterministic rejection — reporting it retryable made an agent
    # that trusts `retryable` loop forever. It must be a non-retryable INVALID_ARGUMENT.
    it "rejects a duplicate rule as a non-retryable error" do
      with_store do |store|
        add = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add_scope_rule","arguments":{"kind":"include","match_type":"host","pattern":"dup.example.com"}}})
        drive(store, add)
        dup = drive(store, add)[0]["result"]
        dup["isError"].as_bool.should be_true
        dup["structuredContent"]["error_code"].as_s.should eq("INVALID_ARGUMENT")
        dup["structuredContent"]["retryable"].as_bool.should be_false
        store.scope_rules.size.should eq(1) # not duplicated
      end
    end

    it "toggles the scope lens on/off and reflects it in list_scope" do
      with_store do |store|
        listed0 = tool_payload(drive(store, %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_scope"}}))[0])
        listed0["enabled"].as_bool.should be_false

        on = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"set_scope_enabled","arguments":{"enabled":true}}})
        tool_payload(drive(store, on)[0])["enabled"].as_bool.should be_true

        listed1 = tool_payload(drive(store, %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_scope"}}))[0])
        listed1["enabled"].as_bool.should be_true
      end
    end

    it "reports NOT_FOUND deleting an unknown scope rule id" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"delete_scope_rule","arguments":{"id":999}}})
        resp = drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["error_code"].as_s.should eq("NOT_FOUND")
      end
    end

    it "toggles the sandbox gate on/off, flags block-all, and reflects it in list_scope" do
      with_store do |store|
        listed0 = tool_payload(drive(store, %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_scope"}}))[0])
        listed0["sandbox"].as_bool.should be_false

        on = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"set_sandbox","arguments":{"enabled":true}}})
        payload = tool_payload(drive(store, on)[0])
        payload["sandbox"].as_bool.should be_true
        payload["blocks_all"].as_bool.should be_true # no include rules yet ⇒ blocks everything
        store.setting(Gori::Scope::SETTING_SANDBOX).should eq("1")

        listed1 = tool_payload(drive(store, %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_scope"}}))[0])
        listed1["sandbox"].as_bool.should be_true

        off = %({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"set_sandbox","arguments":{"enabled":false}}})
        tool_payload(drive(store, off)[0])["sandbox"].as_bool.should be_false
        store.setting(Gori::Scope::SETTING_SANDBOX).should eq("0")
      end
    end
  end

  describe "env var tools" do
    it "sets, lists (redacted by default), and deletes an env var" do
      with_store do |store|
        set = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"set_env_var","arguments":{"key":"TOKEN","value":"secret123"}}})
        tool_payload(drive(store, set)[0])["set"].as_bool.should be_true

        listed = tool_payload(drive(store, %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_env"}}))[0]).as_a
        listed.size.should eq(1)
        listed[0]["key"].as_s.should eq("TOKEN")
        listed[0]["value"].as_s.should eq("[REDACTED]")

        sensitive = tool_payload(drive(store, %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_env","arguments":{"include_sensitive":true}}}))[0]).as_a
        sensitive[0]["value"].as_s.should eq("secret123")

        del = %({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"delete_env_var","arguments":{"key":"TOKEN"}}})
        tool_payload(drive(store, del)[0])["deleted"].as_bool.should be_true
        Gori::Settings.project_env_vars.should be_empty
      ensure
        Gori::Settings.project_env_vars = [] of {String, String}
      end
    end

    it "rejects an invalid key" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"set_env_var","arguments":{"key":"bad key!","value":"x"}}})
        resp = drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
      ensure
        Gori::Settings.project_env_vars = [] of {String, String}
      end
    end

    it "reports NOT_FOUND deleting an unknown key" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"delete_env_var","arguments":{"key":"NOPE"}}})
        resp = drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["error_code"].as_s.should eq("NOT_FOUND")
      ensure
        Gori::Settings.project_env_vars = [] of {String, String}
      end
    end
  end

  describe "host override tools" do
    it "adds, lists, updates, and deletes a host override" do
      with_store do |store|
        add = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add_host_override","arguments":{"host":"api.example.com","ip":"10.0.0.1"}}})
        id = tool_payload(drive(store, add)[0])["id"].as_i64
        id.should be > 0

        listed = tool_payload(drive(store, %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_host_overrides"}}))[0]).as_a
        listed.size.should eq(1)
        listed[0]["ip"].as_s.should eq("10.0.0.1")

        upd = %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"update_host_override","arguments":{"id":#{id},"host":"api.example.com","ip":"10.0.0.2"}}})
        tool_payload(drive(store, upd)[0])["ip"].as_s.should eq("10.0.0.2")

        del = %({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"delete_host_override","arguments":{"id":#{id}}}})
        tool_payload(drive(store, del)[0])["deleted"].as_bool.should be_true
        Gori::HostOverrides.load(store).entries.should be_empty
      end
    end

    it "rejects an invalid ip literal" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add_host_override","arguments":{"host":"api.example.com","ip":"not-an-ip"}}})
        resp = drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
      end
    end

    it "reports NOT_FOUND updating an unknown id" do
      with_store do |store|
        upd = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"update_host_override","arguments":{"id":999,"host":"x.test","ip":"1.2.3.4"}}})
        resp = drive(store, upd)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["error_code"].as_s.should eq("NOT_FOUND")
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
          payload = tool_payload(drive(store, call)[0])
          payload["count"].as_i.should eq(2)
          store.count.should eq(2)
        ensure
          File.delete?(path)
        end
      end
    end

    it "returns a clean error for a missing file" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"import_flows","arguments":{"kind":"urls","path":"/no/such/file.txt"}}})
        resp = drive(store, call)[0]["result"]
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
          payload = tool_payload(drive(store, call)[0])
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
        resp = drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["field"].as_s.should eq("kind")
        # The message enumerates the kinds; an agent that guessed wrong gets the real list.
        resp["content"][0]["text"].as_s.should contain("postman")
      end
    end

    it "accepts every kind Import.import_file dispatches on" do
      # The MCP whitelist (mcp/tools/import.cr) and the parser table are edited in different
      # files — a format added to one and not the other is invisible to agents.
      Gori::Import::LABELS.each_key do |kind|
        with_store do |store|
          call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"import_flows","arguments":{"kind":#{kind.to_s.to_json},"path":"/no/such/file"}}})
          resp = drive(store, call)[0]["result"]
          resp["isError"].as_bool.should be_true
          # It got past the kind check and failed on the path — which is the point.
          resp["content"][0]["text"].as_s.should contain("not found")
        end
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

    it "keeps the JSON-RPC response line valid UTF-8 when title/host/notes carry a raw invalid byte" do
      # Same captured-data-can-be-invalid-UTF-8 gap as Issues::Export.json (Serialize.issue
      # wrote these fields unscrubbed) — but here an unscrubbed byte breaks the WIRE response
      # line itself, a genuine JSON-RPC protocol violation a real client could choke on.
      # JSON.parse in Crystal does NOT validate embedded string bytes (confirmed separately),
      # so the meaningful assertion is `valid_encoding?` on the raw response, not just that
      # parsing succeeds.
      with_store do |store|
        id = store.insert_issue(String.new(Bytes[0x62, 0x61, 0x64, 0xff, 0x74]), # "bad\xFFt"
          Gori::Store::Severity::High, String.new(Bytes[0x68, 0xff, 0x6f]),      # "h\xFFo"
          nil        )
        store.update_issue(id, notes: String.new(Bytes[0x6e, 0x31, 0xff, 0x0a, 0x6e, 0x32])) # "n1\xFF\nn2"
        store.flush

        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_issues","arguments":{}}})
        resp = drive(store, call)[0]
        # the literal wire value a real client reads: content[0].text (the nested JSON text)
        resp["result"]["content"][0]["text"].as_s.valid_encoding?.should be_true

        issue = tool_payload(resp)["issues"].as_a.first
        issue["title"].as_s.valid_encoding?.should be_true
        issue["host"].as_s.valid_encoding?.should be_true
        issue["notes"].as_s.valid_encoding?.should be_true
        issue["notes"].as_s.lines.size.should eq(2) # notes keeps its newline
      end
    end
  end

  describe "get_issue" do
    it "keeps the JSON-RPC response line valid UTF-8 when title/host/notes carry a raw invalid byte" do
      with_store do |store|
        id = store.insert_issue(String.new(Bytes[0x62, 0x61, 0x64, 0xff, 0x74]),
          Gori::Store::Severity::High, String.new(Bytes[0x68, 0xff, 0x6f]), nil)
        store.update_issue(id, notes: String.new(Bytes[0x6e, 0x31, 0xff, 0x0a, 0x6e, 0x32]))
        store.flush

        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_issue","arguments":{"id":#{id}}}})
        resp = drive(store, call)[0]
        # the literal wire value a real client reads: content[0].text (the nested JSON text)
        resp["result"]["content"][0]["text"].as_s.valid_encoding?.should be_true

        issue = tool_payload(resp)
        issue["title"].as_s.valid_encoding?.should be_true
        issue["host"].as_s.valid_encoding?.should be_true
        issue["notes"].as_s.valid_encoding?.should be_true
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
          request: "GET / HTTP/1.1\r\nHost: h.test\r\nAuthorization: Bearer topsecret\r\n\r\n".to_slice,
          http2: false, auto_cl: true, flow_id: nil, position: 0, sni: nil)
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

# Project lifecycle drives Tools directly against an ISOLATED GORI_HOME so it
# never touches the developer's real ~/.gori/projects (delete is destructive).
describe "Gori::MCP::Tools project lifecycle" do
  it "creates, lists, switches, and (dry-run → token) deletes projects in isolation" do
    root = File.tempname("gori-projhome")
    Dir.mkdir_p(root)
    prev = ENV["GORI_HOME"]?
    ENV["GORI_HOME"] = root
    cur_db = File.join(root, "current.db")
    store = Gori::Store.open(cur_db)
    tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false, db_path: cur_db)
    begin
      # create two projects (already bound → create does NOT auto-switch)
      doomed = JSON.parse(tools.call("create_project", JSON.parse(%({"name":"Doomed","description":"scratch"}))).text)
      doomed["created"].as_bool.should be_true
      doomed["switched"]?.try(&.as_bool?).should be_false
      doomed_slug = doomed["slug"].as_s
      alt = JSON.parse(tools.call("create_project", JSON.parse(%({"name":"Alt"}))).text)["slug"].as_s

      # list shows both (neither current — server serves current.db, not a registry project)
      listed = JSON.parse(tools.call("list_projects", JSON.parse("{}")).text)["projects"].as_a.map { |p| p["slug"].as_s }
      listed.should contain(doomed_slug)
      listed.should contain(alt)

      # switch to Alt → subsequent tools serve it
      sw = JSON.parse(tools.call("switch_project", JSON.parse(%({"project":#{alt.to_json}}))).text)
      sw["switched"].as_bool.should be_true
      JSON.parse(tools.call("project_info", JSON.parse("{}")).text)["project_slug"].as_s.should eq(alt)

      # delete Doomed: a real delete without a token is refused
      no_token = tools.call("delete_project", JSON.parse(%({"project":#{doomed_slug.to_json},"dry_run":false})))
      no_token.is_error.should be_true

      # dry_run issues a confirmation token + preview
      dry = JSON.parse(tools.call("delete_project", JSON.parse(%({"project":#{doomed_slug.to_json}}))).text)
      dry["dry_run"].as_bool.should be_true
      token = dry["confirmation_token"].as_s
      dry["flows"].as_i.should eq(0)

      # a wrong token is refused
      tools.call("delete_project", JSON.parse(%({"project":#{doomed_slug.to_json},"dry_run":false,"confirmation_token":"del_bogus"}))).is_error.should be_true

      # the real delete with the issued token succeeds
      done = JSON.parse(tools.call("delete_project", JSON.parse(%({"project":#{doomed_slug.to_json},"dry_run":false,"confirmation_token":#{token.to_json}}))).text)
      done["deleted"].as_bool.should be_true

      # Doomed is gone, Alt remains
      after = JSON.parse(tools.call("list_projects", JSON.parse("{}")).text)["projects"].as_a.map { |p| p["slug"].as_s }
      after.should_not contain(doomed_slug)
      after.should contain(alt)

      # deleting the currently-served project (Alt) is refused
      tools.call("delete_project", JSON.parse(%({"project":#{alt.to_json}}))).is_error.should be_true
    ensure
      store.close rescue nil
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(root)
    end
  end
end

describe "Gori::MCP::Tools unbound mode" do
  it "connects without a store, refuses traffic tools, and binds on create" do
    root = File.tempname("gori-unbound")
    Dir.mkdir_p(root)
    prev = ENV["GORI_HOME"]?
    ENV["GORI_HOME"] = root
    tools = Gori::MCP::Tools.new(nil, allow_actions: true, verify_upstream: false,
      selection_source: "unbound")
    begin
      info = JSON.parse(tools.call("project_info", JSON.parse("{}")).text)
      info["bound"].as_bool.should be_false
      info["selection_source"].as_s.should eq("unbound")
      info["note"]?.try(&.as_s?).should_not be_nil

      hist = tools.call("list_history", JSON.parse("{}"))
      hist.is_error.should be_true
      hist.error_code.should eq("NO_PROJECT")

      # pure tools work unbound
      dec = tools.call("decode", JSON.parse(%({"input":"aGVsbG8=","spec":"base64-decode"})))
      dec.is_error.should be_false

      # create auto-binds when unbound
      created = JSON.parse(tools.call("create_project", JSON.parse(%({"name":"First"}))).text)
      created["created"].as_bool.should be_true
      created["switched"].as_bool.should be_true

      info2 = JSON.parse(tools.call("project_info", JSON.parse("{}")).text)
      info2["bound"].as_bool.should be_true
      info2["project"].as_s.should eq("First")

      hist2 = tools.call("list_history", JSON.parse("{}"))
      hist2.is_error.should be_false
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(root)
    end
  end

  it "allows switch_project and create_project under read-only when unbound" do
    root = File.tempname("gori-unbound-ro")
    Dir.mkdir_p(root)
    prev = ENV["GORI_HOME"]?
    ENV["GORI_HOME"] = root
    # Seed a project via registry so switch has a target without using create.
    reg = Gori::ProjectRegistry.new(Gori::Paths.projects_dir)
    seeded = reg.create("Seeded")
    Gori::Store.open(seeded.db_path).close

    tools = Gori::MCP::Tools.new(nil, allow_actions: false, verify_upstream: false,
      selection_source: "unbound")
    begin
      send = tools.call("send_request", JSON.parse(%({"url":"http://example.test/"})))
      send.is_error.should be_true
      # unbound gate fires first for traffic tools that need a project
      send.error_code.should eq("NO_PROJECT")

      sw = JSON.parse(tools.call("switch_project", JSON.parse(%({"project":"Seeded"}))).text)
      sw["switched"].as_bool.should be_true

      # after bind, send is still disabled by read-only
      send2 = tools.call("send_request", JSON.parse(%({"url":"http://example.test/"})))
      send2.is_error.should be_true
      send2.error_code.should eq("TOOL_DISABLED")

      # create under read-only is refused once bound
      cr = tools.call("create_project", JSON.parse(%({"name":"Nope"})))
      cr.is_error.should be_true
      cr.error_code.should eq("TOOL_DISABLED")
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(root)
    end
  end

  it "handshakes an unbound Server over stdio" do
    input = IO::Memory.new(%({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
))
    output = IO::Memory.new
    Gori::MCP::Server.new(nil, allow_actions: true, verify_upstream: false,
      selection_source: "unbound", input: input, output: output).run
    lines = output.to_s.each_line.reject(&.strip.empty?).map { |l| JSON.parse(l) }.to_a
    lines.size.should eq(2)
    init = lines[0]["result"]
    init["serverInfo"]["name"].as_s.should eq("gori")
    init["instructions"].as_s.should match(/No project is bound/i)
    names = lines[1]["result"]["tools"].as_a.map { |t| t["name"].as_s }
    names.should contain("list_projects")
    names.should contain("create_project")
    names.should contain("switch_project")
    names.should contain("list_history")
  end
end

describe "MCP env reload (R2-3)" do
  it "reloads project env vars from the store before an active tool call" do
    with_store do |store|
      store.set_setting(Gori::Env::PROJECT_VARS_KEY,
        Gori::Env.serialize_vars([{"APIHOST", "old.test"}]))
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      begin
        # initialize -> Env.load_project seeded the old value.
        Gori::Settings.project_env_vars.should eq([{"APIHOST", "old.test"}])

        # Simulate `gori run project env set APIHOST new.test` from the CLI while the
        # MCP server keeps running (writes straight to the shared DB).
        store.set_setting(Gori::Env::PROJECT_VARS_KEY,
          Gori::Env.serialize_vars([{"APIHOST", "new.test"}]))
        Gori::Settings.project_env_vars.should eq([{"APIHOST", "old.test"}]) # still stale in-process

        # Any active/outbound tool reloads first. This fuzz_start fails arg validation
        # (no template/url) and never touches the network, but the reload in `call` runs
        # BEFORE dispatch regardless — deterministic.
        tools.call("fuzz_start", JSON.parse("{}"))
        Gori::Settings.project_env_vars.should eq([{"APIHOST", "new.test"}])
      ensure
        Gori::Settings.project_env_vars = [] of {String, String}
      end
    end
  end

  it "does not reload for a read-only tool" do
    with_store do |store|
      store.set_setting(Gori::Env::PROJECT_VARS_KEY,
        Gori::Env.serialize_vars([{"APIHOST", "old.test"}]))
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      begin
        store.set_setting(Gori::Env::PROJECT_VARS_KEY,
          Gori::Env.serialize_vars([{"APIHOST", "new.test"}]))
        tools.call("list_scope", JSON.parse("{}"))
        Gori::Settings.project_env_vars.should eq([{"APIHOST", "old.test"}]) # read tool: no churn
      ensure
        Gori::Settings.project_env_vars = [] of {String, String}
      end
    end
  end
end

# Small CRUD gaps that used to be TUI-only: issue delete, scope-rule edit-in-place,
# sitemap tags, and repeater tags.
private def tools_for(store) : Gori::MCP::Tools
  Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
end

private def ok_json(tools : Gori::MCP::Tools, name : String, args : String) : JSON::Any
  r = tools.call(name, JSON.parse(args))
  fail "tool #{name} errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

describe "MCP delete_issue" do
  it "removes the issue and its entity links" do
    with_store do |store|
      rid = store.insert_repeater("https://acme.test/", "GET / HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 0)
      id = store.insert_issue("boom", Gori::Store::Severity::High, "acme.test", nil)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, id, Gori::Store::LinkRefKind::Repeater, rid)
      tools = tools_for(store)

      ok_json(tools, "delete_issue", %({"id":#{id}}))["deleted"].as_bool.should be_true
      store.get_issue(id).should be_nil
      store.list_links(Gori::Store::LinkOwnerKind::Issue, id).empty?.should be_true

      tools.call("delete_issue", JSON.parse(%({"id":#{id}}))).is_error.should be_true # already gone
    end
  end
end

describe "MCP update_scope_rule" do
  it "edits a rule in place, keeping its id and defaulting unspecified fields" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "old.test")
      id = Gori::Scope.load(store).rules.first.id
      tools = tools_for(store)

      res = ok_json(tools, "update_scope_rule", %({"id":#{id},"pattern":"new.test"}))
      res["id"].as_i64.should eq(id) # same rule, not delete + re-add
      res["kind"].as_s.should eq("include")
      res["match_type"].as_s.should eq("host")

      rule = Gori::Scope.load(store).rules.first
      rule.id.should eq(id)
      rule.pattern.should eq("new.test")
      rule.kind.should eq("include")
    end
  end

  it "rejects an unknown id and an invalid field" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "a.test")
      id = Gori::Scope.load(store).rules.first.id
      tools = tools_for(store)
      tools.call("update_scope_rule", JSON.parse(%({"id":9999,"pattern":"x"}))).is_error.should be_true
      tools.call("update_scope_rule", JSON.parse(%({"id":#{id},"kind":"bogus"}))).is_error.should be_true
      # An invalid regex must not land in the gate.
      tools.call("update_scope_rule", JSON.parse(%({"id":#{id},"match_type":"regex","pattern":"[bad"}))).is_error.should be_true
      Gori::Scope.load(store).rules.first.pattern.should eq("a.test")
    end
  end
end

describe "MCP sitemap tags" do
  it "sets, lists, clears, and stamps a tag onto the matching list_sitemap entry" do
    with_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
        method: "GET", target: "/login?a=1", http_version: "HTTP/1.1",
        head: "GET /login?a=1 HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
      tools = tools_for(store)

      res = ok_json(tools, "set_sitemap_tag", %({"host":"acme.test","path":"/login?a=1","tag":"auth entry"}))
      res["tag"].as_s.should eq("auth entry")

      tags = ok_json(tools, "list_sitemap_tags", "{}").as_a
      tags.size.should eq(1)
      tags.first["path"].as_s.should eq("/login?a=1")

      entry = ok_json(tools, "list_sitemap", "{}").as_a.first
      entry["tag"].as_s.should eq("auth entry")

      ok_json(tools, "set_sitemap_tag", %({"host":"acme.test","path":"/login?a=1"}))["cleared"].as_bool.should be_true
      ok_json(tools, "list_sitemap_tags", "{}").as_a.empty?.should be_true
    end
  end

  it "keys tags on the path INCLUDING the query, matching the Sitemap tree" do
    with_store do |store|
      tools = tools_for(store)
      ok_json(tools, "set_sitemap_tag", %({"host":"acme.test","path":"/login?a=1","tag":"with-query"}))
      ok_json(tools, "set_sitemap_tag", %({"host":"acme.test","path":"/login","tag":"bare"}))
      # Two DISTINCT nodes — stripping the query would collapse them and file the tag
      # under a key the tree never looks up.
      store.sitemap_tags[{"acme.test", "/login?a=1"}]?.should eq("with-query")
      store.sitemap_tags[{"acme.test", "/login"}]?.should eq("bare")
    end
  end
end

describe "MCP repeater tags" do
  it "sets and clears tags through update_repeater, and lists them back" do
    with_store do |store|
      id = store.insert_repeater("https://acme.test/", "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        false, true, nil, 0)
      tools = tools_for(store)

      ok_json(tools, "update_repeater", %({"id":#{id},"tags":"auth prod"}))
      # repeaters_mcp is the loader every listing surface reads — it must SELECT tags,
      # or a stored tag reads back as nil everywhere but the TUI.
      store.repeaters_mcp.first.tags.should eq("auth prod")

      ok_json(tools, "update_repeater", %({"id":#{id},"tags":""}))
      store.repeaters_mcp.first.tags.should be_nil
    end
  end
end

private def seed_flow(store, target = "/a") : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
  id
end

describe "MCP flow deletion" do
  it "deletes one flow by id" do
    with_store do |store|
      a = seed_flow(store, "/a")
      b = seed_flow(store, "/b")
      tools = tools_for(store)

      ok_json(tools, "delete_flow", %({"id":#{a}}))["deleted"].as_bool.should be_true
      store.get_flow(a).should be_nil
      store.get_flow(b).should_not be_nil
      tools.call("delete_flow", JSON.parse(%({"id":#{a}}))).is_error.should be_true # already gone
    end
  end

  it "refuses clear_history without confirm:true and reports the count it would destroy" do
    with_store do |store|
      seed_flow(store, "/a")
      seed_flow(store, "/b")
      tools = tools_for(store)

      r = tools.call("clear_history", JSON.parse("{}"))
      r.is_error.should be_true
      r.text.should contain("2")
      store.count.should eq(2) # nothing destroyed

      tools.call("clear_history", JSON.parse(%({"confirm":false}))).is_error.should be_true
      store.count.should eq(2)

      ok_json(tools, "clear_history", %({"confirm":true}))["deleted"].as_i.should eq(2)
      store.count.should eq(0)
    end
  end

  it "refuses both under --read-only" do
    with_store do |store|
      id = seed_flow(store)
      ro = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
      ro.call("delete_flow", JSON.parse(%({"id":#{id}}))).is_error.should be_true
      ro.call("clear_history", JSON.parse(%({"confirm":true}))).is_error.should be_true
      store.count.should eq(1)
    end
  end
end

describe "MCP entity links" do
  it "lists an issue's evidence resolved to labels, and round-trips add/remove" do
    with_store do |store|
      fid = seed_flow(store, "/evidence")
      rid = store.insert_repeater("https://acme.test/", "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        false, true, nil, 0)
      iid = store.insert_issue("boom", Gori::Store::Severity::High, "acme.test", nil)
      tools = tools_for(store)

      ok_json(tools, "list_links", %({"owner_kind":"issue","owner_id":#{iid}}))["total"].as_i.should eq(0)

      res = ok_json(tools, "add_link",
        %({"owner_kind":"issue","owner_id":#{iid},"ref_kind":"flow","ref_id":#{fid}}))
      res["already_linked"].as_bool.should be_false
      ok_json(tools, "add_link",
        %({"owner_kind":"issue","owner_id":#{iid},"ref_kind":"repeater","ref_id":#{rid}}))

      listed = ok_json(tools, "list_links", %({"owner_kind":"issue","owner_id":#{iid}}))
      listed["total"].as_i.should eq(2)
      kinds = listed["links"].as_a.map { |l| l["ref_kind"].as_s }
      kinds.should contain("flow")
      kinds.should contain("repeater")
      listed["links"].as_a.each { |l| l["label"].as_s.empty?.should be_false }

      ok_json(tools, "remove_link",
        %({"owner_kind":"issue","owner_id":#{iid},"ref_kind":"flow","ref_id":#{fid}}))["removed"].as_bool.should be_true
      ok_json(tools, "list_links", %({"owner_kind":"issue","owner_id":#{iid}}))["total"].as_i.should eq(1)
    end
  end

  it "reports a re-link as already_linked rather than duplicating" do
    with_store do |store|
      fid = seed_flow(store)
      iid = store.insert_issue("x", Gori::Store::Severity::Info, nil, nil)
      tools = tools_for(store)
      args = %({"owner_kind":"issue","owner_id":#{iid},"ref_kind":"flow","ref_id":#{fid}})

      ok_json(tools, "add_link", args)["already_linked"].as_bool.should be_false
      ok_json(tools, "add_link", args)["already_linked"].as_bool.should be_true
      store.list_links(Gori::Store::LinkOwnerKind::Issue, iid).size.should eq(1)
    end
  end

  # This example used to pin the OPPOSITE — that deleting a repeater leaves the link dangling,
  # "because gone is not the same as never there". That reading only holds where the id cannot
  # come back, which is true of flows and false of repeaters: `repeaters.id` has no
  # AUTOINCREMENT and closing the NEWEST tab deletes at the top of the id space, so the
  # counter resets and the very next tab takes the dead id. The link then resolved
  # `stale: false` to an unrelated request — an issue's evidence pointer naming a different
  # URL. A pointer that starts lying is worse than either honest answer, so this one cascades.
  it "drops a repeater link when the repeater is deleted, because its id can be reused" do
    with_store do |store|
      rid = store.insert_repeater("https://victim.test/a", "GET /a HTTP/1.1\r\nHost: victim.test\r\n\r\n".to_slice,
        false, true, nil, 0)
      iid = store.insert_issue("x", Gori::Store::Severity::Info, nil, nil)
      tools = tools_for(store)
      ok_json(tools, "add_link", %({"owner_kind":"issue","owner_id":#{iid},"ref_kind":"repeater","ref_id":#{rid}}))

      store.delete_repeater(rid)
      ok_json(tools, "list_links", %({"owner_kind":"issue","owner_id":#{iid}}))["total"].as_i.should eq(0)

      # The id comes straight back — which is exactly why the link could not be left behind.
      again = store.insert_repeater("https://unrelated.test/z", "GET /z HTTP/1.1\r\nHost: unrelated.test\r\n\r\n".to_slice,
        false, true, nil, 0)
      again.should eq(rid)
      ok_json(tools, "list_links", %({"owner_kind":"issue","owner_id":#{iid}}))["total"].as_i.should eq(0)
    end
  end

  it "drops a flow link when the flow itself is deleted (delete_flow cascades entity_links)" do
    with_store do |store|
      fid = seed_flow(store)
      iid = store.insert_issue("x", Gori::Store::Severity::Info, nil, nil)
      tools = tools_for(store)
      ok_json(tools, "add_link", %({"owner_kind":"issue","owner_id":#{iid},"ref_kind":"flow","ref_id":#{fid}}))

      ok_json(tools, "delete_flow", %({"id":#{fid}}))
      ok_json(tools, "list_links", %({"owner_kind":"issue","owner_id":#{iid}}))["total"].as_i.should eq(0)
    end
  end

  it "refuses to link either end to a row that does not exist" do
    with_store do |store|
      fid = seed_flow(store)
      iid = store.insert_issue("x", Gori::Store::Severity::Info, nil, nil)
      tools = tools_for(store)

      tools.call("add_link", JSON.parse(%({"owner_kind":"issue","owner_id":9999,"ref_kind":"flow","ref_id":#{fid}}))).is_error.should be_true
      tools.call("add_link", JSON.parse(%({"owner_kind":"issue","owner_id":#{iid},"ref_kind":"flow","ref_id":9999}))).is_error.should be_true
      tools.call("add_link", JSON.parse(%({"owner_kind":"bogus","owner_id":#{iid},"ref_kind":"flow","ref_id":#{fid}}))).is_error.should be_true
      tools.call("add_link", JSON.parse(%({"owner_kind":"issue","owner_id":#{iid},"ref_kind":"bogus","ref_id":#{fid}}))).is_error.should be_true
      store.list_links(Gori::Store::LinkOwnerKind::Issue, iid).empty?.should be_true
    end
  end

  it "refuses mutation under --read-only but still lists" do
    with_store do |store|
      fid = seed_flow(store)
      iid = store.insert_issue("x", Gori::Store::Severity::Info, nil, nil)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, iid, Gori::Store::LinkRefKind::Flow, fid)
      ro = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)

      ro.call("add_link", JSON.parse(%({"owner_kind":"issue","owner_id":#{iid},"ref_kind":"flow","ref_id":#{fid}}))).is_error.should be_true
      ro.call("remove_link", JSON.parse(%({"owner_kind":"issue","owner_id":#{iid},"ref_kind":"flow","ref_id":#{fid}}))).is_error.should be_true
      ok_json(ro, "list_links", %({"owner_kind":"issue","owner_id":#{iid}}))["total"].as_i.should eq(1)
    end
  end
end

describe "MCP saved OAST providers" do
  it "CRUDs a project provider and redacts its token by default" do
    with_store do |store|
      tools = tools_for(store)
      ok_json(tools, "list_oast_providers", "{}")["total"].as_i.should eq(0)

      created = ok_json(tools, "create_oast_provider",
        %({"name":"private","kind":"interactsh","host":"https://oast.internal","token":"SECRET"}))
      id = created["id"].as_s
      id.should start_with("p_")

      listed = ok_json(tools, "list_oast_providers", "{}")["providers"].as_a.first
      listed["name"].as_s.should eq("private")
      listed["scope"].as_s.should eq("project")
      listed["enabled"].as_bool.should be_true
      listed["token"].as_s.should eq("[REDACTED]") # a provider token is a credential

      ok_json(tools, "list_oast_providers", %({"include_sensitive":true}))["providers"]
        .as_a.first["token"].as_s.should eq("SECRET")

      ok_json(tools, "set_oast_provider_enabled", %({"id":"#{id}","enabled":false}))
      ok_json(tools, "list_oast_providers", "{}")["providers"].as_a.first["enabled"].as_bool.should be_false

      ok_json(tools, "delete_oast_provider", %({"id":"#{id}"}))["deleted"].as_i.should eq(1)
      store.oast_providers.empty?.should be_true
    end
  end

  it "keeps unmentioned fields on update — editing the name must not drop the token" do
    with_store do |store|
      tools = tools_for(store)
      id = ok_json(tools, "create_oast_provider",
        %({"name":"private","host":"https://oast.internal","token":"SECRET"}))["id"].as_s

      ok_json(tools, "update_oast_provider", %({"id":"#{id}","name":"renamed"}))
      row = store.oast_providers.first
      row.name.should eq("renamed")
      row.token.should eq("SECRET") # survived
      row.host.should eq("https://oast.internal")
      row.enabled?.should be_true
    end
  end

  it "refuses an unknown kind rather than storing one that can never fire" do
    with_store do |store|
      tools = tools_for(store)
      tools.call("create_oast_provider", JSON.parse(%({"name":"x","kind":"bogus"}))).is_error.should be_true
      store.oast_providers.empty?.should be_true
    end
  end

  it "refuses to touch a GLOBAL provider or an unknown id" do
    with_store do |store|
      tools = tools_for(store)
      tools.call("delete_oast_provider", JSON.parse(%({"id":"g_abc"}))).is_error.should be_true
      tools.call("update_oast_provider", JSON.parse(%({"id":"p_999","name":"x"}))).is_error.should be_true
      tools.call("delete_oast_provider", JSON.parse(%({"id":"nonsense"}))).is_error.should be_true
    end
  end

  it "refuses mutation under --read-only but still lists" do
    with_store do |store|
      store.insert_oast_provider("p", "interactsh", "https://x.test", "T", true, 0)
      ro = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
      ro.call("create_oast_provider", JSON.parse(%({"name":"x"}))).is_error.should be_true
      ro.call("delete_oast_provider", JSON.parse(%({"id":"p_1"}))).is_error.should be_true
      ok_json(ro, "list_oast_providers", "{}")["total"].as_i.should eq(1)
    end
  end
end

describe "MCP minimize_repeater" do
  it "refuses a WebSocket session, an unknown id, and a bad scheme" do
    with_store do |store|
      ws = store.insert_repeater("https://acme.test/",
        "GET /ws HTTP/1.1\r\nHost: acme.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".to_slice,
        false, true, nil, 0)
      bad = store.insert_repeater("ftp://acme.test/", "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        false, true, nil, 1)
      tools = tools_for(store)

      tools.call("minimize_repeater", JSON.parse(%({"repeater_id":9999}))).is_error.should be_true
      tools.call("minimize_repeater", JSON.parse(%({"repeater_id":#{ws}}))).is_error.should be_true
      tools.call("minimize_repeater", JSON.parse(%({"repeater_id":#{bad}}))).is_error.should be_true
    end
  end

  it "refuses an out-of-scope target before sending anything" do
    with_store do |store|
      id = store.insert_repeater("https://acme.test/", "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        false, true, nil, 0)
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "other.test")
      tools = tools_for(store)

      r = tools.call("minimize_repeater", JSON.parse(%({"repeater_id":#{id}})))
      r.is_error.should be_true
      r.text.should contain("scope")
    end
  end

  it "refuses a sandbox-blocked target even under allow_unscoped" do
    with_store do |store|
      id = store.insert_repeater("https://acme.test/", "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        false, true, nil, 0)
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "other.test")
      scope.enable_sandbox
      tools = tools_for(store)

      # allow_unscoped bypasses the include gate but NEVER the sandbox — same two-layer
      # model the other active tools use.
      r = tools.call("minimize_repeater", JSON.parse(%({"repeater_id":#{id},"allow_unscoped":true})))
      r.is_error.should be_true
      r.text.should contain("sandbox")
    end
  end

  it "is refused under --read-only (it sends real requests)" do
    with_store do |store|
      id = store.insert_repeater("https://acme.test/", "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        false, true, nil, 0)
      ro = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
      ro.call("minimize_repeater", JSON.parse(%({"repeater_id":#{id}}))).is_error.should be_true
    end
  end
end

describe "code-review follow-ups" do
  it "refuses to minimize a repeater whose saved request holds §fuzz§ markers" do
    with_store do |store|
      id = store.insert_repeater("https://acme.test/",
        "GET /a?id=§1§ HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, false, true, nil, 0)
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")
      tools = tools_for(store)

      # A marked-up template is not a request: minimizing it would send real requests full of
      # literal § bytes, and apply:true would overwrite the user's template with the result.
      r = tools.call("minimize_repeater", JSON.parse(%({"repeater_id":#{id}})))
      r.is_error.should be_true
      r.text.should contain("marker")
      # Untouched.
      String.new(store.get_repeater(id).not_nil!.request).should contain("§1§")
    end
  end

  it "flags a sitemap tag whose path matches no captured endpoint" do
    with_store do |store|
      seed_flow(store, "/api/users")
      tools = tools_for(store)

      hit = ok_json(tools, "set_sitemap_tag", %({"host":"acme.test","path":"/api/users","tag":"ok"}))
      hit["matches_endpoint"].as_bool.should be_true
      hit.as_h.has_key?("warning").should be_false

      # Sitemap.add drops a trailing slash, so /api/users/ is a key no node ever has.
      miss = ok_json(tools, "set_sitemap_tag", %({"host":"acme.test","path":"/api/users/","tag":"typo"}))
      miss["matches_endpoint"].as_bool.should be_false
      miss["warning"].as_s.should contain("no captured endpoint")
    end
  end
end

# A captured request line is parsed with a plain `String.new` over wire bytes (no scrub) and
# SQLite round-trips those bytes verbatim, so anything derived from captured traffic can be
# invalid UTF-8. The stdio JSON-RPC transport carries UTF-8 TEXT: one bad byte anywhere makes
# a strict client reject the entire response line, not just the offending field.
private def seed_invalid_utf8_flow(store) : Int64
  bad_target = String.new(Bytes[0x2f, 0x63, 0x61, 0x66, 0xe9]) # "/caf\xE9" — not valid UTF-8
  bad_target.valid_encoding?.should be_false
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: bad_target, http_version: "HTTP/1.1",
    head: "GET #{bad_target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice))
end

describe "MCP JSON-RPC UTF-8 validity" do
  # Assert on the tool's RAW payload string, never on a parsed field: Crystal's JSON parser
  # reassembles an escaped string char-by-char and silently turns an invalid byte into
  # U+FFFD, so `JSON.parse(...)["target"]` reports clean text for a payload that is NOT.
  # Going through Tools (not Server) also bypasses the transport safety net, so these pin
  # the per-site Serialize.text calls rather than the net that backstops them.
  it "keeps an invalid-UTF-8 captured target out of list_history's payload" do
    with_store do |store|
      seed_invalid_utf8_flow(store)
      # Round-trip check: the store really does hand the invalid bytes back.
      store.recent_flows(10, nil, nil).first.target.valid_encoding?.should be_false

      payload = tools_for(store).call("list_history", JSON.parse("{}")).text
      payload.valid_encoding?.should be_true
      payload.should contain("caf")
    end
  end

  it "keeps it out of list_sitemap's and get_flow's payloads" do
    with_store do |store|
      id = seed_invalid_utf8_flow(store)
      tools = tools_for(store)
      tools.call("list_sitemap", JSON.parse("{}")).text.valid_encoding?.should be_true
      tools.call("get_flow", JSON.parse(%({"id":#{id}}))).text.valid_encoding?.should be_true
    end
  end

  it "keeps a repeater seeded from a captured request out of its payload" do
    with_store do |store|
      bad_host = String.new(Bytes[0x61, 0xe9, 0x2e, 0x74, 0x65, 0x73, 0x74]) # "a\xE9.test"
      store.insert_repeater("https://#{bad_host}/", "GET / HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 0)
      tools_for(store).call("get_repeater_context", JSON.parse("{}")).text.valid_encoding?.should be_true
    end
  end

  it "scrubs at the transport as a last resort so the whole line stays parseable" do
    with_store do |store|
      seed_invalid_utf8_flow(store)
      input = IO::Memory.new(%({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{}}}) + "\n")
      output = IO::Memory.new
      Gori::MCP::Server.new(store, allow_actions: true, verify_upstream: false,
        input: input, output: output).run
      # The emitted BYTES, not just the decoded field: this is the transport contract.
      output.to_s.each_line.reject(&.strip.empty?).each do |line|
        line.valid_encoding?.should be_true
      end
    end
  end
end

describe "MCP project env vars" do
  it "reports an out-of-band env change instead of a stale in-process copy" do
    with_store do |store|
      tools = tools_for(store)
      ok_json(tools, "list_env", "{}").as_a.should be_empty

      # Another process (`gori run project env set`) writes to the same project DB.
      store.set_setting(Gori::Env::PROJECT_VARS_KEY, %([{"key":"CLI_TOKEN","value":"abc"}]))

      listed = ok_json(tools, "list_env", %({"include_sensitive":true}))
      listed.as_a.map { |v| v["key"].as_s }.should eq ["CLI_TOKEN"]
    end
  end

  it "does not clobber an out-of-band env var when setting another" do
    with_store do |store|
      tools = tools_for(store)
      ok_json(tools, "list_env", "{}") # bind with an empty set, as a long-lived server would

      store.set_setting(Gori::Env::PROJECT_VARS_KEY, %([{"key":"CLI_TOKEN","value":"abc"}]))
      ok_json(tools, "set_env_var", %({"key":"MCP_KEY","value":"v"}))

      # set_env_var read-modify-WRITES the whole array; on a stale copy CLI_TOKEN vanished.
      keys = ok_json(tools, "list_env", "{}").as_a.map { |v| v["key"].as_s }
      keys.should contain "CLI_TOKEN"
      keys.should contain "MCP_KEY"
    end
  end

  it "does not resurrect a var another process deleted when deleting one" do
    with_store do |store|
      tools = tools_for(store)
      ok_json(tools, "set_env_var", %({"key":"A","value":"1"}))
      ok_json(tools, "set_env_var", %({"key":"B","value":"2"}))

      store.set_setting(Gori::Env::PROJECT_VARS_KEY, %([{"key":"B","value":"2"}])) # CLI removed A
      ok_json(tools, "delete_env_var", %({"key":"B"}))

      ok_json(tools, "list_env", "{}").as_a.should be_empty
    end
  end
end

describe "MCP send_websocket scope gate" do
  it "honours a path-scoped include the way send_request does" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("include", "string", "/chat")
      scope.enable
      ws = "GET /chat HTTP/1.1\r\nHost: acme.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
           "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
      rid = store.insert_repeater("https://acme.test", ws.to_slice, false, true, nil, 0)

      # Anchoring the check on a bare "/" refused this — the include names a PATH.
      r = tools_for(store).call("send_websocket", JSON.parse(%({"repeater_id":#{rid}})))
      r.error_code.should_not eq "SCOPE_BLOCKED"
    end
  end

  it "still refuses a target the scope does not include" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("include", "string", "/chat")
      scope.enable
      ws = "GET /admin HTTP/1.1\r\nHost: acme.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
           "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
      rid = store.insert_repeater("https://acme.test", ws.to_slice, false, true, nil, 0)

      r = tools_for(store).call("send_websocket", JSON.parse(%({"repeater_id":#{rid}})))
      r.error_code.should eq "SCOPE_BLOCKED"
    end
  end
end

describe "MCP host overrides" do
  it "reports a duplicate host as a permanent error, not a retryable one" do
    with_store do |store|
      tools = tools_for(store)
      ok_json(tools, "add_host_override", %({"host":"acme.test","ip":"127.0.0.1"}))

      dup = tools.call("add_host_override", JSON.parse(%({"host":"acme.test","ip":"127.0.0.2"})))
      dup.is_error.should be_true
      # PROJECT_BUSY/retryable:true made an agent that trusts `retryable` loop forever (#414).
      dup.error_code.should eq "INVALID_ARGUMENT"
      dup.retryable.should be_false
      dup.text.should contain("already exists")
    end
  end

  it "reports a collision on update as a permanent error too" do
    with_store do |store|
      tools = tools_for(store)
      ok_json(tools, "add_host_override", %({"host":"a.test","ip":"127.0.0.1"}))
      second = ok_json(tools, "add_host_override", %({"host":"b.test","ip":"127.0.0.2"}))

      clash = tools.call("update_host_override", JSON.parse(%({"id":#{second["id"]},"host":"a.test","ip":"127.0.0.3"})))
      clash.error_code.should eq "INVALID_ARGUMENT"
      clash.retryable.should be_false
    end
  end

  it "still allows editing an entry's ip without renaming it" do
    with_store do |store|
      tools = tools_for(store)
      added = ok_json(tools, "add_host_override", %({"host":"a.test","ip":"127.0.0.1"}))
      edited = ok_json(tools, "update_host_override", %({"id":#{added["id"]},"host":"a.test","ip":"10.0.0.1"}))
      edited["ip"].as_s.should eq "10.0.0.1"
    end
  end
end

describe "MCP agent event feed" do
  it "records the intercept write verbs the human needs to see" do
    with_store do |store|
      tools = tools_for(store)
      # No live capturing instance, so each verb fails — the feed logs failures too, which is
      # exactly what an operator wants to see an agent attempting on held traffic.
      tools.call("intercept_forward", JSON.parse(%({"item_id":1}))).is_error.should be_true
      tools.call("intercept_toggle", JSON.parse(%({"enable":false}))).is_error.should be_true

      logged = store.events_after(0_i64, 50).select { |e| e.kind == "agent_action" }.map(&.payload)
      logged.should contain "intercept_forward"
      logged.should contain "intercept_toggle"
    end
  end

  it "records an ACTIVE probe scan but not a passive one" do
    with_store do |store|
      seed_flow(store, "/a")
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")
      tools = tools_for(store)

      ok_json(tools, "probe_scan", "{}")                       # passive — sends nothing
      tools.call("probe_scan", JSON.parse(%({"active":true}))) # sends real requests

      logged = store.events_after(0_i64, 50).select { |e| e.kind == "agent_action" && e.payload == "probe_scan" }
      # The argument decides, not the tool name: a passive rescan would bury the outbound ones.
      logged.size.should eq 1
    end
  end
end

# Publish the bridge blob a capturing TUI would, so the intercept write verbs enqueue for
# real, and auto-ack the first queued command so the tool returns without its 3s poll.
private def with_live_intercept(store, &)
  store.set_intercept_bridge({
    "capturing" => true, "enabled" => true, "direction" => "both", "filter" => "",
    "session_token" => "sess-1", "heartbeat_ms" => Time.utc.to_unix_ms,
  }.to_json)
  spawn do
    120.times do
      if row = store.intercept_commands_after(0_i64, 10).first?
        store.ack_intercept_command(row.id, "edited", "ok")
        break
      end
      sleep 5.milliseconds
    end
  end
  yield
end

# The bytes actually handed to the capturing instance — the only thing that matters here.
private def queued_intercept_bytes(store) : Bytes
  store.intercept_commands_after(0_i64, 10).first.bytes.not_nil!
end

describe "MCP intercept_forward_edit" do
  it "forwards a binary body from raw_base64 byte-for-byte" do
    with_store do |store|
      # A PNG-ish body holding a bare LF and a non-UTF-8 octet: neither survives a JSON
      # string, and the old whole-message CRLF gsub rewrote the 0x0A into 0x0D 0x0A.
      body = Bytes[0x89, 0x50, 0x4e, 0x47, 0x0a, 0xff]
      wire = IO::Memory.new
      wire.print "POST /upload HTTP/1.1\r\nHost: acme.test\r\nContent-Length: #{body.size}\r\n\r\n"
      wire.write body

      with_live_intercept(store) do
        r = tools_for(store).call("intercept_forward_edit",
          JSON.parse(%({"item_id":1,"raw_base64":"#{Base64.strict_encode(wire.to_slice)}"})))
        r.is_error.should be_false
      end

      queued = queued_intercept_bytes(store)
      sep = Gori::MCP::Serialize.head_body_split(queued).not_nil!
      queued[(sep + 4)..].should eq body # untouched, 0x0A and 0xFF included
    end
  end

  it "normalizes CRLF in raw's HEADER block but never in its body" do
    with_store do |store|
      with_live_intercept(store) do
        # Hand-typed LF-only head (must still frame) with an LF-separated text body (must not
        # grow — rewriting it is what desyncs a Content-Length and corrupts non-text bodies).
        raw = "POST /a HTTP/1.1\\nHost: acme.test\\n\\nline1\\nline2"
        tools_for(store).call("intercept_forward_edit",
          JSON.parse(%({"item_id":1,"raw":"#{raw}"}))).is_error.should be_false
      end

      String.new(queued_intercept_bytes(store))
        .should eq "POST /a HTTP/1.1\r\nHost: acme.test\r\nContent-Length: 11\r\n\r\nline1\nline2"
    end
  end

  it "rejects raw and raw_base64 together instead of silently picking one" do
    with_store do |store|
      r = tools_for(store).call("intercept_forward_edit",
        JSON.parse(%({"item_id":1,"raw":"GET / HTTP/1.1\\r\\n\\r\\n","raw_base64":"R0VUIC8gSFRUUC8xLjENCg0K"})))
      r.error_code.should eq "INVALID_ARGUMENT"
      r.text.should contain "only one"
    end
  end

  it "rejects invalid base64 with an actionable message" do
    with_store do |store|
      r = tools_for(store).call("intercept_forward_edit", JSON.parse(%({"item_id":1,"raw_base64":"!!!not base64!!!"})))
      r.error_code.should eq "INVALID_ARGUMENT"
      r.field.should eq "raw_base64"
    end
  end

  it "still requires one of the two" do
    with_store do |store|
      r = tools_for(store).call("intercept_forward_edit", JSON.parse(%({"item_id":1})))
      r.error_code.should eq "INVALID_ARGUMENT"
      r.field.should eq "raw"
    end
  end
end

describe "MCP job project binding" do
  # A finished job outlives a switch_project (only a RUNNING one blocks the switch), and its
  # buffered results carry History flow ids that resolve to unrelated rows in the new DB.
  # Isolated GORI_HOME, like the project-lifecycle spec — switch_project touches the registry.
  it "refuses to serve a finished job's results after switch_project" do
    root = File.tempname("gori-jobhome")
    Dir.mkdir_p(root)
    prev = ENV["GORI_HOME"]?
    ENV["GORI_HOME"] = root
    cur_db = File.join(root, "current.db")
    store = Gori::Store.open(cur_db)
    tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false, db_path: cur_db)
    begin
      Gori::Scope.load(store).add("include", "host", "127.0.0.1")
      started = ok_json(tools, "fuzz_start",
        %({"url":"http://127.0.0.1:1","template":"GET /§x§ HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\n\\r\\n",) +
        %("payloads":[{"list":["a"]}],"max_requests":1,"retries":0,"timeout_ms":50}))
      job_id = started["job_id"].as_s

      # Let the job reach a terminal state so it does not block the switch.
      40.times do
        break unless JSON.parse(tools.call("fuzz_status", JSON.parse(%({"job_id":"#{job_id}"}))).text)["status"].as_s == "running"
        sleep 25.milliseconds
      end
      ok_json(tools, "fuzz_status", %({"job_id":"#{job_id}"}))["job_complete"].as_bool.should be_true

      other = JSON.parse(tools.call("create_project", JSON.parse(%({"name":"Other"}))).text)["slug"].as_s
      ok_json(tools, "switch_project", %({"project":#{other.to_json}}))

      # The job is still remembered, but its results are no longer meaningful here.
      %w[fuzz_status fuzz_results fuzz_stop get_job stop_job].each do |verb|
        r = tools.call(verb, JSON.parse(%({"job_id":"#{job_id}"})))
        r.error_code.should eq "PROJECT_CHANGED"
      end
      # list_jobs still SHOWS it, flagged, so the agent can see why its id refuses.
      listed = ok_json(tools, "list_jobs", "{}")["jobs"].as_a.find { |x| x["job_id"].as_s == job_id }
      listed.should_not be_nil
      listed.not_nil!["project_changed"].as_bool.should be_true
    ensure
      store.close rescue nil
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(root)
    end
  end
end

describe "MCP create_issue evidence" do
  it "refuses a flow_id that names no flow" do
    with_store do |store|
      r = tools_for(store).call("create_issue", JSON.parse(%({"title":"boom","flow_id":9999})))
      r.error_code.should eq "NOT_FOUND"
      # ...and nothing was persisted.
      store.issues.should be_empty
    end
  end

  it "still accepts a real flow_id" do
    with_store do |store|
      id = seed_flow(store, "/a")
      ok_json(tools_for(store), "create_issue", %({"title":"boom","flow_id":#{id}}))["id"].as_i64.should be > 0
    end
  end
end

describe "MCP update_scope_rule" do
  it "refuses a blank pattern instead of silently keeping the old one" do
    with_store do |store|
      tools = tools_for(store)
      added = ok_json(tools, "add_scope_rule", %({"kind":"include","match_type":"host","pattern":"acme.test"}))
      r = tools.call("update_scope_rule", JSON.parse(%({"id":#{added["id"]},"pattern":"   "})))
      r.error_code.should eq "INVALID_ARGUMENT"
      r.field.should eq "pattern"
      # Unchanged, and still gating traffic.
      Gori::Scope.load(store).rules.first.pattern.should eq "acme.test"
    end
  end

  it "still keeps the current pattern when it is omitted entirely" do
    with_store do |store|
      tools = tools_for(store)
      added = ok_json(tools, "add_scope_rule", %({"kind":"include","match_type":"host","pattern":"acme.test"}))
      ok_json(tools, "update_scope_rule", %({"id":#{added["id"]},"kind":"exclude"}))["pattern"].as_s.should eq "acme.test"
    end
  end
end

describe "MCP update_repeater" do
  it "masks a secret in the summary it hands back" do
    with_store do |store|
      Gori::Env.save_project(store, [{"TOKEN", "s3cr3t-value"}])
      tools = tools_for(store)
      created = ok_json(tools, "create_repeater",
        %({"target":"https://acme.test","request":"GET / HTTP/1.1\\r\\nHost: acme.test\\r\\n\\r\\n"}))

      updated = ok_json(tools, "update_repeater",
        %({"id":#{created["id"]},"request":"GET /a?token=s3cr3t-value HTTP/1.1\\r\\nHost: acme.test\\r\\n\\r\\n"}))
      updated["summary"].as_s.should_not contain "s3cr3t-value"
      updated["summary"].as_s.should contain "$TOKEN"
    end
  end
end

describe "MCP get_current_context" do
  it "emits each key exactly once" do
    with_store do |store|
      store.set_setting(Gori::Store::UI_STATE_KEY, %({"active_tab":"history","focus_pane":"body"}))
      lines = drive(store, %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_current_context","arguments":{}}}),
        project_name: "acme")
      raw = lines[0]["result"]["content"][0]["text"].as_s
      # A duplicate key is first/last-wins by parser and rejected outright by strict ones,
      # so count the RAW text — JSON.parse would silently collapse it.
      raw.scan(/"project":/).size.should eq 1
      JSON.parse(raw)["project"].as_s.should eq "acme"
      JSON.parse(raw)["active_tab"].as_s.should eq "history"
    end
  end
end

# #538 — the MCP server is the third caller of Settings.load_project_network. It never opens
# a listening socket (OAST polls a remote collector), so it binds the four outbound/capture
# keys and none of the bind pair.
describe "MCP per-project network overrides" do
  it "installs the project's upstream/timeouts/capture cap at bind time, and no bind address" do
    with_store do |store|
      store.set_setting(Gori::Settings::PROJECT_BIND_HOST_KEY, "0.0.0.0")
      store.set_setting(Gori::Settings::PROJECT_BIND_PORT_KEY, "9100")
      store.set_setting(Gori::Settings::PROJECT_UPSTREAM_KEY, "jump:8888")
      store.set_setting(Gori::Settings::PROJECT_CONNECT_TIMEOUT_KEY, "7")
      store.set_setting(Gori::Settings::PROJECT_IO_TIMEOUT_KEY, "9")
      store.set_setting(Gori::Settings::PROJECT_CAPTURE_MAX_KEY, "16")

      Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)

      Gori::Settings.project_upstream_proxy.should eq("jump:8888")
      Gori::Settings.project_connect_timeout_secs.should eq(7)
      Gori::Settings.project_io_timeout_secs.should eq(9)
      Gori::Settings.project_capture_max_mib.should eq(16)
      # The dial decision Upstream.dial consults — the actual defect in #538 was `send_request`
      # and `fuzz_start` reaching a pinned project's targets DIRECT.
      route = Gori::Settings.upstream_route("example.com")
      {route.kind, route.host, route.port}.should eq({"http", "jump", 8888})
      # Nothing on this surface listens, so the bind pin must not be installed.
      Gori::Settings.project_bind_host.should be_nil
      Gori::Settings.project_bind_port.should be_nil
    ensure
      Gori::Settings.project_upstream_proxy = nil
      Gori::Settings.project_connect_timeout_secs = nil
      Gori::Settings.project_io_timeout_secs = nil
      Gori::Settings.project_capture_max_mib = nil
    end
  end

  it "clears a previous project's pins when it binds an unpinned project" do
    with_store do |store|
      Gori::Settings.project_upstream_proxy = "stale:8888"
      Gori::Settings.project_capture_max_mib = 64

      Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)

      Gori::Settings.project_upstream_proxy.should be_nil
      Gori::Settings.project_capture_max_mib.should be_nil
    ensure
      Gori::Settings.project_upstream_proxy = nil
      Gori::Settings.project_capture_max_mib = nil
    end
  end
end
