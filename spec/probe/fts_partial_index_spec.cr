require "../spec_helper"

# `Probe::Scan.flow_ids` drains the off-commit trigram index (Store V4) before selecting the set
# to scan, because a scan that silently skipped flows would UNDER-REPORT findings — and a report
# with fewer findings in it is indistinguishable from a clean one.
#
# The drain's RETURN never said whether it worked. `index_pending!` reports a batch that lost
# SQLite's single writer slot to a capturing peer as "0 indexed" and takes its `break if n == 0`
# there (Store#index_pending!) — deliberate, so a contended write can never hang capture, and it
# means the drain returns normally with rows still dirty. Both surfaces then scanned the short
# set: `gori run probe` printed its usual summary, and MCP `probe_scan` answered `issues: []`.
#
# The peer connection stands in for the second gori that makes this reachable (a TUI capturing
# beside an agent's `gori mcp`); SQLite locks per CONNECTION, so one pool holding BEGIN IMMEDIATE
# is the same contention a second process produces. `busy_timeout=1` skips the real 5 s wait.
private def contended_probe_store(&)
  path = File.tempname("gori-probe-fts", ".db")
  url = "sqlite3:#{path}?journal_mode=wal&busy_timeout=1"
  db = DB.open(url)
  Gori::Store::Schema.migrate!(db)
  store = Gori::Store.new(db, nil)
  # The idle indexer would drain the backlog within one FAST tick (5 ms), before the peer lock
  # could be taken — the order these examples need is unreachable with it running. Pausing it is
  # a real product state (#752); explicit `index_pending!`, the call under test, still runs.
  store.pause_background_index
  peer = DB.open(url)
  begin
    yield store, peer
  ensure
    done = Channel(Nil).new(1)
    spawn do
      store.close
      done.send(nil)
    end
    select
    when done.receive
      # closed cleanly
    when timeout(20.seconds)
      # a wedged writer must fail the example, never hang the run
    end
    peer.close rescue nil
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def while_probe_peer_writes(peer : DB::Database, &)
  lock = peer.checkout
  lock.exec("BEGIN IMMEDIATE")
  begin
    yield
  ensure
    lock.exec("ROLLBACK") rescue nil
    lock.release rescue nil
  end
end

# A flow whose RESPONSE body carries `needle` (≥3 chars → QL's trigram path, not the `instr`
# fallback), left DIRTY: nothing flushes and the idle indexer is paused.
private def seed_dirty_probe_flow(store, needle : String) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: "/admin", http_version: "HTTP/1.1",
    head: "GET /admin HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200,
    head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n".to_slice,
    body: "<p>#{needle}</p>".to_slice, reason: "OK", content_type: "text/html", duration_us: 1_i64))
  id
end

describe "Gori::Probe::Scan.flow_ids when the FTS drain lost the writer slot" do
  it "refuses instead of returning a short set to scan" do
    contended_probe_store do |store, peer|
      seed_dirty_probe_flow(store, "needleone")
      store.fts_backlog.should be > 0 # the drain has real work to fail at

      filter = Gori::QL.parse("body:needleone")
      ex = nil.as(Exception?)
      while_probe_peer_writes(peer) do
        ex = expect_raises(Gori::Error) { Gori::Probe::Scan.flow_ids(store, filter) }
      end
      msg = ex.not_nil!.message.not_nil!
      msg.should contain("1 flow could not be indexed")
      msg.should contain("under-report findings")
      msg.should contain("Nothing was scanned")
      # HEAD returned `[] of Int64` here — a scan over nothing, reported like a clean one.
    end
  end

  # The complement, and what stops the guard from being unconditional: with the writer free the
  # drain finishes and the same filter selects the flow.
  it "selects the flow once the drain actually completes" do
    contended_probe_store do |store, _peer|
      id = seed_dirty_probe_flow(store, "needletwo")
      Gori::Probe::Scan.flow_ids(store, Gori::QL.parse("body:needletwo")).should eq([id])
      store.fts_backlog.should eq(0) # it drained here — not a pre-indexed pass
    end
  end

  # A nil filter (the whole history — `gori run probe` with no query) and a non-FTS filter both
  # read no trigram index at all, so neither may be refused by a backlog they don't depend on.
  it "leaves a nil filter and a non-FTS filter alone while the backlog is stuck" do
    contended_probe_store do |store, peer|
      id = seed_dirty_probe_flow(store, "needlethree")
      while_probe_peer_writes(peer) do
        Gori::Probe::Scan.flow_ids(store, nil).should eq([id])
        Gori::Probe::Scan.flow_ids(store, Gori::QL.parse("host:acme.test")).should eq([id])
      end
    end
  end
end
