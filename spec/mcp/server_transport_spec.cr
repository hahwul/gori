require "../spec_helper"
require "../support/mcp_harness"

# An origin that completes the TCP handshake and then says nothing, so a send_request
# against it occupies the tools worker until its own idle timeout fires. The socket is held
# by the fiber for the life of the example (the spec's timeout, not the origin's, ends it).
private def start_silent_origin : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    conn = origin.accept?
    sleep 5.seconds
    conn.try(&.close) rescue nil
    origin.close rescue nil
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

# The structuredContent emitter has to answer for shapes no tool in the tree produces
# today (a bare scalar, a text that is not one whole JSON document) — that is the point of
# the guard, so it is reachable from here rather than only through whichever tool happens
# to return the shape this month.
class Gori::MCP::Server
  def spec_structured(text : String) : String
    JSON.build { |j| j.object { emit_structured(j, text) } }
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
    head: "GET #{bad_target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, source: Gori::FlowSource::Kind::Proxy))
end

# A WS origin that upgrades, then reads until the client stops — so a multi-frame send
# (unlike start_mcp_ws_origin's single read-then-close) is not racing a shut socket.
private def start_mcp_ws_sink_origin : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 2.seconds
    head = Gori::Proxy::Codec::Http1.read_head(conn).not_nil!
    key = String.new(head).each_line
      .find(&.downcase.starts_with?("sec-websocket-key:"))
      .try { |line| line.split(':', 2)[1].strip } || ""
    accept = Base64.strict_encode(Digest::SHA1.digest(key + Gori::Repeater::WsEngine::GUID))
    conn << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
            "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
    conn.flush
    buf = Bytes.new(4096)
    loop { break if conn.read(buf) == 0 }
  rescue
  ensure
    conn.try(&.close) rescue nil
    origin.close rescue nil
  end
  port
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

    # One line that is not valid UTF-8 used to END the process: the JSON parse failed (as
    # it should), and the id recovery that answers such a line ran a regex over it — PCRE2
    # refuses a non-UTF-8 subject and raises `ArgumentError`, which nothing on the way out
    # of `run` caught. The client lost every later answer over one byte it never saw.
    it "answers a line whose bytes are not valid UTF-8 and keeps serving" do
      with_store do |store|
        bad = "\xff\xfe" + %({"jsonrpc":"2.0","id":9,"method":"ping"})
        bad.valid_encoding?.should be_false # guard the guard: the fixture must really be invalid
        out = mcp_drive(store, bad, INIT)
        out.size.should eq(2)
        out[0]["error"]["code"].as_i.should eq(-32700) # answered, correlated…
        out[0]["id"].as_i.should eq(9)
        out[1]["result"]["serverInfo"]["name"].as_s.should eq("gori") # …and the session lived on
      end
    end

    # structuredContent is copied through from the tool's own JSON text rather than parsed
    # and rebuilt. These pin the two things the copy has to keep doing: the MCP object shape
    # (an array payload is wrapped under `items`), and the refusal to emit anything that is
    # not exactly one JSON document — a raw copy of a half-JSON text would break the frame.
    it "wraps an array tool payload under items in structuredContent" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"oast_presets","arguments":{}}})
        sc = mcp_drive(store, call)[0]["result"]["structuredContent"]
        sc.as_h.keys.should eq(["items"])
        sc["items"].as_a.should_not be_empty
      end
    end

    it "emits no structuredContent for a text a raw copy could not carry" do
      server = Gori::MCP::Server.new(nil, allow_actions: false, verify_upstream: false,
        input: IO::Memory.new, output: IO::Memory.new)
      server.spec_structured(%({"a":1})).should eq(%({"structuredContent":{"a":1}}))
      server.spec_structured(%([1,2])).should eq(%({"structuredContent":{"items":[1,2]}}))
      server.spec_structured("5").should eq(%({"structuredContent":{"value":5}}))
      server.spec_structured("plain sentence").should eq("{}")
      server.spec_structured(%({"a":1} and then some)).should eq("{}")
    end

    # The reader/worker split exists for exactly this: a `ping` is a liveness probe, and a
    # client whose probe stalls behind a long tool call concludes the server is dead and
    # kills it mid-work. `SlowInput` holds the stream open past the tool call the way a real
    # client's idle connection does, so the ping is genuinely concurrent with the tool.
    it "answers ping while a tool call is still running" do
      with_store do |store|
        port = start_silent_origin # accepts, then never answers: send_request waits out its timeout
        send = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":) +
               %({"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/",) +
               %("allow_unscoped":true,"timeout_ms":1500}}})
        started = Time.instant
        out = mcp_drive(store, send, %({"jsonrpc":"2.0","id":2,"method":"ping"}))
        # The ping came back FIRST — it did not wait out the request in front of it. Before
        # the reader/worker split this line arrived only after the whole timeout elapsed.
        out.map { |r| r["id"].as_i }.should eq([2, 1])
        (Time.instant - started).should be >= 1.second # …and the slow call really was slow
      end
    end

    it "drops the response to a request the client cancelled" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"project_info","arguments":{}}})
        cancel = %({"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7,"reason":"timed out"}})
        # The cancel is read (and recorded) by the reader before the worker gets to id 7.
        out = mcp_drive(store, call, cancel, %({"jsonrpc":"2.0","id":8,"method":"ping"}))
        out.map { |r| r["id"].as_i }.should eq([8]) # 7's answer suppressed, 8 still served
      end
    end

    it "keeps a cancellation for an id it never held from accumulating" do
      with_store do |store|
        cancel = %({"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"never-sent"}})
        out = mcp_drive(store, cancel, %({"jsonrpc":"2.0","id":"never-sent","method":"ping"}))
        # A cancel that arrived before (or without) its request must not silence a LATER
        # request that happens to reuse the id — nothing was pending, so nothing was recorded.
        out.map { |r| r["id"].as_s }.should eq(["never-sent"])
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
        out = mcp_drive(store, INIT)
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
        mcp_drive(store, line)[0]["result"]["protocolVersion"].as_s.should eq("2024-11-05")
      end
    end

    it "falls back to our version for an unsupported/garbage protocolVersion" do
      with_store do |store|
        line = %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}})
        mcp_drive(store, line)[0]["result"]["protocolVersion"].as_s.should eq(Gori::MCP::Server::PROTOCOL_VERSION)
      end
    end

    it "preserves the id type (string stays string)" do
      with_store do |store|
        line = %({"jsonrpc":"2.0","id":"abc","method":"ping"})
        out = mcp_drive(store, line)
        out[0]["id"].as_s.should eq("abc")
        out[0]["result"].as_h.should be_empty
      end
    end

    it "treats a notification (no id) as silent — no response" do
      with_store do |store|
        out = mcp_drive(store, %({"jsonrpc":"2.0","method":"notifications/initialized"}))
        out.should be_empty
      end
    end

    it "answers a message carrying no method at all, id or not" do
      with_store do |store|
        # Silence is for a NOTIFICATION — no id, but a method. An object naming no method is
        # malformed, and JSON-RPC answers it at null rather than dropping it on the floor.
        out = mcp_drive(store, %({"jsonrpc":"2.0","params":{}}))
        out.size.should eq(1)
        out[0]["id"].raw.should be_nil
        out[0]["error"]["code"].as_i.should eq(-32600)
      end
    end
  end

  # SUPPORTED_VERSIONS advertises 2025-03-26 — the one MCP revision that REQUIRES receiving
  # JSON-RPC batches (2025-06-18 removed batching again). A batch used to come back as a
  # single `Invalid Request` at id null, so a client tracking one promise per request in the
  # batch resolved none of them and hung on a revision the server had just claimed.
  describe "JSON-RPC batches" do
    it "answers a batch with one array, correlated per member id" do
      with_store do |store|
        batch = %([{"jsonrpc":"2.0","id":1,"method":"ping"},) +
                %({"jsonrpc":"2.0","method":"notifications/initialized"},) +
                %({"jsonrpc":"2.0","id":"two","method":"ping"}])
        out = mcp_drive(store, batch)
        out.size.should eq(1) # one framed line, not three
        arr = out[0].as_a
        # The notification contributes nothing; the two requests keep their own id types.
        arr.size.should eq(2)
        arr[0]["id"].as_i.should eq(1)
        arr[0]["result"].as_h.should be_empty
        arr[1]["id"].as_s.should eq("two")
        arr[1]["result"].as_h.should be_empty
      end
    end

    it "answers a bad member beside its siblings instead of voiding the batch" do
      with_store do |store|
        batch = %([{"jsonrpc":"2.0","id":1,"method":"ping"},"garbage",) +
                %({"jsonrpc":"2.0","id":9,"method":"nope"}])
        arr = mcp_drive(store, batch)[0].as_a
        arr.size.should eq(3)
        arr[0]["result"].as_h.should be_empty
        arr[1]["id"].raw.should be_nil # a non-object member has no id to answer with
        arr[1]["error"]["code"].as_i.should eq(-32600)
        arr[2]["id"].as_i.should eq(9)
        arr[2]["error"]["code"].as_i.should eq(-32601)
      end
    end

    it "stays silent for an all-notification batch" do
      with_store do |store|
        # `[]` back would be a protocol violation of its own, not a harmless empty answer.
        batch = %([{"jsonrpc":"2.0","method":"notifications/initialized"},) +
                %({"jsonrpc":"2.0","method":"notifications/cancelled"}])
        mcp_drive(store, batch).should be_empty
      end
    end

    it "answers an unparseable batch at id null, not at its first member's id" do
      with_store do |store|
        # `1e400` is legal JSON that Crystal's Float64 parser refuses, so the whole LINE
        # fails to parse. recover_id scrapes the first `"id"` it sees — in a batch that id
        # belongs to member 1, and answering the batch under it resolves exactly one of the
        # client's promises while every other member hangs.
        batch = %([{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"limit":1e400}},) +
                %({"jsonrpc":"2.0","id":2,"method":"ping"}])
        out = mcp_drive(store, batch)
        out.size.should eq(1)
        out[0]["id"].raw.should be_nil
        out[0]["error"]["code"].as_i.should eq(-32700)
      end
    end

    it "answers a member with neither method nor id, keeping the array aligned" do
      with_store do |store|
        # A client correlating responses to members BY POSITION needs one element per
        # member; a silently skipped member shifts every response after it.
        batch = %([{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","params":{}}])
        arr = mcp_drive(store, batch)[0].as_a
        arr.size.should eq(2)
        arr[0]["id"].as_i.should eq(1)
        arr[1]["id"].raw.should be_nil
        arr[1]["error"]["code"].as_i.should eq(-32600)
      end
    end

    it "rejects an empty batch with a single null-id error" do
      with_store do |store|
        out = mcp_drive(store, "[]")
        out.size.should eq(1)
        out[0]["id"].raw.should be_nil
        out[0]["error"]["code"].as_i.should eq(-32600)
      end
    end

    it "runs real tool calls inside a batch" do
      with_store do |store|
        mcp_seed_flow(store, "ex.com", "GET", "/a", 200)
        batch = %([{"jsonrpc":"2.0","id":1,"method":"tools/call",) +
                %("params":{"name":"list_history","arguments":{"limit":1}}},) +
                %({"jsonrpc":"2.0","id":2,"method":"tools/list"}])
        arr = mcp_drive(store, batch)[0].as_a
        arr.size.should eq(2)
        arr[0]["result"]["isError"].as_bool.should be_false
        JSON.parse(arr[0]["result"]["content"][0]["text"].as_s).as_a.size.should eq(1)
        arr[1]["result"]["tools"].as_a.should_not be_empty
      end
    end
  end

  describe "tools/list" do
    it "lists read tools and gates action/write tools behind allow_actions" do
      with_store do |store|
        listing = %({"jsonrpc":"2.0","id":2,"method":"tools/list"})

        full = mcp_drive(store, listing, allow_actions: true)[0]["result"]["tools"].as_a
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

        ro = mcp_drive(store, listing, allow_actions: false)[0]["result"]["tools"].as_a
        ro_names = ro.map(&.["name"].as_s)
        ro_names.should contain("list_history")
        ro_names.should_not contain("send_request")
        ro_names.should_not contain("create_issue")
        ro_names.should_not contain("update_issue")
      end
    end
  end

  describe "error channels" do
    it "returns -32600 with echoed id when method is missing" do
      with_store do |store|
        out = mcp_drive(store, %({"jsonrpc":"2.0","id":"req-1"}))
        out[0]["error"]["code"].as_i.should eq(-32600)
        out[0]["id"].as_s.should eq("req-1")
      end
    end

    it "answers a parse error with id null and keeps serving" do
      with_store do |store|
        # Correlated by id, not by position: `ping` is answered by the READER, ahead of a
        # queue it must never wait behind, so it can legitimately overtake the error that
        # was read before it. JSON-RPC pairs a response to its request by id alone.
        out = mcp_drive(store, "{not json", %({"jsonrpc":"2.0","id":1,"method":"ping"}))
        parse_error = out.find! { |r| r["error"]?.try(&.["code"].as_i) == -32700 }
        parse_error["id"].raw.should be_nil
        pong = out.find! { |r| r["id"]?.try(&.as_i?) == 1 }
        pong["result"].as_h.should be_empty # loop recovered
      end
    end

    it "returns -32601 for an unknown method" do
      with_store do |store|
        out = mcp_drive(store, %({"jsonrpc":"2.0","id":1,"method":"bogus/method"}))
        out[0]["error"]["code"].as_i.should eq(-32601)
      end
    end

    it "returns isError (not a protocol error) for an unknown tool" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nope","arguments":{}}})
        resp = mcp_drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["error"]?.should be_nil
      end
    end
  end

  describe "structured error contract" do
    it "codes an unknown tool UNKNOWN_TOOL with a structured error object" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nope","arguments":{}}})
        err = mcp_drive(store, call)[0]["result"]["structuredContent"]
        err["error_code"].as_s.should eq("UNKNOWN_TOOL")
        err["message"].as_s.should contain("nope")
        err["retryable"].as_bool.should be_false
      end
    end

    it "codes a missing/invalid id INVALID_ARGUMENT (the residual default)" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_flow","arguments":{}}})
        err = mcp_drive(store, call)[0]["result"]["structuredContent"]
        err["error_code"].as_s.should eq("INVALID_ARGUMENT")
      end
    end

    it "codes a bad flow id NOT_FOUND" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":9999}}})
        err = mcp_drive(store, call)[0]["result"]["structuredContent"]
        err["error_code"].as_s.should eq("NOT_FOUND")
      end
    end

    it "codes a query that compiles to nothing QUERY_SYNTAX with field:query" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{"query":"status:>=foo"}}})
        err = mcp_drive(store, call)[0]["result"]["structuredContent"]
        err["error_code"].as_s.should eq("QUERY_SYNTAX")
        err["field"].as_s.should eq("query")
      end
    end

    it "codes a disabled action tool TOOL_DISABLED in read-only mode" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"x"}}})
        err = mcp_drive(store, call, allow_actions: false)[0]["result"]["structuredContent"]
        err["error_code"].as_s.should eq("TOOL_DISABLED")
      end
    end

    it "leaves a success payload's structuredContent unchanged (no error object)" do
      with_store do |store|
        mcp_seed_flow(store, "h.test", "GET", "/a", 200)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_history","arguments":{}}})
        resp = mcp_drive(store, call)[0]["result"]
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
          body: nil, source: Gori::FlowSource::Kind::Proxy))
        store.update_response(Gori::Store::CapturedResponse.new(
          flow_id: id, status: 200,
          head: "HTTP/1.1 200 OK\r\nSet-Cookie: sid=xyz\r\nContent-Type: text/plain\r\n\r\n".to_slice, body: nil))

        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":#{id}}}})
        p = mcp_tool_payload(mcp_drive(store, call)[0])
        p["request_head"].as_s.should contain("Authorization: [REDACTED]")
        p["request_head"].as_s.should contain("Cookie: [REDACTED]")
        p["request_head"].as_s.should_not contain("topsecret")
        p["request_head"].as_s.should_not contain("sid=abc")
        p["request_head"].as_s.should contain("Host: h.test") # non-sensitive kept
        p["response_head"].as_s.should contain("Set-Cookie: [REDACTED]")
        p["response_head"].as_s.should_not contain("sid=xyz")
        p["sensitive_headers_redacted"].as_bool.should be_true

        rawc = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":#{id},"include_sensitive":true}}})
        raw = mcp_tool_payload(mcp_drive(store, rawc)[0])
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
        p = mcp_tool_payload(mcp_drive(store, call)[0])
        p["sensitive_headers_redacted"].as_bool.should be_true
        sess = p["sessions"][0]
        sess["request"].as_s.should contain("Authorization: [REDACTED]")
        sess["request"].as_s.should_not contain("topsecret")

        rawc = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_repeater_context","arguments":{"id":#{rid},"include_content":true,"include_sensitive":true}}})
        raw = mcp_tool_payload(mcp_drive(store, rawc)[0])
        raw["sessions"][0]["request"].as_s.should contain("Bearer topsecret")
      end
    end
  end
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

describe "Gori::MCP::Server WebSocket frame shapes" do
  # `messages` was typed "array of strings" and every entry became `OutMsg.new(1, …)`, so
  # opcode 1 / FIN=1 / RSV=0 / masked / honest-length was the only frame this tool could ever
  # produce. A bare string still means exactly that; everything else is opt-in.
  it "accepts the object form and the WsFrameSpec string form, and reports what it framed" do
    with_store do |store|
      port = start_mcp_ws_sink_origin
      request = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
      repeater_id = store.insert_repeater("ws://127.0.0.1:#{port}", request.to_slice, false, true, nil, 0)
      msgs = %([{"opcode":9,"text":"ping-shaped"},) +
             %({"opcode":1,"rsv":4,"text":"rsv1"},) +
             %({"opcode":1,"mask":false,"text":"bare"},) +
             %({"opcode":1,"declared_len":4096,"text":"lies"},) +
             %("opcode=close,hex=03ea627965",) +
             %("plain string is still just text"])
      call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_websocket","arguments":) +
             %({"repeater_id":#{repeater_id},"messages":#{msgs},"idle_ms":100,"allow_unscoped":true}}})
      resp = mcp_drive(store, call, verify_upstream: false)[0]
      resp["result"]["isError"].as_bool.should be_false
      out = mcp_tool_payload(resp)["messages"].as_a.select { |m| m["direction"].as_s == "out" }
      out.map { |m| m["frame"].as_s }.should eq([
        "PING", "TEXT rsv=4", "TEXT unmasked", "TEXT len=4096", "CLOSE", "TEXT",
      ])
      out[4]["close_code"].as_i.should eq(1002)
      out[4]["close_reason"].as_s.should eq("bye")
      out[5]["payload"].as_s.should eq("plain string is still just text")
    end
  end

  it "persists a shaped ws_out_messages entry and the key toggle on create_repeater" do
    with_store do |store|
      call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_repeater","arguments":) +
             %({"target":"ws://127.0.0.1:1","request":"GET /ws HTTP/1.1\\r\\nHost: h\\r\\nUpgrade: websocket\\r\\n\\r\\n",) +
             %("ws_keep_key":true,"ws_out_messages":[{"opcode":9,"text":"p"},{"opcode":1,"rsv":4,"text":"r"}]}}})
      resp = mcp_drive(store, call)[0]
      resp["result"]["isError"].as_bool.should be_false
      id = JSON.parse(resp["result"]["content"][0]["text"].as_s)["id"].as_i64
      rows = store.ws_messages_for_repeater(id)
      rows.map(&.opcode).should eq([9, 1])
      rows[1].shape.rsv.should eq(4)
      store.get_repeater(id).not_nil!.ws_keep_key?.should be_true
    end
  end
end

# MCP `get_flow`'s ws_messages projection, and the V7 shape reaching it.
#
# `gori run show --format json` has emitted the shape since the shape existed; MCP did not,
# so the AGENT surface — the one that cannot look at the wire itself — was the single place a
# captured RSV1 frame, an unmasked client frame, or a CLOSE's code was invisible. Both
# projections now call one emitter, so they cannot drift again.
describe "MCP ws_messages shape projection" do
  it "emits fin/rsv/masked/frames only when they differ from an ordinary frame" do
    plain = Gori::Store::WsMessage.new(1_i64, 1_i64, nil, 0_i64, "out", 1, "hi".to_slice)
    json = JSON.build { |j| j.object { Gori::MCP::Serialize.emit_ws_messages(j, [plain]) } }
    json.should_not contain("\"fin\"")
    json.should_not contain("\"rsv\"")
    json.should_not contain("\"masked\"")
    json.should_not contain("\"frames\"")
  end

  it "emits the shape for a frame an operator would come here to see" do
    shaped = Gori::Store::WsMessage.new(1_i64, 1_i64, nil, 0_i64, "out", 1, "x".to_slice,
      Gori::Store::WsShape.new(fin: false, rsv: 4, masked: false, frames: 2))
    json = JSON.build { |j| j.object { Gori::MCP::Serialize.emit_ws_messages(j, [shaped]) } }
    json.should contain("\"fin\":false")
    json.should contain("\"rsv\":4")
    json.should contain("\"masked\":false")
    json.should contain("\"frames\":2")
  end

  it "emits a CLOSE's code and reason — the most diagnostic frame there is" do
    payload = Bytes[0x03, 0xEA] + "bye-reason".to_slice
    close = Gori::Store::WsMessage.new(1_i64, 1_i64, nil, 0_i64, "in", 8, payload)
    json = JSON.build { |j| j.object { Gori::MCP::Serialize.emit_ws_messages(j, [close]) } }
    json.should contain("\"close_code\":1002")
    json.should contain("\"close_reason\":\"bye-reason\"")
    json.should contain("\"type\":\"close\"")
  end
end
