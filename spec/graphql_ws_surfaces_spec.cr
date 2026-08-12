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
    method: "GET", target: "/graphql", http_version: "HTTP/1.1", head: req.to_slice, body: nil))
  resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n"
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 101, head: resp.to_slice, body: nil, reason: "Switching Protocols",
    content_type: nil, duration_us: 1000_i64))
  store.insert_ws_message(id, "out", 1, %({"type":"connection_init","payload":{}}).to_slice)
  store.insert_ws_message(id, "out", 1, SUB_FRAME.to_slice)
  store.insert_ws_message(id, "in", 1, %({"id":"1","type":"next","payload":{"data":{}}}).to_slice)
  id
end

private def tmp_store(&)
  path = File.tempname("gori-gqlws", ".db")
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

describe "GraphQL over WebSocket — the headless surfaces" do
  it "emits `graphql_ws` from the shared DecodedView emitter (CLI json + MCP get_flow)" do
    tmp_store do |store|
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
    tmp_store do |store|
      id = ws_flow(store)
      detail = store.get_flow(id).not_nil!
      projection = Gori::MCP::Serialize.flow_detail_json(detail, store.ws_messages(id))
      JSON.parse(projection)["graphql_ws"].as_a[0]["operation"].as_s.should eq("OnMessage")
    end
  end

  it "emits nothing for a socket that carries no GraphQL" do
    tmp_store do |store|
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
