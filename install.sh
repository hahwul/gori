#!/usr/bin/env bash
# gori one-line installer — https://gori.hahwul.com/install.sh
#
#   curl -fsSL https://gori.hahwul.com/install.sh | bash
#
# Downloads the matching GitHub release asset for this machine and installs
# `gori` onto PATH. Release asset names (PR #114 / hwaro parity):
#   gori-v*-linux-x86_64
#   gori-v*-linux-arm64
#   gori-v*-osx-arm64.tar.gz
#   gori-v*-osx-x86_64.tar.gz
#
# Override install root with GORI_INSTALL_PREFIX (default: /usr/local if
# writable, else ~/.local). macOS keeps gori + lib/ under $PREFIX/opt/gori.
set -euo pipefail

REPO="hahwul/gori"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
# Download URL pattern: https://github.com/hahwul/gori/releases/download/<tag>/<asset>
DOWNLOAD_BASE="https://github.com/${REPO}/releases/download"

log()  { printf 'gori-install: %s\n' "$*"; }
die()  { printf 'gori-install: error: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

need_cmd curl
need_cmd uname
need_cmd mktemp
need_cmd mkdir
need_cmd chmod

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"

case "$os" in
  linux)  os_key="linux" ;;
  darwin) os_key="osx" ;;
  *)      die "unsupported OS '$os' (supported: linux, darwin/macOS)" ;;
esac

case "$arch" in
  x86_64|amd64)   arch_key="x86_64" ;;
  aarch64|arm64)  arch_key="arm64" ;;
  *)              die "unsupported architecture '$arch' (supported: x86_64, arm64)" ;;
esac

if [ -n "${GORI_INSTALL_PREFIX:-}" ]; then
  PREFIX="$GORI_INSTALL_PREFIX"
elif [ -w /usr/local/bin ] 2>/dev/null || [ "$(id -u)" -eq 0 ]; then
  PREFIX="/usr/local"
else
  PREFIX="${HOME}/.local"
fi

log "fetching latest release metadata from ${API_URL}"
release_json="$(curl -fsSL \
  -H "Accept: application/vnd.github+json" \
  -H "User-Agent: gori-install.sh" \
  "$API_URL")" || die "failed to fetch latest release (is the network up? are releases published?)"

# Prefer python3 for JSON; fall back to a conservative sed/grep parse of tag_name.
tag=""
asset_ok=""
if command -v python3 >/dev/null 2>&1; then
  parsed="$(printf '%s' "$release_json" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception as e:
    sys.stderr.write("json parse error: %s\n" % e)
    sys.exit(2)
tag = d.get("tag_name") or ""
names = [a.get("name","") for a in (d.get("assets") or [])]
print(tag)
print("\n".join(names))
' )" || die "could not parse GitHub releases JSON"
  tag="$(printf '%s\n' "$parsed" | head -1)"
  asset_names="$(printf '%s\n' "$parsed" | tail -n +2)"
elif command -v python >/dev/null 2>&1; then
  parsed="$(printf '%s' "$release_json" | python -c '
import sys, json
d = json.load(sys.stdin)
tag = d.get("tag_name") or ""
names = [a.get("name","") for a in (d.get("assets") or [])]
print(tag)
print("\n".join(names))
' )" || die "could not parse GitHub releases JSON"
  tag="$(printf '%s\n' "$parsed" | head -1)"
  asset_names="$(printf '%s\n' "$parsed" | tail -n +2)"
else
  tag="$(printf '%s' "$release_json" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
  asset_names=""
fi
[ -n "$tag" ] || die "could not parse tag_name from GitHub releases API response"

ver="${tag#v}"
if [ "$os_key" = "linux" ]; then
  asset="gori-v${ver}-linux-${arch_key}"
else
  asset="gori-v${ver}-osx-${arch_key}.tar.gz"
fi

if [ -n "$asset_names" ]; then
  printf '%s\n' "$asset_names" | grep -Fxq "$asset" || \
    die "release ${tag} has no asset '${asset}' (see https://github.com/${REPO}/releases) — assets may not be published yet"
fi

url="${DOWNLOAD_BASE}/${tag}/${asset}"
log "install channel: standalone binary"
log "version: ${tag}  asset: ${asset}"
log "prefix: ${PREFIX}"
log "downloading ${url}"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/gori-install.XXXXXX")"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

curl -fsSL -o "${tmpdir}/${asset}" "$url" || die "download failed — asset may not exist yet for ${tag} (see https://github.com/${REPO}/releases)"

if [ ! -s "${tmpdir}/${asset}" ]; then
  die "downloaded asset is empty: ${asset}"
fi

bin_dir="${PREFIX}/bin"
mkdir -p "$bin_dir"

if [ "$os_key" = "linux" ]; then
  install_path="${bin_dir}/gori"
  # install(1) is not always present on minimal images
  cp "${tmpdir}/${asset}" "$install_path"
  chmod 755 "$install_path"
else
  need_cmd tar
  # Reject tar-slip entries before extract
  if tar tzf "${tmpdir}/${asset}" 2>/dev/null | grep -E '(^/|(^|/)\.\.(/|$))' >/dev/null; then
    die "refusing archive with unsafe path entries"
  fi
  tar xzf "${tmpdir}/${asset}" -C "$tmpdir"
  [ -f "${tmpdir}/gori" ] || die "archive missing gori binary (expected top-level gori + lib/)"
  # Always use PREFIX/opt/gori so lib/ never lands on a shared library root (e.g. /usr/local/lib).
  opt_dir="${PREFIX}/opt/gori"
  mkdir -p "$opt_dir"
  # Replace previous install while keeping gori and lib/ together for @executable_path/lib
  if [ -d "${opt_dir}/lib" ]; then
    rm -rf "${opt_dir}/lib"
  fi
  cp "${tmpdir}/gori" "${opt_dir}/gori"
  chmod 755 "${opt_dir}/gori"
  if [ -d "${tmpdir}/lib" ]; then
    cp -R "${tmpdir}/lib" "${opt_dir}/lib"
  fi
  ln -sfn "${opt_dir}/gori" "${bin_dir}/gori"
  install_path="${bin_dir}/gori"
  log "macOS bundle installed under ${opt_dir} (gori + lib/)"
fi

log "installed ${install_path}"
if ! command -v gori >/dev/null 2>&1; then
  log "note: ${bin_dir} is not on PATH yet — add: export PATH=\"${bin_dir}:\$PATH\""
fi

if [ -x "$install_path" ]; then
  # Resolve symlink for version check
  if "$install_path" --version 2>/dev/null; then
    :
  else
    log "binary installed but --version failed (Gatekeeper quarantine on macOS? try: xattr -dr com.apple.quarantine ${PREFIX}/opt/gori)"
  fi
fi

log "done. Update later with: gori update"
