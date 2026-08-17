+++
title = "Carry a session"
description = "Log in once, capture the token, and replay every later request as an authenticated user — by hand and headless."
weight = 50

[extra]
group = "The manual loop"
+++

An authenticated test is a login you do once and a token you carry everywhere after. This playbook captures the login, binds its rotating token to a name, writes that name onto every later request, does the same thing headless in a single command, and then carries several sessions side by side. Budget about ten minutes.

> **Before you begin.** [Set up an engagement](/playbooks/set-up-an-engagement/) first, and be able to log into the target through the proxy so its auth response is captured. Only replay sessions against a target you are authorized to test; the examples use `api.example.com` as a stand-in.

## 1. Capture a login

You need the response that authenticates you before you can reuse it. Log in to the target through gori the way the [Quick Start](/getting-started/quick-start/) covers — an **Open browser** session, or your own client pointed at `127.0.0.1:8070`. The flow you are after is the one whose response hands you a session: a `Set-Cookie: session=…`, or a token in a JSON body such as `{"access_token": …}`. Find it in **History**:

```bash
gori run history -q 'path:/login status:200'
```

Note the flow id — the headless step at the end replays exactly this flow.

**Checkpoint.** The login response is in History and carries the token, whether as a `Set-Cookie` header or a field in its body.

## 2. Extract the token into a variable

A rotating token is worthless to a rule that has to spell it out in advance, so gori binds it to a name it fills in at send time. Open the **Rewriter** tab, `extract` sub-tab, and add a rule that reads the token out of the login response and binds `$SESSION` to it. A **descriptor** picks where the value lives — a cookie, a response header, a regex over the body, a JSON path, or a byte range — alongside a condition (`path:/login AND status:200`) and an optional host glob, so the rule only reads the response you mean.

```bash
gori run rewriter extract add --name SESSION --kind cookie --selector session \
  --when 'path:/login AND status:200' --host '*.example.com'
```

For a token in a JSON body instead, use `--kind jsonpath --selector '$.access_token'` (or `--kind regex` with a capture group over the body).

**Checkpoint.** `gori run rewriter bindings` lists `$SESSION`. Extraction runs on proxy traffic and on hand sends (a Repeater send), **not** on sweeps — so replay the login once and the `bindings` sub-tab shows the name bound. The value lives in memory only; it is never written to `settings.json` or the project database.

## 3. Write it back on every request

Binding the name only captured the value; a **Match & Replace** rule is what puts it back on the wire. On the **Rewriter** tab add a **set header** rule on the **request** side that sets `Authorization` (or `Cookie`) to `$SESSION`. The `$SESSION` is resolved when each request goes out, not when you saved the rule, so every Repeater and Fuzzer send from here leaves authenticated.

```bash
gori run rewriter add --op set_header --target request \
  --find Authorization --value 'Bearer $SESSION' --host '*.example.com'
```

**Checkpoint.** A Repeater replay of a protected endpoint that returned `401` before now returns `200`. If the rule is skipped instead, the events feed says the name resolved to nothing — recapture the login to rebind it.

## 4. Do it headless

`gori run` is one process per invocation, and a binding lives only in the memory of the process that observed the login — so a fresh `fuzz` or `mine` has nothing to resolve `$SESSION` with and is refused before it sends. A sweep is deliberately not an extraction source either: a response echoing an attack payload back could otherwise rebind your session to a payload-derived value. `--bind-from` closes the gap. It replays one captured flow — the login — first, so its response fills the binding table for the rest of the run in the same process:

```bash
gori run fuzz 42 --bind-from 17 --wordlist ids.txt
# bind-from: flow #17 replayed → bound $SESS
```

The same flag works on `mine`, `sequence`, and `discover`.

**Checkpoint.** The run prints a `bind-from: flow #… replayed → bound $…` line, and its responses come back authenticated instead of a wall of `401`s.

## 5. Carry more than one session

Steps 2–4 carry *a* session. A real engagement usually needs several at once — an admin, a low-privilege user, an anonymous client — and `$SESSION` can only mean one thing at a time. A **session slot** is that name: an identity with its own header overlay and its own binding table, and the one that is **active** is what a send goes out as.

Slots are the same rows the [Authorize](/guide/authorize/) tab's identities card edits, so a set you already configured there is already here. Add one headless:

```bash
gori run session add --name admin    --set 'Authorization: Bearer $SESSION' --rule SESSION
gori run session add --name low-priv --set 'Authorization: Bearer $SESSION' --rule SESSION
gori run session list
```

Both slots write the same header off the same `$SESSION`, and they mean different tokens: a slot that **claims** an extract rule (`--rule SESSION`) takes that rule's observed value into its own table instead of the global one. Which token each ends up holding is decided by which login you replay while that slot is active.

Then name the identity on the send. In the TUI it is `Ctrl-P` → **Session slot** (or the `session:NAME` chip in the top bar), and every later send says who it is going out as. Headless it is `--slot`:

```bash
gori run fuzz 42 --slot low-priv --bind-from 17 --wordlist ids.txt
# slot: sending as low-priv
# bind-from: flow #17 replayed → bound $SESSION
```

`--slot` is applied **before** `--bind-from`, so the login replay fills the active slot's table and the sweep resolves `$SESSION` out of the same one. Run the identical command with `--slot admin` and a different login flow, and the two runs are two sessions of the same target.

The overlay is header-only — `Content-Length` never moves and the body is byte-exact — so a slot is safe on bytes you did not author: a captured replay, a fuzz template with its payload already spliced.

Two limits worth knowing before you lean on it. The active slot is **never persisted**: reopening the project starts as-captured, because a slot's values are memory-only and restoring the pointer into an empty table would send an overlay whose `$SESSION` is literal. And there is no cookie jar and no auto-login macro — a slot carries the headers you wrote and the values gori observed, and `--bind-from` is the explicit version of "log in again".

**Checkpoint.** `gori run session list` shows both slots, and a `--slot low-priv` run prints `slot: sending as low-priv` before its first request.

## Next Steps

- [Authorize](/guide/authorize/): replay one request under *every* slot at once to find broken access control
- [Decode and transform](/playbooks/decode-and-transform/): read and rewrite the encoded values a session rides on
- [Session bindings](/guide/proxy/#session-bindings): the full reference for extract rules and where a value may live
- [Scripting](/guide/scripting/): the headless sweep contract, exit codes, and `--bind-from`
