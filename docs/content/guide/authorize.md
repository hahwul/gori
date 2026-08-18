+++
title = "Authorize"
description = "Replay a captured request under several identities and diff the verdicts to find broken access control."
weight = 75

[extra]
group = "Workbenches"
+++

Most access-control bugs are invisible from one session. You are logged in as an admin, `/admin/users` returns the list, and everything looks correct — because you never asked what the *anonymous* client gets, or the read-only user, or the tenant next door. **Authorize** asks: it takes a request you already captured, replays it under several identities, and compares each response against a baseline. An identity that is served what the baseline was served is a likely authorization bypass. It is gori's counterpart to Burp's Autorize / Auth Analyzer and to AuthMatrix.

The **Authorize** tab is hidden by default. Reveal it from the tab-bar `⋯` menu, the command palette (`Ctrl-P` → **Go to Authorize**), or Preferences (`Ctrl-,`) → **Network & Tabs** → **Tabs**.

## What an Identity Is

An identity is a **session slot**: a name, a static header overlay applied to the captured request before it is replayed, and the extract rules whose bound values belong to it. It is the same object everywhere in gori — the Authorize tab replays under *every* slot, and a Repeater or Fuzzer send goes out as the *one* that is active (see [Session slots](#session-slots-one-list-two-readers) below). One list, one settings row, three surfaces.

| Field | Effect |
|-------|--------|
| **set** | Upsert a header: replace the value of every header of that name (case-insensitive, original casing kept), or append it when absent |
| **remove** | Drop every header of that name |

An "anonymous" identity removes `Cookie` and `Authorization`. An "admin" or "low-priv" identity sets them to another session's values. An API identity sets `X-Api-Key`. The overlay touches header lines only — the request line, the body, and `Content-Length` never move, so what you are comparing really is the same request under different credentials.

Press `i` on the tab to open the identities card. A fresh project starts with two: **as-captured** (no overlay at all) and **anonymous** (drops `Cookie` and `Authorization`).

| Key | In the identities card |
|-----|------------------------|
| `↑` / `↓` | Pick an identity |
| `a` | Add |
| `e` / `↵` | Edit |
| `d` | Delete |
| `b` | Make this one the baseline |
| `esc` | Close |

The add / edit form has three fields: a **name** (unique — two rows under one label would make the results table unreadable, and all three surfaces refuse a duplicate; names are compared case-insensitively), the headers to **set**, one `Name: value` per line, and the headers to **remove**, comma-separated. `⇥` moves between fields, `↵` saves. A header line whose name is not a valid token, or whose value carries a CR or LF, is refused with the offending line named rather than silently dropped.

Identities are saved with the project, so `gori run authorize` and the MCP tools default to the same set you configured here. The list shows header *names* only — a session cookie is a credential, and a list that paints it on screen leaks it to anyone glancing at your terminal. The form shows values, because that is what editing means.

Changing the identity set marks every result already on screen as pending again. Those verdicts were produced under the old set, and reporting them beside new ones would compare two different tests.

## Session Slots: One List, Two Readers

This tab reads the list *across*: every slot, one request, compare the answers. Every other send seam reads it *down*: pick one slot, and every request from then on goes out wearing it. Same rows, same card, two questions.

Picking the active one is a separate action from editing the list, because it is a different kind of state:

| Surface | Pick the active slot | Edit the list |
|---------|----------------------|---------------|
| TUI | `Ctrl-P` → **Session slot**, or click the `session:NAME` chip | `i` on this tab |
| `gori run` | `--slot NAME` on the sending command | `gori run session list \| show \| add \| edit \| rm \| baseline` |
| MCP | `set_active_session_slot` | `list_session_slots`, `create_session_slot`, `update_session_slot`, `delete_session_slot` |

What the active slot changes, on `send_request`, a Repeater or Fuzzer send, and an intercept forward:

- its **header overlay** is applied to the final wire bytes — after `$NAME` substitution, header lines only, so `Content-Length` never moves and the body is byte-exact;
- `$NAME` resolves against **its** binding table. An extract rule a slot claims writes that slot's table; a rule no slot claims keeps writing the one global table it always did. So `Authorization: Bearer $SESSION` means admin's token on the `admin` slot and the low-priv user's on `low-priv`, off one saved string.

Three things the active slot deliberately does **not** do:

- **It does not apply to an Authorize run.** This tab supplies the identity itself, once per send, and comparing them *is* the measurement — so a run reads the list across and wears none of it, whichever slot is active. Left to apply, the active slot would write its `Cookie` over the top of every identity, including the one whose whole job is to remove it: every response would match the baseline by construction and every queued row would report a bypass that does not exist.
- **It is never persisted.** Reopening a project, or a new `gori mcp` connection, starts as-captured. A slot's *values* are memory-only by design, so restoring "admin is active" into an empty admin table would hand the next send an overlay whose `$SESSION` is literal — a `401` with no visible cause. Activation is one keystroke; a stale one is a support ticket.
- **`as-captured` is the baseline in both senses.** With no slot active nothing changes a byte, which is what makes every project and every playbook written before slots existed behave exactly as it did.

There is no cookie jar and no auto-login macro here. A slot carries the headers you wrote and the values gori observed; `--bind-from` replays one flow *you* named to fill them.

## The Baseline

Exactly one identity in a run is the **baseline** — the response every other identity is judged against. Unless an identity claims it (`b` in the card, `"baseline":true` in JSON), the request **as captured** is the baseline: it goes out with its original session, and everything else is a lens over that same request.

A run needs at least one identity besides the baseline, and all three surfaces refuse one that does not have it. With a single identity, every trial would be the baseline judged against itself; the run would finish, report "no identity matched the baseline", and mean nothing at all.

## The Loop

1. In **History**, select the flows worth testing and `Space` → **Send to Authorize**. From **Sitemap**, the same verb queues the selected endpoint's captured flow.
2. On the **Authorize** tab, press `i` and set up the identities you want to compare.
3. `Ctrl-R` replays every queued request that has no result yet; `⇧R` re-runs everything; `t` runs just the request under the cursor.
4. Read the table. The top pane is one row per request with an aggregate verdict; `⇥` drills into the selected request's identities in the bottom pane.

Each identity gets its **own connection**. That is deliberate and costs a handshake per trial: connection-oriented authentication (NTLM, Negotiate — ordinary on internal engagements) authenticates the *connection*, not the message, so a reused socket would serve an identity that dropped `Cookie` the baseline's content anyway and manufacture a bypass that does not exist.

`Ctrl-X` stops. The stop is polled between requests *and* between identities, so it takes effect at the next send rather than after the five identities already queued for the request in flight. A request cut short mid-identity yields **no** verdict at all: a partial set of trials must never read as "enforced".

## Reading a Verdict

Each identity's response is reduced to three facts — status, decoded body size, and a SimHash content fingerprint — and compared with the baseline's. Bodies are decoded (gzip / deflate / br / chunked) before hashing, because a fingerprint over compressed bytes is meaningless.

| Verdict | Means |
|---------|-------|
| `baseline` | This row *is* the baseline |
| `different` | A different status **class** (2xx vs 4xx vs 3xx) — the clearest sign access control engaged. Or two redirects that point somewhere else |
| `same` | Same status class, and the body matches: within a SimHash distance of 3 **and** within 10% in size. Or two redirects to the same place |
| `review` | Same status class, divergent body — or the baseline itself errored, so there was nothing to anchor against |
| `error` | This identity's send failed (TLS, DNS, timeout, refused); nothing was compared |

Two redirects are judged on their **`Location`**, before the body is looked at. A redirect's body is empty, so on the three facts above every `3xx` matched every other `3xx` — and an authenticated `302 → /dashboard` against an anonymous `302 → /login`, which is the clearest *enforcement* there is, came back `same`. Where the origin steers each identity is the only thing a redirect says, so that is what gets compared: an exact string match, because `/login` and `/login/` are a difference worth showing you rather than one worth deciding for you.

The per-request row aggregates them: **BYPASS** when any non-baseline identity came back `same`, **enforced** when every one clearly differed, **review** otherwise.

Both halves of the `same` test matter. SimHash skips numeric and hex tokens, so two differently-sized pages can hash close; the size band catches that. The 10% tolerance exists because real pages carry per-request noise — CSRF tokens, timestamps — and an exact match would flag all of it.

This is a heuristic, and the names are deliberately neutral, because the *security* meaning depends on the identity's intended privilege and only you know that. `same` on a low-privilege identity is a likely bypass. `same` on a second admin session is exactly right. `review` is where a tailored "access denied" page rendered at 200 and a legitimately per-user page look identical to a fingerprint. The tab states the comparison; you read the intent.

## What Gets Skipped, and Why

A selection can reach flows that cannot be replayed meaningfully. gori names every one of them rather than quietly sending less than you asked for.

| Reason | Why | Override |
|--------|-----|----------|
| **no identity changes them** | No identity would alter this request's bytes, so every trial sends the same thing, the responses match by construction, and the row would read `same` — a finding manufactured out of nothing | Add an identity that sets or drops the header this endpoint authenticates with |
| **not a safe method to repeat** | Only `GET` / `HEAD` / `OPTIONS` are replayed by default. A replayed `POST` / `PUT` / `PATCH` / `DELETE` runs its side effect again, once per identity | `--unsafe-methods` (CLI), `unsafe_methods:true` (MCP). The TUI's manual queue takes any method, because there a human picked the request |
| **never completed** | The capture has no response to compare against | — |
| **answered by gori** | gori short-circuited this request itself; there is no origin behind it | — |
| **outside project scope** | The outbound gate refused the target before the socket | `--allow-unscoped` (CLI), `allow_unscoped:true` (MCP), or add a scope include rule |
| **already queued** | The same flow was named twice | — |

The first row is the one worth internalizing. The skip is not a "does this request carry a `Cookie`?" test — that question missed APIs authenticating through `X-Api-Key`, and on a site you were not logged into it skipped everything while saying nothing. gori asks the exact question instead: *would any identity change these bytes?* If not, there is nothing to compare, and it says so.

## Passive Replay

`p` turns on unattended replay: as you browse through the proxy, every completed, in-scope, safe-method flow that at least one identity would change is queued and replayed automatically. It is off by default and nothing else turns it on — this is the one control in the tab that puts requests on a target with nobody pressing a key.

Passive is gated harder than the manual queue: it needs a **scope include rule**, and with none configured nothing is replayed at all. gori says so at the keypress rather than leaving you to wonder. A browser session reaches a great deal that is not the engagement, and passive follows the browser.

Two more properties worth knowing. Passive dedups by **endpoint** (`METHOD` + URL), not by flow id, so a session's tenth visit to `/orders` does not requeue it while `/orders?id=2` still gets its own row. And the queue is capped at 200 requests — a long browse would otherwise replay more traffic than the browsing itself did. The cap is announced when it bites.

The tab keeps a live readout of what passive has actually done (`N seen · M queued · K skipped (reason)`), because "nothing happened" and "nothing matched" otherwise look identical.

## Keys

| Key | Action |
|-----|--------|
| `Ctrl-R` | Run pending — replay every queued request with no result yet (never run, or the send failed) |
| `⇧R` | Run all — replay everything, re-sending requests that already have a result |
| `t` | Run this request only |
| `Ctrl-X` | Stop the run |
| `i` | Identities — edit the set every request is replayed under |
| `p` | Toggle passive replay |
| `d` | Remove the selected request from the queue |
| `↑` / `↓` | Move between requests |
| `⇥` | Move between the selected request's identities |
| `PgUp` / `PgDn` | Scroll the detail pane |
| `Space` → `X` | Clear — empty the queue and its results (menu only) |

From **History** or **Sitemap**, `Space` → **Send to Authorize** queues a request here.

## Headless

```bash
# Two captured flows, under the identities saved in the project
gori run authorize 12 13

# An explicit identity set, and a QL query instead of ids
gori run authorize --query 'host:acme.test method:GET status:200' \
  --identities identities.json --limit 20
```

`identities.json` is the same shape the tab persists and the MCP tools take:

```json
[{"name": "anonymous", "remove": ["Cookie", "Authorization"]},
 {"name": "low-priv",  "set": [{"name": "Cookie", "value": "session=…"}]}]
```

Text output is one block per request — a headline you can scan down the left edge for `[!] BYPASS`, then one row per identity:

```
authorizing 2 requests × 2 identities (as-captured, anonymous) = 4 requests
[!] BYPASS    #1     GET    http://127.0.0.1:8399/admin/users  · 1 of 1 identity matched the baseline
      as-captured         baseline  200  118B     —
      anonymous           same      200  118B     Δ status 200 · size same · time -434 µs

[ ] enforced  #2     GET    http://127.0.0.1:8399/orders
      as-captured         baseline  200  118B     —
      anonymous           different 403  9B       Δ status 200 → 403 · size -109 B · time +272 µs
done · 2 requests replayed · 4 sends · 1 possible bypass
```

Skips are stated up front, per flow, before anything is sent:

```
skipped 1 flow · 1 no identity changes them
  #1     GET    http://acme.test/pricing  — no identity changes them
```

Manage the slot list — the same rows the `i` card edits — without opening the TUI:

```bash
gori run session list                       # names, overlays (values [REDACTED]), claimed rules
gori run session add --name low-priv --set 'Cookie: session=…' --rule SESSION
gori run session edit low-priv --clear-set --set 'Cookie: session=new'
gori run session baseline as-captured
gori run session rm low-priv
```

There is no `gori run session activate`: a `gori run` process sends and exits, so the active pointer has nothing to span. Name the identity on the send instead — `--slot NAME` works on `repeater`, `fuzz`, `mine`, `sequence` and `discover`, and applies before `--bind-from` replays its seed, so the seed fills the slot the run then sends as.

`--format jsonl` streams one object per request as it lands; `--format json` buffers and emits a single array at the end. Both carry the decoded body size the verdict actually compared alongside the wire size, which a gzipped response makes disagree by an order of magnitude. Full flags are in the [CLI Reference](/reference/cli/#run-authorize).

## From an Agent

Four MCP tools drive the same engine as a background job: `authorize_start` (returns a `job_id`, the planned send count, the identity names, the scope gate, and everything it skipped), `authorize_status`, `authorize_results`, and `authorize_stop`.

`authorize_results` puts the answer first. `access_control` names the outcome in one token — `BYPASS`, `enforced`, `review`, or `nothing_sent` — `summary` says it in a sentence, and `bypasses` lists every request where a non-baseline identity was served the baseline's response, flat and never paged. An agent that reads nothing else still gets the finding.

Five more manage the slots themselves: `list_session_slots` (with the active one named, header values `[REDACTED]` unless you ask), `create_session_slot`, `update_session_slot`, `delete_session_slot`, and `set_active_session_slot` — which picks the identity every *other* tool's sends go out as, for the life of that server process.

A run is capped at 2,000 sends, and the cap counts `flows × identities`: a 500-row query under four identities is refused up front, naming both factors, rather than truncated into a run that would report "enforced" for flows it never sent. Layer-1 scope is strict here — an out-of-scope target needs an explicit `allow_unscoped:true`, because nobody eyeballed it.

## A Run That Sent Nothing Is Not Evidence

This is the property the code goes out of its way to enforce, on every surface.

If the sandbox or an exclude rule refused every send before the socket, if every selected flow was skipped, or if you stopped the run part-way, gori does **not** report "no identity matched the baseline". It says nothing was sent. A clean bill of health for traffic that never left the machine is the worst way an access-control test can fail — worse than a false positive, because you would close the ticket.

The same caution applies to a genuine `enforced`: it means access control held *for the identities you tested, on the requests you replayed*. A different endpoint, a different privilege boundary, or an identity you did not model is untested, not safe.

## Next Steps

- [Proxy & History](/guide/proxy/): capture the traffic and set the scope this tab replays inside
- [Scanning & Issues](/guide/scanning/): file a confirmed bypass as an Issue
- [Scripting](/guide/scripting/): run the same comparison headless, in CI
- [MCP Server](/guide/mcp/): hand the whole loop to an agent
