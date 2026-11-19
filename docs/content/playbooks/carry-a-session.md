+++
title = "Carry a session"
description = "Log in once, capture the token, and replay every later request as an authenticated user, by hand and headless."
weight = 50

[extra]
group = "The manual loop"
+++

This playbook captures a login, binds its rotating token to a name, writes that name onto every later request, does the same thing headless in a single command, carries several sessions side by side, and finally fetches a fresh token for every request when the app hands out single-use ones. Budget about ten minutes.

> **Before you begin.** [Set up an engagement](/playbooks/set-up-an-engagement/) first, and be able to log into the target through the proxy so its auth response is captured. Only replay sessions against a target you are authorized to test. The examples use `api.example.com` as a stand-in.

## 1. Capture a login

Log in to the target through gori the way the [Quick Start](/getting-started/quick-start/) covers: an **Open browser** session, or your own client pointed at `127.0.0.1:8070`. You want the flow whose response hands you a session, such as a `Set-Cookie: session=…` or a token in a JSON body like `{"access_token": …}`. Find it in **History**:

```bash
gori run history -q 'path:/login status:200'
```

Note the flow id. The headless step later replays this flow.

**Checkpoint.** The login response is in History and carries the token, whether as a `Set-Cookie` header or a field in its body.

## 2. Extract the token into a variable

A rule cannot spell out a rotating token in advance, so gori binds the token to a name and fills the name in at send time. Open the **Rewriter** tab, `extract` sub-tab, and add a rule that reads the token out of the login response and binds `$BIND.SESSION` to it. A **descriptor** picks where the value lives (a cookie, a response header, a regex over the body, a JSON path, or a byte range) alongside a condition (`path:/login AND status:200`) and an optional host glob, so the rule only reads the response you mean.

```bash
gori run rewriter extract add --name SESSION --kind cookie --selector session \
  --when 'path:/login AND status:200' --host '*.example.com'
```

For a token in a JSON body, use `--kind jsonpath --selector '$.access_token'` (or `--kind regex` with a capture group over the body).

**Checkpoint.** `gori run rewriter bindings` lists `$BIND.SESSION`. Extraction runs on proxy traffic and on hand sends (a Repeater send), **not** on sweeps. Replay the login once and the `bindings` sub-tab shows the name bound. The value lives in memory only and is never written to `settings.json` or the project database.

## 3. Write it back on every request

Next, put the value back on the wire. How you do that depends on who sends the request. For traffic through the proxy (your browser or client), use a **Match & Replace** rule. On the **Rewriter** tab, add a **set header** rule on the **request** side that sets `Authorization` (or `Cookie`) to `$BIND.SESSION`. `$BIND.SESSION` is resolved as each request goes out, so every proxied request from here on is authenticated.

```bash
gori run rewriter add --op set_header --target request \
  --find Authorization --value 'Bearer $BIND.SESSION' --host '*.example.com'
```

Match & Replace rules touch proxied traffic only. A Repeater or Fuzzer send goes out as you wrote it, so write the name into the request itself. An `Authorization: Bearer $BIND.SESSION` line in the Repeater editor or a fuzz template is resolved at send time the same way, and a session slot (step 5) adds the header for you without editing each request.

**Checkpoint.** A request through the proxy to a protected endpoint that returned `401` before now returns `200`, and so does a Repeater send whose `Authorization` line reads `Bearer $BIND.SESSION`. If the rule is skipped, the events feed says the name resolved to nothing. Recapture the login to rebind it.

## 4. Do it headless

`gori run` is one process per invocation, and a binding lives only in the memory of the process that observed the login. A fresh `fuzz` or `mine` has nothing to resolve `$BIND.SESSION` with, so the token goes out as literal text. A sweep is not an extraction source either, so a response echoing an attack payload cannot rebind your session. `--bind-from` replays one captured flow (the login) first, so its response fills the binding table for the rest of the run in the same process. The template has to name the token, so fuzz a request file whose `Authorization` line reads `Bearer $BIND.SESSION`. A captured flow's bytes do not contain that name, and step 5's `--slot` adds the header to those:

```bash
gori run fuzz --request req.http --target https://api.example.com --bind-from 17 --wordlist ids.txt
# bind-from: flow #17 replayed → bound $BIND.SESSION
```

The same flag works on `mine`, `sequence`, and `discover`.

**Checkpoint.** The run prints a `bind-from: flow #… replayed → bound $…` line, and its responses come back authenticated instead of `401`.

## 5. Carry more than one session

Steps 2-4 carry one session. An engagement usually needs several at once (an admin, a low-privilege user, an anonymous client), and `$BIND.SESSION` holds one value at a time. A **session slot** is an identity with its own header overlay and its own binding table. A send goes out as the **active** slot.

Slots are the same rows the [Authorize](/guide/authorize/) tab's identities card edits, so slots you configured there appear here. Add one headless:

```bash
gori run session add --name admin    --set 'Authorization: Bearer $BIND.SESSION' --rule SESSION
gori run session add --name low-priv --set 'Authorization: Bearer $BIND.SESSION' --rule SESSION
gori run session list
```

Both slots write the same header from the same `$BIND.SESSION` but hold different tokens. A slot that claims an extract rule (`--rule SESSION`) takes that rule's observed value into its own table instead of the global one. Each slot holds the token from the login you replay while it is active.

Then name the identity on the send. In the TUI it is `Ctrl-P` → **Session slot** (or the `session:NAME` chip in the top bar), and every later send shows which slot it goes out as. Headless it is `--slot`:

```bash
gori run fuzz 42 --slot low-priv --bind-from 17 --wordlist ids.txt
# slot: sending as low-priv
# bind-from: flow #17 replayed → bound $BIND.SESSION
```

`--slot` is applied before `--bind-from`, so the login replay fills the active slot's table and the sweep resolves `$BIND.SESSION` out of the same one. Run the same command with `--slot admin` and a different login flow, and the second run tests the same target as a second session.

The overlay is header-only (`Content-Length` does not change and the body is byte-exact), so a slot is safe on bytes you did not author: a captured replay, a fuzz template with its payload already spliced.

Two limits apply. The active slot is **never persisted**. Reopening the project starts as-captured, because a slot's values are memory-only and an overlay over an empty table would send `$BIND.SESSION` literally. There is no cookie jar. A slot carries the headers you wrote and the values gori observed, and `--bind-from` is how you log in again.

For a run long enough to outlive the token, give the slot **refresh steps**: the Repeater sessions that log in, in order. `gori run session edit admin --refresh 12,14 --refresh-before jwt-exp` makes a `--slot admin` send refresh the slot first whenever its bound JWT is about to expire, and `gori run session refresh admin` runs the steps by hand to check them. In the TUI, `Ctrl-P` → **Use as refresh for slot…** on a Repeater sub-tab appends that sub-tab to a slot's steps. A refresh runs before a send, and gori never retries after a `401`. See [refresh steps](/reference/cli/#refresh-steps).

**Checkpoint.** `gori run session list` shows both slots, and a `--slot low-priv` run prints `slot: sending as low-priv` before its first request.

## 6. Fetch a fresh token for every request

Some values expire long before the session, such as a form's CSRF token or a nonce the app hands out on each page load and accepts once. Refresh steps renew a value before it *expires*, but a sweep still spends one value on every candidate, so the first candidate gets `200` and every one after it `403`. A **request-time macro** is a saved Repeater session that runs before each candidate, so the extract rule from step 2 rebinds the name to a fresh value.

Save the request that serves the token (the form page, or the API call that returns the nonce) as a Repeater session, and keep an extract rule that binds it:

```bash
gori run rewriter extract add --name CSRF --kind regex \
  --selector 'name="csrf" value="([^"]+)"' --when 'path:/profile AND status:200'
```

Then write `$BIND.CSRF` where the token goes in the request you sweep: a Repeater session (here `12`) whose body reads `csrf=$BIND.CSRF&email=§x§`. Name the token's session (here `15`) as the macro:

```bash
gori run fuzz --repeater 12 --macro 15 --wordlist emails.txt
```

The default cadence runs the macro before every candidate, so the sweep sends one candidate at a time. `--macro-every 10` lets ten share a value when the app allows it. A macro that fails (an error, a `4xx`/`5xx`, or no binding rebound) never sends its candidate with a stale token, and three failures in a row end the run. Seed the sweep from a Repeater session or a draft, because a captured flow is sent as captured and does not contain `$BIND.CSRF`. A token that travels in a header can go in the active slot's overlay instead. In the TUI the macro is a row on the Fuzzer's **ADVANCED** card and in the Miner's popup, and over MCP it is `macro_steps` on `fuzz_start` / `mine_start`. See [Rotating Tokens with a Macro](/guide/repeater-and-fuzzer/#rotating-tokens-with-a-macro).

**Checkpoint.** Rows after the first come back with real answers instead of `403`, and `gori run history -q 'src:macro'` lists the macro's steps.

## Next Steps

- [Test access control](/playbooks/test-access-control/): replay your captured requests as each slot and find what the server forgets to check
- [Authorize](/guide/authorize/): replay one request under *every* slot at once to find broken access control
- [Decode and transform](/playbooks/decode-and-transform/): read and rewrite the encoded values a session carries
- [Session bindings](/guide/proxy/#session-bindings): the full reference for extract rules and where a value may live
- [Scripting](/guide/scripting/): the headless sweep contract, exit codes, and `--bind-from`
