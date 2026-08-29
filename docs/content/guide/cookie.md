+++
title = "Cookie"
description = "Decode, verify, crack, and re-sign Flask, Rack, and Django signed session cookies."
weight = 55

[extra]
group = "Workbenches"
+++

The **Cookie** tab is a workbench for framework signed session cookies — **Flask** (itsdangerous), **Rack**, and **Django**. Decode one into its parts, verify a candidate signing secret or brute-force it from a wordlist, then edit the session and re-sign it. It goes further than the [Decoder](/guide/decoder/)'s read-only `cookie-decode` / `flask-decode` / `rack-decode` / `django-decode` converters, which only show you the parts.

Select a cookie anywhere (a **History** detail pane, **Notes**, …) and `Space` → **Send to Cookie** to seed a new workbench sub-tab with it. Sessions are ephemeral: nothing is written to disk. If you have hidden the tab, reveal it again from the tab-bar `⋯` menu, the command palette (`Ctrl-P` → **Go to Cookie**), or Preferences.

## Two Lenses

One session, two views, toggled with `Ctrl-T`. The top card of each lens carries the switch on its border — ` ^T:→FORGE ` on INPUT, ` ^T:→DECODE ` on PAYLOAD — and clicking it does the same thing as the key:

- **Decode**: paste a cookie into INPUT and its parts decode live in DECODED. **OPTIONS** pins how it is read — the format (`Ctrl-A` cycles `auto` / `flask` / `rack` / `django`; `auto` detects it from the punctuation), the Django HMAC algorithm, and a signing salt. **SECRET** holds a candidate key, and its verify verdict (`✓ verified` / `✗ bad key`) is live as you type; press `c` to crack it (see below).
- **Forge**: edit the session in PAYLOAD — a JSON object for Flask/Django, the opaque base64 value for Rack — set a SECRET, and the re-signed cookie appears live in OUTPUT.

Press `l` to load the payload currently decoded on the Decode side into the Forge editor, so you can tweak a value and re-sign in two moves. Copy any result with `y` (the forged cookie with `t`).

> Unlike the [JWT](/guide/jwt/) tab, which decodes but never verifies, Cookie has the secret path: a `✓` in SECRET means the key you typed actually signs this cookie. Forge genuinely re-signs with the secret, salt, and algorithm you give it.

## The Three Formats

| Format | Shape | Signature |
|--------|-------|-----------|
| **Flask** | `value.timestamp.signature` | itsdangerous HMAC (a leading `.` on the value marks zlib compression). |
| **Rack** | `base64--40-hex` | Base64-Marshal value + HMAC-SHA1. The value is opaque bytes, so Forge takes it as base64 rather than JSON. |
| **Django** | `value:timestamp:signature` | `django.core.signing`, a salted HMAC. A **session** cookie signs under a non-default salt — see below. |

## Cracking the Secret

The **SECRET** field doubles as the source for `c` (crack), so there is no separate prompt:

- a **path to a file** is read as a wordlist, one candidate per line;
- a **comma-separated list** (`admin,secret,changeme`) is tried inline;
- a **lone secret** is a one-element list — the same check as the live verify, said as a crack.

On a hit the field is replaced with the winning secret and the verdict flips to `✓`, ready to carry straight into the Forge lens.

> A Django **session** cookie (`django.contrib.sessions`) is signed under a non-default salt, so cracking it with the default salt fails. Set the salt in **OPTIONS** first — for a session cookie that is `django.contrib.sessions.backends.signed_cookies`. The same applies to `--salt` on the CLI.

## Headless

```bash
gori run cookie eyJ1c2Vy...                                  # decode (auto-detect, default)
gori run cookie eyJ1c2Vy... --verify --secret s3cret         # does this secret sign it?
gori run cookie eyJ1c2Vy... --crack --wordlist words.txt     # brute-force the secret
gori run cookie eyJ1c2Vy... --crack --secrets a,b,s3cret     # …or an inline list
gori run cookie --forge --type flask --payload '{"admin":true}' --secret s3cret
cat cookie.txt | gori run cookie                             # cookie from stdin
```

The cookie comes from the argument or stdin; there is no project or capture involved (it is pure local compute). `--type` pins the format (default: auto-detect), `--salt` and `--algorithm` thread the Django/Flask knobs, and `--format` is `text` or `json`. Flask/Django `--forge` takes a `--payload` JSON; Rack takes the opaque `--value`. See the [CLI Reference](/reference/cli/#run-cookie).

Over MCP, `cookie_decode` / `cookie_verify` / `cookie_crack` / `cookie_forge` are read tools available even under `--read-only`, since they touch no network or state.

## Next Steps

- [JWT](/guide/jwt/): the sibling workbench for JSON Web Tokens
- [Decoder](/guide/decoder/): decode a cookie inside a longer transform chain
- [Repeater & Fuzzer](/guide/repeater-and-fuzzer/): fire a forged cookie at the target
