# Contributing to gori

Thanks for helping improve gori. This is a security tool for **authorized** testing
only — please keep contributions aligned with that purpose.

## Getting set up

Requires [Crystal](https://crystal-lang.org) `>= 1.20.2` and the native libraries used
for HTTP body decode:

- macOS: `brew install crystal brotli zstd sqlite`
- Debian/Ubuntu: `apt install crystal libbrotli-dev libzstd-dev libsqlite3-dev`

Then:

```sh
shards install   # fetch dependencies (incl. ameba, into lib/)
just build       # → bin/gori
just test        # run the spec suite
```

`just --list` shows every task. Build without the native codecs (gzip/deflate still
work via stdlib) with `crystal build -Dwithout_native_codecs`.

## Before you open a PR

- **`just check`** must pass — `crystal tool format --check` and ameba. Format only the
  files you changed (`crystal tool format <files>`); never run a whole-tree format (it
  reformats dozens of unrelated files due to Crystal version drift).
- **`just test`** must be green. Add or update specs under `spec/` mirroring the source
  you touched; `just test-<area>` runs a single subdir while iterating.
- Never build or benchmark with `-Dpreview_mt` — gori assumes the single-threaded fiber
  scheduler (see DESIGN.md §2).
- Keep changes scoped and behavior-preserving unless the PR is explicitly a behavior
  change; note any intentional behavior change in the PR description.

## Where things live

Read **CLAUDE.md** for the module map, the build/test/lint commands, the TUI seams
(`TabController`/`Host`, `Overlay`/`OverlayHost`), and the "how to add a feature"
checklist. Read **DESIGN.md** for the architecture and the P0–P8 design principles the
code cites inline.

## Licensing

By contributing you agree that your contributions are licensed under the project's
[Apache-2.0](LICENSE) license.
