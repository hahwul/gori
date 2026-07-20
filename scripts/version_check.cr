# Verifies that every version-bearing file in the repo agrees.
# Keep the tracked-file list in sync with scripts/version_update.cr.
#
# Usage: crystal run scripts/version_check.cr  (just vc)

FILES = {
  "shard.yml"           => /^version:\s*(\S+)/m,
  "src/gori.cr"         => /VERSION = "([^"]+)"/,
  "snap/snapcraft.yaml" => /^version:\s*(\S+)/m,
  "aur/PKGBUILD"        => /^pkgver=(\S+)/m,
  "spec/gori_spec.cr"   => /VERSION\.should eq\("([^"]+)"\)/,
}

versions = FILES.map do |path, pattern|
  version = File.read(path).match(pattern).try(&.[1])
  puts "#{"#{path}:".ljust(21)} #{version || "not found"}"
  {path, version}
end

missing = versions.select { |_, version| version.nil? }
unless missing.empty?
  STDERR.puts "✗ version not found in: #{missing.map(&.[0]).join(", ")}"
  exit 1
end

unique = versions.compact_map(&.[1]).uniq!
if unique.size > 1
  STDERR.puts "✗ version mismatch: #{unique.join(", ")}"
  exit 1
end

puts "✓ versions match (#{unique.first})"
