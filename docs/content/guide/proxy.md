+++
title = "Proxy & History"
description = "Capture traffic, intercept requests, scope your target, and inspect every protocol."
weight = 10

[extra]
group = "Core"
+++

The proxy sits between your client and the upstream server, records each exchange as a *flow*, and stores it in the current project. **History** is where you read those flows back.

## Capturing Traffic

Start gori and point your client at `127.0.0.1:8070` (see the [Quick Start](/getting-started/quick-start/)). Toggle capture at any time with `c`. Turning it off lets traffic pass through without being recorded, which is handy while you set up.

Once a client is pointed at the proxy, `http://gori.proxy/` serves gori's info page and CA download. It is a reserved name answered locally, so it never reaches the network — useful on a phone, where the proxy usually gets configured before the certificate. A client with no proxy configured gets the same page by browsing to the listen address directly.

Each flow records the full request and response: start line, headers, and body (the stored body is capped at 2 MiB; larger bodies still forward byte-exact and report their true size). Bodies compressed with gzip, deflate, Brotli, or Zstd are decoded for display.

> **HTTPS & upstream verification.** For HTTPS, gori verifies the origin server's certificate against your system CA trust store, resolved automatically from standard locations (and honouring `SSL_CERT_FILE` / `SSL_CERT_DIR`). If none is found — e.g. a minimal container — verification fails and those flows are recorded as errors; set `SSL_CERT_FILE=/path/to/ca-bundle.crt`, or run with `--insecure-upstream` (Settings → **Network → verify upstream**). This is separate from trusting gori's own root CA in your *client*, which is what lets gori decrypt the traffic in the first place.

<figure class="tui-shot">
  <img src="/images/tui/response-detail.svg" alt="gori flow detail view on the RESPONSE sub-tab, showing an HTTP/2 200 status line and syntax-highlighted response headers">
  <figcaption>Open any flow with <kbd>Enter</kbd> to read the full request and response, with sub-tabs for headers, HTTP/2 frames, and raw bytes.</figcaption>
</figure>

## Intercept

Press `i` to enable **Intercept**. When on, matching requests (and optionally responses) are held so you can forward, drop, or edit them before they continue. A filter bar at the top of the Intercept tab lets you choose the direction to catch and narrow what gets held with a query-language expression, so you only pause on the traffic you care about.

<figure class="tui-shot">
  <img src="/images/tui/intercept.svg" alt="gori Intercept tab with a filter bar for catch direction and a query condition, and a card explaining forward and drop while catch is off">
  <figcaption>The <strong>Intercept</strong> tab: toggle catch with <kbd>i</kbd>, pick a direction, and hold only matching traffic to forward, drop, or edit in flight.</figcaption>
</figure>

The queue takes the same **multi-select** as the History list ([Marking flows](#marking-flows), below): `t` marks the held message under the cursor and steps down, `Shift-↑` / `Shift-↓` extend a contiguous range, `Shift-T` marks the whole queue, and `Esc` clears. Forward (`f`) and drop (`d`) then act on **the marks if any are set, else the cursor row**, so a burst of holds can be released or killed in one keystroke — `Shift-F` still forwards the entire queue whether anything is marked or not. Marked rows get a full bar in the gutter and the filter row shows a live `3 marked` count; a mark disappears the moment its message leaves the queue, so the count never outlives what is on screen.

Reading a held message needs no marks and no editor: `Shift-←` / `Shift-→` scroll the preview sideways and `PgUp` / `PgDn` / `Home` / `End` scroll it vertically, leaving the held bytes untouched.

### What gets held

Requests are held on HTTP/1.1 and HTTP/2, gRPC included. So are responses, except the ones that have no last byte to wait for: a WebSocket upgrade (`101`), a Server-Sent Events stream, and a close-delimited response are forwarded as they arrive rather than held. **WebSocket messages are held too, but only if you ask for them** — see [Intercept on WebSocket](#intercept-websocket) below. The request that opened the socket is held like any other request.

### Intercept on WebSocket {#intercept-websocket}

**A WebSocket message is held only when the catch condition contains `proto:ws`.** Nothing else arms it — not a blank condition, not `host:acme.test`, not any direction setting. That is the exact opposite of the rule for HTTP, where a blank condition holds everything, and it is deliberate: a browser tolerates one stalled request, but a trading or chat socket carrying tens of messages a second, frozen whole because you typed a host filter, is not a state you can drain your way out of.

So the condition to type is `proto:ws`, optionally narrowed:

```
proto:ws body:subscribe          hold only messages containing "subscribe"
proto:ws host:acme.test          hold only this socket's messages
```

`body:` is a substring of the message payload and matches WebSocket messages only — at an HTTP hold gate the bytes do not exist yet. The `c:REQ` / `c:RES` chip works as usual: `REQ` is client → server, `RES` is server → client.

A held message goes in the same queue as a held request, with a `WS↑` or `WS↓` badge, the socket that carries it, and the start of the payload. Forward, drop, edit and the marks all work the same way. What is different:

- **Catch has to be on before the socket opens.** gori decides once, at the `101`, whether a socket needs the holding path. Turning catch on — or adding `proto:ws` — reaches the *next* handshake, not the connection already running. Reconnect the client. Narrowing the condition afterwards does take effect immediately.
- **A held message blocks its whole direction** until you decide it. Later messages from that peer queue behind it, and they are released in arrival order however you decide them — decide message 5 before 3 and it still goes out third. The **opposite direction keeps running**, and so do `PING`/`PONG` in both, so the socket does not die while you read. There is no way to let one message past another; a WebSocket has no message identifiers to reorder.
- **A dropped message is invisible to both endpoints.** Nothing is written, and a WebSocket stream has no message identity for the peer to notice a hole in — no error, no gap, no retry. That is weaker than dropping an HTTP/1.1 request (which answers a `502`) or an HTTP/2 one (which cancels the stream), and gori keeps no message-log row for it either. If you need the attempt on record, note it yourself.
- **A binary message (opcode 2) is read-only.** You can hold, forward and drop it; you cannot edit it. The editor round-trips through text, which is lossy on protobuf, msgpack or CBOR — and on a WebSocket that is the common case, not the exception. The pane says `READ-ONLY` and the queue row shows the size instead of a preview.
- **Editing a text message changes its line endings.** The editor normalises `CRLF` to `LF`, shared with the Repeater and the HTTP intercept editor. `$NAME` bindings are *not* expanded in a WebSocket payload — a `$` there is a byte, not a reference — so what you type is what is sent.
- **An edited message is re-framed as one frame** and a client → server message is re-masked with a fresh key, exactly as a [Match & Replace rule](#match-replace-websocket) does. A message you forward unchanged keeps the sender's own frame and mask key.
- **A hold has about 5 seconds left once the peer closes the other direction.** gori waits that long for the closing handshake to finish and then tears the socket down; anything still held is forwarded unedited. The same happens if a `CLOSE` arrives in the direction you are holding — everything undecided goes out in order, then the `CLOSE`, because the protocol forbids data frames after one.
- **Only data messages are held.** `PING`, `PONG` and `CLOSE` always pass: holding a ping breaks keepalive by construction, and holding a close strands the tunnel.
- **A very deep queue is released for you.** Past about 1 MiB queued behind a held message, or on a frame too large to buffer, the hold fails open — everything queued forwards unedited, with one line in `gori.log`. A WebSocket has no application-level flow control, so nothing slows the sender down while you read. A queue that deep usually means the condition is too wide.

Match & Replace runs **before** the hold, so what you see in the editor is what your rules produced, and what you forward is what goes out.

### Intercept on HTTP/2

Intercept works on HTTP/2 without downgrading the connection, so gRPC clients keep working while catch is on, and streams are held **individually** — holding one request does not freeze the tab. Three things differ from HTTP/1.1:

- **The head is held, not the body.** You see and edit the request or response head; the body streams past untouched. For a message with no body — most page loads — that is the whole message and nothing is missing. For one with a body, the body is still fully visible in History afterwards, just not editable in the intercept editor. A body typed into the editor is ignored, and `Content-Length` stays as the sender set it.
- **Drop cancels the stream** rather than answering with a `502` page. The client sees a cancelled request (gRPC reports `CANCELLED`); the connection and every other stream on it stay up. History records the drop exactly as it does on HTTP/1.1.
- **A held request delays later requests on the same connection.** HTTP/2 requires new streams to reach the origin in order, so requests that start *after* a held one wait for your decision. Requests already in flight keep uploading, all responses keep arriving, and a held *response* delays nothing at all.

Everything a head rule cannot express on HTTP/2 ([Head rules on HTTP/2](#head-rules-on-http2), below) applies to a head you edit by hand too.

## Scope

Scope keeps a large session focused on your target. In the **Project** tab you define include/exclude rules by host, string, or regular expression. Toggle the **scope lens** with `s` to filter the views down to in-scope traffic, and use scope to gate what Intercept and the scanners act on.

### Sandbox

The **Sandbox** is a hard containment gate for staying strictly in-bounds during a test. Toggle it in the **Project** tab's **NETWORK** pane, or from anywhere via the command palette (`Ctrl-P` → **Toggle sandbox**) — default: off. While it's on, the capture proxy forwards only the requests your scope *allows*. Everything else is blocked before it reaches the origin and recorded as an aborted flow so the attempt stays visible. On HTTP/1.1 the client gets a `403` with an `X-Gori-Sandbox: blocked` header; on HTTP/2 the blocked stream is cancelled (`RST_STREAM` with `CANCEL`) and the rest of the connection keeps working. "Allowed" means the scope evaluated as an allowlist: at least one include rule must match, and no exclude rule may match.

Because it is an allowlist, a scope with no include rules blocks all traffic, so add an include for your target first (enabling the sandbox with an empty scope asks you to confirm exactly this). A red `sandbox` chip in the top bar stays lit whenever it's on, and the NETWORK row spells out the current effect right next to the toggle.

The sandbox governs proxied and captured traffic only. Repeater, Fuzzer, Miner, and the MCP `send_request` tool enforce scope on their own (they refuse an out-of-scope target with `SCOPE_BLOCKED`). For HTTPS the sandbox relies on TLS interception to read request URLs: a host that can't be in scope is refused at the `CONNECT` step, and every request on a host that gets through is checked individually. That per-request check runs on HTTP/2 as well, per stream, so the sandbox no longer costs a host its protocol and gRPC clients keep working while it's on. Cleartext HTTP/2 tunnelled inside `CONNECT` (h2c, rare) has no per-request check available, so the sandbox refuses that tunnel outright.

## Sitemap

The **Sitemap** tab collapses History into a deduplicated tree of `host → path` endpoints, with method chips and scope markers. It's a quick way to see the shape of a target's attack surface. Press `g` to fold path-param ids, so `/user/1` and `/user/2` share one node and `/user/<uuid>` collapses into a single `{uuid}`.

<figure class="tui-shot">
  <img src="/images/tui/sitemap.svg" alt="gori Sitemap tab showing captured hosts expanded into a tree of paths with method chips and per-host path counts">
  <figcaption>The <strong>Sitemap</strong> folds History into a <code>host → path</code> tree with method chips, so you can read a target's surface at a glance.</figcaption>
</figure>

### Marking paths (multi-select)

The tree takes the same **multi-select** as the History list ([Marking flows](#marking-flows), below). Press `t` to **mark** the path under the cursor and step down, so a run of `t` marks consecutive rows; `Shift-↑` / `Shift-↓` extend a contiguous range from where you started; `Esc` clears the marks. Marked rows get a full bar in the gutter and the filter row shows a live `3 marked` count (plus how many are currently off-screen — a mark under a collapsed subtree stays marked). Letting go of `Shift` and pressing a plain `↑` / `↓` hands the range back, the way a GUI list collapses its highlight; marks you placed with `t` stay, and the wheel only scrolls.

Marks change **what the action menu acts on**, not which actions exist — the effective target is *the marks if any are set, else the cursor row*:

| Action | Key | Over marks |
|--------|-----|-----------|
| Tag path | `Shift-T` | One editor, one memo, applied to every marked path (blank clears them all) |
| Send to Repeater | `r` | One sub-tab per marked endpoint, deduplicated by captured flow (max 20) |

So `/ status:5xx` → mark the paths that matter → `Shift-T` → `auth` tags the lot, and `tag:auth` brings them back later. The menu title reads `SPACE · 3 MARKED` and the entries rename themselves (`Tag 3 paths`, `Send 3 paths to Repeater`). Discover and the Sequencer stay single-target — they scan one subtree / collect one endpoint's token — and their menu entries say `(cursor)` while marks are set.

Note that **`t` marks and `Shift-T` tags** — tagging moved off `t` so that `t` means the same thing in both lists. A synthetic `{uuid}` / `[1, 2, 3 …]` fold is not a real path, so it can't be marked or tagged: a range sweeps over it, and `t` on one says so. Unlike History there is no "mark all": on a tree that would sweep hosts and folders into the same batch as the endpoints under them.

## Protocol Support

gori understands the protocols it carries:

| Protocol | Support |
|----------|---------|
| **HTTP/1.1** | Full capture and repeater |
| **HTTP/2** | Relay after ALPN with per-stream intercept and head rules, raw frame log, HPACK decode, stream → flow assembly |
| **WebSocket** | Live message capture, repeater, per-message intercept (opt in with `proto:ws`), and Match & Replace on messages. Compression is removed from the handshake (see below) |
| **gRPC** | Framed over HTTP/2 with status trailers; protobuf shown as raw bytes (no `.proto` schema) |
| **Server-Sent Events** | Parsed into discrete events at display time |

**A WebSocket through gori is never compressed.** gori removes `Sec-WebSocket-Extensions` from the handshake it relays, so `permessage-deflate` is never negotiated and every captured frame is the message that was sent. Without that removal the two peers would agree on compression that gori does not decode, and History, the detail view, `gori run history show`, the MCP tools and export would all show you a deflate stream while presenting it as the payload. Removing the offer is the price of a capture you can trust: an app that would have used compression does not get it while it goes through gori. If you need a particular host's sockets relayed exactly as they are, put it under [TLS passthrough](/reference/config/#tls-passthrough), which leaves the connection alone and captures nothing for it.

On top of the wire protocols, gori decodes common payloads inline:

- **JWT**: header and payload decoded from `Authorization`, cookies, URLs, and bodies (signatures are shown but never verified).
- **SAML**: base64 (and DEFLATE for the redirect binding) decoded for `SAMLRequest` / `SAMLResponse`.
- **GraphQL**: `query`, `operationName`, and `variables` parsed from POST bodies and `?query=` parameters.
- **Form params**: `application/x-www-form-urlencoded` and `multipart/form-data` request bodies, plus the URL query string, decoded into a flat key=value list in the PARAMS pane (multipart file parts are summarised).

## Filtering History

History is searchable with gori's [query language](/reference/query-language/). A few examples:

```text
status:5xx                  flows that errored
host:api.example.com        a single host
method:POST body:password   POST requests mentioning "password"
dur:>500                    responses slower than 500 ms
path~/admin/                path matching a regex
```

Type a query in the History filter bar, or run it headless:

```bash
gori run history -q 'status:5xx host:api.example.com'
```

## Marking flows (multi-select)

Press `t` to **mark** the flow under the cursor and step to the next older one, so a run of `t` marks consecutive rows (in either list order). `Shift-↑` / `Shift-↓` extend a contiguous range from where you started, `Shift-T` marks everything the current filter shows, and `Esc` clears the marks. Marked rows get a full bar in the gutter and the filter row shows a live `3 marked` count.

Letting go of `Shift` ends the range: a plain `↑` / `↓` (or `PgUp` / `PgDn`, or a click on another row) hands the range back and moves on, the way a GUI list collapses its highlight. Marks you placed deliberately with `t` or `Shift-T` stay — that is what makes a discontiguous set possible, since you arrow between them without `Shift`. The mouse wheel only scrolls, so it never drops a mark.

Marks change **what the space menu acts on**, not which actions exist:

> the effective target is **the marks if any are set, else the cursor row**

So `/ status:5xx` → `Shift-T` → `Space` → `X` deletes every error in one confirm, and `Space` → `Y` copies all their URLs. The menu title reads `SPACE · 3 MARKED` and the entries rename themselves (`Delete 3 flows`, `Mine 3 flows`) so a batch is never a surprise.

| Action | Key | Over marks |
|--------|-----|-----------|
| Copy | `y` | The URL list (one per line) |
| Copy as… | `Space` `Y` | urls / host list / cURL / raw requests / raw responses / req+res pairs |
| Delete | `Space` `X` | One confirm for the whole set |
| Link… | `Space` `k` | One card lists every issue and note (plus `+ New issue…` / `+ New note…`); pick or create once, attach every flow |
| Add issue | `Shift-F` | One issue with every flow as evidence |
| Repeater / Fuzzer | `Ctrl-R` / `Shift-I` | One sub-tab per flow (max 20) |
| Mine parameters | `Space` `m` | One config popup, one session per flow (max 20) |
| Run active scan | `Space` `A` | The request estimate is summed across the set |
| Add host to scope | `Space` `h` | Hosts deduplicated — 12 flows on 2 hosts adds 2 rules |
| Send to Comparer | `Space` `c` | Exactly 2 marked fills A (older) and B (newer) directly |

Marks survive a filter change, a re-sort, and leaving the tab and coming back; the count chip tells you how many are currently off-screen. Anything that sends traffic still asks first and still honours scope per request — marking changes the request count, never the gate. A few actions stay single-target because they only make sense for one flow (opening the detail, the Sequencer); their menu entries say `(cursor)` while marks are set.

## Match & Replace (Rewriter tab)

The **Rewriter** tab is the Match & Replace editor: rules that rewrite requests and responses in flight. It sits on the tab bar right of Comparer, and the command palette reaches it too (`Ctrl-P` → **Match & Replace**, or **Go to Rewriter**).

Each rule has an operation:

| Operation | What it does |
|-----------|--------------|
| **Replace** | Find and replace text in the head or body, by literal substring or regex |
| **Add header** | Append a `Name: value` header |
| **Set header** | Replace a header's value by name, or add it if absent |
| **Remove header** | Drop a header by name |
| **Short circuit** | Answer the request from the rule, without dialing the origin at all |

A **Replace** rule targets the request or response, and the **head** (request/status line + headers), the **body** (the entity), or **ws** (a WebSocket message — see [Match & Replace on WebSocket](#match-replace-websocket) below). Choose literal or regex matching; a regex replacement supports `$1`/`$2` capture-group interpolation (write `$$` for a literal `$`). Header operations always act on the head and match by header name, case-insensitively. An empty value deletes the matched text or removes the header.

Scope any rule to a **host** glob so it only fires for matching traffic: a plain string matches as a substring (`example.com` matches `api.example.com`), and `*` is a wildcard (`*.example.com`). Leave it empty to apply to every host.

Manage the list with `a` add, `e`/`Enter` edit, `x` enable/disable, `d` delete, `s` global/project, `Shift-J`/`Shift-K` reorder (rules apply top to bottom), and `space` for the full menu. The editor shows a live preview of how many recent flows a rule would affect. Rules take effect as soon as you save, with no restart.

Under the list sits an editable **sample** message and, beside it, the same message after the enabled rules run. Paste a real captured request in there to see what your rules do to it before you turn them loose. The sample is saved with the project, like the rules it previews.

### Global and project rules

Every rule lives in one of two places, shown in the `G`/`P` column of the list:

- **Project** rules are stored in the project database. They are what this engagement needs and nothing else sees them.
- **Global** rules are stored in the `rewriter` section of `settings.json` and apply in **every** project — a standing policy like "strip CSP on `*.corp.internal`" that you do not want to rebuild per engagement.

Set the scope in the editor's `scope:` row when you create a rule, or press `s` on the list to move an existing one between the two. The rule keeps its fields and its state where you are standing; what changes is who else sees it.

Global rules apply **first**, in their own order, then the project's own — the standing layer, then the local one. `Shift-J`/`Shift-K` reorder within a scope and never across it, because the boundary is not a position.

A global rule carries a **default** on/off state, and a project may disagree with it:

- `x` toggles the rule **in this project**. For a global rule that writes an override, and the row is marked `G*`.
- `Shift-X` (space menu: **Enable/disable everywhere**) flips the global default itself, which every project that has not overridden it follows.
- Toggling back to the default **removes** the override, so the project follows the library again — including later changes to it.

Deleting a global rule removes it from every project. A running gori in another window picks up global changes when its rules reload (reopen the Rewriter tab), and a second gori **process** only on restart.

Headless, `--scope=global` addresses the library on every subcommand: `gori run rewriter add --scope=global …`, `gori run rewriter disable 3 --scope=global` (this project's override) and `--everywhere` on top of that for the default. The MCP rule tools take the same `scope` argument.

> Upgrading from the old saved-rule **library** (`s`/`o`): its entries are adopted as global rules, **disabled**, the first time gori reads the file. A preset did nothing until you loaded it, so none of them start rewriting traffic on their own; arm the ones you want with `x`.

A **body** rule buffers the message to rewrite it and re-syncs `Content-Length` automatically (a chunked body is de-chunked and re-framed); head rules keep the body streaming untouched. A compressed (`Content-Encoding: gzip`/`br`/…) body isn't decompressed, so a literal pattern won't match it, and streaming responses (SSE, close-delimited, WebSocket upgrades) are left to stream. **A body rule still forces matching hosts to HTTP/1.1.** On HTTP/2 Match & Replace applies to heads; body rewriting there is not implemented and is not planned, because HTTP/2 flow control makes a rewrite that changes a body's length either fail outright or deadlock the stream. So a body rule takes its hosts down to HTTP/1.1, and an h2 client that can't take that downgrade (gRPC) won't connect while one is enabled. `gori.log` records that once per host, naming the host and the reason.

### Match & Replace on WebSocket {#match-replace-websocket}

Set **part** to `ws` and the rule rewrites WebSocket messages instead of an HTTP head or body. **Target picks the direction**: `request` is client → server, `response` is server → client. Everything else works the same way — literal or regex, capture groups, `$NAME` bindings, and the host glob, which is matched against the host that opened the socket.

```
gori run rewriter add --target=request --part=ws --find='"role":"user"' --value='"role":"admin"'
```

The rule fires on the whole message, reassembled from its fragments, so a pattern that spans a fragment boundary still matches. It is deliberately a separate part rather than a flavour of `body`: an existing body rule never starts rewriting frames because you turned WebSocket on.

Six things are worth knowing before you rely on it:

- **A rule takes effect on the next handshake, not the open socket.** gori decides once, at the `101`, whether a socket needs the rewriting path. Reconnect the client after enabling a rule.
- **Only text messages are rewritten.** A binary message (opcode 2) is carried through untouched, because a text find/replace over protobuf or msgpack corrupts rather than edits. So is a text message that is not valid UTF-8.
- **A rewritten message is re-framed as one frame**, and a client → server message is re-masked with a fresh key. Once the length changes the sender's fragmentation cannot be reproduced. A message no rule changed is forwarded as the peer's own frame, mask key and all.
- **Header and short-circuit operations cannot use `ws`.** A WebSocket message has no headers, and a stub answers a request that a message is not. gori refuses the combination instead of quietly turning it into an HTTP head rule.
- **The message log records what gori sent**, not what arrived — the same rule the rest of the proxy follows, so History shows the bytes the peer actually saw.
- **A message larger than 16 MiB is forwarded untouched**, as is any single frame past the same cap. The rewrite needs the whole message in memory and a long-lived socket should not be able to grow the proxy heap without bound.

A rule rewrites in flight and nothing pauses. To stop a message and decide about it by hand, hold it instead — see [Intercept on WebSocket](#intercept-websocket). The two compose: rules run first, and the editor shows you their output.

### Short circuit — answer without an origin

The other four operations rewrite a message that already exists. **Short circuit** answers instead: the request is matched, gori replies with a response you wrote, and the origin is never dialed. That covers what a Replace rule structurally cannot — the endpoint 404s or 500s, the origin is offline or behind an auth wall, or the body has to be constructed rather than derived.

It is how you ask *"is this check enforced anywhere but the client?"*: force an authorization probe to return `{"isAdmin": true}`, flip an entitlement the client is trusted to honour, inject a payload into a JSON field to reach a DOM sink, or serve a malformed body to test the client's parsing.

The rule matches the **request head** (literal or regex, host glob as usual) and carries the response you want. Write it as a raw HTTP response — press `Enter` on the `response:` row to open the editor:

```
200 OK
Content-Type: application/json

{"isAdmin": true}
```

The first line is the status; `200`, `200 OK` and `HTTP/1.1 200 OK` all work, and an omitted reason phrase is filled in for you. Lines up to the blank line are headers, and everything after it is the body, byte for byte as you typed it. For a large or binary stub, set **body file** to a path instead: gori serves that file's bytes as the body and re-reads it whenever it changes on disk, so you can edit the stub outside gori and see it on the next request.

`Content-Length` is always re-derived from the bytes gori actually sends — a `Content-Length` or `Transfer-Encoding` in your rule is dropped, because one that disagreed with the body would desync the next request on a keep-alive connection. Everything else goes out exactly as written; gori adds no header of its own.

If the rule cannot be honoured (the response doesn't parse, the body file is gone) gori answers `502` with `X-Gori-Short-Circuit: error` and records the reason on the flow. It does **not** fall through to the origin: you declared the request contained, and leaking a payload because a stub file was deleted is the worse failure.

Two consequences worth knowing:

- **Short-circuited flows are marked in History.** They show `STUB` in the `PROTO` column and no duration, because there was no round trip. Filter with `stub:true` to review them, or `stub:false` to read History as traffic that really happened — worth doing before you screenshot anything.
- **Probe skips them.** A passive rule reading a stub is reading your bytes, not the target's, and an active probe would compare a canned baseline against a live origin. Both refuse, so a stub can never manufacture a finding.

**A short-circuit rule forces matching hosts to HTTP/1.1**, the way a body rule does: the h2 relay has no way to answer a request locally, so a stub rule left on an h2 connection would silently let the request through to the origin — the one thing it exists to prevent. `gori.log` records that once per host, naming the host and the reason. An h2-only client (gRPC) will not connect while a stub rule is enabled.

### Head rules on HTTP/2

Head rules apply to HTTP/2 without downgrading the connection, so gRPC keeps working. Rules are written against the same head the flow detail view shows (`GET /path HTTP/2`, a `Host:` line standing in for `:authority`, lowercase field names), and that is what they run against on the wire. A few things behave differently from HTTP/1.1 because HTTP/2 has no place for them:

- The start line reads `HTTP/2`, and responses carry no reason phrase. A rule written against `HTTP/1.1` or `200 OK` won't match, and a rule that writes a version or a reason phrase has it dropped.
- Field names go out lowercase, so a rule that only changes a name's capitalization does nothing.
- `Cookie` stays split across however many lines the client sent, so a pattern spanning the whole cookie string may not match.
- `:scheme` isn't reachable, and `Content-Length` is restored from the original head (the body streams untouched).
- Trailers and server-pushed heads aren't rewritten, so gRPC's `grpc-status` isn't reachable from a rule.
- A rule that adds `Connection`, `Keep-Alive`, `Transfer-Encoding` or `Upgrade` is sent as written. HTTP/2 forbids those, so the peer will reset the stream, which is deliberate: those bytes are yours to send.

Head rules take effect on connections opened after you save. A rule enabled while a long-lived HTTP/2 connection is already open applies from that connection's next request head.

The same rules are scriptable headless: `gori run rewriter` (list / add / rm / enable / disable / preview) and the MCP `create_rule` / `update_rule` / `list_rules` / `preview_rule` tools. Both carry the `scope` argument, so a global rule can be created and toggled without opening the TUI.

## Colouring rows (Colormarker tab)

Marks are for the set you are working on right now. A **colour rule** is standing: it says "any 5xx on this engagement is red" once, and every matching row stays red as traffic arrives. Same idea as ZAP's neonmarker, driven by a condition rather than a tag.

The tab is **hidden by default** — show it from `settings:tabs`, where it sits next to Rewriter.

Each rule carries a condition, a colour, and a style:

| Style | What it draws |
|-------|---------------|
| `full` | Tints the whole History row's background |
| `strip` | Paints one colour cell in a narrow column ahead of `TIME` — a stripe down the left edge of the list |

Both styles coexist: use `strip` for noise you want to be able to skip past, `full` for the rows you want to be unable to miss. Six colours (`red`, `orange`, `yellow`, `green`, `blue`, `purple`), resolved through the active theme, so they read correctly on light and dark palettes alike.

The tint **mixes into** the cursor and mark bands rather than replacing them, so a selected coloured row still reads as selected, and a marked one keeps its full gutter bar. The swatch column is only reserved while a `strip` rule is enabled, so a project with no colour rules renders exactly as before.

**The first enabled match wins.** This is the one place Colormarker differs from the Rewriter next door: rewrite rules *compose* — every enabled rule runs, in order — while colour rules *resolve*, so the first match paints the row and the rest are never consulted. Order is therefore a real decision, not a tiebreak: `Shift-J` / `Shift-K` reorder, and global rules resolve before project ones, so a standing policy outranks a local layer.

Conditions use the same boolean grammar the conditional-intercept bar speaks — `host:`, `path:`, `method:`, `scheme:`, `status:`, `proto:`, plus `AND` / `OR` / `NOT`, `-negation` and `(grouping)`. `Tab` on the `when:` row completes the token under the caret. Three things behave differently from the History search bar, and gori refuses or warns rather than letting you discover them from an empty list:

- **`body:` never matches here.** A History row carries no payload.
- **`host:` is a substring, not a DNS-label glob.** `host:alpha.test` also matches `xalpha.test`.
- **There is no `header:` / `size:` / `dur:` / `url:` / `stub:`.** Those need a query, and a colour is decided while the row is being drawn. An unknown field is refused — left alone it would quietly become a free-text search and the rule would never fire.

A rule lives either in this project or in the **global library** every project reads, exactly like a Match & Replace rule: `s` moves it between the two, `x` toggles it here, and `Shift-X` flips a global rule's default everywhere. A project that disagrees with the library stores only the disagreement, and that disagreement is dropped the moment the two agree again — so a rule you toggled off and back on goes back to following the library rather than pinning today's answer.

| Action | Key |
|--------|-----|
| Add / edit a rule | `a` / `Enter` or `e` |
| Enable or disable here | `x` |
| Flip a global rule's default everywhere | `Shift-X` |
| Move between project and global | `s` |
| Reorder (changes which rule wins) | `Shift-J` / `Shift-K` |
| Delete | `d` |

The rule form previews as you type: how many recent flows the condition **matches**, and how many it would actually **paint** — the two differ when an earlier rule already claims the row.

Scriptable headless too: `gori run colormarker` (list / add / rm / enable / disable / move / preview) and the MCP `create_color_rule` / `list_color_rules` / `move_color_rule` / `preview_color_rule` tools.

## Session bindings

A rotating token — a session cookie, a CSRF field, a bearer — is worth nothing to a rule that has to spell it out in advance. A **binding** is a name gori fills in at send time from something it saw in a response, and it has two halves that are two separate rows:

- an **extract rule** (Rewriter tab, `extract` sub-tab) reads a value out of a response and binds a name to it. It carries a condition in the intercept-filter grammar (`path:/login AND status:200`), an optional host glob, and a descriptor: a cookie, a response header, a regex over the body, a JSON path, or a byte range.
- an ordinary **Match & Replace rule** writes it back out. A replacement of `$SESSION` in a `set header` rule, or in a body `replace`, is resolved when the request goes out rather than when the rule was saved.

One name is written by exactly one extract rule; a second rule claiming the same name is refused when you save it, with the reason. A name that is declared but not yet bound does **not** go out empty and does not go out as the literal `$SESSION` — the rule is skipped and the reason lands in the events feed.

Extraction runs on **traffic through the proxy** and on **sends you made by hand** (a Repeater tab). It deliberately does **not** run on a sweep — Fuzzer, Miner, Discover, or an active Probe. A sweep sends attacker-shaped payloads, and a response echoing one back could rebind your session to a payload-derived value that then went out on every later request.

It also runs on the bytes that were **delivered**: after Match & Replace, and after whatever you decided at the intercept gate. A response you edited binds what you edited; a response you dropped binds nothing, because the browser never got it.

**Where the value lives.** In memory, for as long as the project is open. The rule is saved; the value never is — not in `settings.json`, not in the project database. A token restored on reopen is stale by construction, and re-extracting it costs one request. A bound value never appears in the events feed, in an issue, in a note or in a log line. It **does** appear in captured traffic, because that is where it came from — masking a capture would be a lie about the wire.

**What a body descriptor costs.** A cookie or header descriptor reads the response head, which every response is parsed for anyway, so it costs nothing and works on HTTP/2. A regex, JSON path or byte-range descriptor needs the response body, so gori buffers the response instead of streaming it — the same trade a Match & Replace body rule makes — and **forces matching hosts to HTTP/1.1**, for the same reason a body rule does: HTTP/2 DATA frames are relayed untouched. Only hosts the rule's own glob matches are downgraded, and `gori.log` records that once per host with the reason. Streaming responses (SSE, close-delimited, WebSocket upgrades) and bodies over the buffering ceiling are never buffered, so a body descriptor cannot read them; when its condition selects one anyway, the events feed says so rather than reporting that the selector found nothing.

Compressed bodies **are** decoded before a body descriptor runs, so a CSRF token in a gzipped HTML page is reachable — unlike a Match & Replace body pattern, which matches the entity as it arrived. The same descriptor means the same thing whether the proxy or a Repeater send saw the response.

The `bindings` sub-tab lists every name, whether it is bound, which rule wrote it, and a masked preview. Headless: `gori run rewriter extract` / `gori run rewriter bindings`, and the MCP `create_extract_rule` / `update_extract_rule` / `list_extract_rules` tools.


## Import

You don't have to capture everything live. From the command palette (`Ctrl-P`):

| Action | Source |
|--------|--------|
| **Import: HAR** | Browser or proxy HAR export → full request/response flows |
| **Import: URLs** | Text file, one URL per line → skeleton request flows |
| **Import: OpenAPI** | OpenAPI/Swagger JSON or YAML → one request template per operation |
| **Import: Postman** | Postman Collection v2 export → one request template per saved request |
| **Import: Insomnia** | Insomnia v4 JSON export → one request template per saved request |
| **Import: Burp** | Burp Suite saved items (XML) → full request/response flows, byte-exact |

Malformed entries are skipped rather than aborting the whole import. Imported flows land in History like captured traffic, so you can filter, Repeater, Fuzz, and scan them the same way.

**Postman and Insomnia** resolve `{{variables}}` from the collection's own variable list (Insomnia: from the exported environments). A request whose URL still holds an unresolved variable is skipped rather than stored with a literal `{{baseUrl}}` host — if every request is skipped that way, the error names the variables so you know what to add. Folder nesting is walked in full, and auth seeds `bearer`, `basic`, and header API keys; token-exchange schemes (OAuth, AWS SigV4, NTLM, …) are left for you to fill in.

**Burp** items keep their wire bytes exactly as saved — odd spacing, duplicate headers, a deliberately wrong `Content-Length`, a CRLF in the request target. A hand-forged request replays from the Repeater byte-for-byte, which is the point of importing from Burp rather than re-describing the request.

The same sources are scriptable headless: `gori run import --postman PATH` (and `--har` / `--urls` / `--oas` / `--insomnia` / `--burp`), and the MCP `import_flows` tool.

## Host Overrides

Host overrides are a `/etc/hosts`-style map: dial a specific IP for a hostname without changing DNS. Two layers exist:

| Layer | Where | Precedence |
|-------|-------|------------|
| **Project** | **Project** tab → HOST OVERRIDES pane (`a` / `e` / `d`) | Wins on collision |
| **Global** | Preferences (`Ctrl-,`) → **Network & Tabs** → **Network** → **Hostname overrides**, `Ctrl-P` → **Settings: Hostnames**, or `hostname_overrides` in `settings.json` | Fallback |

Useful for staging hosts, IP-based virtual hosts, or pointing a production hostname at a lab box while keeping the `Host` header intact.

## Clients That Cannot Use a Proxy

Some clients ignore proxy settings entirely — embedded devices, statically-linked binaries, anything that never reads `HTTP_PROXY`. For those, run a **transparent listener** and redirect traffic into it with your firewall; no client-side configuration is needed at all.

gori recovers the destination from the kernel where it can (`SO_ORIGINAL_DST` on Linux, a `pf` lookup on macOS, which needs root). That answer decides which machine the connection reaches, while the client's `Host` header or TLS SNI still supplies the name — the one the certificate is minted for, that scope matches, and that History shows. Where the kernel cannot answer, the name is resolved as the destination too. The log says which source decided, so a destination that looks wrong is traceable.

Add it under `listeners` in `settings.json` and point `iptables` / `pf` at it — see the [`listeners` reference](/reference/config/#listeners) for the config keys and the redirect rules. Captured flows, scope, the Sandbox and the passthrough list all behave exactly as on the normal proxy path.

The certificate still has to be trusted on the client: transparent mode removes the proxy *setting*, not the need for gori's CA.

If a **reverse listener** would also work for your target, prefer it. It declares the destination outright, so it needs no firewall rule and none of the destination is taken from what the client sent.

## When a Pinned App Is in the Way

gori intercepts every HTTPS connection, which breaks any client that pins certificates — a mobile app, an auto-updater, a background agent. On a phone or a shared machine that traffic arrives whether you want it or not, and it fails loudly while you are trying to test something else.

List those hosts under **TLS passthrough** (Preferences → **Network & Tabs** → **Network**, comma-separated, or `network.tls_passthrough` in `settings.json`). A listed host is relayed as an opaque tunnel: the client sees the origin's real certificate and works normally. Nothing is captured for it, which is the trade.

Scope will not do this for you. Scope decides what is recorded and acted on; an out-of-scope host is still decrypted. Passthrough is the only setting that keeps gori's hands off the TLS itself. See the [`tls_passthrough` reference](/reference/config/#tls-passthrough) for pattern syntax.

A bypassed host leaves no flow anywhere, so the top bar grows a yellow `bypass:N` chip the first time one is relayed. Click it (or run **TLS passthrough hosts** from the command palette) for the list: each host with the rule that matched, when it was first seen, and how many connections it covered. The list is session-wide, not per project, because the setting is global.

## Project Tab

The **Project** home tab is more than a summary. Under the overview sits a sub-tab strip: `←`/`→` switch cards, `↓`/`Enter` drop into the one showing, and `Esc` (or `↑` at the top) comes back up to the strip.

The overview band carries the project's own facts: name, directory, its registry short id and
bound workspace, the proxy address with whether capture is live, flow and byte counts, confirmed
issues (with unreviewed Probe hits alongside), database size, when it was created and last
touched, and the technologies Probe fingerprinted. It lays those out in two columns on a wide
terminal and folds them into one summary line per group on a short one, so a narrow window loses
detail rather than whole facts.


<figure class="tui-shot">
  <img src="/images/tui/project.svg" alt="gori Project tab with overview, at-a-glance status bars, scope, host overrides, environment variables, description, and network panes">
  <figcaption>The <strong>Project</strong> home: overview and status at a glance, plus panes for scope, host overrides, env vars, and per-project network settings.</figcaption>
</figure>

| Sub-tab | Purpose |
|------|---------|
| **DESCRIPTION** | Free-form project notes |
| **SCOPE** | Include/exclude rules (host, string, or regex) |
| **HOST OVERRIDES** | Per-project dial map |
| **ENV** | Per-project `$KEY` variables for outbound requests. See [Repeater & Fuzzer](/guide/repeater-and-fuzzer/#environment-variables) |
| **NETWORK** | Scope-lens + **sandbox** toggles, plus per-project network pins (bind / upstream) that override the global Settings default |

Scope rules and host overrides are also scriptable: `gori run project scope add --kind=include --type=host --pattern=api.example.com`, `gori run project host-override add --host=api.example.com --ip=10.0.0.1`. Full flags are in the [CLI Reference](/reference/cli/#run-project).

## Next Steps

- [Repeater & Fuzzer](/guide/repeater-and-fuzzer/): act on the flows you capture
- [Decoder](/guide/decoder/): encode, decode, and hash without leaving the TUI
- [Scanning & Issues](/guide/scanning/): automated and manual analysis
- [Query Language](/reference/query-language/): the full filter syntax
