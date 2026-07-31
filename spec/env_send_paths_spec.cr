require "./spec_helper"
require "./support/memory_backend"
require "socket"
require "base64"
require "digest/sha1"

# Issue #524: #519 refused an unresolved `$NAME` at plan-build time, on the five
# `plan.cr` builders. THREE send paths expand without going through a builder, so they
# kept putting the token's own characters on the wire — WebSocket message payloads
# (expanded one frame at a time, after `Repeater::Plan` built the handshake), the TUI's
# intercept forward, and minimize (which dials `Fuzz::Sender` directly, by design).
#
# This file pins the refusal on each of the three, and — just as important — pins the
# NON-refusals: a binary WS frame, a body `$`, and every display path keep working.
#
# The WS scope rule is the one thing #519 did not settle, because a message payload has
# no head to check. It is resolved here as: check the WHOLE payload, and only for frames
# that are EXPANDED — i.e. text frames. The axis #519 drew as an offset (head vs body) is
# carried for a frame by the OPCODE instead. See `Gori::CLI::Run.refuse_unresolved_ws`.

include Gori::Tui

private def with_no_vars(&)
  Gori::Settings.env_prefix = "$"
  Gori::Settings.env_vars = [] of {String, String}
  Gori::Settings.project_env_vars = [] of {String, String}
  yield
ensure
  Gori::Settings.env_vars = [] of {String, String}
  Gori::Settings.project_env_vars = [] of {String, String}
  Gori::Settings.env_prefix = "$"
end

private def with_env_store(&)
  path = File.tempname("gori-env-send", ".db")
  store = Gori::Store.open(path)
  begin
    with_no_vars { yield store }
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def env_tools(store) : Gori::MCP::Tools
  Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
end

# Upgrade, echo the one client frame back, close. Enough to prove a send actually
# reached the wire rather than being refused before the dial.
private def start_env_ws_origin : Int32
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

private WS_UPGRADE = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"

# `ws_out_messages` is private CLI glue; reopen the module for a bare-call wrapper.
# Distinctly named from cli_run_spec.cr's own wrapper — both files compile into the same
# module in a full run, and two identical `def`s would silently redefine each other.
module Gori::CLI::Run
  def self.ws_out_messages_env_for_spec(store : Gori::Store, id : Int64,
                                        override : Array(String)) : Array(Gori::Repeater::WsEngine::OutMsg)
    ws_out_messages(store, id, override)
  end
end

describe "WebSocket message payloads (#524)" do
  # The refusal, on the surface that has a machine-readable answer to assert.
  it "MCP send_websocket refuses an unresolved token in a `messages` argument, naming it" do
    with_env_store do |store|
      rid = store.insert_repeater("ws://127.0.0.1:1", WS_UPGRADE.to_slice, false, true, nil, 0)
      r = env_tools(store).call("send_websocket",
        JSON.parse(%({"repeater_id":#{rid},"messages":["auth $SESSION"],"allow_unscoped":true})))
      r.is_error.should be_true
      r.error_code.should eq("INVALID_ARGUMENT")
      r.text.should contain("$SESSION")    # the refusal names the token…
      r.text.should contain("set_env_var") # …and MCP's own way to fix it
      r.text.should_not contain("connect") # refused BEFORE the dial
    end
  end

  it "MCP send_websocket refuses an unresolved token in a STORED text frame too" do
    with_env_store do |store|
      rid = store.insert_repeater("ws://127.0.0.1:1", WS_UPGRADE.to_slice, false, true, nil, 0)
      store.insert_ws_message(0_i64, "out", 1, %({"token":"$SESSION"}).to_slice, repeater_id: rid)
      store.flush
      r = env_tools(store).call("send_websocket", JSON.parse(%({"repeater_id":#{rid},"allow_unscoped":true})))
      r.is_error.should be_true
      r.text.should contain("$SESSION")
    end
  end

  # THE control the issue calls for. A binary frame is never expanded, so it has no
  # literal token to leak and must not be refused — the `$A` here is two random bytes,
  # exactly the false positive a whole-request check would produce.
  it "still sends a BINARY frame whose bytes happen to contain $A" do
    with_env_store do |store|
      port = start_env_ws_origin
      rid = store.insert_repeater("ws://127.0.0.1:#{port}",
        "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".to_slice,
        false, true, nil, 0)
      payload = Bytes[0x8B, 0x1F, '$'.ord.to_u8, 'A'.ord.to_u8, 0x00, 0xFE, '$'.ord.to_u8, '_'.ord.to_u8]
      store.insert_ws_message(0_i64, "out", 2, payload, repeater_id: rid)
      store.flush

      r = env_tools(store).call("send_websocket",
        JSON.parse(%({"repeater_id":#{rid},"idle_ms":200,"allow_unscoped":true})))
      r.is_error.should be_false
      payload_json = JSON.parse(r.text)
      payload_json["upgraded"].as_bool.should be_true # it dialed and framed — no refusal
      payload_json["messages"].as_a.size.should be >= 1
    end
  end

  # The CLI's own glue, through the existing spec wrapper. The refusal itself `abort`s
  # (verified against the built binary — a spec cannot rescue `exit`), so what is pinned
  # here is the half that must NOT abort: a resolved token expands, and a binary frame
  # carrying token-shaped bytes passes through byte-for-byte.
  it "gori run repeater send leaves a binary stored frame untouched and expands a text one" do
    with_env_store do |store|
      Gori::Settings.env_vars = [{"WHO", "alice"}]
      id = store.insert_repeater("ws://x.test", WS_UPGRADE.to_slice, false, true, nil, 0)
      bin = Bytes[0xFF, '$'.ord.to_u8, 'A'.ord.to_u8, 0x00]
      store.insert_ws_message(0_i64, "out", 2, bin, repeater_id: id)
      store.insert_ws_message(0_i64, "out", 1, "hi $WHO".to_slice, repeater_id: id)
      store.flush

      msgs = Gori::CLI::Run.ws_out_messages_env_for_spec(store, id, [] of String)
      msgs.size.should eq(2)
      msgs[0].opcode.should eq(2)
      msgs[0].payload.should eq(bin) # byte-for-byte, `$A` included
      String.new(msgs[1].payload).should eq("hi alice")
    end
  end

  it "TUI RepeaterView reports the unresolved tokens in its message pane, and none once set" do
    with_env_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "ws.test", port: 443,
        method: "GET", target: "/ws", http_version: "HTTP/1.1",
        head: "GET /ws HTTP/1.1\r\nHost: ws.test\r\nUpgrade: websocket\r\n\r\n".to_slice, body: nil))
      view = RepeaterView.new
      view.load_ws(store.get_flow(id).not_nil!, [%({"t":"$SESSION"}), "ping $SESSION", "plain"])

      view.ws_unresolved_env.should eq(["SESSION"]) # deduplicated across lines

      # A line seeded from a captured BINARY frame — the pane takes stored OUT frames
      # verbatim, opcode and all — is not text an operator typed, and its `$A` is a byte.
      # Refusing on it took out a real WS session (caught driving the built TUI, not by
      # this spec: the status line named `$A, $_` alongside the genuine token).
      view.load_ws(store.get_flow(id).not_nil!,
        [String.new(Bytes[0x8B, 0x1F, 0x24, 0x41, 0x00, 0xFE, 0x24, 0x5F]), "ping $SESSION"])
      view.ws_unresolved_env.should eq(["SESSION"])
      # The DISPLAY path is untouched: the copy menu still reads the literal token.
      String.new(view.ws_out_messages[1].payload).should eq("ping $SESSION")

      Gori::Settings.env_vars = [{"SESSION", "s3cr3t"}]
      view.ws_unresolved_env.should be_empty
      String.new(view.ws_out_messages[1].payload).should eq("ping s3cr3t")
    end
  end
end

describe "Intercept forward (#524)" do
  it "reports an unresolved token in a pending edit — and nothing for an UNEDITED hold" do
    path = File.tempname("gori-env-icv", ".db")
    store = Gori::Store.open(path)
    begin
      with_no_vars do
        ic = Gori::Interceptor.new(Gori::Scope.load(store))
        ic.toggle
        spawn do
          ic.hold_request("GET /a HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
            method: "GET", target: "/a", host: "acme.test", port: 80, scheme: "http")
        end
        Fiber.yield
        view = InterceptView.new
        view.reload(ic)

        # An unedited hold forwards byte-exact and never expands — nothing to check.
        view.unresolved_env.should be_empty
        view.toggle_edit
        view.unresolved_env.should be_empty # opened to VIEW only — still not dirty

        view.edit_move(1, 0) # onto the Host line — still inside the HEAD
        view.edit_end
        view.edit_newline
        "Auth: Bearer $SESSION".each_char { |c| view.edit_insert(c) }
        view.unresolved_env.should eq(["SESSION"])

        Gori::Settings.env_vars = [{"SESSION", "s3cr3t"}]
        view.unresolved_env.should be_empty
        it0 = view.selected_item.not_nil!
        String.new(view.forward_bytes(it0)).should contain("Bearer s3cr3t")
      end
    ensure
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end

  # Head-only, exactly as #519 fixed it for the builders: an edited BINARY body must
  # still forward. `$A` in a body is a byte, not a reference.
  it "does not report a token-shaped byte pair in an edited BODY" do
    path = File.tempname("gori-env-icv2", ".db")
    store = Gori::Store.open(path)
    begin
      with_no_vars do
        ic = Gori::Interceptor.new(Gori::Scope.load(store))
        ic.toggle
        spawn do
          ic.hold_request("POST /u HTTP/1.1\r\nHost: acme.test\r\nContent-Length: 4\r\n\r\nBODY".to_slice,
            method: "POST", target: "/u", host: "acme.test", port: 80, scheme: "http")
        end
        Fiber.yield
        view = InterceptView.new
        view.reload(ic)
        view.toggle_edit
        view.edit_move(99, 0) # down past the blank line — into the BODY
        view.edit_end
        "$A$_".each_char { |c| view.edit_insert(c) }

        view.unresolved_env.should be_empty
        String.new(view.forward_bytes(view.selected_item.not_nil!)).should contain("$A$_")
      end
    ensure
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end
end

describe "Minimize (#524)" do
  it "MCP minimize_repeater refuses an unresolved token in the request head, naming it" do
    with_env_store do |store|
      id = store.insert_repeater("http://acme.test/",
        "GET / HTTP/1.1\r\nHost: acme.test\r\nAuth: Bearer $SESSION\r\n\r\n".to_slice, false, true, nil, 0)
      r = env_tools(store).call("minimize_repeater", JSON.parse(%({"repeater_id":#{id},"allow_unscoped":true})))
      r.is_error.should be_true
      r.error_code.should eq("INVALID_ARGUMENT")
      r.text.should contain("$SESSION")
      r.text.should contain("set_env_var")
    end
  end

  it "MCP minimize_repeater refuses an unresolved TARGET and an unresolved SNI" do
    with_env_store do |store|
      plain = "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice
      bad_target = store.insert_repeater("http://$HOST/", plain, false, true, nil, 0)
      bad_sni = store.insert_repeater("https://acme.test/", plain, false, true, nil, 1, sni: "$SNI_HOST")
      tools = env_tools(store)

      r1 = tools.call("minimize_repeater", JSON.parse(%({"repeater_id":#{bad_target},"allow_unscoped":true})))
      r1.is_error.should be_true
      # Named as an ENV problem, not as "could not determine a target host" — the literal
      # `$HOST` survives Env.expand and would otherwise be reported as an unparseable host.
      r1.text.should contain("$HOST")

      r2 = tools.call("minimize_repeater", JSON.parse(%({"repeater_id":#{bad_sni},"allow_unscoped":true})))
      r2.is_error.should be_true
      r2.text.should contain("$SNI_HOST")
    end
  end

  # The narrowing, pinned: minimize replays captured requests, and a binary body is where
  # `$A` occurs by chance about once per 1.2KB. Refusing on the body would take out
  # essentially every upload session (#519).
  it "does not refuse a token-shaped byte pair in the request BODY" do
    with_env_store do |store|
      id = store.insert_repeater("http://127.0.0.1:1/",
        "POST /u HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 4\r\n\r\n$A$_".to_slice, false, true, nil, 0)
      r = env_tools(store).call("minimize_repeater", JSON.parse(%({"repeater_id":#{id},"allow_unscoped":true})))
      # It gets past the env gate and fails on the (deliberately dead) port instead.
      r.text.should_not contain("unresolved env")
    end
  end
end
