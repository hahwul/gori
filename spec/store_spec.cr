require "./spec_helper"

describe Gori::Store do
  # crystal-db's `Pool#close` only empties the pool, so a read that outlived its project built
  # a fresh connection: the file reopened outside the open lock and its WAL stayed pinned.
  it "refuses a read after close instead of reopening the database" do
    dir = File.tempname("gori-store-close")
    Dir.mkdir_p(dir)
    begin
      store = Gori::Store.open(File.join(dir, "gori.db"))
      store.close
      expect_raises(DB::Error, "store is closed") { store.@db.scalar("SELECT 1") }
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
