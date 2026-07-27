require "./spec_helper"
require "file_utils"

private def with_tmp_dir(&)
  dir = File.tempname("gori-project")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe Gori::Project do
  # The TUI used to answer a failed open by dropping the operator on the project picker
  # with NOTHING on screen — the reason reachable only by knowing to read ~/.gori/gori.log.
  # A typo'd `--db` therefore rendered as "no projects yet", which reads as "my capture is
  # gone". These pin the message the picker now shows.
  describe "#open_failure_reason" do
    # SQLite raises the same DB::ConnectionRefused whether the directory is missing, the
    # file is not a database, or it simply cannot be read — so the message has to come from
    # the path, not the exception. Both examples below pass the SAME exception.
    it "names the missing parent directory" do
      with_tmp_dir do |dir|
        project = Gori::Project.new("p", File.join(dir, "nope", "gori.db"))
        reason = project.open_failure_reason(DB::ConnectionRefused.new)
        reason.should contain("no such directory")
        reason.should contain(File.join(dir, "nope"))
      end
    end

    it "says a present file is not a database" do
      with_tmp_dir do |dir|
        path = File.join(dir, "notes.txt")
        File.write(path, "not a database")
        reason = Gori::Project.new("p", path).open_failure_reason(DB::ConnectionRefused.new)
        reason.should contain("not a valid SQLite database")
        reason.should contain(path)
      end
    end

    # "The file is not there" is not a failure on its own — the TUI CREATES a db at a fresh
    # path in a directory that exists. Reaching here with one means something else broke, so
    # the exception is all there is to report; claiming "not a valid SQLite database" about
    # a file that does not exist would be a wrong answer stated confidently.
    it "falls back to the exception when the path explains nothing" do
      with_tmp_dir do |dir|
        project = Gori::Project.new("mydb", File.join(dir, "fresh.db"))
        reason = project.open_failure_reason(Gori::Error.new("disk is full"))
        reason.should contain("mydb")
        reason.should contain("disk is full")
      end
    end

    # A non-DB exception against an EXISTING file takes the same fallback: only a driver
    # error is evidence about the file's contents.
    it "does not blame the file for a non-database error" do
      with_tmp_dir do |dir|
        path = File.join(dir, "gori.db")
        File.write(path, "")
        reason = Gori::Project.new("p", path).open_failure_reason(Gori::Error.new("migration failed"))
        reason.should_not contain("not a valid SQLite database")
        reason.should contain("migration failed")
      end
    end

    # Never blank: the picker prints this verbatim, and an empty red row is worse than a
    # class name.
    it "still says something when the exception has no message" do
      with_tmp_dir do |dir|
        project = Gori::Project.new("p", File.join(dir, "fresh.db"))
        project.open_failure_reason(Exception.new).presence.should_not be_nil
      end
    end
  end
end
