require "./spec_helper"

# The decode panes are all keyed on a request or response BODY, and the surfaces that render
# them are four: History, `gori run show` (text and JSON), and MCP `get_flow`. A 101 flow has
# no body, so a GraphQL subscription reached NONE of them. These pin that the transcript now
# feeds the shared emitter — the one `gori run show --format json` and MCP both go through, so
# the two cannot diverge.
private SUB_FRAME = %({"id":"1","type":"subscribe","payload":{"operationName":"OnMessage",) +
                    %("query":"subscription OnMessage { messageAdded { id } }"}})

private def ws_flow(store : Gori::Store) : Int64
  req = "GET /graphql HTTP/1.1\r\nHost: api.test\r\nUpgrade: websocket\r\n" \
        "Sec-WebSocket-Protocol: graphql-transport-ws\r\n\r\n"
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
    method: "GET", target: "/graphql", http_version: "HTTP/1.1", head: req.to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
  resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n"
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 101, head: resp.to_slice, body: nil, reason: "Switching Protocols",
    content_type: nil, duration_us: 1000_i64))
  store.insert_ws_message(id, "out", 1, %({"type":"connection_init","payload":{}}).to_slice)
  store.insert_ws_message(id, "out", 1, SUB_FRAME.to_slice)
  store.insert_ws_message(id, "in", 1, %({"id":"1","type":"next","payload":{"data":{}}}).to_slice)
  id
end

describe "GraphQL over WebSocket — the headless surfaces" do
  it "emits `graphql_ws` from the shared DecodedView emitter (CLI json + MCP get_flow)" do
    with_store do |store|
      id = ws_flow(store)
      detail = store.get_flow(id).not_nil!
      json = JSON.parse(JSON.build do |j|
        j.object do
          Gori::DecodedView.emit_json(j, target: detail.row.target,
            req_head: detail.request_head, req_body: detail.request_body,
            resp_head: detail.response_head, resp_body: detail.response_body,
            ws_messages: store.ws_messages(id))
        end
      end)
      ops = json["graphql_ws"].as_a
      ops.size.should eq(1)
      ops[0]["frame"].as_i.should eq(2)
      ops[0]["direction"].as_s.should eq("out")
      ops[0]["type"].as_s.should eq("subscribe")
      ops[0]["id"].as_s.should eq("1")
      ops[0]["operation"].as_s.should eq("OnMessage")
      ops[0]["query"].as_s.should contain("messageAdded")
      # `graphql` stays the ONE operation a request BODY holds — a 101 flow has none, and
      # folding the two keys together would make a reader guess which it had.
      json["graphql"]?.should be_nil
    end
  end

  it "reaches MCP get_flow's projection" do
    with_store do |store|
      id = ws_flow(store)
      detail = store.get_flow(id).not_nil!
      projection = Gori::MCP::Serialize.flow_detail_json(detail, store.ws_messages(id))
      JSON.parse(projection)["graphql_ws"].as_a[0]["operation"].as_s.should eq("OnMessage")
    end
  end

  it "emits nothing for a socket that carries no GraphQL" do
    with_store do |store|
      id = ws_flow(store)
      store.ws_messages(id) # sanity: the flow exists
      json = JSON.parse(JSON.build do |j|
        j.object do
          Gori::DecodedView.emit_json(j, target: "/ws",
            req_head: nil, req_body: nil, resp_head: nil, resp_body: nil,
            ws_messages: [Gori::Store::WsMessage.new(0_i64, id, nil, 0_i64, "out", 1, %({"a":1}).to_slice)])
        end
      end)
      json["graphql_ws"]?.should be_nil
    end
  end
end

# The shared headless projection carries a binary document too, so `gori run show --format json`
# and MCP `get_flow` cannot grow separate ideas of what a msgpack body says.
describe Gori::DecodedView do
  it "emits a MessagePack response body as the same JSON the pane renders" do
    json = JSON.build do |j|
      j.object do
        Gori::DecodedView.emit_json(j, target: "/rpc",
          req_head: "POST /rpc HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, req_body: nil,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/msgpack\r\n\r\n".to_slice,
          resp_body: Bytes[0x82, 0xa1, 0x61, 0x01, 0xa1, 0x62, 0xc4, 0x02, 0xff, 0xfe])
      end
    end
    doc = JSON.parse(json)["binary_documents"].as_a
    doc.size.should eq(1)
    doc[0]["side"].as_s.should eq("response")
    doc[0]["format"].as_s.should eq("msgpack")
    doc[0]["complete"].as_bool.should be_true
    doc[0]["json"].as_s.should eq(%({"a":1,"b":{"$bin":"//4="}}))
  end

  it "says nothing for a flow that carries none" do
    json = JSON.build do |j|
      j.object do
        Gori::DecodedView.emit_json(j, target: "/", req_head: nil, req_body: nil,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n".to_slice,
          resp_body: %({"a":1}).to_slice)
      end
    end
    JSON.parse(json).as_h.has_key?("binary_documents").should be_false
  end
end
