# Verifies that every version-bearing marker in the repo agrees.
# Keep the tracked list in sync with scripts/version_update.cr.
#
# Usage: crystal run scripts/version_check.cr  (just vc)
#
# A LIST, not a path-keyed hash: one file can carry SEVERAL markers, and a hash
# would silently check only the last one per path. The install docs quote the
# version three times over — `gori --version` output, the installer's rate-limit
# fallback line, and the versioned asset name — and only the first was tracked, so
# the other two still read v0.1.4 four releases later. `label` names them apart in
# the output.
record Marker, path : String, pattern : Regex, label : String? = nil do
  def name : String
    label ? "#{path} (#{label})" : path
  end
end

MARKERS = [
  Marker.new("shard.yml", /^version:\s*(\S+)/m),
  Marker.new("src/gori.cr", /VERSION = "([^"]+)"/),
  Marker.new("snap/snapcraft.yaml", /^version:\s*(\S+)/m),
  Marker.new("aur/PKGBUILD", /^pkgver=(\S+)/m),
  Marker.new("flake.nix", /version = "([^"]+)";/),
  Marker.new("spec/gori_spec.cr", /VERSION\.should eq\("([^"]+)"\)/),
  Marker.new("docs/content/getting-started/installation.md", /You should see `gori ([^`]+)`\./, "version output"),
  Marker.new("docs/content/getting-started/installation.md", /resolved v([\d.]+) via/, "installer fallback"),
  Marker.new("docs/content/getting-started/installation.md", /`gori-v([\d.]+)-linux-x86_64`/, "asset name"),
  Marker.new("docs/content/getting-started/installation.ko.md", /`gori ([^`]+)`이 표시되어야 합니다\./, "version output"),
  Marker.new("docs/content/getting-started/installation.ko.md", /resolved v([\d.]+) via/, "installer fallback"),
  Marker.new("docs/content/getting-started/installation.ko.md", /`gori-v([\d.]+)-linux-x86_64`/, "asset name"),
]

# Read each file ONCE — several markers share a path.
sources = MARKERS.map(&.path).uniq!.to_h { |path| {path, File.read(path)} }

width = MARKERS.max_of { |m| m.name.size } + 2
found = MARKERS.map do |marker|
  version = sources[marker.path].match(marker.pattern).try(&.[1])
  puts "#{"#{marker.name}:".ljust(width)} #{version || "not found"}"
  {marker, version}
end

missing = found.select { |_, version| version.nil? }
unless missing.empty?
  STDERR.puts "✗ version not found in: #{missing.map(&.[0].name).join(", ")}"
  exit 1
end

unique = found.compact_map(&.[1]).uniq!
if unique.size > 1
  STDERR.puts "✗ version mismatch: #{unique.join(", ")}"
  exit 1
end

puts "✓ versions match (#{unique.first})"
