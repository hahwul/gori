+++
title = "Scanning & Issues"
description = "The Probe scanner, the Param Miner, and triaging results into Issues."
+++

gori includes automated analysis that runs alongside your manual testing. **Probe** watches traffic for issues, the **Param Miner** discovers hidden inputs, and **Issues** is where results get triaged.

## Probe: the Scanner

**Probe** groups security issues by type and severity. Its passive checks run as you browse (with zero extra requests), inspecting **History** flows and **Repeater** send results.

Its **active** checks are deliberately *light-touch*: a handful of safe, low-volume probes over traffic you've already captured. Only safe methods (`GET` / `HEAD`) are probed, each unique surface is tested once, and nothing goes out until you arm active mode. It's built to confirm a quick hunch (a parameter reflects, an origin is honored) while keeping your footprint quiet.

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
| `client` | Client-side suspicions in page and bundle scripts: DOM-based XSS (source into sink), DOM clobbering, prototype pollution, and postMessage weaknesses. Heuristic, so treat as leads to confirm |
| `active` | Confirmed by a light-touch probe (for example reflected parameters). TUI active scan only |

Severities run `info`, `low`, `medium`, `high`, `critical`. Headless `gori run probe` runs **passive** checks only (categories except `active`).

Run passive analysis headless. It reads what's already captured (History + Repeater responses) and sends nothing:

```bash
gori run probe                       # all issues
gori run probe --severity high       # only high-severity
gori run probe --category cors       # a single category
gori run probe -q 'host:example.com' # filter History with QL (Repeater still scanned)
```

## Param Miner

The **Miner** discovers parameters a server accepts but doesn't advertise. Point it at a flow and it probes candidate names across locations: query string, form body, multipart/form-data, JSON (including nested objects and array roots), headers, and cookies. It buckets guesses efficiently and reports the ones that change the response. Multipart is applicable but off by default (a captured file part would be re-sent on every request); enable it with `--locations multipart` or its checkbox.

```bash
gori run mine <flow-id> \
  --locations query,headers \
  --wordlist params.txt \
  --bucket 50
```

> The Miner tab is hidden by default. Enable it from the command palette (`Ctrl-P`) when you need it.

## Discover: Spider & Brute-Force

Where the Miner finds hidden inputs, **Discover** finds hidden endpoints. It spiders a target (following links you never clicked) and brute-forces unlinked directories and paths (`/admin`, `.git/config`, `/api/v2`). It lives as a sub-tab under the new **Target** tab, next to the Sitemap, and every endpoint it finds flows straight into that Sitemap.

Start a run from where you already are: on a **Sitemap** node or a **History** flow, press `Space` and pick **Discover here**. A small popup lets you choose the exploration style (spider, brute-force, or both, the default), a max depth, the crawl scope, and concurrency. The run happens in the background: watch the bottom bar, pause or stop it from the Discover sub-tab (`^X` stop, `p` pause), and jump to the results from the completion notification.

Discover is built for tight false-positive and false-negative rates on real sites:

- **Soft-404 calibration.** Before brute-forcing a directory it sends a few known-bad paths to learn how that server answers a miss. It handles a server that returns `200` for everything and one that redirects every unknown path to `/login`, so a wordlist hit only counts when it genuinely diverges from that baseline.
- **No runaway crawls.** Two independent guards stop a crawl from exploding: URL-shape folding collapses `/user/1`, `/user/2`, `/user/3`… into one template, and a content fingerprint collapses near-duplicate listing pages into one cluster. A depth cap, a page cap, and a hard request budget bound the rest.
- **Scope-aware by default.** A run stays on the seed origin unless you've set Scope include rules, in which case it follows them; Scope excludes and the sandbox are always respected. Launch on a path (not a host) to confine the run to that subtree.

Each run reports its FP/FN figures: how many probes the calibrator suppressed, how much exploration the traps guards cut, and the confidence spread of what it kept.

Headless, it's `gori run discover`, and it's exposed to agents over MCP (`discover_start` / `discover_status` / `discover_results` / `discover_stop`):

```bash
gori run discover --target https://target.example \
  --max-depth 3 \
  --extensions php,json,bak \
  --format jsonl
```

Discover sends real, unsolicited traffic to the target. Only run it against systems you are authorized to test.

> From the Sitemap, `Space` also offers **Send to Repeater**, which opens the selected endpoint's captured request in the Repeater workbench.

## Issues

**Issues** is your triage list. Promote anything worth tracking (from Probe, the Fuzzer, the Miner, or your own inspection) into an issue with a severity and a status, and jump straight back to the evidence flow. Issues can be exported for reporting:

```bash
gori run issues --format markdown --export report.md
```

## Notes & Comparer

Two more tools round out analysis:

- **Notes**: free-form, per-project Markdown documents (multiple notes per project). Create, edit, and close notes from the Notes tab; list or dump them headless with `gori run notes` / `gori run notes --all`. Agents can manage notes over MCP (`list_notes`, `get_note`, `create_note`, …).
- **Comparer**: load two flows into slots A and B for a line-by-line diff, useful for spotting how a response changed between requests. Send a flow from History with `Space` → Comparer, or swap slots on the Comparer tab.

Issues, notes, repeaters, and fuzz/miner sessions can be linked so you jump from an issue straight back to the evidence flow or the session that produced it.

## Next Steps

- [MCP Server](/guide/mcp/): let an agent run scans and read issues
- [CLI Reference](/reference/cli/): `probe`, `mine`, `issues`, and `notes` flags
- [Query Language](/reference/query-language/): scope your scans
