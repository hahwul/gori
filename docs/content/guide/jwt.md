+++
title = "JWT"
description = "Decode, verify, edit and re-sign JSON Web Tokens across HMAC and the asymmetric algorithms, and generate alg:none, weak-secret, header-injection and algorithm-confusion payloads."
weight = 50

[extra]
group = "Workbenches"
+++

The **JWT** tab is a workbench for JSON Web Tokens: decode one, edit its claims and re-sign it, and generate the classic attack payloads to test against the server. It goes further than the [Decoder](/guide/decoder/)'s read-only `jwt-decode` converter, which only shows you the parts.

<figure class="tui-shot">
  <img src="/images/tui/jwt.svg" alt="gori JWT tab with a decoded HS256 token: the INPUT token under a ^T:→ENCODE lens chip, the decoded header JSON, and an ATTACKS list of 23 generated payloads including alg=none case variants and signature stripping">
  <figcaption>The <strong>JWT</strong> tab decodes a token live (header, payload, signature) and lists ready-to-send attack payloads: alg:none, weak-secret, and header injection.</figcaption>
</figure>

Select a token anywhere (a **History** detail pane, **Notes**, …) and `Space` → **Send to JWT** to seed a new workbench sub-tab with it. Sessions are ephemeral: nothing is written to disk. If you have hidden the tab, reveal it again from the tab-bar `⋯` menu, the command palette (`Ctrl-P` → **Go to JWT**), or Preferences.

## Two Lenses

One session, two views, toggled with `Ctrl-T`. The top card of each lens carries the switch on its border (` ^T:→ENCODE ` on INPUT, ` ^T:→DECODE ` on HEADER), and clicking it does the same thing as the key:

- **Decode**: paste a token into INPUT and the header, payload, and signature decode live. Below them is a selectable list of generated **attack payloads**.
- **Encode**: edit the HEADER and PAYLOAD as JSON, choose an algorithm (`Ctrl-A` cycles the HMAC family, then `RS`/`PS`/`ES` at 256/384/512, `EdDSA`, and `none`), set a SECRET, and the re-signed token appears live in OUTPUT. For an asymmetric algorithm the card becomes **KEY** and takes a path to a PEM private key instead of a typed secret.

`Space` → **Load decoded claims** loads the token currently decoded on the Decode side into the Encode editors, so you can tweak a claim and re-sign in two moves. Copy any result with `y`.

> A signature is decoded and shown but **never verified on the Decode side**, so a decode tells you what a token claims, not whether it is trusted. Encode genuinely signs with the key and algorithm you give it, and `gori run jwt --verify` (or MCP `jwt_verify`) answers the trust question when you hold the key.

## Algorithms

HMAC (`HS256` / `HS384` / `HS512`) signs with a secret you type. The asymmetric families sign with a PEM key you supply — gori generates none, so forging an `RS256` token still requires the `RS256` private key:

| Family | Algorithms | Key |
|--------|------------|-----|
| **HMAC** | `HS256` `HS384` `HS512` | the shared secret, inline |
| **RSA PKCS#1** | `RS256` `RS384` `RS512` | an RSA private key to sign, public key / certificate to verify |
| **RSA-PSS** | `PS256` `PS384` `PS512` | the same RSA key; salt length is the digest length (RFC 7518 §3.5) |
| **ECDSA** | `ES256` `ES384` `ES512` | a P-256 / P-384 / P-521 key. The signature is the fixed-width `r‖s` form JOSE mandates, so `ES512` is 132 bytes, not 128 |
| **EdDSA** | `EdDSA` | an Ed25519 key |
| **Unsigned** | `none` | none — the auth-bypass shape, offered deliberately |

A key is either inline PEM text or a path to a `.pem` file. Verification additionally accepts an X.509 **certificate** (what an IdP publishes as `x5c`) or the private key itself.

## Encrypted Tokens (JWE)

A five-part `header.encrypted_key.iv.ciphertext.tag` token is a **JWE** — an encrypted JWT. gori recognizes it everywhere it recognizes a JWS (the JWT tab, the Decoder, the body pretty-printer, `gori run jwt`, MCP `jwt_decode`) and shows the **protected header**: the `alg` that wrapped the content-encryption key, the `enc` that encrypted the claims, and the `kid`.

gori does **not** decrypt. With no key the claims are marked encrypted and nothing is guessed at in their place, and the projections that only make sense over claims refuse the token outright: `--attacks` generates nothing (there is no claims segment to tamper with and no signature to strip), and `--verify` says so rather than reporting an unsupported algorithm.

## Attack Payloads

From a decoded token, gori generates ready-to-send variants that probe common JWT verification flaws:

| Attack | What it tests |
|--------|---------------|
| **alg:none** | Strips the signature and sets `alg` to `none` (plus the `None` / `NONE` / `nOnE` case variants), for a server that accepts unsigned tokens. Two more payloads keep the original header: **signature stripped** (an empty third segment) and **no signature segment** (a 2-part token). |
| **Weak secret** | Re-signs the token with a list of common weak HMAC secrets, to catch a guessable signing key. |
| **Header injection** | Manipulates the `kid`, `jku`, `x5u`, and `jwk` header parameters, for a server that trusts attacker-supplied key material. |
| **Algorithm confusion** | Only with the server's public key (`--attacks --key`, MCP `public_key`). Downgrades an `RS`/`PS`/`ES` token to `HS256` and HMAC-signs it with the public key's own bytes, for a server that dispatches on the token's `alg` and reuses its verification key. One payload per spelling a server might hold: the canonical SPKI PEM OpenSSL would write, and the bytes as supplied with and without a trailing newline. |

Send a candidate to **Repeater** to try it against the target, or straight into a request you're already editing.

## Headless

```bash
gori run jwt eyJhbGci...                       # decode (default)
gori run jwt eyJhbGci... --encode --alg HS256 --secret s3cret
gori run jwt eyJhbGci... --encode --set role=admin --secret s3cret   # patch one claim, re-sign
gori run jwt eyJhbGci... --encode --payload '{"sub":"1","admin":true}' --secret s3cret   # replace the claims wholesale
gori run jwt eyJhbGci... --encode --alg ES256 --key ./private.pem     # sign with an asymmetric key
gori run jwt eyJhbGci... --verify --key ./public.pem                  # does this token check out?
gori run jwt eyJhbGci... --attacks             # print the attack payloads
gori run jwt eyJhbGci... --attacks --key ./public.pem                 # ...plus algorithm confusion
cat token.txt | gori run jwt --attacks         # token from stdin
```

The token comes from the argument or stdin; there is no project or capture involved (it is pure local compute). `--format` is `text` or `json`. On `--encode`, `--set KEY=VALUE` patches one claim (repeatable; the value is JSON when it parses, so `admin=true` is a boolean and `role=admin` a string) and `--payload JSON` replaces the whole claims object; the two are mutually exclusive. `--secret` and `--key` fill the same slot, so pass one. `--verify` prints `verified: yes|no` and exits 0 either way — a "no" is an answer, so scripts read the field, not the exit code. See the [CLI Reference](/reference/cli/#run-jwt).

Over MCP, `jwt_decode` / `jwt_verify` / `jwt_encode` / `jwt_attacks` are read tools available even under `--read-only`: they touch no network and write nothing. `jwt_encode` takes the same `set` / `payload` claim edits and the same `key`; `jwt_attacks` takes `public_key`. Note that `key` / `public_key` accept a **path**, so those two arguments read a file the caller names — pass the PEM inline if the client should not reach the filesystem.

## Next Steps

- [Decoder](/guide/decoder/): decode a JWT inside a longer transform chain
- [Sequencer](/guide/sequencer/): grade the randomness of a token that is not a JWT
- [Repeater & Fuzzer](/guide/repeater-and-fuzzer/): fire an attack payload at the target
