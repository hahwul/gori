alias b := build
alias d := dev
alias t := test
alias vc := version-check
alias vu := version-update
alias bm := benchmark
alias ds := docs-serve

# List available tasks.
default:
    @just --list

# Build gori binary, then run the TUI (debug build; fast incremental compile).
[group('build')]
dev: build
    ./bin/gori

# Build gori binary (debug; outputs to bin/gori).
[group('build')]
build:
    shards build

# Run all tests.
[group('development')]
test:
    crystal spec

# Run one spec file (or dir), e.g. `just test-file spec/store_spec.cr`.
[group('development')]
test-file path:
    crystal spec {{path}}

# Run every spec under one `spec/<area>` dir for fast feedback while iterating.
[group('development')]
test-tui:
    crystal spec spec/tui

[group('development')]
test-store:
    crystal spec spec/store

[group('development')]
test-proxy:
    crystal spec spec/proxy

[group('development')]
test-verb:
    crystal spec spec/verb

[group('development')]
test-repeater:
    crystal spec spec/repeater

[group('development')]
test-discover:
    crystal spec spec/discover

[group('development')]
test-miner:
    crystal spec spec/miner

[group('development')]
test-oast:
    crystal spec spec/oast

[group('development')]
test-sequencer:
    crystal spec spec/sequencer

[group('development')]
test-import:
    crystal spec spec/import

# Check code format and lint without changing files.
[group('development')]
check:
    crystal tool format --check
    lib/ameba/bin/ameba.cr

# Auto-format code and fix lint issues.
[group('development')]
fix:
    crystal tool format
    lib/ameba/bin/ameba.cr --fix

# Check that the version in shard.yml and src/gori.cr agree.
[group('version')]
version-check:
    #!/usr/bin/env bash
    set -euo pipefail
    shard_ver=$(grep '^version:' shard.yml | head -1 | sed 's/version:[[:space:]]*//')
    code_ver=$(grep 'VERSION = ' src/gori.cr | head -1 | sed 's/.*"\(.*\)".*/\1/')
    echo "shard.yml:   $shard_ver"
    echo "src/gori.cr: $code_ver"
    if [ "$shard_ver" != "$code_ver" ]; then
        echo "✗ version mismatch" >&2
        exit 1
    fi
    echo "✓ versions match"

# Show the current version, then prompt for a new one (blank keeps it).
[group('version')]
version-update:
    #!/usr/bin/env bash
    set -euo pipefail
    current=$(grep '^version:' shard.yml | head -1 | sed 's/version:[[:space:]]*//')
    echo "Current version: $current"
    read -r -p "New version (blank to keep): " target
    if [ -z "$target" ]; then
        echo "No change."
        exit 0
    fi
    perl -i -pe 's/^version:\s*\S+/version: '"$target"'/' shard.yml
    perl -i -pe 's/(VERSION = ")[^"]*(")/${1}'"$target"'${2}/' src/gori.cr
    echo "✓ version: $current -> $target"

# Build (release) and run the end-to-end proxy benchmark harness.
[group('benchmark')]
benchmark:
    crystal build bench/proxy_bench.cr -o bin/proxy_bench --release
    ./bin/proxy_bench

# Seed the local "demo" project with a varied dataset for the TUI to explore.
[group('demo')]
seed-demo:
    crystal run scripts/seed_demo.cr

# Local mock GitHub releases server for testing `gori update` download progress.
# In another terminal:
#   GORI_UPDATE_API_URL=http://127.0.0.1:8765/repos/hahwul/gori/releases/latest ./bin/gori update
[group('development')]
update-mock port="8765" size="4M" throttle="400k":
    crystal run scripts/mock_update_server.cr -- --port {{port}} --size {{size}} --throttle {{throttle}}

[group('documents')]
docs-serve:
    hwaro serve -i docs --base-url="http://localhost:3000"

# Re-capture every TUI screenshot for the docs (dark → tui/, light → tui/light/).
[group('documents')]
docs-shots: build
    docs/tools/tui-capture/capture.sh

# Re-capture only the light-theme TUI screenshots (→ tui/light/).
[group('documents')]
docs-shots-light: build
    SHOTS="goriday:light" docs/tools/tui-capture/capture.sh
