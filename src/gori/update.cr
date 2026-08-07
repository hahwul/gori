require "http/client"
require "json"
require "uri"
require "file_utils"
require "random/secure"
require "digest/sha256"

module Gori
  # Channel-aware self-update for `gori update`.
  #
  # Pure helpers (channel detection, asset naming, release JSON parsing) are
  # unit-tested with injected paths/fixtures. I/O (HTTP, filesystem, Process)
  # lives in the methods used by the CLI entrypoint.
  module Update
    GITHUB_REPO   = "hahwul/gori"
    API_LATEST    = "https://api.github.com/repos/#{GITHUB_REPO}/releases/latest"
    RELEASES_URL  = "#{REPOSITORY_URL}/releases"
    USER_AGENT    = "gori/#{VERSION} (+#{REPOSITORY_URL})"
    MAX_REDIRECTS = 10
    HTTP_TIMEOUT  = 60.seconds
    # api.github.com caps unauthenticated callers at 60 requests/hour per IP and
    # answers 403 once that is spent — a shared NAT/CI egress IP burns it fast.
    # This endpoint is the plain web one, not the API, so it carries no such cap:
    # it 302s to .../releases/tag/<tag>, which is enough to name the release.
    RELEASES_LATEST_URL = "#{RELEASES_URL}/latest"
    DOWNLOAD_BASE       = "#{RELEASES_URL}/download"
    # A PAT lifts the API cap to 5000/hour. Checked in order, first non-empty wins.
    TOKEN_ENVS = %w[GORI_GITHUB_TOKEN GITHUB_TOKEN GH_TOKEN]
    # Short timeout for the TUI startup update check (background, best-effort) so a
    # slow/hung GitHub never keeps a fiber alive for a full minute. The explicit
    # `gori update` flow keeps HTTP_TIMEOUT.
    UPDATE_CHECK_TIMEOUT = 8.seconds
    # Download progress meter
    PROGRESS_BAR_WIDTH    = 24
    PROGRESS_CHUNK        = 64 * 1024
    PROGRESS_MIN_INTERVAL = 100.milliseconds
    # Env override for local mock release servers (scripts/mock_update_server.cr).
    UPDATE_API_ENV = "GORI_UPDATE_API_URL"
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
      Nix
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
    # The Nix store is checked first: it is the one root that is *immutable*, so a
    # self-update there cannot even be attempted (and `~/.nix-profile/bin/gori` is a
    # symlink chain the caller's `File.realpath` has already resolved into it).
    #
    # For FHS system bins (`/usr/bin`, `/bin`):
    # - owned by pacman/dpkg/rpm → that package channel (never overwrite)
    # - probed and **not** owned → Binary (manual copy; self-update allowed)
    # - unprobed → fall back to os-release family for package guidance, else Binary
    def self.detect_channel(exe_path : String, *,
                            owner : OwnerResult = OwnerResult::Unknown,
                            os_family : OsFamily = OsFamily::Unknown) : Channel
      return Channel::Nix if nix_path?(exe_path)
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

    # Covers every Nix entry point — `nix profile`, `nix run`, NixOS/home-manager —
    # because all of them ultimately resolve to a store path. Kept to the default
    # store location (a relocated NIX_STORE_DIR would degrade to Binary, which the
    # read-only store then rejects with a plain permission error).
    def self.nix_path?(path : String) : Bool
      path.starts_with?("/nix/store/")
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
      when .nix?
        # No `command:` — which one is right depends on how it was installed, and the
        # store is read-only either way, so guessing would be worse than listing them.
        {
          message: "Nix install detected (the store is read-only). Upgrade the way you installed it:\n  nix profile upgrade gori\n  # declarative (NixOS / home-manager): nix flake update gori, then rebuild\n  # one-off run of the latest: nix run github:hahwul/gori",
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
      channel.homebrew? || channel.snap? || channel.pacman? || channel.deb? || channel.rpm? || channel.nix?
    end

    # ---------------------------------------------------------------------------
    # Release asset naming (pure)
    # ---------------------------------------------------------------------------

    def self.normalize_version(version : String) : String
      v = version
      v = v[1..] if v.starts_with?('v') || v.starts_with?('V')
      v
    end

    # One display form for every version `gori update` prints. Release tags come
    # back as `v0.2.0` while `Gori::VERSION` is bare `0.2.0`, so a line that
    # interpolates both raw reads as "Updating 0.1.4 → v0.2.0". Normalize first,
    # then re-add the prefix, so a tag is never rendered as `vv0.2.0`.
    def self.display_version(version : String) : String
      "v#{normalize_version(version)}"
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

    # The version the ProjectPicker should surface as "update available", or nil
    # when nothing fresh should be shown. Pure (unit-tested): `latest` is offered
    # only when it is strictly newer than `local` AND we have not already notified
    # about it (read-once — `notified` is the last version we surfaced). Returns the
    # normalized version so the caller can persist it as the new read-once marker.
    def self.notice_version(local : String, latest : String, notified : String) : String?
      return nil if latest.empty?
      return nil unless version_cmp(local, latest) < 0
      norm = normalize_version(latest)
      return nil if norm == normalize_version(notified)
      norm
    end

    # Release asset basename for platform (matches PR #114 / hwaro parity).
    # Linux: plain binary `gori-v{ver}-linux-{x86_64|arm64}`
    # macOS: tarball `gori-v{ver}-osx-{arm64|x86_64}.tar.gz` (contains gori + lib/)
    def self.asset_name(version : String, os : String, arch : String) : String
      release_asset_name("v#{normalize_version(version)}-", os, arch)
    end

    # The version-less copy release-binary.yml publishes beside every versioned
    # asset ("Create version-less alias assets"). It exists so a client that only
    # *guessed* the versioned filename from a tag has a second name to try — see
    # the 404 retry in update_binary.
    def self.alias_asset_name(os : String = current_os, arch : String = current_arch) : String
      release_asset_name("", os, arch)
    end

    private def self.release_asset_name(version_part : String, os : String, arch : String) : String
      arch_n = normalize_arch(arch)
      case normalize_os(os)
      when "linux"
        "gori-#{version_part}linux-#{arch_n}"
      when "osx"
        "gori-#{version_part}osx-#{arch_n}.tar.gz"
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

    # An asset the release does not actually carry (HTTP 404), as distinct from
    # every other download failure. Split out so the version-less alias retry in
    # update_binary fires for exactly that case: a checksum mismatch or a
    # truncated transfer must never be retried under a second name.
    class AssetNotFound < Error
    end

    struct Asset
      getter name : String
      getter browser_download_url : String
      getter size : Int64
      # GitHub asset digest as advertised by the releases API, e.g.
      # "sha256:<hex>" (nil on older API responses / GHE / mock fixtures).
      getter digest : String?

      def initialize(@name : String, @browser_download_url : String,
                     @size : Int64 = 0_i64, @digest : String? = nil)
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
      data = begin
        JSON.parse(json_body)
      rescue ex : JSON::ParseException
        raise Error.new("could not parse release information (server did not return valid JSON): #{ex.message}")
      end
      # Valid JSON with a non-object root ([], null, a bare string/number) would otherwise
      # make `data["tag_name"]?` raise a BARE Exception — not a Gori::Error — and nothing
      # on the `gori update` path rescues that, so the operator got a backtrace instead of
      # a message. Reachable from any 200 carrying such a body: a captive portal, a GHE
      # mirror, or GORI_UPDATE_API_URL aimed at a list endpoint.
      obj = data.as_h? || raise Error.new(
        "could not parse release information (expected a JSON object, got #{data.raw.class})")
      tag = obj["tag_name"]?.try(&.as_s?)
      raise Error.new("release JSON missing tag_name") unless tag

      assets = [] of Asset
      if arr = obj["assets"]?.try(&.as_a?)
        arr.each do |item|
          name = item["name"]?.try(&.as_s?) || next
          url = item["browser_download_url"]?.try(&.as_s?) || next
          size = item["size"]?.try(&.as_i64?) || 0_i64
          digest = item["digest"]?.try(&.as_s?)
          assets << Asset.new(name, url, size, digest)
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

    # The version-less alias to try after `asset` came back 404, or nil when there
    # is none to try (`asset` already IS the alias, or the release does not list one).
    #
    # A pure lookup on purpose: no URL is ever guessed here. The redirect path puts
    # the alias into its synthesized list up front (see synthesize_release_json),
    # with the digest from the same SHA256SUMS fetch that gave the versioned asset
    # its own — so the retry inherits a real URL and a real checksum instead of
    # reaching back out to the host that just failed us.
    #
    # On the API path the list is authoritative. It can lack the alias — the step
    # that produces it in release-binary.yml is continue-on-error — but that step
    # only *copies* the file; both names then go up in one upload, so an absent
    # alias implies a present versioned asset and we never get here.
    def self.alias_asset(release : Release, asset : Asset, *,
                         os : String = current_os, arch : String = current_arch) : Asset?
      name = alias_asset_name(os, arch)
      return nil if asset.name == name
      release.assets.find { |a| a.name == name }
    rescue
      # alias_asset_name raises on an unsupported OS; there is simply nothing to
      # retry then, and the caller must surface the original 404.
      nil
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
    # Download progress (pure formatters + streaming copy)
    # ---------------------------------------------------------------------------

    # Human-readable byte size with a space before the unit (e.g. "12.4 MB").
    def self.format_size(bytes : Int64) : String
      n = bytes.to_f
      return "#{bytes} B" if n < 1024
      n /= 1024
      return "#{round1(n)} kB" if n < 1024
      n /= 1024
      return "#{round1(n)} MB" if n < 1024
      n /= 1024
      return "#{round1(n)} GB" if n < 1024
      "#{round1(n / 1024)} TB"
    end

    # Elapsed span for download summaries ("850ms", "5.1s").
    def self.format_duration(span : Time::Span) : String
      ms = span.total_milliseconds
      return "#{ms.round.to_i}ms" if ms < 1000
      "#{round1(span.total_seconds)}s"
    end

    # Horizontal block bar of `done/total`, exactly `width` columns.
    # Unknown total (total <= 0) → empty string (caller uses indeterminate line).
    def self.format_progress_bar(done : Int64, total : Int64, width : Int32 = PROGRESS_BAR_WIDTH) : String
      return "" if width <= 0
      return "░" * width if total <= 0
      frac = (done.to_f / total.to_f).clamp(0.0, 1.0)
      filled = (frac * width).round.to_i
      filled = 1 if filled < 1 && done > 0
      filled = width if filled > width
      String.build do |io|
        filled.times { io << '█' }
        (width - filled).times { io << '░' }
      end
    end

    # One progress line (no trailing newline). When total is unknown, omit the bar/%.
    def self.format_progress_line(done : Int64, total : Int64, *,
                                  elapsed : Time::Span = Time::Span::ZERO,
                                  width : Int32 = PROGRESS_BAR_WIDTH) : String
      rate = if elapsed.total_seconds > 0
               format_size((done.to_f / elapsed.total_seconds).round.to_i64) + "/s"
             else
               "—/s"
             end
      if total > 0
        pct = ((done.to_f / total.to_f) * 100).clamp(0.0, 100.0).round.to_i
        bar = format_progress_bar(done, total, width)
        "#{bar}  #{pct.to_s.rjust(3)}%  #{format_size(done)} / #{format_size(total)}  #{rate}"
      else
        "#{format_size(done)}  #{rate}"
      end
    end

    private def self.round1(n : Float64) : String
      ((n * 10).round / 10.0).to_s
    end

    # Stream body_io → dest with optional live progress on a TTY (or when force_progress).
    # Returns bytes written. `on_progress` is always invoked when present (for tests).
    def self.copy_with_progress(body_io : IO, dest : String, total : Int64, *,
                                progress_io : IO? = nil,
                                on_progress : Proc(Int64, Int64, Nil)? = nil,
                                force_progress : Bool = false) : Int64
      show = force_progress || !!(progress_io && progress_io.tty?)
      started = Time.instant
      last_draw = Time.instant - PROGRESS_MIN_INTERVAL # allow first draw immediately
      downloaded = 0_i64
      buf = Bytes.new(PROGRESS_CHUNK)

      begin
        File.open(dest, "w") do |file|
          loop do
            n = body_io.read(buf)
            break if n == 0
            file.write(buf[0, n])
            downloaded += n
            on_progress.try &.call(downloaded, total)

            if show && progress_io
              now = Time.instant
              if now - last_draw >= PROGRESS_MIN_INTERVAL || (total > 0 && downloaded >= total)
                line = format_progress_line(downloaded, total, elapsed: started.elapsed)
                progress_io.print "\r\e[K  #{line}"
                progress_io.flush
                last_draw = now
              end
            end
          end
        end
      ensure
        # In an `ensure`, not after the loop: a reset mid-transfer left the last
        # bar standing and the error message was then printed onto that same
        # line, right after the rate — the one moment the operator most needs to
        # read it. The line belongs to this method either way it exits.
        if show && progress_io
          progress_io.print "\r\e[K"
          progress_io.flush
        end
      end
      downloaded
    end

    # ---------------------------------------------------------------------------
    # Checksum verification (integrity, NOT authenticity — see NOTE)
    # ---------------------------------------------------------------------------
    #
    # NOTE: the digest verified here comes from the SAME release JSON that names
    # the asset. It defeats CDN/transfer tampering and wrong-asset installs (the
    # JSON is fetched over TLS from api.github.com; assets are redirected to a
    # separate CDN host), but it does NOT defeat an attacker who controls the
    # release itself — they would publish a fake tarball AND a matching digest.
    # True authenticity needs a signed checksums file verified against a public
    # key embedded in this binary (release-side infra; not implemented).
    HEX_SHA256 = /\A[0-9a-f]{64}\z/

    # Parse a GitHub asset digest ("sha256:<hex>") into a lowercase 64-char hex
    # string, or nil when absent/unsupported (older API, GHE, non-sha256 algo).
    def self.parse_sha256_digest(digest : String?) : String?
      return nil unless digest
      d = digest.strip.downcase
      return nil unless d.starts_with?("sha256:")
      hex = d.lchop("sha256:")
      HEX_SHA256.matches?(hex) ? hex : nil
    end

    # Parses a `sha256sum`-style SHA256SUMS body into {asset name => hex}. Lines
    # are "<64 hex><spaces><name>", the name optionally prefixed with `*` for
    # binary mode. Anything that does not match that shape is skipped rather than
    # raising — a malformed line must not cost us the checksums we can read.
    def self.parse_checksums(text : String) : Hash(String, String)
      sums = {} of String => String
      text.each_line do |line|
        parts = line.strip.split(/\s+/, 2)
        next unless parts.size == 2
        hex = parts[0].downcase
        next unless HEX_SHA256.matches?(hex)
        name = parts[1].strip.lchop('*')
        sums[name] = hex unless name.empty?
      end
      sums
    end

    # Streamed SHA256 of a file as lowercase hex (constant memory).
    def self.file_sha256(path : String) : String
      digest = Digest::SHA256.new
      io_guard("could not read #{path} to checksum it") do
        File.open(path) do |file|
          buf = Bytes.new(PROGRESS_CHUNK)
          loop do
            n = file.read(buf)
            break if n == 0
            digest.update(buf[0, n])
          end
        end
      end
      digest.hexfinal
    end

    # Verify a downloaded file against the expected sha256 hex; raise on mismatch.
    # No-op when `expected_hex` is nil (release JSON advertised no usable digest)
    # so behavior is preserved against older APIs — keeps this change non-breaking.
    def self.verify_sha256!(path : String, expected_hex : String?, asset_name : String) : Nil
      return unless expected_hex
      actual = file_sha256(path)
      return if actual == expected_hex
      raise Error.new(
        "checksum mismatch for #{asset_name}: expected sha256 #{expected_hex} " \
        "but got #{actual} (download corrupted or tampered in transit)"
      )
    end

    # ---------------------------------------------------------------------------
    # CLI orchestration + I/O
    # ---------------------------------------------------------------------------

    # Turn the I/O failures an updater actually MEETS — no route to GitHub, DNS
    # that does not resolve, a TLS store that cannot verify (#323/#333), a
    # connection reset mid-transfer, a `tar` that is not installed — into the
    # project's expected-error type.
    #
    # CLI.run's rescue is deliberately narrow (see cli.cr): anything that is not
    # a Gori::Error reaches the top of the process as a Crystal backtrace,
    # "because those are bugs and want a trace". Being offline is not a bug, and
    # it is the single likeliest way `gori update` fails — yet that is exactly
    # what it answered with. Only the I/O families are converted here, so a
    # genuine bug still gets its trace.
    #
    # Gori::Error descends straight from Exception, so the errors this module
    # raises on purpose (including AssetNotFound, which the alias retry rescues
    # by type) pass through untouched.
    private def self.io_guard(what : String, &)
      yield
    rescue ex : IO::Error | OpenSSL::Error
      raise Error.new("#{what}: #{ex.message.presence || ex.class}")
    end

    def self.resolve_executable_path : String
      path = Process.executable_path
      raise Error.new("could not determine the running gori executable path") unless path
      File.realpath(path)
    rescue ex : File::Error
      # The running binary was moved or deleted underneath us (a package manager
      # upgrading it, a concurrent `gori update`). File::Error is not a
      # Gori::Error, so this used to be the first thing `gori update` did and the
      # first way it could backtrace.
      raise Error.new(
        "could not resolve the running gori executable: #{ex.message.presence || ex.class} " \
        "(it may have been moved or deleted while running)"
      )
    end

    private def self.http_client(host : String, port : Int32, tls : Bool,
                                 timeout : Time::Span = HTTP_TIMEOUT) : HTTP::Client
      # When tls is a bare `true`, HTTP::Client builds OpenSSL::SSL::Context::Client.new
      # with only the compiled-in OPENSSLDIR store. A static-musl release binary's store
      # is often empty (#323/#333) — exactly the environment `gori update` exists to
      # serve (Channel::Binary). Apply the same system-trust repair the proxy uses so
      # GitHub HTTPS verification works out of the box; additive and rescue-guarded.
      client = if tls
                 ctx = OpenSSL::SSL::Context::Client.new
                 Proxy::Upstream.apply_system_trust(ctx)
                 HTTP::Client.new(host, port, ctx)
               else
                 HTTP::Client.new(host, port, false)
               end
      client.connect_timeout = timeout
      client.read_timeout = timeout
      client
    end

    # Best-effort latest published release version (normalized, no leading `v`), or
    # nil on ANY failure (offline, rate-limited, malformed). Used by the TUI startup
    # update check — never raises into the caller, uses UPDATE_CHECK_TIMEOUT.
    def self.latest_version(api_url : String? = nil,
                            timeout : Time::Span = UPDATE_CHECK_TIMEOUT) : String?
      parse_release(fetch_latest_release_json(api_url, timeout: timeout)).version
    rescue
      # Rate-limited or offline. This check only needs a version number, and the
      # redirect endpoint still supplies one, so the notice survives a spent quota.
      return nil unless default_api?(api_url)
      resolve_tag_via_redirect(timeout).try { |tag| normalize_version(tag) }
    end

    # Resolves the releases API URL: explicit arg → env override → GitHub default.
    def self.resolve_api_url(api_url : String? = nil) : String
      api_url || ENV[UPDATE_API_ENV]? || API_LATEST
    end

    # True only when we are talking to the real GitHub API rather than a mock
    # server injected by a spec or GORI_UPDATE_API_URL. The redirect fallback
    # targets github.com specifically, so it must not fire for those.
    def self.default_api?(api_url : String? = nil) : Bool
      resolve_api_url(api_url) == API_LATEST
    end

    # First non-empty value among TOKEN_ENVS, or nil.
    def self.github_token : String?
      TOKEN_ENVS.each do |name|
        value = ENV[name]?.try(&.strip)
        return value if value && !value.empty?
      end
      nil
    end

    # Tag out of a /releases/latest redirect Location, or nil when the target is
    # not a release page. A repo with no published release redirects to plain
    # /releases, so requiring the /releases/tag/ segment is what stops this path
    # from inventing a tag out of an unrelated redirect.
    def self.tag_from_release_location(location : String?) : String?
      return nil unless location
      loc = location.strip
      return nil unless loc.includes?("/releases/tag/")
      tag = loc.rpartition("/releases/tag/")[2]
      # Drop anything GitHub might append after the tag.
      tag = tag.partition('?')[0].partition('#')[0].partition('/')[0]
      tag.empty? ? nil : tag
    end

    # Names the latest release from the web redirect instead of the API: no
    # quota, but the tag is all we learn (no asset list, no size, no digest).
    # Returns nil on any failure — callers treat that as "fallback unavailable".
    def self.resolve_tag_via_redirect(timeout : Time::Span = HTTP_TIMEOUT) : String?
      uri = URI.parse(RELEASES_LATEST_URL)
      host = uri.host
      return nil unless host
      port = uri.port || (uri.scheme == "https" ? 443 : 80)
      client = http_client(host, port, uri.scheme == "https", timeout)
      begin
        response = client.head(uri.request_target,
          headers: HTTP::Headers{"User-Agent" => USER_AGENT})
        return nil unless {301, 302, 303, 307, 308}.includes?(response.status_code)
        tag_from_release_location(response.headers["Location"]?)
      ensure
        client.close
      end
    rescue
      nil
    end

    # Stand-in for the API payload, built from a tag alone, so the redirect path
    # can reuse parse_release/resolve_asset_from_json unchanged. Asset names are
    # derived exactly as release-binary.yml builds them. Digests come from the
    # release's SHA256SUMS when it has them; without one verify_sha256! no-ops, so
    # the caller warns that the checksum check was skipped (see update_binary).
    #
    # Lists the version-less alias alongside the versioned asset because the
    # versioned name here is a GUESS made from a tag read out of a Location header.
    # When that guess is wrong the versioned name 404s and the alias — which
    # carries no version to get wrong — is the one name still worth trying, so it
    # has to already be in the list the retry looks through.
    def self.synthesize_release_json(tag : String, os : String = current_os,
                                     arch : String = current_arch,
                                     digest : String? = nil,
                                     alias_digest : String? = nil) : String
      entries = [] of {String, String?}
      entries << {asset_name(tag, os, arch), digest}
      # Guarded: alias_asset_name shares asset_name's unsupported-OS raise, and
      # having reached here at all means the versioned name resolved fine.
      if alias_name = (alias_asset_name(os, arch) rescue nil)
        entries << {alias_name, alias_digest}
      end
      JSON.build do |json|
        json.object do
          json.field "tag_name", tag
          json.field "assets" do
            json.array do
              entries.each do |(name, hex)|
                json.object do
                  json.field "name", name
                  json.field "browser_download_url", "#{DOWNLOAD_BASE}/#{tag}/#{name}"
                  json.field "digest", "sha256:#{hex}" if hex
                end
              end
            end
          end
        end
      end
    end

    # {asset name => sha256} from the release's SHA256SUMS, empty when the release
    # publishes none / the fetch fails. Only needed on the redirect fallback: the
    # API hands us a per-asset digest directly, but it is the API that is
    # unavailable there, and SHA256SUMS travels the same no-quota download path.
    #
    # Fetched once and returned whole rather than looked up per name, because that
    # one file already covers BOTH the versioned asset and its version-less alias
    # (release-binary.yml emits a line for each). Re-fetching it for the alias would
    # mean a second round trip on the one code path where GitHub is already known
    # to be failing — and a transient failure there would silently downgrade the
    # alias to no checksum at all, after we had told the operator we would verify.
    def self.fetch_checksums(tag : String) : Hash(String, String)
      body : String? = nil
      with_tempdir("gori-sums-") do |dir|
        dest = File.join(dir, "SHA256SUMS")
        download_to("#{DOWNLOAD_BASE}/#{tag}/SHA256SUMS", dest)
        body = File.read(dest)
      end
      body.try { |text| parse_checksums(text) } || {} of String => String
    rescue
      {} of String => String
    end

    # fetch_latest_release_json, but when GitHub refuses (rate limit, outage) it
    # names the release through the redirect endpoint instead. Returns the JSON
    # and whether it came from that fallback, so the caller can say so.
    #
    # Falls back on any fetch error rather than only 403: resolve_tag_via_redirect
    # validates its own answer, so a genuine "no releases" still surfaces the
    # original error instead of being papered over.
    def self.fetch_latest_release_json_with_fallback(api_url : String? = nil, *,
                                                     timeout : Time::Span = HTTP_TIMEOUT) : {String, Bool}
      {fetch_latest_release_json(api_url, timeout: timeout), false}
    rescue ex
      raise ex unless default_api?(api_url)
      tag = resolve_tag_via_redirect(timeout)
      raise ex unless tag
      sums = fetch_checksums(tag)
      alias_name = (alias_asset_name(current_os, current_arch) rescue nil)
      {synthesize_release_json(tag,
        digest: sums[asset_name(tag, current_os, current_arch)]?,
        alias_digest: alias_name.try { |n| sums[n]? }), true}
    end

    # Maps a non-200 releases-API status onto the error we surface. Split out of
    # fetch_latest_release_json so the status ladder does not dominate it.
    private def self.api_error(status : Int32, body : String) : Error
      case status
      when 404
        Error.new("no GitHub releases found for #{GITHUB_REPO} — see #{RELEASES_URL}")
      when 401
        Error.new("GitHub API rejected the token (HTTP 401) — check #{TOKEN_ENVS.join('/')}")
      when 403, 429
        Error.new(
          "GitHub API rate limit reached (HTTP #{status}; unauthenticated callers get " \
          "60 requests/hour per IP) — retry shortly, or set GITHUB_TOKEN to raise it to 5000/hour"
        )
      else
        snippet = body.lines.first?.try { |l| l.size > 200 ? l[0, 200] : l } || ""
        Error.new("GitHub releases API returned HTTP #{status}#{snippet.empty? ? "" : ": #{snippet}"}")
      end
    end

    def self.fetch_latest_release_json(api_url : String? = nil, *,
                                       timeout : Time::Span = HTTP_TIMEOUT) : String
      url = resolve_api_url(api_url)
      uri = URI.parse(url)
      headers = HTTP::Headers{
        "Accept"     => "application/vnd.github+json",
        "User-Agent" => USER_AGENT,
      }
      host = uri.host || raise Error.new("invalid API URL: #{url}")
      # Gated on the host, not on resolve_api_url: a token must never travel to a
      # mock server or any other endpoint someone points GORI_UPDATE_API_URL at.
      if host == "api.github.com" && (token = github_token)
        headers["Authorization"] = "Bearer #{token}"
      end
      port = uri.port || (uri.scheme == "https" ? 443 : 80)
      tls = uri.scheme == "https"
      client = http_client(host, port, tls, timeout)
      begin
        response = io_guard("could not reach #{host}") do
          client.get(uri.request_target, headers: headers)
        end
        raise api_error(response.status_code, response.body) unless response.status_code == 200
        response.body
      ensure
        client.close
      end
    end

    def self.download_to(url : String, dest : String, redirects_left : Int32 = MAX_REDIRECTS, *,
                         expected_size : Int64 = 0_i64,
                         progress_io : IO? = nil,
                         on_progress : Proc(Int64, Int64, Nil)? = nil,
                         force_progress : Bool = false) : Int64
      raise Error.new("too many redirects downloading #{url}") if redirects_left < 0

      uri = URI.parse(url)
      host = uri.host || raise Error.new("invalid download URL: #{url}")
      port = uri.port || (uri.scheme == "https" ? 443 : 80)
      tls = uri.scheme == "https"
      headers = HTTP::Headers{"User-Agent" => USER_AGENT}

      client = http_client(host, port, tls)
      begin
        # Capture result outside the HTTP block (block return is not always the method return).
        result = 0_i64
        redirect_url : String? = nil
        # Guards the whole streamed exchange, not just the connect: a reset or a
        # read timeout part-way through tens of MB is the commonest way this
        # fails, and it surfaces from inside the block.
        io_guard("could not download #{url}") do
          client.get(uri.request_target, headers: headers) do |response|
            code = response.status_code
            if {301, 302, 303, 307, 308}.includes?(code)
              location = response.headers["Location"]?
              raise Error.new("redirect without Location from #{url}") unless location
              response.body_io.gets_to_end
              # Resolve relative redirects against the current URL.
              redirect_url = location.starts_with?("http://") || location.starts_with?("https://") ? location : URI.parse(url).resolve(location).to_s
              next
            end
            unless code == 200
              response.body_io.gets_to_end
              # 404 gets its own type: it is the one status that means "this exact
              # name is not in the release", which is the only thing worth retrying
              # under the version-less alias.
              raise AssetNotFound.new("download failed HTTP 404 for #{url}") if code == 404
              raise Error.new("download failed HTTP #{code} for #{url}")
            end
            cl = response.headers["Content-Length"]?.try(&.to_i64?) || 0_i64
            total = cl > 0 ? cl : expected_size
            result = copy_with_progress(response.body_io, dest, total,
              progress_io: progress_io,
              on_progress: on_progress,
              force_progress: force_progress)
            # Verify against the ACTUAL HTTP Content-Length header, not just whatever
            # size the (unauthenticated) release JSON claims. A truncated/interrupted
            # transfer must never be silently accepted just because the JSON's `size`
            # field is 0 or wrong — this is the one completeness signal the server
            # can't lie about without also lying to every other HTTP client.
            if cl > 0 && result != cl
              File.delete?(dest)
              raise Error.new(
                "download truncated for #{url}: expected #{cl} bytes (Content-Length) but received #{result}"
              )
            end
          end
        end
        if next_url = redirect_url
          return download_to(next_url, dest, redirects_left - 1,
            expected_size: expected_size,
            progress_io: progress_io,
            on_progress: on_progress,
            force_progress: force_progress)
        end
        result
      ensure
        client.close
      end
    end

    # Put `source` in place of `target` without ever writing into the live target
    # file: copy to a sibling temp, chmod, then rename over it. The rename is
    # atomic within the directory, so a failure at any step leaves the binary that
    # is currently installed exactly as it was.
    #
    # There is deliberately NO in-place `cp source, target` fallback. `tmp` is
    # created in `File.dirname(target)`, so it is on the target's own filesystem and
    # the cross-device rename such a fallback claimed to rescue does not arise —
    # the one exception being a target that is itself a bind mountpoint (a
    # single-file `docker run -v` of the binary), where rename gives EBUSY/EXDEV.
    # That layout loses its self-update and gets a clear error instead, which is
    # the better trade: what the fallback actually did was truncate the running
    # binary and, if the write then died (ENOSPC/EIO), leave a corrupt gori behind
    # — turning a clean, non-destructive failure into a destructive one.
    #
    # Rescues every exception rather than only File::Error: a copy that fails
    # part-way with, say, IO::Error would otherwise strand `tmp` next to the binary.
    def self.atomic_install(source : String, target : String) : Nil
      dir = File.dirname(target)
      # Outside the `begin` below, so it needs its own guard: install_dir_writable?
      # deliberately passes a directory that does not exist yet ("atomic_install
      # creates it"), and creating it fails for real — an unwritable parent, or a
      # plain file sitting at that path.
      io_guard("could not create the install directory #{dir}") { Dir.mkdir_p(dir) }
      # Before staging a new one, clear temps an earlier run never got to rename.
      # The `rescue` below only runs when the copy raises — Crystal's default
      # SIGINT terminates without unwinding, so a Ctrl-C during the copy (or a
      # kill, or a power loss) strands a full ~40 MB duplicate of the binary in
      # the operator's install directory, and every retry adds another. lib/
      # already sweeps its own leftovers; this is the same sweep for the binary.
      sweep_install_leftovers(dir)
      tmp = File.join(dir, "#{INSTALL_TMP_PREFIX}#{Process.pid}.#{Random::Secure.hex(4)}")
      begin
        FileUtils.cp(source, tmp)
        File.chmod(tmp, 0o755)
        File.rename(tmp, target)
      rescue ex
        File.delete?(tmp)
        raise Error.new(
          "failed to install binary to #{target}: #{ex.message} " \
          "(the binary already installed there was left untouched)"
        )
      end
    end

    # Remove `.gori-update.*` siblings stranded by an interrupted run.
    #
    # Matched by prefix over Dir.children rather than by Dir.glob, for the reason
    # sweep_lib_leftovers gives: the install path is the operator's, and a `[`,
    # `*` or `?` in it would make a glob both miss the real leftovers and rm
    # entries it was never meant to see. The prefix starts with a dot and the
    # installed binary is `gori`, so the target itself can never match.
    #
    # A concurrent `gori update` could have its in-flight temp swept here. That
    # costs the loser a clean "failed to install" — the installed binary is never
    # touched — which is the right trade against leaving the copies to pile up.
    private def self.sweep_install_leftovers(dir : String) : Nil
      Dir.children(dir).each do |name|
        File.delete?(File.join(dir, name)) if name.starts_with?(INSTALL_TMP_PREFIX)
      end
    rescue
      # A leftover we cannot clear is cosmetic; never fail an update over it.
    end

    # `atomic_install` renames a sibling temp file over the target, so replacing
    # gori needs a writable *directory* — the mode of the binary itself is
    # irrelevant. Checked before the download because the asset is tens of MB and
    # "permission denied" is otherwise only discovered once all of it is on disk.
    def self.install_dir_writable?(target_path : String) : Bool
      dir = File.dirname(File.expand_path(target_path))
      return true unless File.directory?(dir) # atomic_install creates it
      File::Info.writable?(dir)
    end

    # Crystal has no Dir.mktmpdir; create a unique dir under Dir.tempdir and clean up.
    private def self.with_tempdir(prefix : String, &)
      dir = File.tempname(prefix, "")
      # A TMPDIR that has been removed, or points somewhere unwritable, is an
      # operator condition and gets a message like every other one.
      io_guard("could not create a temporary directory under #{File.dirname(dir)}") do
        Dir.mkdir_p(dir)
      end
      begin
        yield dir
      ensure
        # Rescued so a tempdir we cannot clear — which is cosmetic — never
        # replaces the real exception on the way out.
        begin
          FileUtils.rm_rf(dir) if File.exists?(dir)
        rescue
        end
      end
    end

    # `tar` is assumed present, and on a minimal image it is not: Process.run
    # raises File::NotFoundError rather than returning a failed status, which is
    # not a Gori::Error and so backtraced out of the macOS archive install.
    def self.list_tar_entries(archive : String) : String
      listing = IO::Memory.new
      tar_err = IO::Memory.new
      status = io_guard("could not run tar") do
        Process.run("tar", ["tzf", archive], output: listing, error: tar_err)
      end
      raise Error.new("tar list failed: #{tar_err}") unless status.success?
      listing.to_s
    end

    def self.extract_tar(archive : String, dest_dir : String) : Nil
      assert_safe_tar_listing(list_tar_entries(archive))
      tar_err = IO::Memory.new
      status = io_guard("could not run tar") do
        Process.run("tar", ["xzf", archive, "-C", dest_dir],
          output: Process::Redirect::Close, error: tar_err)
      end
      raise Error.new("tar extract failed: #{tar_err}") unless status.success?
    end

    LIB_BACKUP_SUFFIX  = ".gori-old."
    LIB_STAGING_SUFFIX = ".gori-new."
    # Sibling temp atomic_install renames over the target (see sweep_install_leftovers).
    INSTALL_TMP_PREFIX = ".gori-update."

    # Replace lib/ only at a verified-safe destination. Stages to a temp name then renames.
    #
    # Returns where the previous lib/ was moved to, or nil when there was none.
    # The backup is NOT deleted here: the caller owns it until the new binary is
    # in place too (see install_from_download), because a failed binary install is
    # exactly when the old dylibs have to come back.
    def self.replace_lib_dir(lib_src : String, lib_dst : String) : String?
      raise Error.new("refusing to install lib/ at unsafe path: #{lib_dst}") if forbidden_lib_destination?(lib_dst)

      parent = File.dirname(lib_dst)
      io_guard("could not create #{parent} for the bundled lib/") { Dir.mkdir_p(parent) }

      # Half-copied staging trees are always garbage, so they go unconditionally.
      # Backups do NOT: if a previous run died between renaming lib/ aside and
      # renaming the new one in, that backup is the ONLY surviving copy of the
      # installed dylibs and deleting it here would destroy them for good. It is
      # redundant — and only then — when lib/ is standing, which is the window
      # this sweep exists for (a run killed after the swap but before the binary).
      sweep_lib_leftovers(lib_dst, LIB_STAGING_SUFFIX)
      sweep_lib_leftovers(lib_dst, LIB_BACKUP_SUFFIX) if File.exists?(lib_dst)

      staged = "#{lib_dst}#{LIB_STAGING_SUFFIX}#{Process.pid}.#{Random::Secure.hex(4)}"
      backup = "#{lib_dst}#{LIB_BACKUP_SUFFIX}#{Process.pid}.#{Random::Secure.hex(4)}"
      moved = false
      begin
        # Inside the begin: a cp_r that dies on ENOSPC part-way through would
        # otherwise strand a half-copied dylib tree next to the live install, and
        # every retry would add another one under a fresh pid.
        FileUtils.cp_r(lib_src, staged)
        if File.exists?(lib_dst)
          File.rename(lib_dst, backup)
          moved = true
        end
        File.rename(staged, lib_dst)
        moved ? backup : nil
      rescue ex
        # Best-effort restore
        FileUtils.rm_rf(staged) if File.exists?(staged)
        if moved && File.exists?(backup) && !File.exists?(lib_dst)
          File.rename(backup, lib_dst) rescue nil
        end
        raise Error.new("failed to install bundled lib/ to #{lib_dst}: #{ex.message}")
      end
    end

    # Undo what replace_lib_dir did. `backup` nil means there was no previous lib/,
    # so reverting means removing the one we just installed. Returns whether the
    # tree is back the way it was — the caller puts that in its error on purpose,
    # since a silent failure here leaves new dylibs beside an old binary, the one
    # state the operator cannot fix without a full reinstall.
    def self.restore_lib_dir(lib_dst : String, backup : String?) : Bool
      # Check before deleting: losing the new lib/ AND having no backup to put
      # back is strictly worse than leaving the swap in place.
      return false if backup && !File.exists?(backup)
      FileUtils.rm_rf(lib_dst) if File.exists?(lib_dst)
      File.rename(backup, lib_dst) if backup
      true
    rescue
      false
    end

    # Remove `lib<suffix>*` siblings stranded by an interrupted run. Never touches
    # lib/ itself.
    #
    # Matches by prefix over Dir.children rather than by Dir.glob: the install path
    # is the operator's, and a prefix containing `[`, `*` or `?` would make a glob
    # both miss the real leftovers and rm_rf entries under sibling directories it
    # was never meant to see.
    private def self.sweep_lib_leftovers(lib_dst : String, suffix : String) : Nil
      parent = File.dirname(lib_dst)
      prefix = "#{File.basename(lib_dst)}#{suffix}"
      Dir.children(parent).each do |name|
        FileUtils.rm_rf(File.join(parent, name)) if name.starts_with?(prefix)
      end
    rescue
      # A leftover we cannot clear is cosmetic; never fail an update over it.
    end

    # The `gori` binary inside an extracted archive: at the top level normally,
    # otherwise the first match anywhere in the tree that is not itself a slip path.
    private def self.extracted_binary(dir : String) : String
      top = File.join(dir, "gori")
      return top if File.file?(top)
      found = Dir.glob(File.join(dir, "**", "gori")).find do |p|
        File.file?(p) && File.basename(p) == "gori" && !unsafe_tar_entry?(p.lchop(dir).lchop('/'))
      end
      raise Error.new("archive did not contain a gori binary") unless found
      found
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

          new_bin = extracted_binary(dir)
          lib_src = File.join(File.dirname(new_bin), "lib")
          # Install lib first so a failed lib step never leaves a new binary without
          # dylibs — but hold on to the tree it displaced until the binary is in
          # place too. The reverse failure (new dylibs, old binary) breaks just as
          # hard when a bundled dylib's basename changed between releases, and it
          # used to be unrecoverable: replace_lib_dir deleted the backup on success
          # and with_tempdir then swept away the new binary on the way out.
          swapped = Dir.exists?(lib_src)
          backup = swapped ? replace_lib_dir(lib_src, lib_dst) : nil

          begin
            atomic_install(new_bin, target_path)
          rescue ex
            raise swapped ? lib_rollback_error(ex, lib_dst, backup) : ex
          end

          # Rescued: the update has fully succeeded by now, and a backup we cannot
          # reclaim (NFS silly-rename, a held-open file) must not turn that into a
          # backtrace that suppresses the "Installed …" line and reads as failure.
          begin
            FileUtils.rm_rf(backup) if backup && File.exists?(backup)
          rescue
          end
        end
      else
        atomic_install(downloaded, target_path)
      end
    end

    # Roll the lib/ swap back after the binary install failed, and say in the error
    # whether that worked. Whether it worked is the whole message: a rollback that
    # succeeded means the installed gori still runs and the user can just retry,
    # while one that failed means they are looking at a gori that may not start.
    private def self.lib_rollback_error(ex : Exception, lib_dst : String, backup : String?) : Error
      if restore_lib_dir(lib_dst, backup)
        Error.new("#{ex.message} — the bundled lib/ was rolled back, so the installed gori is unchanged")
      else
        Error.new(
          "#{ex.message} — and the bundled lib/ at #{lib_dst} could NOT be rolled back, " \
          "so the installed gori may no longer start. Re-run `gori update`, or reinstall: " \
          "curl -fsSL https://gori.hahwul.com/install.sh | bash"
        )
      end
    end

    # Post-download integrity gate: non-empty, matches the size the release
    # advertised, and matches its sha256 when the API supplied a digest. The
    # digest is absent on the redirect fallback, where verify_sha256! no-ops.
    private def self.verify_download!(dest : String, asset : Asset, got : Int64, io : IO, *,
                                      announce_skip : Bool = false) : Nil
      raise Error.new("downloaded asset is empty: #{asset.name}") unless got > 0
      if asset.size > 0 && got != asset.size
        raise Error.new("downloaded size mismatch for #{asset.name}: expected #{asset.size} bytes, got #{got}")
      end
      if expected_sha = parse_sha256_digest(asset.digest)
        io.puts "Verifying sha256 checksum"
        verify_sha256!(dest, expected_sha, asset.name)
      elsif announce_skip
        # Said HERE rather than beside the "resolved via redirect" note, because
        # only here is `asset` the one that actually came down. download_asset
        # can swap in the version-less alias, which carries its own SHA256SUMS
        # entry — so the note used to be read off an asset that was never
        # installed and could claim a skip for a download it then verified.
        io.puts "Note: #{asset.name} has no SHA256SUMS entry in this release, so sha256 verification is skipped."
      end
    end

    # Download `asset` into `dir`; if the release does not carry that exact name,
    # retry once under the version-less alias. Returns the file written, the asset
    # it actually came from, and its byte count.
    #
    # Only a 404 triggers the retry. A truncated transfer or a checksum mismatch
    # means the asset IS there and came back wrong — fetching it under a second
    # name would paper over the signal the integrity checks exist to raise.
    private def self.download_asset(release : Release, asset : Asset, dir : String, io : IO, *,
                                    force_progress : Bool) : {String, Asset, Int64}
      dest = File.join(dir, asset.name)
      got = download_to(asset.browser_download_url, dest,
        expected_size: asset.size, progress_io: io, force_progress: force_progress)
      {dest, asset, got}
    rescue ex : AssetNotFound
      # A 404 is not proof the release is unusable: the redirect fallback only ever
      # GUESSED this filename from a tag. release-binary.yml publishes a
      # version-less copy of every asset for exactly this second chance, and
      # install.sh has taken it since #345 — this is the same retry for
      # `gori update`, which until now simply died here.
      fallback = alias_asset(release, asset)
      raise ex unless fallback
      io.puts "#{asset.name} is not in #{display_version(release.tag_name)};"
      io.puts "retrying the version-less alias #{fallback.name}"
      dest = File.join(dir, fallback.name)
      got = download_to(fallback.browser_download_url, dest,
        expected_size: fallback.size, progress_io: io, force_progress: force_progress)
      {dest, fallback, got}
    end

    def self.update_binary(target_path : String, io : IO = STDOUT, _err : IO = STDERR, *,
                           release_json : String? = nil,
                           api_url : String? = nil,
                           force_progress : Bool = false) : Nil
      json, via_redirect = if provided = release_json
                             {provided, false}
                           else
                             fetch_latest_release_json_with_fallback(api_url)
                           end
      release = parse_release(json)
      ver = release.version
      local = normalize_version(VERSION)

      cmp = version_cmp(local, ver)
      if cmp == 0
        io.puts "Already up to date (#{display_version(ver)})."
        return
      end
      if cmp > 0
        io.puts "Local version #{display_version(local)} is newer than latest release #{display_version(release.tag_name)}; not downgrading."
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

      # Same reason, same place: an unwritable install directory is knowable now,
      # and finding out after pulling tens of MB is the difference between a
      # one-line error and a wasted download on a metered link.
      unless install_dir_writable?(target_path)
        raise Error.new(
          "cannot write to #{File.dirname(target_path)} — `gori update` installs by renaming " \
          "a new file into that directory. Re-run as its owner (e.g. `sudo gori update`), or " \
          "reinstall under a writable prefix: " \
          "GORI_INSTALL_PREFIX=\"$HOME/.local\" curl -fsSL https://gori.hahwul.com/install.sh | bash"
        )
      end

      if via_redirect
        io.puts "Note: the GitHub release API was unavailable (rate limit or outage);"
        io.puts "      resolved #{display_version(release.tag_name)} from #{RELEASES_LATEST_URL} instead."
      end

      io.puts "Updating #{display_version(VERSION)} → #{display_version(ver)}"
      size_note = asset.size > 0 ? " (#{format_size(asset.size)})" : ""
      io.puts "Downloading #{asset.name}#{size_note}"

      with_tempdir("gori-dl-") do |dir|
        started = Time.instant
        dest, asset, got = download_asset(release, asset, dir, io, force_progress: force_progress)
        verify_download!(dest, asset, got, io, announce_skip: via_redirect)
        io.puts "Downloaded #{format_size(got)} in #{format_duration(started.elapsed)}"
        install_from_download(dest, target_path, asset_is_archive?(asset.name))
      end

      io.puts "Installed #{display_version(release.tag_name)} → #{target_path}"
      if current_os == "osx"
        io.puts "Note: macOS release keeps gori and lib/ side by side under #{File.dirname(target_path)}."
      end
    end

    # Entry used by `gori update`. Raises `Gori::Error` on failure (CLI aborts).
    # Package-manager commands are print-only unless `exec_package_commands` is true
    # (CLI: `gori update --exec`).
    #
    # Tests inject `owner` / `os_family` to avoid live package-manager probes.
    # `api_url` / `GORI_UPDATE_API_URL` point the releases API at a mock server.
    def self.run(io : IO = STDOUT, err : IO = STDERR, *,
                 exe_path : String? = nil,
                 release_json : String? = nil,
                 api_url : String? = nil,
                 exec_package_commands : Bool = false,
                 owner : OwnerResult? = nil,
                 os_family : OsFamily? = nil,
                 force_progress : Bool = false) : Nil
      path = exe_path || resolve_executable_path
      resolved_owner = owner || (system_package_path?(path) ? probe_package_owner(path) : OwnerResult::None)
      resolved_family = os_family || load_os_family
      channel = detect_channel(path, owner: resolved_owner, os_family: resolved_family)

      io.puts "gori #{display_version(VERSION)}"
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
              status = io_guard("could not run #{cmd}") do
                Process.run(cmd, shell: true, output: io, error: err)
              end
              unless status.success?
                raise Error.new("#{cmd} failed (exit #{status.exit_code})")
              end
            else
              io.puts "(#{tool} not found on PATH — run the command above yourself)"
            end
          else
            io.puts "Re-run with --exec to run the command above automatically."
          end
        elsif exec_package_commands
          # pacman/deb/rpm/nix deliberately carry no single auto-runnable command
          # (which of them is right depends on the AUR helper / how nix installed
          # it, and the others need sudo). That left `--exec` printing NOTHING
          # about itself on those channels, so it read as having run something.
          io.puts ""
          io.puts "(--exec has nothing to run on the #{channel.to_s.downcase} channel: " \
                  "the upgrade needs a privileged or interactive command, so run one of the lines above yourself.)"
        end
      else
        io.puts action[:message]
        io.puts ""
        update_binary(path, io, err,
          release_json: release_json,
          api_url: api_url,
          force_progress: force_progress)
      end
    end
  end
end
