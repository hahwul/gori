require "../spec_helper"

# A tag pinned on a path whose captures all carry a query string is invisible BY DESIGN:
# `Sitemap.fold_queries_node!` builds a synthetic `grouped` fold node for the path, and
# `Sitemap.stamp_tags!` refuses to stamp a tag on a grouped node "because the tag key is the
# path WITH the query". The TUI tree and `gori run sitemap` both honour that.
#
# MCP's `list_sitemap` did not: it stamped `tags[{host, path}]` onto its already-FOLDED rows,
# so `set_sitemap_tag` answered `matches_endpoint:false` with "this tag will not show in
# list_sitemap or the TUI" and then list_sitemap showed it — the two MCP tools contradicting
# each other, and `set_sitemap_tag`'s own schema ("that folded row is synthetic … it holds no
# tag of its own").

private def call_json(tools : Gori::MCP::Tools, name : String, args : String) : JSON::Any
  r = tools.call(name, JSON.parse(args))
  fail "tool #{name} errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

private def seed(store, target : String) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "acme.test", port: 80,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
  id
end

private def row_for(res : JSON::Any, target : String) : JSON::Any
  res.as_a.find { |r| r["target"].as_s == target }.not_nil!
end

describe "MCP list_sitemap tag stamping" do
  it "does not stamp a path tag on a folded row, matching the tree model" do
    with_store do |store|
      seed(store, "/search?q=1")
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      call_json(tools, "set_sitemap_tag", %({"host":"acme.test","path":"/search","tag":"look-here"}))

      row = row_for(call_json(tools, "list_sitemap", "{}"), "/search")
      row["query_variants"].as_i.should eq(1)
      row.as_h.has_key?("tag").should be_false
    end
  end

  it "keeps set_sitemap_tag's invisibility warning honest about list_sitemap" do
    with_store do |store|
      seed(store, "/search?q=1")
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)

      set = call_json(tools, "set_sitemap_tag", %({"host":"acme.test","path":"/search","tag":"look-here"}))
      set["matches_endpoint"].as_bool.should be_false
      set["warning"].as_s.should contain("will not show in list_sitemap")

      # The warning said list_sitemap will not show it. It must not.
      row_for(call_json(tools, "list_sitemap", "{}"), "/search").as_h.has_key?("tag").should be_false
    end
  end

  it "still stamps a tag on an UNFOLDED row" do
    with_store do |store|
      seed(store, "/plain")
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      call_json(tools, "set_sitemap_tag", %({"host":"acme.test","path":"/plain","tag":"plain-tag"}))

      row = row_for(call_json(tools, "list_sitemap", "{}"), "/plain")
      row["query_variants"]?.try(&.as_i).should be_nil
      row["tag"].as_s.should eq("plain-tag")
    end
  end

  it "reports a tag pinned on a variant through variant_tags, and through fold_query:false" do
    with_store do |store|
      seed(store, "/search?q=1")
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      set = call_json(tools, "set_sitemap_tag", %({"host":"acme.test","path":"/search?q=1","tag":"variant-tag"}))
      set["matches_endpoint"].as_bool.should be_true

      folded = row_for(call_json(tools, "list_sitemap", "{}"), "/search")
      folded.as_h.has_key?("tag").should be_false
      folded["variant_tags"].as_a.map { |t| {t["path"].as_s, t["tag"].as_s} }
        .should eq([{"/search?q=1", "variant-tag"}])

      row_for(call_json(tools, "list_sitemap", %({"fold_query":false})), "/search?q=1")["tag"]
        .as_s.should eq("variant-tag")
    end
  end
end
