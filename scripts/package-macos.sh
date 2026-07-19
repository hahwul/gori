#!/usr/bin/env bash
# Bundle Homebrew-linked dylibs next to a Crystal macOS binary so the
# release tarball runs without a local OpenSSL (or other brew) install.
#
# For gori this bundles libssl/libcrypto, libbrotlidec, libzstd, libyaml, libgmp,
# libpcre2 and libgc. It deliberately does NOT bundle libsqlite3: the sqlite3
# shard links `@[Link("sqlite3")]`, which resolves to /usr/lib/libsqlite3.dylib —
# a system library present on every macOS, and outside the Homebrew prefixes this
# script walks.
#
# Usage: scripts/package-macos.sh <binary-path> <output-tarball> [staged-name]
#
# Archive layout:
#   <staged-name>
#   lib/*.dylib
set -euo pipefail

BINARY="${1:?Usage: $0 <binary-path> <output-tarball> [staged-name]}"
OUTPUT="${2:?Usage: $0 <binary-path> <output-tarball> [staged-name]}"
NAME="${3:-$(basename "$BINARY")}"

if [[ ! -f "$BINARY" ]]; then
  echo "error: binary not found: $BINARY" >&2
  exit 1
fi

if ! command -v otool >/dev/null 2>&1 || ! command -v install_name_tool >/dev/null 2>&1; then
  echo "error: otool and install_name_tool are required (macOS only)" >&2
  exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

mkdir -p "$STAGING/lib"
cp "$BINARY" "$STAGING/$NAME"
chmod +x "$STAGING/$NAME"

BREW_PREFIX_RE='^(/opt/homebrew|/usr/local)/'

# Every load command of a Mach-O image, verbatim (system libs included).
load_commands() {
  otool -L "$1" | awk 'NR>1 {print $1}'
}

# `deps.txt` holds the load-command strings to rewrite; `origins.txt` maps each
# staged basename back to the directory it was copied from. The latter is what
# lets us resolve `@rpath` / `@loader_path` references: Homebrew's brotli, for
# one, links libbrotlidec against `@rpath/libbrotlicommon.1.dylib`, so matching
# only on the brew prefix silently drops libbrotlicommon from the bundle.
DEPS_FILE="$STAGING/deps.txt"
ORIGINS_FILE="$STAGING/origins.txt"
: > "$DEPS_FILE"
: > "$ORIGINS_FILE"

origin_dir_of() {
  awk -F'\t' -v want="$1" '$1 == want { print $2; exit }' "$ORIGINS_FILE"
}

# Map a load command to the file on disk it refers to, or nothing if it is a
# system library we must not bundle. $2 is the directory the *referencing* image
# was copied from, used to anchor @rpath/@loader_path.
resolve_dep() {
  local dep="$1" origin="$2" candidate
  case "$dep" in
    @rpath/* | @loader_path/*)
      [[ -n "$origin" ]] || return 0
      candidate="$origin/$(basename "$dep")"
      ;;
    *)
      candidate="$dep"
      ;;
  esac
  # Print nothing for anything we must not bundle: system libraries (note
  # /usr/lib/libsqlite3.dylib is not even on disk — it lives in the dyld shared
  # cache, so `-f` is false) and unresolvable @rpath entries. Always succeed:
  # under `set -e` a non-zero return here would abort the caller's assignment.
  if [[ -f "$candidate" && "$candidate" =~ $BREW_PREFIX_RE ]]; then
    printf '%s\n' "$candidate"
  fi
  return 0
}

while true; do
  added=0
  for target in "$STAGING/$NAME" "$STAGING"/lib/*.dylib; do
    [[ -e "$target" ]] || continue
    # The main binary was copied from wherever it was built, not from a brew
    # prefix, so it anchors nothing; staged dylibs anchor to their brew dir.
    target_origin=""
    [[ "$target" != "$STAGING/$NAME" ]] && target_origin="$(origin_dir_of "$(basename "$target")")"

    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      src="$(resolve_dep "$dep" "$target_origin")"
      [[ -n "$src" ]] || continue

      base="$(basename "$src")"
      if ! grep -Fxq "$dep" "$DEPS_FILE"; then
        echo "$dep" >> "$DEPS_FILE"
      fi
      if [[ ! -f "$STAGING/lib/$base" ]]; then
        cp "$src" "$STAGING/lib/$base"
        chmod u+w "$STAGING/lib/$base" # brew ships these 0444; install_name_tool needs write
        printf '%s\t%s\n' "$base" "$(dirname "$src")" >> "$ORIGINS_FILE"
        added=1
      fi
    done < <(load_commands "$target")
  done
  [[ "$added" -eq 0 ]] && break
done

rewrite_paths() {
  local target="$1"
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    install_name_tool -change "$dep" "@executable_path/lib/$(basename "$dep")" "$target"
  done < "$DEPS_FILE"
}

rewrite_paths "$STAGING/$NAME"
for lib in "$STAGING"/lib/*.dylib; do
  [[ -e "$lib" ]] || continue
  install_name_tool -id "@executable_path/lib/$(basename "$lib")" "$lib"
  rewrite_paths "$lib"
done

# `install_name_tool` rewrites load commands in place, which invalidates each
# Mach-O's code signature. On Apple Silicon that is fatal, not cosmetic: dyld
# refuses the image and the kernel SIGKILLs the process (exit 137) the moment a
# bundled dylib is loaded. Re-sign every image we touched, ad-hoc.
if ! command -v codesign >/dev/null 2>&1; then
  echo "error: codesign is required to re-sign rewritten binaries" >&2
  exit 1
fi
for target in "$STAGING"/lib/*.dylib "$STAGING/$NAME"; do
  [[ -e "$target" ]] || continue
  codesign --force --sign - "$target" 2>/dev/null
done

# Audit the binary *and* every bundled dylib: an unrewritten @rpath buried in a
# transitive dylib still aborts at load time, and checking only the top-level
# binary would not see it.
leaked=0
for target in "$STAGING/$NAME" "$STAGING"/lib/*.dylib; do
  [[ -e "$target" ]] || continue
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    if [[ "$dep" =~ $BREW_PREFIX_RE ]] || [[ "$dep" == @rpath/* ]] || [[ "$dep" == @loader_path/* ]]; then
      echo "error: unbundled reference in $(basename "$target"): $dep" >&2
      leaked=1
    fi
  done < <(load_commands "$target")
done
[[ "$leaked" -eq 0 ]] || exit 1

# Smoke-test the staged tree *before* archiving, and let a failure abort the
# release. Guarding this behind `if` would hide exactly the signature breakage
# the codesign pass above exists to prevent.
echo "Verifying staged binary:"
"$STAGING/$NAME" --version

mkdir -p "$(dirname "$OUTPUT")"
tar -czf "$OUTPUT" -C "$STAGING" "$NAME" lib

echo "Created $OUTPUT"