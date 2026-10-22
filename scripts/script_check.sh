#!/usr/bin/env bash
# Type-checks every program in scripts/ and eval/ and reports the ones that no longer compile.
#
# Usage: scripts/script_check.sh   (just scripts-check, and the CI `benchmarks` job)
#
# The sibling of `scripts/bench_check.sh` (and runs its loop), for the same reason and
# against the same failure mode: nothing else in CI compiles these files, so one rots
# silently until someone reaches for it. `scripts/seed_demo.cr` had — four
# `update_repeater_response` call sites predated the `request_sha256:` argument #1047 added,
# and the demo seeder every manual TUI pass starts from was unbuildable on main with nothing
# red to say so.
#
# `--no-codegen`, and nothing is RUN: `seed_demo.cr` writes a project database and
# `mock_update_server.cr` binds a port. The question here is only whether each still
# describes the API it calls.
#
# eval/ rides along for the same reason: `eval/fixtures.cr` requires `src` and inserts flows
# through the Store API, and nothing else compiles it either (`just eval` is run by hand).
set -uo pipefail

cd "$(dirname "$0")/.."
exec scripts/bench_check.sh scripts programs scripts/*.cr eval/*.cr
