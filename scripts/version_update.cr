# Shows the current version, prompts for a new one (blank keeps it), then
# writes it to every version-bearing file. Resets aur/PKGBUILD's pkgrel to 1
# on every bump. Keep the tracked-file list in sync with
# scripts/version_check.cr.
#
# Usage: crystal run scripts/version_update.cr  (just vu)

FILES = {
  "shard.yml"                                       => {/^version:\s*\S+/m, ->(v : String) { "version: #{v}" }},
  "src/gori.cr"                                     => {/VERSION = "[^"]+"/, ->(v : String) { %(VERSION = "#{v}") }},
  "snap/snapcraft.yaml"                             => {/^version:\s*\S+/m, ->(v : String) { "version: #{v}" }},
  "aur/PKGBUILD"                                    => {/^pkgver=\S+/m, ->(v : String) { "pkgver=#{v}" }},
  "spec/gori_spec.cr"                               => {/VERSION\.should eq\("[^"]+"\)/, ->(v : String) { %(VERSION.should eq("#{v}")) }},
  "docs/content/getting-started/installation.md"    => {/You should see `gori [^`]+`\./, ->(v : String) { "You should see `gori #{v}`." }},
  "docs/content/getting-started/installation.ko.md" => {/`gori [^`]+`이 표시되어야 합니다\./, ->(v : String) { "`gori #{v}`이 표시되어야 합니다." }},
}

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

FILES.each do |path, (pattern, replacement)|
  content = File.read(path)
  unless content.matches?(pattern)
    STDERR.puts "✗ no version marker in #{path}"
    exit 1
  end
  updated = content.sub(pattern, replacement.call(target))
  updated = updated.sub(/^pkgrel=\d+/m, "pkgrel=1") if path == "aur/PKGBUILD"
  File.write(path, updated)
  puts "  ✓ #{path}"
end

puts "✓ version: #{current} -> #{target}"
