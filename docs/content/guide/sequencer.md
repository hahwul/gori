+++
title = "Sequencer"
description = "Grade the randomness of session tokens, CSRF tokens, and reset codes for predictability."
weight = 60

[extra]
group = "Workbenches"
+++

If a session cookie, CSRF token, password-reset code, or API key is predictable, an attacker can forge or guess it. The **Sequencer** collects a sample of tokens and grades how random they really are, the gori counterpart of Burp Sequencer or the Caido Sequencer.

<figure class="tui-shot">
  <img src="/images/tui/sequencer.svg" alt="gori Send to Sequencer config card over the History tab, showing an auto-detected session cookie as the token, a sample count of 500, and concurrency 1">
  <figcaption>Sending a captured flow to the <strong>Sequencer</strong> auto-detects the session cookie and lets you set the sample size and concurrency before collecting.</figcaption>
</figure>

The **Sequencer** tab is hidden by default. Reveal it from the tab-bar `⋯` menu or the command palette (`Ctrl-P` → **Go to Sequencer**).

## Two Ways to Feed It

**Live.** Point it at a request that hands out a fresh token, and gori replays that request many times, pulling the token out of each response. From **History**, select the flow that sets the token and `Space` → **Send to Sequencer**; gori auto-detects the likely session cookie. Tune the token location and sample size with `c` (reconfigure), then `Ctrl-R` to collect and `Ctrl-X` to stop.

**Manual.** Already have a list of tokens? Paste them (one per line) for a pure statistical analysis with no network traffic.

Extract the token from any of these locations:

| Location | Extracts |
|----------|----------|
| Cookie | A `Set-Cookie` value by name |
| Header | A response header value |
| Regex | Capture group 1 of a body regex |
| Position | A fixed byte range of the body (`A:B`) |
| JSONPath | A value at a JSON body path (`$.data.token`) |

Live collection defaults to **concurrency 1**, because session tokens are often stateful (each request advances a server-side counter). Raise it only when the endpoint is stateless.

## Reading the Grade

The headline is **effective entropy** in bits: a conservative estimate of how much real unpredictability each token carries, measured across the sample. The rating follows from it:

| Rating | Effective entropy |
|--------|-------------------|
| **Secure** | >= 88 bits |
| **Moderate** | >= 60 bits |
| **Weak** | >= 30 bits |
| **Critical** | below 30 bits |

Any **duplicate** or **sequential** token drops the verdict straight to Critical, however high the entropy looks. Underneath, gori runs a battery of statistical tests over the token's symbol bitstream (monobit, poker, runs, longest-run, per-bit bias, cumulative sums, approximate entropy, and a spectral test), a chi-square on byte frequencies, a lag-1 serial correlation, and a compression check against the alphabet's entropy floor. The tests judged on a p-value share a Bonferroni-corrected threshold, so a clean token is no likelier to be flagged as the battery grows.

A small sample (fewer than ~20 usable tokens) softens hard failures to warnings and caps the rating, since there isn't enough data to be sure.

### Structure Is Not Secret

Real tokens usually carry a skeleton: a `sess_v1_` prefix, a version byte, base64 padding. The **Structure** row reports how many positions never vary across the sample, and every byte-level test then measures the *varying* region only.

That distinction decides the grade. A token of `sess_v1_` plus 24 random hex characters looks like a 19-character alphabet if you count the prefix, which is not a power of two, which switches off the entire bit-test battery as not-applicable; chi-square and compression then fail on a distribution skewed purely by the prefix. Measured against the varying region instead, the same sample is what it actually is: lower-hex, full battery active, every row passing.

For a token whose random part is a *suffix* behind a variable-length head (`123-<random>`), gori anchors the per-position window to whichever end carries more entropy, so the head does not drag the estimate down.

The panes are **CONFIG** (source and token location), **SAMPLES** (the collected tokens), and **ANALYSIS** (the grade and the per-test breakdown), with a detail view for any one sample.

## Getting the Verdict Out

Collected tokens are live credentials, so they are never written to disk and vanish with the session. The verdict should not.

| Action | Key | Writes |
|--------|-----|--------|
| Export report | `⇧E` | A Markdown report at a path you choose |
| Export report (JSON) | palette | The same report as JSON |
| File as issue | `Space` → `i` | An Issue in the Issues tab |

**File as issue** records the grade in the Issues report, mapping Critical to `critical`, Weak to `high`, Moderate to `medium`, and Secure to `info`. The Issue carries the target, the token descriptor, the entropy figures, and the full test table as its body, plus the seeding flow as evidence. Neither the export nor the Issue contains a token value: the report is built from frequency tables and verdicts, so there is no sample in it to leak.

## Headless

```bash
# Live: replay flow 42, extract the SESSIONID cookie, collect 500 tokens
gori run sequence 42 --cookie SESSIONID --count 500

# Manual: analyze tokens you already have (no network)
gori run sequence --tokens tokens.txt
cat tokens.txt | gori run sequence --tokens -
```

Pick exactly one token location (`--cookie` / `--header` / `--regex` / `--position` / `--jsonpath`), and source the request from `--flow`, `--request FILE`, or stdin. Rate and transport flags mirror the Fuzzer (`--concurrency`, `--rate`, `--throttle`, `--timeout`, `--target`, `--http2`, …). Output is `text`, `json`, `jsonl`, or `markdown` (the same document the TUI's **Export report** writes). Full flags are in the [CLI Reference](/reference/cli/#run-sequence).

Over MCP, `sequence_analyze` grades a token list inline, and `sequence_start` / `sequence_status` / `sequence_results` / `sequence_stop` drive a live collection as a background job. Results return the **report**, never the raw tokens.

## Next Steps

- [Repeater & Fuzzer](/guide/repeater-and-fuzzer/): capture the request that mints a token
- [JWT](/guide/jwt/): if the token is a JWT, decode and attack it instead
- [MCP Server](/guide/mcp/): grade tokens from an agent
