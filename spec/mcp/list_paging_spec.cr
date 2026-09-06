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

# `list_history` had the same shape of problem with a different consequence. Its cursor
# WORKS and the contract was documented ("a page shorter than `limit` means no older rows"),
# but it was an inference the caller had to make and then spend a second call on: a query
# matching 51 flows and one matching exactly 50 returned byte-identical answers. And `since`
# silently flipped the row order, which the schema said and the payload did not.

private def hist(tools : Gori::MCP::Tools, args : String) : JSON::Any
  r = tools.call("list_history", JSON.parse(args))
  fail "list_history errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

private def seed_hist(store, target : String) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "acme.test", port: 80,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
  id
end

describe "MCP list_history paging" do
  it "separates a full page from a set that exactly fills it" do
    with_store do |store|
      ids = (0...4).map { |i| seed_hist(store, "/h#{i}") }

      exact = hist(tools_for(store), %({"limit":4}))
      exact["returned"].as_i.should eq(4)
      exact["has_more"].as_bool.should be_false # 4 of 4 — used to be indistinguishable
      exact["flows"].as_a.size.should eq(4)

      short = hist(tools_for(store), %({"limit":3}))
      short["has_more"].as_bool.should be_true
      short["next_before_id"].as_i64.should eq(ids[1]) # oldest on this page
    end
  end

  it "hands back the cursor spelled as the argument it goes in, and walks the whole set" do
    with_store do |store|
      4.times { |i| seed_hist(store, "/h#{i}") }
      tools = tools_for(store)

      seen = [] of Int64
      args = %({"limit":2})
      loop do
        page = hist(tools, args)
        page["order"].as_s.should eq("newest_first")
        seen.concat(page["flows"].as_a.map(&.["id"].as_i64))
        break unless page["has_more"].as_bool
        args = %({"limit":2,"before_id":#{page["next_before_id"].as_i64}})
      end
      seen.size.should eq(4)
      seen.uniq.size.should eq(4)
      seen.should eq(seen.sort.reverse!) # newest-first throughout
    end
  end

  it "says which end it is handing back when `since` flips the order" do
    with_store do |store|
      ids = (0...4).map { |i| seed_hist(store, "/h#{i}") }
      tools = tools_for(store)

      tail = hist(tools, %({"since":#{ids[0]},"limit":2}))
      tail["order"].as_s.should eq("oldest_first")
      tail["flows"].as_a.map(&.["id"].as_i64).should eq([ids[1], ids[2]])
      tail["has_more"].as_bool.should be_true
      tail["next_since"].as_i64.should eq(ids[2])
      tail.as_h.has_key?("next_before_id").should be_false

      rest = hist(tools, %({"since":#{ids[2]},"limit":2}))
      rest["flows"].as_a.map(&.["id"].as_i64).should eq([ids[3]])
      rest["has_more"].as_bool.should be_false
    end
  end

  it "reports an empty page without a cursor to follow" do
    with_store do |store|
      tools = tools_for(store)
      empty = hist(tools, "{}")
      empty["returned"].as_i.should eq(0)
      empty["has_more"].as_bool.should be_false
      empty.as_h.has_key?("next_before_id").should be_false
    end
  end
end
