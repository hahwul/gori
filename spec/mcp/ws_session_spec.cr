require "../spec_helper"
require "socket"
require "digest/sha1"
require "base64"
require "json"

private alias WS = Gori::Proxy::WS

# A local WS origin on 127.0.0.1: handshake, then `handler` runs with the upgraded socket.
# `echo_origin` answers each TEXT with `re:<text>` and `push` with two unprompted messages.
private class WsOrigin
  getter port : Int32

  def initialize(&@handler : IO -> Nil)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    spawn do
      while conn = @server.accept?
        spawn_with(conn) { |c| serve(c) }
      end
    rescue
    end
  end

  def close : Nil
    @server.close rescue nil
  end

  private def serve(tcp : TCPSocket) : Nil
    tcp.read_timeout = 5.seconds
    head = Gori::Proxy::Codec::Http1.read_head(tcp).not_nil!
    key = String.new(head).each_line
      .find(&.downcase.starts_with?("sec-websocket-key:"))
      .try(&.split(':', 2)[1].strip) || ""
    accept = Base64.strict_encode(Digest::SHA1.digest(key + Gori::Repeater::WsEngine::GUID))
    tcp << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
           "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
    tcp.flush
    @handler.call(tcp)
  rescue
  ensure
    tcp.close rescue nil
  end
end

private def echo_origin : WsOrigin
  WsOrigin.new do |conn|
    while frame = WS.read_frame(conn)
      case frame.opcode
      when WS::OP_TEXT
        msg = String.new(frame.payload)
        if msg == "push"
          conn.write(WS.encode(WS::OP_TEXT, "p1".to_slice, mask: false))
          conn.write(WS.encode(WS::OP_TEXT, "p2".to_slice, mask: false))
          conn.flush
        else
          conn.write(WS.encode(WS::OP_TEXT, "re:#{msg}".to_slice, mask: false))
          conn.flush
        end
      when WS::OP_CLOSE
        conn.write(WS.encode(WS::OP_CLOSE, frame.payload, mask: false))
        conn.flush
        break
      end
    end
  end
end

private def seed_ws_repeater(store, port : Int32) : Int64
  store.insert_repeater(target: "ws://127.0.0.1:#{port}",
    request: ("GET /ws HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n" \
              "Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n").to_slice,
    http2: false, auto_cl: false, flow_id: nil, position: 0)
end

private def call_json(tools, name, args) : JSON::Any
  JSON.parse(tools.call(name, JSON.parse(args)).text)
end

private def eventually(timeout : Time::Span = 3.seconds, &) : Nil
  deadline = Time.instant + timeout
  until yield
    raise "condition not met within #{timeout}" if Time.instant > deadline
    sleep 10.milliseconds
  end
end

describe "MCP ws_session tools" do
  # A cancel between messages answers with what already went out, so a retry does not resend it.
  it "reports the messages a cancelled send already wrote" do
    origin = echo_origin
    begin
      with_store do |store|
        store.add_scope_rule("include", "host", "127.0.0.1")
        tools = tools_for(store)
        rid = seed_ws_repeater(store, origin.port)
        job_id = call_json(tools, "ws_session_open", %({"repeater_id":#{rid}}))["job_id"].as_s
        checks = 0
        res = tools.call("ws_session_send", JSON.parse(%({"job_id":"#{job_id}","messages":["a","b","c"]})),
          cancelled: -> { (checks += 1) > 1 })
        res.is_error.should be_false
        sent = JSON.parse(res.text)
        sent["sent"].as_i.should eq(1)
        sent["cancelled"].as_bool.should be_true
        sent["messages"].as_a.select { |m| m["direction"].as_s == "out" }.map(&.["payload"].as_s).should eq(["a"])
        call_json(tools, "stop_job", %({"job_id":"#{job_id}","wait":true}))
      end
    ensure
      origin.close
    end
  end

  it "opens, sends, reads server push through a get_job cursor, and stops" do
    origin = echo_origin
    begin
      with_store do |store|
        store.add_scope_rule("include", "host", "127.0.0.1")
        tools = tools_for(store)
        rid = seed_ws_repeater(store, origin.port)

        opened = call_json(tools, "ws_session_open", %({"repeater_id":#{rid}}))
        opened["upgraded"].as_bool.should be_true
        job_id = opened["job_id"].as_s
        job_id.should start_with("ws_")

        # A send that waits for the echo.
        sent = call_json(tools, "ws_session_send",
          %({"job_id":"#{job_id}","messages":["hi"],"wait_ms":2000}))
        sent["sent"].as_i.should eq(1)
        rows = sent["messages"].as_a
        rows.any? { |m| m["direction"].as_s == "in" && m["payload"].as_s == "re:hi" }.should be_true
        cursor = sent["cursor"].as_i64

        # Server pushes two messages between sends; a later get_job past the cursor sees them.
        call_json(tools, "ws_session_send", %({"job_id":"#{job_id}","messages":["push"],"wait_ms":2000}))
        eventually do
          j = call_json(tools, "get_job", %({"job_id":"#{job_id}","after":#{cursor}}))
          pushed = j["messages"].as_a.select { |m| m["direction"].as_s == "in" }.map(&.["payload"].as_s)
          pushed.includes?("p1") && pushed.includes?("p2")
        end

        stopped = call_json(tools, "stop_job", %({"job_id":"#{job_id}","wait":true}))
        stopped["stopped"].as_bool.should be_true
        call_json(tools, "get_job", %({"job_id":"#{job_id}"}))["open"].as_bool.should be_false
      end
    ensure
      origin.close
    end
  end

  it "answers an Engine.IO heartbeat on its own" do
    # The origin pings `2`; the session must reply `3` without the agent asking.
    seen = Channel(String).new(4)
    origin = WsOrigin.new do |conn|
      conn.write(WS.encode(WS::OP_TEXT, "2".to_slice, mask: false))
      conn.flush
      while frame = WS.read_frame(conn)
        break if frame.opcode == WS::OP_CLOSE
        seen.send(String.new(frame.payload)) if frame.opcode == WS::OP_TEXT
      end
    end
    begin
      with_store do |store|
        store.add_scope_rule("include", "host", "127.0.0.1")
        tools = tools_for(store)
        rid = seed_ws_repeater(store, origin.port)
        opened = call_json(tools, "ws_session_open", %({"repeater_id":#{rid},"engine_io":true}))
        job_id = opened["job_id"].as_s
        select
        when got = seen.receive
          got.should eq("3")
        when timeout(3.seconds)
          raise "no heartbeat reply"
        end
        call_json(tools, "stop_job", %({"job_id":"#{job_id}"}))
      end
    ensure
      origin.close
    end
  end

  it "caps the number of concurrent sessions and refuses beyond it with a sentence" do
    origin = echo_origin
    begin
      with_store do |store|
        store.add_scope_rule("include", "host", "127.0.0.1")
        tools = tools_for(store)
        rid = seed_ws_repeater(store, origin.port)
        ids = [] of String
        Gori::MCP::Tools::MAX_WS_SESSIONS.times do
          ids << call_json(tools, "ws_session_open", %({"repeater_id":#{rid}}))["job_id"].as_s
        end
        over = tools.call("ws_session_open", JSON.parse(%({"repeater_id":#{rid}})))
        over.is_error.should be_true
        over.text.should contain("too many open WebSocket sessions")
        ids.each { |id| tools.call("stop_job", JSON.parse(%({"job_id":"#{id}"}))) }
      end
    ensure
      origin.close
    end
  end

  it "refuses an out-of-scope origin with SCOPE_BLOCKED and opens with allow_unscoped" do
    origin = echo_origin
    begin
      with_store do |store|
        store.add_scope_rule("include", "host", "only.example.com")
        tools = tools_for(store)
        rid = seed_ws_repeater(store, origin.port)
        blocked = tools.call("ws_session_open", JSON.parse(%({"repeater_id":#{rid}})))
        blocked.is_error.should be_true
        blocked.error_code.should eq("SCOPE_BLOCKED")
        ok = call_json(tools, "ws_session_open", %({"repeater_id":#{rid},"allow_unscoped":true}))
        ok["upgraded"].as_bool.should be_true
        tools.call("stop_job", JSON.parse(%({"job_id":"#{ok["job_id"].as_s}"})))
      end
    ensure
      origin.close
    end
  end

  it "closes every session on switch_project" do
    origin = echo_origin
    begin
      with_store do |store|
        store.add_scope_rule("include", "host", "127.0.0.1")
        tools = tools_for(store)
        rid = seed_ws_repeater(store, origin.port)
        opened = call_json(tools, "ws_session_open", %({"repeater_id":#{rid}}))
        session = tools.@ws_jobs[opened["job_id"].as_s].session

        # An unbind is the simplest binding change; it must close the live session.
        tools.call("switch_project", JSON.parse(%({"unbind":true})))
        eventually { session.closed? }
        tools.@ws_jobs.should be_empty
      end
    ensure
      origin.close
    end
  end

  it "re-checks Layer 2 before each send: a mid-session Sandbox refuses and closes it" do
    origin = echo_origin
    begin
      with_store do |store|
        tools = tools_for(store)
        rid = seed_ws_repeater(store, origin.port)
        # Open with no scope (allow_unscoped), so enabling the Sandbox — which does not
        # allowlist the host — is what newly blocks it.
        opened = call_json(tools, "ws_session_open", %({"repeater_id":#{rid},"allow_unscoped":true}))
        job_id = opened["job_id"].as_s
        session = tools.@ws_jobs[job_id].session

        tools.call("set_sandbox", JSON.parse(%({"enabled":true})))
        # The scope reload behind the gate is throttled to RELOAD_INTERVAL (1 s); wait past it.
        sleep 1.2.seconds

        refused = tools.call("ws_session_send", JSON.parse(%({"job_id":"#{job_id}","messages":["blocked"]})))
        refused.is_error.should be_true
        refused.text.should contain("refused")
        eventually { session.closed? }
      end
    ensure
      origin.close
    end
  end

  it "stamps ended_at on the first get_job after a peer close" do
    # The origin ends the socket at once; the first poll must carry the real end time.
    origin = WsOrigin.new do |conn|
      conn.write(WS.encode(WS::OP_CLOSE, Bytes[0x03, 0xe8], mask: false))
      conn.flush
      sleep 200.milliseconds
    end
    begin
      with_store do |store|
        store.add_scope_rule("include", "host", "127.0.0.1")
        tools = tools_for(store)
        rid = seed_ws_repeater(store, origin.port)
        job_id = call_json(tools, "ws_session_open", %({"repeater_id":#{rid}}))["job_id"].as_s
        session = tools.@ws_jobs[job_id].session
        eventually { session.closed? }

        first = call_json(tools, "get_job", %({"job_id":"#{job_id}"}))
        first["status"].as_s.should eq("done")
        first["ended_at"].as_i64.should eq(session.closed_at.not_nil!.to_unix_ms)
      end
    ensure
      origin.close
    end
  end

  it "points a wrong-kind id at a tool that exists" do
    with_store do |store|
      tools = tools_for(store)
      # A fuzz-looking id to a ws tool, and a ws-looking id to a fuzz tool: both route to
      # get_job, never the nonexistent `fuzz_send` / `ws_session_status`.
      to_ws = tools.call("ws_session_send", JSON.parse(%({"job_id":"fz_9","messages":["x"]})))
      to_ws.text.should contain("use get_job")
      to_ws.text.should_not contain("fuzz_send")
      to_fuzz = tools.call("fuzz_status", JSON.parse(%({"job_id":"ws_9"})))
      to_fuzz.text.should contain("use get_job")
      to_fuzz.text.should_not contain("ws_session_status")
    end
  end

  it "holds a transcript page to the reply byte budget and pages on from its cursor" do
    big = "x" * 40_000
    origin = WsOrigin.new do |conn|
      while frame = WS.read_frame(conn)
        break if frame.opcode == WS::OP_CLOSE
        3.times { conn.write(WS.encode(WS::OP_TEXT, big.to_slice, mask: false)) }
        conn.flush
      end
    end
    begin
      with_store do |store|
        store.add_scope_rule("include", "host", "127.0.0.1")
        tools = tools_for(store)
        rid = seed_ws_repeater(store, origin.port)
        job_id = call_json(tools, "ws_session_open", %({"repeater_id":#{rid}}))["job_id"].as_s
        call_json(tools, "ws_session_send", %({"job_id":"#{job_id}","messages":["go"]}))
        eventually do
          call_json(tools, "get_job", %({"job_id":"#{job_id}","after":3}))["messages"].as_a.size == 1
        end
        first = call_json(tools, "get_job", %({"job_id":"#{job_id}"}))
        first["cut_by"].as_s.should eq("bytes")
        first["has_more"].as_bool.should be_true
        seen = first["messages"].as_a.map(&.["seq"].as_i64)
        seen.size.should be < 4
        first["cursor"].as_i64.should eq(seen.last)
        rest = call_json(tools, "get_job", %({"job_id":"#{job_id}","after":#{seen.last}}))
        rest["messages"].as_a.first["seq"].as_i64.should eq(seen.last + 1)
        call_json(tools, "stop_job", %({"job_id":"#{job_id}"}))
      end
    ensure
      origin.close
    end
  end

  it "waits past a server PING for the real answer" do
    origin = WsOrigin.new do |conn|
      while frame = WS.read_frame(conn)
        break if frame.opcode == WS::OP_CLOSE
        next unless frame.opcode == WS::OP_TEXT
        conn.write(WS.encode(WS::OP_PING, "k".to_slice, mask: false))
        conn.flush
        sleep 300.milliseconds
        conn.write(WS.encode(WS::OP_TEXT, "late".to_slice, mask: false))
        conn.flush
      end
    end
    begin
      with_store do |store|
        store.add_scope_rule("include", "host", "127.0.0.1")
        tools = tools_for(store)
        rid = seed_ws_repeater(store, origin.port)
        job_id = call_json(tools, "ws_session_open", %({"repeater_id":#{rid}}))["job_id"].as_s
        sent = call_json(tools, "ws_session_send", %({"job_id":"#{job_id}","messages":["q"],"wait_ms":3000}))
        sent["messages"].as_a.any? { |m| m["payload"]?.try(&.as_s?) == "late" }.should be_true
        call_json(tools, "stop_job", %({"job_id":"#{job_id}"}))
      end
    ensure
      origin.close
    end
  end
end
