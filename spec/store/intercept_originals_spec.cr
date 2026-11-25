require "../spec_helper"

private def io_request(target : String, original : Bytes? = nil) : Gori::Store::CapturedRequest
  Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "http", host: "io.test", port: 80, method: "GET",
    target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: io.test\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy, intercept_original: original)
end

# A request edited at Intercept stores what went upstream in `flows` and what the client sent
# in `intercept_originals` (V44); the side row's existence is the "edited" flag (#1378).
describe "Store intercept originals (V44)" do
  original = "GET /?id=1 HTTP/1.1\r\nHost: io.test\r\n\r\n".to_slice

  it "keeps the pre-edit request beside an edited flow and flags every read of its row" do
    with_store do |store|
      edited = store.insert_flow(io_request("/?id=2", original))
      plain = store.insert_flow(io_request("/plain"))

      store.intercept_original(edited).should eq(original)
      store.intercept_original(plain).should be_nil

      store.flow_row(edited).not_nil!.intercept_edited?.should be_true
      store.flow_row(plain).not_nil!.intercept_edited?.should be_false
      store.get_flow(edited).not_nil!.row.intercept_edited?.should be_true
      store.get_flow(edited, body_max: 16).not_nil!.row.intercept_edited?.should be_true
      store.recent_flows(10).map { |r| {r.id, r.intercept_edited?} }.should eq([{plain, false}, {edited, true}])
      store.search(Gori::QL.parse("host:io.test"), 10).find!(&.id.==(edited)).intercept_edited?.should be_true
    end
  end

  it "goes with its flow on delete and on clear" do
    with_store do |store|
      a = store.insert_flow(io_request("/a", original))
      b = store.insert_flow(io_request("/b", original))

      store.delete_flow(a).should be_true
      store.intercept_original(a).should be_nil
      store.intercept_original(b).should eq(original)

      store.clear_flows.should be_true
      store.@db.scalar("SELECT COUNT(*) FROM intercept_originals").as(Int64).should eq(0)
    end
  end
end

private def io_response(flow_id : Int64, head : String, body : String? = nil,
                        original : Bytes? = nil, rewrite : Gori::Store::Rewrite? = nil) : Gori::Store::CapturedResponse
  resp = Gori::Store::CapturedResponse.new(flow_id: flow_id, status: head.split(' ')[1].to_i,
    head: head.to_slice, body: body.try(&.to_slice))
  resp.intercept_original = original
  resp.rewrite = rewrite
  resp
end

# A response edited at Intercept stores what the client received in `flows` and what the origin
# sent in `intercept_response_originals` (V54), the request side's twin.
describe "Store intercept response originals (V54)" do
  origin = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".to_slice

  it "keeps the origin's response beside an edited flow and flags that side on every read" do
    with_store do |store|
      edited = store.insert_flow(io_request("/r"))
      store.update_response(io_response(edited, "HTTP/1.1 403 Forbidden\r\nContent-Length: 2\r\n\r\n", "no", origin))
      plain = store.insert_flow(io_request("/plain"))
      store.update_response(io_response(plain, "HTTP/1.1 200 OK\r\n\r\n"))
      both = store.insert_flow(io_request("/both", "GET /b0 HTTP/1.1\r\n\r\n".to_slice))
      store.update_response(io_response(both, "HTTP/1.1 204 No Content\r\n\r\n", nil, origin))
      store.flush

      store.intercept_original(edited, Gori::Store::RuleTarget::Response).should eq(origin)
      store.intercept_original(edited).should be_nil # the request side was not edited
      store.intercept_original(plain, Gori::Store::RuleTarget::Response).should be_nil

      row = store.flow_row(edited).not_nil!
      row.intercept_edited?.should be_true
      row.intercept_edited_request?.should be_false
      row.intercept_edited_response?.should be_true
      store.get_flow(edited).not_nil!.row.intercept_edited?(Gori::Store::RuleTarget::Response).should be_true
      store.flow_row(plain).not_nil!.intercept_edited?.should be_false
      b = store.flow_row(both).not_nil!
      {b.intercept_edited_request?, b.intercept_edited_response?}.should eq({true, true})
      store.recent_flows(10).map { |r| {r.id, r.intercept_edited_response?} }
        .should eq([{both, true}, {plain, false}, {edited, true}])

      # The surfaces' one reader hands back the origin's head and body, split.
      d = store.get_flow(edited).not_nil!
      head, body = Gori::Interceptor.original(store, d, Gori::Store::RuleTarget::Response).not_nil!
      String.new(head).should eq("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n")
      String.new(body.not_nil!).should eq("ok")
    end
  end

  it "keeps a response rule's hits but not a second original beside an edit" do
    with_store do |store|
      id = store.insert_flow(io_request("/rule"))
      hits = [Gori::Store::RuleRef.new(Gori::Store::RuleScope::Project, 3_i64)]
      rewrite = Gori::Store::Rewrite.new(hits, "HTTP/1.1 200 OK\r\n\r\n".to_slice, "pre-rule".to_slice)
      store.update_response(io_response(id, "HTTP/1.1 500 X\r\n\r\n", "edited", origin, rewrite))
      store.flush

      store.flow_row(id).not_nil!.rewritten_by.should eq(hits)
      store.rewrite_original(id, Gori::Store::RuleTarget::Response).should be_nil
      store.rule_hit_sides(id).should eq([Gori::Store::RuleTarget::Response])
      store.intercept_original(id, Gori::Store::RuleTarget::Response).should eq(origin)
    end
  end

  it "goes with its flow on delete and on clear" do
    with_store do |store|
      a = store.insert_flow(io_request("/a"))
      store.update_response(io_response(a, "HTTP/1.1 200 OK\r\n\r\n", nil, origin))
      b = store.insert_flow(io_request("/b"))
      store.update_response(io_response(b, "HTTP/1.1 200 OK\r\n\r\n", nil, origin))
      store.flush

      store.delete_flow(a).should be_true
      store.intercept_original(a, Gori::Store::RuleTarget::Response).should be_nil
      store.intercept_original(b, Gori::Store::RuleTarget::Response).should eq(origin)

      store.clear_flows.should be_true
      store.@db.scalar("SELECT COUNT(*) FROM intercept_response_originals").as(Int64).should eq(0)
    end
  end
end
