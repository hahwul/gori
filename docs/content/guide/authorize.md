+++
title = "Authorization Testing"
description = "Replay a captured request under several identities and diff the verdicts to find broken access control."
weight = 75

[extra]
group = "Workbenches"
+++

Most access-control bugs are invisible from one session. When you are logged in as an admin, `/admin/users` returns the list and looks correct, but that does not show what an anonymous client, a read-only user or another tenant gets. **Authorize** takes a request you already captured, replays it under several identities, and compares each response against a baseline. An identity that is served what the baseline was served is a likely authorization bypass. It is gori's counterpart to Burp's Autorize / Auth Analyzer and to AuthMatrix.

The **Authorize** tab is off the bar by default. Press **`0`** and type "auth", use the command palette (`Ctrl-P` → **Go to Authorize**), or give it one of the nine slots in Preferences (`Ctrl-,`) → **Network & Tabs** → **Tabs**.

## What an Identity Is

An identity is a **session slot**: a name, a static header overlay applied to the captured request before it is replayed, and the extract rules whose bound values belong to it. gori uses the same slots everywhere. The Authorize tab replays under every slot, and a Repeater or Fuzzer send goes out as the one that is active (see [Session slots](#session-slots-one-list-two-readers) below).

| Field | Effect |
|-------|--------|
| **set** | Upsert a header: replace the value of every header of that name (case-insensitive, original casing kept), or append it when absent |
| **remove** | Drop every header of that name |

An "anonymous" identity removes `Cookie` and `Authorization`. An "admin" or "low-priv" identity sets them to another session's values. An API identity sets `X-Api-Key`. The overlay touches header lines only. The request line, the body, and `Content-Length` do not change, so you compare the same request under different credentials.

Press `i` on the tab to open the identities card. A fresh project starts with two: **as-captured** (no overlay) and **anonymous** (drops `Cookie` and `Authorization`).

| Key | In the identities card |
|-----|------------------------|
| `↑` / `↓` | Pick an identity |
| `a` | Add |
| `e` / `↵` | Edit |
| `d` | Delete |
| `b` | Make this one the baseline |
| `esc` | Close |

The add / edit form has four fields: a **name** (unique and compared case-insensitively, with a duplicate refused on all three surfaces), the headers to **remove** (`drop headers:`, comma-separated), the headers to **set** (one `Name: value` per line), and **refresh before** (`off`, `jwt-exp` or `ttl=10m`; see [Refreshing a slot](#refreshing-a-slot)). The slot's refresh steps are listed read-only on the line above it. `⇥` moves between fields, `↵` saves (inside the set-headers editor it inserts a newline). A header line whose name is not a valid token, or whose value carries a CR or LF, is refused, and the error names the line.

Identities are saved with the project, so `gori run authorize` and the MCP tools default to the same set you configured here. The list shows header names only, so a session cookie is not shown on screen. The form shows values.

Changing the identity set marks every result already on screen as pending again, since those verdicts were produced under the old set.

## Session Slots: One List, Two Readers

This tab sends one request as every slot and compares the answers. Every other send path uses one slot. Pick it, and every request from then on goes out as that slot.

Picking the active slot and editing the list are separate actions:

| Surface | Pick the active slot | Edit the list |
|---------|----------------------|---------------|
| TUI | `Ctrl-P` → **Session slot**, or click the `session:NAME` chip | `i` on this tab |
| `gori run` | `--slot NAME` on the sending command | `gori run session list \| show \| add \| from-flow \| from-request \| edit \| rm \| baseline \| refresh` |
| MCP | `set_active_session_slot` | `list_session_slots`, `create_session_slot`, `update_session_slot`, `delete_session_slot` |

The active slot changes two things on `send_request`, a Repeater or Fuzzer send, and an intercept forward:

- Its **header overlay** is applied to the final wire bytes after `$BIND.NAME` substitution, to header lines only, so `Content-Length` does not change and the body is byte-exact.
- `$BIND.NAME` resolves against its binding table. An extract rule a slot claims writes that slot's table, and a rule no slot claims writes the global table. `Authorization: Bearer $BIND.SESSION` then means admin's token on the `admin` slot and the low-priv user's on `low-priv`, from one saved string.

A slot header resolves `$BIND.NAME` and `$GEN.NAME` only. An `$ENV.KEY` in one goes out as typed, and `gori run session add`/`edit` and MCP's slot writes warn when a header names one. Write the value instead.

There are three things the active slot does not do:

- **It does not apply to an Authorize run.** This tab supplies each identity itself, once per send, so a run ignores whichever slot is active. Otherwise the active slot's `Cookie` would overwrite every identity, including the one that removes it, and every queued row would report a bypass that does not exist. The second point above still applies: each identity's `$BIND.NAME` resolves from that identity's binding table as its overlay goes on, so `Cookie: session=$BIND.SESSION` on both `admin` and `low-priv` sends two different sessions.
- **It is never persisted.** Reopening a project, or a new `gori mcp` connection, starts as-captured. A slot's values are memory-only, so a restored "admin is active" would send an overlay whose `$BIND.SESSION` is literal and get a `401` with no visible cause.
- **`as-captured` is the baseline in both senses.** With no slot active no byte changes, so projects and playbooks written before slots existed behave as they did.

There is no cookie jar here. A slot carries the headers you wrote and the values gori observed. `--bind-from` replays one flow you named to fill them, and a slot's refresh steps replay the Repeater sessions you put in its list.

## Refreshing a Slot

A slot is a snapshot, so a long run can outlive its token. Give the slot **refresh steps**, the Repeater sessions that log in, in order (for example `csrf-fetch → login`), and the slot re-authenticates itself. Each step's response goes through the slot's extract rules, which rebind it. A step resolves the slot's own `$BIND.NAME` values and carries no slot header overlay, so the login never sends the stale credential it is replacing. A login that asks for a one-time code carries [`$GEN.TOTP`](/guide/repeater-and-fuzzer/#environment-variables), which mints a fresh code on every refresh.

| Surface | Add a step | Refresh now | Policy |
|---------|------------|-------------|--------|
| TUI | In the Repeater, `Ctrl-P` → **Use as refresh for slot…** on the login sub-tab | `Ctrl-R` on the row in the session slot picker | the **refresh before** field of the identity form (`i` on this tab) |
| `gori run` | `session edit NAME --refresh 12,14` | `session refresh NAME` | `--refresh-before` |
| MCP | `update_session_slot{refresh}` | `refresh_session_slot` | none: only `off` |

A **refresh before** policy runs the refresh automatically before a send that goes out as the slot: `jwt-exp` when a JWT bound in the slot is within 30 s of its `exp`, or `ttl=10m` when that long has passed since the last successful refresh (or, before one, since the slot's oldest binding). A refresh that leaves the JWT still about to expire counts as a failure. It applies to every identity an Authorize run sends as, not only to the active slot. It acts before a send and never reads a response. A `401` in this tab is a verdict and does not trigger a login and retry.

Only the operator arms a policy. An automatic refresh in the TUI sends the steps with the slot's live credentials and skips the up-front scope check. An agent over `gori mcp` can therefore set `refresh_before` only to `off`, and when it changes the steps of an armed slot (its `refresh` list, or the request or target of one of its Repeater sessions) the policy turns off and the reply says so. It can still run the steps by hand with `refresh_session_slot`, which is gated like any agent send.

Each refresh step lands in History with source `refresh` (`src:refresh`, SRC `RFRSH`), each refresh writes one event, and the `session:NAME` chip shows `⟳` while one runs and `!` after one failed. A failure also raises a notification and leaves the send going out with the value it had. A failed automatic refresh waits 30 s before it tries again, and after 3 failures in a row it switches off until a manual refresh succeeds. A step whose Repeater session was deleted stays in the list as `(deleted)` and refuses to run. Values stay per process. A refresh in the TUI does not update a running `gori mcp`.

## The Baseline

Exactly one identity in a run is the **baseline**, the response every other identity is judged against. Unless an identity claims it (`b` in the card, `"baseline":true` in JSON), the request as captured is the baseline. It goes out with its original session.

A run needs at least one identity besides the baseline, and all three surfaces refuse one that does not have it. With a single identity, the run would only compare the baseline against itself.

## The Loop

1. In **History**, select the flows worth testing and `Space` `>` `a` (**Send flow to…** → **Send to Authorize**). From **Sitemap**, the same verb queues the selected endpoint's captured flow.
2. On the **Authorize** tab, press `i` and set up the identities you want to compare.
3. `Ctrl-R` replays every queued request that has no result yet, `⇧R` re-runs everything, and `t` runs the request under the cursor.
4. Read the table. The top pane is one row per request with an aggregate verdict. `⇥` drills into the selected request's identities in the bottom pane.

Each identity gets its own connection, which costs a handshake per trial. Connection-oriented authentication (NTLM, Negotiate, common on internal engagements) authenticates the connection, not the message, so on a reused socket an identity that dropped `Cookie` would still be served the baseline's content, and the run would report a bypass that does not exist.

`Ctrl-X` stops. The stop is polled between requests and between identities, so it takes effect at the next send. A request cut short mid-identity yields no verdict, so a partial set of trials never reads as "enforced". With [passive replay](#passive-replay) on, a stop also pauses passive replay until your next `Ctrl-R`, or until you switch passive off and on with `p`.

## Reading a Verdict

Each identity's response is reduced to three facts (status, decoded body size, and a SimHash content fingerprint) and compared with the baseline's. Bodies are decoded (gzip / deflate / br / chunked) before hashing.

| Verdict | Means |
|---------|-------|
| `baseline` | This row *is* the baseline |
| `different` | A different status **class** (2xx vs 4xx vs 3xx) where this identity did not gain a 2xx, the clearest sign access control engaged. Or two redirects to a different destination |
| `same` | Same status class, and the body matches: within a SimHash distance of 3 **and** within 10% in size. Or two redirects to the same place |
| `review` | Same status class, divergent body. Or this identity got a 2xx the baseline did not (`403 → 200`, `304 → 200`); two redirects to the same path that differ only in query or fragment; a `HEAD` or `304` pair with no `ETag` or `Content-Length` to compare; or the baseline itself errored or was denied (4xx/5xx), so there was nothing to anchor against |
| `error` | This identity's send failed (TLS, DNS, timeout, refused); nothing was compared |

Two redirects are judged on their `Location`, before the body. A redirect's body is empty, so on the three facts alone an authenticated `302 → /dashboard` and an anonymous `302 → /login` would both read `same`. When both responses carry a `Location`, an exact match is `same`, the same scheme, host, port and path with only the query or fragment differing is `review` (both identities still reached the resource), and anything else is `different`. Paths are compared as written, so `/login` and `/login/` count as different.

The per-request row aggregates them: **BYPASS** (the TUI row reads `⚠ N same`) when any non-baseline identity came back `same`, **enforced** when every one clearly differed, **error** when every one of their sends *failed*, **review** otherwise.

A request nothing answered has neither a `same` nor a `different` verdict, so an aggregate built from those two alone would call it enforced. Every surface reports it as `error` instead: the tab paints the row `error`, `gori run authorize` prints `[x] error` for it, and the MCP verdict is `error` with an `unanswered_count` beside it. When nothing in the run was compared (every request either refused by the gate or unanswered), the CLI says so on its summary line and exits non-zero, so a script that gates on the exit code does not read a dead host as an endpoint that held.

SimHash skips numeric and hex tokens, so two differently-sized pages can hash close. The size band catches that. The 10% tolerance exists because real pages carry per-request noise (CSRF tokens, timestamps), and an exact match would flag all of it.

This is a heuristic, and the verdict names are neutral, because the security meaning depends on the identity's intended privilege, which only you know. `same` on a low-privilege identity is a likely bypass. `same` on a second admin session is expected. `review` is where a tailored "access denied" page rendered at 200 and a legitimately per-user page look identical to a fingerprint.

## What Gets Skipped, and Why

A selection can reach flows that cannot be replayed meaningfully. gori names every one it skips.

| Reason | Why | Override |
|--------|-----|----------|
| **no identity changes them** | No identity would alter this request's bytes, so every trial sends the same thing, the responses match by construction, and the row would read `same` | Add an identity that sets or drops the header this endpoint authenticates with |
| **not a safe method to repeat** | Only `GET` / `HEAD` / `OPTIONS` are replayed by default. A replayed `POST` / `PUT` / `PATCH` / `DELETE` runs its side effect again, once per identity | `--unsafe-methods` (CLI), `unsafe_methods:true` (MCP). The TUI's manual queue takes any method, because there a human picked the request |
| **never completed** | The capture has no response to compare against | — |
| **answered by gori** | gori short-circuited this request itself; there is no origin behind it | — |
| **outside project scope** | The outbound gate refused the target before the socket | `--allow-unscoped` (CLI), `allow_unscoped:true` (MCP), or add a scope include rule |
| **already queued** | The same flow was named twice | — |
| **no flow with that id** | A flow id you named does not exist (a typo, or a pruned flow) | — |
| **sent by gori, not the browser** | Passive replay only: the flow is gori's own traffic (a Repeater send, a fuzz row, an agent's request), not something you browsed | — |

The first row asks whether any identity would change the request's bytes, not whether the request carries a `Cookie`. A `Cookie` check would miss APIs authenticating through `X-Api-Key`.

## Passive Replay

`p` turns on unattended replay: as you browse through the proxy, every completed, in-scope, safe-method flow that at least one identity would change is queued and replayed automatically. It is off by default, and nothing else turns it on. It is the only control in the tab that sends requests to a target without anyone pressing a key.

Unlike the manual queue, passive needs a **scope include rule**. With none configured nothing is replayed, and gori says so when you press `p`. A browser session reaches many hosts outside the engagement, and passive follows the browser.

Passive dedups by endpoint (`METHOD` + URL), not by flow id, so a tenth visit to `/orders` does not requeue it while `/orders?id=2` gets its own row. The queue is capped at 200 requests, and gori announces when the cap is reached.

The tab keeps a live readout of what passive has done (`N seen · M queued · K skipped (reason)`).

## Keys

| Key | Action |
|-----|--------|
| `Ctrl-R` | Run pending: replay every queued request with no result yet (never run, or the send failed) |
| `⇧R` | Run all: replay everything, re-sending requests that already have a result |
| `t` | Run this request only |
| `Ctrl-X` | Stop the run |
| `i` | Identities: edit the set every request is replayed under |
| `p` | Toggle passive replay |
| `d` | Remove the selected request from the queue |
| `/` | Filter the queue by method / host / path / verdict |
| `y` | Copy the selected request as `METHOD host/path` |
| `↑` / `↓` | Move between requests |
| `⇥` | Move between the selected request's identities |
| `PgUp` / `PgDn` | Scroll the detail pane |
| `⇧X` | Clear: empty the queue and every identity's results (asks first). `Space` → `X` does the same; `⇧X` is the clear-all key in History, Probe, Issues and the Project ACTIVITY feed too |

From **History** or **Sitemap**, `Space` `>` `a` (**Send flow to…** → **Send to Authorize**) queues a request here.

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

Text output is one block per request: a headline you can scan down the left edge for `[!] BYPASS`, then one row per identity:

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

Manage the slot list (the same rows the `i` card edits) without opening the TUI:

```bash
gori run session list                       # names, overlays (values [REDACTED]), claimed rules
gori run session add --name low-priv --set 'Cookie: session=…' --rule SESSION
gori run session edit low-priv --clear-set --set 'Cookie: session=new'
gori run session baseline as-captured
gori run session rm low-priv
```

There is no `gori run session activate`, because a `gori run` process sends and exits. Name the identity on the send instead. `--slot NAME` works on `send`, `repeater`, `repeater send`, `repeater race`, `repeater timing`, `repeater minimize`, `fuzz`, `mine`, `sequence`, `discover` and `retest run`, and applies before `--bind-from` replays its seed, so the seed fills the slot the run then sends as.

`--format jsonl` streams one object per request as it lands. `--format json` buffers and emits a single array at the end. Both carry the decoded body size the verdict compared alongside the wire size. For a gzipped response the two can differ by an order of magnitude. Full flags are in the [CLI Reference](/reference/cli/#run-authorize).

## From an Agent

Four MCP tools drive the same engine as a background job: `authorize_start` (returns a `job_id`, the planned send count, the identity names, the scope gate, and everything it skipped), `authorize_status`, `authorize_results`, and `authorize_stop`.

`authorize_results` puts the answer first. `access_control` names the outcome in one token (`BYPASS`, `enforced`, `review`, `error`, or `nothing_sent`; the last two both mean nothing was compared), `summary` says it in a sentence, and `bypasses` lists every request where a non-baseline identity was served the baseline's response, flat and never paged. Past the 40 KB reply budget the rest are named by flow id in `bypasses_unshown_ids`, and their detail is in the `results` rows marked `bypass: true`.

Six more manage the slots: `list_session_slots` (with the active one named, header values `[REDACTED]` unless you ask), `create_session_slot`, `update_session_slot`, `delete_session_slot`, `set_active_session_slot` (picks the identity every other tool's sends go out as, for the life of that server process), and `refresh_session_slot` (runs a slot's refresh steps now).

A run is capped at 2,000 sends, and the cap counts `flows × identities`. A 500-row query under five identities (2,500 sends) is refused up front, naming both factors, instead of being truncated. Layer-1 scope is strict here. An out-of-scope target needs `allow_unscoped:true`.

## A Run That Sent Nothing Is Not Evidence

Every surface enforces this.

If the sandbox or an exclude rule refused every send before the socket, or if every selected flow was skipped, gori does **not** report "no identity matched the baseline". It says nothing was sent. A run you stop part-way says it was stopped and counts only the requests that finished.

A genuine `enforced` means access control held for the identities you tested, on the requests you replayed. A different endpoint, a different privilege boundary, or an identity you did not model is untested, not safe.

## Next Steps

- [Proxy & History](/guide/proxy/): capture the traffic and set the scope this tab replays inside
- [Scanning & Issues](/guide/scanning/): file a confirmed bypass as an Issue
- [Scripting](/guide/scripting/): run the same comparison headless, in CI
- [MCP Server](/guide/mcp/): hand the loop to an agent
