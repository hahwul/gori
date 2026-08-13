#!/usr/bin/env bash
# Type-checks every harness in bench/ and reports the ones that no longer compile.
#
# Usage: scripts/bench_check.sh   (just benchmark-check, and the CI `benchmarks` job)
#
# ONE implementation with two callers on purpose. The justfile recipe is the local entry
# point and CI runs the same script, so the two cannot drift into checking different things —
# which matters here more than usual, because the failure this guards against is silent by
# construction: nothing else in CI compiles bench/, so a rotted harness stays green until
# someone reaches for it mid-investigation. Seventeen had rotted that way before this
# existed.
#
# `--no-codegen`: this asks whether each harness still describes the API it measures, not
# whether it produces a fast binary. Harnesses are never RUN here — several want a loopback
# origin or a seeded multi-GB database, and their run times are minutes.
set -uo pipefail

cd "$(dirname "$0")/.."

fail=0
broken=()
for f in bench/*.cr; do
  if ! crystal build "$f" -o /dev/null --no-codegen 2>/dev/null; then
    broken+=("$f")
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "bench harnesses that no longer compile:" >&2
  for f in "${broken[@]}"; do
    echo "  $f" >&2
  done
  echo "" >&2
  echo "Re-run one for the compiler's reason:  crystal build ${broken[0]} -o /dev/null --no-codegen" >&2
  exit 1
fi

echo "all bench harnesses build ($(ls bench/*.cr | wc -l | tr -d ' ') harnesses)"
