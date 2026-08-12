+++
title = "Scripting"
description = "Drive gori headless with gori run: the same project and engines as the TUI, shaped for pipelines and CI."
weight = 80

[extra]
group = "Automation"
+++

gori has three entry points over one project and one engine: `gori` (the TUI, for you), **`gori run`** (the headless CLI, for scripts), and [`gori mcp`](/guide/mcp/) (for AI agents). This page is the scripting path.

`gori run` is not a thin wrapper around the TUI — it is the same Store, Repeater, and sweep engines with a terminal-free front end. Anything you capture by hand is queryable from a script, and anything a script captures shows up when you open the TUI.

```bash
gori run <subcommand> [verb] [options]
```

Run `gori run -h` for the full subcommand list, or [CLI Reference](/reference/cli/) for every flag.

## Choosing a Project

Each project is its own SQLite database. Read subcommands resolve one in this order:

| Selector | Meaning |
|----------|---------|
| `--db=PATH` | A specific database file — wins over everything |
| `--project=NAME` | Match by short id, directory slug, display name, or unique id prefix (case-insensitive) |
| *(neither)* | The most-recently-active project |

`gori run capture` differs on one point: it **creates or reopens** its target, where reads require a project that already exists.

Read subcommands never take the capture lock, so they are safe to run against a project a live TUI is capturing into — SQLite WAL keeps both readers and the writer happy.

```bash
gori run history --project my-engagement -q 'status:5xx'
gori run issues --db /path/to/project.db --format json
```

## The Scripting Contract

The JSON that `gori run` emits is a stable, documented shape meant to be parsed, not eyeballed. Four rules make it pipe cleanly:

**STDOUT is data, STDERR is diagnostics.** Warnings, counts, notes, and export confirmations go to STDERR, so `gori run … | jq` never has to filter chatter out of its input.

**`--format` picks the shape.** Most subcommands take `text` (default) or `json`; some add `jsonl`, `raw`, `har`, `paths`, or `markdown`. Where a run streams, the two JSON shapes differ and the difference is worth knowing:

| Subcommand | `--format json` | `--format jsonl` |
|------------|-----------------|------------------|
| `capture`, `history` | One JSON object per line | Alias for `json` — same output |
| `fuzz`, `mine`, `discover` | Buffered; one JSON array at the end | One object per line, as each result lands |

Reach for `jsonl` when you want to consume a long sweep while it runs, and `json` when you want one document at the end.

**Exit codes are meaningful.**

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Error — a failed send, an unreadable project, a mutation that could not be applied |
| `3` | `gori run fuzz --fail-if-no-matches` completed cleanly but nothing matched |

A fuzz run where nothing matched *and* every send errored (target down, TLS failure, scope-blocked) exits `1`, not `3` — a script can tell "no findings" apart from "never reached the target" without `--fail-if-no-matches`.

**A closed pipe is not an error.** `gori run history | head -5` exits `0` and stays quiet, the way any Unix filter should.

```bash
# Every 5xx in the project, as JSON Lines, into jq
gori run history -q 'status:5xx' --limit 500 --format json | jq -r '.url'

# Capture for five minutes into a named project, streaming to a file
gori run capture --project ci-run --for 5m --format jsonl > flows.jsonl

# Fail a CI job when the fuzzer finds a reflected marker
gori run fuzz 42 --wordlist payloads.txt --mr 'gori-canary' --fail-if-no-matches
```

## Staying In Scope

Every active subcommand — anything that opens a socket — routes through the same outbound gate the TUI and MCP use. A project with scope rules refuses targets outside them; `--allow-unscoped` is the deliberate waiver, and the sandbox and explicit excludes apply regardless.

When you fuzz a raw request with `--request` or STDIN and pass no `--project` / `--db`, there is no scope to consult, so gori prints an explicit unscoped warning to STDERR rather than pretending it checked.

## Authenticated Sweeps

Session bindings (`$SESSION` and friends) live in the memory of the gori process that observed them — they are never persisted, because a restored token is stale by construction. That is fine in the TUI, where one process holds both the send and the sweep that follows, but `gori run` is one-shot per process.

`--bind-from FLOW-ID` closes the gap: it replays one captured flow first, so the response fills the bindings your fuzz, mine, sequence, or discover template reads in the same process.

```bash
gori run fuzz 42 --bind-from 41 --wordlist ids.txt
```

See [Session bindings](/guide/proxy/#session-bindings) for how extract rules define them.

## What to Reach For

| Task | Subcommand |
|------|------------|
| Capture traffic in CI, headless | `capture` |
| Query or export History (incl. HAR) | `history`, `show` |
| Replay and diff a request | `repeater`, `compare` |
| Sweep payloads or hunt hidden params | `fuzz`, `mine` |
| Crawl and brute-force endpoints | `discover`, `sitemap` |
| Scan and triage | `probe`, `issues`, `notes` |
| Pure compute, no project needed | `decoder`, `jwt`, `cookie` |
| Manage projects, scope, env, rules | `project`, `rewriter`, `colormarker` |

## Next Steps

- [CLI Reference](/reference/cli/): every subcommand and flag
- [Query Language](/reference/query-language/): the filter syntax `-q` accepts
- [MCP Server](/guide/mcp/): the same project, driven by an AI agent instead of a shell
