require "./spec_helper"
require "file_utils"

private def mode_of(path : String) : Int32
  (File.info(path).permissions.value & 0o777).to_i
end

private def with_tmp_dir(&)
  dir = File.tempname("gori-paths")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

# `ensure_dir` locks gori's own tree to 0700 (captured traffic, the CA key, settings.json).
# The `tighten:` split exists because ONE caller — Settings.save under `gori --config PATH` —
# passes a directory the operator named rather than one gori owns, and re-moding that is a
# side effect nobody asked for.
describe Gori::Paths do
  describe ".ensure_dir" do
    it "creates a missing directory at 0700" do
      with_tmp_dir do |dir|
        fresh = File.join(dir, "made", "by", "gori")
        Gori::Paths.ensure_dir(fresh)
        mode_of(fresh).should eq(0o700)
      end
    end

    it "tightens a pre-existing loose directory by default" do
      with_tmp_dir do |dir|
        # An 0755 tree from an install that predates DIR_MODE.
        File.chmod(dir, 0o755)
        Gori::Paths.ensure_dir(dir)
        mode_of(dir).should eq(0o700)
      end
    end

    # The regression this pair pins: `--config ~/dotfiles/gori.json` used to chmod
    # ~/dotfiles to 0700, and a relative `--config gori.json` did it to the working
    # directory.
    it "leaves a pre-existing directory's mode alone with tighten: false" do
      with_tmp_dir do |dir|
        File.chmod(dir, 0o755)
        Gori::Paths.ensure_dir(dir, tighten: false)
        mode_of(dir).should eq(0o755)
      end
    end

    # Not owning a directory it FINDS does not mean not owning one it MAKES: an intermediate
    # gori has to create for the config file is still gori's, so it is created locked.
    it "still creates a missing directory at 0700 with tighten: false" do
      with_tmp_dir do |dir|
        File.chmod(dir, 0o755)
        nested = File.join(dir, "profiles")
        Gori::Paths.ensure_dir(nested, tighten: false)
        mode_of(nested).should eq(0o700)
        mode_of(dir).should eq(0o755) # the parent it merely passed through is untouched
      end
    end
  end
end
