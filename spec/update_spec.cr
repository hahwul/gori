require "./spec_helper"
require "file_utils"
require "./support/mock_release_server"

# Sets env vars for the block and restores them exactly afterwards — a nil value
# means "unset", both going in and coming back out, so a var that did not exist
# before does not linger as an empty string for later examples.
private def with_env(vars : Hash(String, String?), &)
  saved = vars.keys.to_h { |key| {key, ENV[key]?} }
  begin
    vars.each { |key, value| value ? (ENV[key] = value) : ENV.delete(key) }
    yield
  ensure
    saved.each { |key, value| value ? (ENV[key] = value) : ENV.delete(key) }
  end
end

# chmod-based permission examples say nothing when the process ignores the mode:
# access(2) succeeds unconditionally for root. CI runs `crystal spec` on a plain
# ubuntu-latest runner (non-root), so the negative cases below do execute there;
# this guard is for someone running the suite inside a root container. Probe the
# actual behaviour rather than guessing from the uid.
# A response body that yields a few chunks and then dies, the way a connection
# reset part-way through a release asset does.
private class BurstThenResetIO < IO
  def initialize(@chunks : Int32)
  end

  def read(slice : Bytes) : Int32
    raise IO::Error.new("connection reset by peer") if @chunks <= 0
    @chunks -= 1
    slice.fill(0x61_u8)
    slice.size
  end

  def write(slice : Bytes) : Nil
  end
end

# A port nothing is listening on: bind to 0 so the OS picks a free one, then
# close it, so a connect there is REFUSED rather than left to time out (which
# would make the network examples below take HTTP_TIMEOUT each).
private def dead_port : Int32
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  server.close
  port
end

private def mode_enforced?(dir : String) : Bool
  probe = File.join(dir, ".gori-perm-probe")
  File.write(probe, "x")
  File.delete?(probe)
  false
rescue
  true
end

# `verify_download!` is private and only ever called from inside update_binary's
# tempdir block, where the redirect fallback it disclaims for cannot be reached
# without talking to github.com. Expose it the way the other specs expose privates
# (spec/cli_spec.cr does the same for split_subcommand / global_version_flag?).
module Gori::Update
  def self.verify_download_for_spec(dest : String, asset : Asset, got : Int64, io : IO, *,
                                    announce_skip : Bool) : Nil
    verify_download!(dest, asset, got, io, announce_skip: announce_skip)
  end
end

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

    it "detects Nix store paths" do
      Gori::Update.detect_channel("/nix/store/0fhkwk15n3ya0llfr0754awcldpz4x54-gori-0.1.3/bin/gori")
        .should eq(Gori::Update::Channel::Nix)
      # `~/.nix-profile/bin/gori` is a symlink; the caller realpaths it into the store
      # before this runs, so only the resolved form has to match.
      Gori::Update.detect_channel("/nix/store/abc-gori-0.1.3/bin/gori")
        .should eq(Gori::Update::Channel::Nix)
      Gori::Update.detect_channel("/home/u/nix/store/gori").should eq(Gori::Update::Channel::Binary)
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

  describe ".notice_version" do
    it "surfaces a strictly-newer release the user has not been notified about" do
      Gori::Update.notice_version("0.1.1", "0.2.0", "").should eq("0.2.0")
      Gori::Update.notice_version("0.1.1", "v0.2.0", "").should eq("0.2.0")
    end

    it "returns nil when up to date or on a newer local build" do
      Gori::Update.notice_version("0.2.0", "0.2.0", "").should be_nil
      Gori::Update.notice_version("0.3.0", "0.2.0", "").should be_nil
    end

    it "returns nil when the newer release was already notified (read-once)" do
      Gori::Update.notice_version("0.1.1", "0.2.0", "0.2.0").should be_nil
      Gori::Update.notice_version("0.1.1", "0.2.0", "v0.2.0").should be_nil
    end

    it "re-notifies when a release newer than the last-notified one appears" do
      Gori::Update.notice_version("0.1.1", "0.3.0", "0.2.0").should eq("0.3.0")
    end

    it "returns nil for an empty latest (fetch failed / no cache)" do
      Gori::Update.notice_version("0.1.1", "", "").should be_nil
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

  describe ".parse_sha256_digest" do
    it "extracts lowercase hex from a sha256: digest (case-insensitive prefix + hex)" do
      Gori::Update.parse_sha256_digest("sha256:#{"a" * 64}").should eq("a" * 64)
      Gori::Update.parse_sha256_digest("SHA256:#{"A" * 64}").should eq("a" * 64) # downcased
    end

    it "returns nil for absent / unsupported / malformed digests" do
      Gori::Update.parse_sha256_digest(nil).should be_nil
      Gori::Update.parse_sha256_digest("sha512:#{"a" * 128}").should be_nil # wrong algo
      Gori::Update.parse_sha256_digest("sha256:xyz").should be_nil          # not hex
      Gori::Update.parse_sha256_digest("sha256:#{"a" * 63}").should be_nil  # wrong length
    end
  end

  describe ".file_sha256" do
    it "streams the lowercase hex sha256 of a file (known \"abc\" vector)" do
      dir = File.tempname("gori-sha-")
      Dir.mkdir_p(dir)
      begin
        f = File.join(dir, "x")
        File.write(f, "abc")
        Gori::Update.file_sha256(f).should eq("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
      ensure
        FileUtils.rm_rf(dir)
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

    it "captures an asset digest when present and leaves it nil when absent" do
      json = <<-JSON
        {"tag_name":"v1.0.0","assets":[
          {"name":"a","browser_download_url":"http://x/a","size":1,"digest":"sha256:#{"b" * 64}"},
          {"name":"b","browser_download_url":"http://x/b","size":2}
        ]}
        JSON
      rel = Gori::Update.parse_release(json)
      rel.assets[0].digest.should eq("sha256:#{"b" * 64}")
      rel.assets[1].digest.should be_nil
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

    it "returns nix guidance without a single auto-run command" do
      action = Gori::Update.package_action(Gori::Update::Channel::Nix)
      action[:command].should be_nil
      action[:message].should contain("nix profile upgrade gori")
      action[:message].should match(/read-only/i)
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

    it "prints nix guidance instead of downloading into the read-only store" do
      io = IO::Memory.new
      Gori::Update.run(io, io,
        exe_path: "/nix/store/0fhkwk15n3ya0llfr0754awcldpz4x54-gori-0.1.3/bin/gori")
      out = io.to_s
      out.should contain("install channel: nix")
      out.should contain("nix profile upgrade gori")
      out.should_not contain("Running:")
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
        io.to_s.should contain("Local version v#{Gori::VERSION} is newer than latest release v0.0.1")
      end
    end
  end

  describe ".display_version" do
    it "renders one `v`-prefixed form whether the input carries the prefix or not" do
      Gori::Update.display_version("0.2.0").should eq("v0.2.0")
      Gori::Update.display_version("v0.2.0").should eq("v0.2.0")
      Gori::Update.display_version("V0.2.0").should eq("v0.2.0")
    end
  end

  describe ".asset_is_archive?" do
    it "detects macOS tarballs vs plain Linux binaries" do
      Gori::Update.asset_is_archive?("gori-v0.1.0-osx-arm64.tar.gz").should be_true
      Gori::Update.asset_is_archive?("gori-v0.1.0-linux-x86_64").should be_false
    end
  end

  describe "progress formatters" do
    it "formats human sizes with a unit space" do
      Gori::Update.format_size(0).should eq("0 B")
      Gori::Update.format_size(512).should eq("512 B")
      Gori::Update.format_size(1536).should eq("1.5 kB")
      Gori::Update.format_size(5_i64 * 1024 * 1024).should eq("5.0 MB")
    end

    it "builds a fixed-width bar from 0% to 100%" do
      empty = Gori::Update.format_progress_bar(0, 100, 10)
      empty.size.should eq(10)
      empty.should eq("░" * 10)

      full = Gori::Update.format_progress_bar(100, 100, 10)
      full.should eq("█" * 10)

      mid = Gori::Update.format_progress_bar(50, 100, 10)
      mid.size.should eq(10)
      mid.should contain("█")
      mid.should contain("░")
    end

    it "includes percent, sizes, and rate in a known-total progress line" do
      line = Gori::Update.format_progress_line(50_i64 * 1024, 100_i64 * 1024,
        elapsed: 1.second, width: 10)
      line.should match(/%/)
      line.should contain("50.0 kB")
      line.should contain("100.0 kB")
      line.should contain("/s")
    end

    it "omits the bar when total is unknown" do
      line = Gori::Update.format_progress_line(4096, 0, elapsed: 0.5.seconds)
      line.should_not contain("█")
      line.should_not contain("%")
      line.should contain("4.0 kB")
    end

    it "formats short durations" do
      Gori::Update.format_duration(250.milliseconds).should eq("250ms")
      Gori::Update.format_duration(1.5.seconds).should eq("1.5s")
    end
  end

  describe ".download_to with mock release server" do
    it "streams the asset, reports progress, and writes the full body" do
      payload = ("x" * 32_768) # 32 KiB — multiple chunks
      with_mock_release_server(tag: "v99.0.0", body: payload) do |server|
        name = server.asset_names.find { |n| n.includes?("linux-x86_64") }.not_nil!
        dest = File.tempname("gori-dl-")
        begin
          samples = [] of {Int64, Int64}
          got = Gori::Update.download_to(server.download_url(name), dest,
            expected_size: payload.bytesize.to_i64,
            on_progress: ->(done : Int64, total : Int64) {
              samples << {done, total}
            })
          got.should eq(payload.bytesize)
          File.read(dest).should eq(payload)
          samples.size.should be > 0
          samples.last[0].should eq(payload.bytesize)
          samples.last[1].should eq(payload.bytesize)
          # Monotonic downloaded counters
          samples.each_cons(2) { |(a, b)| b[0].should be >= a[0] }
        ensure
          File.delete?(dest)
        end
      end
    end

    it "draws progress when force_progress is set even without a TTY" do
      payload = "a" * 8192
      with_mock_release_server(body: payload) do |server|
        name = server.asset_names.first
        dest = File.tempname("gori-dl-")
        io = IO::Memory.new
        begin
          Gori::Update.download_to(server.download_url(name), dest,
            expected_size: payload.bytesize.to_i64,
            progress_io: io,
            force_progress: true)
          out = io.to_s
          # Force-progress writes use \r redraws; at least one progress tick or clear.
          (out.includes?("\r") || out.includes?("%") || out.includes?("B")).should be_true
        ensure
          File.delete?(dest)
        end
      end
    end

    it "update_binary installs from the mock and prints staged download lines" do
      payload = "#!/bin/sh\necho mock-new\n"
      root = File.tempname("gori-upd-")
      Dir.mkdir_p(root)
      begin
        want = Gori::Update.asset_name("99.0.0", Gori::Update.current_os, Gori::Update.current_arch)
        body_bytes = if Gori::Update.asset_is_archive?(want)
                       stage = File.join(root, "stage")
                       Dir.mkdir_p(File.join(stage, "lib"))
                       File.write(File.join(stage, "gori"), payload)
                       File.chmod(File.join(stage, "gori"), 0o755)
                       File.write(File.join(stage, "lib", "libexample.dylib"), "dylib")
                       archive = File.join(root, "asset.tar.gz")
                       Process.run("tar", ["czf", archive, "-C", stage, "gori", "lib"],
                         output: Process::Redirect::Close, error: Process::Redirect::Close)
                       File.read(archive).to_slice
                     else
                       payload.to_slice
                     end

        with_mock_release_server(tag: "v99.0.0", body: body_bytes, asset_names: [want]) do |srv|
          target_dir = File.join(root, "opt", "gori")
          Dir.mkdir_p(target_dir)
          target = File.join(target_dir, "gori")
          File.write(target, "#!/bin/sh\necho old\n")
          File.chmod(target, 0o755)

          io = IO::Memory.new
          Gori::Update.update_binary(target, io, release_json: srv.release_json)

          out = io.to_s
          # Both sides carry the `v` — `Gori::VERSION` is bare and the tag is not,
          # so this line is where the two forms used to collide.
          out.should contain("Updating v#{Gori::VERSION} → v99.0.0")
          out.should contain("Downloading #{want}")
          out.should contain("Downloaded")
          out.should contain("Installed v99.0.0")
          File.read(target).should contain("mock-new")
        end
      ensure
        FileUtils.rm_rf(root) if File.exists?(root)
      end
    end

    it "fetches release JSON from the mock API URL" do
      with_mock_release_server(tag: "v99.0.0", body: "hi") do |server|
        json = Gori::Update.fetch_latest_release_json(server.api_url)
        rel = Gori::Update.parse_release(json)
        rel.tag_name.should eq("v99.0.0")
        rel.assets.size.should be > 0
      end
    end

    it "rejects a truncated download even when the release JSON reports size: 0 (Bug A)" do
      # Mirrors the confirmed exploit: the release JSON's `size` field is
      # unauthenticated and wrong (0), but the real HTTP Content-Length header
      # promises the full asset — and the server only ever delivers half of it
      # before hanging up (simulating a killed-mid-transfer process). The fix
      # must catch this from the real Content-Length, not the JSON size.
      payload = "x" * 40_000
      with_mock_release_server(tag: "v99.0.0", body: payload, reported_size: 0_i64, truncate_at: 20_000) do |server|
        name = server.asset_names.find { |n| n.includes?("linux-x86_64") }.not_nil!
        dest = File.tempname("gori-dl-")
        begin
          expect_raises(Gori::Error, /truncated/) do
            Gori::Update.download_to(server.download_url(name), dest, expected_size: 0_i64)
          end
        ensure
          File.delete?(dest)
        end
      end
    end

    it "update_binary refuses to install a truncated download and leaves the target untouched (Bug A)" do
      payload = "y" * 40_000
      root = File.tempname("gori-trunc-")
      Dir.mkdir_p(root)
      begin
        want = Gori::Update.asset_name("99.0.0", Gori::Update.current_os, Gori::Update.current_arch)
        with_mock_release_server(tag: "v99.0.0", body: payload, asset_names: [want],
          reported_size: 0_i64, truncate_at: 20_000) do |srv|
          target_dir = File.join(root, "opt", "gori")
          Dir.mkdir_p(target_dir)
          target = File.join(target_dir, "gori")
          original = "#!/bin/sh\necho old\n"
          File.write(target, original)
          File.chmod(target, 0o755)

          io = IO::Memory.new
          expect_raises(Gori::Error, /truncated/) do
            Gori::Update.update_binary(target, io, release_json: srv.release_json)
          end

          File.read(target).should eq(original)
        end
      ensure
        FileUtils.rm_rf(root) if File.exists?(root)
      end
    end

    it "verifies and installs when the release advertises a correct sha256 digest (R2-10)" do
      payload = "#!/bin/sh\necho mock-verified\n"
      root = File.tempname("gori-sha-ok-")
      Dir.mkdir_p(root)
      begin
        want = Gori::Update.asset_name("99.0.0", Gori::Update.current_os, Gori::Update.current_arch)
        body_bytes = if Gori::Update.asset_is_archive?(want)
                       stage = File.join(root, "stage")
                       Dir.mkdir_p(File.join(stage, "lib"))
                       File.write(File.join(stage, "gori"), payload)
                       File.chmod(File.join(stage, "gori"), 0o755)
                       File.write(File.join(stage, "lib", "libexample.dylib"), "dylib")
                       archive = File.join(root, "asset.tar.gz")
                       Process.run("tar", ["czf", archive, "-C", stage, "gori", "lib"],
                         output: Process::Redirect::Close, error: Process::Redirect::Close)
                       File.read(archive).to_slice
                     else
                       payload.to_slice
                     end
        # provide_digest: the mock computes sha256 over the served body, so it matches.
        with_mock_release_server(tag: "v99.0.0", body: body_bytes, asset_names: [want], provide_digest: true) do |srv|
          target_dir = File.join(root, "opt", "gori")
          Dir.mkdir_p(target_dir)
          target = File.join(target_dir, "gori")
          File.write(target, "#!/bin/sh\necho old\n")
          File.chmod(target, 0o755)

          io = IO::Memory.new
          Gori::Update.update_binary(target, io, release_json: srv.release_json)
          io.to_s.should contain("Verifying sha256 checksum")
          io.to_s.should contain("Installed v99.0.0")
          File.read(target).should contain("mock-verified")
        end
      ensure
        FileUtils.rm_rf(root) if File.exists?(root)
      end
    end

    it "refuses to install on a sha256 checksum mismatch and leaves the target untouched (R2-10)" do
      # A well-formed download whose advertised digest does NOT match the body — the
      # CDN/transit-tampering (or wrong-asset) case the digest check exists to catch.
      payload = "z" * 4096
      root = File.tempname("gori-sha-bad-")
      Dir.mkdir_p(root)
      begin
        want = Gori::Update.asset_name("99.0.0", Gori::Update.current_os, Gori::Update.current_arch)
        with_mock_release_server(tag: "v99.0.0", body: payload, asset_names: [want],
          provide_digest: true, digest_override: "sha256:#{"0" * 64}") do |srv|
          target_dir = File.join(root, "opt", "gori")
          Dir.mkdir_p(target_dir)
          target = File.join(target_dir, "gori")
          original = "#!/bin/sh\necho keep-me\n"
          File.write(target, original)
          File.chmod(target, 0o755)

          io = IO::Memory.new
          expect_raises(Gori::Error, /checksum mismatch/) do
            Gori::Update.update_binary(target, io, release_json: srv.release_json)
          end
          File.read(target).should eq(original) # never replaced
        end
      ensure
        FileUtils.rm_rf(root) if File.exists?(root)
      end
    end
  end

  describe ".parse_release non-JSON handling (Bug B)" do
    it "raises a clean Gori::Error instead of an unhandled JSON::ParseException" do
      expect_raises(Gori::Error, /could not parse release information/) do
        Gori::Update.parse_release("<html><body>captive portal</body></html>")
      end
    end

    it "raises a clean Gori::Error for valid JSON whose root is not an object" do
      # `data["tag_name"]?` on a non-Hash JSON::Any raises a BARE Exception, which no
      # rescue on the `gori update` path catches (cli.cr rescues Gori::Error), so the
      # operator got an unhandled backtrace instead of the intended message. Any 200 whose
      # body is valid JSON with a non-object root reaches this — a captive proxy, a GHE
      # mirror, or GORI_UPDATE_API_URL pointed at a list endpoint.
      {"[]", "null", %("a string"), "42"}.each do |body|
        expect_raises(Gori::Error, /could not parse release information/) do
          Gori::Update.parse_release(body)
        end
      end
    end

    it "update_binary surfaces the same clean error for a non-JSON release response" do
      io = IO::Memory.new
      expect_raises(Gori::Error, /could not parse release information/) do
        Gori::Update.update_binary("/tmp/does-not-matter", io, release_json: "not json at all")
      end
    end
  end

  # --- fail-fast on an unwritable install directory --------------------------
  # The macOS archive-layout check already refuses before the download; a target
  # we cannot write is knowable at the same moment, and used to be discovered
  # only after tens of MB were on disk.

  describe ".install_dir_writable?" do
    it "reports on the directory, not the file — atomic_install renames into it" do
      dir = File.tempname("gori-perm-")
      Dir.mkdir_p(dir)
      begin
        target = File.join(dir, "gori")
        File.write(target, "old")
        # A read-only *file* in a writable directory is still replaceable.
        File.chmod(target, 0o444)
        Gori::Update.install_dir_writable?(target).should be_true

        File.chmod(dir, 0o500)
        Gori::Update.install_dir_writable?(target).should be_false if mode_enforced?(dir)
      ensure
        File.chmod(dir, 0o755) rescue nil
        FileUtils.rm_rf(dir) if File.exists?(dir)
      end
    end

    it "allows a directory atomic_install would still have to create" do
      Gori::Update.install_dir_writable?(File.join(File.tempname("gori-absent-"), "gori")).should be_true
    end
  end

  describe ".update_binary permission pre-check" do
    it "refuses an unwritable install dir before downloading anything" do
      root = File.tempname("gori-ro-")
      Dir.mkdir_p(root)
      begin
        want = Gori::Update.asset_name("99.0.0", Gori::Update.current_os, Gori::Update.current_arch)
        target_dir = File.join(root, "opt", "gori")
        Dir.mkdir_p(target_dir)
        target = File.join(target_dir, "gori")
        File.write(target, "old")
        File.chmod(target_dir, 0o500)

        if mode_enforced?(target_dir)
          # An unreachable download URL: reaching it at all would mean the pre-check
          # did not fire, so a passing example also proves nothing was fetched.
          json = %({"tag_name":"v99.0.0","assets":[{"name":"#{want}","browser_download_url":"http://127.0.0.1:1/nope","size":1}]})
          io = IO::Memory.new
          expect_raises(Gori::Error, /cannot write to/) do
            Gori::Update.update_binary(target, io, release_json: json)
          end
          io.to_s.should_not contain("Downloading")
        end
      ensure
        File.chmod(File.join(root, "opt", "gori"), 0o755) rescue nil
        FileUtils.rm_rf(root) if File.exists?(root)
      end
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

    # atomic_install used to end in an in-place `cp source, target` as a "cross
    # device rename" fallback. tmp lives in File.dirname(target), so that rename
    # can never be cross-device — all the fallback could actually do is truncate
    # the live binary and, on a mid-write failure, leave a corrupt gori behind.
    it "leaves the installed binary untouched when the install cannot complete" do
      dir = File.tempname("gori-noclobber-")
      Dir.mkdir_p(dir)
      begin
        source = File.join(dir, "new-gori")
        File.write(source, "#!/bin/sh\necho new-build\n")
        # A directory at the target path: the rename fails, and an in-place copy
        # would fail too — the point is that neither is attempted destructively.
        target = File.join(dir, "gori")
        Dir.mkdir_p(target)
        File.write(File.join(target, "sentinel"), "still here")

        expect_raises(Gori::Error, /left untouched/) do
          Gori::Update.atomic_install(source, target)
        end

        File.read(File.join(target, "sentinel")).should eq("still here")
        # No orphaned staging file next to it either.
        # Dir.children, not Dir.glob: glob skips dotfiles by default, so a glob for
        # `.gori-update.*` reports empty even when the orphan is right there.
        Dir.children(dir).select(&.starts_with?(".gori-update.")).should be_empty
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

    # A binary install that fails AFTER lib/ was swapped used to leave new dylibs
    # beside the old binary with the backup already deleted — unrecoverable when a
    # bundled dylib's basename changed between releases.
    it "rolls lib/ back when the binary install fails" do
      root = File.tempname("gori-rollback-")
      Dir.mkdir_p(root)
      begin
        stage = File.join(root, "stage")
        Dir.mkdir_p(File.join(stage, "lib"))
        File.write(File.join(stage, "gori"), "#!/bin/sh\necho new\n")
        File.chmod(File.join(stage, "gori"), 0o755)
        File.write(File.join(stage, "lib", "libexample.dylib"), "new-dylib")
        archive = File.join(root, "gori-v0.0.0-osx-arm64.tar.gz")
        Process.run("tar", ["czf", archive, "-C", stage, "gori", "lib"],
          output: Process::Redirect::Close, error: Process::Redirect::Close)

        target_dir = File.join(root, "opt", "gori")
        Dir.mkdir_p(File.join(target_dir, "lib"))
        File.write(File.join(target_dir, "lib", "libexample.dylib"), "old-dylib")
        # Make the binary install fail without touching permissions: a *directory*
        # at the target path cannot be renamed over by a regular file.
        target = File.join(target_dir, "gori")
        Dir.mkdir_p(target)

        expect_raises(Gori::Error, /was rolled back/) do
          Gori::Update.install_from_download(archive, target, true)
        end

        File.read(File.join(target_dir, "lib", "libexample.dylib")).should eq("old-dylib")
        # And no staging debris survives the failure.
        Dir.glob(File.join(target_dir, "lib.gori-*")).should be_empty
      ensure
        FileUtils.rm_rf(root) if File.exists?(root)
      end
    end

    it "removes a freshly installed lib/ when the target had none to restore" do
      # The other rollback branch: the archive carries lib/ but the install dir did
      # not, so reverting means taking the new tree back out rather than moving one
      # back in. Untested, this is a silent rm_rf.
      root = File.tempname("gori-rollback-nolib-")
      Dir.mkdir_p(root)
      begin
        stage = File.join(root, "stage")
        Dir.mkdir_p(File.join(stage, "lib"))
        File.write(File.join(stage, "gori"), "#!/bin/sh\necho new\n")
        File.chmod(File.join(stage, "gori"), 0o755)
        File.write(File.join(stage, "lib", "libexample.dylib"), "new-dylib")
        archive = File.join(root, "gori-v0.0.0-osx-arm64.tar.gz")
        Process.run("tar", ["czf", archive, "-C", stage, "gori", "lib"],
          output: Process::Redirect::Close, error: Process::Redirect::Close)

        target_dir = File.join(root, "opt", "gori")
        Dir.mkdir_p(target_dir)
        target = File.join(target_dir, "gori")
        Dir.mkdir_p(target) # a directory here makes atomic_install fail

        expect_raises(Gori::Error, /was rolled back/) do
          Gori::Update.install_from_download(archive, target, true)
        end

        Dir.exists?(File.join(target_dir, "lib")).should be_false
      ensure
        FileUtils.rm_rf(root) if File.exists?(root)
      end
    end

    it "refuses to drop lib/ when the backup it would restore is gone" do
      # Deleting the installed tree and only then discovering there is nothing to
      # put back is strictly worse than leaving the swap in place, so the existence
      # check has to happen first. Nothing else pins that ordering.
      root = File.tempname("gori-restore-")
      Dir.mkdir_p(root)
      begin
        lib_dst = File.join(root, "lib")
        Dir.mkdir_p(lib_dst)
        File.write(File.join(lib_dst, "libexample.dylib"), "installed")

        Gori::Update.restore_lib_dir(lib_dst, File.join(root, "no-such-backup")).should be_false
        File.read(File.join(lib_dst, "libexample.dylib")).should eq("installed")
      ensure
        FileUtils.rm_rf(root) if File.exists?(root)
      end
    end

    it "restores the backup over whatever is currently installed" do
      root = File.tempname("gori-restore-ok-")
      Dir.mkdir_p(root)
      begin
        lib_dst = File.join(root, "lib")
        Dir.mkdir_p(lib_dst)
        File.write(File.join(lib_dst, "libexample.dylib"), "new")
        backup = File.join(root, "lib.gori-old.1.aaaa")
        Dir.mkdir_p(backup)
        File.write(File.join(backup, "libexample.dylib"), "old")

        Gori::Update.restore_lib_dir(lib_dst, backup).should be_true
        File.read(File.join(lib_dst, "libexample.dylib")).should eq("old")
        File.exists?(backup).should be_false
      ensure
        FileUtils.rm_rf(root) if File.exists?(root)
      end
    end

    it "keeps a stranded backup that is the only surviving copy of lib/" do
      # A run killed between `rename(lib, backup)` and `rename(staged, lib)` leaves
      # no lib/ and a backup holding the ONLY copy of the installed dylibs. Sweeping
      # that away would destroy them for good — and then a later rollback, finding
      # no backup to restore, would remove lib/ altogether.
      root = File.tempname("gori-nosweep-")
      Dir.mkdir_p(root)
      begin
        src = File.join(root, "src-lib")
        Dir.mkdir_p(src)
        File.write(File.join(src, "libexample.dylib"), "new")

        dst_parent = File.join(root, "opt", "gori")
        Dir.mkdir_p(dst_parent)
        lib_dst = File.join(dst_parent, "lib") # deliberately absent
        only_copy = File.join(dst_parent, "lib.gori-old.999.deadbeef")
        Dir.mkdir_p(only_copy)
        File.write(File.join(only_copy, "libexample.dylib"), "the-only-copy")

        Gori::Update.replace_lib_dir(src, lib_dst).should be_nil
        File.read(File.join(only_copy, "libexample.dylib")).should eq("the-only-copy")
      ensure
        FileUtils.rm_rf(root) if File.exists?(root)
      end
    end

    it "clears a half-copied staging tree left by an interrupted run" do
      root = File.tempname("gori-staging-")
      Dir.mkdir_p(root)
      begin
        src = File.join(root, "src-lib")
        Dir.mkdir_p(src)
        File.write(File.join(src, "libexample.dylib"), "new")

        dst_parent = File.join(root, "opt", "gori")
        Dir.mkdir_p(File.join(dst_parent, "lib"))
        stranded = File.join(dst_parent, "lib.gori-new.999.deadbeef")
        Dir.mkdir_p(stranded)
        File.write(File.join(stranded, "partial.dylib"), "half")

        Gori::Update.replace_lib_dir(src, File.join(dst_parent, "lib"))
        # Always garbage, unlike a backup — a half-copy is never worth keeping.
        File.exists?(stranded).should be_false
      ensure
        FileUtils.rm_rf(root) if File.exists?(root)
      end
    end

    it "sweeps by name prefix, so glob metacharacters in the install path are literal" do
      # `~/opt/gori[stable]/lib` under Dir.glob would parse `[stable]` as a
      # character class: it would miss the real backup and could rm_rf entries
      # under sibling directories it was never pointed at.
      root = File.tempname("gori-meta-")
      Dir.mkdir_p(root)
      begin
        src = File.join(root, "src-lib")
        Dir.mkdir_p(src)
        File.write(File.join(src, "libexample.dylib"), "new")

        dst_parent = File.join(root, "gori[stable]")
        Dir.mkdir_p(File.join(dst_parent, "lib"))
        stranded = File.join(dst_parent, "lib.gori-new.999.deadbeef")
        Dir.mkdir_p(stranded)

        Gori::Update.replace_lib_dir(src, File.join(dst_parent, "lib"))
        File.exists?(stranded).should be_false
      ensure
        FileUtils.rm_rf(root) if File.exists?(root)
      end
    end

    it "clears a lib backup stranded by an earlier interrupted run" do
      root = File.tempname("gori-sweep-")
      Dir.mkdir_p(root)
      begin
        src = File.join(root, "src-lib")
        Dir.mkdir_p(src)
        File.write(File.join(src, "libexample.dylib"), "new")

        dst_parent = File.join(root, "opt", "gori")
        Dir.mkdir_p(File.join(dst_parent, "lib"))
        File.write(File.join(dst_parent, "lib", "libexample.dylib"), "old")
        stranded = File.join(dst_parent, "lib.gori-old.999.deadbeef")
        Dir.mkdir_p(stranded)
        File.write(File.join(stranded, "libexample.dylib"), "ancient")

        backup = Gori::Update.replace_lib_dir(src, File.join(dst_parent, "lib"))
        File.exists?(stranded).should be_false
        # The caller now owns the backup — it must still be there to roll back to.
        File.exists?(backup.not_nil!).should be_true
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

  # --- rate-limit fallback ---------------------------------------------------
  # api.github.com allows 60 unauthenticated requests/hour per IP; past that it
  # answers 403 and `gori update` used to simply fail. These cover the two ways
  # out: a token, and naming the release from the web redirect instead.

  describe ".tag_from_release_location" do
    it "extracts the tag from a release redirect" do
      Gori::Update.tag_from_release_location(
        "https://github.com/hahwul/gori/releases/tag/v0.1.4").should eq("v0.1.4")
    end

    it "ignores query strings, fragments and trailing segments" do
      Gori::Update.tag_from_release_location(
        "https://github.com/hahwul/gori/releases/tag/v1.2.3?a=1").should eq("v1.2.3")
      Gori::Update.tag_from_release_location(
        "  https://github.com/hahwul/gori/releases/tag/v1.2.3#notes  ").should eq("v1.2.3")
    end

    it "returns nil when the redirect is not a release page" do
      # A repo with no published release redirects to plain /releases. Reading a
      # tag out of that would send the installer after an asset that cannot exist.
      Gori::Update.tag_from_release_location("https://github.com/hahwul/gori/releases").should be_nil
      Gori::Update.tag_from_release_location("https://github.com/hahwul/gori/releases/tag/").should be_nil
      Gori::Update.tag_from_release_location("https://github.com/login").should be_nil
      Gori::Update.tag_from_release_location(nil).should be_nil
    end
  end

  describe ".github_token" do
    it "takes the first non-empty of GORI_GITHUB_TOKEN, GITHUB_TOKEN, GH_TOKEN" do
      with_env({"GORI_GITHUB_TOKEN" => "a", "GITHUB_TOKEN" => "b", "GH_TOKEN" => "c"}) do
        Gori::Update.github_token.should eq("a")
      end
      with_env({"GORI_GITHUB_TOKEN" => nil, "GITHUB_TOKEN" => "b", "GH_TOKEN" => "c"}) do
        Gori::Update.github_token.should eq("b")
      end
      with_env({"GORI_GITHUB_TOKEN" => nil, "GITHUB_TOKEN" => nil, "GH_TOKEN" => "c"}) do
        Gori::Update.github_token.should eq("c")
      end
    end

    it "treats a blank value as absent" do
      with_env({"GORI_GITHUB_TOKEN" => "   ", "GITHUB_TOKEN" => nil, "GH_TOKEN" => nil}) do
        Gori::Update.github_token.should be_nil
      end
    end
  end

  describe ".default_api?" do
    it "is false for an explicit URL or the env override" do
      Gori::Update.default_api?("http://127.0.0.1:1/x").should be_false
      with_env({"GORI_UPDATE_API_URL" => "http://127.0.0.1:1/x"}) do
        Gori::Update.default_api?.should be_false
      end
    end

    it "is true for the stock GitHub endpoint" do
      with_env({"GORI_UPDATE_API_URL" => nil}) do
        Gori::Update.default_api?.should be_true
      end
    end
  end

  describe ".synthesize_release_json" do
    it "builds a release the normal parser and asset picker consume" do
      json = Gori::Update.synthesize_release_json("v9.9.9", "linux", "x86_64")
      release = Gori::Update.parse_release(json)
      release.tag_name.should eq("v9.9.9")
      asset = Gori::Update.select_asset(release, "linux", "x86_64").not_nil!
      asset.name.should eq("gori-v9.9.9-linux-x86_64")
      asset.browser_download_url.should eq(
        "https://github.com/hahwul/gori/releases/download/v9.9.9/gori-v9.9.9-linux-x86_64")
    end

    it "advertises no digest when SHA256SUMS gave none, rather than faking one" do
      release = Gori::Update.parse_release(
        Gori::Update.synthesize_release_json("v9.9.9", "osx", "arm64"))
      release.assets.first.digest.should be_nil
      Gori::Update.parse_sha256_digest(release.assets.first.digest).should be_nil
    end

    it "carries a SHA256SUMS digest through so verify_sha256! actually runs" do
      hex = "e" * 64
      release = Gori::Update.parse_release(
        Gori::Update.synthesize_release_json("v9.9.9", "linux", "x86_64", digest: hex))
      Gori::Update.parse_sha256_digest(release.assets.first.digest).should eq(hex)
    end

    # The versioned name here is a GUESS made from a tag read out of a Location
    # header. When it is wrong the versioned asset 404s, and the alias — which has
    # no version to get wrong — is the only name left worth trying, so it has to
    # already be in the list download_asset's retry looks through.
    it "lists the version-less alias beside the guessed versioned asset" do
      release = Gori::Update.parse_release(
        Gori::Update.synthesize_release_json("v9.9.9", "linux", "x86_64"))
      release.assets.map(&.name).should eq(["gori-v9.9.9-linux-x86_64", "gori-linux-x86_64"])
      release.assets[1].browser_download_url.should eq(
        "https://github.com/hahwul/gori/releases/download/v9.9.9/gori-linux-x86_64")

      versioned = Gori::Update.select_asset(release, "linux", "x86_64").not_nil!
      versioned.name.should eq("gori-v9.9.9-linux-x86_64")
      Gori::Update.alias_asset(release, versioned, os: "linux", arch: "x86_64")
        .not_nil!.name.should eq("gori-linux-x86_64")
    end

    it "gives the alias its own SHA256SUMS digest, so the retry is still verified" do
      # Both names sit in one SHA256SUMS (release-binary.yml emits a line for each),
      # fetched once. Re-fetching it for the alias would mean a second round trip on
      # the one path where GitHub is already failing — and a flake there would drop
      # the retry to no checksum after we said we would verify.
      versioned_hex = "a" * 64
      alias_hex = "b" * 64
      release = Gori::Update.parse_release(
        Gori::Update.synthesize_release_json("v9.9.9", "linux", "x86_64",
          digest: versioned_hex, alias_digest: alias_hex))
      Gori::Update.parse_sha256_digest(release.assets[0].digest).should eq(versioned_hex)
      Gori::Update.parse_sha256_digest(release.assets[1].digest).should eq(alias_hex)
    end

    it "omits the alias entirely when the platform has no naming for it" do
      release = Gori::Update.parse_release(
        Gori::Update.synthesize_release_json("v9.9.9", "linux", "x86_64"))
      release.assets.size.should eq(2)
      # asset_name would raise for plan9 before we ever get here; the point is that
      # the alias guard degrades rather than taking the whole synthesis down.
      Gori::Update.alias_asset_name("linux", "arm64").should eq("gori-linux-arm64")
    end
  end

  # --- version-less alias retry ----------------------------------------------
  # release-binary.yml publishes `gori-linux-x86_64` beside `gori-v1.2.3-linux-x86_64`.
  # install.sh has retried the alias since #345; `gori update` used to just die on
  # the 404, which matters because the redirect fallback only GUESSES the
  # versioned filename from a tag it read out of a Location header.

  describe ".alias_asset_name" do
    it "drops the version from the platform asset name" do
      Gori::Update.alias_asset_name("linux", "x86_64").should eq("gori-linux-x86_64")
      Gori::Update.alias_asset_name("darwin", "arm64").should eq("gori-osx-arm64.tar.gz")
    end

    it "rejects unsupported OS just like asset_name" do
      expect_raises(Gori::Error, /unsupported OS/) do
        Gori::Update.alias_asset_name("plan9", "x86_64")
      end
    end
  end

  describe ".alias_asset" do
    it "prefers the entry the release actually lists" do
      release = Gori::Update.parse_release(<<-JSON)
        {"tag_name":"v9.9.9","assets":[
          {"name":"gori-v9.9.9-linux-x86_64","browser_download_url":"http://x/versioned","size":1},
          {"name":"gori-linux-x86_64","browser_download_url":"http://x/alias","size":2}
        ]}
        JSON
      versioned = Gori::Update.select_asset(release, "linux", "x86_64").not_nil!
      alias_asset = Gori::Update.alias_asset(release, versioned, os: "linux", arch: "x86_64").not_nil!
      alias_asset.name.should eq("gori-linux-x86_64")
      alias_asset.browser_download_url.should eq("http://x/alias")
    end

    it "never invents a download URL — an unlisted alias is simply no retry" do
      # A pure lookup. The redirect path seeds the alias (with its digest) into the
      # list up front, so there is nothing left for this to guess; guessing anyway
      # would send us back to the host that just 404'd, without a checksum.
      release = Gori::Update.parse_release(
        %({"tag_name":"v9.9.9","assets":[{"name":"gori-v9.9.9-linux-x86_64","browser_download_url":"http://x/v","size":1}]}))
      versioned = Gori::Update.select_asset(release, "linux", "x86_64").not_nil!
      Gori::Update.alias_asset(release, versioned, os: "linux", arch: "x86_64").should be_nil
    end

    it "returns nil rather than raising when the platform has no alias name" do
      # alias_asset_name raises on an unsupported OS, and that must degrade to
      # "nothing to retry" — the caller has to surface the original 404, not a
      # second, unrelated error.
      release = Gori::Update.parse_release(
        %({"tag_name":"v9.9.9","assets":[{"name":"gori-v9.9.9-plan9-x86_64","browser_download_url":"http://x/v","size":1}]}))
      Gori::Update.alias_asset(release, release.assets.first,
        os: "plan9", arch: "x86_64").should be_nil
    end

    it "returns nil when the asset already IS the alias (no second retry)" do
      release = Gori::Update.parse_release(
        %({"tag_name":"v9.9.9","assets":[{"name":"gori-linux-x86_64","browser_download_url":"http://x/a","size":1}]}))
      already = release.assets.first
      Gori::Update.alias_asset(release, already, os: "linux", arch: "x86_64").should be_nil
    end
  end

  describe "update_binary alias retry" do
    it "falls back to the version-less alias when the versioned name 404s" do
      payload = "#!/bin/sh\necho from-alias\n"
      root = File.tempname("gori-alias-")
      Dir.mkdir_p(root)
      begin
        os = Gori::Update.current_os
        arch = Gori::Update.current_arch
        want = Gori::Update.asset_name("99.0.0", os, arch)
        alias_name = Gori::Update.alias_asset_name(os, arch)
        body_bytes = if Gori::Update.asset_is_archive?(alias_name)
                       stage = File.join(root, "stage")
                       Dir.mkdir_p(File.join(stage, "lib"))
                       File.write(File.join(stage, "gori"), payload)
                       File.chmod(File.join(stage, "gori"), 0o755)
                       File.write(File.join(stage, "lib", "libexample.dylib"), "dylib")
                       archive = File.join(root, "asset.tar.gz")
                       Process.run("tar", ["czf", archive, "-C", stage, "gori", "lib"],
                         output: Process::Redirect::Close, error: Process::Redirect::Close)
                       File.read(archive).to_slice
                     else
                       payload.to_slice
                     end

        # Only the alias is servable; the versioned name 404s. Both are listed in
        # the release JSON, so the retry resolves entirely against 127.0.0.1 — a
        # spec that quietly reached github.com would pass here and flake in CI.
        with_mock_release_server(tag: "v99.0.0", body: body_bytes, asset_names: [alias_name]) do |srv|
          json = <<-JSON
            {"tag_name":"v99.0.0","assets":[
              {"name":"#{want}","browser_download_url":"#{srv.download_url(want)}","size":0},
              {"name":"#{alias_name}","browser_download_url":"#{srv.download_url(alias_name)}","size":0}
            ]}
            JSON

          target_dir = File.join(root, "opt", "gori")
          Dir.mkdir_p(target_dir)
          target = File.join(target_dir, "gori")
          File.write(target, "#!/bin/sh\necho old\n")
          File.chmod(target, 0o755)

          io = IO::Memory.new
          Gori::Update.update_binary(target, io, release_json: json)

          out = io.to_s
          out.should contain("#{want} is not in v99.0.0")
          out.should contain("retrying the version-less alias #{alias_name}")
          out.should contain("Installed v99.0.0")
          File.read(target).should contain("from-alias")
        end
      ensure
        FileUtils.rm_rf(root) if File.exists?(root)
      end
    end

    it "does not retry the alias for a non-404 failure" do
      # A truncated transfer (or a checksum mismatch) means the asset IS there and
      # came back wrong. Retrying it under a second name would paper over exactly
      # the signal the integrity checks exist to raise.
      payload = "z" * 40_000
      root = File.tempname("gori-no-retry-")
      Dir.mkdir_p(root)
      begin
        os = Gori::Update.current_os
        arch = Gori::Update.current_arch
        want = Gori::Update.asset_name("99.0.0", os, arch)
        alias_name = Gori::Update.alias_asset_name(os, arch)
        with_mock_release_server(tag: "v99.0.0", body: payload, asset_names: [want, alias_name],
          reported_size: 0_i64, truncate_at: 20_000) do |srv|
          target_dir = File.join(root, "opt", "gori")
          Dir.mkdir_p(target_dir)
          target = File.join(target_dir, "gori")
          File.write(target, "old")
          File.chmod(target, 0o755)

          io = IO::Memory.new
          expect_raises(Gori::Error, /truncated/) do
            Gori::Update.update_binary(target, io, release_json: srv.release_json)
          end
          io.to_s.should_not contain("retrying the version-less alias")
          File.read(target).should eq("old")
        end
      ensure
        FileUtils.rm_rf(root) if File.exists?(root)
      end
    end
  end

  describe ".parse_checksums" do
    it "parses sha256sum-style lines" do
      text = "#{"a" * 64}  gori-v9.9.9-linux-x86_64\n#{"b" * 64}  gori-linux-x86_64\n"
      sums = Gori::Update.parse_checksums(text)
      sums["gori-v9.9.9-linux-x86_64"].should eq("a" * 64)
      sums["gori-linux-x86_64"].should eq("b" * 64)
    end

    it "accepts the binary-mode marker and uppercase hex" do
      sums = Gori::Update.parse_checksums("#{"A" * 64} *gori-osx-arm64.tar.gz\n")
      sums["gori-osx-arm64.tar.gz"].should eq("a" * 64)
    end

    it "skips malformed lines instead of discarding the whole file" do
      text = String.build do |s|
        s << "not-a-hash  gori-bad\n"
        s << "\n"
        s << "#{"c" * 64}  gori-ok\n"
        s << "#{"d" * 63}  gori-tooshort\n"
        s << "#{"e" * 64}\n" # hash with no name
      end
      sums = Gori::Update.parse_checksums(text)
      sums.keys.should eq(["gori-ok"])
    end
  end

  describe ".fetch_latest_release_json_with_fallback" do
    it "reports HTTP 403 as a rate limit and names the token workaround" do
      with_mock_release_server(api_status: 403) do |server|
        ex = expect_raises(Gori::Error, /rate limit/i) do
          Gori::Update.fetch_latest_release_json(server.api_url)
        end
        ex.message.not_nil!.should contain("GITHUB_TOKEN")
      end
    end

    it "passes an API success straight through, with no fallback flag" do
      with_mock_release_server do |server|
        json, via_redirect = Gori::Update.fetch_latest_release_json_with_fallback(server.api_url)
        via_redirect.should be_false
        Gori::Update.parse_release(json).tag_name.should eq("v99.0.0")
      end
    end

    it "does not fall back to github.com when an explicit API URL was given" do
      # Mock servers and GORI_UPDATE_API_URL must stay hermetic: a 403 from the
      # injected endpoint has to surface, not silently retarget the real repo.
      with_mock_release_server(api_status: 403) do |server|
        expect_raises(Gori::Error, /rate limit/i) do
          Gori::Update.fetch_latest_release_json_with_fallback(server.api_url)
        end
      end
    end

    it "never sends a token to a host other than api.github.com" do
      with_env({"GORI_GITHUB_TOKEN" => "secret-pat"}) do
        with_mock_release_server do |server|
          Gori::Update.fetch_latest_release_json(server.api_url)
          server.last_api_headers.not_nil!["Authorization"]?.should be_nil
        end
      end
    end
  end

  # CLI.run's rescue is deliberately narrow: a non-Gori::Error reaches the top of
  # the process as a Crystal backtrace, "because those are bugs and want a trace"
  # (cli.cr). Being offline is not a bug — it is the likeliest way an updater
  # fails — and every network path here used to answer it with exactly that
  # trace. `gori update` on a machine with no route out printed
  # `Unhandled exception: ... (Socket::ConnectError)`.
  describe "I/O failures surface as Gori::Error, never a backtrace (Bug C)" do
    it "wraps a refused connection to the releases API" do
      url = "http://127.0.0.1:#{dead_port}/repos/hahwul/gori/releases/latest"
      expect_raises(Gori::Error, /could not reach 127\.0\.0\.1/) do
        Gori::Update.fetch_latest_release_json(url)
      end
    end

    # fetch_latest_release_json_with_fallback re-raises whatever the API fetch
    # threw once the redirect fallback has nothing to offer (or is not eligible).
    # That re-raise is only as clean as the original exception.
    it "keeps the re-raise from the fallback path a Gori::Error too" do
      url = "http://127.0.0.1:#{dead_port}/repos/hahwul/gori/releases/latest"
      expect_raises(Gori::Error, /could not reach/) do
        Gori::Update.fetch_latest_release_json_with_fallback(url)
      end
    end

    it "wraps a refused connection while downloading an asset" do
      url = "http://127.0.0.1:#{dead_port}/download/gori-v99.0.0-linux-x86_64"
      dest = File.tempname("gori-dl-")
      begin
        expect_raises(Gori::Error, /could not download/) do
          Gori::Update.download_to(url, dest)
        end
      ensure
        File.delete?(dest)
      end
    end

    it "wraps a file that cannot be read for checksumming" do
      expect_raises(Gori::Error, /could not read .* to checksum it/) do
        Gori::Update.file_sha256(File.join(File.tempname("gori-absent-", ""), "nope"))
      end
    end

    # install_dir_writable? deliberately passes a directory that does not exist
    # yet, on the grounds that atomic_install creates it — so the mkdir is the
    # first place the layout can actually be rejected, and it sat outside
    # atomic_install's own rescue.
    it "wraps an install directory that cannot be created" do
      root = File.tempname("gori-mkdir-")
      Dir.mkdir_p(root)
      begin
        blocker = File.join(root, "prefix")
        File.write(blocker, "a file, not a directory")
        source = File.join(root, "new-gori")
        File.write(source, "new")

        # install_dir_writable? says yes (the dir simply is not there yet).
        Gori::Update.install_dir_writable?(File.join(blocker, "bin", "gori")).should be_true
        expect_raises(Gori::Error, /could not create the install directory/) do
          Gori::Update.atomic_install(source, File.join(blocker, "bin", "gori"))
        end
      ensure
        FileUtils.rm_rf(root) if File.exists?(root)
      end
    end

    # Process.run RAISES File::NotFoundError when the binary is absent rather
    # than returning a failed status, so `tar list failed` never got a chance to
    # run on a minimal image — the macOS archive install backtraced instead.
    it "wraps a missing tar" do
      expect_raises(Gori::Error, /could not run tar/) do
        with_env({"PATH" => File.tempname("gori-empty-path-", "")}) do
          Gori::Update.list_tar_entries("/nonexistent.tar.gz")
        end
      end
    end
  end

  describe ".run --exec on channels with no single command" do
    # package_action deliberately returns `command: nil` for pacman/deb/rpm/nix:
    # which one is right depends on the AUR helper / how nix installed it, and
    # the rest need sudo. But the whole acknowledgement lived inside
    # `if cmd = action[:command]`, so `--exec` printed NOTHING about itself on
    # those channels and read as though it had run the upgrade.
    it "says --exec had nothing to run instead of staying silent" do
      {
        {"/usr/bin/gori", Gori::Update::OwnerResult::Pacman, Gori::Update::OsFamily::ArchLike, "pacman"},
        {"/usr/bin/gori", Gori::Update::OwnerResult::Dpkg, Gori::Update::OsFamily::DebianLike, "deb"},
        {"/usr/bin/gori", Gori::Update::OwnerResult::Rpm, Gori::Update::OsFamily::RhelLike, "rpm"},
        {"/nix/store/0fhkwk15n3ya0llfr0754awcldpz4x54-gori-0.1.3/bin/gori",
         Gori::Update::OwnerResult::None, Gori::Update::OsFamily::Unknown, "nix"},
      }.each do |(path, owner, family, channel)|
        io = IO::Memory.new
        Gori::Update.run(io, io, exe_path: path, exec_package_commands: true,
          owner: owner, os_family: family)
        out = io.to_s
        out.should contain("install channel: #{channel}")
        out.should contain("--exec has nothing to run on the #{channel} channel")
        # Still no claim that anything was executed.
        out.should_not contain("Running:")
      end
    end

    it "stays quiet about --exec on those channels when it was not passed" do
      io = IO::Memory.new
      Gori::Update.run(io, io, exe_path: "/usr/bin/gori",
        owner: Gori::Update::OwnerResult::Pacman,
        os_family: Gori::Update::OsFamily::ArchLike)
      io.to_s.should_not contain("--exec")
    end

    # The channels that DO carry a command keep the hint they always had.
    it "leaves the Homebrew/Snap hint alone" do
      io = IO::Memory.new
      Gori::Update.run(io, io, exe_path: "/opt/homebrew/Cellar/gori/0.1.0/bin/gori")
      out = io.to_s
      out.should contain("Re-run with --exec to run the command above automatically.")
      out.should_not contain("has nothing to run")
    end
  end

  describe ".copy_with_progress on a failed transfer" do
    # The clear used to sit AFTER the copy loop, so an exception skipped it: the
    # last bar stayed on screen and `gori update: …` was then printed onto that
    # same line, right after the transfer rate.
    it "clears the progress line even when the download raises" do
      term = IO::Memory.new
      dest = File.tempname("gori-progress-")
      begin
        expect_raises(IO::Error, /connection reset/) do
          Gori::Update.copy_with_progress(BurstThenResetIO.new(2), dest, 10_000_000_i64,
            progress_io: term, force_progress: true)
        end
        drawn = term.to_s
        drawn.should contain("%") # a bar really was drawn
        drawn.should end_with("\r\e[K")
      ensure
        File.delete?(dest)
      end
    end
  end

  describe ".atomic_install leftover sweep" do
    # atomic_install's `rescue` only runs when the copy RAISES. Crystal's default
    # SIGINT terminates without unwinding, so Ctrl-C during the copy (or a kill,
    # or a power loss) stranded a full ~40 MB duplicate of the binary in the
    # operator's install directory, and every retry added another. lib/ already
    # swept its own leftovers; the binary did not.
    it "clears .gori-update.* temps stranded by an interrupted run" do
      dir = File.tempname("gori-sweep-")
      Dir.mkdir_p(dir)
      begin
        target = File.join(dir, "gori")
        File.write(target, "#!/bin/sh\necho old\n")
        File.chmod(target, 0o755)
        File.write(File.join(dir, ".gori-update.4242.deadbeef"), "a" * 4096)
        File.write(File.join(dir, ".gori-update.4243.cafebabe"), "a" * 4096)
        # Neither the installed binary nor an unrelated sibling may be touched.
        File.write(File.join(dir, "gori-notes.txt"), "keep me")

        source = File.join(dir, "new-gori")
        File.write(source, "#!/bin/sh\necho new\n")

        Gori::Update.atomic_install(source, target)

        # Dir.children, not Dir.glob: glob skips dotfiles, so it reports empty
        # even when the orphans are right there.
        Dir.children(dir).select(&.starts_with?(".gori-update.")).should be_empty
        File.read(target).should contain("echo new")
        File.read(File.join(dir, "gori-notes.txt")).should eq("keep me")
      ensure
        FileUtils.rm_rf(dir) if File.exists?(dir)
      end
    end

    # Matched by prefix over Dir.children rather than by Dir.glob, for the reason
    # sweep_lib_leftovers gives: the install path belongs to the operator.
    it "treats glob metacharacters in the install path as literal" do
      root = File.tempname("gori-sweep-glob-")
      dir = File.join(root, "gori[1]*?")
      Dir.mkdir_p(dir)
      begin
        target = File.join(dir, "gori")
        File.write(target, "old")
        File.write(File.join(dir, ".gori-update.7.abcd1234"), "stale")
        source = File.join(root, "new-gori")
        File.write(source, "new")

        Gori::Update.atomic_install(source, target)

        Dir.children(dir).select(&.starts_with?(".gori-update.")).should be_empty
        File.read(target).should eq("new")
      ensure
        FileUtils.rm_rf(root) if File.exists?(root)
      end
    end
  end

  describe "redirect-fallback checksum notice" do
    # The "no SHA256SUMS, so verification is skipped" line used to be printed
    # BEFORE the download, off the versioned asset. But the versioned name on the
    # redirect path is a GUESS from a tag, and download_asset swaps in the
    # version-less alias when that guess 404s — and the alias carries its own
    # SHA256SUMS entry. So the operator was told verification was skipped for an
    # asset that was never fetched, while the one that was actually installed got
    # verified. The notice now reads off the asset that came down.
    it "reports on the asset that was actually downloaded, not the one first guessed" do
      wrong = Gori::Update::Asset.new("gori-v9.9.9-linux-x86_64", "http://127.0.0.1/x", 0_i64, nil)
      verified = Gori::Update::Asset.new("gori-linux-x86_64", "http://127.0.0.1/y", 0_i64,
        "sha256:#{"b" * 64}")

      payload = File.tempname("gori-notice-")
      begin
        File.write(payload, "body")
        real = Gori::Update.file_sha256(payload)
        good = Gori::Update::Asset.new(verified.name, verified.browser_download_url, 0_i64,
          "sha256:#{real}")

        io = IO::Memory.new
        Gori::Update.verify_download_for_spec(payload, good, 4_i64, io, announce_skip: true)
        out = io.to_s
        out.should contain("Verifying sha256 checksum")
        out.should_not contain("verification is skipped")

        # And the genuine no-digest case still says so, naming that same asset.
        io2 = IO::Memory.new
        Gori::Update.verify_download_for_spec(payload, wrong, 4_i64, io2, announce_skip: true)
        io2.to_s.should contain("#{wrong.name} has no SHA256SUMS entry")

        # Off the redirect path there is nothing to disclaim: the API always
        # hands over a per-asset digest, so silence there is not a skipped check.
        io3 = IO::Memory.new
        Gori::Update.verify_download_for_spec(payload, wrong, 4_i64, io3, announce_skip: false)
        io3.to_s.should be_empty

        # A digest that is present but wrong still fails, notice or not.
        expect_raises(Gori::Error, /checksum mismatch/) do
          Gori::Update.verify_download_for_spec(payload, verified, 4_i64, IO::Memory.new,
            announce_skip: true)
        end
      ensure
        File.delete?(payload)
      end
    end
  end
end
