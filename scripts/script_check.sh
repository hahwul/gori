#!/usr/bin/env bash
# Type-checks every program in scripts/ and reports the ones that no longer compile.
#
# Usage: scripts/script_check.sh   (just scripts-check, and the CI `benchmarks` job)
#
# The sibling of `scripts/bench_check.sh`, for the same reason and against the same failure
# mode: nothing else in CI compiles these files, so one rots silently until someone reaches
# for it. `scripts/seed_demo.cr` had — four `update_repeater_response` call sites predated
# the `request_sha256:` argument #1047 added, and the demo seeder every manual TUI pass
# starts from was unbuildable on main with nothing red to say so.
#
# `--no-codegen`, and nothing is RUN: `seed_demo.cr` writes a project database and
# `mock_update_server.cr` binds a port. The question here is only whether each still
# describes the API it calls.
set -uo pipefail

cd "$(dirname "$0")/.."

fail=0
broken=()
for f in scripts/*.cr; do
  if ! crystal build "$f" -o /dev/null --no-codegen 2>/dev/null; then
    broken+=("$f")
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "scripts that no longer compile:" >&2
  for f in "${broken[@]}"; do
    echo "  $f" >&2
  done
  echo "" >&2
  echo "Re-run one for the compiler's reason:  crystal build ${broken[0]} -o /dev/null --no-codegen" >&2
  exit 1
fi

echo "all scripts build ($(ls scripts/*.cr | wc -l | tr -d ' ') programs)"
