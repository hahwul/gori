require "../spec_helper"

# The whole file used to go in as ONE `insert_import_batch` — one writer op and therefore one
# transaction — so a captured flow arriving mid-import waited behind the entire file. Measured
# on a 50k-entry HAR with capture writes against the same store: 598 ms of stall, against
# 22 ms once chunked. Chunking gives up whole-file atomicity, so these pin what replaced it.
private def chunk_store(&)
  path = File.tempname("gori-import-chunk", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def pair(i : Int32) : Gori::Import::Builder::FlowPair
  Gori::Import::Builder.complete_flow(
    i.to_i64, "http://h.test/p/#{i}", "GET", Gori::Import::Builder::Headers.new,
    nil, "HTTP/1.1", 200, "OK", Gori::Import::Builder::Headers.new, nil, nil, nil)
end

describe "Import.insert_all chunking" do
  it "commits every pair across chunk boundaries" do
    chunk_store do |store|
      n = Gori::Import::IMPORT_CHUNK * 2 + 7 # spans three chunks, last one partial
      committed, attempted = Gori::Import.insert_all(store, (0...n).map { |i| pair(i) })
      committed.should eq(n)
      attempted.should eq(n)
      store.count.should eq(n.to_i64)
    end
  end

  it "reports attempted alongside committed on a clean import" do
    chunk_store do |store|
      committed, attempted = Gori::Import.insert_all(store, (0...5).map { |i| pair(i) })
      committed.should eq(5)
      attempted.should eq(5)
      Gori::Import::Result.new(committed, 0, attempted).short?.should be_false
    end
  end
end

# The contract that REPLACED whole-file atomicity: a short import must be named, not printed
# as a smaller success. Every surface reads these two fields (`shortfall_note` is the one
# home for the wording; MCP emits the same facts as `attempted` + `partial`).
describe "Import::Result shortfall" do
  it "says how many did not commit, and how to retry" do
    r = Gori::Import::Result.new(count: 1200, skipped: 0, attempted: 5000)
    r.short?.should be_true
    note = r.shortfall_note.should_not be_nil
    note.should contain("3800 of 5000")
    note.should contain("re-run")
  end

  it "stays silent when everything committed" do
    Gori::Import::Result.new(count: 5000, skipped: 3, attempted: 5000).short?.should be_false
    Gori::Import::Result.new(count: 5000, skipped: 3, attempted: 5000).shortfall_note.should be_nil
  end

  it "stays silent for a Result built without an attempted count" do
    # The field defaults to 0 so older construction sites keep compiling; a zero must not be
    # read as "attempted nothing, so everything is missing".
    Gori::Import::Result.new(count: 4).short?.should be_false
  end
end
