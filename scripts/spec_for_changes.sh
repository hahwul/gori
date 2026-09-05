#!/usr/bin/env bash
# Print the spec files that mirror what changed against BASE_REF, one per line — the input
# to `just test-changed`, the pre-flight before `just test`.
#
# Usage: scripts/spec_for_changes.sh [BASE_REF]   (default origin/main)
#
# Why: `crystal spec` on the whole suite compiles for ~35 s no matter what changed (the
# per-unit object cache saves ~2 s of that), while the specs for one change compile in
# 3–9 s. The tree mirrors `src/gori/<dir>/<name>.cr` as `spec/<dir>/<name>_spec.cr`
# (AGENTS.md, Repo map), so the mapping is a walk, not a list nobody maintains:
#
#   src/gori/a/b/c.cr  →  spec/a/b/c_spec.cr, and spec/a/b/c/ if that is a directory;
#                         else spec/a/b/ (a class-reopen slice runs its owner's specs);
#                         else spec/a/;   else spec/a_spec.cr.
#   src/gori/store.cr  →  spec/store/ (no spec/store_spec.cr exists; the dir is the mirror).
#   spec/**/x_spec.cr  →  itself.   Any other spec/**/*.cr (a harness) → its directory.
#   src/gori.cr, src/main.cr, spec/spec_helper.cr, spec/support/*  →  EVERY spec, since
#                         nothing narrower is honest; a note says so on stderr.
#
# Deleted files are skipped. scripts/, bench/, docs and lib/ map to nothing.
set -euo pipefail

base=${1:-origin/main}
cd "$(dirname "$0")/.."

if ! git rev-parse --verify --quiet "$base" >/dev/null; then
  echo "spec_for_changes: base ref '$base' not found (fetch it, or pass one)" >&2
  exit 2
fi
merge_base=$(git merge-base "$base" HEAD)

all=0
out=()
add() { out+=("$1"); }

# Walk src/gori/a/b/c.cr up through its mirrors; prints nothing when no mirror exists.
mirror() {
  local rel=$1 # a/b/c (no extension)
  local hit=0
  [ -f "spec/${rel}_spec.cr" ] && { add "spec/${rel}_spec.cr"; hit=1; }
  [ -d "spec/${rel}" ] && { add "spec/${rel}"; hit=1; }
  [ "$hit" -eq 1 ] && return 0
  local dir=$rel
  while [[ "$dir" == */* ]]; do
    dir=${dir%/*}
    [ -d "spec/$dir" ] && { add "spec/$dir"; return 0; }
    [ -f "spec/${dir}_spec.cr" ] && { add "spec/${dir}_spec.cr"; return 0; }
  done
  return 0
}

while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -e "$f" ] || continue # deleted
  case "$f" in
    src/gori.cr|src/main.cr|spec/spec_helper.cr|spec/support/*) all=1 ;;
    src/gori/*.cr) rel=${f#src/gori/}; mirror "${rel%.cr}" ;;
    spec/*_spec.cr) add "$f" ;;
    spec/*.cr) add "$(dirname "$f")" ;;
    *) ;;
  esac
done < <(git diff --name-only "$merge_base" HEAD; git diff --name-only HEAD; git ls-files --others --exclude-standard)

if [ "$all" -eq 1 ]; then
  echo "spec_for_changes: a file every spec depends on changed — the whole suite is the honest set" >&2
  find spec -name '*_spec.cr' | sort
  exit 0
fi

# Drop a file already covered by a listed directory, then unique.
printf '%s\n' ${out[@]+"${out[@]}"} | sort -u | awk '
  { paths[NR] = $0 }
  END {
    for (i = 1; i <= NR; i++) {
      covered = 0
      for (j = 1; j <= NR; j++)
        if (i != j && index(paths[i], paths[j] "/") == 1) covered = 1
      if (!covered) print paths[i]
    }
  }'
