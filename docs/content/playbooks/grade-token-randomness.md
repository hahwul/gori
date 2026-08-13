+++
title = "Grade token randomness"
description = "Collect a few hundred session tokens and let the Sequencer score how predictable they are."
weight = 90

[extra]
group = "Workbenches"
+++

A predictable session cookie, CSRF token, or reset code is one an attacker can forge or guess. The **Sequencer** collects a few hundred of them and grades the real unpredictability each one carries. This playbook runs one grade end to end — point, collect, read, export — in about ten minutes, most of it spent waiting on the server to hand out samples.

> **Before you begin.** [Set up an engagement](/playbooks/set-up-an-engagement/) so the target is scoped — the Sequencer replays a live request many times and won't fire out of scope. Have a flow whose response sets the token you want to grade (a `Set-Cookie` for a session or CSRF token). Only collect tokens from a target you're authorized to test; each sample is a real, freshly minted credential.

## 1. Point the Sequencer at a token

The Sequencer tab is hidden by default — it's a workbench you reach for occasionally, not part of the daily loop. Reveal it from the tab-bar `⋯` menu, or with `Ctrl-P` → **Go to Sequencer**.

Feed it from a captured flow: in **History**, select the flow whose response sets the token, then `Space` → **Send to Sequencer**. gori auto-detects the likely session cookie and drops you on the **CONFIG** pane. Press `c` to reconfigure the token location if the guess is wrong — pick one of Cookie, Header, Regex, Position, or JSONPath.

Aim the extraction at the token's *varying* region only. Real tokens carry a skeleton — a `sess_v1_` prefix, a version byte, padding — that never changes across the sample. Counting that fixed structure as if it were random drags the grade down and can misfire the bit-level tests, so the token descriptor should cover the part that actually moves.

<figure class="tui-shot">
  <img src="/images/tui/sequencer.svg" alt="gori Send to Sequencer config card over the History tab, showing an auto-detected session cookie as the token, with rows for sample count, max requests, concurrency and notification">
  <figcaption>Sending a captured flow to the <strong>Sequencer</strong> auto-detects the session cookie and lets you set the sample size and concurrency before collecting.</figcaption>
</figure>

**Checkpoint.** The **CONFIG** pane names your source flow and the token location you picked; the **SAMPLES** pane is still empty.

## 2. Collect samples

Press `Ctrl-R` to collect. gori replays the source request over and over, pulling the token out of each response, until it reaches the target count. `Ctrl-X` stops early. Collection runs at **concurrency 1** by default, because session tokens are often stateful — each request advances a server-side counter — and firing them in parallel would scramble the order the tests rely on. Raise it only when the endpoint is stateless.

Same collection, headless — replay flow 42, extract the `SESSIONID` cookie, gather 500 tokens:

```bash
gori run sequence 42 --cookie SESSIONID --count 500
```

**Checkpoint.** The **SAMPLES** count climbs toward your target as the replays land.

## 3. Read the grade

The **ANALYSIS** pane leads with **effective entropy** in bits — a conservative estimate of the real unpredictability per token — and a rating that follows from it: **Secure** (≥ 88 bits), **Moderate** (≥ 60), **Weak** (≥ 30), **Critical** (below 30). Under it sits the battery of statistical tests gori ran over the token bitstream (monobit, runs, chi-square, serial correlation, compression, and more).

Read it like this: a high entropy figure with every row passing means the token *looks random* to every test gori has — no shortcut to forge it turned up. Any **duplicate** or **sequential** token, though, drops the verdict straight to **Critical** however high the entropy reads, because a token you saw twice is a token you can predict. A small sample (under ~20 usable tokens) softens hard failures to warnings and caps the rating, so collect more before you trust a clean grade.

**Checkpoint.** The **ANALYSIS** pane shows one overall rating plus the per-test table behind it.

## 4. Export the verdict

The collected tokens are live credentials, so gori never writes them to disk — they vanish with the session. The verdict shouldn't. Press `⇧E` to export a Markdown report to a path you choose (the palette offers the same report as JSON), or `Space` → `i` to file it as an **Issue**, which maps Critical to `critical`, Weak to `high`, Moderate to `medium`, and Secure to `info`. Neither carries a token value: the report is built from frequency tables and verdicts, so there's nothing in it to leak.

**Checkpoint.** You have a saved grade — report or Issue — and not a single raw token left behind.

## Next Steps

- [Confirm blind vulnerabilities with OAST](/playbooks/confirm-blind-vulns-oast/): the next workbench, for bugs the response never shows
- [Sequencer](/guide/sequencer/): the full reference for token locations, the test battery, and structure detection
- [CLI Reference](/reference/cli/#run-sequence): every `gori run sequence` flag, including `--tokens` for a pasted list
