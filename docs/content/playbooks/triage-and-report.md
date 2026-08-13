+++
title = "Triage and report"
description = "Turn scattered findings into issues, prove a fix with a diff, and export a report a teammate can read."
weight = 110

[extra]
group = "Wrap up"
+++

By now you have findings scattered across the Probe tab, a Repeater tab, and your own memory. This playbook gathers them into something you can hand off: an issue with a severity, a diff that proves it, and a report a teammate can read without gori installed. Set aside about ten minutes. Almost nothing here sends new traffic — you work with what you already captured.

> **Before you begin.** You need an engagement with some captured or tested traffic worth writing up — work through the earlier playbooks first, or bring a project of your own. The examples use `api.example.com` as a stand-in.

## 1. Skim passive findings

**Probe** runs its passive checks on every flow you capture and every Repeater send. They cost nothing extra — no request leaves your machine to produce them — so this is the cheapest place to start. Open the **Probe** tab: findings are grouped by check and host, so one row can stand for dozens of hits (permissive CORS, missing security headers, cookie hygiene, secrets in a URL, and the rest).

Open a row and the **AFFECTED URLS** list is the evidence: `↑`/`↓` walk it, `Enter` opens the flow that URL was captured on in the same detail view History uses, and `r` sends it to the Repeater to dig further.

Read the same set headless, which also sends nothing on its own:

```bash
gori run probe                       # passive findings only
gori run probe --severity high       # only the high-severity rows
gori run probe --category cors       # a single category
```

**Checkpoint.** The Probe tab lists findings grouped by severity and category, each one openable to the flow it came from — and History's request count did not move to produce them.

## 2. File an issue

**Issues** is the triage list you eventually hand to a report. Press `Shift-F` on a **History** flow or a Repeater send to file one; promote a **Probe** finding into an issue from the Probe tab. Give it a severity (`info` through `critical`) and a status (`open`, `confirmed`, `false-positive`, `resolved`). The flow you filed it from is linked as evidence, so the issue carries its own proof — `Enter` on the issue jumps straight back to that exchange.

<figure class="tui-shot">
  <img src="/images/tui/issues.svg" alt="gori Issues tab listing triaged findings with severity, status, host and title columns, one row selected and its linked evidence flow shown">
  <figcaption>The <strong>Issues</strong> tab: every finding you promote, each with a severity and a status, linked back to the evidence flow that proves it.</figcaption>
</figure>

From a script, file and update issues directly — `--flow` links the evidence in the same move:

```bash
gori run issues create --title "IDOR on /v1/users/{id}" --severity high --host api.example.com --flow 42
gori run issues update 7 --status confirmed --notes "Verified on staging"
gori run probe promote 12            # confirm a Probe finding into Issues
```

**Checkpoint.** The **Issues** tab shows your issue with its severity, and opening it jumps to the evidence flow.

## 3. Prove it with the Comparer

A finding lands harder with the before and after side by side — the unauthenticated `403` next to the authenticated `200`, or the patched response next to the vulnerable one. The **Comparer** holds two messages, A and B, and diffs them.

Fill the slots from wherever a request and its response live. Select the first flow in **History** and press `Space` → **Send to Comparer**; it lands in slot A. Send the second the same way to fill slot B. A Repeater send or a Fuzzer result row goes in the same way — and since neither leaves a captured flow behind, this is their only route into a diff. On the Comparer tab itself, `a` / `b` pick a captured flow straight into either slot.

The divider between the columns states the A→B delta before you read a line: a `403 → 200` is usually the whole answer. `←`/`→` switches between diffing the requests and the responses, and on a changed row only the bytes that actually differ are lit red and green, so one flipped value stands out without reading the line.

```bash
gori run compare 41 42 --pane response --changes-only
```

**Checkpoint.** The diff highlights the change that proves the finding — a status flip like `403 → 200`, or the one value that moved.

## 4. Keep notes and links

Not everything is an issue. **Notes** are free-form, per-project Markdown (multiple notes per project) — a running log of what you tried, the payload that worked, the lead to return to. Create and edit them on the **Notes** tab.

To tie the loose evidence together, press `Space` → **Link…** from History, the Repeater, the Fuzzer, or the Miner. One card lists every issue *and* every note, with `+ New issue…` / `+ New note…` pinned above them — so attaching what you are looking at to an existing issue, or filing a fresh one already linked, is the same keystroke. Whatever you type filters by title, host, or status, and becomes the new issue's title if you land on the create row.

```bash
gori run notes create --text "SSRF candidate on /fetch — needs OAST to confirm"
gori run notes --all
```

**Checkpoint.** The Notes tab holds your note, and an issue you linked lists the evidence flow or session under it.

## 5. Export the report

When the issues are triaged, export them as a single Markdown document a teammate can read without gori installed:

```bash
gori run issues --format markdown --export report.md
```

To hand over the raw traffic behind a finding — not just the write-up — export a History query as one HAR log. It writes to STDOUT, loads into Burp, Charles, or a browser's network panel, and imports straight back into gori:

```bash
gori run history -q 'host:api.example.com status:200' --format har > evidence.har
```

**Checkpoint.** `report.md` exists on disk and reads as a severity-ordered list of your issues; `evidence.har` carries the flows behind them.

## Next Steps

- [Run an AI co-pilot session](/playbooks/run-an-ai-co-pilot/): put an agent on the same project and watch every move it makes
- [Scanning & Issues](/guide/scanning/): the full reference for Probe, Issues, Notes, and the Comparer
- [CLI Reference](/reference/cli/): `run issues`, `run compare`, and `run history --format har` in full
