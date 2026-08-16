require "./spec_helper"
require "./support/memory_backend"
require "socket"
require "base64"
require "digest/sha1"

# Issue #524 gave three builder-less send paths their own copy of #519's unresolved-`$NAME`
# refusal — WebSocket message payloads (expanded one frame at a time, after
# `Repeater::Plan` built the handshake), the TUI's intercept forward, and minimize (which
# dials `Fuzz::Sender` directly, by design).
#
# ROUND 7, OWNER POLICY: all three refusals are GONE, along with the builder refusal they
# mirrored. A `$NAME` with a value is followed; without one it is a literal string on the
# wire. Never a refusal. The token grammar is byte-identical to GraphQL's `$id`, Mongo's
# `$ne` and JSON Schema's `$ref`, so the refusal made ordinary captured traffic unsendable.
#
# So this file now pins the EXPANSION on each of the three, and the literal fallthrough
# beside it — which is what the refusals were guarding in the first place: that the operator
# can tell what the wire will carry. The NON-refusals it already pinned (a binary WS frame,
# a body `$`, every display path) are unchanged and still here.

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
# Distinctly named from spec/cli/run_spec.cr's own wrapper — both files compile into the same
# module in a full run, and two identical `def`s would silently redefine each other.
module Gori::CLI::Run
  def self.ws_out_messages_env_for_spec(store : Gori::Store, id : Int64,
                                        override : Array(String)) : Array(Gori::Repeater::WsEngine::OutMsg)
    ws_out_messages(store, id, override.map { |t| Gori::Store::WsOutMessage.text(t) })
  end
end

describe "WebSocket message payloads (#524)" do
  # INVERTED for the owner's round-7 policy. These two used to assert that MCP
  # `send_websocket` REFUSED an unresolved token in a frame, before the dial. It no longer
  # does: a `$NAME` with no value is a literal string on the wire, and a WS frame is the
  # place that bites hardest — a captured `{"$where":"this.a==1"}` is a MongoDB injection
  # test, and the refusal's own remedy (set the var) sent `{"WHEREVAL":"this.a==1"}` instead.
  #
  # Asserted against a live origin now rather than as an error string, because "what reached
  # the socket" is the fact that replaced the refusal.
  it "MCP send_websocket sends an unresolved token in a `messages` argument literally" do
    with_env_store do |store|
      port = start_env_ws_origin
      rid = store.insert_repeater("ws://127.0.0.1:#{port}",
        WS_UPGRADE.gsub("acme.test", "127.0.0.1:#{port}").to_slice, false, true, nil, 0)
      r = env_tools(store).call("send_websocket",
        JSON.parse(%({"repeater_id":#{rid},"messages":["auth $SESSION"],"allow_unscoped":true})))
      r.is_error.should be_false
      out = JSON.parse(r.text)["messages"].as_a.first
      out["payload"].as_s.should eq("auth $SESSION")
      # Nothing was substituted, so the reply carries no expansion notice either.
      out["payload_expanded"]?.should be_nil
    end
  end

  # The COMPLEMENT: a token that HAS a value still expands on the same path.
  it "MCP send_websocket still expands a token that HAS a value" do
    with_env_store do |store|
      port = start_env_ws_origin
      # Through the STORE — `Tools` hydrates project env from it, so an in-memory assignment
      # is clobbered before the call runs.
      Gori::Env.save_project(store, [{"SESSION", "s3cr3t"}])
      rid = store.insert_repeater("ws://127.0.0.1:#{port}",
        WS_UPGRADE.gsub("acme.test", "127.0.0.1:#{port}").to_slice, false, true, nil, 0)
      r = env_tools(store).call("send_websocket",
        JSON.parse(%({"repeater_id":#{rid},"messages":["auth $SESSION"],"allow_unscoped":true})))
      r.is_error.should be_false
      # The reply MASKS the resolved secret back to `$SESSION` for display, so the honest
      # machine-readable signal that expansion ran is `payload_expanded`.
      out = JSON.parse(r.text)["messages"].as_a.first
      out["payload_expanded"].as_bool.should be_true
      out["payload_authored"].as_s.should eq("auth $SESSION")
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

  # `load_ws` seeds from a CAPTURED 101 flow, so this pane holds frames the WS relay
  # RECORDED — the premise the old refusal rested on ("a text frame is UTF-8 the operator
  # typed, the same provenance as a header value") is false for exactly this population.
  # A captured `{"$where":…}` / `{"t":"$SESSION"}` is replayed as recorded or not at all,
  # so there is no expansion here and therefore nothing to report unresolved. What the
  # example was really guarding — that a captured BINARY frame's `$A` never becomes a
  # refusal, and that the display path stays literal — is asserted on both sides below.
  it "TUI RepeaterView does not expand or report tokens in a CAPTURED message pane" do
    with_env_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "ws.test", port: 443,
        method: "GET", target: "/ws", http_version: "HTTP/1.1",
        head: "GET /ws HTTP/1.1\r\nHost: ws.test\r\nUpgrade: websocket\r\n\r\n".to_slice, body: nil))
      view = RepeaterView.new
      view.load_ws(store.get_flow(id).not_nil!,
        [%({"t":"$SESSION"}), "ping $SESSION", "plain"].map { |t| Gori::Store::WsOutMessage.text(t) })

      view.evidence?.should be_true
      String.new(view.ws_out_messages[0].payload).should eq(%({"t":"$SESSION"}))

      # A captured BINARY frame is not text an operator typed, and its `$A` is a byte. It is
      # kept in the seed with its opcode, so it still replays; it just never reaches the pane.
      view.load_ws(store.get_flow(id).not_nil!,
        [Gori::Store::WsOutMessage.new(2, Bytes[0x8B, 0x1F, 0x24, 0x41, 0x00, 0xFE, 0x24, 0x5F]),
         Gori::Store::WsOutMessage.text("ping $SESSION")])
      # The DISPLAY path is untouched: the copy menu still reads the literal token.
      String.new(view.ws_out_messages[1].payload).should eq("ping $SESSION")

      # …and setting the var does NOT change the wire. That is the whole point: a capture
      # replayed twice, under two different project configurations, is the same bytes.
      Gori::Settings.env_vars = [{"SESSION", "s3cr3t"}]
      String.new(view.ws_out_messages[1].payload).should eq("ping $SESSION")
    end
  end

  # THE COMPLEMENT, and the half that is still a DRAFT: a hand-authored WS tab (no flow
  # behind it) keeps EXPANDING a resolved token. It used to REFUSE an unresolved one; under
  # the owner's round-7 policy it sends it literally instead, which is the assertion that
  # changed here.
  it "TUI RepeaterView expands a resolved token in a HAND-AUTHORED pane, literal otherwise" do
    with_no_vars do
      view = RepeaterView.new
      view.restore("ws://ws.test", WS_UPGRADE, false, false,
        ws_messages: [Gori::Store::WsOutMessage.text("ping $SESSION")])
      view.evidence?.should be_false
      String.new(view.ws_out_messages[0].payload).should eq("ping $SESSION")

      Gori::Settings.env_vars = [{"SESSION", "s3cr3t"}]
      String.new(view.ws_out_messages[0].payload).should eq("ping s3cr3t")
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

        # An unedited hold forwards byte-exact and never expands.
        view.toggle_edit
        view.edit_move(1, 0) # onto the Host line — still inside the HEAD
        view.edit_end
        view.edit_newline
        "Auth: Bearer $SESSION".each_char { |c| view.edit_insert(c) }
        # Unset: the token forwards LITERALLY. This used to be a refusal that held the whole
        # batch — inverted for the owner's round-7 policy.
        it0 = view.selected_item.not_nil!
        String.new(view.forward_bytes(it0)).should contain("Bearer $SESSION")

        Gori::Settings.env_vars = [{"SESSION", "s3cr3t"}]
        String.new(view.forward_bytes(it0)).should contain("Bearer s3cr3t")
      end
    ensure
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end

  # An edited BINARY body must still forward untouched. `$A` in a body is a byte, not a
  # reference — and now the same is true in the head.
  it "leaves a token-shaped byte pair in an edited BODY on the wire" do
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
  # INVERTED for the owner's round-7 policy: minimize used to refuse an unresolved token in
  # the REQUEST HEAD. It no longer does — only the TARGET and SNI (the dial tuple) are still
  # refused, which the next example pins. The error asserted here is now the ordinary
  # "nothing to dial" one, proving the run got PAST the env gate.
  it "MCP minimize_repeater does not refuse an unresolved token in the request head" do
    with_env_store do |store|
      id = store.insert_repeater("http://acme.test/",
        "GET / HTTP/1.1\r\nHost: acme.test\r\nAuth: Bearer $SESSION\r\n\r\n".to_slice, false, true, nil, 0)
      r = env_tools(store).call("minimize_repeater", JSON.parse(%({"repeater_id":#{id},"allow_unscoped":true})))
      r.text.should_not contain("set_env_var")
      r.text.should_not contain("unresolved env")
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
