require "../spec_helper"

# `list_sitemap` capped at `limit` and answered with a BARE ARRAY, so a full page and a
# complete surface were the same answer — and unlike `list_history` this tool has no id
# cursor an agent could probe the boundary with. `sitemap_entries_detailed`'s own comment
# already named the consequence ("with no cursor on this read, a group that loses an
# arbitrary tiebreak is not on a later page; it is unreachable"): everything past the cap
# was simply invisible, and an agent mapping an attack surface had no way to learn that the
# 200 endpoints it just enumerated stood for 4,000.
#
# The page now carries its own truth — {returned, scanned, offset, limit, has_more} — and
# `offset` walks the total ordering, so every endpoint is reachable.

private def sm_call(tools : Gori::MCP::Tools, args : String) : JSON::Any
  r = tools.call("list_sitemap", JSON.parse(args))
  fail "list_sitemap errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

private def seed_endpoint(store, target : String) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "acme.test", port: 80,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
  id
end

describe "MCP list_sitemap paging" do
  it "says has_more when the page hides endpoints, and false when it does not" do
    with_store do |store|
      5.times { |i| seed_endpoint(store, "/p#{i}") }
      tools = tools_for(store)

      page = sm_call(tools, %({"limit":2}))
      page["returned"].as_i.should eq(2)
      page["offset"].as_i.should eq(0)
      page["limit"].as_i.should eq(2)
      page["has_more"].as_bool.should be_true

      # The row fetched to DECIDE has_more is not reported as data.
      page["entries"].as_a.size.should eq(2)

      whole = sm_call(tools, "{}")
      whole["returned"].as_i.should eq(5)
      whole["has_more"].as_bool.should be_false
    end
  end

  it "walks every endpoint through offset, with no repeat and no gap" do
    with_store do |store|
      5.times { |i| seed_endpoint(store, "/p#{i}") }
      tools = tools_for(store)

      seen = [] of String
      offset = 0
      loop do
        page = sm_call(tools, %({"limit":2,"offset":#{offset}}))
        seen.concat(page["entries"].as_a.map(&.["target"].as_s))
        break unless page["has_more"].as_bool
        offset += page["limit"].as_i
      end

      seen.should eq(["/p0", "/p1", "/p2", "/p3", "/p4"])
      seen.uniq.size.should eq(seen.size)
    end
  end

  it "reports `scanned` as the PRE-FOLD row count, so a folded page still adds up" do
    with_store do |store|
      seed_endpoint(store, "/search?q=1")
      seed_endpoint(store, "/search?q=2")
      seed_endpoint(store, "/login")
      tools = tools_for(store)

      page = sm_call(tools, "{}")
      page["scanned"].as_i.should eq(3)  # three raw endpoint rows
      page["returned"].as_i.should eq(2) # /search folded, /login
      page["has_more"].as_bool.should be_false
    end
  end

  it "pages the collapse_transport view too" do
    with_store do |store|
      3.times { |i| seed_endpoint(store, "/c#{i}") }
      tools = tools_for(store)

      page = sm_call(tools, %({"limit":2,"collapse_transport":true}))
      page["entries"].as_a.size.should eq(2)
      page["has_more"].as_bool.should be_true

      rest = sm_call(tools, %({"limit":2,"offset":2,"collapse_transport":true}))
      rest["entries"].as_a.size.should eq(1)
      rest["has_more"].as_bool.should be_false
    end
  end
end
