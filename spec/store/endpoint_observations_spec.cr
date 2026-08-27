require "../spec_helper"

# `Store#endpoint_observations` — the grouped read the retest diff builds a snapshot from.
# One row per (host, method, target, status, content-type), which is what lets the diff say
# WHICH content types an endpoint answered with instead of concatenating them into a string
# a comma inside a header value would make unsplittable.

private def obs_store(&)
  path = File.tempname("gori-obs", ".db")
  store = Gori::Store.open(path, background_index: false)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def obs_flow(store : Gori::Store, target : String, *, status : Int32? = 200,
                     ctype : String? = "application/json", size : Int32 = 10,
                     at : Int64 = 5_i64) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: at, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  if st = status
    body = "x" * size
    store.update_response(Gori::Store::CapturedResponse.new(
      flow_id: id, status: st, content_type: ctype,
      head: "HTTP/1.1 #{st} OK\r\n\r\n".to_slice, body: body.to_slice,
      body_size: body.bytesize.to_i64))
  end
  id
end

describe "Store#endpoint_observations" do
  it "groups by (endpoint, status, content-type) and counts each group" do
    obs_store do |store|
      2.times { obs_flow(store, "/a") }
      obs_flow(store, "/a", status: 500)
      rows = store.endpoint_observations(raise_on_error: true)
      rows.size.should eq(2)
      ok = rows.find! { |r| r.status == 200 }
      ok.count.should eq(2)
      ok.target.should eq("/a")
      rows.find! { |r| r.status == 500 }.count.should eq(1)
    end
  end

  it "keeps a content type per row rather than concatenating a set" do
    # A `Content-Type` value may legitimately contain a comma, so a GROUP_CONCAT'd set
    # could not be split back apart — which is why the grouping is done in SQL.
    obs_store do |store|
      obs_flow(store, "/feed", ctype: "application/json")
      obs_flow(store, "/feed", ctype: "application/xml")
      types = store.endpoint_observations(raise_on_error: true).compact_map(&.content_type).sort!
      types.should eq(["application/json", "application/xml"])
    end
  end

  it "reports the newest flow of a group as its sample" do
    obs_store do |store|
      obs_flow(store, "/a")
      newest = obs_flow(store, "/a")
      store.endpoint_observations(raise_on_error: true).first.flow_id.should eq(newest)
    end
  end

  it "leaves the size NULL for a group that never got a response" do
    obs_store do |store|
      obs_flow(store, "/pending", status: nil)
      row = store.endpoint_observations(raise_on_error: true).first
      row.status.should be_nil
      row.min_size.should be_nil
    end
  end

  it "honours a QL filter" do
    obs_store do |store|
      obs_flow(store, "/keep")
      obs_flow(store, "/drop")
      filter = Gori::QL.parse("path:/keep")
      rows = store.endpoint_observations(filter, raise_on_error: true)
      rows.map(&.target).should eq(["/keep"])
    end
  end

  it "cuts at the limit deterministically, so the loser is not simply unreachable" do
    # ORDER BY names every GROUP BY column, so the same three flows always yield the same
    # two rows — a group that lost an arbitrary tiebreak would be on no later page.
    obs_store do |store|
      obs_flow(store, "/c")
      obs_flow(store, "/a")
      obs_flow(store, "/b")
      first = store.endpoint_observations(limit: 2, raise_on_error: true).map(&.target)
      first.should eq(["/a", "/b"])
      store.endpoint_observations(limit: 2, raise_on_error: true).map(&.target).should eq(first)
    end
  end

  it "degrades to no rows on a bad query for a live surface, and raises for a one-shot" do
    obs_store do |store|
      broken = Gori::QL::Filter.new("no_such_column = ?", ["x"] of DB::Any)
      store.endpoint_observations(broken).should be_empty
      expect_raises(Exception) { store.endpoint_observations(broken, raise_on_error: true) }
    end
  end
end
