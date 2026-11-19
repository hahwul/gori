+++
title = "Session Cookie Security"
description = "Decode, verify, crack, and re-sign Flask, Rack, and Django signed session cookies."
weight = 55

[extra]
group = "Workbenches"
+++

The **Cookie** tab is a workbench for framework signed session cookies: **Flask** (itsdangerous), **Rack**, and **Django**. Decode one into its parts, verify a candidate signing secret or brute-force it from a wordlist, then edit the session and re-sign it. The [Decoder](/guide/decoder/)'s read-only `cookie-decode` / `flask-decode` / `rack-decode` / `django-decode` converters only show the parts.

Select a cookie anywhere (a **History** detail pane, **Notes**, …) and `Space` `S` (**Send selection to…**) → `k` **Cookie** to seed a new workbench sub-tab with it. Sessions are ephemeral, and nothing is written to disk. The tab is off the bar by default. Press **`0`** and type "cookie", use the command palette (`Ctrl-P` → **Go to Cookie**), or give it a slot in Preferences.

## Two Lenses

A session has two views, toggled with `Ctrl-T`. The top card of each lens carries the switch on its border (` →FORGE ` on INPUT, ` →DECODE ` on PAYLOAD), and clicking it also toggles:

- **Decode**: paste a cookie into INPUT and its parts decode live in DECODED. **OPTIONS** pins how it is read: the format (`Ctrl-A` cycles `auto` / `flask` / `rack` / `django`; `auto` detects it from the punctuation), the Django HMAC algorithm, and a signing salt. **SECRET** holds a candidate key, and its verify verdict (`✓ verified` / `✗ bad key`) is live as you type. To crack it, press `c` from a read pane (INPUT in READ mode, or DECODED). In SECRET and the other editable panes `c` types the letter (see below).
- **Forge**: edit the session in PAYLOAD (a JSON object for Flask/Django, the opaque base64 value for Rack), set a SECRET, and the re-signed cookie appears live in OUTPUT.

`Space` → **Load decoded payload** loads the payload currently decoded on the Decode side into the Forge editor, ready to edit a value and re-sign. Copy any result with `y` from a read pane, or `Ctrl-Y` while editing (the forged cookie with `Space` → **Copy forged cookie**).

> The [JWT](/guide/jwt/) tab decodes without verifying. The Cookie tab verifies. A `✓` in SECRET means the key you typed signs this cookie. Forge re-signs with the secret, salt, and algorithm you give it.

## The Three Formats

| Format | Shape | Signature |
|--------|-------|-----------|
| **Flask** | `value.timestamp.signature` | itsdangerous HMAC (a leading `.` on the value marks zlib compression). |
| **Rack** | `base64--40-hex` | Base64-Marshal value + HMAC-SHA1. The value is opaque bytes, so Forge takes it as base64 rather than JSON. |
| **Django** | `value:timestamp:signature` | `django.core.signing`, a salted HMAC. A **session** cookie signs under a non-default salt; see below. |

## Cracking the Secret

The **SECRET** field doubles as the source for `c` (crack), so there is no separate prompt:

- a **path to a file** is read as a wordlist, one candidate per line;
- a **comma-separated list** (`admin,secret,changeme`) is tried inline;
- a **lone secret** is a one-element list, so the crack runs the same check as the live verify.

On a hit the field is replaced with the winning secret and the verdict flips to `✓`, ready for the Forge lens.

> A Django **session** cookie (`django.contrib.sessions`) is signed under a non-default salt, so cracking it with the default salt fails. When the format resolves to Django, **OPTIONS** shows a ` salt:signing ` badge. Click it (or `Space` → **Toggle Django salt**) to flip the salt field to `django.contrib.sessions.backends.signed_cookies`. Verify, crack, and forge then all sign under it. You can also type any salt by hand. The same applies to `--salt` on the CLI, where a Django `--verify` or `--crack` that fails under the default salt prints a hint naming the session salt.

## Headless

```bash
gori run cookie eyJ1c2Vy...                                  # decode (auto-detect, default)
gori run cookie eyJ1c2Vy... --verify --secret s3cret         # does this secret sign it?
gori run cookie eyJ1c2Vy... --crack --wordlist words.txt     # brute-force the secret
gori run cookie eyJ1c2Vy... --crack --secrets a,b,s3cret     # …or an inline list
gori run cookie --forge --type flask --payload '{"admin":true}' --secret s3cret
cat cookie.txt | gori run cookie                             # cookie from stdin
```

The cookie comes from the argument or stdin. No project or capture is involved, and everything is computed locally. `--type` pins the format (default: auto-detect), `--salt` sets the Flask/Django signing salt, `--algorithm` the Django HMAC algorithm (`sha256` or `sha1`), and `--format` is `text` or `json`. `--forge` defaults the algorithm to `sha256`. Left unset, `--verify`/`--crack` read it off the cookie's signature length, so an older SHA-1 app is not misread as a bad key. Flask/Django `--forge` takes a `--payload` JSON, and Rack takes the opaque `--value`. `--timestamp UNIX` stamps the forged cookie with that second instead of now. See the [CLI Reference](/reference/cli/#run-cookie).

Over MCP, `cookie_decode` / `cookie_verify` / `cookie_crack` / `cookie_forge` are read tools available even under `--read-only`, since they touch no network or state.

## Next Steps

- [JWT](/guide/jwt/): the sibling workbench for JSON Web Tokens
- [Decoder](/guide/decoder/): decode a cookie inside a longer transform chain
- [Repeater & Fuzzer](/guide/repeater-and-fuzzer/): send a forged cookie to the target
