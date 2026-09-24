require "./spec_helper"

# The cross-project search behind the picker's ^F (#1229). The regression it exists to avoid is
# the first example: a search over the registry must not write, migrate or lock a single one of
# the databases it reads — not a stale schema, not a live capture's WAL, not a cleanly closed
# project whose `-wal` is gone. Every shape is BUILT here rather than taken from whatever the
# platform leaves behind a close (macOS keeps an empty `-wal`, Linux deletes it), so both CI
# platforms exercise both open paths.

private alias PS = Gori::ProjectSearch

private def with_dir(&)
  dir = File.tempname("gori-psearch")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def project_in(dir : String, name : String) : Gori::Project
  Dir.mkdir_p(File.join(dir, name))
  Gori::Project.new(name, File.join(dir, name, Gori::Project::DB_FILE))
end

# A database at schema `version`, built the way that gori release built it: the first
# `version` migrations, in WAL mode, with `user_version` stamped. Returned OPEN, so a caller can
# keep writing into its WAL (autocheckpoint off, the way a crash or a live session leaves it).
private def build_db(path : String, version : Int32 = Gori::Store::Schema::VERSION) : DB::Connection
  conn = DB.connect("sqlite3:#{path}?journal_mode=wal&wal_autocheckpoint=0")
  Gori::Store::Schema::MIGRATIONS[0, {version, Gori::Store::Schema::VERSION}.min].each do |stmts|
    stmts.each { |sql| conn.exec(sql) }
  end
  conn.exec("PRAGMA user_version = #{version}")
  conn
end

private CLOCK = [1_700_000_000_000_000_i64]

# A flow in V1's columns only, so a database at any version takes it. `indexed: false` leaves
# it for the off-commit indexer (`fts_dirty = 1`, which only V4+ has).
private def add_flow(conn : DB::Connection, host : String, target : String, *,
                     req : String? = nil, resp : String? = nil, status : Int32? = 200,
                     indexed : Bool = true, resp_head : String = "HTTP/1.1 200 OK\r\n\r\n",
                     content_type : String? = nil) : Int64
  CLOCK[0] += 1000
  conn.exec("INSERT INTO flows (created_at, scheme, host, port, method, target, http_version, " \
            "request_head, request_body, response_head, response_body, status, state, content_type) " \
            "VALUES (?, 'https', ?, 443, 'GET', ?, 'HTTP/1.1', ?, ?, ?, ?, ?, 2, ?)",
    CLOCK[0], host, target, "GET #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice,
    req.try(&.to_slice), resp_head.to_slice, resp.try(&.to_slice), status, content_type)
  id = conn.scalar("SELECT last_insert_rowid()").as(Int64)
  if indexed
    conn.exec("INSERT INTO flows_fts(rowid, req, resp) VALUES (?, ?, ?)", id, req || "", resp || "")
  else
    conn.exec("UPDATE flows SET fts_dirty = 1 WHERE id = ?", id)
  end
  id
end

private def delete_sidecars(path : String) : Nil
  File.delete?("#{path}-wal")
  File.delete?("#{path}-shm")
end

# Size and mtime of the two files `Project#last_modified` reads. `-shm` is deliberately left
# out: it is SQLite's scratch index, rebuilt from the `-wal` by any reader (a READONLY connection
# creates it when a crash left a `-wal` without one), and nothing in gori reads it.
private def stamps(path : String)
  [path, "#{path}-wal"].map do |f|
    File.info?(f).try { |i| {f, i.size, i.modification_time} }
  end
end

# Backdate both files, so a write during the search cannot hide inside the same clock tick.
private def backdate(path : String) : Nil
  past = Time.utc(2020, 1, 1)
  [path, "#{path}-wal"].each { |f| File.utime(past, past, f) if File.exists?(f) }
end

private def user_version_on_disk(path : String) : Int32
  # Straight from the header (offset 60, big-endian): opening a connection to ASK would be
  # the very kind of access this file is checking the search does not make.
  bytes = Bytes.new(64)
  File.open(path, "rb", &.read_fully(bytes))
  IO::ByteFormat::BigEndian.decode(Int32, bytes[60, 4])
end

private def search_all(projects : Array(Gori::Project), needle : String,
                       cap = PS::DEFAULT_CAP) : Array(PS::Result)
  out = [] of PS::Result
  PS.run(projects, needle, cap: cap) { |r| out << r }
  out
end

private def open_fds : Int32
  Dir.children("/dev/fd").size
end

describe Gori::ProjectSearch do
  it "never writes, migrates or locks the databases it reads, in every on-disk shape" do
    with_dir do |dir|
      # A crashed session: frames in the -wal nobody checkpointed, and no connection left.
      crashed = project_in(dir, "crashed")
      src = File.join(dir, "src.db")
      w = build_db(src)
      add_flow(w, "crash.test", "/c", resp: "needle-in-wal")
      File.copy(src, crashed.db_path)
      File.copy("#{src}-wal", "#{crashed.db_path}-wal")
      w.close

      # A live capture in another process: a writer holding uncheckpointed frames right now.
      live = project_in(dir, "live")
      live_conn = build_db(live.db_path)
      add_flow(live_conn, "live.test", "/l", resp: "needle-live")

      # A cleanly closed project on Linux: no -wal, no -shm. The immutable path.
      clean = project_in(dir, "clean")
      c = build_db(clean.db_path)
      add_flow(c, "clean.test", "/k", resp: "needle-clean")
      c.close
      delete_sidecars(clean.db_path)

      # A project from an old gori (v2), which `Store.open(read_only: true)` WOULD migrate.
      stale = project_in(dir, "stale")
      s = build_db(stale.db_path, version: 2)
      add_flow(s, "stale.test", "/s", resp: "needle-stale")
      s.close
      delete_sidecars(stale.db_path)

      projects = [crashed, live, clean, stale]
      projects.each { |p| backdate(p.db_path) }
      before = projects.map { |p| stamps(p.db_path) }

      results = search_all(projects, "needle")
      results.map(&.skipped).should eq([nil, nil, nil, nil])
      results.map(&.hits.map(&.host)).should eq([["crash.test"], ["live.test"], ["clean.test"], ["stale.test"]])

      projects.map { |p| stamps(p.db_path) }.should eq(before)
      # The immutable path created nothing beside the files it read.
      File.exists?("#{clean.db_path}-wal").should be_false
      File.exists?("#{clean.db_path}-shm").should be_false
      File.exists?("#{stale.db_path}-wal").should be_false
      user_version_on_disk(stale.db_path).should eq(2)
      # And the live writer was never blocked: it can still write after the search.
      add_flow(live_conn, "live.test", "/after", resp: "x")
      live_conn.close
    end
  end

  it "searches a schema stamped by a NEWER gori instead of refusing it" do
    with_dir do |dir|
      newer = project_in(dir, "newer")
      conn = build_db(newer.db_path, version: Gori::Store::Schema::VERSION + 3)
      add_flow(conn, "api.newer.test", "/v9/users")
      conn.close
      results = search_all([newer], "api.newer")
      results.first.skipped.should be_nil
      results.first.hits.map(&.target).should eq(["/v9/users"])
      user_version_on_disk(newer.db_path).should eq(Gori::Store::Schema::VERSION + 3)
    end
  end

  it "matches the host, the path and the indexed body, newest first, and says which half matched" do
    with_dir do |dir|
      proj = project_in(dir, "p")
      conn = build_db(proj.db_path)
      body_id = add_flow(conn, "a.test", "/one", resp: %({"token":"tok_live_123"}))
      url_id = add_flow(conn, "b.test", "/tok_live_123/two")
      both_id = add_flow(conn, "tok_live_123.test", "/three", req: "tok_live_123")
      add_flow(conn, "c.test", "/unrelated", resp: "nothing to see")
      conn.close
      hits = search_all([proj], "TOK_LIVE_123").first.hits
      hits.map(&.flow_id).should eq([both_id, url_id, body_id])
      hits.map(&.match).should eq([PS::Match::Url, PS::Match::Url, PS::Match::Body])
      hits.first.status.should eq(200)
    end
  end

  it "keeps at most `cap` hits per project, and says so only when more matched" do
    with_dir do |dir|
      proj = project_in(dir, "p")
      conn = build_db(proj.db_path)
      ids = (1..5).map { |i| add_flow(conn, "cap.test", "/#{i}") }
      conn.close
      over = search_all([proj], "cap.test", cap: 2).first
      over.hits.map(&.flow_id).should eq(ids.last(2).reverse)
      over.truncated.should be_true
      # Exactly `cap` matches is all of them: nothing is hidden, so nothing may claim to be.
      exact = search_all([proj], "cap.test", cap: 5).first
      exact.hits.size.should eq(5)
      exact.truncated.should be_false
    end
  end

  it "keeps the cap and the newest-first order across indexed and not-yet-indexed hits" do
    with_dir do |dir|
      proj = project_in(dir, "p")
      conn = build_db(proj.db_path)
      a = add_flow(conn, "m.test", "/a", resp: "merge-needle")
      b = add_flow(conn, "m.test", "/b", resp: "merge-needle", indexed: false)
      c = add_flow(conn, "m.test", "/merge-needle")
      d = add_flow(conn, "m.test", "/d", resp: "merge-needle", indexed: false)
      conn.close
      result = search_all([proj], "merge-needle", cap: 3).first
      result.hits.map(&.flow_id).should eq([d, c, b])
      result.truncated.should be_true
      search_all([proj], "merge-needle").first.hits.map(&.flow_id).should eq([d, c, b, a])
    end
  end

  it "skips a not-yet-indexed body the indexer will skip too, so the answer holds once it drains" do
    with_dir do |dir|
      proj = project_in(dir, "p")
      conn = build_db(proj.db_path)
      add_flow(conn, "z.test", "/gz", resp: "…skip-needle…", indexed: false,
        resp_head: "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\n")
      add_flow(conn, "z.test", "/png", resp: "…skip-needle…", indexed: false, content_type: "image/png")
      text = add_flow(conn, "z.test", "/json", resp: "…skip-needle…", indexed: false,
        content_type: "application/json")
      conn.close
      search_all([proj], "skip-needle").first.hits.map(&.flow_id).should eq([text])
    end
  end

  it "says when a database has no body index, so a long needle's empty answer is not overread" do
    with_dir do |dir|
      proj = project_in(dir, "p")
      conn = build_db(proj.db_path)
      add_flow(conn, "n.test", "/x", resp: "no-index-needle")
      conn.exec("DROP TABLE flows_fts")
      conn.close
      result = search_all([proj], "no-index-needle").first
      result.skipped.should be_nil
      result.hits.should be_empty
      result.body_searched.should be_false
    end
  end

  it "reads an old schema that has no fts_dirty column" do
    with_dir do |dir|
      proj = project_in(dir, "v2")
      conn = build_db(proj.db_path, version: 2)
      add_flow(conn, "old.test", "/legacy", resp: "old-secret-value")
      conn.close
      result = search_all([proj], "secret-value").first
      result.skipped.should be_nil
      result.hits.map(&.match).should eq([PS::Match::Body])
      result.unindexed.should eq(0)
    end
  end

  it "scans the bodies the index has not reached yet, and counts the rest as unindexed" do
    with_dir do |dir|
      proj = project_in(dir, "dirty")
      conn = build_db(proj.db_path)
      # Oldest: a match past the scan window, so it can only be COUNTED, never found.
      add_flow(conn, "d.test", "/too-old", resp: "dirty-needle", indexed: false)
      PS::DIRTY_SCAN_MAX.times { |i| add_flow(conn, "d.test", "/filler/#{i}", resp: "filler", indexed: false) }
      fresh = add_flow(conn, "d.test", "/fresh", resp: "…the DIRTY-NEEDLE, just captured", indexed: false)
      conn.close
      result = search_all([proj], "dirty-needle").first
      result.hits.map(&.flow_id).should eq([fresh])
      result.hits.first.match.should eq(PS::Match::Body)
      # 502 dirty rows, the newest 500 scanned.
      result.unindexed.should eq(2)
    end
  end

  it "treats quotes and control characters as literal text, never as syntax or as match-all" do
    with_dir do |dir|
      proj = project_in(dir, "p")
      conn = build_db(proj.db_path)
      quoted = add_flow(conn, "q.test", "/q", resp: %(he said "open sesame" twice))
      add_flow(conn, "r.test", "/100%/under_score", resp: "plain")
      conn.close
      search_all([proj], %("open sesame")).first.hits.map(&.flow_id).should eq([quoted])
      # NUL and friends are dropped the way `body:` drops them, so the phrase still matches.
      search_all([proj], "open\u0000 ses\u0001ame").first.hits.map(&.flow_id).should eq([quoted])
      # A needle made only of control characters is no needle at all — not `%%`.
      search_all([proj], "\u0000\u0001").should be_empty
      search_all([proj], "   ").should be_empty
      # LIKE metacharacters are literal.
      search_all([proj], "%").first.hits.map(&.host).should eq(["r.test"])
      search_all([proj], "_").first.hits.map(&.host).should eq(["r.test"])
      search_all([proj], %(")).first.hits.should be_empty
    end
  end

  it "searches only host and path for a needle under the trigram floor" do
    with_dir do |dir|
      proj = project_in(dir, "p")
      conn = build_db(proj.db_path)
      add_flow(conn, "a.test", "/x", resp: "zq in the body only")
      host_hit = add_flow(conn, "zq.test", "/y")
      conn.close
      result = search_all([proj], "zq").first
      result.body_searched.should be_false
      result.hits.map(&.flow_id).should eq([host_hit])
      PS.body_searchable?("zq").should be_false
      PS.body_searchable?("zqx").should be_true
    end
  end

  it "folds a non-ASCII needle the way History does" do
    with_dir do |dir|
      proj = project_in(dir, "p")
      conn = build_db(proj.db_path)
      id = add_flow(conn, "bank.test", "/Überweisung/42")
      conn.close
      # Native LIKE folds ASCII only; `QL.contains_cond` routes this needle through
      # `gori_ci_contains`, which this handle must have registered.
      search_all([proj], "überweisung").first.hits.map(&.flow_id).should eq([id])
    end
  end

  it "lists a database it cannot search as skipped, with a reason, and still searches the rest" do
    with_dir do |dir|
      missing = project_in(dir, "missing")
      junk = project_in(dir, "junk")
      File.write(junk.db_path, "this is not a database, it is a text file with some length")
      empty = project_in(dir, "empty")
      File.write(empty.db_path, "")
      fifo = project_in(dir, "fifo")
      LibC.mkfifo(fifo.db_path, 0o600).should eq(0)
      corrupt = project_in(dir, "corrupt")
      File.write(corrupt.db_path, Gori::Store::SQLITE_MAGIC.to_a.map(&.chr).join + ("\xff" * 4000))
      foreign = project_in(dir, "foreign")
      DB.open("sqlite3:#{foreign.db_path}") { |db| db.exec("CREATE TABLE notes (body TEXT)") }
      good = project_in(dir, "good")
      conn = build_db(good.db_path)
      add_flow(conn, "found.test", "/")
      conn.close

      results = search_all([missing, junk, empty, fifo, corrupt, foreign, good], "found")
      results.map(&.project.name).should eq(%w[missing junk empty fifo corrupt foreign good])
      results[0...6].each(&.skipped.should_not(be_nil))
      results[0].skipped.should eq("no database file")
      results[1].skipped.should eq(PS::NOT_A_DATABASE)
      results[2].skipped.should eq("empty database file")
      results[3].skipped.should eq("not a regular file")
      results[5].skipped.to_s.should contain("not a gori project")
      results[6].skipped.should be_nil
      results[6].hits.map(&.host).should eq(["found.test"])
      # Nothing was created where there was nothing.
      File.exists?(missing.db_path).should be_false
    end
  end

  it "skips a database another process has locked, after a short wait rather than a hang" do
    with_dir do |dir|
      proj = project_in(dir, "locked")
      conn = build_db(proj.db_path)
      add_flow(conn, "l.test", "/")
      # EXCLUSIVE locking mode in WAL: the holder keeps the database lock and bypasses the
      # shared-memory index, so no other connection can read it until it lets go.
      conn.exec("PRAGMA locking_mode = EXCLUSIVE")
      add_flow(conn, "l.test", "/2")
      started = Time.instant
      result = search_all([proj], "l.test").first
      (Time.instant - started).should be < 2.seconds
      result.skipped.should eq("busy (another process holds a lock)")
      conn.close
    end
  end

  it "stops between projects when cancelled, and yields nothing for the ones it never reached" do
    with_dir do |dir|
      projects = (1..3).map do |i|
        proj = project_in(dir, "p#{i}")
        conn = build_db(proj.db_path)
        add_flow(conn, "stop.test", "/#{i}")
        conn.close
        proj
      end
      control = Gori::Store::QueryControl.new
      seen = [] of String
      done = PS.run(projects, "stop.test", control: control) do |r|
        seen << r.project.name
        control.cancel
      end
      done.should be_false
      seen.should eq(["p1"])
    end
  end

  it "abandons a query mid-scan when cancelled, without reporting the project as skipped" do
    with_dir do |dir|
      proj = project_in(dir, "big")
      conn = build_db(proj.db_path)
      conn.exec("BEGIN")
      # Enough rows that the scan runs well past the progress handler's step interval.
      3000.times { |i| add_flow(conn, "big.test", "/#{i}", indexed: true) }
      conn.exec("COMMIT")
      conn.close
      control = Gori::Store::QueryControl.new
      control.cancel
      PS.search(proj, "no-such-needle", control: control).should be_nil
    end
  end

  it "leaves no descriptor open behind, whatever each database turned out to be" do
    with_dir do |dir|
      good = project_in(dir, "good")
      conn = build_db(good.db_path)
      add_flow(conn, "fd.test", "/", resp: "fd body")
      conn.close
      clean = project_in(dir, "clean")
      c = build_db(clean.db_path)
      add_flow(c, "fd.test", "/")
      c.close
      delete_sidecars(clean.db_path)
      junk = project_in(dir, "junk")
      File.write(junk.db_path, "junk junk junk junk junk junk junk junk junk junk junk junk")
      missing = project_in(dir, "missing")
      projects = [good, clean, junk, missing] * 10

      baseline = open_fds
      search_all(projects, "fd.test")
      search_all(projects, "fd body")
      cancelled = Gori::Store::QueryControl.new
      cancelled.cancel
      projects.each { |p| PS.search(p, "fd.test", control: cancelled) }
      # Bounded rather than exact: `run` yields between projects, so a fiber an earlier example
      # left running may open or close a descriptor mid-measurement. A real leak is at least one
      # per searchable project per pass — 60 and more here — so the bound still catches it.
      (open_fds - baseline).should be < 10
    end
  end

  describe ".open_mode" do
    it "reads a WAL database with no -wal beside it as immutable, and anything else read-only" do
      with_dir do |dir|
        path = File.join(dir, "g.db")
        build_db(path).close
        File.exists?("#{path}-wal") ? PS.open_mode(path).should(eq(:read_only)) : nil
        delete_sidecars(path)
        PS.open_mode(path).should eq(:immutable)
        # A rollback-journal database never grows a -wal, so READONLY alone is safe.
        rollback = File.join(dir, "r.db")
        DB.open("sqlite3:#{rollback}") { |db| db.exec("CREATE TABLE flows (id INTEGER PRIMARY KEY)") }
        PS.open_mode(rollback).should eq(:read_only)
        # A live writer's -wal is there, so the reader takes the WAL-coherent path.
        live = File.join(dir, "l.db")
        w = build_db(live)
        PS.open_mode(live).should eq(:read_only)
        w.close
      end
    end
  end

  describe ".needle" do
    it "strips control characters and surrounding blanks, and answers nil for nothing left" do
      PS.needle("  tok\u0000en ").should eq("token")
      PS.needle("\u0007").should be_nil
      PS.needle("").should be_nil
    end
  end
end
