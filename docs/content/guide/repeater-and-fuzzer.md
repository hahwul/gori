+++
title = "Repeater & Fuzzer"
description = "The request workbench and the Intruder-style fuzzer, in the TUI and headless."
weight = 20

[extra]
group = "Core"
+++

Once you've captured an interesting flow, **Repeater** and the **Fuzzer** are where you test it.

## Repeater

Repeater is a request workbench. Send a flow to it, edit any part of the request, and re-send. The response, timing, and a diff against the previous response are shown side by side. Sessions persist with the project, so you can come back to them later.

Once a few dozen have piled up, the chip strip scrolls and hunting along it with `←`/`→` stops being practical. At the strip's left edge sits **`⌕ N`**, where `N` is how many sessions are open: press `←` from the first chip to reach it (or click it) and `Enter` lists every session, filtered as you type by name, method, path, target host or `#tag`. `Enter` jumps to the one you picked. Every workbench strip has it — Fuzzer, Notes, Decoder, JWT, Comparer, Miner and Sequencer alike.

<figure class="tui-shot">
  <img src="/images/tui/repeater.svg" alt="gori Repeater tab with an editable HTTP/2 request pane, a response pane showing headers and a JSON body, and a replayed 200 in 1152ms status line">
  <figcaption><strong>Repeater</strong>: an editable request on the left, the live response and timing on the right, with a diff against the previous send.</figcaption>
</figure>

Repeater handles more than HTTP/1:

- **HTTP/2** requests are re-sent over a real h2 connection.
- **WebSocket** repeater opens a handshake, then lets you send messages and watch the drained responses.
- **gRPC** repeater reuses the HTTP/2 engine for framed messages.
- A **decode** mode re-encodes edited SAML / GraphQL payloads on send. (To decode or edit a JWT, use the [Decoder](/guide/decoder/) tab's `jwt-decode`.)

Replay from the command line, optionally against a new target:

```bash
gori run repeater <flow-id> --target https://staging.example.com --diff
```

## Environment Variables

Outbound requests support `$KEY`-style substitution. Tokens stay as literal text in the editor and expand only at send time: in Repeater, the Fuzzer, the Miner, Intercept forwards, `gori run`, and MCP `send_request`.

Define variables in two places (project wins on a key collision):

| Layer | Where |
|-------|-------|
| **Global** | Preferences (`Ctrl-,`) → **Editor & Keys** → **Env**, `Ctrl-P` → **Settings: Env**, or the `env` section of `settings.json` |
| **Project** | **Project** tab → **ENV** pane (`a` add, `e` edit, `d` delete) |

Default prefix is `$` (changeable via **Change prefix** in the ENV space menu, or `env.prefix` in settings). Keys are `A-Z a-z _` followed by `A-Z a-z 0-9 _`.

An unknown token stays visible as literal text wherever a request is *shown*. The editor keeps what you typed, and the highlighter marks an unregistered token differently from a registered one. It is not sent, though: Repeater, the Fuzzer, the Miner, the Sequencer and Discover each refuse a run whose request line, headers or target still name a variable that resolves to nothing, and say which one — as do minimize, an intercept forward you edited, and a WebSocket message. Set it, or drop the token. The check covers the request head only. A `$` inside a body is treated as a byte, so binary uploads replay unchanged. A WebSocket **text** message has no head, so the whole payload is checked; a **binary** message is never checked, and never expanded.

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
| `pitchfork` | Parallel sets: payload *n* from each set together |
| `clusterbomb` | Every combination across all sets |

### Positions and Payloads

Mark positions with `§…§` markers in the request, or let gori place them automatically. Payload sets can be a built-in preset (`sqli`, `xss`, `traversal`, `format-string`, `bad-strings`, `command-injection`) for a fast start with no file, a wordlist, an explicit list, a numeric range, N empty (null) payloads, or brute-force character sets. A preset can merge an extra file (built-in first, de-duped), and composes with any other set. Processors let you transform each payload on the way out: prefix/suffix, URL/base64/hex encoding, case folding, hashing, or a regex replace.

A single marker can also carry a Decoder chain of its own. Put the cursor inside it and press `Ctrl-Y` to open the chain editor, which previews the value through every step before you send. Anything you [saved in the Decoder library](/guide/decoder/#building-a-chain) can be called there by name, so a chain you built once is one word in a marker: `§admin¦myenc > url-encode§`. Repeater markers work the same way.

### Matching

Filter results with ffuf-style matchers and filters on status, size, words, lines, and body regex, plus auto-calibration to drop noisy baselines. Matched responses are highlighted and can be extracted with a capture regex.

### Connection Reuse

A sweep reuses one HTTP/1.1 connection across many requests, so a run pays one TCP — and, on `https`, one TLS — handshake per worker instead of one per request. Against a remote origin that is usually the largest single cost of a run.

Requests gori cannot prove unambiguous never share a socket, whatever the setting: a `Content-Length` that does not match the body on the wire, `CL`+`TE`, an obfuscated framing header, `Connection: close`, or `Upgrade` each get their own connection, so a smuggling payload can never misframe the next payload's result. Turn reuse off entirely with `--no-keep-alive` (CLI), `keep_alive: false` (MCP), or the **Keep-alive** toggle in the Fuzzer's ADVANCED overlay when the target's behaviour is per-connection — a connection-scoped rate limit, a load balancer pinning by connection — or when keep-alive handling is itself what you are testing.

`gori run fuzz` reports what the run actually paid: `connections · 50 dialed · 2950 reused`.

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

- [Decoder](/guide/decoder/): local encode/decode/hash chains
- [Scanning & Issues](/guide/scanning/): Probe and the Param Miner
- [CLI Reference](/reference/cli/): every `run` flag
- [MCP Server](/guide/mcp/): drive fuzzing from an agent
