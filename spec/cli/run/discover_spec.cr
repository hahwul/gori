require "../../spec_helper"

# `gori run discover` — what happens to a crawled exchange when its batch cannot be written.
#
# `flush_discover` handed `Store#insert_import_batch` its buffer and cleared it without reading
# the answer. That answer is the COMMITTED count, and it is 0 for a batch the writer rolled back
# — a peer holding SQLite's writer slot past the busy budget — so up to 200 crawled exchanges
# vanished per collision: printed as findings, absent from History and the Sitemap, no STDERR
# line, exit 0. The TUI twin reports the same loss on its toast and in the notification centre;
# a script gets a count on STDERR and a non-zero exit.
module Gori::CLI::Run
  def self.flush_discover_for_spec(store : Gori::Store,
                                   pending : Array({Gori::Store::CapturedRequest, Gori::Store::CapturedResponse?})) : Int32
    flush_discover(store, pending)
  end
end

private def crawled_pairs(n : Int32) : Array({Gori::Store::CapturedRequest, Gori::Store::CapturedResponse?})
  (1..n).map do |i|
    f = Gori::Discover::Finding.new("http://t/#{i}", "GET", 200, 2_i64, "text/plain",
      Gori::Discover::Source::Bruteforced, 1, 0.9, nil)
    p = Gori::Discover::Persist.flow_pair(f, i.to_i64, surface: Gori::FlowSource::Surface::Cli)
    {p.request, p.response}
  end
end

# A store whose busy budget is one millisecond, and a second connection that can take the
# writer slot out from under it — the model `spec/store/repeaters_spec.cr` uses for the same
# condition. Yields the store and a proc that runs its block under a peer's `BEGIN IMMEDIATE`.
private def with_contended_store(&)
  path = File.tempname("gori-discover-contended", ".db")
  store = Gori::Store.open(path, busy_timeout_ms: 1)
  peer = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=1")
  begin
    hold = ->(blk : ->) do
      lock = peer.checkout
      begin
        lock.exec("BEGIN IMMEDIATE")
        blk.call
      ensure
        lock.exec("ROLLBACK") rescue nil
        lock.release rescue nil
      end
    end
    yield store, hold
  ensure
    peer.close rescue nil
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
    File.delete?("#{path}.open.lock")
  end
end

describe "gori run discover — a flush the writer rolled back" do
  it "answers how many exchanges did NOT land, and still clears the buffer" do
    with_contended_store do |store, hold|
      pending = crawled_pairs(3)
      lost = 0
      hold.call(-> { lost = Gori::CLI::Run.flush_discover_for_spec(store, pending) })
      lost.should eq(3)
      pending.should be_empty # never retried: keeping a refused batch is the unbounded growth the cap prevents
      store.count.should eq(0_i64)
    end
  end

  it "answers 0 when the batch committed" do
    with_contended_store do |store, _hold|
      pending = crawled_pairs(2)
      Gori::CLI::Run.flush_discover_for_spec(store, pending).should eq(0)
      pending.should be_empty
      store.count.should eq(2_i64)
    end
  end

  it "answers 0 for an empty buffer without touching the store" do
    with_contended_store do |store, hold|
      empty = [] of {Gori::Store::CapturedRequest, Gori::Store::CapturedResponse?}
      hold.call(-> { Gori::CLI::Run.flush_discover_for_spec(store, empty).should eq(0) })
    end
  end

  it "says the count, the cause, and that the printed findings cannot be opened" do
    note = Gori::CLI::Run.discover_unsaved_note(200)
    note.should start_with("gori run discover: 200 captured exchanges NOT saved")
    note.should contain("project busy")
    note.should contain("cannot be opened")
    Gori::CLI::Run.discover_unsaved_note(1).should contain("1 captured exchange NOT saved")
  end
end
