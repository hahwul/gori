require "../spec_helper"

# #752: a TUI and a `gori mcp` on one project are two SQLite writers, and a collision between
# them used to be TERMINAL rather than momentary. The losing write left its statement un-reset,
# SQLite then refused the ROLLBACK, and the writer's connection — pinned for the life of the
# store — stayed in a transaction it could never close. Every later write failed the same way,
# the open transaction kept the WAL write lock away from the peer, and the TUI went on running
# while nothing it captured was saved. Only restarting the process cleared it.
#
# These examples stand in for the peer process with a second connection to the same file: SQLite
# locks per CONNECTION, so one pool holding a write transaction is the same contention a second
# gori would produce. `busy_timeout=1` is what makes them fast — the real 5 s is exactly the wait
# these examples want to skip, not something they are testing.
private def contended_store(&)
  path = File.tempname("gori-contended", ".db")
  url = "sqlite3:#{path}?journal_mode=wal&busy_timeout=1"
  db = DB.open(url)
  Gori::Store::Schema.migrate!(db)
  store = Gori::Store.new(db, nil)
  peer = DB.open(url)
  begin
    yield store, peer
  ensure
    peer.close rescue nil
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# Close on a fiber and select against a timeout: the failure these examples guard leaves the
# writer wedged, and a spec that reproduces THAT by hanging reports nothing at all (crystal spec
# block-buffers). Same reasoning, same shape as writer_survives_constraint_spec.cr.
private def close_within(store : Gori::Store, span : Time::Span) : Bool
  done = Channel(Nil).new(1)
  spawn do
    store.close
    done.send(nil)
  end
  select
  when done.receive
    true
  when timeout(span)
    false
  end
end

private def capture(i : Int32) : Gori::Store::CapturedRequest
  Gori::Store::CapturedRequest.new(
    created_at: i.to_i64, scheme: "http", host: "a.test", port: 80, method: "GET",
    target: "/p#{i}", http_version: "HTTP/1.1",
    head: "GET /p#{i} HTTP/1.1\r\nHost: a.test\r\n\r\n".to_slice, body: nil)
end

# Takes the WAL write lock the way a peer gori's writer would, runs the block, and gives it back.
private def while_peer_writes(peer : DB::Database, &)
  lock = peer.checkout
  lock.exec("BEGIN IMMEDIATE")
  begin
    yield
  ensure
    lock.exec("ROLLBACK") rescue nil
    lock.release rescue nil
  end
end

describe "Gori::Store writer against a second writer on the same database" do
  # THE REPORTED BUG, end to end. The FTS indexer is the write an otherwise-idle gori keeps
  # making, so it is where two open gori collide first — and because capture shares the writer's
  # connection with it, an indexer that wedged that connection took capture down with it. What
  # the operator saw was a TUI still running, still proxying, and quietly saving nothing.
  it "keeps capturing after the idle indexer collided with a peer" do
    contended_store do |store, peer|
      store.insert_flow(capture(1)).should be > 0
      store.flush
      store.insert_flow(capture(2)).should be > 0 # leaves a dirty row for the indexer to find

      while_peer_writes(peer) do
        # Losing the race is expected and fine: the rows stay dirty and the drain reports 0.
        store.index_pending!.should eq(0)
      end

      # The peer is gone and this write has nothing left to contend with. HEAD: 0, and 0 for
      # every later capture too — the connection stayed in a transaction it could not roll back,
      # and only restarting the process cleared it.
      store.insert_flow(capture(3)).should be > 0
      store.flush
      store.count.should eq(3)
      close_within(store, 20.seconds).should be_true
    end
  end

  it "keeps indexing after a peer held the write lock through an FTS batch" do
    contended_store do |store, peer|
      store.insert_flow(capture(1)).should be > 0
      store.flush
      store.fts_backlog.should eq(0)

      store.insert_flow(capture(2)).should be > 0
      while_peer_writes(peer) do
        store.index_pending!.should eq(0)
      end

      # Nothing was lost — the row is still dirty — and the drain now completes. HEAD: the
      # backlog stayed dirty forever, which is the ~250 ms "FTS index batch failed" loop in
      # gori.log that the report opens with.
      store.fts_backlog.should be > 0
      store.index_pending!.should be > 0
      store.fts_backlog.should eq(0)
      close_within(store, 20.seconds).should be_true
    end
  end

  it "answers the caller a failed batch rather than blocking on it" do
    contended_store do |store, peer|
      while_peer_writes(peer) do
        # A capture batch that cannot take the write lock is refused, not hung: the proxy fiber
        # gets its 0 back and the TUI's write_failures counter is what says capture stopped.
        store.insert_flow(capture(1)).should eq(0_i64)
      end
      store.write_failures.should be > 0
      store.insert_flow(capture(2)).should be > 0
      store.flush
      store.count.should eq(1)
      close_within(store, 20.seconds).should be_true
    end
  end

  it "still lets the peer write once its own batch has failed" do
    contended_store do |store, peer|
      while_peer_writes(peer) do
        store.insert_flow(capture(1)).should eq(0_i64)
      end

      # The other half of the report: gori did not merely stop saving its own flows, it kept the
      # WAL write lock away from the process beside it. A wedged writer holds an open transaction,
      # so this BEGIN IMMEDIATE used to time out against gori itself.
      lock = peer.checkout
      begin
        lock.exec("BEGIN IMMEDIATE")
        lock.exec("ROLLBACK")
      ensure
        lock.release rescue nil
      end
      close_within(store, 20.seconds).should be_true
    end
  end
end

describe "a read-only Gori::Store" do
  it "reads normally, persists nothing, and leaves the write lock alone" do
    path = File.tempname("gori-ro", ".db")
    url = "sqlite3:#{path}?journal_mode=wal&busy_timeout=1"
    seed = DB.open(url)
    Gori::Store::Schema.migrate!(seed)
    writer = Gori::Store.new(seed, nil)
    writer.insert_flow(capture(1)).should be > 0
    writer.flush
    close_within(writer, 20.seconds).should be_true

    store = Gori::Store.new(DB.open(url), nil, read_only: true)
    begin
      store.read_only?.should be_true
      store.count.should eq(1) # reads are unaffected — that is the whole point of the mode

      # Writes take the same path a closing store gives them: answered with the caller's
      # degradation value, never persisted, and above all never parked on a reply that no
      # writer fiber exists to send.
      store.insert_flow(capture(2)).should eq(0_i64)
      store.flush # must not hang: `index_pending!` has no writer to round-trip through either
      store.count.should eq(1)

      # And the reason the mode exists (#752): this process is not holding SQLite's one writer
      # slot, so the gori actually capturing into this project can still take it.
      peer = DB.open(url)
      begin
        lock = peer.checkout
        lock.exec("BEGIN IMMEDIATE")
        lock.exec("ROLLBACK")
        lock.release
      ensure
        peer.close
      end

      close_within(store, 20.seconds).should be_true
    ensure
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end
end
