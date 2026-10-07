require "./spec_helper"
require "file_utils"

private def with_shared_dir(&)
  dir = File.tempname("gori-status-key")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

# The capture-status marker describes the capture the capture LOCK guards, so the two have to
# agree on identity. The lock is keyed on the DB FILE precisely so two `--db` databases sharing
# a directory capture independently; the marker was keyed on the directory, so those two
# sessions shared one file.
describe "capture-status marker keying" do
  it "gives two databases in one directory their own marker" do
    with_shared_dir do |dir|
      canonical = Gori::Project.new("api", File.join(dir, Gori::Project::DB_FILE))
      side = Gori::Project.new("side", File.join(dir, "other.db"))

      # Precondition, and the reason this matters: both hold their own lock at once.
      canonical.capture_lock_path.should_not eq(side.capture_lock_path)
      a = Gori::CaptureLock.try_at(canonical.capture_lock_path)
      b = Gori::CaptureLock.try_at(side.capture_lock_path)
      begin
        a.should_not be_nil
        b.should_not be_nil
      ensure
        a.try(&.close)
        b.try(&.close)
      end

      canonical.capture_status_path.should_not eq(side.capture_status_path)

      Gori::CaptureStatus.write_at(canonical.capture_status_path, "127.0.0.1", 8070, true)
      Gori::CaptureStatus.write_at(side.capture_status_path, "10.0.0.9", 9999, true)

      # The second write must not have overwritten the first session's address.
      Gori::CaptureStatus.read_at(canonical.capture_status_path).not_nil!.port.should eq(8070)
      Gori::CaptureStatus.read_at(side.capture_status_path).not_nil!.port.should eq(9999)

      # And one session closing must not delete a live session's marker.
      File.delete?(side.capture_status_path)
      Gori::CaptureStatus.read_at(canonical.capture_status_path).not_nil!.port.should eq(8070)
      Gori::CaptureStatus.read_at(side.capture_status_path).should be_nil
    end
  end

  it "keeps the canonical db on the legacy per-directory path" do
    with_shared_dir do |dir|
      # No migration and no regression: the picker reads `CaptureStatus.path(project.dir)` for
      # every registry project, and every marker already on disk lives at that path.
      project = Gori::Project.new("api", File.join(dir, Gori::Project::DB_FILE))
      project.capture_status_path.should eq(Gori::CaptureStatus.path(dir))
      Gori::CaptureStatus.write_at(project.capture_status_path, "127.0.0.1", 8070, false)
      Gori::CaptureStatus.read_at(Gori::CaptureStatus.path(dir)).not_nil!.listening.should be_false
      Gori::CaptureStatus.read_at(Gori::CaptureStatus.path(dir)).not_nil!.port.should eq(8070)
    end
  end

  it "creates the directory for a marker written beside a db that has no dir yet" do
    parent = File.tempname("gori-status-parent")
    begin
      project = Gori::Project.new("side", File.join(parent, "proj", "other.db"))
      Gori::CaptureStatus.write_at(project.capture_status_path, "127.0.0.1", 8071, true)
      Gori::CaptureStatus.read_at(project.capture_status_path).not_nil!.port.should eq(8071)
    ensure
      FileUtils.rm_rf(parent) if Dir.exists?(parent)
    end
  end
end
