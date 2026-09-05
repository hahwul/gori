#!/usr/bin/env bash
# Fails when a Crystal file changed on this branch carries MORE ameba findings than it did
# on the base ref. Per file, count against count — nothing about the backlog.
#
# Usage: scripts/ameba_gate.sh [BASE_REF]   (default origin/main; `just lint-gate`, and the
#        CI `lint-gate` job on pull requests)
#
# Why a diff gate and not the plain `ameba` run: the tree carries ~640 pre-existing findings,
# most of them Metrics/CyclomaticComplexity in the TUI that `.ameba.yml` deliberately left in
# place. A gate that is always red is a gate nobody reads, and one made green by excluding
# that category would hide new offences of the same kind (see the `lint-gate` job in
# ci.yml). Comparing each changed file against ITS OWN base count sidesteps both: the
# backlog is neither paid down nor hidden, and a change cannot add to it. A new file starts
# from zero, so it has to be clean. Deleting a file is never a regression.
#
# Both sides are linted with THIS checkout's .ameba.yml and the same compiled ameba, so a
# rule added or relaxed on the branch applies to both counts and never reads as a change.
set -uo pipefail

base=${1:-origin/main}
cd "$(dirname "$0")/.."

if ! git rev-parse --verify --quiet "$base" >/dev/null; then
  echo "ameba_gate: base ref '$base' not found (fetch it, or pass one)" >&2
  exit 2
fi
merge_base=$(git merge-base "$base" HEAD)

# Changed .cr files that still exist at HEAD. Renames count as the new path only.
# A while-read loop rather than `mapfile`: macOS ships bash 3.2, which has neither that
# builtin nor a tolerance for expanding an empty array under `set -u`.
files=()
while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(git diff --name-only --diff-filter=AMR "$merge_base" HEAD -- '*.cr' | grep -vE '^lib/' || true)
if [ "${#files[@]}" -eq 0 ]; then
  echo "ameba_gate: no Crystal files changed against $base"
  exit 0
fi

bin=${AMEBA_BIN:-}
if [ -z "$bin" ]; then
  bin=$(mktemp -t ameba.XXXXXX)
  crystal build lib/ameba/bin/ameba.cr -o "$bin" || { echo "ameba_gate: could not compile ameba" >&2; exit 2; }
  trap 'rm -f "$bin"' EXIT
fi
config=$(pwd)/.ameba.yml

# One line per finding in flycheck format, `path:line:col: ...`, folded to counts per path.
count() { # $1 = directory to lint in, rest = files
  local dir=$1; shift
  (cd "$dir" && "$bin" --format flycheck --no-color --config "$config" "$@" 2>/dev/null) |
    awk -F: '/^[^ ]+\.cr:[0-9]+:[0-9]+: / { n[$1]++ } END { for (f in n) print n[f], f }'
}

head_counts=$(count . ${files[@]+"${files[@]}"})

base_dir=$(mktemp -d -t ameba-base.XXXXXX)
trap 'rm -rf "$base_dir"; [ -n "${AMEBA_BIN:-}" ] || rm -f "$bin"' EXIT
git archive "$merge_base" | tar -x -C "$base_dir"
base_files=()
for f in ${files[@]+"${files[@]}"}; do
  [ -f "$base_dir/$f" ] && base_files+=("$f")
done
base_counts=""
[ "${#base_files[@]}" -gt 0 ] && base_counts=$(count "$base_dir" ${base_files[@]+"${base_files[@]}"})

fail=0
for f in ${files[@]+"${files[@]}"}; do
  h=$(awk -v f="$f" '$2 == f { print $1 }' <<<"$head_counts"); h=${h:-0}
  b=$(awk -v f="$f" '$2 == f { print $1 }' <<<"$base_counts"); b=${b:-0}
  if [ "$h" -gt "$b" ]; then
    echo "  $f: $b -> $h findings"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "ameba_gate: files above gained findings against $base. See them with:" >&2
  echo "  crystal run lib/ameba/bin/ameba.cr -- <file>" >&2
  exit 1
fi
echo "ameba_gate: no changed file gained findings against $base (${#files[@]} files)"
