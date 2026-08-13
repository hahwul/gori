+++
title = "Decoder"
description = "Encode, decode, hash, and transform data in a multi-step pipeline inside the TUI."
weight = 40

[extra]
group = "Workbenches"
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

You can keep several conversions open as **sub-tabs** (new, rename, duplicate, close from the space menu). Open sub-tabs are saved with the **project**, so they come back the next time you open it and never follow you into another project.

## Building a Chain

Type converter names on the CHAIN line. Steps run left to right:

```text
url-decode | base64-decode | jwt-decode
hex-encode | upper
gzip-decompress | json-unescape
```

Aliases work the same as the primary name (`b64` → `base64-encode`, `url` → `url-encode`, and so on). Autocomplete helps when the name is fuzzy.

Save a chain under a name (**Save chain by name** from the space menu, or `Ctrl-S`) and reload it later. The save prompt starts from the sub-tab's own name, and saving under a name that already exists updates it. **Load a saved chain** (`Ctrl-O`) opens a picker over everything you've saved, showing each chain's spec next to its name, so you don't have to remember what you called it — type to filter, and `Ctrl-X` deletes the highlighted entry from the library. Both entries are in the space menu wherever you are in the tab: the sub-tab strip, the tab bar, or inside a pane.

Named chains live under the `decoder` section of settings and are shared by every project — the chain is a recipe, while what you run through it stays with the project. The Rewriter draws the same line differently: its rules are themselves [global or project-scoped](/guide/proxy/#global-and-project-rules).

A saved name is also a **converter**: type it as a step and the whole saved spec runs in that position.

```
myenc > url-encode
```

That works everywhere gori accepts a chain, not only in this tab: the `Ctrl-Y` chain editor on a Repeater or Fuzzer `§…§` marker, `gori run decoder`, and the MCP `decode` tool. Autocomplete lists saved names next to the built-in converters, and `gori run decoder list` shows them with the category `saved`.

Saved chains can call each other. A recursive definition fails that step with a message instead of hanging, and a name a built-in already answers to (including its aliases) is refused when you save it, because the built-in has to keep winning: letting the library shadow `base64-decode` would change what every spec in every project already means.

## Converters

| Category | Examples |
|----------|----------|
| **Encoding** | `base64-encode` / `base64-decode`, `base64url-encode`, `url-encode` / `url-decode`, `hex-encode` / `hex-decode`, `base32`, `ascii85`, `base58`, `base36`, `base62`, `quoted-printable`, `punycode-encode` / `punycode-decode` |
| **Number bases** | `decimal-encode` / `decimal-decode`, `binary-encode` / `binary-decode`, `octal-encode` / `octal-decode` |
| **Compression** | `gzip-compress` / `gzip-decompress`, `zlib-compress` / `zlib-decompress`, `deflate-raw` / `inflate-raw` (headerless, RFC 1951) |
| **Token** | `jwt-decode` (header + payload; signature shown, not verified) |
| **Hash** | `md5`, `sha1`, `sha224`, `sha256`, `sha384`, `sha512`, `crc32` |
| **Escape** | `html-escape` / `html-unescape`, `json-escape` / `json-unescape`, `unicode-escape` / `unicode-unescape`, `xml-escape` / `xml-unescape`, `c-string-escape` / `c-string-unescape`, `shell-escape`, `powershell-escape` |
| **Text** | `rot13`, `rot47`, `upper`, `lower`, `reverse`, `homoglyph`, `typo` |

A few entries only go one way, and the chain will not undo them. `shell-escape` and `powershell-escape` wrap a value in a quoted literal. `homoglyph` swaps ASCII letters for Unicode lookalikes, and is partial: a letter with no established confusable is left alone. `typo` is a generator rather than a transform, emitting one near-miss variant per line, built from omissions, adjacent-character swaps, and QWERTY neighbour keys.

OUTPUT can cycle display modes (text → hex → base64) for binary results. Copy with `y` in READ mode, `Ctrl-Y` while editing INPUT in INS, or use the space menu.

## When to Use It

- Decode a JWT or nested Base64 blob from History without mutating the flow
- Build the same transform you'll apply as a Fuzzer payload processor
- Quickly hash or URL-encode values while writing Repeater requests

Decoder does not send network traffic; it's pure local transformation.

## Next Steps

- [Repeater & Fuzzer](/guide/repeater-and-fuzzer/): payload processors use similar encode/hash steps
- [Proxy & History](/guide/proxy/): JWT / SAML / GraphQL are also decoded inline on captured flows
- [Hotkeys](/guide/hotkeys/): rebind Decoder-scoped actions
