# Verifies that nix/shards.nix still describes the dependency set shard.lock pins.
#
# `just nix-shards` regenerates that file with crystal2nix, and AGENTS.md asks for
# it in the same commit as the dependency change — but nothing enforced it, and the
# failure is silent in the worst way: bump a shard, forget the regeneration, and
# `nix build` stays green while linking the OLD revisions. The flake produces a
# binary this tree does not describe, and no output anywhere says so.
#
# This reads the two files and compares them, so it needs neither Nix nor the
# network — which is the point. CI has no Nix job (the flake pins its own compiler,
# several minutes cold), so the check that would catch this by building does not run.
#
# Usage: crystal run scripts/nix_shards_check.cr  (just nix-shards-check)

require "yaml"

LOCK_PATH = "shard.lock"
NIX_PATH  = "nix/shards.nix"

# shard.lock's `git:` value is a full URL; a `github:`/`gitlab:`/`bitbucket:` value is
# the bare `owner/repo` that resolver implies. Qualifying it HERE, where the key that
# names the host is still in hand, is what keeps the comparison below a plain string
# match — guessing the host afterwards from a slash-shaped string cannot tell the
# three apart.
RESOLVER_HOSTS = {"github" => "github.com", "gitlab" => "gitlab.com", "bitbucket" => "bitbucket.org"}

record LockDep, name : String, url : String, version : String
record NixDep, name : String, url : String, rev : String, hash : String

def abort_with(message : String) : NoReturn
  STDERR.puts "✗ #{message}"
  exit 1
end

# YAML, not a hand-rolled line scan: `yaml` is stdlib, so requiring it costs nothing
# that a scan would save (this still runs before `shards install` has touched `lib/`),
# and an indentation-sensitive regex over a nested mapping is how a parser starts
# quietly returning "" for a key whose spelling moved.
def parse_lock(text : String) : Array(LockDep)
  doc = YAML.parse(text)
  shards = doc["shards"]?
  abort_with("#{LOCK_PATH} has no `shards:` mapping — the file's shape changed") unless shards

  shards.as_h.map do |name, attrs|
    entry = attrs.as_h
    url = entry["git"]?.try(&.as_s)
    unless url
      # First resolver key present wins; shards only ever writes one.
      RESOLVER_HOSTS.each do |key, host|
        if slug = entry[key]?.try(&.as_s)
          url = "https://#{host}/#{slug}.git"
          break
        end
      end
    end
    abort_with("#{name}: no `git:`/#{RESOLVER_HOSTS.keys.join('/')} key in #{LOCK_PATH}") unless url
    version = entry["version"]?
    abort_with("#{name}: no `version:` in #{LOCK_PATH}") unless version
    LockDep.new(name.as_s, url, scalar(version))
  end
end

# A version reaches YAML as a String ("1.7.0", "0.6.1+git.commit.<sha>"), but a
# two-component one ("1.7") would arrive as a Float and `as_s` would raise on it.
def scalar(value : YAML::Any) : String
  value.as_s? || value.raw.to_s
end

# crystal2nix emits either a fetchgit attrset (`url`/`rev`/`sha256`) or a
# fetchFromGitHub one (`owner`/`repo`/`rev`/`sha256`); buildCrystalPackage picks the
# fetcher by whether `url` is present, so both shapes are legal input here.
def parse_nix(text : String) : Array(NixDep)
  text.scan(/"([^"]+)"\s*=\s*\{(.*?)\};/m).map do |m|
    body = m[2]
    url = body.match(/\burl\s*=\s*"([^"]+)"/).try(&.[1])
    owner = body.match(/\bowner\s*=\s*"([^"]+)"/).try(&.[1])
    repo = body.match(/\brepo\s*=\s*"([^"]+)"/).try(&.[1])
    url ||= (owner && repo) ? "https://github.com/#{owner}/#{repo}.git" : ""
    rev = body.match(/\brev\s*=\s*"([^"]+)"/).try(&.[1]) || ""
    hash = body.match(/\b(?:sha256|hash)\s*=\s*"([^"]+)"/).try(&.[1]) || ""
    NixDep.new(m[1], url, rev, hash)
  end
end

# Compare the repository, not the spelling: the same dependency is an https URL on one
# side and an owner/repo pair on the other, and neither difference is a drift.
def normalize_url(url : String) : String
  url.sub(/^git\+/, "").sub(/^(https?|ssh|git):\/\//, "").sub(/^git@/, "").sub(/\.git$/, "").rstrip('/').downcase
end

# The locked `version` is either a release ("1.7.0") or a commit pin that shards
# spells "0.6.1+git.commit.<sha>" for a branch dependency. crystal2nix turns the
# first into the release TAG and the second into the bare sha, so this checks the
# correspondence rather than guessing a tag convention: any tag ending in the
# version counts (`v1.7.0`, `1.7.0`, `ameba-1.7.0`), but `v11.7.0` does not satisfy
# `1.7.0` — what sits in front of the match has to end in a separator, never a digit
# or a dot, or a neighbouring release would read as a hit.
def rev_matches?(rev : String, version : String) : Bool
  if m = version.match(/\+git\.commit\.([0-9a-f]+)$/)
    return rev == m[1]
  end
  return false if version.empty? || !rev.ends_with?(version)
  prefix = rev[0, rev.size - version.size]
  prefix.empty? || !(prefix[-1].ascii_number? || prefix[-1] == '.')
end

# Presence is not enough: a truncated or hand-mangled digest passes an `.empty?` test
# and then fails inside `nix build`, which is the one place this check exists so as
# not to depend on. crystal2nix writes nix32 (52 chars); accept the hex and SRI
# spellings a hand edit might substitute, and nothing else.
def hash_shape_ok?(hash : String) : Bool
  return true if hash.matches?(/\A[0-9a-df-np-sv-z]{52}\z/)
  return true if hash.matches?(/\A[0-9a-f]{64}\z/)
  hash.matches?(/\Asha256-[A-Za-z0-9+\/]{43}=\z/)
end

[LOCK_PATH, NIX_PATH].each do |path|
  abort_with("#{path} not found — run this from the repository root") unless File.exists?(path)
end

lock = parse_lock(File.read(LOCK_PATH))
nix = parse_nix(File.read(NIX_PATH))

abort_with("no shards parsed out of #{LOCK_PATH} — the file's shape changed") if lock.empty?

by_name = nix.to_h { |d| {d.name, d} }
problems = [] of String

# `to_h` is last-wins, exactly as Nix reads a repeated attribute — so a bad merge that
# left two blocks for one shard would be certified clean against whichever the merge
# happened to put second. Say so instead.
if by_name.size != nix.size
  duplicated = nix.map(&.name).tally.select { |_, n| n > 1 }.keys
  problems << "#{NIX_PATH} defines #{duplicated.join(", ")} more than once"
end

width = lock.max_of(&.name.size) + 2
lock.each do |dep|
  entry = by_name[dep.name]?
  unless entry
    problems << "#{dep.name}: in #{LOCK_PATH}, missing from #{NIX_PATH}"
    puts "#{"#{dep.name}:".ljust(width)} MISSING"
    next
  end

  ok = true
  if normalize_url(entry.url) != normalize_url(dep.url)
    problems << "#{dep.name}: url #{entry.url.inspect} != #{dep.url.inspect}"
    ok = false
  end
  unless rev_matches?(entry.rev, dep.version)
    problems << "#{dep.name}: rev #{entry.rev.inspect} does not match locked version #{dep.version.inspect}"
    ok = false
  end
  unless hash_shape_ok?(entry.hash)
    problems << "#{dep.name}: #{entry.hash.empty? ? "no sha256/hash" : "sha256 #{entry.hash.inspect} is not a nix32, hex or SRI digest"}"
    ok = false
  end
  puts "#{"#{dep.name}:".ljust(width)} #{dep.version} -> #{entry.rev} #{ok ? "✓" : "✗"}"
end

(by_name.keys - lock.map(&.name)).each do |extra|
  problems << "#{extra}: in #{NIX_PATH}, missing from #{LOCK_PATH}"
  puts "#{"#{extra}:".ljust(width)} STALE"
end

unless problems.empty?
  STDERR.puts
  problems.each { |p| STDERR.puts "✗ #{p}" }
  STDERR.puts
  STDERR.puts "#{NIX_PATH} is out of step with #{LOCK_PATH}. Regenerate it:"
  STDERR.puts "  just nix-shards"
  exit 1
end

puts "✓ #{NIX_PATH} matches #{LOCK_PATH} (#{lock.size} shards)"
