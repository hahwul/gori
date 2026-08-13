+++
title = "Fuzz a parameter"
description = "Mark one part of a captured request, throw a wordlist at it, and read the responses that stand out."
weight = 40

[extra]
group = "The manual loop"
+++

You have a captured request with a parameter worth pushing on. This playbook marks one value in it, throws a payload set at that single spot, and reads the responses for the one that behaves differently — the whole Intruder-style loop, in the TUI and headless. Budget about ten minutes.

> **Before you begin.** [Set up an engagement](/playbooks/set-up-an-engagement/) first, so your target is scoped — the Fuzzer refuses an out-of-scope host with `SCOPE_BLOCKED`. Have one captured flow in **History** that carries a parameter: a query key, a JSON field, a header. Only fuzz a target you are authorized to test; the examples use `api.example.com` as a stand-in.

## 1. Send a request to the Fuzzer

Everything starts from a real captured request, so you fuzz the exact bytes the app sent rather than a hand-typed approximation. In **History**, select the flow that carries the parameter and press `Shift-I`. gori copies it into the **Fuzzer** tab and switches you there — the same move as `Ctrl-R` to Repeater, one tab further along. Headless, the flow id is the source:

```bash
gori run fuzz <flow-id>
```

A source can also be a raw request file (`--request`) or stdin, but a captured flow keeps the run inside your project scope for free.

**Checkpoint.** The **Fuzzer** tab holds a copy of the request as its template, unchanged until you mark it.

## 2. Mark a position

The Fuzzer sends the template verbatim except where you mark a position. Wrap the value to vary in `§…§` markers: put the cursor on it and press `Ctrl-A` to auto-mark the common params (query keys, form and JSON fields), or type the markers by hand around anything else — a header value, a path segment.

How markers and payloads combine is the **mode**, set in CONFIG:

| Mode | Behavior |
|------|----------|
| `sniper` | One position at a time, cycling a single payload set (default) |
| `batteringram` | The same payload in every marked position |
| `pitchfork` | Parallel sets: payload *n* from each set together |
| `clusterbomb` | Every combination across all sets |

For a single position, `sniper` is the one you want; the other three only earn their keep once you mark more than one spot. Headless, positions come from the `§…§` markers in the request, `--auto` to place them for you, or `--mark=TOKEN`, and the mode is a flag:

```bash
gori run fuzz <flow-id> --auto --mode sniper
```

**Checkpoint.** Exactly one value is wrapped in `§…§` (or highlighted after `Ctrl-A`), and the mode reads `sniper`.

## 3. Attach payloads

A payload set is what gets substituted into the marker. Start with a built-in preset (`sqli`, `xss`, `traversal`, `format-string`, `bad-strings`, `command-injection`) for a fast first pass with no file, or point at a wordlist, an explicit list, a numeric range, or a brute-force character set.

One thing to know before you run: **gori does not URL-encode payloads by default.** Raw bytes go on the wire as written, so a payload carrying a raw space in a query string corrupts the request line unless you add a processor. Processors transform each payload on the way out — prefix/suffix, URL/base64/hex encoding, case folding, hashing, or a regex replace. Put the cursor inside a marker and press `Ctrl-Y` to open its processor chain, which previews the value through every step before a single request goes out.

```bash
gori run fuzz <flow-id> --auto --mode sniper --wordlist params.txt --encode url
```

**Checkpoint.** CONFIG lists your payload set, and `Ctrl-Y` shows each payload as it will actually leave — encoded if you added an encoder, raw if you did not.

## 4. Set a matcher and run

A matcher decides which responses are worth your attention, so the results table surfaces signal instead of every reply. Filter on status, size, words, lines, or a body regex — ffuf-style — and turn on **auto-calibration** so a noisy baseline (a soft 404, a catch-all 200) doesn't drown the real hits. Press `Ctrl-R` to run.

Headless, the matcher flags are `--mc`/`--fc` (status), `--ms`/`--fs` (size), `--mw`/`--fw` (words), `--ml`/`--fl` (lines), `--mr`/`--fr` (body regex), and `--ac` to auto-calibrate:

```bash
gori run fuzz <flow-id> \
  --auto \
  --wordlist params.txt \
  --mode sniper \
  --mc 200,302 \
  --fs 0 \
  --ac
```

<figure class="tui-shot">
  <img src="/images/tui/fuzzer.svg" alt="gori Fuzzer tab: a captured request template with one value wrapped in marker highlights, the payload set and attack mode in the CONFIG pane, a filling results table, and a status and size distribution sidebar">
  <figcaption>The <strong>Fuzzer</strong>: one marked position in the template, a payload set and <code>sniper</code> mode in the CONFIG pane, and the results table filling as each request lands.</figcaption>
</figure>

**Checkpoint.** The results table fills as requests land; sort it by status or size to bring the outliers to the top.

## 5. Read results and seed the next step

The finding is the row that doesn't match its neighbours — an unexpected `200` or `500` where the rest `404`, or a length that jumps when one payload lands differently. That row is a lead, not a conclusion: from a result, its `Space` menu sends it on to the **Repeater**, or to the **Comparer** to diff it against the baseline, so you keep probing the one payload that stood out by hand.

Hidden parameters the app never named at all are a different job. Where the Fuzzer varies a value you can see, the **Miner** guesses candidate names the server accepts but doesn't advertise — see [Param Miner](/guide/scanning/#param-miner).

## Next Steps

- [Carry a session](/playbooks/carry-a-session/): replay every later request as a logged-in user
- [Fuzzer reference](/guide/repeater-and-fuzzer/#fuzzer): attack modes, payload sets, and matchers in full
- [Param Miner](/guide/scanning/#param-miner): find the parameters the app never named
