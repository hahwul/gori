require "../spec_helper"

# #2022: a sitemap row is an aggregate and carried no flow id, so following one up meant a
# second query by host and path, which can land on another variant and retypes a host whose
# bytes may not be what they look like.

private def seed(store, host : String, target : String, status : Int32?) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: host, port: 443,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  if status
    store.update_response(Gori::Store::CapturedResponse.new(
      flow_id: id, status: status, head: "HTTP/1.1 #{status} X\r\n\r\n".to_slice))
  end
  id
end

private def sitemap(tools, args = "{}") : Array(JSON::Any)
  r = tools.call("list_sitemap", JSON.parse(args))
  fail r.text if r.is_error
  JSON.parse(r.text)["entries"].as_a
end

describe "MCP list_sitemap sample flow ids" do
  it "gives an unfolded row the newest answered flow of its exact key, opened by get_flow" do
    with_store do |store|
      # U+0455, not Latin s: the bytes travel by id, not by retyping the host.
      host = "ѕhop.test"
      answered = seed(store, host, "/login", 200)
      seed(store, host, "/login", nil) # newer, still pending
      seed(store, "other.test", "/login", 200)
      store.flush
      tools = tools_for(store)
      row = sitemap(tools).find! { |e| e["host"].as_s == host }
      row["sample_flow_id"].as_i64.should eq(answered)
      row["count"].as_i.should eq(2)
      flow = JSON.parse(tools.call("get_flow", JSON.parse(%({"id":#{answered}}))).text)
      flow["host"].as_s.should eq(host)
    end
  end

  it "puts no single id on a folded row, and one per query target instead" do
    with_store do |store|
      a = seed(store, "a.test", "/search?q=1", 200)
      b = seed(store, "a.test", "/search?q=2", 500)
      store.flush
      tools = tools_for(store)
      folded = sitemap(tools).find! { |e| e["target"].as_s == "/search" }
      folded.as_h.has_key?("sample_flow_id").should be_false
      targets = folded["query_targets"].as_a.map(&.as_s)
      ids = folded["query_target_flow_ids"].as_a.map(&.as_i64)
      targets.zip(ids).to_h.should eq({"/search?q=1" => a, "/search?q=2" => b})
      folded.as_h.has_key?("bare_target_flow_id").should be_false

      unfolded = sitemap(tools, %({"fold_query":false}))
      unfolded.to_h { |e| {e["target"].as_s, e["sample_flow_id"].as_i64} }
        .should eq({"/search?q=1" => a, "/search?q=2" => b})
    end
  end

  it "keeps an id for the path itself when its query variants fold onto it" do
    with_store do |store|
      bare = seed(store, "a.test", "/search", 200)
      q = seed(store, "a.test", "/search?q=1", 200)
      store.flush
      folded = sitemap(tools_for(store)).find! { |e| e["target"].as_s == "/search" }
      folded["count"].as_i.should eq(2)
      folded["query_target_flow_ids"].as_a.map(&.as_i64).should eq([q])
      folded["bare_target_flow_id"].as_i64.should eq(bare)
      folded.as_h.has_key?("sample_flow_id").should be_false
    end
  end

  it "samples a flow the query matched" do
    with_store do |store|
      seed(store, "a.test", "/x", 200)
      bad = seed(store, "a.test", "/x", 500)
      store.flush
      sitemap(tools_for(store), %({"query":"status:500"})).first["sample_flow_id"].as_i64.should eq(bad)
    end
  end
end
