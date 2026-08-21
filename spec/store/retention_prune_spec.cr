require "../spec_helper"

# `Store#prune` used to seek its cutoff arithmetically — `MAX(id) - @retention_flows` — which is
# "the newest N flows" only on a GAP-FREE id space. `flows.id` is monotonic but not gapless:
# `delete_flow`/`delete_flows` remove arbitrary mid-history ids (the History tab's multi-select,
# MCP `delete_flow`, `gori run history delete`), so an operator who prunes by hand leaves holes.
# The sweep then destroyed flows it was explicitly asked to keep, silently and irreversibly,
# logged as an ordinary retention drop. `Store::Compact.prune_old_flows` already documented and
# fixed this exact arithmetic; these specs pin the two sweeps to one definition of "the newest N".

private def prune_store(retention, prune_interval, &)
  path = File.tempname("gori-retention-prune", ".db")
  db = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
  Gori::Store::Schema.migrate!(db)
  store = Gori::Store.new(db, nil, retention_flows: retention, prune_interval: prune_interval)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def pruned_request(target : String) : Gori::Store::CapturedRequest
  Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "http", host: "acme.test", port: 80,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy)
end

describe "Store#prune retention cutoff" do
  it "keeps every flow when the surviving row count is under the cap, despite gapped ids" do
    # 10 captures, 6 hand-deleted from the middle (survivors 1, 2, 9, 10), then 15 more captures:
    # 19 rows against a cap of 20, so the sweep must drop NOTHING. The old arithmetic computed
    # `25 - 20 = 5` and destroyed flows 1 and 2.
    prune_store(20, 2) do |store|
      ids = (1..10).map { |i| store.insert_flow(pruned_request("/#{i}")) }
      store.flush
      store.delete_flows(ids[2..7])
      store.flush
      survivors = ids.select { |id| store.flow_row(id) }
      survivors.size.should eq(4) # the hand-delete landed as intended

      (11..25).each { |i| store.insert_flow(pruned_request("/#{i}")) }
      store.flush

      ids.select { |id| store.flow_row(id) }.should eq(survivors)
    end
  end

  it "still drops the oldest flows once the cap is genuinely exceeded" do
    # The regression guard on the tightening: retention must keep sweeping. 12 captures under a
    # cap of 5 leaves exactly the newest 5.
    prune_store(5, 2) do |store|
      ids = (1..12).map { |i| store.insert_flow(pruned_request("/#{i}")) }
      store.flush
      ids.select { |id| store.flow_row(id) }.should eq(ids.last(5))
    end
  end

  it "counts surviving ROWS, not id distance, when the cap is exceeded on a gapped space" do
    # Both halves at once: gaps present AND the cap exceeded. 10 captures, ids 3..8 hand-deleted
    # (survivors 1, 2, 9, 10), then 8 more (ids 11..18) — 12 rows against a cap of 6, so exactly
    # the newest 6 by ROW ORDER survive: 13..18. The old arithmetic would have kept 13..18 too
    # only by coincidence of the numbers; what it could never do is stop at a row count.
    prune_store(6, 2) do |store|
      ids = (1..10).map { |i| store.insert_flow(pruned_request("/#{i}")) }
      store.flush
      store.delete_flows(ids[2..7])
      store.flush
      more = (11..18).map { |i| store.insert_flow(pruned_request("/#{i}")) }
      store.flush
      alive = (ids + more).select { |id| store.flow_row(id) }
      alive.size.should eq(6)
      alive.should eq(more.last(6))
    end
  end

  it "is a no-op for a store with fewer flows than the cap" do
    prune_store(100, 2) do |store|
      ids = (1..6).map { |i| store.insert_flow(pruned_request("/#{i}")) }
      store.flush
      ids.select { |id| store.flow_row(id) }.should eq(ids)
    end
  end
end
