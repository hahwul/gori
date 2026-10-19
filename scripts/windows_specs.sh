#!/usr/bin/env bash
# Run spec files against a prebuilt Windows spec runner, one process per file (#1510).
#
# One process per file: on Windows an exception raised from an `ensure` while another unwinds
# aborts the whole process (FAST_FAIL), so a single run would lose every result after the first
# such failure. A failed file runs once more, alone: the heavy migration specs can outrun the
# timeout when they share the runner with three others. A file that fails twice is a real failure.
#
# usage: scripts/windows_specs.sh RUNNER.exe SPEC_FILE...
set -euo pipefail
runner=${1:?usage: windows_specs.sh RUNNER.exe SPEC_FILE...}
shift
export RUNNER=$runner

run_file() {
  locs=$(grep -nE '^\s*it "' "$1" | cut -d: -f1 | sed "s|^|--location $1:|" || true)
  [ -n "$locs" ] || return 0
  # An outer timeout too: a call that blocks the whole scheduler starves the watchdog.
  # `|| code=$?`: the retry below calls this from this script's own `-e` shell.
  code=0
  out=$(timeout -k 5 400 "$RUNNER" --verbose $locs 2>&1) || code=$?
  [ "$code" -eq 0 ] && return 0
  [ "$code" -eq 124 ] && out="$out
TIMEOUT: still running after 400s"
  printf '::group::FAIL %s\n%s\n::endgroup::\n' "$1" "$(echo "$out" | tail -60)"
}
export -f run_file

start=$SECONDS
printf '%s\n' "$@" | xargs -P 4 -I{} bash -c 'run_file "$1"' _ {} | tee spec-results.txt
sed -n 's/^::group::FAIL //p' spec-results.txt > retry.txt
: > spec-retry.txt
while read -r f; do
  run_file "$f" | tee -a spec-retry.txt
done < retry.txt
failed=$(grep -c '^::group::FAIL' spec-retry.txt || true)
echo "$# spec files in $((SECONDS - start))s; failing: $failed (of $(wc -l < retry.txt) retried alone)"
test "$failed" -eq 0
