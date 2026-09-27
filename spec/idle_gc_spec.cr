require "./spec_helper"

private MIB = 1024_u64 * 1024

# A sample with `alloc` cumulative bytes allocated and `writes` cumulative writer ops; free heap
# defaults to well above the returnable threshold.
private def sample(alloc : UInt64 = 0_u64, writes : Int64 = 0_i64,
                   free : UInt64 = 200_u64 * MIB, since_gc : UInt64 = 0_u64) : Gori::IdleGc::Sample
  Gori::IdleGc::Sample.new(alloc, free, since_gc, writes)
end

# Drive `gc` one tick per second from `t0 + from` to `t0 + to` (inclusive) with the same sample,
# returning how many of those ticks asked for a collection.
private def run_quiet(gc : Gori::IdleGc, t0 : Time::Instant, from : Int32, to : Int32,
                      s : Gori::IdleGc::Sample) : Int32
  (from..to).count { |sec| gc.tick(t0 + sec.seconds, s) }
end

describe Gori::IdleGc do
  it "waits out QUIET_FOR before the first collection" do
    t0 = Time.instant
    gc = Gori::IdleGc.new(t0, sample)
    quiet = Gori::IdleGc::QUIET_FOR.total_seconds.to_i
    run_quiet(gc, t0, 1, quiet - 1, sample).should eq(0)
    gc.tick(t0 + quiet.seconds, sample).should be_true
  end

  it "collects at most MAX_COLLECTIONS times per quiet period, then stops" do
    t0 = Time.instant
    gc = Gori::IdleGc.new(t0, sample)
    run_quiet(gc, t0, 1, 60, sample).should eq(Gori::IdleGc::MAX_COLLECTIONS)
    gc.collections.should eq(Gori::IdleGc::MAX_COLLECTIONS)
  end

  it "never collects while the store writers take ops, however long it runs" do
    t0 = Time.instant
    gc = Gori::IdleGc.new(t0, sample)
    (1..60).count { |sec| gc.tick(t0 + sec.seconds, sample(writes: sec.to_i64)) }.should eq(0)
  end

  it "never collects while a tick allocates BUSY_ALLOC_BYTES or more" do
    t0 = Time.instant
    gc = Gori::IdleGc.new(t0, sample)
    busy = Gori::IdleGc::BUSY_ALLOC_BYTES
    (1..60).count { |sec| gc.tick(t0 + sec.seconds, sample(alloc: busy * sec)) }.should eq(0)
  end

  it "treats a trickle of allocation below BUSY_ALLOC_BYTES as quiet" do
    t0 = Time.instant
    gc = Gori::IdleGc.new(t0, sample)
    small = Gori::IdleGc::BUSY_ALLOC_BYTES - 1
    (1..60).count { |sec| gc.tick(t0 + sec.seconds, sample(alloc: small * sec)) }.should eq(Gori::IdleGc::MAX_COLLECTIONS)
  end

  it "re-arms on activity: a burst mid-sequence restarts the quiet clock and the budget" do
    t0 = Time.instant
    gc = Gori::IdleGc.new(t0, sample)
    run_quiet(gc, t0, 1, 12, sample).should eq(3) # seconds 10, 11, 12
    gc.tick(t0 + 13.seconds, sample(writes: 1)).should be_false
    gc.collections.should eq(0)
    quiet = Gori::IdleGc::QUIET_FOR.total_seconds.to_i
    run_quiet(gc, t0, 14, 13 + quiet - 1, sample(writes: 1)).should eq(0)
    run_quiet(gc, t0, 13 + quiet, 200, sample(writes: 1)).should eq(Gori::IdleGc::MAX_COLLECTIONS)
  end

  it "skips a heap with nothing worth returning" do
    t0 = Time.instant
    little = sample(free: 1_u64 * MIB, since_gc: 1_u64 * MIB)
    gc = Gori::IdleGc.new(t0, little)
    run_quiet(gc, t0, 1, 60, little).should eq(0)
  end

  it "collects garbage not yet found: a small free list but a large allocation since the last GC" do
    t0 = Time.instant
    s = sample(free: 1_u64 * MIB, since_gc: 100_u64 * MIB)
    gc = Gori::IdleGc.new(t0, s)
    gc.tick(t0 + Gori::IdleGc::QUIET_FOR, s).should be_true
  end

  it "stops early once the free heap has been returned" do
    t0 = Time.instant
    gc = Gori::IdleGc.new(t0, sample)
    quiet = Gori::IdleGc::QUIET_FOR.total_seconds.to_i
    gc.tick(t0 + quiet.seconds, sample).should be_true
    gc.tick(t0 + (quiet + 1).seconds, sample(free: 0_u64)).should be_false
  end
end

describe "Gori::Store.write_ops" do
  it "advances when a store's writer takes an op" do
    with_store do |store|
      before = Gori::Store.write_ops
      store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "a.test", port: 80, method: "GET",
        target: "/", http_version: "HTTP/1.1",
        head: "GET / HTTP/1.1\r\nHost: a.test\r\n\r\n".to_slice, body: nil,
        source: Gori::FlowSource::Kind::Proxy)).should be > 0
      Gori::Store.write_ops.should be > before
    end
  end

  # A blind CONNECT tunnel and a body streaming past the capture limit write nothing to the Store
  # and allocate nothing per chunk; a collection there would pause live traffic.
  it "counts tunnel bytes and a lent copy buffer as traffic" do
    t0 = Time.instant
    quiet = Gori::IdleGc::QUIET_FOR.total_seconds.to_i
    tunnel = Gori::IdleGc.new(t0, sample)
    moving = (1..quiet + 5).count do |sec|
      tunnel.tick(t0 + sec.seconds, Gori::IdleGc::Sample.new(0_u64, 200_u64 * MIB, 0_u64, 0_i64, sec.to_i64, 0))
    end
    moving.should eq(0)
    streaming = Gori::IdleGc.new(t0, sample)
    busy = Gori::IdleGc::Sample.new(0_u64, 200_u64 * MIB, 0_u64, 0_i64, 0_i64, 1)
    run_quiet(streaming, t0, 1, quiet + 5, busy).should eq(0)
  end

  it "sees the proxy counters move" do
    before = Gori::Proxy::Pump.forwarded
    r, w = IO.pipe
    w.write("abc".to_slice)
    w.close
    Gori::Proxy::Pump.copy(r, IO::Memory.new)
    (Gori::Proxy::Pump.forwarded - before).should eq(3)
    Gori::Proxy::CopyBufPool.lent.should eq(0)
    Gori::Proxy::CopyBufPool.lend { Gori::Proxy::CopyBufPool.lent.should eq(1) }
    Gori::Proxy::CopyBufPool.lent.should eq(0)
  end
end
