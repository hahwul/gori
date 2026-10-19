require "../../spec_helper"

# MCP `ws_inject` (#1630), the checks it makes before the bridge, and how `get_flow` marks
# the row it leaves. The live round trip is `Store#send_ws_inject`, shared with
# `gori run intercept inject` and specced there.

private def flow_with(store : Gori::Store, head : String) : Int64
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "echo.test", port: 80, method: "GET",
    target: "/ws", http_version: "HTTP/1.1", head: head.to_slice,
    source: Gori::FlowSource::Kind::Proxy))
end

private def call(store : Gori::Store, args : String)
  tools_for(store).call("ws_inject", JSON.parse(args))
end

private H1_HEAD = "GET /ws HTTP/1.1\r\nHost: echo.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"

describe "MCP ws_inject" do
  it "validates its arguments before anything else" do
    with_store do |store|
      id = flow_with(store, H1_HEAD)
      call(store, %({"flow_id":#{id},"direction":"up"})).text.should contain("expected out | in")
      call(store, %({"flow_id":#{id},"opcode":"cont"})).text.should contain("invalid 'opcode'")
      r = call(store, %({"flow_id":#{id},"payload":"a","payload_base64":"YQ=="}))
      {r.is_error, r.error_code}.should eq({true, "INVALID_ARGUMENT"})
      call(store, %({"flow_id":#{id + 99}})).error_code.should eq("NOT_FOUND")
    end
  end

  it "refuses an HTTP/2 WebSocket by name" do
    with_store do |store|
      id = flow_with(store, "CONNECT /ws HTTP/2\r\n#{Gori::Proxy::H2::HeadCodec::PROTOCOL_MARKER}: websocket\r\n\r\n")
      r = call(store, %({"flow_id":#{id},"allow_unscoped":true}))
      r.error_code.should eq("INVALID_ARGUMENT")
      r.text.should contain("RFC 8441")
    end
  end

  it "is scope-gated against the flow's host" do
    with_store do |store|
      id = flow_with(store, H1_HEAD)
      call(store, %({"flow_id":#{id}})).error_code.should eq("SCOPE_BLOCKED")
    end
  end

  it "says a headless capture cannot inject when no TUI is capturing" do
    with_store do |store|
      id = flow_with(store, H1_HEAD)
      r = call(store, %({"flow_id":#{id},"allow_unscoped":true}))
      r.error_code.should eq("PROJECT_BUSY")
      r.text.should contain("a headless capture cannot inject")
    end
  end

  # A write that started before the ack deadline may still land, so a blind retry could
  # inject twice: the agent is told to look first, not that a retry is safe.
  it "reports an unconfirmed inject as not retryable" do
    with_store do |store|
      id = flow_with(store, H1_HEAD)
      store.set_intercept_bridge({"capturing" => true, "session_token" => "s",
                                  "heartbeat_ms" => Time.utc.to_unix_ms}.to_json)
      r = call(store, %({"flow_id":#{id},"allow_unscoped":true}))
      r.error_code.should eq("NOT_CONFIRMED")
      r.retryable.should be_false
      r.text.should contain("check the flow's messages")
    end
  end

  it "marks an injected frame in get_flow, and leaves a peer's alone" do
    with_store do |store|
      id = flow_with(store, H1_HEAD)
      store.insert_ws_message(id, "in", 1, "peer".to_slice)
      store.insert_ws_message(id, "in", 1, "mine".to_slice, origin: Gori::Store::WsMessage::ORIGIN_GORI)
      flow = JSON.parse(tools_for(store).call("get_flow", JSON.parse(%({"flow_id":#{id}}))).text)
      msgs = flow["ws_messages"]["messages"].as_a
      msgs.map { |m| {m["origin"].as_s, m["injected"]?.try(&.as_bool)} }.should eq([{"target", nil}, {"gori", true}])
    end
  end
end
