# Install-channel detection and the package-manager guidance that follows from it —
# reopens Gori::Update. Split out of update.cr along the banners that file already drew.
# A package-managed install is never self-updated; this is what decides that.
module Gori::Update
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
end
