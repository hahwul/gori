+++
title = "Scanning & Findings"
description = "The Prism scanner, the Param Miner, and triaging results into Findings."
+++

gori includes automated analysis that runs alongside your manual testing. **Prism** watches traffic for issues, the **Param Miner** discovers hidden inputs, and **Findings** is where results get triaged.

## Prism — the Scanner

**Prism** groups security issues by type and severity. Its passive checks run as you browse — with zero extra requests — inspecting **History** flows and **Replay** send results for things like missing or weak security headers, cookie flags, information leaks, technology fingerprints (including WebSocket), CORS misconfigurations, and secrets in WebSocket text frames. Active checks send a small, controlled number of probes (for example, a CORS arbitrary-origin reflection test) only when you ask for them.

Run passive analysis headless — it reads what's already captured (History + Replay responses) and sends nothing:

```bash
gori run prism                       # all issues
gori run prism --severity high       # only high-severity
gori run prism --category cors       # a single category
gori run prism -q 'host:example.com' # filter History with QL (Replay still scanned)
```

Categories include `headers`, `cookies`, `tech`, `infoleak`, and `cors`; severities run `info`, `low`, `medium`, `high`, `critical`.

## Param Miner

The **Miner** discovers parameters a server accepts but doesn't advertise. Point it at a flow and it probes candidate names across locations — query string, form body, JSON, headers, and cookies — bucketing guesses efficiently and reporting the ones that change the response.

```bash
gori run mine <flow-id> \
  --locations query,headers \
  --wordlist params.txt \
  --bucket 50
```

> The Miner tab is hidden by default. Enable it from the command palette (`Ctrl-P`) when you need it.

## Findings

**Findings** is your triage list. Promote anything worth tracking — from Prism, the Fuzzer, the Miner, or your own inspection — into a finding with a severity and a status, and jump straight back to the evidence flow. Findings can be exported for reporting:

```bash
gori run findings --format markdown --export report.md
```

## Notes & Comparer

Two more tools round out analysis:

- **Notes** — free-form, per-project Markdown notes with links back to entities.
- **Comparer** — load two flows into slots A and B for a line-by-line diff, useful for spotting how a response changed between requests.

## Next Steps

- [MCP Server](/guide/mcp/) — let an agent run scans and read findings
- [CLI Reference](/reference/cli/) — `prism`, `mine`, and `findings` flags
- [Query Language](/reference/query-language/) — scope your scans
