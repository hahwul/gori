+++
title = "Configuration"
description = "The settings.json keys and the GORI_HOME storage layout."
weight = 20
+++

gori stores global preferences in `settings.json` and each project as its own SQLite database. See the [Configuration guide](/getting-started/configuration/) for a walkthrough; this page is the key-by-key reference.

## Storage Layout

Everything lives under `GORI_HOME` (`$GORI_HOME` if set and non-empty, otherwise `~/.gori`):

| Path | Contents |
|------|----------|
| `settings.json` | Global preferences |
| `gori.db` | Default project database |
| `projects/` | One subdirectory per named project, each with its own DB |
| `ca/` | Root CA: `root.crt.pem` and `root.key.pem` |
| `themes/` | User themes |
| `wordlists/` | Fuzzer / miner wordlists |
| `protos/` | gRPC descriptor sets (`protoc --descriptor_set_out`), loaded by any project with no path of its own |
| `active_project` | Marker for the most-recently-used project |

## settings.json

`settings.json` is JSON. Find or edit it with `gori settings` / `gori settings --edit`.

Its location resolves as `--config PATH` → `$GORI_CONFIG` → `$GORI_HOME/settings.json`, so a run can use a different configuration without relocating the CA, project databases, themes and wordlists. Sections can be moved between configs with [`gori settings export` / `import`](/reference/cli/#profiles). Five of them — `rewriter`, `scan_rules`, `decoder`, `statusline` and `editor` — can carry a command rather than data, so a profile can carry code; both ends of a transfer [say so](/reference/cli/#profiles-that-carry-commands).

### network

```json
{
  "network": {
    "bind_host": "127.0.0.1",
    "bind_port": 8070,
    "upstream_proxy": ""
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `bind_host` | string | `127.0.0.1` | Global default listen address (used when a project has no `net.bind_host`) |
| `bind_port` | integer | `8070` | Global default listen port (used when a project has no `net.bind_port`) |
| `upstream_proxy` | string | `""` | Global default upstream: legacy `host:port`/`http://…`, `http+tls://…` (TLS to the proxy), or `socks5://…`/`socks5h://…`; empty = direct. Project `net.upstream_proxy` wins when set. `https://…` is the **legacy spelling of the plaintext form** — see [upstream_rules](#upstream_rules) |
| `upstream_proxy_ca` | string | `""` | PEM bundle trusted for the **upstream proxy's own** certificate on an `http+tls` hop, in addition to the system store. Blank = system trust only. A path, never a secret — safe to share in a profile |
| `upstream_proxy_insecure` | bool | `false` | Skip verification of the **upstream proxy's** certificate. Independent of `verify_upstream` and untouched by `--insecure-upstream`, which are about the **origin**. Off by default: that hop carries every `CONNECT` authority and every `Proxy-Authorization` credential |
| `verify_upstream` | bool | `true` | Verify upstream TLS certificates against the system CA trust store, resolved automatically from standard locations (honouring `SSL_CERT_FILE` / `SSL_CERT_DIR`); if none is found, HTTPS verification fails — set `SSL_CERT_FILE` or turn this off. Toggling it re-syncs the running proxy, the active prober, and the Repeater / Fuzzer / Miner senders without a restart. `--insecure-upstream` seeds it off for one session |
| `serve_landing` | bool | `true` | Serve the built-in info / CA-download page, both when the listen address is hit directly and at the reserved host `http://gori.proxy/` (or `http://gori/`) for a client already pointed at the proxy |
| `connect_timeout_secs` | integer | `30` | Upstream connect timeout in seconds (minimum `1`) |
| `io_timeout_secs` | integer | `30` | Upstream read / write idle timeout in seconds (minimum `1`) |
| `capture_max_mib` | integer | `2` | Largest body stored per message, in MiB. Larger bodies still forward byte-exact; only the stored copy is truncated, and the true wire size is recorded |
| `http2` | string | `"auto"` | `auto` reflects the origin's ALPN; `off` forces HTTP/1.1 on every tunnelled connection. See [http2](#http2) below |
| `strip_alt_svc` | bool | `false` | Remove the `Alt-Svc` response fields advertising HTTP/3 before the client sees them, so a browser cannot switch to a transport gori does not carry. See [strip_alt_svc](#strip-alt-svc) below |
| `tls_passthrough` | array | `[]` | Hosts to relay without decrypting. See [tls_passthrough](#tls_passthrough) below |

CLI `--listen` / `--port` override these for the current process only (not written to disk). See [Per-Project Overrides](#per-project-overrides).

#### http2

`auto` (the default) reflects the origin's ALPN: gori advertises HTTP/2 to the client only when the origin speaks it. `off` never advertises it, so every tunnelled connection takes the HTTP/1.1 path.

Pinning the version matters because h1-vs-h2 differences are often the *subject* of a test — request framing, header-name handling, smuggling — and holding the protocol constant is how the difference gets isolated.

Before this setting, the only lever was an implementation detail: gori downgrades to HTTP/1.1 when Match & Replace rules are live, so the way to force h1 was to enable a no-op rule. That also turned on head rewriting, and was easy to leave behind.

`off` takes effect on the next tunnelled connection, and skips the origin ALPN probe entirely (one fewer connection per origin). It does **not** override the downgrades gori still performs for correctness: a live Match & Replace **body** rule, a body-scoped **extract** rule, or a **short-circuit** rule forces HTTP/1.1 regardless. Match & Replace on HTTP/2 applies to heads, body rewriting there is not implemented and is not planned (HTTP/2 flow control makes a rewrite that changes a body's length either fail outright or deadlock the stream), body extraction needs an entity the relay does not assemble at that seam, and the h2 relay has no way to answer a request locally. Intercept, head rules and the Sandbox no longer downgrade anything. A cleartext-HTTP/2 (`h2c`) tunnel inside `CONNECT` is refused rather than relayed when `off`: the client has already committed to h2 by sending the preface, so there is nothing to downgrade.

Every downgrade is announced in `gori.log`, once per host, naming the host and which reason caused it. An HTTP/2-only client — every gRPC client — cannot connect to a host while a downgrade applies, and that log line is the only place the reason is written down.

There is no `force` mode. It would need a defined fallback for an origin that turns out not to speak HTTP/2, and no need for it has come up; the string form leaves room to add it without a compatibility shim.

#### tls_passthrough

A CONNECT whose host matches is answered `200` and then relayed as an opaque byte tunnel: no certificate is minted for it, nothing is decrypted, and nothing is captured. The client validates the origin's own certificate, exactly as if gori were not in the path.

This is the escape hatch for a client that pins certificates — a mobile app, an auto-updater, a desktop agent — sharing the proxy with your actual target. Without it, that traffic breaks. Scope does not help here: scope decides what is *recorded* and acted on, never whether TLS is intercepted, so an out-of-scope host is still decrypted.

It is also the answer for a **non-HTTP protocol** on the same path — MQTT, AMQP, a database wire protocol, or anything else whose first byte is not text. gori's proxy speaks HTTP; point one of those at it and, without passthrough, gori terminates TLS and then finds bytes that are not an HTTP request. It no longer hangs silently on that: the connection is recorded as a `not an HTTP request` flow naming the observed bytes, so you can see what arrived and reach for passthrough. List the host here and gori tunnels it byte-exact instead.

A protocol that opens with a *text* line (SSH's `SSH-2.0-…` banner, an SMTP greeting) is **not** detected, on purpose: on the first line it is indistinguishable from a deliberately malformed request line, and gori forwards those verbatim rather than second-guessing your payload. Such a connection still waits out the head timeout. Reach for passthrough there too.

It also covers the two shapes with no bytes to judge. A **server-speaks-first** protocol — SMTP, IMAP, POP3, MySQL, where the *server* greets first — has its client connect and send nothing at all, so there is nothing to classify; the connection is now recorded as a `no request` flow naming that shape once the read times out, instead of dying in silence. On a reverse or transparent listener that flow names the origin the client was dialling — declared for the reverse one, read from the kernel's redirect for the transparent one where the platform answers — which for a redirected `:25` or `:143` is the whole diagnosis and the host to list here. On a socks5 listener it names the destination the client asked for, once the handshake got that far; before that there is nothing to name. On the forward-proxy listener there is no name to record — nothing arrived to carry one — so there the flow's advice is to keep gori off that port instead.

A **non-TLS payload inside `CONNECT`** — `ssh -o ProxyCommand='nc -X connect proxy:8080 %h %p'`, the ordinary corporate-proxy pattern — is refused with a flow that names the byte it opened with, rather than being fed to a TLS handshake it can never complete. Listing the host makes it work: a listed host is relayed byte-exact, with no peek at what it speaks. The same peek now identifies an `h2c` tunnel by its full `PRI * HTTP/2.0` preface rather than by its first byte, so a plaintext `POST` or `PROPFIND` tunnelled to port 80 is refused like any other undecodable payload instead of being handed to the HTTP/2 relay.

If gori cannot complete a TLS handshake with a client reaching a tunnelled origin — most often because the client does not trust the CA yet, and always for a client that pins a certificate — that is written to `gori.log` once per host, port and reason. The CA-download page at `gori.proxy` is excluded: a client arrives there precisely because it does not trust the CA yet, so a failure is the expected first step, not a fault to report.

```json
{
  "network": {
    "tls_passthrough": ["updates.example.com", "*.push.apple.com"]
  }
}
```

Patterns use the same dialect as scope `host` rules: `example.com` covers that host **and its subdomains**, `*.push.example.com` is a glob (subdomains only, not the bare host), and an IPv6 literal matches bracketed or bare. Matching is case-insensitive. Entries are bare hosts — a scheme, a path, or a `:port` is rejected when you save, because such an entry could never match.

Empty (the default) means everything is intercepted, which is how gori behaved before this setting existed. Plaintext HTTP is unaffected: there is no TLS there to pass through.

Because a bypassed host produces no flow, gori writes one line to its log the first time each host is relayed, so a host missing from History has a traceable reason. Edit the list from Preferences → **Network & Tabs** → **Network** → **TLS passthrough** (comma-separated).

#### strip_alt_svc {#strip-alt-svc}

gori does not intercept HTTP/3: QUIC is UDP, and every gori listener is a TCP socket. So an origin answering `Alt-Svc: h3=":443"` is inviting the client onto a transport gori cannot read, and what you are left with is a History that just stops. Turn this on and gori removes the `Alt-Svc` fields advertising `h3` (or an `h3-…` draft) from the response the *client* receives, on both HTTP/1.1 and HTTP/2, so the response the client reads offers it nowhere to go.

It is off by default on purpose. gori edits a response you did not ask it to edit only where *not* editing it would make gori lie about what it captured — the `Sec-WebSocket-Extensions` strip is that case, because a negotiated `permessage-deflate` leaves every stored frame a deflate stream presented as the payload. An `Alt-Svc` left in place corrupts nothing gori records; it only means the client may leave. That is a call about the test in front of you, so it is a switch the human throws.

**With it off, gori says so instead.** A response that advertises h3 and reaches the client un-stripped now carries an advisory naming the evidence and the setting — *"kept 1 Alt-Svc HTTP/3 advertisement (`h3=":443"`) in this response — gori does not intercept HTTP/3, so a client acting on it leaves the proxy for a transport gori cannot see, and whatever it does there is missing from History rather than absent (settings network.strip_alt_svc is off)."* — on both HTTP/1.1 and HTTP/2, in the same places the removal advisory appears. Nothing on the wire changes: the origin's head reaches the client byte for byte, and only the flow gains a sentence. Each host is also named once in `gori.log`, and the passive probe's existing `tech_http3` fingerprint still raises its own once-per-host `Alt-Svc: <host> advertised HTTP/3` event, clickable through to the Probe tab — so the session-level view of "which hosts are inviting clients away" is where it already was. What was missing, and is what this adds, is the per-flow record: a gap in History that nothing explains reads exactly like an origin that had nothing more to say.

Removal is per **field**, and only for fields that advertise h3. `Alt-Svc: clear` is never removed: RFC 7838 §3 makes it the instruction to *forget* cached alternatives, which is the one spelling that helps here. A plain `h2=":8443"` alternative is never removed either — that is another TCP port, still tunnelled through gori.

The strip runs *before* Match & Replace, so a response head rule that puts the header back wins. An operator saying so about one host outranks a switch thrown for all of them.

On HTTP/2 there is a price: removing a field means gori re-encodes that response's header block, and HPACK's per-connection state makes that one-way, so from the first strip onward gori re-encodes every response head on that connection and gives up the origin's HPACK compression for it. The raw frame log for that connection then holds gori's HPACK rather than the origin's, which the advisory on the flow says out loud. A trailer block and a PUSH_PROMISE are left alone: no client acts on an `Alt-Svc` in either, and stripping one would let an origin close that latch whenever it liked.

Every flow whose response was stripped carries an advisory naming what was removed and quoting the removed value, in the History detail pane, `gori run history --format json` and the MCP `get_flow` tool. The switch costs you the bypass, not the evidence — but it does move where that evidence lives. The passive probe reads the *stored* response, and the stored response is the one gori delivered, so a captured flow stops raising the `tech_http3` fingerprint and its `Alt-Svc: <host> advertised HTTP/3` event line once the strip is on. The per-flow advisory is where that fact moves to, and the event was a warning about a bypass that can no longer happen. Only captured traffic is affected: a response gori elicited itself — a Repeater send, a Fuzz sweep, a Discover crawl, MCP `send_request`, an import — never goes through the proxy path, so it keeps the origin's `Alt-Svc` and still fingerprints. Resend the request from the Repeater and the advertisement is back in front of you.

Three things it cannot cover. A host on [`tls_passthrough`](#tls-passthrough) is never decrypted, so there is no response for gori to edit. A client can learn an h3 route without any `Alt-Svc` at all — a DNS `HTTPS` record does it, and no response-side strip reaches that. And a field-name spelled with whitespace before the colon (`Alt-Svc : h3=…`) is not recognised, by this setting or by gori's own header projection; a conforming client rejects that field too (RFC 9112 §5.1). Toggle the setting from Preferences → **Network & Tabs** → **Network** → **Strip HTTP/3 Alt-Svc**.

### listeners

Additional sockets the proxy accepts on, alongside the primary `network.bind_host` / `bind_port`.

```json
{
  "listeners": [
    { "host": "192.168.1.10", "port": 8081, "mode": "proxy" },
    { "host": "127.0.0.1", "port": 8080, "mode": "transparent", "target_port": 80 },
    { "host": "127.0.0.1", "port": 8443, "mode": "transparent", "target_port": 443 },
    { "host": "0.0.0.0", "port": 9000, "mode": "reverse", "origin": "https://api.example.com" },
    { "host": "127.0.0.1", "port": 1080, "mode": "socks5" }
  ]
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `host` | string | — | Listen address. Required |
| `port` | integer | — | Listen port. Required |
| `mode` | string | `"proxy"` | `proxy`, `transparent`, `reverse` or `socks5`. An unknown mode drops the entry rather than defaulting to `proxy`, which could expose an unintended forward proxy on a LAN address |
| `target_port` | integer | `80` / `443` | Transparent only: the upstream port to use when the kernel cannot say which one the client dialled. Advisory — see [Transparent mode](#transparent-mode) |
| `origin` | string | — | Reverse only, required: the absolute `http(s)` URL to forward to |
| `rewrite_host` | boolean | `false` | Reverse only: replace the forwarded `Host` with the origin's authority |

A field used in the wrong mode is **rejected**, not ignored — `target_port` outside transparent, `origin` or `rewrite_host` outside reverse. Silently dropping it would leave a config that reads as if it does something it does not. A `socks5` entry therefore carries `host`, `port` and `mode` and nothing else: all three of those fields belong to the other two modes.

The primary bind stays a scalar on purpose. It is not "an address gori listens on"; it is *the forward-proxy endpoint you configure a client against*, and that is singular by construction. It stays what the status bar, the statusline JSON, the capture-status sidecar and the live rebind all report. Additional listeners are an **inventory** instead: a `listeners:N` chip appears beside the listen chip whenever any are configured, and opens a read-only list of every one with its mode, address, origin and status. The chip turns red as `listeners:N/M` when one of them is not up.

The asymmetry is deliberate. gori can move the primary bind under you (a taken port falls back), so it has to be announced. Every address in `listeners` was typed there by you, so it only has to be confirmed.

An extra listener that fails to bind (privileged port, address in use) does **not** stop capture on the primary, and the failure is recorded rather than swallowed — it shows in the `listeners:N/M` chip and names its reason in the list. An entry that is unusable for any other reason (a missing `origin`, a field in the wrong mode) is dropped from the running set and listed there too, rather than vanishing. An entry duplicating the primary address is skipped.

The section is read at startup and is **not** applied live: editing it and saving raises a notification telling you a restart is needed.

#### Transparent mode

A transparent listener serves clients that believe they are talking to the origin. There is no `CONNECT` and no absolute-form request target, so gori has to recover the destination per connection, and it has two sources that answer different halves of the question.

**The kernel** still remembers what the client dialled before the redirect rule rewrote it, and gori asks it once per connection:

- **Linux** — `getsockopt(SOL_IP, SO_ORIGINAL_DST)`, or the `SOL_IPV6` form for a v6 connection. Always available; it just returns nothing when no redirect put the connection there.
- **macOS** — a `DIOCNATLOOK` on `/dev/pf`. That device is root-only, so this works only when gori itself runs as root.

That answer is an **address and a port**. The port is authoritative: it is the port the client actually connected to, so it outranks both `target_port` and any port in the client's `Host` header. The address is where gori **dials**, whatever the client called the destination.

**The client's own bytes** supply the name: the `Host` header for cleartext, the TLS **SNI** for HTTPS, read out of the ClientHello *before* the handshake. gori keeps using the name whenever there is one, because a name is what everything downstream needs — which leaf certificate to mint, the sandbox gate, the [passthrough list](#tls_passthrough), the origin ALPN probe, scope matching, and what History shows. The kernel's address fills in as the name only when there is no name at all.

So the two never compete. The name identifies the destination and travels upstream byte-exact; the address decides which machine the connection reaches. A client that lies in `Host` still gets a certificate for the name it asked for and still shows up in History under it — but it cannot move gori's upstream connection anywhere.

A [hostname override](#hostname_overrides) still wins over the kernel address, because it is a mapping you wrote by name. That is the one way a transparent destination can be redirected, and it takes an entry in your own table to do it.

Which source decided a destination is written to the log, once per listener and once again if it ever changes, so a destination that looks wrong can be traced instead of guessed at.

Route traffic to it with your firewall. On Linux:

```bash
iptables -t nat -A OUTPUT -p tcp --dport 80  -j REDIRECT --to-port 8080
iptables -t nat -A OUTPUT -p tcp --dport 443 -j REDIRECT --to-port 8443
```

On macOS, an equivalent `pf` `rdr` rule.

**Why `target_port` is still here.** The kernel lookup does not always answer: there is no mechanism outside Linux and macOS, macOS needs root, and a connection made straight to the listener with no redirect in front of it has nothing earlier to recover. `target_port` is the declared fallback for those — the redirect rule's intent, written down, so the listener taking redirected `:443` traffic sets `target_port: 443`. When the kernel does answer, `target_port` is not consulted.

**When the kernel does not answer.** Everything above degrades to what gori did before the lookup existed: the name is resolved through DNS, so a client that lies in `Host` (or offers a misleading SNI) steers the upstream dial to a host of its choosing, and `target_port` decides the port. That is the case on any platform without a mechanism, on macOS without root, and for a connection that reached the listener without a redirect in front of it. The log line says which source decided, so you can tell which of the two you are in. If a destination that cannot be influenced by the client matters for your deployment, use [reverse mode](#reverse-mode) — it declares the destination and consults nothing the client sent, on every platform and without root.

Everything else behaves exactly as on the proxy path: flows are captured into the same project, scope and the Sandbox apply, and the passthrough list is honoured. A TLS connection with **no SNI** is now served when the kernel supplies an address (gori mints a leaf for that IP), and dropped, logged once, only when there is no address either. A host the Sandbox rules out is still dropped outright — there is no way to answer a TLS client with a 403.

#### Reverse mode

A reverse listener also serves clients that believe they are talking to the origin, but the origin is **declared** rather than derived. gori answers as if it were the origin and forwards to `origin`.

```json
{ "host": "0.0.0.0", "port": 9000, "mode": "reverse", "origin": "https://api.example.com" }
```

This is the mode for a client that cannot be pointed at a proxy at all: a mobile app with no proxy setting, a CI step, an appliance. There is no `CONNECT`, no proxy configuration, and no firewall rule — the client just has to reach the socket.

Because the destination is configuration rather than derivation, it has none of transparent mode's failure modes. A request with no `Host` header is served. A `Host` naming somewhere else is served, and forwarded to `origin` regardless — the header is not consulted for routing.

`origin` must be an absolute URL with an `http` or `https` scheme; the port defaults from the scheme. A bare `api.example.com:8443` is refused rather than assumed `http`, because the assumption would silently decide whether gori speaks TLS to your origin. An origin pointing back at gori's own primary bind or at another listener is refused when you save, since that is a forwarding loop you can create by typing.

**TLS.** The listener terminates TLS when the client opens with one, using a leaf minted for the **configured** origin host, never for the client's SNI — reading the SNI would reintroduce exactly the derivation this mode removes. In practice the client must reach the socket under the origin's name, which is the ordinary reverse-proxy arrangement: a hosts entry or a DNS record. The origin leg follows the origin's own scheme, so `"origin": "http://127.0.0.1:3000"` gives you TLS in front of a cleartext backend.

**`rewrite_host`.** A conventional reverse proxy rewrites `Host` to the upstream's name. gori does not do that implicitly: rewriting is a mutation of your client's bytes on the live path, so it is opt-in. With `rewrite_host: false` (the default) the client's `Host` reaches the origin byte for byte. With it on, the `Host` is replaced with the origin's authority — one field, with the rest of the head untouched, and a duplicated `Host` collapsed to one.

Scope works as everywhere else: the Sandbox and `exclude` rules apply unchanged, gated per request and before the TLS handshake. The `include` list stays a lens over captured traffic rather than a gate here, because a reverse listener forwards what a client sent and never originates a request of its own.

#### SOCKS5 mode

A SOCKS5 listener (RFC 1928) takes its destination from the client in a handshake, then intercepts everything that follows — TLS, HTTP/2 prior knowledge, or plain HTTP, routed on its first bytes the way the other listeners route theirs. (One difference, deliberate: the TLS test here reads two bytes rather than one, because a SOCKS listener is where a non-HTTP protocol is most likely to arrive — `ssh -D` is what most people point at one — and a payload whose first octet happens to be `0x16` should not be fed to a TLS handshake it cannot finish.)

```json
{ "host": "127.0.0.1", "port": 1080, "mode": "socks5" }
```

This is the mode for a client that *can* be pointed at a proxy, just not at an HTTP one: `ALL_PROXY=socks5://127.0.0.1:1080`, a runtime whose only proxy setting is SOCKS, a tool that speaks SOCKS and nothing else. gori already speaks the other end of the same protocol — an [`upstream_rules`](#upstream_rules) entry with `"kind": "socks5"` reaches an origin *through* somebody else's SOCKS proxy — so the word appears twice in this file, pointing opposite ways. This one is inbound.

The destination arrives **declared**, which is what it has over transparent mode: no kernel redirect rule, and nothing has to recover the destination from an SNI or a `Host` header. On a cleartext connection a request whose `Host` names somewhere else is still sent where the handshake said, and the handshake's authority is what History records, while the client's own header is forwarded byte for byte. On a TLS connection the SNI supplies the *name* instead — the leaf is minted for it, the passthrough list and the Sandbox match on it, and it is what History shows — while the connection is dialled at the destination the handshake declared: the same split [transparent mode](#transparent-mode) has between the name and the address. A ClientHello carrying no SNI falls back to the declared destination for both.

**NO-AUTH only.** A client that offers no method gori serves is told so with RFC 1928's `0xFF` and closed. The forward-proxy listener beside it has no authentication either, and a SOCKS listener asking for a password would be claiming an access control the rest of the process does not have.

**CONNECT only.** `BIND` and `UDP ASSOCIATE` are refused with reply code `0x07` rather than by hanging up, so the client reports the real cause. BIND needs a socket opened on the client's behalf and UDP ASSOCIATE is a datagram relay, and every gori listener is a TCP socket — the same reason [HTTP/3 is out of reach](#strip-alt-svc).

Two things are checked before gori answers `succeeded`, and each is refused with reply code `0x02` ("not allowed by ruleset") rather than a dropped connection: a destination naming any socket gori is serving — this listener, a sibling, or the primary bind — which would dial this proxy through itself, and a host the Sandbox excludes. Both gates exist on the forward proxy's `CONNECT` path for the same reason: on those two listeners the *client* names the destination outright, where a transparent listener is steered by the kernel first and only falls back to what the client said.

Every refusal is recorded in the project as a flow carrying its reason, too. A client pointed at the wrong port, one asking for UDP, one that opened with something that is not SOCKS at all — each shows up in History instead of being a connection that closed without saying why.

### upstream_rules

`network.upstream_proxy` is the catch-all route. Bare `host:port` and `http://…` use a plaintext HTTP CONNECT proxy (default port `8080`). `http+tls://…` uses the same CONNECT protocol with the hop to the proxy wrapped in TLS (default port `443`). `socks5://…` resolves destination names **locally** and sends an address literal; `socks5h://…` sends hostname targets as `ATYP DOMAIN` so the **proxy** resolves them. Both SOCKS forms default to port 1080. URI credentials are refused—configure direct credentials in the Project tab, or use an `upstream_rules` entry with `username` and `password_env`.

#### `https://` means the plaintext proxy, not TLS

`https://proxy:3128` has meant *a plaintext HTTP CONNECT proxy* since before gori could speak TLS to a proxy at all, and it still does. It was not reclaimed: every existing `settings.json` carrying one means the plaintext form, and redefining the scheme would have moved that egress onto a handshake the proxy may not offer — on upgrade, with no edit. So the spelling is **accepted unchanged and reported**, never reinterpreted:

- gori prints one startup warning per configured `https://` upstream, naming both fixes.
- Write `http://` for the same behaviour without the ambiguity, or `http+tls://` to actually encrypt the hop.
- Editing the proxy fields in **settings:network** (or the **Project settings** card) rewrites the value canonically as `http://…` on save. An untouched value is left byte-for-byte as written.

#### TLS to the proxy (`http+tls`)

The `CONNECT` request line — which names the origin you are reaching for — and the `Proxy-Authorization` header are written **inside** the TLS session, never in front of it. Nothing about the request is sent before the handshake completes.

The proxy leg is verified on its **own** hostname: SNI and the checked certificate name are the proxy address you configured, never the origin's, and never a [host override](#hostname_overrides) (overrides apply to the origin leg only). It is governed by `network.upstream_proxy_ca` and `network.upstream_proxy_insecure` — **not** by `verify_upstream` / `--insecure-upstream`, which describe the origin. A relaxed origin policy for one broken target does not stop authenticating the proxy that carries the whole session, and a rejected proxy certificate says so in those terms rather than offering `--insecure-upstream` as a fix.

An `https://` origin reached through an `http+tls` proxy is TLS inside TLS: the origin handshake runs over the tunnel, so the origin's certificate is still verified end to end under its own policy.

All networking owned by gori uses this routing decision, including capture/replay/scan engines, the updater, and OAST provider traffic. A configured proxy that is malformed, unreachable, or refuses a tunnel fails closed; gori does not retry the destination directly. A blank project pin and a matching `direct` rule remain explicit operator exceptions.

Per-destination upstream routing can say "route `*.corp.internal` through the internal proxy, everything else direct", carry credentials, and choose different proxies.

Rules are **ordered** and the **first match wins**, so specific rules go above general ones. Edit them with `gori settings --edit`.

```json
{
  "upstream_rules": [
    { "host": "intranet.corp.internal", "kind": "direct" },
    {
      "host": "*.corp.internal",
      "kind": "http",
      "addr": "proxy.corp.internal:3128",
      "username": "alice",
      "password_env": "CORP_PROXY_PASS"
    },
    { "host": "*.partner.example", "kind": "http+tls", "addr": "proxy.partner.example:443" },
    { "host": "*.onion", "kind": "socks5h", "addr": "127.0.0.1:9050" }
  ]
}
```

| Key | Type | Description |
|-----|------|-------------|
| `host` | string | Host pattern, same dialect as scope `host` rules: `corp.internal` covers that host and its subdomains, `*.corp.internal` is a glob, `*` is the catch-all. Case-insensitive |
| `kind` | string | `direct`, `http`, `http+tls` (HTTP CONNECT over TLS), `socks5` (local DNS), or `socks5h` (proxy DNS). An unknown kind drops the rule rather than being treated as `direct`, which would quietly disable an intended proxy |
| `addr` | string | Proxy `host:port`. Port defaults to `8080` for `http`, `443` for `http+tls`, and `1080` for either SOCKS kind. Must be absent for `direct` |
| `username` | string | Optional. Sent as HTTP Basic (RFC 7617) for `http` and `http+tls`, or via the RFC 1929 exchange for either SOCKS kind |
| `password_env` | string | Optional. The **name** of an OS environment variable holding the password |

**Global-rule passwords are never stored in `settings.json`.** Only the username and the environment-variable *name* are written; the password is read from the OS environment at dial time, so `export CORP_PROXY_PASS=…` takes effect without a restart. gori's own `env` section is deliberately not used for this — those variables live in `settings.json` in plaintext, which would put the secret in the file by another route and defeat sharing or exporting a config (see [#439](https://github.com/hahwul/gori/issues/439)). A `password_env` containing `$` is rejected: it holds a variable name, not a value. Direct credentials entered in Project settings have different storage described under [Per-Project Overrides](#per-project-overrides).

`network.upstream_proxy_ca` and `network.upstream_proxy_insecure` are one policy for **every** `http+tls` hop, whether it came from a rule, the scalar, or a project pin. There is no per-rule TLS field yet; add one when a second TLS proxy with a different trust anchor forces it.

The scalar and rules use the same DNS distinction: `socks5` performs the destination lookup on the gori host, while `socks5h` delegates it to the proxy. Use `socks5h` for Tor, split DNS, or a jump host that can resolve names unavailable locally. A failed local lookup stops before connecting to the proxy and never falls back to a direct origin connection.

Precedence, highest first:

| Priority | Source |
|----------|--------|
| 1 (highest) | Project `net.upstream_proxy` — an explicit per-project pin, which bypasses the table wholesale |
| 2 | `upstream_rules`, first host match |
| 3 | `network.upstream_proxy` — the implicit catch-all |
| 4 (lowest) | Direct |

For an open project, **Destination host** is evaluated before this table. `*` (the default)
leaves the precedence above unchanged; a non-matching destination goes direct without falling
through to a global rule or scalar proxy.

A rule is matched against the **original** hostname, before any [host override](#hostname_overrides) is applied — an override only changes which IP is dialled.

### outbound_tls

Per-destination TLS policy for the connections gori **makes**: a client certificate to present, the protocol range / cipher list to negotiate with, and the shape of the ClientHello gori sends (its [TLS fingerprint](#tls-fingerprint)). Ordered, first match wins, same host-pattern dialect. Edit with `gori settings --edit`.

This is a separate table from [`upstream_rules`](#upstream_rules) on purpose. Both are keyed by destination host, but they answer different questions, and folding them together would make the common shape inexpressible — "everything through the corporate proxy, plus a client certificate for one host" would need the proxy address duplicated onto that host's row, because one first-match table can only apply a single row per host.

```json
{
  "outbound_tls": [
    {
      "host": "mtls.example.com",
      "client_cert": "/home/you/certs/client.crt.pem",
      "client_key": "/home/you/certs/client.key.pem"
    },
    {
      "host": "legacy-appliance.internal",
      "min_version": "tls1.0",
      "ciphers": "ALL:@SECLEVEL=0",
      "permissive": true
    }
  ]
}
```

| Key | Type | Description |
|-----|------|-------------|
| `host` | string | Host pattern, as in `upstream_rules`. `*` is the catch-all |
| `client_cert` | string | Path to a PEM certificate chain to present (mutual TLS) |
| `client_key` | string | Path to the matching PEM private key. Both halves are required, or neither |
| `min_version` | string | Lowest protocol to negotiate: `tls1.0`, `tls1.1`, `tls1.2`, `tls1.3`. Empty leaves the default |
| `max_version` | string | Highest protocol to negotiate, same values. Empty leaves the default |
| `ciphers` | string | OpenSSL cipher list for TLS 1.2 and below. Empty leaves the default |
| `permissive` | bool | Talk to broken/legacy servers: drops the OpenSSL security level to 0 and allows renegotiation |
| `preset` | string | A named browser approximation: `chrome`, `firefox`, `safari`, `curl`. See [TLS fingerprint](#tls-fingerprint) |
| `groups` | string | Named groups / curves and their order, e.g. `X25519:P-256:P-384`. Empty leaves the default |
| `sigalgs` | string | Signature algorithms and their order, e.g. `ecdsa_secp256r1_sha256:rsa_pss_rsae_sha256` |
| `ciphersuites` | string | The **TLS 1.3** suites, which `ciphers` cannot reach |
| `alpn` | array | Ordered ALPN list, e.g. `["h2", "http/1.1"]`. Only `h2` and `http/1.1` are allowed — gori has to be able to speak whatever the origin selects |
| `session_tickets` | bool | `false` drops the `session_ticket` extension from the hello. Omitted = OpenSSL's default (on) |
| `ocsp_stapling` | bool | `true` adds the `status_request` extension, which browsers send and stock OpenSSL does not. Omitted = off |

**Why `min_version` exists.** gori cannot reach a TLS 1.0/1.1-only appliance out of the box, and `verify_upstream: false` does not help — that turns off certificate *verification*, not protocol negotiation. Crystal's TLS client context disables TLS 1.0 and 1.1 in its constructor, so lowering the floor here is the only way. A legacy appliance usually needs `permissive: true` as well, because distributions build OpenSSL at a security level that rejects the old cipher suites outright.

**Why `max_version` exists.** A floor alone cannot choose a version. Against any origin that also speaks TLS 1.3 — which is every modern one — the handshake lands on 1.3 however low the floor is, so `min_version: "tls1.0"` never answered *"does this target still accept TLS 1.0?"*, and `ciphers` never applied either, because OpenSSL's cipher list governs TLS 1.2 and below only. Setting both bounds is what makes "negotiate TLS 1.2 with `AES128-SHA`" expressible:

```json
{ "host": "legacy.internal", "min_version": "tls1.2", "max_version": "tls1.2", "ciphers": "AES128-SHA", "permissive": true }
```

Pinning both to the same value offers exactly that one version, so a handshake failure is a real answer: the target does not accept it. A `min_version` above `max_version` is rejected at save time — that pair offers no version at all, and OpenSSL's error would name the origin rather than the settings file.

**Certificates are file paths, not inline material.** A private key does not belong in `settings.json`, which is shareable and exportable ([#439](https://github.com/hahwul/gori/issues/439)). A passphrase-protected key is rejected at save time: OpenSSL would prompt for the passphrase on the terminal the TUI owns, so gori would simply appear to hang. Decrypt it first with `openssl pkey -in key.pem -out plain.pem`.

The policy is looked up on the **dialled** host, not on an SNI override — a certificate and a protocol floor belong to the machine actually being talked to, whereas the Repeater's SNI field deliberately lies about the name for domain-fronting and vhost tests.

#### TLS fingerprint {#tls-fingerprint}

With gori in the loop, the ClientHello an origin sees is **gori's OpenSSL handshake, not the browser's**. Anti-bot stacks fingerprint that handshake as a JA3 or JA4 and start serving challenges or `403`s to traffic that was fine a minute ago — the everyday *"it works in the browser, it breaks through the proxy"*. The fields above are the knobs for it, and

```bash
gori settings tls-fingerprint
```

is how you check them: it prints the JA3/JA4 of the ClientHello gori really sends to each destination, built from the same TLS context a dial builds. OpenSSL only ever reports what got *negotiated*, so without that command none of these settings can be verified.

```json
{
  "outbound_tls": [
    { "host": "shop.example.com", "preset": "chrome" },
    {
      "host": "api.internal",
      "groups": "X25519:P-256",
      "sigalgs": "ecdsa_secp256r1_sha256:rsa_pss_rsae_sha256",
      "ciphersuites": "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384",
      "alpn": ["h2", "http/1.1"],
      "ocsp_stapling": true
    }
  ]
}
```

**Presets are approximations, and gori will not claim otherwise.** A preset fills in every *value-level* field a classifier reads — cipher list and order, TLS 1.3 suites, named groups, signature algorithms, the ALPN pair, and whether `session_ticket` / `status_request` appear at all. It does **not** reproduce a browser's JA3 byte for byte, and cannot:

- **Extension order** is OpenSSL's, and OpenSSL emits its own fixed order. JA3 hashes that order.
- **GREASE** ([RFC 8701](https://datatracker.ietf.org/doc/html/rfc8701)) placement is OpenSSL's. Both fingerprints strip GREASE values, but the positions a browser reserves for them are not the ones OpenSSL picks.
- **Post-quantum key shares** (`X25519MLKEM768`), which current Chrome and Firefox offer first, are deliberately left out of the presets: they exist only on OpenSSL 3.5+, and a preset that fails to apply on an older build is worse than one that is honestly incomplete. Add it to a rule's own `groups` where your build has it.
- **SHA-1 signature algorithms**, which Firefox and Safari still list last as legacy fallbacks, are left out for the same reason: Debian and Ubuntu ship OpenSSL with SHA-1 signatures disabled, and listing them would make the preset refuse to apply at all there. No modern origin selects one.

Compare the `JA4_r` lists the report prints, not the digests — that is where you see which field is still wrong. A byte-exact match needs a TLS stack with control over extension order and GREASE (BoringSSL, rustls, uTLS); that is [#822 phase 3](https://github.com/hahwul/gori/issues/822) and is not what these fields do.

A rule's own fields **override** the preset it names, so `{"preset": "chrome", "groups": "P-521"}` is Chrome's everything with your group list.

**ALPN and the two legs.** gori dials with different ALPN offers depending on what it is going to speak on that socket: `h2` on a decrypted tunnel, nothing at all on a leg it will speak HTTP/1.1 on (the plain forward-proxy dial, the Repeater, WebSocket). A configured `alpn` list is used as written on the first, and has `h2` **removed** on the second — an origin that selected `h2` there would leave gori writing HTTP/1.1 into an HTTP/2 connection. `gori settings tls-fingerprint` reports both legs for exactly this reason.

An invalid `groups`, `sigalgs`, `ciphersuites` or `alpn` value is checked by handing the string to the same OpenSSL that would consume it. This table has no in-app editor — you edit the JSON — so the check runs at **startup** and names the rule, the setting and the consequence, rather than leaving you with a handshake failure that reads like the origin's fault:

```
⚠ settings: outbound TLS `groups` is not a group list this OpenSSL accepts: X25519:P-257 — the rule for api.internal; TLS dials to that destination will fail
```

The same line appears as a notification in the TUI. A bad rule affects only its own destination; every other rule, and the rest of gori, still work.

**This table is per DESTINATION, and a fingerprint A/B is not.** "Does this endpoint answer differently as `chrome` than as `curl`?" is a question about one host, and editing a rule here between two sends changes the handshake for every other tab and background capture hitting that host at the same time. A Repeater tab (`␣T`) and a fuzz run (`--tls-preset`) can each name a fingerprint for themselves instead, resolved at dial time and leaving this table alone — see [per-send TLS fingerprints](/reference/cli/#per-send-tls-fingerprints). Such an override replaces the ClientHello shape only: the `client_cert`/`client_key`, `min_version`/`max_version` and `permissive` configured here still apply.

Inbound fingerprint *spoofing* (making the client's own handshake look like something else) is not in scope here; this section only shapes the connections gori makes.

### layout

Per-area TUI layout prefs (command palette → **Settings: Layout**). Omitted when both values are factory defaults.

```json
{
  "layout": {
    "history_preview": false,
    "probe_preview": false,
    "issues_preview": false,
    "history_list_order": "newest",
    "sitemap_expand_depth": -1
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `history_preview` | bool | `false` | History list page shows a bottom Req\|Res preview for the selected flow |
| `probe_preview` | bool | `false` | Probe list page shows a bottom summary of the selected issue |
| `issues_preview` | bool | `false` | Issues list page shows a bottom summary of the selected issue |
| `history_list_order` | string | `"newest"` | List sort: `"newest"` (newest at top) or `"oldest"` (oldest at top) |
| `sitemap_expand_depth` | integer | `-1` | How deep the Sitemap tree opens after reload: `-1` = all expanded; `0`-`3` = expand only nodes shallower than this depth |

### statusline

An opt-in extra row at the very bottom of the TUI (Preferences → **General** → **Statusline**). When enabled, gori runs a shell command on an interval and renders its stdout as that row. Think of it as a customizable status bar, inspired by Claude Code's status line. Disabled by default; the section is omitted from `settings.json` until you change it.

```json
{
  "statusline": {
    "enabled": true,
    "command": "printf 'proj:%s flows:%s' \"$(jq -r .project)\" \"$(jq -r .flows)\"",
    "interval": 3,
    "timeout": 10
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `false` | Whether the statusline row is shown |
| `command` | string | `""` | Shell command, run via `/bin/sh -c`. Its first line of stdout becomes the row. Blank means no row is reserved at all, even when `enabled` |
| `interval` | integer | `3` | Seconds between runs (minimum `1`) |
| `timeout` | integer | `10` | Seconds one run may take before it is killed (minimum `1`). May exceed `interval` |

The command's stdout is parsed for ANSI/SGR colour escapes (16-colour, 256-colour, and truecolor, plus bold/underline/etc.), so you can produce coloured segments. Only the first line is used; output is truncated to the terminal width. It never blocks the UI.

`timeout` is deliberately separate from `interval`. Runs never overlap — gori launches the next one only after the previous has finished — so a script slower than `interval` simply refreshes as fast as it can rather than being killed on every run. A run that does exceed `timeout` is terminated and the row reads `⋯ (timed out)`.

A command that fails without printing anything reports its exit status instead of leaving the row blank — `⋯ (exit 127)` for a command that was not found, `⋯ (killed)` for one a signal ended. A command that exits cleanly having printed nothing leaves the row empty, which is a legitimate thing for a script to do. stderr is discarded either way.

Edits take effect immediately: saving a new `command`, `interval` or `timeout` re-runs the command on the next frame instead of waiting out the current interval.

Each run receives a JSON context on stdin describing the live session, so scripts can display proxy state without querying gori:

```json
{
  "version": 1,
  "project": "acme",
  "capturing": true,
  "flows": 1234,
  "proxy": { "host": "127.0.0.1", "port": 8070, "addr": "127.0.0.1:8070" },
  "upstream": "",
  "upstream_rules": 0
}
```

| Field | Type | Description |
|-------|------|-------------|
| `version` | integer | Context schema version (currently `1`) |
| `project` | string | Active project name |
| `capturing` | bool | Whether the proxy is currently capturing |
| `flows` | integer | Number of captured flows |
| `proxy.host` / `proxy.port` / `proxy.addr` | string / integer / string | The address the proxy is actually listening on |
| `upstream` | string | The **catch-all** upstream proxy address/URI, or empty when connecting directly. A destination matched by an [upstream rule](#upstream_rules) routes elsewhere — this field does not reflect that |
| `upstream_rules` | integer | Number of [upstream rules](#upstream_rules) in effect. Non-zero means routing is per-destination and `upstream` alone does not describe where traffic goes |

### display

Message-body and chrome prefs (command palette → **Settings: Display**). Omitted when every value is a factory default.

```json
{
  "display": {
    "detail_pane": "request",
    "history_time_format": "absolute",
    "show_gutter": true,
    "wrap_lines": true,
    "preview_body_kib": 64,
    "resource_meter": true,
    "terminal_title": "project"
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `detail_pane` | string | `"request"` | Which pane a freshly-opened History flow shows first: `"request"` or `"response"` |
| `history_time_format` | string | `"absolute"` | History list time column: `"absolute"` (MM-DD HH:MM:SS) or `"relative"` (3s/5m/2h) |
| `show_gutter` | bool | `true` | Line-number gutter on the message body views |
| `wrap_lines` | bool | `true` | Soft-wrap a line too wide for a message pane onto continuation rows (the gutter numbers the first). `false` draws one row per line and scrolls sideways instead, following the caret |
| `preview_body_kib` | integer | `64` | How many body bytes the History list preview reads (display only, not the capture limit) |
| `resource_meter` | bool | `true` | CPU/memory readout for gori's own process, at the far right of the bottom bar |
| `terminal_title` | string | `"project"` | Terminal window title: `"project"` → `Gori - <project> - <tab>`, `"tab"` → `Gori - <tab>`, `"off"` → gori never writes the title (leave it to your shell or tmux) |

### hostname_overrides

Global dial map (project-level overrides win on collision). Same idea as `/etc/hosts`:

```json
{
  "hostname_overrides": [
    { "host": "api.prod.internal", "ip": "10.0.0.42" },
    { "host": "api.prod.example", "ip": "127.0.0.1:8443" },
    { "host": "v6.internal", "ip": "[::1]:8443" }
  ]
}
```

The value is an IP literal, optionally with a **port**: `IP`, `IP:PORT`, or `[v6]:PORT`. A bare IP keeps the port from the request URL, which is what an entry written before ports were supported has always meant. Adding a port is the one thing this goes beyond `/etc/hosts` on, and deliberately — `/etc/hosts` is read by a resolver that has no port to change, whereas gori is the thing making the connection. Pointing `https://api.prod.example/` at a local build on `127.0.0.1:8443` is otherwise inexpressible when the traffic comes from a real browser or a mobile app, because gori is not the one writing the URL.

SNI, the certificate hostname and the `Host` header still keep the **original** name; only the TCP connect target moves.

Edit from Preferences → **Network & Tabs** → **Network** → **Hostname overrides**, or the Project tab for per-project entries. See [Proxy & History](/guide/proxy/#host-overrides).

### env

Tokens like `$TOKEN` expand at send time in Repeater, Fuzzer, Miner, Intercept, CLI, and MCP:

```json
{
  "env": {
    "prefix": "$",
    "vars": [
      { "key": "TOKEN", "value": "eyJhbGciOi…" }
    ]
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `prefix` | string | `"$"` | Token prefix (`$KEY`) |
| `vars` | array | `[]` | Global key/value pairs; project vars (Project tab → ENV) override on collision |

See [Environment Variables](/guide/repeater-and-fuzzer/#environment-variables).

### general

Preferences → **General** → **General**:

```json
{
  "general": {
    "clipboard_osc52": true,
    "confirm_quit": false,
    "repeater_record_history": true
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `clipboard_osc52` | bool | `true` | Copy through the OSC 52 terminal escape, so `y` reaches your local clipboard over SSH |
| `confirm_quit` | bool | `false` | Ask before quitting |
| `repeater_record_history` | bool | `true` | Write every **TUI** Repeater send into History as a flow (SRC column: `RPTR`). `gori run repeater send --record-history` and MCP `send_request{record_history}` keep their own per-call arguments |

### notifications

How background jobs (Miner, Fuzzer, Probe, Discover) announce their results. Preferences → **General** → **Notifications**:

```json
{
  "notifications": {
    "bell": false,
    "toast": true,
    "retention": 100
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `bell` | bool | `false` | Ring the terminal bell when a background job produces a result |
| `toast` | bool | `true` | Show a transient toast for the same events |
| `retention` | integer | `100` | How many notifications the notification center keeps |

### probe

```json
{
  "probe": {
    "active_notify": "when-found"
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `active_notify` | string | `"when-found"` | When an active scan notifies: `"when-found"`, `"always"`, or `"off"` |

### discover

Saved defaults for a Discover run. Written only once you save the discover options, so the section is absent until then:

```json
{
  "discover": {
    "containment": "scope-aware",
    "max_depth": 4,
    "concurrency": 20,
    "spider": true,
    "bruteforce": true,
    "extensions": false
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `containment` | string | `"scope-aware"` | How far a run may wander: `"same-origin"`, `"scope-aware"`, or `"host+subdomains"` |
| `max_depth` | integer | `4` | Spider depth cap |
| `concurrency` | integer | `20` | Parallel requests |
| `spider` | bool | `true` | Follow links found in responses |
| `bruteforce` | bool | `true` | Brute-force paths from the wordlist |
| `extensions` | bool | `false` | Also probe extension variants of each candidate |

### mine

Saved Param Miner defaults, written only once you save the mine options:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `locations` | array | `[]` | Where to inject: `query`, `form`, `multipart`, `json`, `headers`, `cookies`. Empty means auto-detect per request |
| `concurrency` | integer | `10` | Parallel requests |
| `notify` | string | `"when-found"` | `"when-found"`, `"always"`, or `"off"` |

### scan_rules

Your own Probe match rules, global across every project. Project-scoped rules live in the project database instead. Edit them in Probe → **Rules** → CUSTOM:

```json
{
  "scan_rules": [
    {
      "id": "a1b2c3d4",
      "title": "Internal hostname leak",
      "description": "Build-server hostname in a response body",
      "side": "response",
      "region": "body",
      "kind": "regex",
      "pattern": "build-\\d+\\.corp\\.internal",
      "severity": "medium",
      "enabled": true
    }
  ]
}
```

| Key | Type | Description |
|-----|------|-------------|
| `id` | string | Random hex token assigned at creation |
| `title` | string | Finding title |
| `description` | string | Shown in the finding detail |
| `side` | string | `request` or `response` |
| `region` | string | `whole`, `header`, or `body` |
| `kind` | string | `string`, `regex`, or `exec` (an argv — see [Process hooks](/guide/scripting/#process-hooks)) |
| `pattern` | string | Literal or regex to match, or the command to run when `kind` is `exec` |
| `severity` | string | `info`, `low`, `medium`, `high`, or `critical` |
| `enabled` | bool | Whether the rule runs |

Parsing is tolerant. An entry missing `id`, `title`, or `pattern` is dropped, and an out-of-range `side` / `region` / `kind` / `severity` falls back to the safest value rather than failing the load.

### retention

How much captured history a project keeps.

```json
{
  "retention": {
    "max_flows": 100000
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `max_flows` | integer | `100000` | Keep at most this many newest flows per project; the oldest are dropped once the cap is passed. `0` = unlimited |

Retention is **not new** — gori has always swept old flows so a project database plateaus instead of growing forever. What this section adds is the ability to see and change the cap, which was previously a compile-time constant. The default is the number that was already in force, so nothing changes until you edit it.

The sweep runs on the capture path, amortized over every few thousand inserts, and cascades to a pruned flow's WebSocket messages and orphaned HTTP/2 frames. It writes one line to the log whenever it drops rows, so a flow that disappeared has a traceable reason rather than looking like a bug.

Raising the cap takes effect on the next project open. Lowering it does not immediately reclaim disk: pruning frees pages for reuse inside the database file but does not shrink the file, so on-disk size only drops after a **Compress** from the project picker, which runs `VACUUM`.

Surfaces that do not own capture never prune, whatever the cap says: `gori mcp`'s store, a project opened only to count its objects for a delete preview, and a freshly created project.

### oast_providers

OAST providers defined once and reusable across every project. Project-scoped providers live in the project database instead; these are the global library, edited in Preferences → **OAST providers**.

```json
{
  "oast_providers": [
    {
      "id": "3f9a2c11",
      "name": "team interactsh",
      "kind": "interactsh",
      "host": "oast.example.com",
      "token": "…",
      "enabled": true
    }
  ]
}
```

| Key | Type | Description |
|-----|------|-------------|
| `id` | string | Random hex token assigned on creation. Do not hand-edit |
| `name` | string | Label shown in the OAST tab |
| `kind` | string | Provider type, e.g. `interactsh` |
| `host` | string | Provider host |
| `token` | string | Optional auth token for the provider |
| `enabled` | bool | Whether the provider is selectable (default `true`) |

The section is omitted entirely until you add a provider. Entries missing `id`, `name`, `kind`, or `host` are dropped on load.

### update

The startup update check behind the project picker's one-line "update available" notice. This is the only automatic outbound call gori makes; `gori update` stays the explicit install path.

```json
{
  "update": {
    "check_enabled": true,
    "notified_version": "0.2.0",
    "latest_seen": "0.2.0",
    "checked_at": 1753600000
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `check_enabled` | bool | `true` | Set `false` to skip the probe entirely |
| `notified_version` | string | `""` | Latest version already surfaced, so the notice shows once per release |
| `latest_seen` | string | `""` | Last version seen from the release feed |
| `checked_at` | integer | `0` | Unix seconds of the last successful check. Caches the result for a day |

The last three are state gori maintains; only `check_enabled` is meant to be edited. The whole section is omitted on a default install.

### fuzzer

Wordlist paths remembered by the Fuzzer's Payload overlay. Scratch state, not project data.

```json
{
  "fuzzer": {
    "recent_wordlists": ["/usr/share/wordlists/params.txt"],
    "favorite_wordlists": ["/home/me/lists/api.txt"]
  }
}
```

| Key | Type | Description |
|-----|------|-------------|
| `recent_wordlists` | array | Most-recently-applied wordlist paths, newest first, capped at 10 |
| `favorite_wordlists` | array | Paths starred in the Path field, offered ahead of the recents |

Omitted until you apply or star a wordlist.

### Other sections

| Section | Description |
|---------|-------------|
| `theme` | Active theme name (default `goridark`). See the [Themes guide](/guide/themes/) |
| `mouse` | Mouse support toggle |
| `mouse_drag` | What releasing a drag does: `select` (default) or `copy` |
| `pretty_bodies` | Pretty-print JSON/XML/etc. bodies in the detail view |
| `editor` | External editor `command` and Markdown handling |
| `tabs` | Which TUI tabs are shown/hidden |
| `hostname_overrides` | Global host → IP dial map. See [hostname_overrides](#hostname_overrides) above |
| `env` | Env-token prefix and global values. See [env](#env) above |
| `hotkeys` | Keybinding overrides (`os` layer + `command_modifier` + `bindings`). See the [Hotkeys guide](/guide/hotkeys/) |
| `hooks` | External process hooks: `timeout_secs` (default 5, clamped 1-60) is the wall-clock budget one hook run gets at every seam. See [Process hooks](/guide/scripting/#process-hooks) |
| `decoder` | Named Decoder chain specs, shared by every project and callable as a chain step by name (open sub-tabs live in the project database) |
| `rewriter` | GLOBAL Match & Replace rules — applied in every project, each with a default on/off state a project can override. See [Global and project rules](/guide/proxy/#global-and-project-rules) |
| `colormarker` | GLOBAL History row-colour rules — the same global/project split as `rewriter`. Display only: a colour rule never modifies traffic. See [run colormarker](/reference/cli/#run-colormarker) |
| `mine` | Saved Param Miner defaults. See [mine](#mine) above |
| `saved_views` | The GLOBAL History **views** library — named QL queries applied as a lens, with the same global/project split `rewriter` has. See [run views](/reference/cli/#run-views) |
| `companion` | Miss Ring, the mascot: `enabled` (off by default), `placement` (`body` \| `bar`), `motion` (`lively` \| `calm` \| `still`) and `notices`. See the [Settings guide](/guide/settings/) |
| `layout` | History / Probe / Issues previews + Sitemap expand depth. See [layout](#layout) above |
| `statusline` | Bottom status row that runs a command on an interval. See [statusline](#statusline) above |
| `display` | Default detail pane, list time format, line-number gutter, `wrap_lines` (soft-wrap long lines, on by default), preview body cap, `resource_meter` (the CPU/memory readout at the far right of the bottom bar, on by default), and `terminal_title` |

## Per-Project Overrides

A project can pin its own network settings without editing the global file. These are stored in the project database (keys `net.bind_host`, `net.bind_port`, `net.upstream_proxy`, `net.upstream_destination_host`, `net.upstream_auth`, `net.connect_timeout_secs`, `net.io_timeout_secs`, `net.capture_max_mib`) and edited from the **Project** tab's **Project settings** sub-tab.

**Destination host** limits proxy routing to one case-insensitive host pattern. `*` is the default and makes every destination eligible; `example.com` covers that host and its subdomains, while `*.example.com` covers subdomains only. Domain, IPv4, IPv6, and `*`-based IP patterns are accepted. A non-match always goes direct and does not fall through to `upstream_rules` or `network.upstream_proxy`. This gate applies to every gori-owned dial while the project is active, including capture, replay, scanners, the updater, and OAST traffic.

To authenticate, choose a **Proxy protocol**, enter the **Proxy host** and **Proxy port**, turn **Proxy auth** on, then enter **Username** and **Password**. **SOCKS5** resolves destination names locally; **SOCKS5H** resolves them at the proxy. HTTP uses Basic authentication, while either SOCKS protocol uses RFC 1929 username/password authentication. NTLM is not supported. Turning authentication on always pins the displayed upstream address to the project—even when it was inherited from the global setting—so the credentials cannot later follow a changed global route or a destination rule.

The password is visible while the **Password** row is focused for editing and masked again when focus leaves. It is stored as plaintext inside the project's owner-only (`0600`) SQLite database, alongside captured engagement data that may already contain credentials. Use a global `upstream_rules` entry with `password_env` instead when the secret must not be stored in a project. For a matching destination, a malformed or orphaned project auth value fails closed before an origin connection.

The timeout and capture-limit keys are engagement properties rather than machine ones: a slow internal appliance needs its own idle timeout, and one target returning very large responses needs its own capture cap — raising either globally would tax every other project.

**Which surfaces apply which keys.** The two bind keys only mean something where gori opens a listening socket; all other keys, including proxy authentication, apply wherever gori dials out or stores a body.

| Surface | `bind_host` / `bind_port` | upstream / destination / auth / timeouts / capture limit |
|---------|---------------------------|-----------------------------------------------------------------------------------|
| TUI (`gori`) | applied — the proxy listens on the pinned address | applied |
| `gori run capture` | applied — the one headless subcommand that listens (the pin wins over `--listen`/`--port`) | applied |
| every other `gori run` subcommand | not applied — nothing binds | applied |
| `gori mcp` | not applied — the server never listens | applied |

**Effective bind / upstream** for an open project:

| Priority | Source |
|----------|--------|
| 1 (highest) | Project DB `net.bind_host` / `net.bind_port` / `net.upstream_proxy` / `net.upstream_destination_host` / `net.upstream_auth` / timeouts / capture limit when set |
| 2 | CLI `--listen` / `--port` (process-only override of the global layer) |
| 3 | `settings.json` `network.*` |
| 4 (lowest) | Factory defaults `127.0.0.1:8070` / direct |

Saving a Project-tab field that equals the current global value deletes that KV key, so the project keeps inheriting future global edits instead of freezing a duplicate. **Destination host** has no global counterpart; saving its default `*` deletes its project key.

## Projects & Database

Each project keeps at most `retention.max_flows` flows (100,000 by default — see [retention](#retention)); older ones are pruned so the file plateaus. Each project is a SQLite database (via `crystal-db` / `crystal-sqlite3`) holding flows, WebSocket messages, scope rules, issues, match rules, HTTP/2 frames, repeater and fuzz sessions, host overrides, sitemap tags, miner sessions, and Probe issues, plus a full-text index over flow bodies. Stored request/response bodies are capped at 2 MiB; larger bodies are truncated in the database, but their true wire size is still recorded. Serve any project's database directly with `--db PATH`, or select a named project with `--project NAME`.
