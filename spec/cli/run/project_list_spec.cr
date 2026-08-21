require "../../spec_helper"
require "file_utils"

# `gori run project list` — which projects it prints, and which project a `--project`-less
# `gori run` actually reads.
#
# Both answer the same operator question: an operator with a project per worktree has
# hundreds of them, all but a few holding nothing, and every `gori run` silently reads
# whichever was touched last. `gori run history` printing "no flows" against a project
# created a minute earlier — while the one they meant still held 1609 — is that question
# going unanswered twice over.

# Private CLI glue — reopen the module for bare-call wrappers (see project_spec.cr).
module Gori::CLI::Run
  def self.project_list_rows_for_spec(counted : Array({Gori::Project, Int64?}), active_db : String?,
                                      all : Bool) : Array(ProjectListRow)
    project_list_rows(counted, active_db, all)
  end

  def self.resolve_read_project_for_spec(project_name : String?, db_path : String?) : Gori::Project
    resolve_read_project(project_name, db_path)
  end

  # The notice is deliberately once-per-PROCESS, and a spec run is one process.
  def self.reset_default_project_notice_for_spec : Nil
    @@said_default_project = false
  end
end

private def with_project_root(&)
  root = File.tempname("gori-listroot")
  begin
    yield Gori::ProjectRegistry.new(root)
  ensure
    FileUtils.rm_rf(root)
  end
end

# A fresh `$GORI_HOME`, so `resolve_read_project` (which reads `Paths.projects_dir`) sees
# only this example's projects and not the suite-wide temp home.
private def with_gori_home(&)
  previous = ENV["GORI_HOME"]?
  home = File.tempname("gori-listhome")
  Dir.mkdir_p(File.join(home, "projects"))
  ENV["GORI_HOME"] = home
  begin
    yield Gori::ProjectRegistry.new(Gori::Paths.projects_dir)
  ensure
    previous ? (ENV["GORI_HOME"] = previous) : ENV.delete("GORI_HOME")
    FileUtils.rm_rf(home)
  end
end

private def seed_project_flow(store) : Int64
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "ex.test", port: 443,
    method: "GET", target: "/", http_version: "HTTP/1.1",
    head: "GET / HTTP/1.1\r\nHost: ex.test\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
end

# One handle, closed exactly once — Store#close is NOT idempotent.
private def with_project_store(project : Gori::Project, &)
  store = Gori::Store.open(project.db_path)
  begin
    yield store
  ensure
    store.close
  end
end

private def project_at(dir : String) : Gori::Project
  Gori::Project.new(File.basename(dir), File.join(dir, Gori::Project::DB_FILE))
end

describe Gori::Store do
  describe ".captured_flows" do
    it "counts a project's flows without opening (and migrating) it as a Store" do
      with_project_root do |registry|
        project = registry.create("spec proj")
        Gori::Store.captured_flows(project.db_path).should eq(0)
        with_project_store(project) { |store| 2.times { seed_project_flow(store) } }
        Gori::Store.captured_flows(project.db_path).should eq(2)
      end
    end

    it "leaves the db's mtime alone, so a census cannot re-order the projects" do
      with_project_root do |registry|
        project = registry.create("spec proj")
        with_project_store(project) { |store| seed_project_flow(store) }
        # Backdate it: `Project#last_modified` is what sorts the registry MRU-first, and a
        # listing that stamped every project "now" would destroy the very ordering the
        # "current project" marker is read off.
        old = Time.utc(2020, 1, 2, 3, 4, 5)
        File.utime(old, old, project.db_path)
        Gori::Store.captured_flows(project.db_path).should eq(1)
        File.info(project.db_path).modification_time.to_unix.should eq(old.to_unix)
      end
    end

    it "answers nil — not 0 — for something that is not a readable project db" do
      with_project_root do |registry|
        project = registry.create("spec proj")
        Gori::Store.captured_flows(File.join(project.dir, "nope.db")).should be_nil
        junk = File.join(project.dir, "junk.db")
        File.write(junk, "this is not a database")
        Gori::Store.captured_flows(junk).should be_nil
      end
    end
  end
end

describe "gori run project list" do
  it "omits a project with nothing captured in it" do
    with_project_root do |registry|
      busy = registry.create("busy")
      leftover = registry.create("leftover")
      counted = [{busy, 3_i64.as(Int64?)}, {leftover, 0_i64.as(Int64?)}]
      rows = Gori::CLI::Run.project_list_rows_for_spec(counted, nil, false)
      rows.map(&.project.name).should eq(["busy"])
    end
  end

  it "includes it under --all" do
    with_project_root do |registry|
      busy = registry.create("busy")
      leftover = registry.create("leftover")
      counted = [{busy, 3_i64.as(Int64?)}, {leftover, 0_i64.as(Int64?)}]
      rows = Gori::CLI::Run.project_list_rows_for_spec(counted, nil, true)
      rows.map(&.project.name).should eq(["busy", "leftover"])
      rows.map(&.empty?).should eq([false, true])
    end
  end

  it "always lists the project a --project-less run would read, empty or not" do
    with_project_root do |registry|
      # Head of an MRU-sorted list = what `ProjectRegistry.default_of` picks, so this is a
      # brand-new project the operator just made: 0 flows, and the very one they want to see.
      fresh = registry.create("just made")
      busy = registry.create("busy")
      counted = [{fresh, 0_i64.as(Int64?)}, {busy, 9_i64.as(Int64?)}]
      rows = Gori::CLI::Run.project_list_rows_for_spec(counted, nil, false)
      rows.map(&.project.name).should eq(["just made", "busy"])
      rows.map(&.current).should eq([true, false])
    end
  end

  it "always lists the project the TUI has open, even when it is neither busy nor current" do
    with_project_root do |registry|
      busy = registry.create("busy")
      open_in_tui = registry.create("open in tui")
      empty = registry.create("empty")
      counted = [{busy, 9_i64.as(Int64?)}, {open_in_tui, 0_i64.as(Int64?)}, {empty, 0_i64.as(Int64?)}]
      rows = Gori::CLI::Run.project_list_rows_for_spec(counted, open_in_tui.db_path, false)
      rows.map(&.project.name).should eq(["busy", "open in tui"])
      rows.map(&.tui_active).should eq([false, true])
    end
  end

  it "keeps a project the census could not read, because unmeasured is not empty" do
    with_project_root do |registry|
      busy = registry.create("busy")
      unreadable = registry.create("unreadable")
      counted = [{busy, 9_i64.as(Int64?)}, {unreadable, nil.as(Int64?)}]
      rows = Gori::CLI::Run.project_list_rows_for_spec(counted, nil, false)
      rows.map(&.project.name).should eq(["busy", "unreadable"])
    end
  end
end

describe "gori run — the defaulted project" do
  it "says which project it used when --project and --db are both omitted" do
    with_gori_home do |registry|
      registry.create("demo")
      notice = IO::Memory.new
      Gori::CLI::Run.default_project_io = notice
      Gori::CLI::Run.reset_default_project_notice_for_spec
      begin
        Gori::CLI::Run.resolve_read_project_for_spec(nil, nil).name.should eq("demo")
        notice.to_s.should contain("using project demo (most recently active)")
        # Once per PROCESS: one command resolves its project up to three times, and three
        # copies of the line read like three different projects.
        Gori::CLI::Run.resolve_read_project_for_spec(nil, nil)
        notice.to_s.scan("using project").size.should eq(1)
      ensure
        Gori::CLI::Run.default_project_io = STDERR
      end
    end
  end

  it "stays quiet when --project names the project outright" do
    with_gori_home do |registry|
      registry.create("demo")
      notice = IO::Memory.new
      Gori::CLI::Run.default_project_io = notice
      Gori::CLI::Run.reset_default_project_notice_for_spec
      begin
        Gori::CLI::Run.resolve_read_project_for_spec("demo", nil).name.should eq("demo")
        notice.to_s.should be_empty
      ensure
        Gori::CLI::Run.default_project_io = STDERR
      end
    end
  end

  it "stays quiet when --db names the database outright" do
    with_gori_home do |registry|
      project = registry.create("demo")
      notice = IO::Memory.new
      Gori::CLI::Run.default_project_io = notice
      Gori::CLI::Run.reset_default_project_notice_for_spec
      begin
        Gori::CLI::Run.resolve_read_project_for_spec(nil, project.db_path)
        notice.to_s.should be_empty
      ensure
        Gori::CLI::Run.default_project_io = STDERR
      end
    end
  end
end
