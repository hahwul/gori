+++
title = "Replay & Fuzzer"
description = "The request workbench and the Intruder-style fuzzer, in the TUI and headless."
+++

Once you've captured an interesting flow, **Replay** and the **Fuzzer** are where you test it.

## Replay

Replay is a request workbench, like a repeater. Send a flow to it, edit any part of the request, and re-send — the response, timing, and a diff against the previous response are shown side by side. Sessions persist with the project, so you can come back to them later.

Replay handles more than HTTP/1:

- **HTTP/2** requests are re-sent over a real h2 connection.
- **WebSocket** replay opens a handshake, then lets you send messages and watch the drained responses.
- **gRPC** replay reuses the HTTP/2 engine for framed messages.
- A **decode** mode re-encodes edited JWT / SAML / GraphQL payloads on send.

Replay from the command line, optionally against a new target:

```bash
gori run replay <flow-id> --target https://staging.example.com --diff
```

## Fuzzer

The Fuzzer is an Intruder-style engine: mark positions in a request, attach payload sets, and send the matrix of requests while matching on the responses.

### Attack Modes

| Mode | Behavior |
|------|----------|
| `sniper` | One position at a time, cycling a single payload set (default) |
| `batteringram` | The same payload in every marked position |
| `pitchfork` | Parallel sets — payload *n* from each set together |
| `clusterbomb` | Every combination across all sets |

### Positions and Payloads

Mark positions with `§…§` markers in the request, or let gori place them automatically. Payload sets can be a wordlist, an explicit list, a numeric range, null bytes, or brute-force character sets. Processors let you transform each payload on the way out — prefix/suffix, URL/base64/hex encoding, case folding, hashing, or a regex replace.

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

- [Scanning & Findings](/guide/scanning/) — Prism and the Param Miner
- [CLI Reference](/reference/cli/) — every `run` flag
- [MCP Server](/guide/mcp/) — drive fuzzing from an agent
