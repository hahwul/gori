+++
title = "Installation"
description = "Install gori via curl, Homebrew, the AUR, Docker, a pre-built binary, or from source."
+++

gori is written in [Crystal](https://crystal-lang.org/). Pick a pre-built channel below, or [build from source](#build-from-source) if none fits your platform. Every channel installs the same `gori` binary. Once it's on your `PATH`, jump to [Verify the Installation](#verify-the-installation).

## Quick install (curl)

macOS and Linux one-liner. Detects OS/arch, downloads the matching [GitHub Release](https://github.com/hahwul/gori/releases/latest) asset, and puts `gori` on your `PATH`:

```bash
curl -fsSL https://gori.hahwul.com/install.sh | bash
```

Installs under `/usr/local` when writable, otherwise `~/.local`. Override with `GORI_INSTALL_PREFIX`. After install, `gori update` self-updates the binary (or guides you through Homebrew / Snap / AUR when those channels own the install).

## Homebrew

Works on **macOS** (Apple Silicon & Intel) and **Linux** (x86_64 & arm64):

```bash
brew install hahwul/gori/gori
```

That is shorthand for tapping first, which you can also do explicitly:

```bash
brew tap hahwul/gori
brew install gori
```

The macOS bottle is a self-contained tarball with every linked dylib bundled next to the binary, and the Linux bottle is a static build. Neither pulls extra Homebrew dependencies.

## Arch Linux (AUR)

A binary package is published to the [AUR](https://aur.archlinux.org/packages/gori) for **x86_64**. Install it with your favorite AUR helper:

```bash
yay -S gori
# or
paru -S gori
```

## Docker

Multi-arch images (x86_64 & arm64) are published to the GitHub Container Registry as [`ghcr.io/hahwul/gori`](https://github.com/hahwul/gori/pkgs/container/gori).

The TUI needs a terminal, so run it interactively. Mount a volume at `/data` (that's `GORI_HOME` inside the container) so your settings and root CA survive restarts, and bind to `0.0.0.0` so the proxy is reachable from your host:

```bash
docker run --rm -it \
  -v gori:/data \
  -p 8070:8070 \
  ghcr.io/hahwul/gori --listen 0.0.0.0
```

> Without a mounted `/data` volume the root CA is regenerated on every run, and must be re-trusted each time. The default bind host is `127.0.0.1`, which is not reachable from outside the container, hence `--listen 0.0.0.0`.

Headless subcommands don't need a TTY:

```bash
docker run --rm    -v gori:/data ghcr.io/hahwul/gori run history
docker run --rm -i -v gori:/data ghcr.io/hahwul/gori mcp
```

## Pre-built Binary

Standalone binaries for macOS and Linux are attached to every [GitHub Release](https://github.com/hahwul/gori/releases/latest).

| Platform | Asset |
|----------|-------|
| Linux x86_64 | `gori-v*-linux-x86_64` |
| Linux arm64 | `gori-v*-linux-arm64` |
| macOS Apple Silicon | `gori-v*-osx-arm64.tar.gz` |
| macOS Intel | `gori-v*-osx-x86_64.tar.gz` |

### Linux

The Linux binaries are statically linked (musl) and self-contained. Download one, make it executable, and move it onto your `PATH`:

```bash
chmod +x gori-v*-linux-x86_64
sudo mv gori-v*-linux-x86_64 /usr/local/bin/gori
```

### macOS

The macOS archive is self-contained. It bundles every dependent dylib in a `lib/` folder next to the binary, which resolves them relative to itself. **Keep `gori` and `lib/` together.** Extract it into a stable location and link the binary onto your `PATH`:

```bash
tar xzf gori-v*-osx-arm64.tar.gz          # extracts `gori` + `lib/`
sudo mkdir -p /usr/local/opt/gori
sudo cp -R gori lib /usr/local/opt/gori/
sudo ln -sf /usr/local/opt/gori/gori /usr/local/bin/gori
```

> The binaries are ad-hoc signed. If Gatekeeper blocks the download, clear the quarantine flag: `xattr -dr com.apple.quarantine /usr/local/opt/gori`. Installing via [Homebrew](#homebrew) avoids this.

## Build from Source

### Prerequisites

- **Crystal** `>= 1.20.2`
- **pkg-config**
- **Git**, to clone the repository

#### System libraries (Brotli / Zstd)

By default gori links against native decoders so it can display HTTP bodies sent with `Content-Encoding: br` (Brotli) and `zstd`. Install them before building:

| Platform | Command |
|----------|---------|
| macOS (Homebrew) | `brew install brotli zstd` |
| Debian / Ubuntu | `sudo apt install libbrotli-dev libzstd-dev` |

### Build

```bash
git clone https://github.com/hahwul/gori
cd gori
shards build --release
```

The release binary is written to `bin/gori`. Move it somewhere on your `PATH`:

```bash
cp bin/gori /usr/local/bin/
```

### Building without Brotli / Zstd

If those libraries are unavailable, build without them. Gzip and deflate decoding (from the Crystal standard library) keep working; Brotli and Zstd bodies show a "decoder not built in" note instead of decoded text:

```bash
shards build --release -Dwithout_native_codecs
```

> If linking fails with undefined `BrotliDecoder*` symbols, `libbrotlidec` is missing or `pkg-config` cannot find it. Install `brotli` (see above) or use `-Dwithout_native_codecs`.

## Verify the Installation

```bash
gori --version
```

You should see `gori 0.1.0`.

## Run Without Installing

During development you can run directly from a checkout:

```bash
shards run gori
```

## Next Steps

You're ready to capture traffic. Head to the [Quick Start](/getting-started/quick-start/).
