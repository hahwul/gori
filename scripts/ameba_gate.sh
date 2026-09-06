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
# from zero, so it has to be clean. A renamed file is scored against its old path, so moving
# one that carries backlog findings is not a regression; deleting a file never is.
#
# Both sides are linted with THIS checkout's .ameba.yml and the same compiled ameba, so a
# rule added or relaxed on the branch applies to both counts and never reads as a change.
# The HEAD side is the WORKING TREE (committed range plus uncommitted and untracked
# files), so `just lint-gate` judges the bytes on disk; in CI the two are the same.
set -uo pipefail

base=${1:-origin/main}
cd "$(dirname "$0")/.."

if ! git rev-parse --verify --quiet "$base" >/dev/null; then
  echo "ameba_gate: base ref '$base' not found (fetch it, or pass one)" >&2
  exit 2
fi
merge_base=$(git merge-base "$base" HEAD) || true
if [ -z "$merge_base" ]; then
  echo "ameba_gate: no merge base between '$base' and HEAD (unrelated histories?)" >&2
  exit 2
fi

# Changed .cr files, with the old path of a rename kept for the base-side lookup. A
# while-read loop rather than `mapfile`: macOS ships bash 3.2, which has neither that
# builtin nor a tolerance for expanding an empty array under `set -u`.
files=()
renamed_from="" # lines of "new<TAB>old"
while IFS=$'\t' read -r status a b; do
  case "$status" in
    R*) [ -n "$b" ] && { files+=("$b"); renamed_from+="$b"$'\t'"$a"$'\n'; } ;;
    D) ;;
    *) [ -n "$a" ] && files+=("$a") ;;
  esac
done < <({ git diff --name-status -M "$merge_base" HEAD -- '*.cr'
           git diff --name-status -M HEAD -- '*.cr'
           git ls-files --others --exclude-standard -- '*.cr' | sed $'s/^/A\t/'; } | grep -vE $'\t''lib/' || true)

# Unique, and only what still exists on disk.
seen=" "
uniq_files=()
for f in ${files[@]+"${files[@]}"}; do
  [ -f "$f" ] || continue
  case "$seen" in *" $f "*) continue ;; esac
  seen+="$f "
  uniq_files+=("$f")
done
files=(${uniq_files[@]+"${uniq_files[@]}"})
if [ "${#files[@]}" -eq 0 ]; then
  echo "ameba_gate: no Crystal files changed against $base"
  exit 0
fi

# The ameba binary as an ABSOLUTE path: `count` runs it from inside the base archive too,
# where a relative AMEBA_BIN would not resolve. Built once, without debug info: nothing
# here reads a backtrace, and the .dwarf sidecar macOS writes otherwise would outlive the
# trap that deletes the binary.
built=""
if [ -n "${AMEBA_BIN:-}" ]; then
  bin=$(cd "$(dirname "$AMEBA_BIN")" && pwd)/$(basename "$AMEBA_BIN")
else
  bin=$(mktemp -t ameba.XXXXXX); built=$bin
  crystal build --no-debug lib/ameba/bin/ameba.cr -o "$bin" || { echo "ameba_gate: could not compile ameba" >&2; exit 2; }
fi
# ameba exits 1 when it has findings, which is also what a missing or broken binary does,
# so ask it to identify itself before trusting a single count from it.
if ! "$bin" --version 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+'; then
  echo "ameba_gate: '$bin' does not run as ameba (\`$bin --version\` printed no version)" >&2
  exit 2
fi
base_dir=$(mktemp -d -t ameba-base.XXXXXX)
trap 'rm -rf "$base_dir"; if [ -n "$built" ]; then rm -f "$built" "$built.dwarf"; fi' EXIT
config=$(pwd)/.ameba.yml

# One line per finding in flycheck format, `path:line:col: ...`, folded to counts per path.
# ameba exits 0 with no findings and 1 with some; any other status means it did not run
# (a bad .ameba.yml key, a rule crashing on one file, a dylib mismatch) and must fail the
# gate rather than count as zero findings — a gate that goes green when its linter breaks
# is worse than none.
count() { # $1 = directory to lint in, rest = files
  local dir=$1; shift
  local out rc
  out=$(cd "$dir" && "$bin" --format flycheck --no-color --config "$config" "$@" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
    echo "ameba_gate: ameba exited $rc in $dir:" >&2
    printf '%s\n' "$out" | tail -20 >&2
    return 2
  fi
  printf '%s\n' "$out" | awk -F: '/^[^ ]+\.cr:[0-9]+:[0-9]+: / { n[$1]++ } END { for (f in n) print n[f], f }'
}
base_name() { # the path a file had at the merge base (its old path for a rename)
  local old
  old=$(printf '%s' "$renamed_from" | awk -F'\t' -v f="$1" '$1 == f { print $2 }')
  echo "${old:-$1}"
}

head_counts=$(count . ${files[@]+"${files[@]}"}) || exit 2

git archive "$merge_base" | tar -x -C "$base_dir"
base_files=()
for f in ${files[@]+"${files[@]}"}; do
  bf=$(base_name "$f")
  [ -f "$base_dir/$bf" ] && base_files+=("$bf")
done
base_counts=""
if [ "${#base_files[@]}" -gt 0 ]; then
  base_counts=$(count "$base_dir" ${base_files[@]+"${base_files[@]}"}) || exit 2
fi

fail=0
for f in ${files[@]+"${files[@]}"}; do
  bf=$(base_name "$f")
  h=$(awk -v f="$f" '$2 == f { print $1 }' <<<"$head_counts"); h=${h:-0}
  b=$(awk -v f="$bf" '$2 == f { print $1 }' <<<"$base_counts"); b=${b:-0}
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
