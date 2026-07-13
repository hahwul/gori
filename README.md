<div align="center">
  <br>
  <img src="docs/static/images/gori-wallpaper.jpg">
  <p>Hack from the terminal.</p>
</div>
<p align="center">
<a href="https://github.com/hahwul/gori/blob/main/CONTRIBUTING.md">
<img src="https://img.shields.io/badge/CONTRIBUTIONS-WELCOME-000000?style=for-the-badge&labelColor=black"></a>
<a href="https://github.com/hahwul/gori/releases">
<img src="https://img.shields.io/github/v/release/hahwul/gori?style=for-the-badge&color=black&labelColor=black&logo=web"></a>
<a href="https://crystal-lang.org">
<img src="https://img.shields.io/badge/Crystal-000000?style=for-the-badge&logo=crystal&logoColor=white"></a>
</p>

<p align="center">
  <a href="#installation">Installation</a> •
  <a href="#usage">Usage</a> •
  <a href="docs/">Documentation</a> •
  <a href="#contributing">Contributing</a>
</p>

---

**gori** (고리 — Korean for *ring, link, loop*) sits in the loop between your client and its target,
capturing every request and response as a *flow* you can intercept, replay, fuzz, and scan across
HTTP/1.1, HTTP/2, WebSocket, gRPC, and SSE. Every action is also a `gori run` subcommand and an MCP
tool, so scripts and AI agents can drive the same engagement.

> ⚠️ **Test only what you are authorized to.** gori is for penetration testing and security
> research against systems you own or have explicit permission to assess.

<details>
<summary><strong>Features</strong></summary>

### Capture & Intercept
- Intercepting proxy for HTTP/1.1, HTTP/2, WebSocket, gRPC, and SSE
- Hold, edit, forward, or drop traffic in flight
- Searchable History of every flow, with a query language for filtering
- Scope rules, hostname overrides, and match & replace

### Replay, Fuzz & Convert
- Replay workbench for crafting and re-sending requests (incl. WebSocket & gRPC)
- Intruder-style Fuzzer with four attack modes
- Convert pipeline for chained encode / decode / hash
- Side-by-side Comparer for diffing two flows
- Inline JWT / SAML / GraphQL decoding, hex view, and pretty-printing

### Discover & Scan
- Prism passive & active vulnerability scanner
- Param Miner for hidden-parameter discovery
- Findings triage with Markdown / JSON export

### Keyboard-first Workflow
- Command palette (`Ctrl-P`) and context space menu (`Space`) reach every action
- Rebindable hotkeys and switchable colour themes
- Mouse support, multi-line editing, and go-to-line navigation

### Headless & Scriptable
- `gori run` mirrors every TUI action for non-interactive use
- MCP server (`gori mcp`) exposes the same engagement to AI agents

</details>

## Installation

### Quick install (macOS / Linux)

```bash
curl -fsSL https://gori.hahwul.com/install.sh | bash
```

Then update later with `gori update` (self-update for binary installs; package-manager guidance for Homebrew / Snap / AUR).

### Homebrew

```bash
brew tap hahwul/gori
brew install gori
```

### From source

Requires [Crystal](https://crystal-lang.org/) `>= 1.20.2` and `pkg-config`.

```bash
git clone https://github.com/hahwul/gori.git
cd gori
shards build --release
```

The binary is written to `bin/gori`.

> For system libraries (Brotli / Zstd), offline builds, and other options, see the
> [Installation guide](docs/content/getting-started/installation.md).

## Usage

Start the proxy and open the TUI — no subcommand needed:

```bash
gori
```

The proxy listens on `127.0.0.1:8070` by default, and a short first-run wizard picks the
**global default** bind and theme (projects can pin their own later). To intercept HTTPS, trust
gori's root CA — the quickest path is the palette's **Open browser** (`Ctrl-P`), which launches a
browser already trusted and proxied. Captured traffic lands in **History**; press `Ctrl-P` for the
command palette or `Space` for context actions.

```bash
gori --listen 0.0.0.0 --port 8080   # global bind for this run only (not persisted)
gori run --help                     # non-interactive subcommands over the same project
gori mcp                            # Model Context Protocol server (stdio)
```

See the [documentation](docs/) for the full guide, or open the **Help** tab in the app.

## Development

```bash
shards build          # release binary at bin/gori
shards run gori       # run without installing
```

If linking fails with undefined `BrotliDecoder*` symbols, `libbrotlidec` is missing or
`pkg-config` cannot find it — see the
[Installation guide](docs/content/getting-started/installation.md) for the system libraries and the
`-Dwithout_native_codecs` offline build.

## Contributing

1. Fork it (<https://github.com/hahwul/gori/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Open a Pull Request

## Contributors

- [hahwul](https://github.com/hahwul) — creator and maintainer

## Why "gori"?

gori (고리) is the Korean word for a **ring, link, or loop** — exactly where the tool sits: in the
loop between your client and its target, capturing and reshaping each request as it passes through.
*Sit in the loop.*
