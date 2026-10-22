# The version-bearing markers, and the two things done with them.
#
# Usage: crystal run scripts/version.cr            (just vc) verify every marker agrees
#        crystal run scripts/version.cr -- update  (just vu) show the current version, prompt
#          for a new one (blank keeps it), then write it to every marker. Resets
#          packaging/aur/PKGBUILD's pkgrel to 1 on every bump.
#
# One list for both, so the check and the bump cannot track different files. Each pattern's
# group 1 is the version the check reads; the bump replaces the whole match with `replace`.
#
# flake.nix holds two versions; the pattern below hits gori's and not the pinned
# compiler's, because that one is spelled `crystalVersion` (capital V) and the
# attribute referencing it, `version = crystalVersion;`, has no string literal.
#
# A LIST, not a path-keyed hash: one file can carry SEVERAL markers, and a hash would
# check (or rewrite) only the last one per path. The install docs quote the version three
# times over — `gori --version` output, the installer's rate-limit fallback line, and the
# versioned asset name — and only the first was tracked, so the other two still read
# v0.1.4 four releases later. `label` names them apart in the output. Entries sharing a
# path are applied in order, each re-reading what the previous one wrote.
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
  Marker.new("shard.yml", /^version:\s*(\S+)/m, ->(v : String) { "version: #{v}" }),
  Marker.new("src/gori.cr", /VERSION = "([^"]+)"/, ->(v : String) { %(VERSION = "#{v}") }),
  Marker.new("snap/snapcraft.yaml", /^version:\s*(\S+)/m, ->(v : String) { "version: #{v}" }),
  Marker.new("packaging/aur/PKGBUILD", /^pkgver=(\S+)/m, ->(v : String) { "pkgver=#{v}" }),
  Marker.new("flake.nix", /version = "([^"]+)";/, ->(v : String) { %(version = "#{v}";) }),
  Marker.new("spec/gori_spec.cr", /VERSION\.should eq\("([^"]+)"\)/, ->(v : String) { %(VERSION.should eq("#{v}")) }),
  Marker.new("docs/content/getting-started/installation.md",
    /You should see `gori ([^`]+)`\./, ->(v : String) { "You should see `gori #{v}`." }, "version output"),
  Marker.new("docs/content/getting-started/installation.md",
    /resolved v([\d.]+) via/, ->(v : String) { "resolved v#{v} via" }, "installer fallback"),
  Marker.new("docs/content/getting-started/installation.md",
    /`gori-v([\d.]+)-linux-x86_64`/, ->(v : String) { "`gori-v#{v}-linux-x86_64`" }, "asset name"),
  Marker.new("docs/content/getting-started/installation.ko.md",
    /`gori ([^`]+)`이 표시되어야 합니다\./, ->(v : String) { "`gori #{v}`이 표시되어야 합니다." }, "version output"),
  Marker.new("docs/content/getting-started/installation.ko.md",
    /resolved v([\d.]+) via/, ->(v : String) { "resolved v#{v} via" }, "installer fallback"),
  Marker.new("docs/content/getting-started/installation.ko.md",
    /`gori-v([\d.]+)-linux-x86_64`/, ->(v : String) { "`gori-v#{v}-linux-x86_64`" }, "asset name"),
]

def check : Nil
  # Read each file ONCE — several markers share a path.
  sources = MARKERS.map(&.path).uniq!.to_h { |path| {path, File.read(path)} }

  width = MARKERS.max_of(&.name.size) + 2
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
end

def update : Nil
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
    updated = updated.sub(/^pkgrel=\d+/m, "pkgrel=1") if marker.path == "packaging/aur/PKGBUILD"
    File.write(marker.path, updated)
    puts "  ✓ #{marker.name}"
  end

  puts "✓ version: #{current} -> #{target}"
end

ARGV.first? == "update" ? update : check
