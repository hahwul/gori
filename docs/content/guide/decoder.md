+++
title = "Decoder"
description = "Encode, decode, hash, and transform data in a multi-step pipeline inside the TUI."
+++

The **Decoder** tab is a scratch workbench for encoding, decoding, hashing, and transforming data. Paste input, build a chain of converters, and read the intermediate and final results.

<figure class="tui-shot">
  <img src="/images/tui/decoder.svg" alt="gori Decoder tab with INPUT, CHAIN, PIPELINE and OUTPUT panes running a base64-encode then upper chain, showing each step's intermediate result">
  <figcaption>The <strong>Decoder</strong> workbench: an input, a chain of converters, and the per-step pipeline with the final output below.</figcaption>
</figure>

## Layout

Four cards stack top to bottom:

| Pane | Role |
|------|------|
| **INPUT** | Source text (editable) |
| **CHAIN** | Pipeline spec: converter names separated by `|`, `>`, or `,` (all equivalent) |
| **PIPELINE** | One row per step with its intermediate output |
| **OUTPUT** | Final result (text / hex / base64 display modes) |

You can keep several conversions open as **sub-tabs** (new, rename, duplicate, close from the space menu).

## Building a Chain

Type converter names on the CHAIN line. Steps run left to right:

```text
url-decode | base64-decode | jwt-decode
hex-encode | upper
gzip-decompress | json-unescape
```

Aliases work the same as the primary name (`b64` → `base64-encode`, `url` → `url-encode`, and so on). Autocomplete helps when the name is fuzzy.

Save a chain under a name (**Save chain by name** from the space menu) and reload it later. Defaults also persist under the `decoder` section of settings.

## Converters

| Category | Examples |
|----------|----------|
| **Encoding** | `base64-encode` / `base64-decode`, `base64url-encode`, `url-encode` / `url-decode`, `hex-encode` / `hex-decode`, `base32`, `ascii85`, `base58` |
| **Compression** | `gzip-compress` / `gzip-decompress`, `zlib-compress` / `zlib-decompress` |
| **Token** | `jwt-decode` (header + payload; signature shown, not verified) |
| **Hash** | `md5`, `sha1`, `sha256`, `sha512` |
| **Escape** | `html-escape` / `html-unescape`, `json-escape` / `json-unescape`, `unicode-escape` / `unicode-unescape` |
| **Text** | `rot13`, `upper`, `lower`, `reverse` |

OUTPUT can cycle display modes (text → hex → base64) for binary results. Copy with `y` in READ mode, or use the space menu.

## When to Use It

- Decode a JWT or nested Base64 blob from History without mutating the flow
- Build the same transform you'll apply as a Fuzzer payload processor
- Quickly hash or URL-encode values while writing Repeater requests

Decoder does not send network traffic; it's pure local transformation.

## Next Steps

- [Repeater & Fuzzer](/guide/repeater-and-fuzzer/): payload processors use similar encode/hash steps
- [Proxy & History](/guide/proxy/): JWT / SAML / GraphQL are also decoded inline on captured flows
- [Hotkeys](/guide/hotkeys/): rebind Decoder-scoped actions
