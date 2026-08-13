# Release asset naming, the safe lib destination, and release JSON -> Asset — reopens
# Gori::Update. Split out of update.cr along the banners that file already drew; carries
# the Asset / Release / AssetNotFound types the section defines.
module Gori::Update
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
end
