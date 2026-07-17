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
  scheduler.
- Keep changes scoped and behavior-preserving unless the PR is explicitly a behavior
  change; note any intentional behavior change in the PR description.

## Where things live

`src/gori/` is organized by subsystem: `proxy/` (the MITM proxy), `store.cr` + `store/`
(SQLite persistence), `tui/` (terminal UI), `verb.cr` + `verbs/` (the command system),
`mcp/` (MCP server), `cli/` (the `gori run` suite), and one directory per tool
(`repeater`, `fuzz`, `miner`, `sequencer`, `discover`, `oast`, `probe`, `decoder`).
Specs under `spec/` mirror the source tree.

## Licensing

By contributing you agree that your contributions are licensed under the project's
[Apache-2.0](LICENSE) license.
