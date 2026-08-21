require "../spec_helper"

# `Store#drain_fts!` is the answer to "can a `body:` query see every stored flow yet", for the
# one-shot surfaces that must not answer off a partial index (`gori run history`/`sitemap`,
# MCP `list_history`, `Probe::Scan`, `Authorize::Plan`).
#
# It exists because `index_pending!` cannot answer it. A batch that loses SQLite's single writer
# slot to a capturing peer is reported as "0 indexed" and the drain takes its `break if n == 0`
# there — deliberate, so a contended write can never hang capture, and it means the call returns
# NORMALLY with rows still dirty.
#
# The part measured rather than guessed: that contention is over almost immediately. Against a
# live capture, 4 of 40 one-shot `body:` queries were refused for a backlog that had not drained,
# and all 4 succeeded on an immediate re-run — so the first cut of this guard was handing the
# operator a refusal for something the process could have waited out inside one keystroke. Hence
# the retry, and hence these examples: the shape under test is a peer that holds the writer
# BRIEFLY, which is the common case and the one a single attempt gets wrong.
private def contended_drain_store(&)
  path = File.tempname("gori-fts-drain", ".db")
  url = "sqlite3:#{path}?journal_mode=wal&busy_timeout=1"
  db = DB.open(url)
  Gori::Store::Schema.migrate!(db)
  store = Gori::Store.new(db, nil)
  # The idle indexer would drain the backlog within one FAST tick (5 ms), before the peer lock
  # could be taken, so the order these examples need is unreachable with it running. Pausing it
  # is a real product state (a view-only Session does it, #752) and leaves `drain_fts!` — an op
  # on the write channel — running.
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
    when timeout(20.seconds)
      # leaked on purpose: a wedged writer must fail the example, never hang the run
    end
    peer.close rescue nil
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# A completed flow whose RESPONSE body carries `needle`, left DIRTY: nothing here flushes and
# the idle indexer is paused.
private def seed_dirty_flow(store, needle : String) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: "/a", http_version: "HTTP/1.1",
    head: "GET /a HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200,
    head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n".to_slice,
    body: "<html><body>#{needle} lives here</body></html>".to_slice,
    reason: "OK", content_type: "text/html", duration_us: 1_i64))
  id
end

describe "Gori::Store#drain_fts!" do
  it "waits out a peer that holds the writer briefly, instead of reporting a backlog" do
    contended_drain_store do |store, peer|
      seed_dirty_flow(store, "needleone")
      store.fts_backlog.should be > 0

      lock = peer.checkout
      lock.exec("BEGIN IMMEDIATE")
      released = false
      # The peer lets go while the drain is still inside its budget — a capturing gori
      # committing one flow, which is the whole population of this failure.
      spawn do
        sleep 60.milliseconds
        lock.exec("ROLLBACK") rescue nil
        lock.release rescue nil
        released = true
      end

      store.drain_fts!.should eq(0)
      released.should be_true # it really did have to wait, rather than winning the first try
      store.fts_backlog.should eq(0)
    end
  end

  it "still reports what is left when the writer never comes back" do
    # Bounded, not blocking: a peer that holds the writer for longer than the budget ends in a
    # number the caller turns into a sentence, never a hang. A SHORT budget here — the point is
    # the shape of the answer, and the shipped budget is exercised by the surfaces' own specs.
    contended_drain_store do |store, peer|
      seed_dirty_flow(store, "needletwo")
      lock = peer.checkout
      lock.exec("BEGIN IMMEDIATE")
      begin
        store.drain_fts!(30.milliseconds).should be > 0
        store.fts_backlog.should be > 0 # refused, and lost nothing doing it
      ensure
        lock.exec("ROLLBACK") rescue nil
        lock.release rescue nil
      end
    end
  end

  it "answers 0 with no waiting at all when there was never a backlog" do
    contended_drain_store do |store, _peer|
      seed_dirty_flow(store, "needlethree")
      store.index_pending!
      store.fts_backlog.should eq(0)
      t0 = Time.instant
      store.drain_fts!.should eq(0)
      (Time.instant - t0).should be < 200.milliseconds
    end
  end
end

describe "Gori::Store#drain_fts! on a READ-ONLY store" do
  it "answers the permanent backlog immediately rather than spending the budget on it" do
    # A read-only store has no writer fiber to drain with, so its backlog cannot move for as
    # long as this process lives (see `Store#read_only?`). Retrying would be a second of
    # latency in front of an answer that was already known — and this is the `gori mcp
    # --read-only` path, where an agent is waiting on it.
    path = File.tempname("gori-fts-drain-ro", ".db")
    begin
      writable = Gori::Store.open(path)
      begin
        writable.pause_background_index
        seed_dirty_flow(writable, "needlefour")
        writable.fts_backlog.should be > 0
      ensure
        writable.close
      end
      ro = Gori::Store.open(path, read_only: true)
      begin
        ro.read_only?.should be_true
        t0 = Time.instant
        ro.drain_fts!.should be > 0
        (Time.instant - t0).should be < 200.milliseconds
      ensure
        ro.close
      end
    ensure
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
      File.delete?("#{path}.open.lock")
    end
  end
end
