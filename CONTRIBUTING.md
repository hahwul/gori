# Contributing to gori

Thanks for helping improve gori. This is a security tool for **authorized** testing
only — please keep contributions aligned with that purpose.

## Getting set up

Requires [Crystal](https://crystal-lang.org) `>= 1.21.0` and the native libraries used
for HTTP body decode:

- macOS: `brew install crystal brotli zstd sqlite`
- Debian/Ubuntu: `apt install crystal libbrotli-dev libzstd-dev libsqlite3-dev`
- Nix: `nix develop` sets all of it up, pinned to the compiler CI builds with

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
- If you change `shard.lock`, regenerate the Nix dependency set in the same commit:
  `crystal2nix` (in the dev shell) rewrites `shards.nix`. `just vu` keeps `flake.nix`'s
  version in step with `shard.yml`.
- Keep changes scoped and behavior-preserving unless the PR is explicitly a behavior
  change; note any intentional behavior change in the PR description.
- Add a `CHANGELOG.md` line under `## Unreleased` for anything a user would notice, in
  the shape the released sections use: **one line per theme, plain, with the issue or PR
  numbers in parentheses at the end**. Join an existing theme line rather than adding a
  fourth bullet about the same area.

  The reasoning that justifies the change does not belong there. It belongs in the PR
  body — which the issue number already points at — or, when it settles a design
  question, in [DESIGN.md §7](DESIGN.md). A changelog entry that has to be read twice is
  one nobody can lift into release notes (#709).

## Where things live

`src/gori/` is organized by subsystem: `proxy/` (the MITM proxy), `store.cr` + `store/`
(SQLite persistence), `tui/` (terminal UI), `verb.cr` + `verbs/` (the command system),
`mcp/` (MCP server), `cli/` (the `gori run` suite), and one directory per tool
(`repeater`, `fuzz`, `miner`, `sequencer`, `discover`, `oast`, `probe`, `decoder`).
Specs under `spec/` mirror the source tree: `spec/<dir>/<name>_spec.cr` covers
`src/gori/<dir>/<name>.cr`. The root of `spec/` holds two kinds of file and nothing else —
the spec for a top-level source file (`spec/scope_spec.cr` ↔ `src/gori/scope.cr`), and a
cross-cutting *seam* spec that asserts a property of several subsystems at once and so
mirrors no single file (`layering_spec.cr`, `send_seam_provenance_spec.cr`).

[DESIGN.md](DESIGN.md) covers the *why*: the P0 to P8 principles that source comments
cite inline (`(P4)`, `(P6/P7)`), the layering contract those directories have to honour,
and the Scope / QL / rendering / data-model sections that comments cite as `DESIGN.md §N`.
Read it before adding a subsystem, and if your change makes a section wrong, fix the
section in the same PR.

## Licensing

By contributing you agree that your contributions are licensed under the project's
[Apache-2.0](LICENSE) license.
