require "./spec_helper"

private def head(ct : String) : Bytes
  "HTTP/1.1 200 OK\r\nContent-Type: #{ct}\r\n\r\n".to_slice
end

private REQ_HEAD = "POST /mcp HTTP/1.1\r\nHost: mcp.test\r\nContent-Type: application/json\r\n\r\n".to_slice

private def rpc(req : String, resp : String, ct = "application/json") : Gori::JsonRpc::Exchange?
  Gori::JsonRpc.from_flow(REQ_HEAD, req.to_slice, head(ct), resp.to_slice)
end

private TOOL_CALL = %({"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_weather","arguments":{"city":"Seoul"}}})

describe Gori::JsonRpc do
  it "pairs a POST answered with application/json" do
    ex = rpc(%({"jsonrpc":"2.0","id":1,"method":"sum","params":[1,2]}), %({"jsonrpc":"2.0","id":1,"result":3})).not_nil!
    ex.calls.size.should eq(1)
    c = ex.calls[0]
    c.method.should eq("sum")
    c.id.should eq(JSON::Any.new(1_i64))
    c.params.not_nil!.should contain("2")
    c.reply.should eq("3")
    c.error.should be_false
    ex.stream.should be_empty
    Gori::JsonRpc.mcp?(ex).should be_false
    Gori::JsonRpc.summary(ex).should start_with("JSON-RPC · 1 call")
  end

  it "pairs an MCP tools/call answered over SSE and lists the stream's notifications apart" do
    body = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progress\":1}}\n\n" \
           "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"sunny\"}]}}\n\n"
    ex = rpc(TOOL_CALL, body, "text/event-stream").not_nil!
    ex.calls.size.should eq(1)
    ex.calls[0].label.should eq("get_weather")
    ex.calls[0].reply.not_nil!.should contain("sunny")
    ex.stream.map(&.method).should eq(["notifications/progress"])
    Gori::JsonRpc.mcp?(ex).should be_true
    Gori::JsonRpc.summary(ex).should eq("MCP · 1 call · 1 stream message · tools/call get_weather")
    Gori::JsonRpc.display(ex).should contain("# ⇠ stream notifications/progress")
  end

  it "pairs a batch by id whatever the reply order, and says which call went unanswered" do
    req = %([{"jsonrpc":"2.0","id":1,"method":"a"},{"jsonrpc":"2.0","id":"1","method":"b"},) +
          %({"jsonrpc":"2.0","id":3,"method":"c"},{"jsonrpc":"2.0","method":"notify"}])
    resp = %([{"jsonrpc":"2.0","id":"1","result":"B"},{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"nope"}}])
    ex = rpc(req, resp).not_nil!
    ex.calls.map(&.method).should eq(%w[a b c notify])
    ex.calls[0].error.should be_true
    ex.calls[0].reply.not_nil!.should contain("nope")
    ex.calls[1].reply.should eq(%("B")) # the string id "1" is not the number 1
    ex.calls[2].reply.should be_nil
    Gori::JsonRpc.summary(ex).should contain("1 unanswered") # the notification expects none
    text = Gori::JsonRpc.display(ex)
    text.should contain("no reply in this flow")
    text.should contain("notification, no reply expected")
  end

  it "offers nothing for plain JSON, or a stream answering a non-RPC request" do
    rpc(%({"model":"x","id":1,"method":"sum"}), %({"id":1,"result":3})).should be_nil
    rpc(%({"q":"shoes"}), "data: {\"jsonrpc\":\"2.0\",\"method\":\"x\"}\n\n", "text/event-stream").should be_nil
  end

  it "lists a bodiless GET stream's messages unpaired" do
    body = "data: {\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{}}\n\n"
    ex = Gori::JsonRpc.from_flow("GET /sse HTTP/1.1\r\n\r\n".to_slice, nil,
      head("text/event-stream"), body.to_slice).not_nil!
    ex.calls.should be_empty
    ex.stream.size.should eq(1)
    ex.stream[0].id.should eq(JSON::Any.new(9_i64))
  end

  # Hostile or merely unusual JSON: `JSON::Any#[]?` raises on a non-object, and every History
  # open, `gori run show` and MCP `get_flow` runs this decoder.
  it "never raises on JSON that is not an object" do
    ["[1,2]", "42", "null", %("x"), %([{"jsonrpc":"2.0","method":"m","id":1}, 5])].each do |req|
      rpc(req, "[1]")
    end
    sse = "data: 1\n\ndata: \"ping\"\n\ndata: [1]\n\n"
    Gori::JsonRpc.from_flow("GET / HTTP/1.1\r\n\r\n".to_slice, nil, head("text/event-stream"), sse.to_slice).should be_nil
    ex = rpc(%({"jsonrpc":"2.0","id":1,"method":"tools/call","params":[1]}), %({"jsonrpc":"2.0","id":1,"result":1,"error":null})).not_nil!
    ex.calls[0].label.should be_nil
    ex.calls[0].error.should be_false # `"error": null` is no error
    ex.calls[0].reply.should eq("1")
  end
end
