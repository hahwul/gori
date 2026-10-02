require "../spec_helper"

private def seed_sitemap_flow(store : Gori::Store, host : String, target : String) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: host, port: 80,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
  id
end

# The check `gori run sitemap tag` and MCP `set_sitemap_tag` make before reporting whether a
# tag will show on a node (#1463 moved it here from the two surfaces).
describe "Gori::Store#sitemap_node_exists?" do
  it "matches a captured endpoint through the tree's own node path" do
    with_store do |store|
      seed_sitemap_flow(store, "acme.test", "/api/users/")
      seed_sitemap_flow(store, "acme.test", "/login?a=1")
      # A trailing slash is dropped exactly as the tree drops it.
      store.sitemap_node_exists?("acme.test", "/api/users").should be_true
      # The query string is part of the key.
      store.sitemap_node_exists?("acme.test", "/login?a=1").should be_true
      store.sitemap_node_exists?("acme.test", "/login").should be_false
    end
  end

  it "answers false for another host or a path nothing captured" do
    with_store do |store|
      seed_sitemap_flow(store, "acme.test", "/api/users")
      store.sitemap_node_exists?("other.test", "/api/users").should be_false
      store.sitemap_node_exists?("acme.test", "/api/user").should be_false
    end
  end
end
