# Shows the current version, prompts for a new one (blank keeps it), then
# writes it to every version-bearing marker. Resets aur/PKGBUILD's pkgrel to 1
# on every bump. Keep the tracked list in sync with scripts/version_check.cr.
#
# Usage: crystal run scripts/version_update.cr  (just vu)
#
# flake.nix holds two versions; the pattern below hits gori's and not the pinned
# compiler's, because that one is spelled `crystalVersion` (capital V) and the
# attribute referencing it, `version = crystalVersion;`, has no string literal.
#
# A LIST, not a path-keyed hash: one file can carry SEVERAL markers (see the
# install docs, which quote the version three times over) and a hash would rewrite
# only the last one per path. Entries sharing a path are applied in order, each
# re-reading what the previous one wrote.
#
# NOT every version string in the docs belongs here. A marker is for text that
# means "the current release" — sample output, an example asset name. Text stating
# WHEN something was introduced ("these start at v0.2.0") is a historical fact that
# must stay put, and bumping it would turn it into a lie.
record Marker, path : String, pattern : Regex, replace : Proc(String, String), label : String? = nil do
  def name : String
    label ? "#{path} (#{label})" : path
  end
end

MARKERS = [
  Marker.new("shard.yml", /^version:\s*\S+/m, ->(v : String) { "version: #{v}" }),
  Marker.new("src/gori.cr", /VERSION = "[^"]+"/, ->(v : String) { %(VERSION = "#{v}") }),
  Marker.new("snap/snapcraft.yaml", /^version:\s*\S+/m, ->(v : String) { "version: #{v}" }),
  Marker.new("aur/PKGBUILD", /^pkgver=\S+/m, ->(v : String) { "pkgver=#{v}" }),
  Marker.new("flake.nix", /version = "[^"]+";/, ->(v : String) { %(version = "#{v}";) }),
  Marker.new("spec/gori_spec.cr", /VERSION\.should eq\("[^"]+"\)/, ->(v : String) { %(VERSION.should eq("#{v}")) }),
  Marker.new("docs/content/getting-started/installation.md",
    /You should see `gori [^`]+`\./, ->(v : String) { "You should see `gori #{v}`." }, "version output"),
  Marker.new("docs/content/getting-started/installation.md",
    /resolved v[\d.]+ via/, ->(v : String) { "resolved v#{v} via" }, "installer fallback"),
  Marker.new("docs/content/getting-started/installation.md",
    /`gori-v[\d.]+-linux-x86_64`/, ->(v : String) { "`gori-v#{v}-linux-x86_64`" }, "asset name"),
  Marker.new("docs/content/getting-started/installation.ko.md",
    /`gori [^`]+`이 표시되어야 합니다\./, ->(v : String) { "`gori #{v}`이 표시되어야 합니다." }, "version output"),
  Marker.new("docs/content/getting-started/installation.ko.md",
    /resolved v[\d.]+ via/, ->(v : String) { "resolved v#{v} via" }, "installer fallback"),
  Marker.new("docs/content/getting-started/installation.ko.md",
    /`gori-v[\d.]+-linux-x86_64`/, ->(v : String) { "`gori-v#{v}-linux-x86_64`" }, "asset name"),
]

current = File.read("shard.yml").match(/^version:\s*(\S+)/m).try(&.[1]) || "unknown"
puts "Current version: #{current}"
print "New version (blank to keep): "
target = gets.try(&.strip) || ""

if target.empty?
  puts "No change."
  exit 0
end

unless target.matches?(/^\d+\.\d+\.\d+$/)
  STDERR.puts "✗ invalid version '#{target}' (expected X.Y.Z)"
  exit 1
end

# Verify EVERY marker before writing ANY: a half-applied bump leaves the tree in a
# state `just vc` rejects, and the operator has to work out which files got written.
MARKERS.each do |marker|
  next if File.read(marker.path).matches?(marker.pattern)
  STDERR.puts "✗ no version marker in #{marker.name}"
  exit 1
end

MARKERS.each do |marker|
  updated = File.read(marker.path).sub(marker.pattern, marker.replace.call(target))
  updated = updated.sub(/^pkgrel=\d+/m, "pkgrel=1") if marker.path == "aur/PKGBUILD"
  File.write(marker.path, updated)
  puts "  ✓ #{marker.name}"
end

puts "✓ version: #{current} -> #{target}"
