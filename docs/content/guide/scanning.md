+++
title = "Scanning & Issues"
description = "The Probe scanner, the Param Miner, and triaging results into Issues."
+++

gori includes automated analysis that runs alongside your manual testing. **Probe** watches traffic for issues, the **Param Miner** discovers hidden inputs, and **Issues** is where results get triaged.

## Probe — the Scanner

**Probe** groups security issues by type and severity. Its passive checks run as you browse — with zero extra requests — inspecting **History** flows and **Repeater** send results.

Its **active** checks are deliberately *light-touch* — a handful of safe, low-volume probes over traffic you've already captured, not the flood of attack payloads a heavyweight scanner throws at a target. Only safe methods (`GET` / `HEAD`) are probed, each unique surface is tested once, and nothing goes out until you arm active mode. It's built to confirm a quick hunch — a parameter reflects, an origin is honored — while keeping your footprint quiet.

<figure class="tui-shot">
  <img src="/images/tui/probe.svg" alt="gori Probe scanner listing passive issues grouped by severity and category: permissive CORS, missing CSP and HSTS, cookie flag issues, and cacheable responses, each with an affected host">
  <figcaption><strong>Probe</strong> surfaces passive issues as you browse (CORS, cookie hygiene, missing security headers, info leaks), grouped by severity and category.</figcaption>
</figure>

| Category | What it covers |
|----------|----------------|
| `headers` | Security headers (HSTS, CSP, …), cleartext Basic auth, mixed content, cacheable API responses |
| `cookies` | `Secure` / `HttpOnly` / `SameSite` and related cookie hygiene |
| `tech` | Technology and protocol fingerprints (also surface on the Project tab) |
| `infoleak` | Body disclosures, secrets in URLs / WS frames, GraphQL introspection |
| `cors` | Wildcard / null origin / credentialed misconfigurations; active origin reflection |
| `active` | Confirmed by a light-touch probe (for example reflected parameters) — TUI active scan only |

Severities run `info`, `low`, `medium`, `high`, `critical`. Headless `gori run probe` runs **passive** checks only (categories except `active`).

Run passive analysis headless — it reads what's already captured (History + Repeater responses) and sends nothing:

```bash
gori run probe                       # all issues
gori run probe --severity high       # only high-severity
gori run probe --category cors       # a single category
gori run probe -q 'host:example.com' # filter History with QL (Repeater still scanned)
```

## Param Miner

The **Miner** discovers parameters a server accepts but doesn't advertise. Point it at a flow and it probes candidate names across locations — query string, form body, multipart/form-data, JSON (including nested objects and array roots), headers, and cookies — bucketing guesses efficiently and reporting the ones that change the response. Multipart is applicable but off by default (a captured file part would be re-sent on every request); enable it with `--locations multipart` or its checkbox.

```bash
gori run mine <flow-id> \
  --locations query,headers \
  --wordlist params.txt \
  --bucket 50
```

> The Miner tab is hidden by default. Enable it from the command palette (`Ctrl-P`) when you need it.

## Issues

**Issues** is your triage list. Promote anything worth tracking — from Probe, the Fuzzer, the Miner, or your own inspection — into an issue with a severity and a status, and jump straight back to the evidence flow. Issues can be exported for reporting:

```bash
gori run issues --format markdown --export report.md
```

## Notes & Comparer

Two more tools round out analysis:

- **Notes** — free-form, per-project Markdown documents (multiple notes per project). Create, edit, and close notes from the Notes tab; list or dump them headless with `gori run notes` / `gori run notes --all`. Agents can manage notes over MCP (`list_notes`, `get_note`, `create_note`, …).
- **Comparer** — load two flows into slots A and B for a line-by-line diff, useful for spotting how a response changed between requests. Send a flow from History with `Space` → Comparer, or swap slots on the Comparer tab.

Issues, notes, repeaters, and fuzz/miner sessions can be **linked** so you jump from an issue straight back to the evidence flow or the session that produced it.

## Next Steps

- [MCP Server](/guide/mcp/) — let an agent run scans and read issues
- [CLI Reference](/reference/cli/) — `probe`, `mine`, `issues`, and `notes` flags
- [Query Language](/reference/query-language/) — scope your scans
