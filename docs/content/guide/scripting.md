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

Read subcommands open the store read-only and never take the capture lock, so they are safe to run against a project a live TUI is capturing into — SQLite WAL keeps both readers and the writer happy. A `body:` query is the exception: answering it drains the search index, which is a write.

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

## Process Hooks

gori has no plugin SDK and is not getting one. When a transform has to be *computed* — re-sign a
JWT, recompress a body, decrypt a proprietary envelope, run a real detector — you hand the bytes
to a program you already own. Bytes in on stdin, replacement bytes out on stdout. That is the
whole extension surface, and it is the same primitive at three seams.

| Seam | Where | What it does |
|------|-------|--------------|
| Rewriter `pipe` op | Rewriter tab, `gori run rewriter add --op=pipe`, MCP `create_rule` | The matched region goes to the command; its stdout replaces it, live in the proxy |
| Decoder `exec:` step | Decoder tab chain, `gori run decoder`, `§value¦chain§` markers | One chain step is a command instead of a converter |
| Probe `exec` rule | Probe rules, `gori run probe rules add --exec` | The region goes to the command; exit 0 raises a finding, stdout is the evidence |
| Miner `--hook` | `gori run mine --hook`, MCP `mine_start` `hook` | The whole assembled request goes to the command; its stdout is the request that ships — one hook per probe |

```bash
# Re-sign every JWT leaving the browser, with your own signer.
gori run rewriter add --op=pipe --match=regex --part=body \
  --find='eyJ[A-Za-z0-9._-]+' --value='./resign.sh --key dev.pem'

# Decode a base64 body, run it through your own parser, pretty-print the result.
gori run decoder 'base64-decode > exec:./parse-envelope --json > json-pretty' "$BLOB"

# Let a real detector decide, instead of a regex.
gori run probe rules add --title 'envelope leak' --exec --pattern './detect-leak --stdin'

# Mine hidden parameters on a signed API: sign every probe before it ships.
gori run mine 42 --locations=query --hook './sign.sh'
```

**The command is exec'd directly. There is no shell.** `argv` is tokenized with quote and
backslash rules (`'a b'`, `"a b"`, `a\ b`) and handed to `execvp` as data — `$FOO`, `*`, `` ` ``,
`;`, `&&`, `|` and `>` are ordinary characters in an argument, never operators. Captured bytes
that flow through a hook can therefore never be shell-interpreted. In a Decoder chain the three
step separators (`>`, `|`, `,`) are consumed before the step is read, so they cannot appear
inside an `exec:` step's arguments.

**A hook never stalls the proxy.** Every run has a hard wall-clock timeout (`hooks.timeout_secs`
in settings.json, 5s by default, 60s ceiling) and a 32 MiB stdout cap. If the command times out,
exits non-zero, cannot be spawned, or floods stdout, the **original bytes pass through
unchanged** and the failure is written to the project event feed as a notice. A wedged hook can
never cost you a flow. In the Rewriter the timeout is a *budget* shared by every pipe rule and
every match in one rewrite, so a pattern matching four hundred times — or four pipe rules on one
head — still costs that rewrite one timeout. A message is rewritten twice (its head and its
body), so that is the bound it sees.

**The Miner's hook runs once per probe, and pays for a signed API.** An app that requires every
parameter to carry an HMAC, a signed envelope or a per-request nonce rejects a raw candidate
before it can react to it, so without a hook there is nothing to mine — every probe looks the
same. `--hook` hands each assembled request (candidate injected, session bindings already
resolved) to your command, and its stdout is what ships; a hook that cannot run **skips that
probe with a reason** rather than sending an unsigned request that the app would reject and the
miner would then read as a clean negative. The timeout is the same `hooks.timeout_secs` budget,
**per outbound request** — and a mine's request count is bounded by `--max-requests` and its own
bucket/bisection/confirm tree, so the total hook cost is bounded with it. The miner is
latency-bound (it counts round-trips), so a hook adds one fork-and-wait to each of them.

**Two things hooks are deliberately not wired into.** The MCP `decode` tool refuses an `exec:`
step (saved chains included) — it is exposed read-only and unbound, and stays pure compute; an
agent that needs a hook configures a `pipe` rewriter rule or an `exec` probe rule, both gated
writes the operator can see. And a Probe `exec` rule runs **once per flow** on the passive
analyzer, so a slow detector is the whole rule set's bottleneck under live capture — keep its
command fast.

**Drawing something is not running it.** Every surface that replays a chain in order to *draw*
withholds the `exec:` step and marks the row held: the Rewriter's OUTPUT pane, the `^Q` chain
editor's preview, and a Fuzzer result row rebuilt from the template (which says the value shown
is the payload *before* that step). The Repeater's Content-Length reflection cannot say it in
place, so it stops rewriting the header instead — `^R` computes the real length from the rendered
bytes, and `^L` recomputes it once at the moment you take the header over. **Restoring is not
running either**: reopening a project rebuilds every saved Repeater tab and Decoder sub-tab
without firing their commands.

**Two places do run it, and both are asking for the bytes of a send.** `^R` obviously. Less
obviously, anything that hands you those exact bytes — the Repeater's `Copy as…` menu and its
Comparer slot — because a `curl` line that omitted the hook would not reproduce the request it
claims to be.

**The Decoder tab's chain is live, including while you type it.** That tab is the workbench
`exec:` was built for, so every edit re-runs the pipeline — and each prefix of a command you are
typing is itself a complete command (`exec:rm -rf /tmp/x` runs `rm -rf /tmp` on the way). Compose
the argv somewhere else and paste it, or point the step at a wrapper script you edit on disk.

**A hook runs as you.** It is not sandboxed, jailed or confined — same trust level as a
`--config` file or any other Rewriter rule. gori never invents a hook: every one of them is
configuration a human wrote, and each is listed plainly in the rule list it belongs to. When
another session (an agent, a second TUI) adds a `pipe` rule to a project you have open, this one
tells you in as many words that it is now running a local command on your behalf.

**A shared profile can carry one.** `rewriter` and `scan_rules` are ordinary exportable sections,
and a `decoder` chain named in `--sections` is too — so a hook travels in a
[profile](/reference/cli/#profiles) like any other rule, which is the point: a team standardising
on one re-signing hook is why hooks exist. Two settings outside the hook seams run a command as
well, and travel the same way: `statusline.command` (through `/bin/sh -c`, on a timer) and
`editor.command`. Both ends say so. `gori settings export` counts what it wrote on stderr, and
`gori settings import` lists every command-carrying entry with its command and **refuses to write
until you pass `--allow-commands`**. Importing someone's profile is the same trust decision as
running their script, so read the commands first — the flag is the acknowledgement, and it is
answerable in a script because there is no prompt.

## What to Reach For

| Task | Subcommand |
|------|------------|
| Capture traffic in CI, headless | `capture` |
| Query or export History (incl. HAR) | `history`, `show` |
| Replay and diff a request | `repeater`, `compare` |
| Sweep payloads or hunt hidden params | `fuzz`, `mine` |
| Crawl and brute-force endpoints | `discover`, `sitemap` |
| Test access control across identities | `authorize` |
| Scan and triage | `probe`, `issues`, `notes` |
| Pure compute, no project needed | `decoder`, `jwt`, `cookie` |
| Manage projects, scope, env, rules | `project`, `rewriter`, `colormarker` |

## Next Steps

- [CLI Reference](/reference/cli/): every subcommand and flag
- [Query Language](/reference/query-language/): the filter syntax `-q` accepts
- [MCP Server](/guide/mcp/): the same project, driven by an AI agent instead of a shell
