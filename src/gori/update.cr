require "http/client"
require "json"
require "uri"
require "file_utils"
require "random/secure"

module Gori
  # Channel-aware self-update for `gori update`.
  #
  # Pure helpers (channel detection, asset naming, release JSON parsing) are
  # unit-tested with injected paths/fixtures. I/O (HTTP, filesystem, Process)
  # lives in the methods used by the CLI entrypoint.
  module Update
    GITHUB_REPO     = "hahwul/gori"
    API_LATEST      = "https://api.github.com/repos/#{GITHUB_REPO}/releases/latest"
    RELEASES_URL    = "#{REPOSITORY_URL}/releases"
    USER_AGENT      = "gori/#{VERSION} (+#{REPOSITORY_URL})"
    MAX_REDIRECTS   = 10
    HTTP_TIMEOUT    = 60.seconds
    # Shared library roots we must never rm_rf / replace wholesale.
    FORBIDDEN_LIB_PATHS = {
      "/usr/local/lib", "/usr/lib", "/lib", "/lib64", "/usr/local/lib64",
      "/opt/homebrew/lib", "/opt/local/lib",
    }
    # Parents of those roots / well-known system prefixes.
    SYSTEM_PREFIXES = {
      "/", "/usr", "/usr/local", "/opt", "/opt/homebrew", "/opt/local", "/snap",
    }

    enum Channel
      Homebrew
      Snap
      Pacman
      Deb
      Rpm
      Binary
    end

    # Result of asking the distro package manager who owns an executable path.
    enum OwnerResult
      Pacman  # pacman -Qo succeeded
      Dpkg    # dpkg-query -S succeeded
      Rpm     # rpm -qf succeeded
      None    # at least one PM tool was queried and none claimed the path
      Unknown # no PM query tools available (or probe skipped)
    end

    # Coarse family from /etc/os-release (for fallback guidance only).
    enum OsFamily
      ArchLike
      DebianLike
      RhelLike
      Unknown
    end

    # ---------------------------------------------------------------------------
    # Channel detection (pure + injectable probes)
    # ---------------------------------------------------------------------------

    # Classify an install from the executable path plus optional ownership/OS hints.
    #
    # For FHS system bins (`/usr/bin`, `/bin`):
    # - owned by pacman/dpkg/rpm → that package channel (never overwrite)
    # - probed and **not** owned → Binary (manual copy; self-update allowed)
    # - unprobed → fall back to os-release family for package guidance, else Binary
    def self.detect_channel(exe_path : String, *,
                            owner : OwnerResult = OwnerResult::Unknown,
                            os_family : OsFamily = OsFamily::Unknown) : Channel
      return Channel::Snap if snap_path?(exe_path)
      return Channel::Homebrew if homebrew_path?(exe_path)

      if system_package_path?(exe_path)
        return channel_for_system_bin(owner, os_family)
      end

      Channel::Binary
    end

    def self.channel_for_system_bin(owner : OwnerResult, os_family : OsFamily) : Channel
      case owner
      when .pacman? then Channel::Pacman
      when .dpkg?   then Channel::Deb
      when .rpm?    then Channel::Rpm
      when .none?   then Channel::Binary
      else
        # OwnerResult::Unknown — no successful probe. Prefer distro guidance over
        # blindly replacing a system path when os-release looks like a packaging distro.
        case os_family
        when .arch_like?   then Channel::Pacman
        when .debian_like? then Channel::Deb
        when .rhel_like?   then Channel::Rpm
        else                    Channel::Binary
        end
      end
    end

    def self.homebrew_path?(path : String) : Bool
      return true if path.includes?("/Cellar/gori")
      return true if path.includes?("/.linuxbrew/") || path.includes?("/linuxbrew/")
      return true if path.includes?("/Homebrew/Cellar/gori") || path.includes?("/Homebrew/opt/gori")
      # Apple Silicon prefix: Cellar, formula opt link, or the bin shim.
      # Prefer File.realpath at the call site so Cellar wins over opt/ symlinks.
      # Do NOT treat bare /usr/local/opt/gori as Homebrew — curl install.sh uses that path too.
      if path.starts_with?("/opt/homebrew/")
        return path.includes?("/Cellar/gori") ||
          path.starts_with?("/opt/homebrew/opt/gori/") ||
          path == "/opt/homebrew/bin/gori"
      end
      path.includes?("/homebrew/Cellar/gori") ||
        path.includes?("/homebrew/opt/gori/")
    end

    def self.snap_path?(path : String) : Bool
      path.starts_with?("/snap/") || path.includes?("/snap/gori/")
    end

    # Paths where distro packages typically install the CLI (not /usr/local).
    def self.system_package_path?(path : String) : Bool
      return true if path == "/usr/bin/gori" || path == "/bin/gori"
      base = File.basename(path)
      return false unless base == "gori"
      path.starts_with?("/usr/bin/") || path.starts_with?("/bin/")
    end

    # Parse /etc/os-release body into a coarse family (pure; for tests + probe).
    def self.parse_os_release(content : String) : OsFamily
      id = ""
      id_like = ""
      content.each_line do |line|
        line = line.strip
        next if line.empty? || line.starts_with?('#')
        if line.starts_with?("ID=")
          id = unquote_os_value(line.lchop("ID=")).downcase
        elsif line.starts_with?("ID_LIKE=")
          id_like = unquote_os_value(line.lchop("ID_LIKE=")).downcase
        end
      end
      blob = "#{id} #{id_like}"
      # Order matters: some images set ID=linux with ID_LIKE=arch.
      return OsFamily::ArchLike if blob.split.any? { |t|
        {"arch", "archlinux", "manjaro", "endeavouros", "garuda", "artix", "archarm"}.includes?(t)
      }
      return OsFamily::DebianLike if blob.split.any? { |t|
        {"debian", "ubuntu", "linuxmint", "pop", "raspbian", "kali", "elementary", "zorin", "neon"}.includes?(t)
      }
      return OsFamily::RhelLike if blob.split.any? { |t|
        {"rhel", "fedora", "centos", "rocky", "almalinux", "ol", "amzn", "sles", "opensuse", "suse", "mageia"}.includes?(t)
      }
      OsFamily::Unknown
    end

    private def self.unquote_os_value(raw : String) : String
      v = raw.strip
      if v.size >= 2 && ((v.starts_with?('"') && v.ends_with?('"')) || (v.starts_with?('\'') && v.ends_with?('\'')))
        v[1..-2]
      else
        v
      end
    end

    def self.load_os_family(os_release_path : String = "/etc/os-release") : OsFamily
      return OsFamily::Unknown unless File.file?(os_release_path)
      parse_os_release(File.read(os_release_path))
    rescue
      OsFamily::Unknown
    end

    # Ask pacman / dpkg / rpm whether they own `path`. Pure enough for tests via
    # the optional `runners` inject (defaults run real Process commands).
    def self.probe_package_owner(path : String) : OwnerResult
      probed = false

      if Process.find_executable("pacman")
        probed = true
        if run_quiet("pacman", ["-Qo", path])
          return OwnerResult::Pacman
        end
      end

      if Process.find_executable("dpkg-query")
        probed = true
        if run_quiet("dpkg-query", ["-S", path])
          return OwnerResult::Dpkg
        end
      elsif Process.find_executable("dpkg")
        probed = true
        if run_quiet("dpkg", ["-S", path])
          return OwnerResult::Dpkg
        end
      end

      if Process.find_executable("rpm")
        probed = true
        if run_quiet("rpm", ["-qf", path])
          return OwnerResult::Rpm
        end
      end

      probed ? OwnerResult::None : OwnerResult::Unknown
    end

    private def self.run_quiet(cmd : String, args : Array(String)) : Bool
      status = Process.run(cmd, args,
        output: Process::Redirect::Close,
        error: Process::Redirect::Close)
      status.success?
    rescue
      false
    end

    # ---------------------------------------------------------------------------
    # Package-manager guidance (pure)
    # ---------------------------------------------------------------------------

    # Returns a short human message and optional shell command for the channel.
    def self.package_action(channel : Channel) : NamedTuple(message: String, command: String?)
      case channel
      when .homebrew?
        {
          message: "Homebrew install detected. Upgrade with the package manager (do not overwrite the brew-managed binary):",
          command: "brew upgrade gori",
        }
      when .snap?
        {
          message: "Snap install detected. Refresh with the package manager:",
          command: "snap refresh gori",
        }
      when .pacman?
        {
          message: "pacman/AUR install detected. Upgrade with your AUR helper (or pacman if packaged in a repo):\n  yay -Syu gori\n  paru -Syu gori\n  # or: sudo pacman -Syu gori",
          command: nil,
        }
      when .deb?
        {
          message: "Debian/Ubuntu package install detected (dpkg owns this binary). Upgrade with apt (do not overwrite /usr/bin):\n  sudo apt update && sudo apt install --only-upgrade gori",
          command: nil,
        }
      when .rpm?
        {
          message: "RPM package install detected. Upgrade with your package manager (do not overwrite /usr/bin):\n  sudo dnf upgrade gori\n  # or: sudo yum upgrade gori\n  # or: sudo zypper update gori",
          command: nil,
        }
      else
        {
          message: "Standalone binary install — downloading the latest GitHub release asset.",
          command: nil,
        }
      end
    end

    def self.package_managed?(channel : Channel) : Bool
      channel.homebrew? || channel.snap? || channel.pacman? || channel.deb? || channel.rpm?
    end

    # ---------------------------------------------------------------------------
    # Release asset naming (pure)
    # ---------------------------------------------------------------------------

    def self.normalize_version(version : String) : String
      v = version
      v = v[1..] if v.starts_with?('v') || v.starts_with?('V')
      v
    end

    def self.normalize_os(os : String) : String
      case os.downcase
      when "darwin", "macos", "osx" then "osx"
      when "linux"                  then "linux"
      else                               os.downcase
      end
    end

    def self.normalize_arch(arch : String) : String
      case arch.downcase
      when "x86_64", "amd64", "x64" then "x86_64"
      when "aarch64", "arm64"       then "arm64"
      else                               arch.downcase
      end
    end

    # Rough numeric compare on dotted versions (enough to refuse downgrades).
    # Returns -1 if a < b, 0 if equal prefix, 1 if a > b.
    def self.version_cmp(a : String, b : String) : Int32
      pa = normalize_version(a).split(/[.+-]/).map { |p| p.to_i? || 0 }
      pb = normalize_version(b).split(/[.+-]/).map { |p| p.to_i? || 0 }
      n = Math.max(pa.size, pb.size)
      n.times do |i|
        av = i < pa.size ? pa[i] : 0
        bv = i < pb.size ? pb[i] : 0
        return -1 if av < bv
        return 1 if av > bv
      end
      0
    end

    # Release asset basename for platform (matches PR #114 / hwaro parity).
    # Linux: plain binary `gori-v{ver}-linux-{x86_64|arm64}`
    # macOS: tarball `gori-v{ver}-osx-{arm64|x86_64}.tar.gz` (contains gori + lib/)
    def self.asset_name(version : String, os : String, arch : String) : String
      ver = normalize_version(version)
      os_n = normalize_os(os)
      arch_n = normalize_arch(arch)
      case os_n
      when "linux"
        "gori-v#{ver}-linux-#{arch_n}"
      when "osx"
        "gori-v#{ver}-osx-#{arch_n}.tar.gz"
      else
        raise Error.new("unsupported OS for gori release assets: #{os} (need linux or osx/darwin)")
      end
    end

    def self.current_os : String
      {% if flag?(:darwin) %}
        "osx"
      {% elsif flag?(:linux) %}
        "linux"
      {% else %}
        "unknown"
      {% end %}
    end

    def self.current_arch : String
      {% if flag?(:aarch64) %}
        "arm64"
      {% elsif flag?(:x86_64) %}
        "x86_64"
      {% else %}
        "unknown"
      {% end %}
    end

    def self.asset_is_archive?(name : String) : Bool
      name.ends_with?(".tar.gz") || name.ends_with?(".tgz")
    end

    # ---------------------------------------------------------------------------
    # Safe lib destination (pure) — never touch shared system library trees
    # ---------------------------------------------------------------------------

    # True when placing `lib/` next to the binary would hit a shared/system lib root.
    # Examples of bad targets:
    #   /usr/local/gori        → /usr/local/lib  (system Homebrew/lib tree)
    #   /usr/local/bin/gori    → /usr/local/bin/lib is odd; still refused as shared bin layout
    def self.forbidden_lib_destination?(lib_dst : String) : Bool
      path = File.expand_path(lib_dst)
      return true if FORBIDDEN_LIB_PATHS.includes?(path)
      return true if path.starts_with?("/System/")
      return true if path == "/usr/lib" || path.starts_with?("/usr/lib/")
      # lib_dst is PREFIX/lib where PREFIX is a system root
      return true if SYSTEM_PREFIXES.includes?(File.dirname(path))
      false
    end

    # Bare binary living under a system .../bin directory (PATH drop-in).
    def self.system_shared_bin_target?(target_path : String) : Bool
      parent = File.dirname(File.expand_path(target_path))
      return false unless File.basename(parent) == "bin"
      SYSTEM_PREFIXES.includes?(File.dirname(parent))
    end

    # Returns the sibling `lib` path if it is safe to replace; nil if the install
    # layout cannot host a bundled lib/ (caller must refuse macOS archive update).
    def self.safe_lib_destination(target_path : String) : String?
      return nil if system_shared_bin_target?(target_path)
      lib_dst = File.join(File.dirname(File.expand_path(target_path)), "lib")
      return nil if forbidden_lib_destination?(lib_dst)
      lib_dst
    end

    # Whether this target path is a supported layout for macOS archive installs
    # (dedicated dir with gori + lib/, not a bare file under system .../bin).
    def self.supports_archive_lib_layout?(target_path : String) : Bool
      !safe_lib_destination(target_path).nil?
    end

    # ---------------------------------------------------------------------------
    # Release JSON → asset (pure)
    # ---------------------------------------------------------------------------

    struct Asset
      getter name : String
      getter browser_download_url : String
      getter size : Int64

      def initialize(@name : String, @browser_download_url : String, @size : Int64 = 0_i64)
      end
    end

    struct Release
      getter tag_name : String
      getter assets : Array(Asset)

      def initialize(@tag_name : String, @assets : Array(Asset))
      end

      def version : String
        Update.normalize_version(tag_name)
      end
    end

    def self.parse_release(json_body : String) : Release
      data = JSON.parse(json_body)
      tag = data["tag_name"]?.try(&.as_s?)
      raise Error.new("release JSON missing tag_name") unless tag

      assets = [] of Asset
      if arr = data["assets"]?.try(&.as_a?)
        arr.each do |item|
          name = item["name"]?.try(&.as_s?) || next
          url = item["browser_download_url"]?.try(&.as_s?) || next
          size = item["size"]?.try(&.as_i64?) || 0_i64
          assets << Asset.new(name, url, size)
        end
      end
      Release.new(tag, assets)
    end

    def self.select_asset(release : Release, os : String = current_os, arch : String = current_arch) : Asset?
      want = asset_name(release.version, os, arch)
      release.assets.find { |a| a.name == want }
    end

    # Parse release JSON and pick the platform asset, or raise a clear Error.
    def self.resolve_asset_from_json(json_body : String, os : String = current_os, arch : String = current_arch) : Asset
      release = parse_release(json_body)
      if release.assets.empty?
        raise Error.new(
          "latest release #{release.tag_name} has no downloadable assets yet — see #{RELEASES_URL}"
        )
      end
      asset = select_asset(release, os, arch)
      unless asset
        want = asset_name(release.version, os, arch)
        names = release.assets.map(&.name)
        listed = names.empty? ? "none" : names.join(", ")
        raise Error.new(
          "no matching asset '#{want}' in #{release.tag_name} (available: #{listed}) — see #{RELEASES_URL}"
        )
      end
      asset
    end

    # ---------------------------------------------------------------------------
    # Tar safety (listing only — pure relative to process I/O but testable with fixtures)
    # ---------------------------------------------------------------------------

    # Reject absolute paths and `..` segments (tar slip).
    def self.unsafe_tar_entry?(entry : String) : Bool
      e = entry.strip
      return false if e.empty?
      return true if e.starts_with?('/')
      e.split('/').any? { |seg| seg == ".." }
    end

    def self.assert_safe_tar_listing(listing : String) : Nil
      listing.each_line do |entry|
        if unsafe_tar_entry?(entry)
          raise Error.new("refusing archive with unsafe path entry: #{entry.strip}")
        end
      end
    end

    # ---------------------------------------------------------------------------
    # CLI orchestration + I/O
    # ---------------------------------------------------------------------------

    def self.resolve_executable_path : String
      path = Process.executable_path
      raise Error.new("could not determine the running gori executable path") unless path
      File.realpath(path)
    end

    private def self.http_client(host : String, port : Int32, tls : Bool) : HTTP::Client
      client = HTTP::Client.new(host, port, tls)
      client.connect_timeout = HTTP_TIMEOUT
      client.read_timeout = HTTP_TIMEOUT
      client
    end

    def self.fetch_latest_release_json(api_url : String = API_LATEST) : String
      uri = URI.parse(api_url)
      headers = HTTP::Headers{
        "Accept"     => "application/vnd.github+json",
        "User-Agent" => USER_AGENT,
      }
      host = uri.host || raise Error.new("invalid API URL: #{api_url}")
      port = uri.port || (uri.scheme == "https" ? 443 : 80)
      tls = uri.scheme == "https"
      client = http_client(host, port, tls)
      begin
        response = client.get(uri.request_target, headers: headers)
        case response.status_code
        when 200
          response.body
        when 404
          raise Error.new("no GitHub releases found for #{GITHUB_REPO} — see #{RELEASES_URL}")
        when 403
          raise Error.new("GitHub API forbidden (rate limit or auth) — see #{RELEASES_URL}")
        else
          snippet = response.body.lines.first?.try { |l| l.size > 200 ? l[0, 200] : l } || ""
          raise Error.new("GitHub releases API returned HTTP #{response.status_code}#{snippet.empty? ? "" : ": #{snippet}"}")
        end
      ensure
        client.close
      end
    end

    def self.download_to(url : String, dest : String, redirects_left : Int32 = MAX_REDIRECTS) : Nil
      raise Error.new("too many redirects downloading #{url}") if redirects_left < 0

      uri = URI.parse(url)
      host = uri.host || raise Error.new("invalid download URL: #{url}")
      port = uri.port || (uri.scheme == "https" ? 443 : 80)
      tls = uri.scheme == "https"
      headers = HTTP::Headers{"User-Agent" => USER_AGENT}

      client = http_client(host, port, tls)
      begin
        client.get(uri.request_target, headers: headers) do |response|
          code = response.status_code
          if {301, 302, 303, 307, 308}.includes?(code)
            location = response.headers["Location"]?
            raise Error.new("redirect without Location from #{url}") unless location
            response.body_io.gets_to_end
            # Resolve relative redirects against the current URL.
            next_url = location.starts_with?("http://") || location.starts_with?("https://") ? location : URI.parse(url).resolve(location).to_s
            client.close
            return download_to(next_url, dest, redirects_left - 1)
          end
          unless code == 200
            response.body_io.gets_to_end
            raise Error.new("download failed HTTP #{code} for #{url}")
          end
          File.open(dest, "w") do |file|
            IO.copy(response.body_io, file)
          end
        end
      ensure
        client.close
      end
    end

    def self.atomic_install(source : String, target : String) : Nil
      dir = File.dirname(target)
      Dir.mkdir_p(dir)
      tmp = File.join(dir, ".gori-update.#{Process.pid}.#{Random::Secure.hex(4)}")
      begin
        FileUtils.cp(source, tmp)
        File.chmod(tmp, 0o755)
        File.rename(tmp, target)
      rescue ex : File::Error
        File.delete?(tmp)
        # Cross-device rename: fall back to copy into a new temp then rename if possible.
        tmp2 = File.join(dir, ".gori-update.#{Process.pid}.#{Random::Secure.hex(4)}")
        begin
          FileUtils.cp(source, tmp2)
          File.chmod(tmp2, 0o755)
          begin
            File.rename(tmp2, target)
          rescue
            # Last resort in-place replace (not crash-safe across power loss).
            FileUtils.cp(source, target)
            File.chmod(target, 0o755)
            File.delete?(tmp2)
          end
        rescue ex2
          File.delete?(tmp2)
          raise Error.new("failed to install binary to #{target}: #{ex2.message} (earlier: #{ex.message})")
        end
      end
    end

    # Crystal has no Dir.mktmpdir; create a unique dir under Dir.tempdir and clean up.
    private def self.with_tempdir(prefix : String, &)
      dir = File.tempname(prefix, "")
      Dir.mkdir_p(dir)
      begin
        yield dir
      ensure
        FileUtils.rm_rf(dir) if File.exists?(dir)
      end
    end

    def self.list_tar_entries(archive : String) : String
      listing = IO::Memory.new
      tar_err = IO::Memory.new
      status = Process.run("tar", ["tzf", archive], output: listing, error: tar_err)
      raise Error.new("tar list failed: #{tar_err}") unless status.success?
      listing.to_s
    end

    def self.extract_tar(archive : String, dest_dir : String) : Nil
      assert_safe_tar_listing(list_tar_entries(archive))
      tar_err = IO::Memory.new
      status = Process.run("tar", ["xzf", archive, "-C", dest_dir],
        output: Process::Redirect::Close, error: tar_err)
      raise Error.new("tar extract failed: #{tar_err}") unless status.success?
    end

    # Replace lib/ only at a verified-safe destination. Stages to a temp name then renames.
    def self.replace_lib_dir(lib_src : String, lib_dst : String) : Nil
      raise Error.new("refusing to install lib/ at unsafe path: #{lib_dst}") if forbidden_lib_destination?(lib_dst)

      parent = File.dirname(lib_dst)
      Dir.mkdir_p(parent)
      staged = "#{lib_dst}.gori-new.#{Process.pid}.#{Random::Secure.hex(4)}"
      backup = "#{lib_dst}.gori-old.#{Process.pid}.#{Random::Secure.hex(4)}"
      FileUtils.rm_rf(staged) if File.exists?(staged)
      FileUtils.cp_r(lib_src, staged)
      begin
        if File.exists?(lib_dst)
          FileUtils.rm_rf(backup) if File.exists?(backup)
          File.rename(lib_dst, backup)
        end
        File.rename(staged, lib_dst)
        FileUtils.rm_rf(backup) if File.exists?(backup)
      rescue ex
        # Best-effort restore
        FileUtils.rm_rf(staged) if File.exists?(staged)
        if File.exists?(backup) && !File.exists?(lib_dst)
          File.rename(backup, lib_dst) rescue nil
        end
        raise Error.new("failed to install bundled lib/ to #{lib_dst}: #{ex.message}")
      end
    end

    def self.install_from_download(downloaded : String, target_path : String, archive : Bool) : Nil
      if archive
        unless supports_archive_lib_layout?(target_path)
          raise Error.new(
            "macOS archive update refuses this install layout (#{target_path}): " \
            "bundled lib/ would land in a shared library directory. " \
            "Install with the curl installer (keeps gori + lib/ under PREFIX/opt/gori) " \
            "or place the binary in a dedicated directory, not directly under .../bin. " \
            "See #{REPOSITORY_URL}#installation"
          )
        end
        lib_dst = safe_lib_destination(target_path)
        raise Error.new("internal: safe lib destination missing") unless lib_dst

        with_tempdir("gori-update-") do |dir|
          extract_tar(downloaded, dir)

          new_bin = File.join(dir, "gori")
          unless File.file?(new_bin)
            found = Dir.glob(File.join(dir, "**", "gori")).find do |p|
              File.file?(p) && File.basename(p) == "gori" && !unsafe_tar_entry?(p.lchop(dir).lchop('/'))
            end
            raise Error.new("archive did not contain a gori binary") unless found
            new_bin = found
          end

          lib_src = File.join(File.dirname(new_bin), "lib")
          # Install lib first so a failed lib step never leaves a new binary without dylibs.
          if Dir.exists?(lib_src)
            replace_lib_dir(lib_src, lib_dst)
          end
          atomic_install(new_bin, target_path)
        end
      else
        atomic_install(downloaded, target_path)
      end
    end

    def self.update_binary(target_path : String, io : IO = STDOUT, _err : IO = STDERR, *,
                           release_json : String? = nil) : Nil
      json = release_json || fetch_latest_release_json
      release = parse_release(json)
      ver = release.version
      local = normalize_version(VERSION)

      cmp = version_cmp(local, ver)
      if cmp == 0
        io.puts "Already up to date (v#{ver})."
        return
      end
      if cmp > 0
        io.puts "Local version v#{local} is newer than latest release #{release.tag_name}; not downgrading."
        return
      end

      asset = resolve_asset_from_json(json, current_os, current_arch)

      # Fail fast on unsafe macOS layouts before downloading tens of MB.
      if asset_is_archive?(asset.name) && !supports_archive_lib_layout?(target_path)
        raise Error.new(
          "cannot install macOS release archive over #{target_path}: " \
          "lib/ would target a shared path. Use: curl -fsSL https://gori.hahwul.com/install.sh | bash"
        )
      end

      io.puts "Updating #{VERSION} → #{release.tag_name}"
      io.puts "Downloading #{asset.name} …"

      with_tempdir("gori-dl-") do |dir|
        dest = File.join(dir, asset.name)
        download_to(asset.browser_download_url, dest)
        got = File.size(dest)
        raise Error.new("downloaded asset is empty: #{asset.name}") unless got > 0
        if asset.size > 0 && got != asset.size
          raise Error.new("downloaded size mismatch for #{asset.name}: expected #{asset.size} bytes, got #{got}")
        end
        install_from_download(dest, target_path, asset_is_archive?(asset.name))
      end

      io.puts "Installed #{release.tag_name} → #{target_path}"
      if current_os == "osx"
        io.puts "Note: macOS release keeps gori and lib/ side by side under #{File.dirname(target_path)}."
      end
    end

    # Entry used by `gori update`. Raises `Gori::Error` on failure (CLI aborts).
    # Package-manager commands are print-only unless `exec_package_commands` is true
    # (CLI: `gori update --exec`).
    #
    # Tests inject `owner` / `os_family` to avoid live package-manager probes.
    def self.run(io : IO = STDOUT, err : IO = STDERR, *,
                 exe_path : String? = nil,
                 release_json : String? = nil,
                 exec_package_commands : Bool = false,
                 owner : OwnerResult? = nil,
                 os_family : OsFamily? = nil) : Nil
      path = exe_path || resolve_executable_path
      resolved_owner = owner || (system_package_path?(path) ? probe_package_owner(path) : OwnerResult::None)
      resolved_family = os_family || load_os_family
      channel = detect_channel(path, owner: resolved_owner, os_family: resolved_family)

      io.puts "gori #{VERSION}"
      io.puts "install channel: #{channel.to_s.downcase} (#{path})"
      io.puts ""

      action = package_action(channel)
      if package_managed?(channel)
        io.puts action[:message]
        if cmd = action[:command]
          io.puts "  #{cmd}"
          io.puts ""
          if exec_package_commands
            tool = cmd.split.first
            if Process.find_executable(tool)
              io.puts "Running: #{cmd}"
              status = Process.run(cmd, shell: true, output: io, error: err)
              unless status.success?
                raise Error.new("#{cmd} failed (exit #{status.exit_code})")
              end
            else
              io.puts "(#{tool} not found on PATH — run the command above yourself)"
            end
          else
            io.puts "Re-run with --exec to run the command above automatically." if cmd
          end
        end
      else
        io.puts action[:message]
        io.puts ""
        update_binary(path, io, err, release_json: release_json)
      end
    end
  end
end
