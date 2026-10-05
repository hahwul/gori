#!/usr/bin/env bash
# Print the CI test mode for a pull request: full, changed, or none.
#
# `scripts/spec_for_changes.sh` owns source-to-spec mapping. This wrapper only decides
# whether the result is safe to use as a fast PR check, or whether the change affects the
# test machinery itself and therefore needs the full four-shard suite.
#
# Usage: scripts/ci_test_scope.sh BASE_REF
set -euo pipefail

base=${1:?usage: ci_test_scope.sh BASE_REF}
cd "$(dirname "$0")/.."

if ! git rev-parse --verify --quiet "$base" >/dev/null; then
  echo "ci_test_scope: base ref '$base' not found (fetch it, or pass one)" >&2
  exit 2
fi

merge_base=$(git merge-base "$base" HEAD)
force_full=0

# These files can change what gets built or what this selector means. A targeted result
# would make a broken selector look like a green test run, which is worse than the extra
# four runners.
while IFS= read -r f; do
  case "$f" in
    .github/workflows/ci.yml|shard.yml|shard.lock|packaging/nix/shards.nix|\
    scripts/ci_test_scope.sh|scripts/spec_for_changes.sh|scripts/spec_shard.sh)
      force_full=1
      ;;
  esac
done < <(
  git diff --name-only "$merge_base" HEAD
  git diff --name-only HEAD
  git ls-files --others --exclude-standard
)

if [ "$force_full" -eq 1 ]; then
  echo full
  exit 0
fi

files=$(scripts/spec_for_changes.sh "$base")
if [ -z "$files" ]; then
  echo none
  exit 0
fi

# A shared source file makes the mapper print the complete sorted spec inventory. Compare
# the inventories rather than duplicating that knowledge here; the mapper remains the one
# place that decides when a source change has no honest narrower mirror.
all_specs=$(find spec -name '*_spec.cr' -print | sort)
if [ "$files" = "$all_specs" ]; then
  echo full
else
  echo changed
fi
