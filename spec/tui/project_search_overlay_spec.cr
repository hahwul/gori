require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The picker's ^F card (#1229): a plain form object — keys in, `Outcome` out, a real search
# fiber behind it. The picker end of the mode (the chord, the routing, the hand-off to the
# session) is in project_picker_global_search_spec.cr.

private alias Key = Termisu::Input::Key
private alias Mod = Termisu::Input::Modifier

private def key(k : Key, mods : Mod = Mod::None, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, mods, char)
end

private def type(ov : ProjectSearchOverlay, text : String) : Nil
  text.each_char { |c| ov.handle_key(key(Key.from_char(c.downcase), Mod::None, c)) }
end

private def with_dir(&)
  dir = File.tempname("gori-psearch-ov")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private CLOCK = [1_700_000_000_000_000_i64]

# A current-schema project holding `flows` ({host, target, body}), each indexed for `body:`.
private def project_with(dir : String, name : String, flows : Array({String, String, String?})) : {Gori::Project, Array(Int64)}
  Dir.mkdir_p(File.join(dir, name))
  project = Gori::Project.new(name, File.join(dir, name, Gori::Project::DB_FILE))
  ids = [] of Int64
  DB.connect("sqlite3:#{project.db_path}?journal_mode=wal") do |conn|
    Gori::Store::Schema::MIGRATIONS.each { |stmts| stmts.each { |sql| conn.exec(sql) } }
    conn.exec("PRAGMA user_version = #{Gori::Store::Schema::VERSION}")
    flows.each do |(host, target, body)|
      CLOCK[0] += 1000
      conn.exec("INSERT INTO flows (created_at, scheme, host, port, method, target, http_version, " \
                "request_head, response_head, response_body, status, state) " \
                "VALUES (?, 'https', ?, 443, 'GET', ?, 'HTTP/1.1', ?, ?, ?, 200, 1)",
        CLOCK[0], host, target, "GET / HTTP/1.1\r\n\r\n".to_slice, "HTTP/1.1 200 OK\r\n\r\n".to_slice,
        body.try(&.to_slice))
      id = conn.scalar("SELECT last_insert_rowid()").as(Int64)
      conn.exec("INSERT INTO flows_fts(rowid, req, resp) VALUES (?, '', ?)", id, body || "")
      ids << id
    end
  end
  {project, ids}
end

# Past the debounce, then until the search fiber has finished. Bounded, so a regression that
# never finishes fails the example instead of hanging the suite.
private def search_now(ov : ProjectSearchOverlay) : Nil
  ov.tick(Time.instant + ProjectSearchOverlay::DEBOUNCE + 1.millisecond)
  deadline = Time.instant + 5.seconds
  while ov.running?
    raise "search did not finish" if Time.instant > deadline
    sleep 1.millisecond
  end
end

private def screen_rows(ov : ProjectSearchOverlay, w = 90, h = 24) : Array(String)
  backend = MemoryBackend.new(w, h)
  ov.render(Screen.new(backend), Rect.new(0, 0, w, h))
  (0...h).map { |y| backend.row(y) }
end

describe ProjectSearchOverlay do
  it "debounces typing, then opens the project AND the flow under the cursor" do
    with_dir do |dir|
      alpha, alpha_ids = project_with(dir, "alpha", [{"a.test", "/x", "session=tok_123"}, {"a.test", "/y", nil}])
      beta, beta_ids = project_with(dir, "beta", [{"tok_123.beta.test", "/", nil}])
      ov = ProjectSearchOverlay.new([alpha, beta])
      type(ov, "tok_123")
      ov.pending?.should be_true
      ov.tick(Time.instant) # inside the debounce: nothing starts
      ov.running?.should be_false
      search_now(ov)

      ov.selected_pick.should eq({alpha, alpha_ids[0]})
      # ↓ steps over beta's group header straight onto its hit.
      ov.handle_key(key(Key::Down))
      ov.selected_pick.should eq({beta, beta_ids[0]})
      ov.handle_key(key(Key::Down)) # the last hit: stays put
      ov.selected_pick.should eq({beta, beta_ids[0]})
      ov.handle_key(key(Key::Up))
      out = ov.handle_key(key(Key::Enter))
      out.kind.should eq(:open)
      out.project.should eq(alpha)
      out.flow_id.should eq(alpha_ids[0])
    end
  end

  it "searches on ↵ straight after typing instead of opening a hit that belongs to no needle" do
    with_dir do |dir|
      proj, _ = project_with(dir, "p", [{"now.test", "/", nil}])
      ov = ProjectSearchOverlay.new([proj])
      type(ov, "now.test")
      ov.handle_key(key(Key::Enter)).kind.should eq(:stay)
      ov.pending?.should be_false
      ov.running?.should be_true
      search_now(ov)
      ov.handle_key(key(Key::Enter)).kind.should eq(:open)
    end
  end

  it "stops a running search on esc, and closes on the next one" do
    with_dir do |dir|
      proj, _ = project_with(dir, "p", [{"esc.test", "/", nil}])
      ov = ProjectSearchOverlay.new([proj])
      type(ov, "esc.test")
      ov.start
      # The fiber has not been scheduled yet, so the search is still running here.
      ov.running?.should be_true
      ov.handle_key(key(Key::Escape)).kind.should eq(:stay)
      ov.running?.should be_false
      ov.handle_key(key(Key::Escape)).kind.should eq(:close)
    end
  end

  it "cancels the search it abandons when the needle changes, and answers only the new one" do
    with_dir do |dir|
      proj, ids = project_with(dir, "p", [{"old.test", "/", nil}, {"new.test", "/", nil}])
      ov = ProjectSearchOverlay.new([proj])
      type(ov, "old.test")
      ov.start
      ov.running?.should be_true
      # The first edit stops the old run outright — not merely outvotes it by generation, which
      # would leave its fiber opening every project's database for a needle nobody wants.
      ov.handle_key(key(Key::Backspace))
      ov.running?.should be_false
      7.times { ov.handle_key(key(Key::Backspace)) }
      type(ov, "new.test")
      search_now(ov)
      ov.selected_pick.should eq({proj, ids[1]})
      ov.status_line.should eq("1/1 searched · 1 hit")
    end
  end

  it "reaches every skipped row, with no hit to hold the cursor" do
    with_dir do |dir|
      broken = (1..12).map do |i|
        Dir.mkdir_p(File.join(dir, "b#{i}"))
        proj = Gori::Project.new("broken-#{i}", File.join(dir, "b#{i}", Gori::Project::DB_FILE))
        File.write(proj.db_path, "definitely not a database, but long enough to have a header")
        proj
      end
      ov = ProjectSearchOverlay.new(broken)
      type(ov, "anything")
      search_now(ov)
      # A short card: ten skipped rows do not fit, so the last ones exist only below the fold.
      screen_rows(ov, h: 14).join("\n").should_not contain("broken-12 ")
      11.times do
        ov.handle_key(key(Key::Down))
        screen_rows(ov, h: 14)
      end
      screen_rows(ov, h: 14).join("\n").should contain("broken-12 ")
      # A skipped row takes the cursor but opens nothing.
      ov.handle_key(key(Key::Enter)).kind.should eq(:stay)
      ov.selected_pick.should be_nil
    end
  end

  it "hands the cursor to the first hit even when a skipped project arrived before it" do
    with_dir do |dir|
      Dir.mkdir_p(File.join(dir, "broken"))
      broken = Gori::Project.new("broken", File.join(dir, "broken", Gori::Project::DB_FILE))
      File.write(broken.db_path, "definitely not a database, but long enough to have a header")
      proj, ids = project_with(dir, "p", [{"first.test", "/", nil}])
      ov = ProjectSearchOverlay.new([broken, proj])
      type(ov, "first.test")
      search_now(ov)
      ov.selected_pick.should eq({proj, ids[0]})
    end
  end

  it "marks a group with more matches than it shows, and only then" do
    with_dir do |dir|
      cap = Gori::ProjectSearch::DEFAULT_CAP
      exact, _ = project_with(dir, "exact", (1..cap).map { |i| {"many.test", "/e#{i}", nil.as(String?)} })
      more, _ = project_with(dir, "more", (1..cap + 1).map { |i| {"many.test", "/m#{i}", nil.as(String?)} })
      ov = ProjectSearchOverlay.new([exact, more])
      type(ov, "many.test")
      search_now(ov)
      text = screen_rows(ov, h: 60).join("\n")
      text.should contain("#{cap} hits")
      text.should contain("#{cap}+ hits")
      text.scan(/#{cap}\+ hits/).size.should eq(1)
    end
  end

  it "keeps the cursor on the skipped row the operator chose while hits stream in above it" do
    with_dir do |dir|
      broken = (1..2).map do |i|
        Dir.mkdir_p(File.join(dir, "b#{i}"))
        proj = Gori::Project.new("broken-#{i}", File.join(dir, "b#{i}", Gori::Project::DB_FILE))
        File.write(proj.db_path, "definitely not a database, but long enough to have a header")
        proj
      end
      proj, _ = project_with(dir, "p", [{"late.test", "/", nil}])
      ov = ProjectSearchOverlay.new(broken + [proj])
      type(ov, "late.test")
      ov.start
      # Let the search fiber take the two broken projects — it yields after each — and no more.
      1000.times do
        break if ov.status_line.starts_with?("scanning 2/3")
        Fiber.yield
      end
      ov.status_line.should start_with("scanning 2/3")
      ov.handle_key(key(Key::Down)) # onto broken-2, deliberately
      search_now(ov)
      # p's group landed ABOVE the skipped rows; the cursor must still be on broken-2.
      ov.selected_pick.should be_nil
      active = screen_rows(ov).find(&.includes?("▎")).to_s
      active.should contain("broken-2")
    end
  end

  it "says how many projects it could search by host and path only" do
    with_dir do |dir|
      proj, _ = project_with(dir, "p", [{"a.test", "/", "no-index-needle"}])
      DB.connect("sqlite3:#{proj.db_path}") { |conn| conn.exec("DROP TABLE flows_fts") }
      ov = ProjectSearchOverlay.new([proj])
      type(ov, "no-index-needle")
      search_now(ov)
      ov.status_line.should eq("1/1 searched · 0 hits · 1 without a body index")
    end
  end

  it "quits the picker on ctrl-c" do
    ov = ProjectSearchOverlay.new([] of Gori::Project)
    ov.handle_key(key(Key::LowerC, Mod::Ctrl)).kind.should eq(:quit)
  end

  it "draws the progress line, each project's group and the ones it could not search" do
    with_dir do |dir|
      alpha, _ = project_with(dir, "alpha", [{"a.test", "/login", "needle-here"}, {"a.test", "/needle-path", nil}])
      Dir.mkdir_p(File.join(dir, "broken"))
      broken = Gori::Project.new("broken", File.join(dir, "broken", Gori::Project::DB_FILE))
      File.write(broken.db_path, "definitely not a database, but long enough to have a header")
      ov = ProjectSearchOverlay.new([alpha, broken])
      type(ov, "needle")
      search_now(ov)
      text = screen_rows(ov).join("\n")
      text.should contain("SEARCH ALL PROJECTS")
      text.should contain("2/2 searched · 2 hits · 1 skipped")
      text.should contain("alpha")
      text.should contain("2 hits")
      text.should contain("a.test/needle-path")
      text.should contain("a.test/login")
      # The body hit says why a URL without the needle is listed — and the tag does not push its
      # status out of the column the URL hit's status sits in.
      rows = screen_rows(ov)
      body_row = rows.find(&.includes?("a.test/login")).to_s
      url_row = rows.find(&.includes?("a.test/needle-path")).to_s
      body_row.should contain("body")
      url_row.should_not contain("body")
      body_row.index("200").should eq(url_row.index("200"))
      text.should contain("skipped  broken — #{Gori::ProjectSearch::NOT_A_DATABASE}")
    end
  end

  it "says when a short needle searched host and path only, and when nothing matched" do
    with_dir do |dir|
      proj, _ = project_with(dir, "p", [{"a.test", "/", "zq"}])
      ov = ProjectSearchOverlay.new([proj])
      type(ov, "zq")
      search_now(ov)
      ov.status_line.should eq("1/1 searched · 0 hits · host/path only")
      screen_rows(ov).join("\n").should contain("no flow matches in 1 project")
    end
  end

  it "explains itself before anything is typed" do
    ov = ProjectSearchOverlay.new([Gori::Project.new("x", "/nonexistent/gori.db")])
    text = screen_rows(ov).join("\n")
    text.should contain("type to search the captured flows of every project")
    text.should contain("bodies from 3")
    ov.status_line.should eq("1 project")
  end

  it "selects a hit on the first click and opens it on the second; a click outside closes" do
    with_dir do |dir|
      proj, ids = project_with(dir, "p", [{"c.test", "/1", nil}, {"c.test", "/2", nil}])
      ov = ProjectSearchOverlay.new([proj])
      type(ov, "c.test")
      search_now(ov)
      area = Rect.new(0, 0, 90, 24)
      screen_rows(ov) # a render settles the scroll the hit-test reads
      box = ov.overlay_box(area).not_nil!
      top = box.y + ProjectSearchOverlay::LIST_OFFSET
      # Newest first: row 0 is the header, row 1 is /2, row 2 is /1.
      ov.click(area, box.x + 10, top + 2).kind.should eq(:stay)
      ov.selected_pick.should eq({proj, ids[0]})
      ov.click(area, box.x + 10, top).kind.should eq(:stay) # the header is not a hit
      ov.selected_pick.should eq({proj, ids[0]})
      out = ov.click(area, box.x + 10, top + 2)
      out.kind.should eq(:open)
      out.flow_id.should eq(ids[0])
      ov.click(area, 0, area.h - 1).kind.should eq(:close)
    end
  end
end
