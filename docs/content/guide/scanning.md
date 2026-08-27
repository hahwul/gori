+++
title = "Scanning & Issues"
description = "The Probe scanner, the Param Miner, and triaging results into Issues."
weight = 30

[extra]
group = "Core"
+++

gori includes automated analysis that runs alongside your manual testing. **Probe** watches traffic for issues, the **Param Miner** discovers hidden inputs, and **Issues** is where results get triaged.

## Probe: the Scanner

**Probe** groups security issues by type and severity. Its passive checks run as you browse (with zero extra requests), inspecting **History** flows and **Repeater** send results.

Its **active** checks are deliberately *light-touch*: a handful of safe, low-volume probes over traffic you've already captured. By default only safe methods (`GET` / `HEAD`) are probed, each unique surface is tested once, and nothing goes out until you arm active mode. It's built to confirm a quick hunch (a parameter reflects, an origin is honored) while keeping your footprint quiet.

Re-sending an unsafe method (`POST` / `PUT` / `PATCH` / `DELETE`) can mutate server state, so it is always opt-in. Tick **unsafe methods** in the per-flow *Run active scan* popup for a single deliberate re-send, or switch Probe to **AGGRESSIVE** mode, which also probes unsafe methods automatically and raises the per-rule caps (wider param sets, a wider forbidden-bypass header set). Both stay inside your project scope, so an out-of-scope host is never touched.

<figure class="tui-shot">
  <img src="/images/tui/probe.svg" alt="gori Probe scanner listing passive issues grouped by severity and category: permissive CORS, missing CSP and HSTS, cookie flag issues, and cacheable responses, each with an affected host">
  <figcaption><strong>Probe</strong> surfaces passive issues as you browse (CORS, cookie hygiene, missing security headers, info leaks), grouped by severity and category.</figcaption>
</figure>

| Category | What it covers |
|----------|----------------|
| `headers` | Security headers (HSTS, CSP incl. report-only-only, XFO, Permissions-Policy, …), cleartext Basic auth, mixed content, cacheable API responses, JWT weaknesses (`alg:none`, non-standard alg, no `exp`), cross-origin subresources without `integrity` |
| `cookies` | `Secure` / `HttpOnly` / `SameSite` and related cookie hygiene |
| `tech` | Technology and protocol fingerprints (also surface on the Project tab) |
| `infoleak` | Body disclosures, secrets in URLs / WS frames, GraphQL introspection, source maps shipped with production scripts, directory listings, sensitive JWT claims |
| `cors` | Wildcard / null origin / credentialed misconfigurations; active origin reflection |
| `client` | Client-side suspicions in page and bundle scripts: DOM-based XSS (source into sink), DOM clobbering, prototype pollution, and postMessage weaknesses. Heuristic, so treat as leads to confirm |
| `active` | Confirmed by a light-touch probe: reflected parameters, backslash-powered injection points, open redirect, CRLF/response-header & host-header injection, access-control bypass (spoofed client-IP / path normalization / URL-rewrite headers), NGINX alias & parameter path traversal, server-side template injection, and Next.js server-action missing authorization (re-sends a `Next-Action` request with the session cookie/Authorization stripped — needs unsafe/AGGRESSIVE, since actions are POST). GraphQL introspection is confirmed actively too (recorded under `infoleak`) |

Severities run `info`, `low`, `medium`, `high`, `critical`. Headless `gori run probe` runs passive checks by default, and pass `--active` to also run active checks.

Findings are grouped by check and host, so one row can stand for dozens of hits. Open it and the **AFFECTED URLS** list is the evidence: `↑`/`↓` walk it and `Enter` opens the flow that URL was captured on, in the same detail view History uses. `o` opens the finding's sample flow, `r` sends it to the Repeater, and `y` copies the selected URLs (or all of them).

Run analysis headless. By default it reads what's already captured (History + Repeater responses) and sends nothing, or pass `--active` to send probe requests:

```bash
gori run probe                       # passive issues
gori run probe --active              # include active checks (sends probe requests)
gori run probe --active --unsafe     # also re-send unsafe methods (may mutate server data)
gori run probe --active --aggressive # wider caps + unsafe methods (authorized targets only)
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

A mine is latency-bound rather than CPU-bound — it sends a bucket, waits, bisects, waits — so what it mostly costs is round trips. Two things keep that count down: the run reuses one connection across its probes (one TCP, and on https one TLS, handshake per worker instead of one per probe — turn it off with the **reuse connections** checkbox, `--no-keep-alive`, or `keep_alive: false` when the target behaves per-connection), and every location is mined through one shared pool of workers, so three locations do not cost three times one location and the tail of a bisection no longer runs alone.

> The Miner tab is hidden by default. Enable it from the command palette (`Ctrl-P`) when you need it.

## Discover: Spider & Brute-Force

Where the Miner finds hidden inputs, **Discover** finds hidden endpoints. It spiders a target (following links you never clicked) and brute-forces unlinked directories and paths (`/admin`, `.git/config`, `/api/v2`). It lives as a sub-tab under the new **Target** tab, next to the Sitemap, and every endpoint it finds flows straight into that Sitemap.

Start a run from where you already are: on a **Sitemap** node or a **History** flow, press `Space` and pick **Discover here**. A small popup lets you choose the exploration style (spider, brute-force, or both, the default), a max depth, the crawl scope, and concurrency. The run happens in the background: watch the bottom bar, pause or stop it from the Discover sub-tab (`^X` stop, `p` pause), and jump to the results from the completion notification.

A finished run is not just a list of URLs. Every finding is stored with the request Discover framed and the response the origin sent back, so in the FINDINGS table `Enter` (or `o`) opens that exchange in the same detail view History uses: headers, body, pretty-printed JSON, and from there `^R` to the Repeater. Headless runs and MCP runs store the same bytes, so a finding is openable with `gori run show` or `get_flow` too.

Discover is built for tight false-positive and false-negative rates on real sites:

- **It reads what the target says about itself.** Every run fetches the well-known documents at the origin — `robots.txt`, `sitemap.xml` and `sitemap_index.xml`, plus the `.well-known/` registry (`openid-configuration`, `oauth-authorization-server`, `oauth-protected-resource`, `security.txt`, `apple-app-site-association`, `assetlinks.json`, `host-meta`, `change-password`) — and crawls the endpoints they declare. An OIDC discovery document alone hands over the authorize, token, userinfo, JWKS, revocation and registration endpoints. These are guesses at fixed paths, so they go through the same soft-404 baseline a wordlist hit does.
- **It reads your JavaScript.** The spider follows `<script src>` like any other link, and now parses the bundle it gets back: quoted root-relative paths and absolute URLs become crawl targets. On an SPA, the API routes are reachable only from JS and by construction unlinked, so this is the surface both the spider and the brute-forcer used to miss entirely. The same pass runs over inline `<script>` blocks, JSON responses and source maps.
- **Soft-404 calibration.** Before brute-forcing a directory it sends a few known-bad paths to learn how that server answers a miss. It handles a custom-designed error page on a real `404`, a server that returns `200` for everything, one that quotes the requested path back into its error page, and one that redirects every unknown path to `/login` — so a wordlist hit only counts when it genuinely diverges from that baseline. Each of those behaves differently under the same wordlist, so the run tells you which one it found (`wildcard-200 (echoes path)`, and so on).
- **The baseline is re-measured when the target changes its mind.** A baseline is taken once per directory, and a rate limiter, a WAF block page or a `5xx` meltdown partway through a sweep makes every remaining probe look like a discovery — the classic way an automated sweep produces hundreds of confident findings that are all the same block page. Discover watches for a run of probes that all clear the baseline *and* all look identical, holds those results back rather than reporting them, and re-measures the directory. What it dropped is reported as `drift` in the run summary, so a directory that went unmeasured never reads as a directory that was empty.
- **No runaway crawls.** Two independent guards stop a crawl from exploding: URL-shape folding collapses `/user/1`, `/user/2`, `/user/3`… into one template, and a content fingerprint collapses near-duplicate listing pages into one cluster. A depth cap, a page cap, and a hard request budget bound the rest.
- **Scope-aware by default.** A run stays on the seed origin unless you've set Scope include rules, in which case it follows them; Scope excludes and the sandbox are always respected. Launch on a path (not a host) to confine the run to that subtree.
- **Connections are reused.** A brute-force pass is one request per wordlist entry per directory, and each one used to pay its own TCP handshake (plus, on https, its own TLS handshake). Discover now keeps a keep-alive connection per origin, so the run pays one handshake per worker instead. Turn it off with the **reuse connections** checkbox, `--no-keep-alive`, or `keep_alive: false` when the target behaves per-connection (a connection-scoped rate limit, a load balancer pinning by connection).

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
gori run issues --format sarif --export issues.sarif   # for GitHub code scanning / a CI dashboard
```

In the TUI, `⇧E` asks for the format and then the destination path. See [Export the report](/playbooks/triage-and-report/#5-export-the-report) for what a SARIF result carries.

### Marking issues (multi-select)

The list marks the same way History does. Press `t` to **mark** the issue under the cursor and step down, so a run of `t` marks consecutive rows. `Shift-↑` / `Shift-↓` extend a contiguous range from where you started, `Shift-T` marks everything the current filter shows, and `Esc` clears the marks. Marked rows get a full bar in the gutter and the filter row shows a live `3 marked` count.

Letting go of `Shift` ends the range: a plain `↑` / `↓` (or `PgUp` / `PgDn`, or a click on another row) hands the range back and moves on, the way a GUI list collapses its highlight. Marks you placed deliberately with `t` or `Shift-T` stay, which is what makes a discontiguous set possible. The mouse wheel only scrolls, so it never drops a mark.

Marks change **what the space menu acts on**, not which actions exist:

> the effective target is **the marks if any are set, else the cursor row**

So `/ status:open severity:low` → `Shift-T` → `Space` → `c` → **False positive** re-triages the whole batch in one pick. The menu title reads `SPACE · 3 MARKED` and the entries rename themselves (`Delete 3 issues`) so a batch is never a surprise.

| Action | Key | Over marks |
|--------|-----|-----------|
| Set severity | `Space` `s` | One pick, written to every marked issue |
| Set status | `Space` `c` | One pick — the bulk "false positive" / "resolved" pass |
| Delete | `Space` `d` | One confirm for the whole set |

Marks survive a filter change, a re-sort (including the one your own severity edit causes), and leaving the tab and coming back; the count chip tells you how many are currently off-screen. Opening an issue pins the actions to that one issue — marks are a list-level idea. Export always writes the **full** report, so its menu entry says `(all)` while marks are set.

## Notes & Comparer

Two more tools round out analysis:

- **Notes**: free-form, per-project Markdown documents (multiple notes per project). Create, edit, and close notes from the Notes tab; list or dump them headless with `gori run notes` / `gori run notes --all`. Agents can manage notes over MCP (`list_notes`, `get_note`, `create_note`, …).
- **Comparer**: load two messages into slots A and B for a side-by-side diff, useful for spotting how a response changed between requests.

  A slot is filled from anywhere that holds a request and a response: `Space` → **Send to Comparer** from History, the Sitemap, a Repeater tab (its last send) or a Fuzzer result row, or `a` / `b` on the Comparer tab itself to pick a captured flow — that picker follows the active Scope lens, like History and the Sitemap, so turn the lens off to reach an out-of-scope flow. A Repeater send and a fuzz row leave no capture behind, so this is the only route those two have into a diff.

  Each column header carries that side's `status · size · time`, and the divider between them states the A→B delta — a `403 → 200` is usually the whole answer, before a body line is read.

  Inside the diff:

  | Key | Action |
  |-----|--------|
  | `←` / `→` | Diff the requests or the responses |
  | `n` / `⇧N` | Jump to the next / previous **changed** row (wraps; the footer shows `3/8`) |
  | `f` | Fold the unchanged runs to `⋯ N unchanged lines ⋯`, keeping 3 lines of context |
  | `↑` / `↓`, `⇧↑` / `⇧↓` | Move the row cursor · grow a whole-row selection |
  | `y` | Copy the selection — or the whole diff — as unified text |
  | `⇧←` / `⇧→` | Scroll both columns sideways together |
  | `s` | Swap A ⇄ B |

  On a changed row only the parts that actually differ are lit red/green; what both sides share is dimmed, so a re-signed token or one flipped JSON value is visible without reading the line.

Issues, notes, repeaters, and fuzz/miner sessions can be linked so you jump from an issue straight back to the evidence flow or the session that produced it. `Space` → **Link…** from History, the Repeater, the Fuzzer, or the Miner opens one card holding every issue *and* every note, with `+ New issue…` / `+ New note…` pinned above them — so filing a brand-new issue for what you are looking at, already linked, is the same keystroke as attaching it to an existing one. Type to filter by title, host, status, or the words `issue` / `note`; whatever you typed becomes the new issue's title if you land on the create row.

## Next Steps

- [MCP Server](/guide/mcp/): let an agent run scans and read issues
- [CLI Reference](/reference/cli/): `probe`, `mine`, `issues`, and `notes` flags
- [Query Language](/reference/query-language/): scope your scans
