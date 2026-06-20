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
end
