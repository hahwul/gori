require "./spec_helper"
require "file_utils"

describe Gori::CaptureLock do
  it "acquires a free dir, denies a second concurrent holder, and frees on close" do
    dir = File.tempname("gori-lock")
    begin
      a = Gori::CaptureLock.try(dir)
      a.should_not be_nil
      # A second acquire opens a NEW fd on the same path; flock treats separate
      # opens as independent OFDs and denies the second while `a` holds it.
      Gori::CaptureLock.try(dir).should be_nil
      a.not_nil!.close
      b = Gori::CaptureLock.try(dir) # freed on close
      b.should_not be_nil
      b.not_nil!.close
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  it "creates the project dir if it does not exist yet" do
    parent = File.tempname("gori-lock-parent")
    dir = File.join(parent, "proj")
    begin
      Dir.exists?(dir).should be_false
      lock = Gori::CaptureLock.try(dir)
      lock.should_not be_nil
      Dir.exists?(dir).should be_true
      File.exists?(Gori::CaptureLock.path(dir)).should be_true
      lock.not_nil!.close
    ensure
      FileUtils.rm_rf(parent) if Dir.exists?(parent)
    end
  end

  it "keys the lock on the DB FILE so two --db files sharing a directory don't collide" do
    dir = File.tempname("gori-lock-db")
    Dir.mkdir_p(dir)
    begin
      pa = Gori::Project.new("a", File.join(dir, "a.db"))
      pb = Gori::Project.new("b", File.join(dir, "b.db"))
      # Distinct db files ⇒ distinct lock files (the bug: they shared <dir>/.capture.lock).
      pa.capture_lock_path.should_not eq(pb.capture_lock_path)

      la = Gori::CaptureLock.try_at(pa.capture_lock_path)
      la.should_not be_nil
      # A DIFFERENT database in the SAME directory must still acquire its own lock — no false
      # serialization (previously this failed with "another instance holds this ... lock").
      lb = Gori::CaptureLock.try_at(pb.capture_lock_path)
      lb.should_not be_nil
      # A second holder of the SAME database is still denied.
      Gori::CaptureLock.try_at(pa.capture_lock_path).should be_nil

      la.not_nil!.close
      lb.not_nil!.close
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  it "keeps the canonical registry db on the legacy per-directory lock (dir-based held? still works)" do
    dir = File.tempname("gori-lock-reg")
    begin
      proj = Gori::Project.new("reg", File.join(dir, Gori::Project::DB_FILE)) # gori.db
      # The canonical db keeps <dir>/.capture.lock, so the registry's dir-based held? guards
      # (delete/rename, project picker, mcp) keep detecting a live capturer — no regression.
      proj.capture_lock_path.should eq(Gori::CaptureLock.path(dir))
      lock = Gori::CaptureLock.try_at(proj.capture_lock_path)
      lock.should_not be_nil
      Gori::CaptureLock.held?(dir).should be_true # dir-based probe sees the db-keyed acquire
      lock.not_nil!.close
      Gori::CaptureLock.held?(dir).should be_false
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end
end
