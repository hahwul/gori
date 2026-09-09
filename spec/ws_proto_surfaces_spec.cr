require "./spec_helper"

# The decode panes are keyed on a request or response BODY, and a 101 flow has neither — its
# bytes live in `ws_messages`. `graphql_ws` closed that for ONE subprotocol; these pin that
# the rest of the family reaches the same headless surfaces through the same shared emitter,
# so `gori run show --format json` and MCP `get_flow` cannot grow separate ideas of what a
# socket speaks.
private def cable_flow(store : Gori::Store) : Int64
  req = "GET /cable HTTP/1.1\r\nHost: api.test\r\nUpgrade: websocket\r\n" \
        "Sec-WebSocket-Protocol: actioncable-v1-json\r\n\r\n"
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
    method: "GET", target: "/cable", http_version: "HTTP/1.1", head: req.to_slice, body: nil,
    source: Gori::FlowSource::Kind::Proxy))
  resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
         "Sec-WebSocket-Protocol: actioncable-v1-json\r\n\r\n"
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 101, head: resp.to_slice, body: nil, reason: "Switching Protocols",
    content_type: nil, duration_us: 1000_i64))
  store.insert_ws_message(id, "in", 1, %({"type":"welcome"}).to_slice)
  store.insert_ws_message(id, "out", 1,
    {"command" => "subscribe", "identifier" => %({"channel":"ChatChannel","room":"1"})}.to_json.to_slice)
  store.insert_ws_message(id, "out", 1,
    {"command" => "message", "identifier" => %({"channel":"ChatChannel"}),
     "data" => %({"action":"speak","message":"hi"})}.to_json.to_slice)
  id
end

private def decoded_json(detail : Gori::Store::FlowDetail,
                         msgs : Array(Gori::Store::WsMessage)) : JSON::Any
  JSON.parse(JSON.build do |j|
    j.object do
      Gori::DecodedView.emit_json(j, target: detail.row.target,
        req_head: detail.request_head, req_body: detail.request_body,
        resp_head: detail.response_head, resp_body: detail.response_body,
        ws_messages: msgs)
    end
  end)
end

describe "WebSocket subprotocols — the headless surfaces" do
  it "emits `ws_proto` from the shared DecodedView emitter (CLI json + MCP get_flow)" do
    with_store do |store|
      id = cable_flow(store)
      json = decoded_json(store.get_flow(id).not_nil!, store.ws_messages(id))
      json["ws_proto"]["protocols"].as_a.map(&.as_s).should eq(["action_cable"])
      frames = json["ws_proto"]["frames"].as_a
      frames.size.should eq(3)
      frames[0]["kind"].as_s.should eq("welcome")
      frames[0]["direction"].as_s.should eq("in")
      frames[1]["frame"].as_i.should eq(2)
      frames[1]["kind"].as_s.should eq("subscribe")
      frames[1]["name"].as_s.should eq("ChatChannel")
      # The channel and the action both live a layer down, inside JSON strings — lifting them
      # out is the whole reason the pane beats reading the raw frame.
      frames[2]["name"].as_s.should eq("ChatChannel#speak")
      frames[2]["payload"].as_s.should contain(%("action":"speak"))
      # `via` is present only for a frame that arrived inside a wrapper.
      frames[2]["via"]?.should be_nil
      # And the GraphQL keys stay out of it: this socket carries neither.
      json["graphql_ws"]?.should be_nil
      json["graphql"]?.should be_nil
    end
  end

  it "reaches MCP get_flow's projection" do
    with_store do |store|
      id = cable_flow(store)
      projection = JSON.parse(
        Gori::MCP::Serialize.flow_detail_json(store.get_flow(id).not_nil!, store.ws_messages(id)))
      projection["ws_proto"]["frames"].as_a[1]["name"].as_s.should eq("ChatChannel")
    end
  end

  it "emits nothing for a socket that carries none of the family" do
    with_store do |store|
      id = cable_flow(store)
      json = JSON.parse(JSON.build do |j|
        j.object do
          Gori::DecodedView.emit_json(j, target: "/ws",
            req_head: nil, req_body: nil, resp_head: nil, resp_body: nil,
            ws_messages: [Gori::Store::WsMessage.new(0_i64, id, nil, 0_i64, "out", 1,
              %({"type":"chat","text":"hi"}).to_slice)])
        end
      end)
      json["ws_proto"]?.should be_nil
    end
  end

  # A SockJS transcript decodes under two protocols at once — the wrapper and what it carries
  # — which is why this is ONE key with a discriminator rather than a key per subprotocol.
  it "names both protocols when one wraps the other" do
    with_store do |store|
      id = cable_flow(store)
      msgs = ["o", "a" + [%(42["chat",{"body":"hi"}])].to_json].map_with_index do |p, i|
        Gori::Store::WsMessage.new(i.to_i64, id, nil, 0_i64, "out", 1, p.to_slice)
      end
      json = JSON.parse(JSON.build do |j|
        j.object do
          Gori::DecodedView.emit_json(j, target: "/ws", req_head: nil, req_body: nil,
            resp_head: nil, resp_body: nil, ws_messages: msgs)
        end
      end)
      json["ws_proto"]["protocols"].as_a.map(&.as_s).should eq(["socketio", "sockjs"])
      inner = json["ws_proto"]["frames"].as_a[1]
      inner["protocol"].as_s.should eq("socketio")
      inner["via"].as_s.should eq("sockjs")
      inner["name"].as_s.should eq("chat")
    end
  end
end
