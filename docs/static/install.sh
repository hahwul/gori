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
# Plain web endpoint (NOT the API): 302s to .../releases/tag/<tag>. No rate limit.
LATEST_URL="https://github.com/${REPO}/releases/latest"
# Download URL pattern: https://github.com/hahwul/gori/releases/download/<tag>/<asset>
DOWNLOAD_BASE="https://github.com/${REPO}/releases/download"

# Optional PAT. api.github.com allows 60 unauthenticated requests per hour per
# IP; authenticated it is 5000. Shared CI/NAT egress IPs burn the anonymous
# quota fast, which is what makes the unauthenticated tier unreliable.
TOKEN="${GORI_GITHUB_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}"

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

# Resolving the tag has three tiers, most informative first. The API is tried
# before the redirect because only the API returns the asset list we validate
# against; the redirect is the one that survives a spent rate limit.
#
#   1. authenticated API  — 5000 req/h, tag + asset list
#   2. anonymous API      — same data, but only 60 req/h per IP
#   3. release redirect   — github.com/<repo>/releases/latest 302s to the tag
#                           URL. Not the API, so no quota; tag only.

# Prints "<body>\n<http_code>". Never aborts the script: even a failed connection
# yields a trailing status line (000), so the caller can tell "GitHub is down"
# apart from "GitHub said no".
#
# stderr is deliberately NOT silenced. Without -f, curl stays quiet on an HTTP
# error status (403 and friends reach us as $api_code), so the only thing this
# lets through is a transport failure — DNS, TLS, proxy — which is exactly the
# detail someone on a broken network needs and cannot get anywhere else.
api_fetch() {
  if [ -n "$TOKEN" ]; then
    curl -sSL -w '\n%{http_code}' \
      -H "Accept: application/vnd.github+json" \
      -H "User-Agent: gori-install.sh" \
      -H "Authorization: Bearer ${TOKEN}" \
      "$1" || true
  else
    curl -sSL -w '\n%{http_code}' \
      -H "Accept: application/vnd.github+json" \
      -H "User-Agent: gori-install.sh" \
      "$1" || true
  fi
}

if [ -n "$TOKEN" ]; then
  log "fetching latest release metadata from ${API_URL} (authenticated)"
else
  log "fetching latest release metadata from ${API_URL}"
fi

api_response="$(api_fetch "$API_URL")"
api_code="$(printf '%s\n' "$api_response" | tail -n1)"
release_json="$(printf '%s\n' "$api_response" | sed '$d')"

tag=""
asset_names=""

if [ "$api_code" = "200" ]; then
  # Prefer python3 for JSON; fall back to a conservative sed/grep parse of tag_name.
  parsed=""
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
' 2>/dev/null || true)"
  elif command -v python >/dev/null 2>&1; then
    parsed="$(printf '%s' "$release_json" | python -c '
import sys, json
d = json.load(sys.stdin)
tag = d.get("tag_name") or ""
names = [a.get("name","") for a in (d.get("assets") or [])]
print(tag)
print("\n".join(names))
' 2>/dev/null || true)"
  fi
  if [ -n "$parsed" ]; then
    tag="$(printf '%s\n' "$parsed" | head -1)"
    asset_names="$(printf '%s\n' "$parsed" | tail -n +2)"
  else
    # No python, or python choked on the body — grep out just the tag.
    tag="$(printf '%s' "$release_json" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || true)"
  fi
  # A parsed-but-tagless response is a broken response; do not trust its asset
  # list either, and let the redirect tier have a go.
  if [ -z "$tag" ]; then
    asset_names=""
    log "could not parse tag_name from the API response — trying the release redirect"
  fi
else
  case "$api_code" in
    401)
      log "GitHub API rejected the token (HTTP 401 — check GITHUB_TOKEN/GH_TOKEN) — trying the release redirect" ;;
    403|429)
      log "GitHub API rate limit reached (HTTP ${api_code} — 60 requests/hour per IP unauthenticated) — trying the release redirect" ;;
    000)
      log "could not reach api.github.com — trying the release redirect" ;;
    *)
      log "GitHub API returned HTTP ${api_code} — trying the release redirect" ;;
  esac
fi

if [ -z "$tag" ]; then
  location="$(curl -sSI "$LATEST_URL" | tr -d '\r' | grep -i '^location:' | tail -n1 | sed 's/^[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*//' || true)"
  # Requiring the /releases/tag/ segment is what keeps this honest: a repo with
  # no published release redirects to plain /releases, which must not read as a tag.
  case "$location" in
    */releases/tag/*)
      tag="${location##*/releases/tag/}"
      tag="${tag%%[?#]*}"   # drop any query string / fragment
      tag="${tag%%/*}"      # drop any trailing path segment
      ;;
    *) tag="" ;;
  esac
  if [ -n "$tag" ]; then
    log "resolved ${tag} via ${LATEST_URL} (no API call)"
  fi
fi

if [ -z "$tag" ]; then
  case "$api_code" in
    403|429)
      die "GitHub API rate limit reached (HTTP ${api_code}) and the release redirect failed too.
  Retry in a few minutes, set GITHUB_TOKEN=<token> to raise the limit to 5000/hour,
  or download manually from https://github.com/${REPO}/releases" ;;
    *)
      die "could not determine the latest release (API HTTP ${api_code}, redirect failed) — see https://github.com/${REPO}/releases" ;;
  esac
fi

ver="${tag#v}"
# Every release also ships a version-less copy of each asset, so a name derived
# from a tag we could not validate against an asset list still has a fallback.
if [ "$os_key" = "linux" ]; then
  asset="gori-v${ver}-linux-${arch_key}"
  alias_asset="gori-linux-${arch_key}"
else
  asset="gori-v${ver}-osx-${arch_key}.tar.gz"
  alias_asset="gori-osx-${arch_key}.tar.gz"
fi

if [ -n "$asset_names" ]; then
  if ! printf '%s\n' "$asset_names" | grep -Fxq "$asset"; then
    if printf '%s\n' "$asset_names" | grep -Fxq "$alias_asset"; then
      log "release ${tag} has no '${asset}' — using version-less alias '${alias_asset}'"
      asset="$alias_asset"
    else
      die "release ${tag} has no asset '${asset}' (see https://github.com/${REPO}/releases) — assets may not be published yet"
    fi
  fi
fi

url="${DOWNLOAD_BASE}/${tag}/${asset}"
log "install channel: standalone binary"
log "version: ${tag}  asset: ${asset}"
log "prefix: ${PREFIX}"
log "downloading ${url}"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/gori-install.XXXXXX")"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

# -S omitted on this first attempt only: a 404 here is handled (we retry the
# alias below), so curl's own error line would read as a failure when it is not.
if ! curl -fsL -o "${tmpdir}/${asset}" "$url"; then
  # Reached without an asset list to check against (redirect tier), so the
  # versioned filename was a guess. Retry the version-less alias under the SAME
  # tag — not /releases/latest/download/, which could hand us a different
  # release if one is published mid-install.
  if [ "$asset" != "$alias_asset" ]; then
    log "no ${asset} in ${tag} — retrying version-less alias ${alias_asset}"
    asset="$alias_asset"
    url="${DOWNLOAD_BASE}/${tag}/${asset}"
    log "downloading ${url}"
    curl -fsSL -o "${tmpdir}/${asset}" "$url" || \
      die "download failed — neither the versioned nor the alias asset exists for ${tag} (see https://github.com/${REPO}/releases)"
  else
    die "download failed — asset may not exist yet for ${tag} (see https://github.com/${REPO}/releases)"
  fi
fi

if [ ! -s "${tmpdir}/${asset}" ]; then
  die "downloaded asset is empty: ${asset}"
fi

# Integrity check against the release's SHA256SUMS, fetched over the same
# download path — so it still works on the redirect tier, where no API digest is
# available. Best-effort by design: releases published before SHA256SUMS existed
# carry none, and refusing to install those would be a regression. A checksum
# that IS present and does NOT match is always fatal.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    return 1
  fi
}

if sums="$(curl -fsL "${DOWNLOAD_BASE}/${tag}/SHA256SUMS")"; then
  # SHA256SUMS lists both the versioned and the version-less name for each
  # asset, so this matches whichever one we ended up downloading.
  expected="$(printf '%s\n' "$sums" | awk -v want="$asset" \
    '{ n = $2; sub(/^\*/, "", n); if (n == want) { print $1; exit } }' || true)"
  if [ -z "$expected" ]; then
    log "SHA256SUMS has no entry for ${asset} — skipping checksum verification"
  elif actual="$(sha256_of "${tmpdir}/${asset}")"; then
    if [ "$actual" = "$expected" ]; then
      log "sha256 verified"
    else
      die "checksum mismatch for ${asset}: expected ${expected}, got ${actual} (download corrupted or tampered in transit)"
    fi
  else
    log "no sha256sum/shasum on this system — skipping checksum verification"
  fi
else
  log "no SHA256SUMS published for ${tag} — skipping checksum verification"
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
