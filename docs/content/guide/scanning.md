+++
title = "Scanning & Findings"
description = "The Prism scanner, the Param Miner, and triaging results into Findings."
+++

gori includes automated analysis that runs alongside your manual testing. **Prism** watches traffic for issues, the **Param Miner** discovers hidden inputs, and **Findings** is where results get triaged.

## Prism — the Scanner

**Prism** groups security issues by type and severity. Its passive checks run as you browse — with zero extra requests — inspecting **History** flows and **Replay** send results. Active checks send a small, controlled number of probes only when you ask for them.

| Category | What it covers |
|----------|----------------|
| `headers` | Security headers (HSTS, CSP, …), cleartext Basic auth, mixed content, cacheable API responses |
| `cookies` | `Secure` / `HttpOnly` / `SameSite` and related cookie hygiene |
| `tech` | Technology and protocol fingerprints (also surface on the Project tab) |
| `infoleak` | Body disclosures, secrets in URLs / WS frames, GraphQL introspection |
| `cors` | Wildcard / null origin / credentialed misconfigurations; active origin reflection |
| `active` | Confirmed by a probe (for example reflected parameters) — TUI active scan only |

Severities run `info`, `low`, `medium`, `high`, `critical`. Headless `gori run prism` runs **passive** checks only (categories except `active`).

Run passive analysis headless — it reads what's already captured (History + Replay responses) and sends nothing:

```bash
gori run prism                       # all issues
gori run prism --severity high       # only high-severity
gori run prism --category cors       # a single category
gori run prism -q 'host:example.com' # filter History with QL (Replay still scanned)
```

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

- **Notes** — free-form, per-project Markdown documents (multiple notes per project). Create, edit, and close notes from the Notes tab; list or dump them headless with `gori run notes` / `gori run notes --all`. Agents can manage notes over MCP (`list_notes`, `get_note`, `create_note`, …).
- **Comparer** — load two flows into slots A and B for a line-by-line diff, useful for spotting how a response changed between requests. Send a flow from History with `Space` → Comparer, or swap slots on the Comparer tab.

Findings, notes, replays, and fuzz/miner sessions can be **linked** so you jump from a finding straight back to the evidence flow or the session that produced it.

## Next Steps

- [MCP Server](/guide/mcp/) — let an agent run scans and read findings
- [CLI Reference](/reference/cli/) — `prism`, `mine`, `findings`, and `notes` flags
- [Query Language](/reference/query-language/) — scope your scans
