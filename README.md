<div align="center">
  <br>
  <img src="docs/static/images/gori-wallpaper.jpg">
  <p>A fast, keyboard-driven HTTP intercepting proxy and web-hacking toolkit for the terminal.</p>
</div>
<p align="center">
<a href="https://github.com/hahwul/gori/blob/main/CONTRIBUTING.md">
<img src="https://img.shields.io/badge/CONTRIBUTIONS-WELCOME-000000?style=for-the-badge&labelColor=black"></a>
<a href="https://github.com/hahwul/gori/releases">
<img src="https://img.shields.io/github/v/release/hahwul/gori?style=for-the-badge&color=black&labelColor=black&logo=web"></a>
<a href="https://crystal-lang.org">
<img src="https://img.shields.io/badge/Crystal-000000?style=for-the-badge&logo=crystal&logoColor=white"></a>
</p>

**gori** (고리 — Korean for *ring, link, loop*) is a keyboard-driven HTTP/HTTPS intercepting
proxy and web-hacking workbench that runs entirely in your terminal. Point a browser or client
at it and gori sits in the loop between you and your target, recording every request and
response as a *flow*. From there it is your pentest workbench: intercept and edit traffic in
flight, replay and fuzz requests, mine hidden parameters, and scan for vulnerabilities —
across HTTP/1.1, HTTP/2, WebSocket, gRPC, and Server-Sent Events, with JWT / SAML / GraphQL
decoded inline.

Everything the TUI does is also a `gori run` subcommand and a Model Context Protocol (MCP)
tool, so scripts and AI agents can drive the same engagement.

> ⚠️ **Test only what you are authorized to.** gori is for penetration testing and security
> research against systems you own or have explicit permission to assess.

## Features

- **Intercepting proxy & History** — capture HTTP/1.1, HTTP/2, WebSocket, gRPC, and SSE; hold, edit, forward, or drop traffic in flight.
- **Replay & Fuzzer** — a request workbench (incl. WebSocket & gRPC) and an Intruder-style fuzzer with four attack modes.
- **Prism scanner & Param Miner** — passive and active vulnerability scanning plus hidden-parameter discovery, triaged into Findings.
- **Convert & Comparer** — a chained encode / decode / hash pipeline and side-by-side flow diffing.
- **Keyboard-first** — a command palette (`Ctrl-P`) and a context space menu (`Space`) reach every action; rebindable hotkeys and colour themes.
- **Headless & scriptable** — drive the same project from `gori run` or an MCP-connected agent.

## Installation

Requires [Crystal](https://crystal-lang.org/) `>= 1.20.2` and `pkg-config`.

### System libraries (Brotli / Zstd)

By default, gori links against native decoders for HTTP `Content-Encoding: br` and
`zstd` in the detail view. Install them before building:

| Platform | Command |
|----------|---------|
| macOS (Homebrew) | `brew install brotli zstd` |
| Debian / Ubuntu | `sudo apt install libbrotli-dev libzstd-dev` |

Then build:

```bash
shards build
```

If these libraries are unavailable, you can still build without them. Gzip and
deflate decoding (Crystal stdlib) continue to work; Brotli and Zstd bodies show a
"decoder not built in" note instead of decoded text:

```bash
shards build -Dwithout_native_codecs
```

## Usage

Start the proxy and open the TUI — no subcommand needed:

```bash
gori
```

The proxy listens on `127.0.0.1:8070` by default, and a short first-run wizard picks the bind
address and theme. To intercept HTTPS, trust gori's root CA — the quickest path is the
palette's **Open browser** (`Ctrl-P`), which launches a browser already trusted and proxied.
Captured traffic lands in **History**; press `Ctrl-P` for the command palette or `Space` for
context actions.

Choose a different bind address or port:

```bash
gori --listen 0.0.0.0 --port 8080
```

Run non-interactively, or expose gori to an agent:

```bash
gori run --help    # non-interactive subcommands over the same project
gori mcp           # Model Context Protocol server (stdio)
```

See the [documentation](docs/) for the full guide, or open the **Help** tab in the app.

## Development

```bash
shards build          # release binary at bin/gori
shards run gori       # run without installing
```

If linking fails with undefined `BrotliDecoder*` symbols, `libbrotlidec` is missing
from your system or `pkg-config` cannot find it — install `brotli` (see above) or
use `-Dwithout_native_codecs`.

## Contributing

1. Fork it (<https://github.com/hahwul/gori/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [hahwul](https://github.com/hahwul) - creator and maintainer
