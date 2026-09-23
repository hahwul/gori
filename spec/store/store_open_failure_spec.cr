require "../spec_helper"

# How many file descriptors this process holds. /dev/fd is present on both macOS and
# Linux and lists exactly the open descriptors, which is the only observable for "the
# database handle was never closed": nothing about the raised exception differs between
# the leaking and the non-leaking version, so an assertion on the error alone would pass
# either way.
private def open_fd_count : Int32
  Dir.children("/dev/fd").size
end

private def with_corrupt_db(&)
  dir = File.tempname("gori-open-fail")
  Dir.mkdir_p(dir)
  path = File.join(dir, "gori.db")
  # A file that is not a database at all. sqlite's open_v2 succeeds on it (the header is
  # read lazily) and the connection URL's `PRAGMA journal_mode=wal` is what fails — inside
  # the driver's constructor, which leaks the handle it had already opened.
  File.write(path, "definitely not a sqlite database\n" * 64)
  begin
    yield path
  ensure
    FileUtils.rm_rf(dir)
  end
end

# A valid, fully-migrated db stamped with a schema version this binary has never heard of
# — i.e. one written by a NEWER gori sharing the same ~/.gori.
private def with_future_version_db(&)
  dir = File.tempname("gori-future-db")
  Dir.mkdir_p(dir)
  path = File.join(dir, "gori.db")
  future = Gori::Store::Schema::VERSION + 7
  begin
    store = Gori::Store.open(path)
    store.close
    DB.open("sqlite3:#{path}") { |db| db.exec("PRAGMA user_version = #{future}") }
    yield path, future
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe "Gori::Store.open failure handling" do
  it "names a file that is not a database instead of an opaque driver refusal" do
    with_corrupt_db do |path|
      ex = expect_raises(Gori::Error) { Gori::Store.open(path) }
      ex.message.to_s.should contain("not a valid SQLite database")
      ex.message.to_s.should contain(path)
    end
  end

  it "refuses a directory in the database slot by name" do
    dir = File.tempname("gori-open-dir")
    Dir.mkdir_p(File.join(dir, "gori.db"))
    begin
      ex = expect_raises(Gori::Error) { Gori::Store.open(File.join(dir, "gori.db")) }
      ex.message.to_s.should contain("directory")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "still creates a brand-new database, and opens a zero-byte file" do
    dir = File.tempname("gori-open-fresh")
    Dir.mkdir_p(dir)
    begin
      # Missing path: the normal "new project" open.
      fresh = File.join(dir, "gori.db")
      store = Gori::Store.open(fresh)
      store.count.should eq(0)
      store.close

      # Zero-byte file: also a legitimate fresh db (sqlite initialises it in place), which
      # is what a `touch`ed path or an interrupted first open leaves behind.
      empty = File.join(dir, "empty.db")
      File.write(empty, "")
      store = Gori::Store.open(empty)
      store.count.should eq(0)
      store.close
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "does not leak a descriptor per refused non-database file" do
    with_corrupt_db do |path|
      # Warm up: the first failed open may pull in lazily-initialised state, so measure
      # the STEADY-state delta.
      begin
        Gori::Store.open(path)
      rescue
      end

      baseline = open_fd_count
      attempts = 12
      attempts.times { expect_raises(Exception) { Gori::Store.open(path) } }

      # One leaked handle per failed open would put the delta at >= attempts.
      (open_fd_count - baseline).should be < attempts
    end
  end

  it "refuses a database written by a newer gori instead of opening it blind" do
    with_future_version_db do |path, future|
      ex = expect_raises(Gori::Error) { Gori::Store.open(path) }
      ex.message.to_s.should contain("newer version of gori")
      ex.message.to_s.should contain(future.to_s)
      ex.message.to_s.should contain(Gori::Store::Schema::VERSION.to_s)
    end
  end

  it "does not leak the connection pool when the migration runner raises" do
    with_future_version_db do |path, _|
      # This one reaches DB.open and fails inside Schema.migrate!, so it exercises the
      # unwind around the pool rather than the pre-flight header check.
      begin
        Gori::Store.open(path)
      rescue
      end

      baseline = open_fd_count
      attempts = 12
      attempts.times { expect_raises(Exception) { Gori::Store.open(path) } }
      (open_fd_count - baseline).should be < attempts
    end
  end
end

# The compress path opens the same db through the same pragma-carrying URL, from a picker
# that recovers from a failed measure and lets the operator try again — so it has to refuse
# a non-database for the same two reasons Store.open does.
describe "Gori::Store compaction against a non-database" do
  it "refuses to measure one, without leaking a descriptor per attempt" do
    with_corrupt_db do |path|
      ex = expect_raises(Gori::Error) { Gori::Store.measure(path) }
      ex.message.to_s.should contain("not a valid SQLite database")

      baseline = open_fd_count
      attempts = 12
      attempts.times { expect_raises(Gori::Error) { Gori::Store.measure(path) } }
      (open_fd_count - baseline).should be < attempts
    end
  end

  it "refuses to compact one, without leaking a descriptor per attempt" do
    with_corrupt_db do |path|
      plan = Gori::Store::CompactPlan.new(response_bodies: true)
      ex = expect_raises(Gori::Error) { Gori::Store.compact(path, plan) }
      ex.message.to_s.should contain("not a valid SQLite database")

      baseline = open_fd_count
      attempts = 12
      attempts.times { expect_raises(Gori::Error) { Gori::Store.compact(path, plan) } }
      (open_fd_count - baseline).should be < attempts
    end
  end
end

describe "Gori::Store.open against a path that is not a regular file" do
  it "refuses a FIFO by name instead of blocking on its open" do
    dir = File.tempname("gori-open-fifo")
    Dir.mkdir_p(dir)
    path = File.join(dir, "gori.db")
    begin
      # A FIFO with no writer: reading its header would block forever, and the TUI has no
      # timeout to fall back on. `mkfifo` is not in the stdlib, so shell out; skip where it
      # is unavailable rather than fail for the wrong reason.
      next unless Process.run("mkfifo", [path]).success?
      File.info(path).type.pipe?.should be_true # else the example would pass for nothing
      ex = expect_raises(Gori::Error) { Gori::Store.open(path) }
      ex.message.to_s.should contain("not a regular file")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end

# #1171: `Store.open` writes before it reads — the open lock, the WAL switch, the 0600 chmod
# and the migration — so a file that is not a gori project has to be refused before any of
# it. Every example checks the file is left EXACTLY as it was, not merely that it raised.
private def with_foreign_file(&)
  dir = File.tempname("gori-foreign-db")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def file_state(path : String) : {Int64, Int16, Array(String)}
  info = File.info(path)
  {info.size, info.permissions.value, Dir.children(File.dirname(path)).sort}
end

describe "Gori::Store.open on a file that is not a gori project (#1171)" do
  it "refuses another tool's database, read-only or not, and leaves it untouched" do
    with_foreign_file do |dir|
      path = File.join(dir, "places.sqlite")
      DB.open("sqlite3:#{path}") { |db| db.exec("CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT)") }
      File.chmod(path, 0o644)
      before = file_state(path)

      [true, false].each do |read_only|
        ex = expect_raises(Gori::Error) { Gori::Store.open(path, read_only: read_only) }
        ex.message.to_s.should contain("not a gori project")
        ex.message.to_s.should contain("moz_places")
      end

      file_state(path).should eq(before) # size, mode 0644, and no -wal/-shm/.open.lock
      DB.open("sqlite3:#{path}") do |db|
        db.scalar("PRAGMA journal_mode").should eq("delete")
        db.scalar("PRAGMA user_version").as(Int64).should eq(0)
        db.query_all("SELECT name FROM sqlite_master WHERE type = 'table'", as: String).should eq(["moz_places"])
      end
    end
  end

  it "refuses a database whose user_version is another application's counter" do
    with_foreign_file do |dir|
      path = File.join(dir, "app.db")
      DB.open("sqlite3:#{path}") do |db|
        db.exec("CREATE TABLE notes (id INTEGER PRIMARY KEY)")
        db.exec("PRAGMA user_version = 3")
      end
      before = file_state(path)
      ex = expect_raises(Gori::Error) { Gori::Store.open(path) }
      ex.message.to_s.should contain("no flows table")
      file_state(path).should eq(before)
    end
  end

  it "refuses an empty file or database on a READ-ONLY open, and initialises it on a writable one" do
    with_foreign_file do |dir|
      empty = File.join(dir, "empty.db")
      File.write(empty, "")
      File.chmod(empty, 0o644)
      before = file_state(empty)
      ex = expect_raises(Gori::Error) { Gori::Store.open(empty, read_only: true) }
      ex.message.to_s.should contain("not a gori project")
      file_state(empty).should eq(before)

      bare = File.join(dir, "bare.db")
      DB.open("sqlite3:#{bare}") { |db| db.exec("PRAGMA user_version = 0; VACUUM") }
      File.size(bare).should be > 0
      expect_raises(Gori::Error, /database is empty/) { Gori::Store.open(bare, read_only: true) }

      # The writable open is how `run import --db` / `capture --db` start a project.
      store = Gori::Store.open(empty)
      store.count.should eq(0)
      store.close
      Gori::Store.open(empty, read_only: true).close # now a gori project: readable
    end
  end
end

describe "Gori::Store.open at the current schema version" do
  it "opens a db already at VERSION without raising" do
    # `current == VERSION` must migrate nothing and refuse nothing: the `>` in the runner's
    # future-version guard is load-bearing, and `MIGRATIONS[VERSION..]?` is an EMPTY SLICE,
    # not nil, so the boundary is one step away from refusing every up-to-date project.
    dir = File.tempname("gori-current-version")
    Dir.mkdir_p(dir)
    begin
      path = File.join(dir, "gori.db")
      Gori::Store.open(path).close
      DB.open("sqlite3:#{path}") do |db|
        db.scalar("PRAGMA user_version").as(Int64).to_i.should eq(Gori::Store::Schema::VERSION)
      end
      Gori::Store.open(path).close # second open: current == VERSION, nothing to do
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
