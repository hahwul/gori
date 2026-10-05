#!/usr/bin/env bash
# Build a static gori binary (or spec runner) on a GitHub windows runner, under Git Bash.
# Crystal's Windows install ships every library gori links except these three, taken from
# vcpkg as static libraries; `--static` then links the static CRT, so the .exe needs no DLL
# and no Visual C++ redistributable. The store's full-text index needs sqlite3's FTS5, which
# vcpkg leaves out by default.
#
# usage: scripts/build-windows.sh SOURCE.cr OUT.exe [crystal build flags...]
set -euo pipefail
src=${1:?usage: build-windows.sh SOURCE.cr OUT.exe [flags...]}
out=${2:?usage: build-windows.sh SOURCE.cr OUT.exe [flags...]}
shift 2

triplet=x64-windows-static
vcpkg install --triplet "$triplet" "sqlite3[fts5]" brotli zstd
export CRYSTAL_LIBRARY_PATH="$(crystal env CRYSTAL_LIBRARY_PATH);C:\\vcpkg\\installed\\$triplet\\lib"
shards install --production
mkdir -p "$(dirname "$out")"
crystal build "$src" -o "$out" --static "$@"
