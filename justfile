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

[group('development')]
test-mcp:
    crystal spec spec/mcp

[group('development')]
test-settings:
    crystal spec spec/settings

# Check code format and lint without changing files.
# Paths are explicit and must stay in step with ci.yml's `format` job: bare
# `crystal tool format` walks the whole working directory, so once `shards install`
# has run it reformats `lib/` too — third-party code that is not ours to change.
[group('development')]
check:
    crystal tool format --check src spec bench scripts
    lib/ameba/bin/ameba.cr

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
