# AGENTS.md: working on gori

gori is an intercepting proxy and workbench for **authorized** security testing, written in
Crystal and shipped as one binary. It sits in the loop between a client and its target,
capturing every request and response as a *flow* you can intercept, replay, fuzz, and scan
across HTTP/1.1, HTTP/2, WebSocket, gRPC, and SSE.

Three entry points, one engine layer underneath: `gori` (TUI), `gori mcp` (stdio JSON-RPC for
agents), `gori run <sub>` (headless, for scripts).

This file is the short version. [DESIGN.md](DESIGN.md) is the long one, and its numbering is
load-bearing: source comments cite principles as `(P4)`, `(P6/P7)` and sections as
`DESIGN.md §4`.

## Three things not to get wrong

### 1. Malformed input is the payload (P7)

A security proxy that sanitizes its operator's bytes is broken. The captured wire bytes are
canonical; parsed columns and pretty views are derived projections.

- There is **no** stdlib `HTTP::Request` parsing anywhere on the proxy path.
  `src/gori/proxy/codec/http1.cr` is a byte-exact sans-IO codec: it flags `malformed?` and
  keeps the octets rather than rejecting. `serialize_head` is the identity function.
- **The axis is provenance, not byte values.** The same octet gets three different answers:
  - **operator bytes** (imported HAR, an MCP `raw` request, a replay) go out verbatim, never
    sanitized. See the comment at `src/gori/import/builder.cr:31-38` and
    `src/gori/mcp/request_builder.cr` (`normalize_raw`).
  - **page-authored bytes** (a crawled `<a href>`) get percent-encoded where they merely
    break, and refused where they *frame*. See `src/gori/discover/url.cr` (`encode_unsafe`).
  - **remote-chosen bytes** (a redirect `Location`) are refused outright, not repaired. See
    `src/gori/fuzz/engine.cr` (redirect following).
- The predicate has **one home**: `Codec::Http1.request_token_safe?`. Do not re-derive it next
  to a new caller; that exact shape has already recurred three times (#390, #394, #397).
- Request framing rejects any obfuscation (`obfuscated_header?`); response framing is
  deliberately narrower (`framing_ambiguous?`, and read the comment above it). Do not
  "symmetrize" them: a request's peer is the operator's own browser, a response's peer is the
  whole internet.

### 2. Three surfaces, one engine layer

The TUI is the center of gravity. `gori mcp` and `gori run` are expected to stay at near
parity with it, and every parity gap found so far has been in a surface, not an engine.

- The shared seam is **`Plan.build(options, outbound) : Plan`**, one per tool:
  `src/gori/{fuzz,miner,discover,sequencer,repeater}/plan.cr`. Option *parsing* is
  surface-specific (an `OptionParser` on the CLI, the args hash on MCP, view state in the
  TUI); everything downstream of the normalized options has exactly one implementation.
- Adding a feature means: engine + `Plan.build` path once, then a thin adapter in each of
  `src/gori/tui/`, `src/gori/cli/run/`, `src/gori/mcp/tools/`. Parity is a convention held by
  each surface calling the same engines, not by a shared dispatcher ([DESIGN.md §2](DESIGN.md)).
- The seam is **not** the `Verb` registry. Its 318 verbs are TUI-only by decision: a verb reads
  its target from TUI selection state instead of naming it, and the missing argument schema is
  the blocker, not registry wiring (`src/gori/verb.cr`, DESIGN.md §7). Do not "fix" parity by
  wiring CLI or MCP into the registry.
- **Layering contract:** core subsystems must not know a surface exists. Self-check:

  ```sh
  grep -rnE '\b(Tui|CLI|MCP)::' \
    src/gori/{store,proxy,probe,fuzz,miner,discover,sequencer,oast}/ \
    src/gori/{store,probe,fuzz,miner,discover,sequencer,oast}.cr
  ```

  Today that returns exactly one hit, a comment in `src/gori/probe/group.cr`. A comment may
  point at a caller; code may not.
- Every gori-originated request goes through the `Gori::Outbound` chokepoint
  (`src/gori/outbound.cr`). It is a required constructor argument on `Fuzz::Sender` and
  `Repeater::Sender`, so an ungated sender is a compile error. Layer 1 (`check`) is the only
  per-surface variance: `Outbound.agent` (MCP, strict), `Outbound.cli` (permissive when
  unconfigured), `Outbound.interactive` (TUI, no up-front gate). Layer 2 (`sweep_block` /
  `send_block`: sandbox + explicit excludes) is identical everywhere and applies even when
  Layer 1 was waived. Judge the host actually dialled via `Outbound.scope_url`, never the
  request line.

### 3. Never stall the data path (P6), and don't crash

The proxy and the Store writer are hot paths. The proxy plus the HTTP/1.1 codec add only
~25µs per request (`src/gori/store/schema.cr:573-576`); capture, not proxying, has been the
bottleneck every time.

- gori runs on Crystal's **single-threaded** cooperative fiber scheduler. **Never** build or
  benchmark with `-Dpreview_mt`: `Store`, `Fuzz::Engine`, `Miner::Engine`, and
  `Store::SafeRegexp` all depend on it.
- All writes funnel through one writer fiber fed by a buffered `Channel`, batched into one
  transaction to amortize fsync. Replies and events fire only **after** commit, and a failed
  batch must not kill the writer fiber or every blocked caller deadlocks (`Store#writer_loop`).
- Measure, don't guess. 36 harnesses live in `bench/` and are cited back from the source they
  justify. Allocation-shaped wins are real; CPU micro-optimizations usually are not.
  `bench/proxy_bench.cr` has ±40% run-to-run noise, so use `bench/capture_bench.cr` for
  allocation deltas.
- Read the comment before touching these; each one is a crash or a DoS that already happened:
  TLS `sync_close: true` (`src/gori/proxy/tls/tunnel.cr:100`, SIGSEGV under a browser's h2
  connections), cross-close on tunnel teardown (`src/gori/proxy/pump.cr:13`, fd exhaustion),
  `TeardownLatch` must stay a reference type (`src/gori/proxy/conn/client_conn.cr:65`), no
  loop-variable capture in `spawn do…end` (`src/gori/proxy/server.cr`).

## Commands

`just --list` shows everything. The ones that matter:

| Task | Command |
| --- | --- |
| Build (debug, → `bin/gori`) | `just build` (`shards build`) |
| Full suite | `just test` (`crystal spec`) |
| One file or dir | `just test-file spec/store_spec.cr` |
| One area | `just test-tui`, `test-store`, `test-proxy`, `test-verb`, `test-repeater`, `test-discover`, `test-miner`, `test-oast`, `test-sequencer`, `test-import` |
| Format + lint check | `just check` (`crystal tool format --check` then `lib/ameba/bin/ameba.cr`) |
| Proxy benchmark | `just benchmark` |
| Version consistency | `just vc` |

ameba runs as the source file in `lib/`, not a `bin/ameba` binary. CI runs only build, spec,
and docker: there is **no lint or format gate** (see the comment in
`.github/workflows/ci.yml`), so `just check` is on you.

## Repo map

`src/main.cr` → `src/gori.cr` → `src/gori/`. Specs under `spec/` mirror the source tree.

| Path | What |
| --- | --- |
| `proxy/` | the MITM proxy: codec, conn, h2, tls, ws (directory-only, there is no `proxy.cr`) |
| `store.cr` + `store/` | SQLite persistence, migrations, reads |
| `tui/` | terminal UI: views, `controllers/`, `runner/` |
| `verb.cr` + `verb/` + `verbs/` | the TUI command system (definitions, keymap, `ExecContext`) |
| `cli/` | the `gori run` suite |
| `mcp/` | the MCP server and its tools |
| `scope.cr`, `outbound.cr` | scope model and the active-traffic chokepoint |
| `ql.cr`, `filter_ast.cr` | the query language behind every filter |
| one dir per tool | `repeater/`, `fuzz/`, `miner/`, `discover/`, `sequencer/`, `probe/`, `oast/`, `decoder/`, `import/`, `jwt/` |

## Before you commit

- `just check` and `just test` green.
- **Format only the files you changed** (`crystal tool format <files>`). A whole-tree format
  rewrites 100+ unrelated files due to Crystal version drift.
- Add or update specs mirroring the source you touched. `spec/spec_helper.cr` points
  `GORI_HOME` at a tempdir before requiring gori; engine specs that are not exercising the
  scope gate use the `ungated_outbound` helper rather than inventing a decision.
- If your change makes a `DESIGN.md` section wrong, fix that section in the same PR, and
  append to the §7 decision log instead of quietly widening a principle to fit.
- Changing `shard.lock` means regenerating `shards.nix` (`crystal2nix`) in the same commit.

## Traps

- Running a whole-tree `crystal tool format` and burying your diff.
- Building or benchmarking with `-Dpreview_mt`.
- Re-deriving a request-line safety check next to a new caller instead of calling
  `request_token_safe?`.
- "Sanitizing" bytes the operator handed gori to replay. That is the payload.
- Making the response framing rule as strict as the request rule.
- Wiring the verb registry into CLI or MCP to close a parity gap.
- Adding a `PlanError::Reason` member: three surfaces `case` it exhaustively.
- Crystal has no `override`, so a subclass silently shadows a base-class contract method.
  Audit overlay and controller subclasses for accidental shadowing.

## Where to read next

[DESIGN.md](DESIGN.md) §1 (principles P0–P8) → §2 (architecture) → §2.1 (layering) → §3
(scope) → §7 (decision log, append-only, dated).
[CONTRIBUTING.md](CONTRIBUTING.md) for setup and PR rules. [README.md](README.md) for the
product surface.
