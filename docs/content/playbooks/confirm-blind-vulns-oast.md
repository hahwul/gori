+++
title = "Confirm blind vulnerabilities with OAST"
description = "Some bugs never show in the response — prove them by making the server call you, and catch the callback."
weight = 100

[extra]
group = "Workbenches"
+++

A blind SSRF, a blind XXE, an out-of-band injection — none of them answer you in the response. They reach out to some *other* server instead. **OAST** gives you that server: gori mints a payload URL tied to a listener, you plant it in a request, and any DNS or HTTP callback the target makes to it lands as a hit you can point to. This playbook runs one confirmation end to end in about ten minutes.

> **Before you begin.** [Set up an engagement](/playbooks/set-up-an-engagement/) first, and have a candidate injection point in hand — a parameter, header, or field that might make the server fetch a URL or resolve a hostname. A callback reaches a public interaction server that sees its metadata, so only run OAST against systems you're authorized to test, and prefer a self-hosted provider for sensitive work.

## 1. Start a listener and grab a payload

Open the **OAST** tab (visible by default, next to Fuzzer) and press `Ctrl-R` to start listening. gori registers with a provider — public `interactsh` by default — and mints a **payload**: a unique hostname/URL that belongs to you for this session. Copy it with `g` (get payload).

Headless, when you want the listener in a script or an agent loop:

```bash
gori run oast listen
```

One caveat: `gori run oast` is a store-free, ad-hoc listener — its registration dies with the process. Only the TUI keeps a listener across a session (resume it later with `r`), so use the tab when the callback might arrive late.

**Checkpoint.** The OAST tab shows a live payload URL, and the **Callbacks** table is empty and waiting.

## 2. Plant the payload

Take that payload URL and put it where the target might dereference it. Send the candidate request to **Repeater** (`Ctrl-R` from History) or the **Fuzzer** (`Shift-I`), then `Space` → **Insert OAST payload** to drop the URL at the cursor. Plant it in whatever might trigger a server-side fetch: a URL parameter, a `Host` or `X-Forwarded-For` header, an XML entity for XXE, a webhook field. Send the request.

**Checkpoint.** The request carrying your payload reached the target — a normal response is fine here; the point is what the *server* does next, out of band.

## 3. Watch for a callback

Back on the **OAST** tab, callbacks land in the **Callbacks** table as the target's infrastructure resolves the name or connects back — each with its protocol (`dns` / `http` / `smtp`), source IP, timestamp, and the sub-identifier that tells you which payload fired. `Ctrl-X` stops polling but keeps the registration, so a payload you already planted keeps resolving; press `r` to resume later and pick up whatever the provider buffered while you were away.

<figure class="tui-shot">
  <img src="/images/tui/oast.svg" alt="gori OAST tab with a Callbacks table of four decrypted hits on an interactsh payload: two DNS A lookups and two HTTP GET requests, each with a source IP and the payload as destination">
  <figcaption>The <strong>OAST</strong> tab registers a payload and lists every DNS, HTTP, or SMTP callback the target makes to it, decrypted and timestamped.</figcaption>
</figure>

> A callback is proof the target reached a server it had no reason to reach. The absence of one is **not** proof of safety — egress may be filtered — only that this path stayed quiet. Don't close a candidate on silence alone.

**Checkpoint.** At least one row sits in the **Callbacks** table, matching the payload you planted in step 2.

## 4. Turn a hit into an Issue

A callback is the strongest evidence this tool produces, so record it. Select the hit and press `Shift-F` (or `Space` → **Add issue**) to file it as an **Issue**, prefilled with its protocol and source and carrying the raw interaction as its notes. It opens at **HIGH** — `Tab` re-rates it before you commit.

**Checkpoint.** The confirmed callback is recorded as an Issue in the **Issues** tab, evidence attached.

## Next Steps

- [Triage and report](/playbooks/triage-and-report/): turn confirmed issues into a deliverable
- [OAST](/guide/oast/): providers, resuming listeners, and self-hosting interactsh
- [CLI Reference](/reference/cli/#run-oast): every `gori run oast` flag and the saved-provider verbs
