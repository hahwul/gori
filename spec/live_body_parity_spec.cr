require "./spec_helper"
require "./support/mcp_harness"
require "json"

module Gori::CLI::Run
  def self.live_show_json_for_spec(detail : Store::FlowDetail) : JSON::Any
    JSON.parse(show_json(detail, true, true, [] of Store::WsMessage, BodyCap.new))
  end
end

# An event stream the proxy is still relaying (#1631) shows its events so far on every surface
# that reads a flow, because all of them read it through `Store#get_flow`: MCP `get_flow` (and
# `get_response_body_chunk`, through `Store#response_parts`), and `gori run show` (`history
# show`), which opens the project read-only.
describe "live SSE body parity across MCP get_flow and gori run show (#1631)" do
  it "shows a Pending event stream's events so far on both surfaces" do
    path = File.tempname("gori-spec", ".db")
    store = Gori::Store.open(path)
    begin
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_000_i64, scheme: "http", host: "live.test", port: 80, method: "GET",
        target: "/events", http_version: "HTTP/1.1",
        head: "GET /events HTTP/1.1\r\nHost: live.test\r\n\r\n".to_slice,
        source: Gori::FlowSource::Kind::Proxy))
      head = Gori::Store::CapturedResponse.new(flow_id: id, status: 200,
        head: "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".to_slice,
        content_type: "text/event-stream", state: Gori::Store::FlowState::Pending)
      store.append_live(id, 0_i64, "data: one\n\n".to_slice, head)
      store.append_live(id, 11_i64, "data: two\n\n".to_slice, nil)
      store.flush

      mcp = mcp_ok_json(tools_for(store), "get_flow", %({"id":#{id}}))
      mcp.to_json.should contain("data: two")
      # The pager that `get_flow` points a long body at pages the same bytes, not an empty one.
      mcp_ok_json(tools_for(store), "get_response_body_chunk", %({"flow_id":#{id}})).to_json.should contain("data: two")

      reader = Gori::Store.open(path, read_only: true)
      begin
        detail = reader.get_flow(id).not_nil!
        detail.row.state.should eq(Gori::Store::FlowState::Pending)
        cli = Gori::CLI::Run.live_show_json_for_spec(detail)
        cli["sse_events"].to_json.should contain("two")
        cli["response"]["body"].to_json.should contain("data: two")
      ensure
        reader.close
      end
    ensure
      store.close
      delete_db_files(path)
    end
  end
end
