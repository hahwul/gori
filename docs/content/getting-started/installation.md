+++
title = "Installation"
description = "Build gori from source with Crystal."
+++

gori is written in [Crystal](https://crystal-lang.org/) and is installed by building from source.

## Prerequisites

- **Crystal** `>= 1.20.2`
- **pkg-config**
- **Git**, to clone the repository

### System libraries (Brotli / Zstd)

By default gori links against native decoders so it can display HTTP bodies sent with `Content-Encoding: br` (Brotli) and `zstd`. Install them before building:

| Platform | Command |
|----------|---------|
| macOS (Homebrew) | `brew install brotli zstd` |
| Debian / Ubuntu | `sudo apt install libbrotli-dev libzstd-dev` |

## Build from Source

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

You're ready to capture traffic — head to the [Quick Start](/getting-started/quick-start/).