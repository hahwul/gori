require "../spec_helper"

private def tmp_store(&)
  path = File.tempname("gori-reqct", ".db")
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

private def grpc_call(store : Gori::Store, *, ct = "application/grpc", answered = false) : Int64
  head = "POST /svc/M HTTP/1.1\r\nHost: api.test\r\nContent-Type: #{ct}\r\n\r\n"
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
    method: "POST", target: "/svc/M", http_version: "HTTP/2", head: head.to_slice, body: nil))
  if answered
    # A proxy's error page, not gRPC — the shape that made the call read as plain HTTP.
    store.update_response(Gori::Store::CapturedResponse.new(
      flow_id: id, status: 502, head: "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/html\r\n\r\n".to_slice,
      body: "<html/>".to_slice, reason: "Bad Gateway", content_type: "text/html", duration_us: 1_i64))
  end
  id
end

# `Proto` is the single source of truth the History PROTO column and the QL `proto:` field both
# defer to, so the label you see and the value you filter on can never drift. It read only the
# RESPONSE's content type, which meant a gRPC call was classified as gRPC exactly when it
# SUCCEEDED — a Pending one, an aborted one, and one answered by a proxy's `text/html` 502 all
# read as plain HTTP, and those are the calls an operator is looking through.
describe "the request Content-Type column (V14)" do
  it "records what the request declared, off the captured head" do
    tmp_store do |store|
      id = grpc_call(store, ct: "application/grpc-web+proto")
      store.get_flow(id).not_nil!.row.request_content_type.should eq("application/grpc-web+proto")
    end
  end

  it "reaches the LIST projection too, not just the detail" do
    tmp_store do |store|
      grpc_call(store)
      store.recent_flows(10).first.request_content_type.should eq("application/grpc")
    end
  end

  it "classifies a still-Pending gRPC call as gRPC" do
    tmp_store do |store|
      row = store.get_flow(grpc_call(store)).not_nil!.row
      row.status.should be_nil # nothing came back
      Gori::Proto.classify(row.status, row.content_type, row.request_content_type)
        .should eq(Gori::Proto::Kind::Grpc)
    end
  end

  it "classifies a gRPC call answered by a proxy error page as gRPC" do
    tmp_store do |store|
      row = store.get_flow(grpc_call(store, answered: true)).not_nil!.row
      row.content_type.should eq("text/html")
      Gori::Proto.classify(row.status, row.content_type, row.request_content_type)
        .should eq(Gori::Proto::Kind::Grpc)
    end
  end

  it "leaves an ordinary request alone" do
    tmp_store do |store|
      id = grpc_call(store, ct: "application/json", answered: true)
      row = store.get_flow(id).not_nil!.row
      row.request_content_type.should eq("application/json")
      Gori::Proto.classify(row.status, row.content_type, row.request_content_type)
        .should eq(Gori::Proto::Kind::Http)
    end
  end

  it "records NULL when the request declared no type" do
    tmp_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h", port: 80, method: "GET", target: "/",
        http_version: "HTTP/1.1", head: "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice, body: nil))
      store.get_flow(id).not_nil!.row.request_content_type.should be_nil
    end
  end

  # The whole point of `Proto`: the column's label and the filter's rows are one decision.
  it "finds the failed call through the QL filter that matches the column" do
    tmp_store do |store|
      pending_id = grpc_call(store)
      errored_id = grpc_call(store, answered: true)
      grpc_call(store, ct: "application/json", answered: true) # must not match

      f = Gori::QL.parse("proto:grpc")
      ids = store.search(f, 50).map(&.id)
      ids.should contain(pending_id)
      ids.should contain(errored_id)
      ids.size.should eq(2)
    end
  end
end
