+++
title = "JWT"
description = "Decode, edit and re-sign JSON Web Tokens, and generate alg:none, weak-secret, and header-injection payloads."
weight = 50

[extra]
group = "Workbenches"
+++

The **JWT** tab is a workbench for JSON Web Tokens: decode one, edit its claims and re-sign it, and generate the classic attack payloads to test against the server. It goes further than the [Decoder](/guide/decoder/)'s read-only `jwt-decode` converter, which only shows you the parts.

<figure class="tui-shot">
  <img src="/images/tui/jwt.svg" alt="gori JWT tab with a decoded HS256 token: the INPUT token, the decoded header JSON, and an ATTACKS list of 23 generated payloads including alg=none case variants and signature stripping">
  <figcaption>The <strong>JWT</strong> tab decodes a token live (header, payload, signature) and lists ready-to-send attack payloads: alg:none, weak-secret, and header injection.</figcaption>
</figure>

The tab is hidden by default. Reveal it from the tab-bar `⋯` menu or the command palette (`Ctrl-P` → **Go to JWT**). Select a token anywhere (a **History** detail pane, **Notes**, …) and `Space` → **Send to JWT** to seed a new workbench sub-tab with it. Sessions are ephemeral: nothing is written to disk.

## Two Lenses

One session, two views, toggled with `Ctrl-E`:

- **Decode**: paste a token into INPUT and the header, payload, and signature decode live. Below them is a selectable list of generated **attack payloads**.
- **Encode**: edit the HEADER and PAYLOAD as JSON, choose an algorithm (`Ctrl-A` cycles `HS256` / `HS384` / `HS512` / `none`), set a SECRET, and the re-signed token appears live in OUTPUT.

Press `l` to load the token currently decoded on the Decode side into the Encode editors, so you can tweak a claim and re-sign in two moves. Copy any result with `y`.

> A signature is decoded and shown but **never verified**, so a decode tells you what a token claims, not whether it is trusted. Encode genuinely signs with the secret and algorithm you give it (the first and only HMAC in gori).

## Attack Payloads

From a decoded token, gori generates ready-to-send variants that probe common JWT verification flaws:

| Attack | What it tests |
|--------|---------------|
| **alg:none** | Strips the signature and sets `alg` to `none` (plus `None` / `NONE` case variants), for a server that accepts unsigned tokens. |
| **Weak secret** | Re-signs the token with a list of common weak HMAC secrets, to catch a guessable signing key. |
| **Header injection** | Manipulates the `kid`, `jku`, `x5u`, and `jwk` header parameters, for a server that trusts attacker-supplied key material. |

Send a candidate to **Repeater** to try it against the target, or straight into a request you're already editing.

## Headless

```bash
gori run jwt eyJhbGci...                       # decode (default)
gori run jwt eyJhbGci... --encode --alg HS256 --secret s3cret
gori run jwt eyJhbGci... --attacks             # print the attack payloads
cat token.txt | gori run jwt --attacks         # token from stdin
```

The token comes from the argument or stdin; there is no project or capture involved (it is pure local compute). `--format` is `text` or `json`. See the [CLI Reference](/reference/cli/#run-jwt).

Over MCP, `jwt_decode` / `jwt_encode` / `jwt_attacks` are read tools available even under `--read-only`, since they touch no network or state.

## Next Steps

- [Decoder](/guide/decoder/): decode a JWT inside a longer transform chain
- [Sequencer](/guide/sequencer/): grade the randomness of a token that is not a JWT
- [Repeater & Fuzzer](/guide/repeater-and-fuzzer/): fire an attack payload at the target
