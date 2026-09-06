require "./spec_helper"

private def capture(store : Gori::Store, method : String, target : String, status : Int32) : Nil
  head = "#{method} #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n"
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
    method: method, target: target, http_version: "HTTP/1.1", head: head.to_slice, source: Gori::FlowSource::Kind::Proxy))
  resp_head = "HTTP/1.1 #{status} X\r\nContent-Length: 0\r\n\r\n"
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: resp_head.to_slice, duration_us: 1_i64))
end

describe "sitemap summary" do
  # Six columns key a group and only two ordered it, so `GET /x` and `POST /x` tied
  # completely and which one survived a LIMIT cut was unspecified by SQL. There is no cursor
  # on this read, so the loser of an arbitrary tiebreak is not on a later page — it is
  # unreachable, and the operator concludes the endpoint was never observed.
  #
  # HONEST NOTE ON WHAT THIS PINS: this example also PASSES against the old partial
  # `ORDER BY host, target`, because SQLite's GROUP BY happens to sort by the grouping
  # columns internally and that order agrees with the requested one here. The total ORDER BY
  # is a GUARANTEE, not an observable change on this data — SQLite is free to change that
  # internal order (a different query plan, an index, a version bump) and the old clause
  # gave it permission to. So treat this as a regression guard on the stated order, not as
  # proof the bug reproduced.
  it "orders totally so a LIMIT cut is deterministic" do
    with_store do |store|
      capture(store, "GET", "/admin", 200)
      capture(store, "POST", "/admin", 200)
      capture(store, "DELETE", "/admin", 200)

      first = store.sitemap_entries_detailed(Gori::QL::EMPTY, 2).map { |e| {e.method, e.target} }
      3.times do
        store.sitemap_entries_detailed(Gori::QL::EMPTY, 2)
          .map { |e| {e.method, e.target} }.should eq(first)
      end
      # And the cut is by a stated order, not by luck: methods sort ascending.
      first.map(&.[0]).should eq(["DELETE", "GET"])
    end
  end

  # Status 101 is exactly what `proto:ws` means, so every WebSocket endpoint used to report
  # "N attempts, 0 successes, 0 errors" — an agent reads that as N failed attempts.
  it "counts a 101 upgrade as a success, not as neither" do
    with_store do |store|
      capture(store, "GET", "/ws", 101)
      capture(store, "GET", "/ws", 101)

      entry = store.sitemap_entries_detailed.find { |e| e.target == "/ws" }.not_nil!
      entry.count.should eq(2)
      entry.ok.should eq(2)
      entry.errors.should eq(0)
    end
  end

  it "still buckets ordinary successes and errors as before" do
    with_store do |store|
      capture(store, "GET", "/ok", 200)
      capture(store, "GET", "/ok", 301)
      capture(store, "GET", "/bad", 404)
      capture(store, "GET", "/bad", 500)

      ok = store.sitemap_entries_detailed.find { |e| e.target == "/ok" }.not_nil!
      ok.ok.should eq(2)
      ok.errors.should eq(0)

      bad = store.sitemap_entries_detailed.find { |e| e.target == "/bad" }.not_nil!
      bad.ok.should eq(0)
      bad.errors.should eq(2)
    end
  end
end
