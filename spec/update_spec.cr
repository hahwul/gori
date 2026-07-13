require "./spec_helper"
require "file_utils"

describe Gori::Update do
  describe ".detect_channel" do
    it "detects Homebrew Cellar paths" do
      Gori::Update.detect_channel("/opt/homebrew/Cellar/gori/0.1.0/bin/gori").should eq(Gori::Update::Channel::Homebrew)
      Gori::Update.detect_channel("/usr/local/Cellar/gori/0.2.0/bin/gori").should eq(Gori::Update::Channel::Homebrew)
      Gori::Update.detect_channel("/home/linuxbrew/.linuxbrew/Cellar/gori/0.1.0/bin/gori").should eq(Gori::Update::Channel::Homebrew)
    end

    it "detects Homebrew opt and prefix paths" do
      Gori::Update.detect_channel("/opt/homebrew/bin/gori").should eq(Gori::Update::Channel::Homebrew)
      Gori::Update.detect_channel("/opt/homebrew/opt/gori/bin/gori").should eq(Gori::Update::Channel::Homebrew)
      Gori::Update.detect_channel("/home/linuxbrew/.linuxbrew/bin/gori").should eq(Gori::Update::Channel::Homebrew)
    end

    it "detects Snap paths" do
      Gori::Update.detect_channel("/snap/gori/current/bin/gori").should eq(Gori::Update::Channel::Snap)
      Gori::Update.detect_channel("/snap/bin/gori").should eq(Gori::Update::Channel::Snap)
    end

    it "classifies /usr/bin by package ownership, not path alone" do
      Gori::Update.detect_channel("/usr/bin/gori",
        owner: Gori::Update::OwnerResult::Pacman).should eq(Gori::Update::Channel::Pacman)
      Gori::Update.detect_channel("/usr/bin/gori",
        owner: Gori::Update::OwnerResult::Dpkg).should eq(Gori::Update::Channel::Deb)
      Gori::Update.detect_channel("/usr/bin/gori",
        owner: Gori::Update::OwnerResult::Rpm).should eq(Gori::Update::Channel::Rpm)
      # Manual copy into /usr/bin — package manager says "not owned" → self-update
      Gori::Update.detect_channel("/usr/bin/gori",
        owner: Gori::Update::OwnerResult::None).should eq(Gori::Update::Channel::Binary)
    end

    it "falls back to os-release family when ownership cannot be probed" do
      Gori::Update.detect_channel("/usr/bin/gori",
        owner: Gori::Update::OwnerResult::Unknown,
        os_family: Gori::Update::OsFamily::ArchLike).should eq(Gori::Update::Channel::Pacman)
      Gori::Update.detect_channel("/usr/bin/gori",
        owner: Gori::Update::OwnerResult::Unknown,
        os_family: Gori::Update::OsFamily::DebianLike).should eq(Gori::Update::Channel::Deb)
      Gori::Update.detect_channel("/usr/bin/gori",
        owner: Gori::Update::OwnerResult::Unknown,
        os_family: Gori::Update::OsFamily::RhelLike).should eq(Gori::Update::Channel::Rpm)
      Gori::Update.detect_channel("/usr/bin/gori",
        owner: Gori::Update::OwnerResult::Unknown,
        os_family: Gori::Update::OsFamily::Unknown).should eq(Gori::Update::Channel::Binary)
    end

    it "classifies standalone binary installs (including curl opt layout and workspace builds)" do
      Gori::Update.detect_channel("/usr/local/bin/gori").should eq(Gori::Update::Channel::Binary)
      # curl install.sh uses PREFIX/opt/gori — must NOT be misclassified as Homebrew
      Gori::Update.detect_channel("/usr/local/opt/gori/gori").should eq(Gori::Update::Channel::Binary)
      Gori::Update.detect_channel("/Users/dev/Projects/gori/bin/gori").should eq(Gori::Update::Channel::Binary)
      Gori::Update.detect_channel("/home/user/.local/bin/gori").should eq(Gori::Update::Channel::Binary)
    end
  end

  describe ".parse_os_release" do
    it "detects Arch-like IDs" do
      Gori::Update.parse_os_release("ID=arch\n").should eq(Gori::Update::OsFamily::ArchLike)
      Gori::Update.parse_os_release("ID=manjaro\nID_LIKE=arch\n").should eq(Gori::Update::OsFamily::ArchLike)
    end

    it "detects Debian-like IDs" do
      Gori::Update.parse_os_release("ID=ubuntu\nID_LIKE=debian\n").should eq(Gori::Update::OsFamily::DebianLike)
      Gori::Update.parse_os_release("ID=\"debian\"\n").should eq(Gori::Update::OsFamily::DebianLike)
    end

    it "detects RHEL-like IDs" do
      Gori::Update.parse_os_release("ID=fedora\n").should eq(Gori::Update::OsFamily::RhelLike)
      Gori::Update.parse_os_release("ID=rocky\nID_LIKE=\"rhel centos fedora\"\n").should eq(Gori::Update::OsFamily::RhelLike)
    end
  end

  describe ".system_package_path?" do
    it "matches FHS system bins only" do
      Gori::Update.system_package_path?("/usr/bin/gori").should be_true
      Gori::Update.system_package_path?("/bin/gori").should be_true
      Gori::Update.system_package_path?("/usr/local/bin/gori").should be_false
      Gori::Update.system_package_path?("/home/u/.local/bin/gori").should be_false
    end
  end

  describe ".asset_name" do
    it "builds Linux plain-binary asset names" do
      Gori::Update.asset_name("0.17.0", "linux", "x86_64").should eq("gori-v0.17.0-linux-x86_64")
      Gori::Update.asset_name("v0.17.0", "linux", "arm64").should eq("gori-v0.17.0-linux-arm64")
      Gori::Update.asset_name("0.1.0", "linux", "amd64").should eq("gori-v0.1.0-linux-x86_64")
      Gori::Update.asset_name("0.1.0", "linux", "aarch64").should eq("gori-v0.1.0-linux-arm64")
    end

    it "builds macOS tarball asset names" do
      Gori::Update.asset_name("0.17.0", "osx", "arm64").should eq("gori-v0.17.0-osx-arm64.tar.gz")
      Gori::Update.asset_name("0.17.0", "darwin", "x86_64").should eq("gori-v0.17.0-osx-x86_64.tar.gz")
      Gori::Update.asset_name("v1.2.3", "macos", "aarch64").should eq("gori-v1.2.3-osx-arm64.tar.gz")
    end

    it "rejects unsupported OS" do
      expect_raises(Gori::Error, /unsupported OS/) do
        Gori::Update.asset_name("0.1.0", "windows", "x86_64")
      end
    end
  end

  describe ".version_cmp" do
    it "orders dotted versions and strips a single leading v" do
      Gori::Update.version_cmp("0.1.0", "0.1.0").should eq(0)
      Gori::Update.version_cmp("v0.1.0", "0.1.0").should eq(0)
      Gori::Update.version_cmp("0.1.0", "0.2.0").should eq(-1)
      Gori::Update.version_cmp("0.10.0", "0.9.0").should eq(1)
      Gori::Update.version_cmp("1.0.0", "0.9.9").should eq(1)
    end
  end

  describe "lib destination safety" do
    it "forbids shared system library roots" do
      Gori::Update.forbidden_lib_destination?("/usr/local/lib").should be_true
      Gori::Update.forbidden_lib_destination?("/usr/lib").should be_true
      Gori::Update.forbidden_lib_destination?("/opt/homebrew/lib").should be_true
    end

    it "forbids lib next to a bare /usr/local/bin binary" do
      Gori::Update.safe_lib_destination("/usr/local/bin/gori").should be_nil
      Gori::Update.supports_archive_lib_layout?("/usr/local/bin/gori").should be_false
    end

    it "allows dedicated opt/gori and workspace layouts" do
      Gori::Update.safe_lib_destination("/usr/local/opt/gori/gori").should eq("/usr/local/opt/gori/lib")
      Gori::Update.supports_archive_lib_layout?("/usr/local/opt/gori/gori").should be_true
      Gori::Update.safe_lib_destination("/Users/dev/Projects/gori/bin/gori").should eq("/Users/dev/Projects/gori/bin/lib")
    end
  end

  describe "tar entry safety" do
    it "flags absolute paths and parent segments" do
      Gori::Update.unsafe_tar_entry?("gori").should be_false
      Gori::Update.unsafe_tar_entry?("lib/foo.dylib").should be_false
      Gori::Update.unsafe_tar_entry?("/etc/passwd").should be_true
      Gori::Update.unsafe_tar_entry?("../evil").should be_true
      Gori::Update.unsafe_tar_entry?("lib/../../etc/passwd").should be_true
    end

    it "assert_safe_tar_listing raises on slip entries" do
      expect_raises(Gori::Error, /unsafe path/) do
        Gori::Update.assert_safe_tar_listing("gori\n../evil\n")
      end
    end
  end

  describe "release JSON resolution" do
    full_release = <<-JSON
      {
        "tag_name": "v0.17.0",
        "assets": [
          {
            "name": "gori-v0.17.0-linux-x86_64",
            "browser_download_url": "https://github.com/hahwul/gori/releases/download/v0.17.0/gori-v0.17.0-linux-x86_64",
            "size": 1000
          },
          {
            "name": "gori-v0.17.0-linux-arm64",
            "browser_download_url": "https://github.com/hahwul/gori/releases/download/v0.17.0/gori-v0.17.0-linux-arm64",
            "size": 1001
          },
          {
            "name": "gori-v0.17.0-osx-arm64.tar.gz",
            "browser_download_url": "https://github.com/hahwul/gori/releases/download/v0.17.0/gori-v0.17.0-osx-arm64.tar.gz",
            "size": 2000
          },
          {
            "name": "gori-v0.17.0-osx-x86_64.tar.gz",
            "browser_download_url": "https://github.com/hahwul/gori/releases/download/v0.17.0/gori-v0.17.0-osx-x86_64.tar.gz",
            "size": 2001
          }
        ]
      }
      JSON

    empty_assets = %({"tag_name":"v0.1.0","assets":[]})
    no_matching = <<-JSON
      {
        "tag_name": "v0.2.0",
        "assets": [
          {
            "name": "sbom.xml",
            "browser_download_url": "https://github.com/hahwul/gori/releases/download/v0.2.0/sbom.xml",
            "size": 10
          }
        ]
      }
      JSON

    it "parses release metadata and lists assets" do
      rel = Gori::Update.parse_release(full_release)
      rel.tag_name.should eq("v0.17.0")
      rel.version.should eq("0.17.0")
      rel.assets.size.should eq(4)
    end

    it "selects the platform asset URL from fixture JSON" do
      asset = Gori::Update.resolve_asset_from_json(full_release, "linux", "x86_64")
      asset.name.should eq("gori-v0.17.0-linux-x86_64")
      asset.browser_download_url.should eq(
        "https://github.com/hahwul/gori/releases/download/v0.17.0/gori-v0.17.0-linux-x86_64"
      )

      mac = Gori::Update.resolve_asset_from_json(full_release, "osx", "arm64")
      mac.name.should eq("gori-v0.17.0-osx-arm64.tar.gz")
      mac.browser_download_url.should contain("gori-v0.17.0-osx-arm64.tar.gz")
    end

    it "fails clearly when the release has no assets" do
      expect_raises(Gori::Error, /no downloadable assets/) do
        Gori::Update.resolve_asset_from_json(empty_assets, "linux", "x86_64")
      end
    end

    it "fails clearly when the platform asset is missing" do
      expect_raises(Gori::Error, /no matching asset.*gori-v0.2.0-linux-x86_64/) do
        Gori::Update.resolve_asset_from_json(no_matching, "linux", "x86_64")
      end
    end

    it "fails when tag_name is missing" do
      expect_raises(Gori::Error, /missing tag_name/) do
        Gori::Update.parse_release(%({"assets":[]}))
      end
    end
  end

  describe ".package_action" do
    it "returns brew upgrade guidance for Homebrew" do
      action = Gori::Update.package_action(Gori::Update::Channel::Homebrew)
      action[:command].should eq("brew upgrade gori")
      action[:message].should match(/Homebrew/i)
    end

    it "returns snap refresh guidance for Snap" do
      action = Gori::Update.package_action(Gori::Update::Channel::Snap)
      action[:command].should eq("snap refresh gori")
      action[:message].should match(/Snap/i)
    end

    it "returns pacman/AUR helper guidance without a single auto-run command" do
      action = Gori::Update.package_action(Gori::Update::Channel::Pacman)
      action[:command].should be_nil
      action[:message].should contain("yay -Syu gori")
      action[:message].should contain("paru -Syu gori")
    end

    it "returns apt guidance for deb and dnf/yum for rpm" do
      deb = Gori::Update.package_action(Gori::Update::Channel::Deb)
      deb[:command].should be_nil
      deb[:message].should match(/apt/i)

      rpm = Gori::Update.package_action(Gori::Update::Channel::Rpm)
      rpm[:command].should be_nil
      rpm[:message].should match(/dnf|yum|zypper/i)
    end

    it "describes standalone binary self-update" do
      action = Gori::Update.package_action(Gori::Update::Channel::Binary)
      action[:command].should be_nil
      action[:message].should match(/binary|GitHub release/i)
    end
  end

  describe ".run with injected path (package channels)" do
    it "prints Homebrew guidance and does not exec by default" do
      io = IO::Memory.new
      Gori::Update.run(io, io,
        exe_path: "/opt/homebrew/Cellar/gori/0.1.0/bin/gori")
      out = io.to_s
      out.should contain("install channel: homebrew")
      out.should contain("brew upgrade gori")
      out.should contain("--exec")
      out.should_not contain("Running:")
      out.should_not contain("no built-in self-update")
    end

    it "prints Snap guidance without executing snap when disabled" do
      io = IO::Memory.new
      Gori::Update.run(io, io,
        exe_path: "/snap/gori/current/bin/gori",
        exec_package_commands: false)
      out = io.to_s
      out.should contain("install channel: snap")
      out.should contain("snap refresh gori")
    end

    it "prints pacman guidance when ownership is pacman" do
      io = IO::Memory.new
      Gori::Update.run(io, io,
        exe_path: "/usr/bin/gori",
        owner: Gori::Update::OwnerResult::Pacman,
        os_family: Gori::Update::OsFamily::ArchLike)
      out = io.to_s
      out.should contain("install channel: pacman")
      out.should contain("yay -Syu gori")
    end

    it "prints apt guidance for dpkg-owned /usr/bin" do
      io = IO::Memory.new
      Gori::Update.run(io, io,
        exe_path: "/usr/bin/gori",
        owner: Gori::Update::OwnerResult::Dpkg,
        os_family: Gori::Update::OsFamily::DebianLike)
      out = io.to_s
      out.should contain("install channel: deb")
      out.should match(/apt/i)
    end

    it "self-updates when /usr/bin is not package-owned (manual install)" do
      io = IO::Memory.new
      empty = %({"tag_name":"v9.9.9","assets":[]})
      expect_raises(Gori::Error, /no downloadable assets|no matching asset|no GitHub releases/) do
        Gori::Update.run(io, io,
          exe_path: "/usr/bin/gori",
          owner: Gori::Update::OwnerResult::None,
          os_family: Gori::Update::OsFamily::DebianLike,
          release_json: empty)
      end
      io.to_s.should contain("install channel: binary")
    end

    it "on binary channel uses fixture JSON and reports missing assets clearly" do
      io = IO::Memory.new
      empty = %({"tag_name":"v9.9.9","assets":[]})
      expect_raises(Gori::Error, /no downloadable assets|no matching asset|no GitHub releases/) do
        Gori::Update.run(io, io,
          exe_path: "/usr/local/bin/gori",
          release_json: empty,
          exec_package_commands: false)
      end
      io.to_s.should contain("install channel: binary")
    end

    it "reports already up to date when release version matches VERSION" do
      io = IO::Memory.new
      json = %({"tag_name":"v#{Gori::VERSION}","assets":[{"name":"gori-v#{Gori::VERSION}-linux-x86_64","browser_download_url":"https://example.com/gori","size":1}]})
      Gori::Update.run(io, io,
        exe_path: "/tmp/fake-gori-bin",
        release_json: json,
        exec_package_commands: false)
      io.to_s.should match(/Already up to date/i)
    end

    it "refuses to download when local version is newer than the release" do
      io = IO::Memory.new
      # VERSION is 0.1.0 in shard; use an ancient remote tag
      # Simulate by injecting JSON with version 0.0.1 while local is higher — only works if VERSION > 0.0.1
      json = %({"tag_name":"v0.0.1","assets":[{"name":"gori-v0.0.1-linux-x86_64","browser_download_url":"https://example.com/gori","size":1}]})
      if Gori::Update.version_cmp(Gori::VERSION, "0.0.1") > 0
        Gori::Update.run(io, io,
          exe_path: "/usr/local/opt/gori/gori",
          release_json: json)
        io.to_s.should match(/not downgrading/i)
      end
    end
  end

  describe ".asset_is_archive?" do
    it "detects macOS tarballs vs plain Linux binaries" do
      Gori::Update.asset_is_archive?("gori-v0.1.0-osx-arm64.tar.gz").should be_true
      Gori::Update.asset_is_archive?("gori-v0.1.0-linux-x86_64").should be_false
    end
  end

  describe ".install_from_download (plain binary)" do
    it "replaces the target path with the downloaded file via the shipped installer" do
      dir = File.tempname("gori-inst-")
      Dir.mkdir_p(dir)
      begin
        source = File.join(dir, "new-gori")
        target = File.join(dir, "gori")
        File.write(source, "#!/bin/sh\necho new-build\n")
        File.write(target, "#!/bin/sh\necho old-build\n")
        File.chmod(source, 0o755)
        File.chmod(target, 0o755)

        Gori::Update.install_from_download(source, target, false)

        File.read(target).should contain("new-build")
        File::Info.executable?(target).should be_true
      ensure
        FileUtils.rm_rf(dir) if File.exists?(dir)
      end
    end
  end

  describe ".install_from_download (macOS-style tarball + lib/)" do
    it "extracts gori and refreshes sibling lib/ next to the target in a dedicated dir" do
      root = File.tempname("gori-tar-")
      Dir.mkdir_p(root)
      begin
        stage = File.join(root, "stage")
        Dir.mkdir_p(File.join(stage, "lib"))
        File.write(File.join(stage, "gori"), "#!/bin/sh\necho from-tar\n")
        File.chmod(File.join(stage, "gori"), 0o755)
        File.write(File.join(stage, "lib", "libexample.dylib"), "dylib-bytes")

        archive = File.join(root, "gori-v0.0.0-osx-arm64.tar.gz")
        status = Process.run("tar", ["czf", archive, "-C", stage, "gori", "lib"],
          output: Process::Redirect::Close, error: Process::Redirect::Close)
        status.success?.should be_true

        target_dir = File.join(root, "opt", "gori")
        Dir.mkdir_p(target_dir)
        target = File.join(target_dir, "gori")
        File.write(target, "old")
        File.chmod(target, 0o755)

        Gori::Update.install_from_download(archive, target, true)

        File.read(target).should contain("from-tar")
        File.read(File.join(target_dir, "lib", "libexample.dylib")).should eq("dylib-bytes")
      ensure
        FileUtils.rm_rf(root) if File.exists?(root)
      end
    end

    it "refuses archive install when lib/ would land on a shared system path" do
      root = File.tempname("gori-unsafe-")
      Dir.mkdir_p(root)
      begin
        stage = File.join(root, "stage")
        Dir.mkdir_p(File.join(stage, "lib"))
        File.write(File.join(stage, "gori"), "bin\n")
        File.chmod(File.join(stage, "gori"), 0o755)
        File.write(File.join(stage, "lib", "x.dylib"), "x")
        archive = File.join(root, "a.tar.gz")
        Process.run("tar", ["czf", archive, "-C", stage, "gori", "lib"],
          output: Process::Redirect::Close, error: Process::Redirect::Close)

        expect_raises(Gori::Error, /refuses this install layout|shared library/) do
          # Simulate a bare /usr/local/bin layout without touching the real filesystem:
          # use install_from_download's layout check with that path string — it validates
          # before extract mutates anything under the real /usr/local.
          Gori::Update.install_from_download(archive, "/usr/local/bin/gori", true)
        end
      ensure
        FileUtils.rm_rf(root) if File.exists?(root)
      end
    end
  end
end
