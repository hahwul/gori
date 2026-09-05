alias b := build
alias d := dev
alias t := test
alias vc := version-check
alias vu := version-update
alias bm := benchmark
alias db := docker-build
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

# Build through the flake — the exact path `nix profile install` takes.
[group('build')]
nix-build:
    nix build .#gori

# Regenerate nix/shards.nix from shard.lock (run it alongside any dependency change).
# crystal2nix takes no path arguments: it reads ./shard.lock and writes ./shards.nix,
# so the file is moved into nix/ afterwards — that is where flake.nix reads it from.
[group('build')]
nix-shards:
    nix run nixpkgs#crystal2nix
    mv shards.nix nix/shards.nix

# Verify nix/shards.nix still pins what shard.lock does — the check that makes the
# recipe above mandatory rather than customary. Forgetting it is silent: the flake
# keeps building the OLD revisions and `nix build` stays green. Reads the two files
# directly, so unlike `nix-build` it needs neither Nix nor the network, which is why
# CI can afford to run it on every PR.
[group('build')]
nix-shards-check:
    crystal run scripts/nix_shards_check.cr

# Nothing builds the image on a PR any more — ci.yml dropped its `build-docker`
# job, and publish-ghcr.yml only runs on a push to `main` — so this recipe is the
# pre-merge check that docker/Dockerfile still compiles.
#
# BuildKit is pinned because the ignore list lives at
# `docker/Dockerfile.dockerignore`: only BuildKit reads a Dockerfile-adjacent
# one. The classic builder looks for `.dockerignore` in the context root, finds
# none, and ships `bin/`, `lib/` and `.git/` into the build context instead.

# Build the container image locally (host arch only).
[group('docker')]
docker-build tag="gori:dev":
    DOCKER_BUILDKIT=1 docker build -f docker/Dockerfile -t {{tag}} .

# Bare, it starts the TUI, which needs the TTY `-it` gives it; state lives in the
# `gori` volume so the CA survives a run. Trailing args pick a headless
# subcommand: `just docker-run gori:dev run history`.

# Run the image `docker-build` produced.
[group('docker')]
docker-run tag="gori:dev" *args:
    docker run --rm -it -v gori:/data {{tag}} {{args}}

# Run all tests. `--no-debug` because the suite is one 7,000-unit binary whose compile the
# object cache barely helps (~35 s warm), and skipping DWARF takes ~17% off that. What it
# costs: an UNEXPECTED exception's backtrace shows mangled names without file:line —
# assertion failures still print `# spec/x_spec.cr:LINE`. CI keeps debug info (ci.yml).
# For the backtrace of a crashing example, rerun that file: `just test-file spec/x_spec.cr`,
# the one spec recipe that keeps debug info. Every other one passes the flag too: the object
# cache keys on bitcode, debug metadata is part of it, and alternating debug and no-debug
# runs re-emits every unit both ways.
[group('development')]
test:
    crystal spec --no-debug

# Run the specs that mirror what changed against BASE (scripts/spec_for_changes.sh) —
# the pre-flight before `just test`: a change's own specs compile in 3–9 s where the
# whole suite takes ~35 s. `just test-changed HEAD` covers uncommitted edits only.
[group('development')]
test-changed base="origin/main":
    #!/usr/bin/env bash
    set -euo pipefail
    files=$(scripts/spec_for_changes.sh {{base}})
    if [ -z "$files" ]; then echo "test-changed: no spec mirrors what changed against {{base}}"; exit 0; fi
    echo "$files" | sed 's/^/  /'
    crystal spec --no-debug $files

# Run the spec files CI's matrix gives one runner, e.g. `just test-shard 2` for the
# third of four. The partition is a function of the tree (scripts/spec_shard.sh), so
# this reproduces exactly what a red shard in Actions ran — CI calls the same script.

# Run one CI spec shard locally (INDEX is 0-based).
[group('development')]
test-shard index total="4":
    crystal spec --no-debug $(scripts/spec_shard.sh {{index}} {{total}})

# Run one spec file (or dir), e.g. `just test-file spec/store_spec.cr`.
[group('development')]
test-file path:
    crystal spec {{path}}

# Run every spec under one `spec/<area>` dir for fast feedback while iterating.
[group('development')]
test-tui:
    crystal spec --no-debug spec/tui

[group('development')]
test-store:
    crystal spec --no-debug spec/store

[group('development')]
test-proxy:
    crystal spec --no-debug spec/proxy

[group('development')]
test-verb:
    crystal spec --no-debug spec/verb

[group('development')]
test-repeater:
    crystal spec --no-debug spec/repeater

[group('development')]
test-discover:
    crystal spec --no-debug spec/discover

[group('development')]
test-miner:
    crystal spec --no-debug spec/miner

[group('development')]
test-oast:
    crystal spec --no-debug spec/oast

[group('development')]
test-sequencer:
    crystal spec --no-debug spec/sequencer

[group('development')]
test-import:
    crystal spec --no-debug spec/import

[group('development')]
test-mcp:
    crystal spec --no-debug spec/mcp

[group('development')]
test-settings:
    crystal spec --no-debug spec/settings

# Check code format and lint without changing files, plus the shards.nix drift gate —
# the point of that gate is that forgetting `just nix-shards` is silent, and a
# pre-commit check a contributor runs is where silence has to end, not CI.
# Paths are explicit and must stay in step with ci.yml's `format` job: bare
# `crystal tool format` walks the whole working directory, so once `shards install`
# has run it reformats `lib/` too — third-party code that is not ours to change.
[group('development')]
check:
    crystal tool format --check src spec bench scripts
    crystal run scripts/nix_shards_check.cr
    lib/ameba/bin/ameba.cr

# ameba as a diff gate: fail if any Crystal file changed against BASE gained findings.
# The same script the CI `lint-gate` job runs on pull requests.
[group('development')]
lint-gate base="origin/main":
    scripts/ameba_gate.sh {{base}}

# Auto-format code and fix lint issues.
[group('development')]
fix:
    crystal tool format src spec bench scripts
    lib/ameba/bin/ameba.cr --fix

# Check that every version-bearing file agrees: shard.yml, src/gori.cr,
# snap/snapcraft.yaml, aur/PKGBUILD and the spec assertion.
[group('version')]
version-check:
    crystal run scripts/version_check.cr

# Show the current version, then prompt for a new one (blank keeps it).
# Writes every version-bearing file and resets the PKGBUILD pkgrel to 1.
[group('version')]
version-update:
    crystal run scripts/version_update.cr

# Type-check every harness in bench/ without generating code.
#
# AGENTS.md says "measure, don't guess" and points at these harnesses, but nothing built
# them: `just check` only FORMATS bench/, and CI ran build + spec + format. Seventeen had
# rotted silently — most by requiring a subtree (`src/gori/tui`) that stopped being
# self-contained, two by drifting off an interface that grew a parameter. The CI
# `benchmarks` job runs the SAME script, so the two cannot check different things.
[group('benchmark')]
benchmark-check:
    scripts/bench_check.sh

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
