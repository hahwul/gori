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

Once a few dozen have piled up, the chip strip scrolls and hunting along it with `←`/`→` stops being practical. Press **`f`** anywhere on the strip and every session is listed, filtered as you type by name, method, path, target host or `#tag`; `Enter` jumps to the one you picked. The same list sits behind the **`⌕`** at the strip's left edge — click it, or reach it with `←` from the first chip. Every workbench strip has both — Fuzzer, Notes, Decoder, JWT, Comparer, Miner and Sequencer alike.

Sub-tabs can also be **marked** for a batch. On the strip, `t` marks the chip under you and steps right, `Shift-T` marks every chip the `/` filter shows, and `Esc` clears the marks before it leaves the strip. A marked chip wears a `▌` bar. Marks change **what the sub-tab actions act on**, not which actions exist — the rule History's list already follows:

> the target is **the marks if any are set, else the active chip**

So `Shift-T` → `Ctrl-W` closes every open session behind one confirm, `Ctrl-R` sends the marked ones together (each on its own connection, up to 20, after a confirm), `Space` → `d` duplicates them, and `Space` → `t` tags them all with what you type. The space menu opened from the strip reads `SPACE · 3 MARKED` and its entries rename themselves (`Close 3 sub-tabs`, `Send 3 sub-tabs`); an action that stays single-target says `(cursor)`. A mark the filter is hiding is called out in the confirm rather than closed quietly. Every workbench strip marks, closes and duplicates this way — Fuzzer, Notes, Decoder, JWT, Cookie, Comparer, Miner and Sequencer alike; sending is Repeater's.

<figure class="tui-shot">
  <img src="/images/tui/repeater.svg" alt="gori Repeater tab with an editable HTTP/2 request pane, a response pane showing headers and a JSON body, and a replayed 200 in 1152ms status line">
  <figcaption><strong>Repeater</strong>: an editable request on the left, the live response and timing on the right, with a diff against the previous send.</figcaption>
</figure>

Repeater handles more than HTTP/1:

- **HTTP/2** requests are re-sent over a real h2 connection.
- **WebSocket** repeater opens a handshake, then replays your messages **one at a time**: each one goes out, the server's answer is drained until the socket falls quiet, and only then does the next leave.
- **gRPC** repeater reuses the HTTP/2 engine for framed messages. A unary call (exactly one framed message) exposes its payload for hex editing with `^X` — and, when a descriptor set declares the rpc, for FIELD editing with `␣E`: pick a schema-known field, type a value, and the message is re-encoded around it with every other byte copied from the capture ([`.proto` as a lens](/guide/proxy/#proto-schema)). A 0- or multi-message body is re-sent verbatim. The 5-byte length prefix in front of the message is governed by the `␣F:FRAME` toggle on the request card — **on** by default in the tab, so an edited unary message goes out well-formed and the origin accepts the call. Turn it **off** to send the captured prefix in front of your edited payload, because a prefix that disagrees with its payload is one of the standard gRPC parser tests. Headless the default is the other way round: `gori run repeater send` (MCP `send_request`) sends the prefix as captured unless you pass `--reframe-grpc` / `reframe_grpc: true`.
- A **decode** mode re-encodes edited SAML / GraphQL payloads on send. (To decode or edit a JWT, use the [Decoder](/guide/decoder/) tab's `jwt-decode`.)

That one-at-a-time order is the point on WebSocket. A socket carries a conversation, so a script whose third message depends on the answer to the second only replays faithfully if gori waits in between — and the transcript then reads in wire order, instead of listing everything you sent ahead of everything the server said. Three things follow from it:

- **A run costs at least one quiet gap per message** (three seconds of server silence, by default). A long script against a server that answers nothing is the slow case.
- **gori stops when the peer does.** If the server sends a `CLOSE`, or the connection ends, the rest of your script is *not* written into a socket nobody is reading — RFC 6455 forbids data frames after a `CLOSE` anyway. The result says how many of your messages actually went out.
- **A `CLOSE` *you* wrote does not stop it.** Sending data after your own `CLOSE` is a protocol test, and Repeater lets you run it — as it does an unmasked frame, a lone continuation, or a length header that disagrees with its payload.

The WebSocket Repeater does not negotiate `permessage-deflate`, and the capture proxy disables it by default. A Match & Replace head rule can deliberately restore the extension offer; a session captured that way holds the extension-encoded bytes and cannot be replayed. Re-capture it without that rule (or with compression disabled in the client).

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
| ------ | ---------- |
| `sniper` | One position at a time, cycling a single payload set (default) |
| `batteringram` | The same payload in every marked position |
| `pitchfork` | Parallel sets: payload *n* from each set together |
| `clusterbomb` | Every combination across all sets |

### Positions and Payloads

Mark positions with `§…§` markers in the request, or let gori place them automatically. Payload sets can be a built-in preset (`sqli`, `xss`, `traversal`, `format-string`, `bad-strings`, `command-injection`) for a fast start with no file, a wordlist, an explicit list, a numeric range, N empty (null) payloads, or brute-force character sets. A preset can merge an extra file (built-in first, de-duped), and composes with any other set. Processors let you transform each payload on the way out: prefix/suffix, URL/base64/hex encoding, case folding, hashing, or a regex replace.

A gRPC message is the one place a marker cannot go usefully — see [Sweeping a gRPC Field](#sweeping-a-grpc-field), where the position is a schema-known field rather than a byte range.

A single marker can also carry a Decoder chain of its own. Put the cursor inside it and press `Ctrl-Y` to open the chain editor, which previews the value through every step before you send. Anything you [saved in the Decoder library](/guide/decoder/#building-a-chain) can be called there by name, so a chain you built once is one word in a marker: `§admin¦myenc > url-encode§`. Repeater markers work the same way.

### Matching

Filter results with ffuf-style matchers and filters on status, size, words, lines, round-trip time (`--mt`/`--ft`, in ms — the dimension a time-based blind payload is the only evidence for), and body regex, plus auto-calibration to drop noisy baselines. Auto-calibration samples the target several times before the sweep and compares each response against every sampled shape, widened by the jitter those samples themselves showed — so a page carrying a per-request id or timestamp calibrates out, while a target whose samples were identical is still compared exactly. Matched responses are highlighted and can be extracted with a capture regex.

### Saving and Reopening Runs

During a TUI run, gori writes every result to a private temporary SQLite spool while the pane keeps a bounded display window: at most 5,000 rows and 64 MiB of dynamic result data. The newest rows remain interactive; an individually oversized row is shown as metrics only. If even its payload/error text exceeds the window, the display truncates and labels those fields and disables Send to Repeater/Comparer rather than reconstructing a request from placeholders. The spool still holds the complete row. It is owner-only, cleaned in small background transactions when a run is discarded, removed wholesale when the project closes, and a spool failure never stops outbound traffic—it only makes that run unavailable for permanent saving.

After a non-empty run finishes and its spool is complete, press **`Shift-S` in READ mode** to save every spooled row permanently in the project. An uppercase `S` still types normally while you are editing. Saving uses row- and byte-bounded background batches, and the status line and Jobs panel report success or failure. Repeating the shortcut does not create a duplicate; a failed project copy retains its temporary spool for retry.

Reopening a project restores the latest successfully saved run for its initially selected Fuzzer session. Other Fuzzer sessions restore lazily on first selection. Restore reads only the newest 5,000 rows / 64 MiB into the pane and labels it `showing N`; the complete archive remains available through paged CLI/MCP readers. Active, partially failed, and legacy incomplete snapshots are never restored automatically. Open **Space → Run history** to choose an older current-format run; `Enter` loads it and `d` deletes it. Closing the Fuzzer session deletes its saved-run history too; the close confirmation says so.

The headless and agent surfaces use the same permanent store:

```bash
gori run fuzz save 42 --auto --preset sqli
gori run fuzz list
gori run fuzz show RUN_ID
gori run fuzz show RUN_ID RESULT_INDEX --format json
gori run fuzz delete RUN_ID --yes
```

The ordinary `gori run fuzz …` command remains ephemeral. Over MCP, pass `save_results: true` to `fuzz_start`, then use `list_fuzz_runs`, `get_fuzz_run`, and `delete_fuzz_run`. Permanent runs are separate from History flows: `--record-history` / `record_history` still controls whether individual sends also appear in History.

### Framing a Sweep

`Content-Length` is recomputed after every payload is spliced in, and one is **added** when the template carries a body but declares no length at all, so an ordinary sweep stays self-consistent; `--verbatim` (MCP `update_content_length: false`, or turning off **Auto Content-Length** on the Fuzzer's ADVANCED card) turns both halves off, because a length that disagrees with the body is the whole point of a CL / CL-TE desync test.

That second half matters more than it sounds: an HTTP/1.1 request body has no close-delimited form, so a body with neither `Content-Length` nor a chunked `Transfer-Encoding` is read by the origin as a **zero-length body** — the payloads go out unread while every row still reports a status. When `--verbatim` leaves a template in exactly that shape, gori says so before the first send rather than letting the run go quiet.

A gRPC template carries a second length declaration — the 5-byte prefix in front of each message — and it gets the opposite default: gori leaves it exactly as the payload left it, and says so once at the end of the run (`2 of 3 requests left it stale`, `grpc_stale_prefix` in MCP `fuzz_status`). That is the right answer when a deliberately-wrong prefix is what you are testing, and the wrong one when you are sweeping an ordinary unary call and every request is being rejected at the framing layer. `--reframe-grpc` (MCP `reframe_grpc: true`, or the **gRPC reframe (unary)** toggle on the Fuzzer's ADVANCED card) recomputes it per request. It is off by default on all three surfaces, and it only touches a single message: a client-streaming body, a `grpc-web-text` body, and a seed whose framing was already broken are left alone and still reported.

### Sweeping a gRPC Field

Marking bytes inside a protobuf message is not something an operator can usefully do: the
value of an `int32` field is the octets of a varint, and `§…§` around them is a test of the
wire format rather than of the field. So a gRPC field position is **named**, not marked —
`--field role`, the MCP `fields` argument, or the **gRPC field(s)** row on the Fuzzer's
ADVANCED card:

```
gori run fuzz --flow 42 --field role --payloads ROLE_ADMIN,ROLE_USER,99
```

`SPEC` is a field name, a path into a nested message (`profile.age`), a field number, or
`tags[1]` for one occurrence of a repeated field. It needs a descriptor set that resolves the
rpc — a `protoc --descriptor_set_out` file or a `gori run grpc reflect` fetch; the field names
are the ones the Repeater's `␣E:FIELDS` form and the History protobuf tree already show for
the same flow.

Two things follow from what a splice can do. The field has to be **present on the captured
message** — gori replaces an occurrence, it never adds one — so a proto3 field left at its
default is absent from the wire and is not a position; the refusal lists what the message does
carry. And a payload for a **`bytes`** field is read as **hex** (`de ad be ef`), because that
declaration's value is binary and a text field would silently send the UTF-8 of what you typed
instead of the octets you meant.

Each payload goes **through the declaration** on its way to bytes, which is the whole reason
the schema is needed: `-3` is ten sign-extended octets as `int32`, one zigzagged octet as
`sint32`, and something else again as a `bool` or an enum. Everything outside the fuzzed field
is copied from the capture rather than re-serialized — an undeclared field number, a group, a
non-minimal varint, the unparsed tail of a truncated capture — and the 5-byte length prefix is
recomputed to describe the message that is actually going out.

A `¦chain` on a field position, and `--encode`/`--prefix`/`--hash` and the rest of the
processor pipeline, transform the **text** before the declared type encodes it. So
`--field name¦base64-encode` sends the base64 of the payload *as that string field*; the same
chain on an `int32` field is refused up front, because base64 text is not an integer. (Use the
steps' `|` or `>` separators inside a chain on the TUI row — the comma there separates fields.)

Three things are refused before the first request rather than discovered mid-sweep: a field the
schema does not declare, a field whose wire type the declaration contradicts (both of which the
Repeater's form renders read-only for the same reason — `^X` is still the way to change those
octets), and a payload the declared type cannot hold.

One combination is *reported* rather than refused: `--verbatim` leaves `Content-Length` at the
capture's value, and a re-encoded message is a different size — so every request declares the
wrong body length and is rejected at the HTTP framing layer before the gRPC layer is reached.
That is the same argument this feature makes for rebuilding the 5-byte prefix, pointed at the
other length declaration, and a CL desync is a real test, so the run says so and proceeds.

### Fuzzing a WebSocket

A WebSocket session is swept like any other target, with one difference that follows from the protocol: **one payload is one whole session**. gori dials, does the RFC 6455 handshake, sends your frame script with the payload spliced in, drains the origin's answer and closes — then does it again for the next payload. A socket is a conversation, not a request/response pair, so nothing else would attribute an answer to the payload that provoked it. Concurrency therefore means that many simultaneous sockets.

Mark `§…§` positions **in the frames**, which is where a WebSocket app's parameters live:

```bash
gori run fuzz --repeater 7 \
  --message '{"op":"login","user":"§admin§"}' \
  --payloads-preset sqli
```

`--repeater N` on a WebSocket session seeds the handshake **and** the frames the session stored, so a captured exchange is swept as it was recorded; `--flow N` does the same from a captured socket. `--message` / `--message-frame` replace those frames when you want to author your own — `--message-frame` takes the same `opcode=…,fin=…,rsv=…,mask=…,len=…,hex=|b64=|text=` grammar as `gori run repeater send`, so a PING, a CLOSE with a chosen code, an unmasked client frame or a length that disagrees with its payload are all reachable. `--idle-ms` sets the per-session silence timeout and `--ws-keep-key` sends the template's own `Sec-WebSocket-Key` so an absent or malformed key can itself be the test.

The **handshake is a position space too**: mark a header or a query value in the upgrade and it sweeps alongside the frames, in one run. And `--ws-http-only` goes the other way — it sends the handshake as an ordinary request and reads the 101 as a response, which is how you test an origin that answers 200 to an upgrade.

Results read like any other sweep, because the inbound frames **are** the response body: `--mr`, `--mh`, `--extract`, size and word matching all work unchanged. Two extra fields carry what the handshake's status cannot, since a successful upgrade is `101` on every row whether the origin liked the payload or not:

```
#1     bob                       101   30B   1w   1.4ms  ws 1 frame · close 1000
#2     admin'--                  101   31B   5w   1.5ms  ws 1 frame · close 1008
```

`ws_close_code` and `ws_frames_in` appear in `--format json` and in MCP `fuzz_results` the same way, and only on WebSocket rows.

Four knobs do not apply. `--race` and `--http2` are refused outright — a race group is byte-identical copies of one request, and gori re-establishes a socket with an HTTP/1.1 upgrade (RFC 8441 extended CONNECT has no send path) — and so is `--record-history`, because a framed exchange is not a request/response flow and writing one would produce a History entry that claims to be a WebSocket with an empty transcript. `--follow-redirects`, `--timeout` and `--ac` are simply inert here and the run says so once, up front, rather than pretending otherwise. Each refusal names `--ws-http-only` where that is the way to get what you asked for — under that flag the run is an ordinary HTTP sweep, so all three work, recording included. A WebSocket seed that carries no outbound frames is swept as plain HTTP too: a handshake-only “framed” run would dial a socket per payload just to send nothing.

### Connection Reuse

A sweep reuses one connection across many requests, so a run pays one TCP — and, on `https`, one TLS — handshake per worker instead of one per request. Against a remote origin that is usually the largest single cost of a run.

**HTTP/2 too.** An h2 sweep reuses a connection serially — stream 1, then 3, then 5 — rather than dialing one per payload. It matters more than it sounds, because h2 is not something you usually turn on by hand: a sweep seeded from a captured h2 flow (`⇧I` from History, `gori run fuzz <flow-id>`) selects it for itself, which is most captured traffic from a modern target. Measured on loopback, where the round trip is ~0 and the win is therefore understated: 2000 requests over h2+TLS went 1.56s to 0.08s, and 2000 handshakes to 50.

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

Sources can be a captured flow (`--flow`), a saved HTTP repeater session (`--repeater`), a raw request file (`--request`), or stdin. Output is `text`, `json`, or `jsonl`. This form is ephemeral and backward-compatible; put the exact same arguments after `gori run fuzz save` to retain every row permanently. `fuzz list`, `fuzz show`, and `fuzz delete` manage those saved runs.

**A Repeater send from the TUI is recorded in History.** The tester driving a request by hand is the one whose evidence went missing, and a send that leaves no flow cannot be compared, exported or handed over; the status line names the id it wrote (`sent → 200 in 391ms · History #84`). Settings → General → *Record Repeater sends* turns it off. WebSocket sends and send-groups are not recorded — a socket's evidence is its frame transcript, which the session already keeps — and the status line says so once.

Everything else stays opt-in, and the headless surfaces keep their own per-call arguments so no script's behaviour moves under the setting: `gori run repeater send --record-history` writes the send as a flow and prints its id (off by default); `gori run fuzz --record-history=none|matched|all` records each sent request+response (`matched` only the rows that matched, `all` every send, capped at 5000); MCP `send_request` records unless you pass `record_history:false`.

Every recorded flow says where it came from — the History **SRC** column, and `src:repeater` /
`src:fuzzer` / `src:gori` in a query — so a resend is never read back as traffic the target's
client produced. See [Where a flow came from](/guide/proxy/#flow-source).

A recorded flow — from either tool — is the request **as it went on the wire**: the active session slot's header overlay and any `$NAME` the send seam resolved are part of it, so replaying, comparing or scanning that flow reproduces the send rather than the draft or template it was assembled from. (A Fuzzer *row* still shows the rendered template, which is what "send to Repeater" seeds a tab from — the slot applies per send.)

## Next Steps

- [Decoder](/guide/decoder/): local encode/decode/hash chains
- [Scanning & Issues](/guide/scanning/): Probe and the Param Miner
- [CLI Reference](/reference/cli/): every `run` flag
- [MCP Server](/guide/mcp/): drive fuzzing from an agent
