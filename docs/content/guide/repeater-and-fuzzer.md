+++
title = "Repeater & Fuzzer"
description = "The request workbench and the Intruder-style fuzzer, in the TUI and headless."
+++

Once you've captured an interesting flow, **Repeater** and the **Fuzzer** are where you test it.

## Repeater

Repeater is a request workbench, like a repeater. Send a flow to it, edit any part of the request, and re-send — the response, timing, and a diff against the previous response are shown side by side. Sessions persist with the project, so you can come back to them later.

<figure class="tui-shot">
  <img src="/images/tui/repeater.svg" alt="gori Repeater tab with an editable HTTP/2 request pane, a response pane showing headers and a JSON body, and a replayed 200 in 1152ms status line">
  <figcaption><strong>Repeater</strong>: an editable request on the left, the live response and timing on the right, with a diff against the previous send.</figcaption>
</figure>

Repeater handles more than HTTP/1:

- **HTTP/2** requests are re-sent over a real h2 connection.
- **WebSocket** repeater opens a handshake, then lets you send messages and watch the drained responses.
- **gRPC** repeater reuses the HTTP/2 engine for framed messages.
- A **decode** mode re-encodes edited SAML / GraphQL payloads on send. (To decode or edit a JWT, use the [Decoder](/guide/decoder/) tab's `jwt-decode`.)

Repeater from the command line, optionally against a new target:

```bash
gori run repeater <flow-id> --target https://staging.example.com --diff
```

## Environment Variables

Outbound requests support `$KEY`-style substitution. Tokens stay as literal text in the editor and expand **only at send time** — in Repeater, the Fuzzer, the Miner, Intercept forwards, `gori run`, and MCP `send_request`.

Define variables in two places (project wins on a key collision):

| Layer | Where |
|-------|-------|
| **Global** | `Ctrl-P` → **Settings: Env**, or the `env` section of `settings.json` |
| **Project** | **Project** tab → **ENV** pane (`a` add, `e` edit, `d` delete) |

Default prefix is `$` (changeable via **Change prefix** in the ENV space menu, or `env.prefix` in settings). Keys are `A–Z a–z _` followed by `A–Z a–z 0–9 _`. Unknown tokens are left unchanged.

```http
GET /api/me HTTP/1.1
Host: api.example.com
Authorization: Bearer $TOKEN
```

Values that appear in captured traffic can be masked back to `$KEY` when copying or displaying, so secrets stay as tokens rather than raw strings.

## Fuzzer

The Fuzzer is an Intruder-style engine: mark positions in a request, attach payload sets, and send the matrix of requests while matching on the responses.

<figure class="tui-shot">
  <img src="/images/tui/fuzzer.svg" alt="gori Fuzzer tab with a request template showing highlighted marker positions, a payload-set config pane, a results table of sent requests, and a distribution sidebar">
  <figcaption>The <strong>Fuzzer</strong>: <code>§…§</code> markers in the template, payload sets and mode in CONFIG, a live results table, and a status / size distribution sidebar.</figcaption>
</figure>

### Attack Modes

| Mode | Behavior |
|------|----------|
| `sniper` | One position at a time, cycling a single payload set (default) |
| `batteringram` | The same payload in every marked position |
| `pitchfork` | Parallel sets — payload *n* from each set together |
| `clusterbomb` | Every combination across all sets |

### Positions and Payloads

Mark positions with `§…§` markers in the request, or let gori place them automatically. Payload sets can be a wordlist, an explicit list, a numeric range, N empty (null) payloads, or brute-force character sets. Processors let you transform each payload on the way out — prefix/suffix, URL/base64/hex encoding, case folding, hashing, or a regex replace.

### Matching

Filter results with ffuf-style matchers and filters on status, size, words, lines, and body regex — plus auto-calibration to drop noisy baselines. Matched responses are highlighted and can be extracted with a capture regex.

### Running Headless

```bash
gori run fuzz <flow-id> \
  --auto \
  --wordlist params.txt \
  --mode sniper \
  --mc 200,302 \
  --fs 0
```

Sources can be a captured flow (`--flow`), a raw request file (`--request`), or stdin. Output is `text`, `json`, or `jsonl`.

## Next Steps

- [Decoder](/guide/decoder/) — local encode/decode/hash chains
- [Scanning & Issues](/guide/scanning/) — Probe and the Param Miner
- [CLI Reference](/reference/cli/) — every `run` flag
- [MCP Server](/guide/mcp/) — drive fuzzing from an agent
