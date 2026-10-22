require "../spec_helper"
require "../support/mcp_harness"

private SCHEMA_RESULT = %({"data":{"__schema":{"queryType":{"name":"Query"},"mutationType":null,) +
                        %("subscriptionType":null,"types":[{"kind":"OBJECT","name":"Query","fields":) +
                        %([{"name":"me","args":[],"type":{"kind":"SCALAR","name":"String","ofType":null}}]}]}}})

# A GraphQL flow on 127.0.0.1:`port` whose response is `resp_body`.
private def graphql_flow(store, port : Int32, resp_body : String) : Int64
  head = "POST /graphql HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nAuthorization: Bearer t\r\n" \
         "Content-Type: application/json\r\nContent-Length: 15\r\n\r\n"
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "127.0.0.1", port: port,
    method: "POST", target: "/graphql", http_version: "HTTP/1.1",
    head: head.to_slice, body: %({"query":"{a}"}).to_slice, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(flow_id: id, status: 200,
    head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n".to_slice,
    body: resp_body.to_slice, content_type: "application/json"))
  id
end

# A one-shot origin that answers the introspection result and hands back the request it read.
# `declared` overstates Content-Length so the origin closes before the body is whole.
private def start_graphql_origin(sink : Channel(String), declared : Int32 = SCHEMA_RESULT.bytesize) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    head = Gori::Proxy::Codec::Http1.read_head(conn)
    text = String.new(head.as(Bytes))
    len = text[/content-length:\s*(\d+)/i, 1].to_i
    body = Bytes.new(len)
    conn.read_fully(body)
    sink.send(text + String.new(body))
    conn << "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{declared}\r\n\r\n#{SCHEMA_RESULT}"
    conn.flush
    conn.close
    origin.close
  rescue
    origin.close rescue nil
  end
  port
end

private def call_tool(tools, args : String)
  tools.call("graphql_schema", JSON.parse(args))
end

describe "MCP graphql_schema" do
  it "summarizes a captured introspection result without sending" do
    with_store do |store|
      id = graphql_flow(store, 1, SCHEMA_RESULT)
      r = call_tool(tools_for(store), %({"flow_id":#{id}}))
      r.is_error.should be_false
      out = JSON.parse(r.text)
      out["source"].as_s.should eq("captured")
      out["query_type"].as_s.should eq("Query")
      out["sdl"].as_s.should eq("type Query {\n  me: String\n}")
      out["status"]?.should be_nil
      out["scope_decision"]?.should be_nil
    end
  end

  it "names send:true when the captured response is not a schema" do
    with_store do |store|
      id = graphql_flow(store, 1, %({"data":{"a":1}}))
      r = call_tool(tools_for(store), %({"flow_id":#{id}}))
      r.error_code.should eq("INVALID_ARGUMENT")
      r.text.should contain("send:true")
    end
  end

  it "re-sends the flow's request as the introspection query with its headers" do
    with_store do |store|
      sink = Channel(String).new(1)
      port = start_graphql_origin(sink)
      id = graphql_flow(store, port, %({"data":{"a":1}}))
      r = call_tool(tools_for(store), %({"flow_id":#{id},"send":true,"allow_unscoped":true}))
      r.is_error.should be_false
      sent = sink.receive
      sent.should start_with("POST /graphql HTTP/1.1\r\n")
      sent.should contain("Authorization: Bearer t\r\n")
      sent.should contain(%("operationName":"IntrospectionQuery"))
      out = JSON.parse(r.text)
      out["source"].as_s.should eq("sent")
      out["status"].as_i.should eq(200)
      out["sdl"].as_s.should contain("me: String")
      out["scope_decision"].as_s.should_not be_empty
    end
  end

  it "says a response cut short is incomplete rather than not JSON" do
    with_store do |store|
      sink = Channel(String).new(1)
      port = start_graphql_origin(sink, SCHEMA_RESULT.bytesize + 1000)
      id = graphql_flow(store, port, %({"data":{"a":1}}))
      r = call_tool(tools_for(store), %({"flow_id":#{id},"send":true,"allow_unscoped":true,"timeout_ms":3000}))
      sink.receive
      r.error_code.should eq("INTROSPECTION_FAILED")
      r.text.should contain("cut short")
      r.text.should_not contain("legacy")
    end
  end

  it "refuses send:true without a scope, before dialling" do
    with_store do |store|
      id = graphql_flow(store, 1, %({"data":{"a":1}}))
      call_tool(tools_for(store), %({"flow_id":#{id},"send":true})).error_code.should eq("SCOPE_BLOCKED")
    end
  end

  it "refuses send:true on a read-only server and still reads" do
    with_store do |store|
      id = graphql_flow(store, 1, SCHEMA_RESULT)
      tools = tools_for(store, allow_actions: false)
      call_tool(tools, %({"flow_id":#{id},"send":true})).error_code.should eq("TOOL_DISABLED")
      call_tool(tools, %({"flow_id":#{id}})).is_error.should be_false
    end
  end
end
