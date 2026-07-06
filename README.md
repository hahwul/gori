# 𝓰𝓸𝓻𝓲

TODO: Write a description here

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

TODO: Write usage instructions here

## Development

```bash
shards build          # release binary at bin/gori
shards run gori       # run without installing
```

If linking fails with undefined `BrotliDecoder*` symbols, `libbrotlidec` is missing
from your system or `pkg-config` cannot find it — install `brotli` (see above) or
use `-Dwithout_native_codecs`.

## Contributing

1. Fork it (<https://github.com/your-github-user/gori/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [hahwul](https://github.com/your-github-user) - creator and maintainer
