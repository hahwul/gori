require "./spec_helper"
require "./support/memory_backend"

# The RPC and LLM decoders reach every surface a decoded pane does (#1590): History detail,
# `gori run show` (JSON through the shared DecodedView emitter; its text sections are pinned in
# spec/cli/run/history_spec.cr) and MCP `get_flow`.
private TOOL_CALL  = %({"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_weather","arguments":{"city":"Seoul"}}})
private MCP_STREAM = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\n\n" \
                     "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"sunny\"}]}}\n\n"
private LLM_REQ    = %({"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]})
private LLM_STREAM = "data: {\"model\":\"gpt-4o-1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hel\"}}]}\n\n" \
                     "data: {\"model\":\"gpt-4o-1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"lo\"},\"finish_reason\":\"stop\"}]}\n\n" \
                     "data: [DONE]\n\n"

private def body_flow(store : Gori::Store, req : String, resp : String, ct : String) : Int64
  head = "POST /x HTTP/1.1\r\nHost: api.test\r\nContent-Type: application/json\r\n\r\n"
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
    method: "POST", target: "/x", http_version: "HTTP/1.1", head: head.to_slice, body: req.to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\nContent-Type: #{ct}\r\n\r\n".to_slice,
    body: resp.to_slice, reason: "OK", content_type: ct, duration_us: 1000_i64))
  id
end

private def decoded_json(detail : Gori::Store::FlowDetail) : JSON::Any
  JSON.parse(JSON.build do |j|
    j.object do
      Gori::DecodedView.emit_json(j, target: detail.row.target,
        req_head: detail.request_head, req_body: detail.request_body,
        resp_head: detail.response_head, resp_body: detail.response_body)
    end
  end)
end

# Every chip label the detail strip draws, walking the panes with Tab.
private def pane_text(store : Gori::Store) : String
  view = Gori::Tui::HistoryView.new
  view.reload(store)
  view.open_detail(store).should be_true
  String.build do |io|
    6.times do
      backend = MemoryBackend.new(120, 30)
      view.render_detail(Gori::Tui::Screen.new(backend), Gori::Tui::Rect.new(0, 0, 120, 30))
      30.times { |y| io << backend.row(y) << '\n' }
      view.toggle_pane
    end
  end
end

describe "JSON-RPC / MCP and LLM decoding — every surface" do
  it "emits json_rpc for an MCP tools/call answered over SSE (CLI json, MCP get_flow, TUI)" do
    with_store do |store|
      id = body_flow(store, TOOL_CALL, MCP_STREAM, "text/event-stream")
      detail = store.get_flow(id).not_nil!
      rpc = decoded_json(detail)["json_rpc"]
      rpc["mcp"].as_bool.should be_true
      rpc["calls"][0]["method"].as_s.should eq("tools/call")
      rpc["calls"][0]["id"].as_i.should eq(7)
      rpc["calls"][0]["label"].as_s.should eq("get_weather")
      rpc["calls"][0]["reply_kind"].as_s.should eq("result")
      rpc["calls"][0]["reply"].as_s.should contain("sunny")
      rpc["stream"][0]["method"].as_s.should eq("notifications/progress")

      JSON.parse(Gori::MCP::Serialize.flow_detail_json(detail))["json_rpc"]["calls"][0]["label"].as_s.should eq("get_weather")

      text = pane_text(store)
      text.should contain("MCP")
      text.should contain("# → tools/call id=7 · get_weather")
    end
  end

  it "emits llm for a streamed OpenAI chat call on every surface" do
    with_store do |store|
      id = body_flow(store, LLM_REQ, LLM_STREAM, "text/event-stream")
      detail = store.get_flow(id).not_nil!
      llm = decoded_json(detail)["llm"]
      llm["dialect"].as_s.should eq("openai-chat")
      llm["model"].as_s.should eq("gpt-4o-1")
      llm["text"].as_s.should eq("Hello")
      llm["streamed"].as_bool.should be_true
      llm["stop_reason"].as_s.should eq("stop")

      JSON.parse(Gori::MCP::Serialize.flow_detail_json(detail))["llm"]["text"].as_s.should eq("Hello")
      pane_text(store).should contain("LLM")
    end
  end

  it "offers no key and no pane for plain JSON" do
    with_store do |store|
      id = body_flow(store, %({"q":"shoes"}), %({"items":[]}), "application/json")
      json = decoded_json(store.get_flow(id).not_nil!)
      json["json_rpc"]?.should be_nil
      json["llm"]?.should be_nil
      text = pane_text(store)
      text.should_not contain("RPC")
      text.should_not contain("LLM")
    end
  end

  it "caps json_rpc lists for MCP and says how many there were" do
    with_store do |store|
      batch = "[" + (1..501).map { |i| %({"jsonrpc":"2.0","id":#{i},"method":"m"}) }.join(",") + "]"
      id = body_flow(store, batch, "", "application/json")
      rpc = JSON.parse(Gori::MCP::Serialize.flow_detail_json(store.get_flow(id).not_nil!))["json_rpc"]
      rpc["calls"].as_a.size.should eq(500)
      rpc["calls_total"].as_i.should eq(501)
      decoded_json(store.get_flow(id).not_nil!)["json_rpc"]["calls"].as_a.size.should eq(501) # the CLI is uncapped
    end
  end
end
