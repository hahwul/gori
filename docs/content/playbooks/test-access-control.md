+++
title = "Test access control"
description = "Replay the requests you captured as another user, and as nobody, to see which ones the server forgets to check."
weight = 55

[extra]
group = "Workbenches"
+++

You browsed the app as one user, and every page worked. That proves very little. The real question is what happens when someone *else* asks for the same thing: a user with fewer rights, a user from another account, or someone who is not logged in at all. This playbook sets up those people as identities, replays your captured requests as each of them, and reads which requests came back the same when they should not have. Budget about fifteen minutes.

> **Before you begin.** [Set up an engagement](/playbooks/set-up-an-engagement/) so your target is scoped, and get two test accounts from whoever authorized the test: one with more rights than the other. [Carry a session](/playbooks/carry-a-session/) explains session slots in more depth, but you do not need it first. Only test a target you are authorized to test; the examples use `api.example.com` as a stand-in.

## 1. Browse as the stronger user

Log in as the account with more rights (an admin, or the owner of some data) and use the app normally through gori. Open the pages, list the records, view a single record, change a setting. Every request you make now is one you can replay later as someone else, so the more of the app you touch, the more you get to test.

Watch for requests that carry an id or name a resource: `/orders/1042`, `/api/users/7/profile`, `?account=acme`. Those are where access-control bugs usually live.

**Checkpoint.** **History** holds the admin's traffic, including a few requests that fetch one specific record.

## 2. Make an identity for the weaker user

An identity is a set of header changes gori applies before it replays a request. A new project already has two: **as-captured**, which sends the request exactly as you captured it, and **anonymous**, which removes `Cookie` and `Authorization`. You only need to add the weaker user.

The quickest way is to let gori read a login. Log in as the weaker account through gori in a second browser or a private window, find that login in History, and build a slot from it. Do not log the admin out to do this: on most apps that kills the session cookie your captured requests carry, and every replay would start from a dead session.

```bash
gori run history -q 'path:/login status:200'
gori run session from-flow <login-flow-id> --name low-priv
```

gori takes the cookies (or the bearer token) from the login response and saves them as the `low-priv` identity. In the TUI you can do the same by hand: open the **Authorize** tab, press `i`, then `a`, name it `low-priv`, and paste the user's `Cookie:` line into the set-headers field.

The Authorize tab is not on the tab bar by default. Press `0` and type "auth", or use `Ctrl-P` → **Go to Authorize**.

**Checkpoint.** `gori run session list` (or `i` on the Authorize tab) shows three identities: `as-captured`, `anonymous` and `low-priv`.

## 3. Queue the requests and run

In **History**, select the requests worth testing and press `Space` → `>` → `a` (**Send flow to…** → **Send to Authorize**). Pick requests that return something private: a record, a profile, a settings page, an admin list. A public page tells you nothing.

On the **Authorize** tab, press `Ctrl-R`. gori replays each queued request once per identity, each on its own connection, and compares every answer with the as-captured one.

Headless, name the flows (or a query) instead:

```bash
gori run authorize 12 13 14
gori run authorize --query 'host:api.example.com method:GET status:200' --limit 20
```

By default only `GET`, `HEAD` and `OPTIONS` are replayed headless. A replayed `POST` or `DELETE` does its job again, once for every identity, so gori skips those unless you pass `--unsafe-methods`. Only do that on a test account where running the action again is harmless. In the TUI, a request you queued by hand is replayed whatever its method, because you chose it.

**Checkpoint.** Every queued row has a verdict, and `⇥` shows how each identity answered.

## 4. Read the results

Each identity's answer is compared with the baseline on status, size and content:

| Verdict | What it means |
|---------|---------------|
| `same` | This identity got what the admin got. If it should not have, that is your bug |
| `different` | A different kind of answer, such as a `403` or a redirect to the login page. Access control did its job |
| `review` | Close but not the same. Look at it yourself |
| `error` | The request failed. Nothing was compared |

A request row reads **BYPASS** when any identity came back `same`. That is a lead, not a finding yet. `same` for `anonymous` on `/admin/users` is a real problem. `same` for `low-priv` on a page every user is allowed to see is fine. gori can compare the answers, but only you know who is supposed to see what.

If almost every row reads `review`, check the baseline first. When the admin's own replay comes back `401` or `403`, the captured session has expired and there is nothing to compare against. Log in as the admin again, capture fresh requests, and rerun.

`review` needs a careful look. Some apps answer a denied request with a friendly "access denied" page and a `200`, and some pages are almost the same for every user. Open the row and read both bodies.

Headless output puts `[!] BYPASS` at the start of the line so it is easy to spot:

```
[!] BYPASS    #1     GET    https://api.example.com/admin/users  · 1 of 2 identities matched the baseline
      as-captured         baseline  200  4.1KB    —
      anonymous           different 302  0B       Δ status 200 → 302 · …
      low-priv            same      200  4.1KB    Δ status 200 · size same · …
```

**Checkpoint.** You have a short list of `BYPASS` and `review` rows, and you know which of them are real.

## 5. Confirm one by hand

Before you write anything up, prove it once by hand. Send the request to the **Repeater** (`Ctrl-R` from History), pick the weaker identity with `Ctrl-P` → **Session slot**, and send it. Headless:

```bash
gori run repeater <flow-id> --slot low-priv
```

Check that the response really holds the admin's data, not an empty shell or a cached page. For an id in the path, try a record that belongs to another user, too. A bug that lets user A read user B's order is worth more than one that shows A their own.

**Checkpoint.** A Repeater send as `low-priv` returns data that user should not see.

## 6. File it

Turn the confirmed row into an issue with the flow attached, so the evidence stays with it:

```bash
gori run issues create --title "Low-privilege user can list all users" \
  --severity high --host api.example.com --flow <flow-id>
```

[Triage and report](/playbooks/triage-and-report/) covers the rest: severity, notes, and the export.

## When nothing comes back

An empty result is not always good news. gori tells you when it skipped a request instead of quietly sending less:

- **no identity changes them**: the request carries no header any identity changes, so every identity would send the same bytes. The endpoint probably authenticates in a header you did not cover (`X-Api-Key`, for example). Add an identity that sets or removes it.
- **not a safe method to repeat**: see step 3.
- **outside project scope**: add the host to the scope.

If every send was refused or failed, the run says nothing was sent. It never reports that as "access control held". And `enforced` only covers the identities and requests you tried. An endpoint you never browsed is untested, not safe.

## Next Steps

- [Authorization Testing](/guide/authorize/): every verdict rule, passive replay, and the MCP tools
- [Carry a session](/playbooks/carry-a-session/): tokens that rotate, and refresh steps for long runs
- [Triage and report](/playbooks/triage-and-report/): turn the bypass into a report
