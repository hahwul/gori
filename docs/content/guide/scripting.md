+++
title = "CLI Scripting with gori run"
description = "Drive gori headless with gori run: the same project and engines as the TUI, shaped for pipelines and CI."
weight = 80

[extra]
group = "Automation"
+++

gori has three entry points over one project and one engine: `gori` (the TUI, for you), **`gori run`** (the headless CLI, for scripts), and [`gori mcp`](/guide/mcp/) (for AI agents). This page is the scripting path.

`gori run` uses the same Store, Repeater, and sweep engines as the TUI, without the terminal front end. Anything you capture by hand is queryable from a script, and anything a script captures shows up when you open the TUI.

```bash
gori run <subcommand> [verb] [options]
```

Run `gori run -h` for the full subcommand list, or [CLI Reference](/reference/cli/) for every flag.

## Choosing a Project

Each project is its own SQLite database. Read subcommands resolve one in this order:

| Selector | Meaning |
|----------|---------|
| `--db=PATH` | A specific database file |
| `--project=NAME` | Match by short id, directory slug, display name, or unique id prefix (case-insensitive). A name that is one project's slug and another's display name, or two projects' shared display name, is refused with each candidate's slug and short id |
| `GORI_PROJECT=NAME` | Set in the environment, the project a script's every command reads (same matching as `--project`) |
| `gori run project switch NAME` | A standing pin, until `project switch --clear` |
| *(none of these)* | The most-recently-active project |

Avoid the last row in a script. A single write to any other project (`notes create --project demo`) makes that project the most recently active, and every later `--project`-less command follows it. Set `GORI_PROJECT` at the top of the script instead. A `GORI_PROJECT` or pin that names no project is refused, never skipped, and the stderr notice says which rule chose the project (`gori run: using project demo (from GORI_PROJECT) — name another with --project NAME or --db PATH`).

Either selector can sit before the subcommand or anywhere after it: `gori run --project demo history`, `gori run project --project demo scope list` and `gori run history --project demo` read the same project.

Passing both `--db` and `--project` is a usage error, and neither wins. That includes the
destructive verbs (`history delete`, `history clear`, `project delete`).

`gori run capture` differs on one point: it **creates or reopens** its target, where reads require a project that already exists.

Read subcommands open the store read-only and never take the capture lock, so they are safe to run against a project a live TUI is capturing into. SQLite WAL lets readers and the writer run at the same time. A `body:` query is the exception: answering it drains the search index, which is a write.

Write subcommands use the same WAL database as the TUI and MCP and serialize through the Store
writer. They may run while the TUI is open, but a capture commit can briefly own SQLite's writer
slot. A short-lived subcommand gives its SQLite open/writer waits a one-second budget. When the
slot stays busy, the required write exits non-zero and says the project is locked by another gori,
with the workaround (retry, or read it with a read-only subcommand). A subcommand that keeps the
project open for a whole run
(`discover`, `fuzz`, `import`, `mine` with a `--macro`, `probe`, `retest run`, `oast listen`/`resume`, `intercept`, `sitemap js --scan`) keeps
the standard five-second wait, the same one the TUI's capture writer uses. A
repeater send that already reached the network keeps its completed-send result even when its
response or History write cannot be persisted: it prints a warning to STDERR, and `--format json`
carries `response_saved` / `history_saved` with the reason, so a script can see that the request
went out and need not retry it because of the write failure.

```bash
gori run history --project my-engagement -q 'status:5xx'
gori run issues --db /path/to/project.db --format json
```

## The Scripting Contract

The JSON that `gori run` emits is a stable, documented shape meant for parsing. Four rules apply:

**STDOUT is data, STDERR is diagnostics.** Warnings, counts, notes, and export confirmations go to STDERR, so `gori run … | jq` receives only data.

**`--format` picks the shape.** Most subcommands take `text` (default) or `json`; some add `jsonl`, `raw`, `har`, `paths`, or `markdown`. `--json` is the same as `--format=json` everywhere `json` is offered. `json` is always one JSON document and `jsonl` always one object per line:

| Subcommand | `--format json` | `--format jsonl` |
|------------|-----------------|------------------|
| `history` | One array, streamed | One object per line |
| `capture` | One array, closed when the capture stops (`--for`, `--max`, Ctrl-C) | One object per flow, as it completes |
| `fuzz`, `mine`, `discover`, `authorize`, `cache-deception` | One JSON array (`fuzz`'s in index order) | One object per line, as each result lands |
| `sequence` | The single report | Each sample as it lands, then the report |

Use `jsonl` to consume a long sweep while it runs, and `json` for one document at the end (`… --format json | jq length` counts the rows).

**Exit codes are meaningful.**

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Error: a failed send, an unreadable project, a mutation that could not be applied, or a sweep (`fuzz`, `mine`, `discover`, `sequence`, `authorize`, `cache-deception`) in which no request got an answer |
| `3` | A verdict gate: `gori run fuzz --fail-if-no-matches` completed cleanly but nothing matched (a `--stop-on` / `--stop-after-matches` that fired exits `0`), or `gori run probe --fail-on=LEVEL` reported an issue at or above LEVEL |
| `130` | Interrupted by SIGINT/SIGTERM. `capture` (which exits `0` when `--for` or `--max` ends it), `fuzz`, `mine`, `discover`, `sequence`, `authorize`, `cache-deception` and `repeater minimize` flush what they collected first, so `&& next-step` does not treat a truncated run as a finished one |

A fuzz run where nothing matched *and* every send errored (target down, TLS failure, scope-blocked) exits `1`, so a script can tell "no findings" apart from "never reached the target" even without `--fail-if-no-matches` (with the flag, `3` wins).

**A closed pipe is not an error.** `gori run history | head -5` exits `0` and stays quiet.

```bash
# Every 5xx in the project, as JSON Lines, into jq
gori run history -q 'status:5xx' --limit 500 --format jsonl | jq -r '.url'

# Capture for five minutes into a named project, streaming to a file
gori run capture --project ci-run --for 5m --format jsonl > flows.jsonl

# Fail a CI job when the fuzzer finds a reflected marker
gori run fuzz 42 --wordlist payloads.txt --mr 'gori-canary' --fail-if-no-matches

# A create command's --format json is the new row, id included: no scraping prose
id=$(gori run repeater create -t https://api.example.com -f req.http --format json | jq .id)
rule=$(gori run project scope add --pattern=api.example.com --format json | jq .id)

# One request per path, no session per path, status and headers only
for p in /api/v1/items/{1..38}; do gori run send "https://api.example.com$p" --headers-only; done

# curl's flags mean what they mean to curl: -d is the body, -b a cookie
gori run send https://api.example.com/login -d 'user=a&pass=b' -b 'lang=en' --format json | jq '{status, error_kind, retryable}'

# Fail a CI job on any finding of medium or worse (exit 3)
gori run probe --fail-on medium
```

## Staying In Scope

Every active subcommand (anything that opens a socket) routes through the same outbound gate the TUI and MCP use. A project with scope rules refuses targets outside them, and `--allow-unscoped` waives that. The sandbox applies regardless. Excludes still hold for sweeps (fuzz, mine, discover, retest), while a hand-authored send passes an exclude the way the proxy does.

When you fuzz a raw request with `--request` or STDIN and name no project (no `--project` / `--db`, and no `GORI_PROJECT` in the environment), there is no scope to consult, so gori prints an unscoped warning to STDERR.

## Authenticated Sweeps

Session bindings (`$BIND.SESSION` and friends) live in the memory of the gori process that observed them. They are never persisted, because a restored token would be stale. In the TUI one process holds both the send and the sweep that follows, but each `gori run` is a separate process.

`--bind-from FLOW-ID` replays one captured flow first, so the response fills the bindings your fuzz, mine, sequence, or discover template reads in the same process.

```bash
gori run fuzz 42 --bind-from 41 --wordlist ids.txt
```

See [Session bindings](/guide/proxy/#session-bindings) for how extract rules define them.

## Process Hooks

gori has no plugin SDK, and none is planned. When a transform has to be computed (re-sign a
JWT, recompress a body, decrypt a proprietary envelope, run a real detector) you hand the bytes
to your own program. It reads the bytes on stdin and writes the replacement on stdout. The same
mechanism works at four seams.

| Seam | Where | What it does |
|------|-------|--------------|
| Rewriter `pipe` op | Rewriter tab, `gori run rewriter add --op=pipe`, MCP `create_rule` | The matched region goes to the command; its stdout replaces it, live in the proxy |
| Decoder `exec:` step | Decoder tab chain, `gori run decoder`, `§value¦chain§` markers | One chain step is a command instead of a converter |
| Probe `exec` rule | Probe rules, `gori run probe rules add --exec` | The region goes to the command; exit 0 raises a finding, stdout is the evidence |
| Miner `--hook` | `gori run mine --hook`, MCP `mine_start` `hook` | The whole assembled request goes to the command; its stdout is the request that ships; one hook per probe |

```bash
# Re-sign every JWT leaving the browser, with your own signer.
gori run rewriter add --op=pipe --match=regex --part=body \
  --find='eyJ[A-Za-z0-9._-]+' --value='./resign.sh --key dev.pem'

# Decode a base64 body and run it through your own parser.
gori run decoder 'base64-decode > exec:./parse-envelope --json' "$BLOB"

# Let a real detector decide, instead of a regex.
gori run probe rules add --title 'envelope leak' --exec --pattern './detect-leak --stdin'

# Mine hidden parameters on a signed API: sign every probe before it ships.
gori run mine 42 --locations=query --hook './sign.sh'
```

**The command is exec'd directly. There is no shell.** `argv` is tokenized with quote and
backslash rules (`'a b'`, `"a b"`, `a\ b`) and handed to `execvp` as data: `$FOO`, `*`, `` ` ``,
`;`, `&&`, `|` and `>` are ordinary characters in an argument. Captured bytes that flow through
a hook are never shell-interpreted. In a Decoder chain the three
step separators (`>`, `|`, `,`) are consumed before the step is read, so they cannot appear
inside an `exec:` step's arguments.

**A hook never stalls the proxy.** Every run has a hard wall-clock timeout (`hooks.timeout_secs`
in settings.json, 5s by default, 60s ceiling) and a 32 MiB stdout cap. If the command times out,
exits non-zero, cannot be spawned, or floods stdout, the original bytes pass through
unchanged and the failure is written to the project event feed as a notice. A Probe `exec`
rule's non-zero exit means "no finding" and is not a failure, but one killed by a signal is.
In the Rewriter the timeout is a *budget* shared by every pipe rule and
every match in one rewrite, so a pattern matching four hundred times (or four pipe rules on one
head) still costs that rewrite one timeout. A message is rewritten twice (its head and its
body), so one message can cost two timeouts.

**The Miner's hook runs once per probe.** An app that requires every parameter to carry an
HMAC, a signed envelope or a per-request nonce rejects a raw candidate before it can react to
it, so without a hook every probe looks the same. `--hook` hands each assembled request
(candidate injected, session bindings already resolved) to your command, and its stdout is what
ships. A hook that cannot run skips that probe with a reason, instead of sending an unsigned
request that the miner would read as a clean negative. The timeout is the same
`hooks.timeout_secs` budget, per outbound request, and a mine's request count is bounded by `--max-requests` and its own
bucket/bisection/confirm tree, so the total hook cost is bounded with it. The miner is
latency-bound (it counts round-trips), so a hook adds one fork-and-wait to each of them. A hook
is for a value your command can compute. A nonce or CSRF token the server hands out is fetched
instead by a [request-time macro](/guide/repeater-and-fuzzer/#rotating-tokens-with-a-macro)
(`--macro`), which replays a saved Repeater session before each probe.

**Two things hooks are not wired into.** The MCP `decode` tool refuses an `exec:` step (saved
chains included). It is exposed read-only and unbound, and stays pure compute. An agent
that needs a hook configures a `pipe` rewriter rule or an `exec` probe rule, both gated writes
the operator can see. A Probe `exec` rule runs once per flow on the passive analyzer. A slow
detector becomes the rule set's bottleneck under live capture, so keep its command fast.

**Drawing something is not running it.** Every surface that replays a chain to draw it
withholds the `exec:` step and marks the row held: the Rewriter's OUTPUT pane, the `^Q` chain
editor's preview, and a Fuzzer result row rebuilt from the template (which says the value shown
is the payload *before* that step). The Repeater's Content-Length reflection cannot say it in
place, so it stops rewriting the header instead; `^R` computes the real length from the rendered
bytes, and `^L` recomputes it once when you take the header over. Reopening a project rebuilds every saved Repeater tab and Decoder sub-tab
without firing their commands.

**Two places do run it.** `^R` does, and so does anything that hands you the bytes of a send (the
Repeater's `Copy as…` menu and its Comparer slot). A `curl` line that omitted the hook
would not reproduce the request.

**The Decoder tab's chain is live, including while you type it.** Every edit re-runs the
pipeline, and each prefix of a command you are
typing is itself a complete command (`exec:rm -rf /tmp/x` runs `rm -rf /tmp` on the way). Compose
the argv somewhere else and paste it, or point the step at a wrapper script you edit on disk.

**A hook runs as you.** It is not sandboxed, and carries the same trust as a `--config` file
or any other Rewriter rule. gori never invents a hook. Every hook is configuration a human
wrote, listed in the rule list it belongs to. When another session (an agent, a second TUI)
adds a `pipe` rule to a project you have open, this one tells you that it is now running a
local command on your behalf.

**A shared profile can carry one.** `rewriter` and `scan_rules` are ordinary exportable sections,
and a `decoder` chain named in `--sections` is too, so a hook travels in a
[profile](/reference/cli/#profiles) like any other rule, and a team can share one re-signing
hook. Two settings outside the hook seams run a command as
well, and travel the same way: `statusline.command` (through `/bin/sh -c`, or `cmd.exe /d /s /c` on Windows, on a timer) and
`editor.command`. Both ends say so. `gori settings export` counts what it wrote on stderr, and
`gori settings import` lists every command-carrying entry with its command and **refuses to write
until you pass `--allow-commands`**. Importing someone's profile is the same trust decision as
running their script, so read the commands first. There is no prompt, so a script can pass the
flag.

## What to Reach For

| Task | Subcommand |
|------|------------|
| Capture traffic in CI, headless | `capture` |
| Query or export History (incl. HAR) | `history`, `show` |
| Send one request, no session | `send` |
| Replay and diff a request | `repeater`, `compare` |
| Sweep payloads or hunt hidden params | `fuzz`, `mine` |
| Crawl and brute-force endpoints | `discover`, `sitemap` |
| Test access control across identities | `authorize`, `session` |
| Catch out-of-band callbacks | `oast` |
| Read a gRPC or GraphQL API's schema | `grpc`, `graphql` |
| Scan and triage | `probe`, `issues`, `notes` |
| Pure compute, no project needed | `decoder`, `jwt`, `cookie` |
| Manage projects, scope, env, network, rules | `project`, `rewriter`, `colormarker` |

## Next Steps

- [CLI Reference](/reference/cli/): every subcommand and flag
- [Query Language](/reference/query-language/): the filter syntax `-q` accepts
- [MCP Server](/guide/mcp/): the same project, driven by an AI agent instead of a shell
