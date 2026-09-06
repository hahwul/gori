require "./spec_helper"
require "file_utils"

# gori runs SQLite in WAL mode, so a live session's writes land in `<db>-wal` and the MAIN
# file's mtime does not move until a checkpoint — which happens when the last connection
# closes. `Project#last_modified` read only the main file, and reported "last active" as the
# moment the project was CREATED for the whole time it was open:
#
#   * the Project tab drew `Activity: 16m ago` above `Created: 7m ago` — activity older than
#     creation, which cannot be true (that row is gone from the tab now, but the reader is not:
#     `project list` below still prints it);
#   * `gori run project list` (and MCP `list_projects`) printed the creation time for a project
#     a peer process was capturing into right then.
#
# `Store.captured_flows` already guards the opposite direction — a read-only census closes the
# last connection, that checkpoints, and the project would be stamped "just active", so it puts
# the mtime back. This is the direction nothing covered.
private def with_db(&)
  dir = File.tempname("gori-wal-mtime")
  Dir.mkdir_p(dir)
  begin
    yield File.join(dir, "gori.db")
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe "Gori::Project#last_modified" do
  it "follows the write-ahead log, which is the only file a live session touches" do
    with_db do |path|
      File.write(path, "x")
      old = Time.utc(2020, 1, 1, 0, 0, 0)
      File.touch(path, old)
      p = Gori::Project.new("wal", path)
      p.last_modified.try(&.to_unix).should eq(old.to_unix)

      # A write lands in the WAL; the db file is untouched, exactly as SQLite leaves it.
      File.write("#{path}-wal", "pending")
      newer = old + 20.minutes
      File.touch("#{path}-wal", newer)
      File.info(path).modification_time.to_unix.should eq(old.to_unix) # unchanged, the premise
      p.last_modified.try(&.to_unix).should eq(newer.to_unix)
    end
  end

  it "keeps the db file's own mtime when it is the newer of the two (post-checkpoint)" do
    with_db do |path|
      File.write(path, "x")
      File.write("#{path}-wal", "")
      stale = Time.utc(2020, 1, 1, 0, 0, 0)
      checkpointed = stale + 1.hour
      File.touch("#{path}-wal", stale)
      File.touch(path, checkpointed)
      Gori::Project.new("wal", path).last_modified.try(&.to_unix).should eq(checkpointed.to_unix)
    end
  end

  it "still answers with no WAL beside it, and nil with no database at all" do
    with_db do |path|
      File.write(path, "x")
      Gori::Project.new("wal", path).last_modified.should_not be_nil
      File.delete(path)
      Gori::Project.new("wal", path).last_modified.should be_nil
    end
  end
end

describe "Gori::Project#db_size_with_wal" do
  it "counts the pending writes the plain db_size cannot see" do
    with_db do |path|
      File.write(path, "0" * 4096)
      File.write("#{path}-wal", "0" * 65536)
      p = Gori::Project.new("wal", path)
      p.db_size.should eq(4096)                  # what MCP/CLI keep reporting under that name
      p.db_size_with_wal.should eq(4096 + 65536) # what the Project tab's DB Size row shows
    end
  end

  it "equals db_size when there is no WAL, and never counts -shm" do
    with_db do |path|
      File.write(path, "0" * 1024)
      File.write("#{path}-shm", "0" * 32768) # a shared-memory index, not data
      p = Gori::Project.new("wal", path)
      p.db_size_with_wal.should eq(1024)
    end
  end
end
