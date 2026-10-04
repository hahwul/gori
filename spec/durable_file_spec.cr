require "./spec_helper"

# Six independent temp+rename impls collapsed into `DurableFile`, and each of the five
# non-reference ones had dropped a different part of the contract. These examples pin the
# parts, so a future caller cannot quietly reintroduce one of the five.
describe Gori::DurableFile do
  describe "symlink handling" do
    # The reason this module exists. `gori --config ~/dotfiles/gori.json` is the advertised
    # way to point gori at a version-controlled settings file; a rename over the link
    # detaches it, and the repo copy then goes stale with nothing to show in `git status`.
    it "writes THROUGH a symlink instead of replacing it" do
      posix_only!("File.symlink needs Developer Mode")
      DurableFileSpec.in_tmp do |dir|
        real = File.join(dir, "real.json")
        link = File.join(dir, "link.json")
        File.write(real, "old")
        File.symlink(real, link)

        Gori::DurableFile.write(link, "new", perm: DurableFileSpec::RW)

        File.symlink?(link).should be_true
        File.read(real).should eq("new")
      end
    end

    it "replaces a DANGLING symlink with a real file rather than failing" do
      posix_only!("File.symlink needs Developer Mode")
      DurableFileSpec.in_tmp do |dir|
        link = File.join(dir, "link.json")
        target = File.join(dir, "gone.json")
        File.symlink(target, link)

        Gori::DurableFile.write(link, "new", perm: DurableFileSpec::RW)

        # `File.read(link)` alone would also pass if the code had FOLLOWED the dangling
        # link and created its target — reading through the link returns "new" either way.
        File.symlink?(link).should be_false
        File.exists?(target).should be_false
        File.read(link).should eq("new")
      end
    end

    # The shape the module doc leads with: the link and its target in DIFFERENT directories.
    # The temp has to be staged beside the TARGET, not beside the link, or the rename
    # crosses a filesystem boundary and the mode lands on the wrong side.
    it "stages beside the target when the link points into another directory" do
      posix_only!("File.symlink needs Developer Mode")
      DurableFileSpec.in_tmp do |dir|
        link_dir = File.join(dir, "home")
        real_dir = File.join(dir, "dotfiles")
        Dir.mkdir_p(link_dir)
        Dir.mkdir_p(real_dir)
        real = File.join(real_dir, "gori.json")
        link = File.join(link_dir, "gori.json")
        File.write(real, "old")
        File.symlink(real, link)

        Gori::DurableFile.write(link, "new", perm: DurableFileSpec::RW)

        File.symlink?(link).should be_true
        File.read(real).should eq("new")
        Dir.children(link_dir).should eq(["gori.json"])
        Dir.children(real_dir).should eq(["gori.json"])
      end
    end
  end

  describe "permissions" do
    before_each { posix_only!("POSIX mode bits") }

    it "carries an existing file's mode across the replace" do
      DurableFileSpec.in_tmp do |dir|
        path = File.join(dir, "cfg.json")
        File.write(path, "old")
        File.chmod(path, 0o600)

        Gori::DurableFile.write(path, "new", perm: DurableFileSpec::RW)

        File.info(path).permissions.should eq(File::Permissions.new(0o600))
      end
    end

    it "uses perm for a file that does not exist yet" do
      DurableFileSpec.in_tmp do |dir|
        path = File.join(dir, "cfg.json")

        Gori::DurableFile.write(path, "new", perm: File::Permissions.new(0o600))

        File.info(path).permissions.should eq(File::Permissions.new(0o600))
      end
    end

    # Every other mode example uses 0600, so an implementation that ignored `perm` and
    # hardcoded 0600 would pass all of them — while silently flipping the two 0644 callers
    # (`.capture.status` and the active-project marker) to 0600. This is the one that
    # observes `perm` actually taking effect. It also catches the umask leaking through
    # `File.open`'s `perm:`.
    it "honours a perm other than 0600 for a new file" do
      DurableFileSpec.in_tmp do |dir|
        path = File.join(dir, "marker")

        Gori::DurableFile.write(path, "new", perm: File::Permissions.new(0o644))

        File.info(path).permissions.should eq(File::Permissions.new(0o644))
      end
    end

    # settings.json holds `env` token VALUES; a copy an older gori wrote at 0644 has to be
    # tightened on the way past, not carried forward. That is what `inherit: false` is for.
    it "forces perm over an existing mode when inherit is false" do
      DurableFileSpec.in_tmp do |dir|
        path = File.join(dir, "settings.json")
        File.write(path, "old")
        File.chmod(path, 0o644)

        Gori::DurableFile.write(path, "new", perm: File::Permissions.new(0o600), inherit: false)

        File.info(path).permissions.should eq(File::Permissions.new(0o600))
      end
    end
  end

  describe "temp files" do
    # `"#{path}.tmp"` was shared by every process writing that path. Two stagers
    # then wrote one file and one renamed the other's half-written bytes into place.
    it "does not derive the temp name from the destination alone" do
      DurableFileSpec.in_tmp do |dir|
        path = File.join(dir, "cfg.json")
        seen = [] of String
        2.times do
          Gori::DurableFile.stage(path, perm: DurableFileSpec::RW) { |tmp, _m| seen << tmp; File.write(tmp, "x") }.discard
        end
        seen.uniq.size.should eq(2)
        seen.should_not contain("#{path}.tmp")
      end
    end

    it "stages in the destination's own directory so the rename stays intra-filesystem" do
      DurableFileSpec.in_tmp do |dir|
        path = File.join(dir, "cfg.json")
        yielded = false
        Gori::DurableFile.stage(path, perm: DurableFileSpec::RW) do |tmp, _m|
          yielded = true
          File.dirname(tmp).should eq(dir)
          File.write(tmp, "x")
        end.discard
        # Asserted OUTSIDE the block: an implementation that stopped yielding would
        # otherwise pass this example by never running its only assertion.
        yielded.should be_true
      end
    end

    # `replace`'s cleanup has to cover a rename that fails AFTER staging succeeded, not
    # just a failing write. A destination that is a non-empty directory makes rename(2)
    # fail exactly there. This is the contract `CertAuthority.write_pair` broke by
    # committing two staged files without a guard over both.
    it "leaves no temp behind when the COMMIT fails" do
      DurableFileSpec.in_tmp do |dir|
        occupied = File.join(dir, "cfg.json")
        Dir.mkdir_p(occupied)
        File.write(File.join(occupied, "child"), "x")

        expect_raises(Exception) do
          Gori::DurableFile.write(occupied, "new", perm: DurableFileSpec::RW)
        end

        Dir.children(dir).should eq(["cfg.json"])
      end
    end

    # `fsync` opens the temp with "a", which CREATES it. Without a guard, a block that
    # wrote nothing yields a valid-looking Staged over a zero-byte file, and committing it
    # blanks live data. No caller does this today; the guard is for the next one.
    it "refuses to install a replacement the block never wrote" do
      DurableFileSpec.in_tmp do |dir|
        path = File.join(dir, "cfg.json")
        File.write(path, "IMPORTANT LIVE DATA")

        expect_raises(Gori::Error, /staged no file/) do
          Gori::DurableFile.replace(path, perm: DurableFileSpec::RW) { |_t, _m| }
        end

        File.read(path).should eq("IMPORTANT LIVE DATA")
        Dir.children(dir).should eq(["cfg.json"])
      end
    end

    # `write_active_project` swallowed every failure at a method-level rescue and left
    # `active_project.tmp.<pid>` behind; nothing in the tree ever swept those. A failing
    # write must clean up after itself AND surface the cause that actually failed, not a
    # complaint about a temp file the operator has never heard of.
    it "leaves no temp behind when the write raises, and reports the original cause" do
      DurableFileSpec.in_tmp do |dir|
        path = File.join(dir, "cfg.json")
        expect_raises(Gori::Error, "boom") do
          Gori::DurableFile.replace(path, perm: DurableFileSpec::RW) do |tmp, _m|
            # Write BEFORE raising: the leak this pins is a temp that reached the disk and
            # was then abandoned, which is the only way `active_project.tmp.<pid>` piled up.
            File.write(tmp, "partial")
            raise Gori::Error.new("boom")
          end
        end
        Dir.children(dir).should be_empty
      end
    end
  end

  describe "staging without committing" do
    # The CA writes a cert and a key that must agree. Both are staged in full before either
    # is renamed, so the on-disk pair never disagrees past the gap between the renames.
    it "does not touch the destination until commit" do
      DurableFileSpec.in_tmp do |dir|
        path = File.join(dir, "cfg.json")
        File.write(path, "old")

        staged = Gori::DurableFile.stage(path, perm: DurableFileSpec::RW) { |tmp, _m| File.write(tmp, "new") }
        File.read(path).should eq("old")

        staged.commit
        File.read(path).should eq("new")
      end
    end

    it "discards a staged replacement without disturbing the destination" do
      DurableFileSpec.in_tmp do |dir|
        path = File.join(dir, "cfg.json")
        File.write(path, "old")

        Gori::DurableFile.stage(path, perm: DurableFileSpec::RW) { |tmp, _m| File.write(tmp, "new") }.discard

        File.read(path).should eq("old")
        Dir.children(dir).should eq(["cfg.json"])
      end
    end
  end
end

# Helper namespace: `describe` blocks cannot host `def self.`, so the scratch-dir helper
# lives here.
module DurableFileSpec
  RW = File::Permissions.new(0o644)

  def self.in_tmp(&)
    dir = File.tempname("gori-durable")
    Dir.mkdir_p(dir)
    begin
      yield dir
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
