+++
title = "Attack a JWT"
description = "Decode a JSON Web Token, tamper with its claims, and test whether the server actually verifies the signature."
weight = 70

[extra]
group = "Workbenches"
+++

A JWT is only as trustworthy as the server's check of its signature. This playbook takes a token off a captured request, reads its claims, changes one, re-signs it, and fires the classic verification-bypass payloads — alg:none, a weak-secret guess, header injection — to find out which the server accepts. Budget about ten minutes.

> **Before you begin.** Set up a project and scope for a host you're authorized to test ([Set up an engagement](/playbooks/set-up-an-engagement/)), and capture a flow that carries a JWT — an `Authorization: Bearer eyJ…` header is the usual source. The examples target `api.example.com`.

## 1. Send a token to the JWT tab

The **JWT** tab is hidden by default; reveal it from the tab-bar `⋯` menu, the command palette (`Ctrl-P` → **Go to JWT**), or Preferences. Then find the token: open the captured flow in **History**, select the token text after `Bearer ` in the request detail, and `Space` → **Send to JWT**. That seeds a new JWT sub-tab and decodes the token live into its **header**, **payload**, and **signature** on the Decode lens.

The decode shows what the token *claims*; it never checks the signature, so a token that decodes cleanly is not necessarily one the server trusts. That is the question the rest of this playbook answers.

<figure class="tui-shot">
  <img src="/images/tui/jwt.svg" alt="gori JWT tab with a decoded HS256 token: the INPUT token under a ^T:→ENCODE lens chip, the decoded header JSON, and an ATTACKS list of generated payloads including alg=none case variants and signature stripping">
  <figcaption>The <strong>JWT</strong> tab decodes a token live (header, payload, signature) and lists ready-to-send attack payloads: alg:none, weak-secret, and header injection.</figcaption>
</figure>

**Checkpoint.** The JWT tab shows the token's header and payload as JSON, with the signature below.

## 2. Tamper a claim

Switch to the Encode lens with `Ctrl-T`, or press `l` to load the decoded token straight into the Encode editors. Edit the **PAYLOAD** JSON — escalate a `role`, swap a `sub`, extend an `exp`. Pick the algorithm with `Ctrl-A` (it cycles `HS256` / `HS384` / `HS512` / `none`), set a **SECRET** when you're signing with an HMAC algorithm, and the re-signed token appears live in OUTPUT. Copy it with `y`.

The same re-sign runs headless, taking the token from the argument or stdin:

```bash
gori run jwt eyJhbGci... --encode --alg HS256 --secret s3cret
```

**Checkpoint.** OUTPUT holds a token carrying your edited claim, re-signed with the algorithm and secret you chose.

## 3. Run the attack presets

You rarely know the secret, so let gori generate the bypass attempts instead. On the Decode lens, below the decoded parts, is a selectable list of **attack payloads** built from the token:

| Attack | What it tests |
|--------|---------------|
| **alg:none** | Strips the signature and sets `alg` to `none` (plus `None` / `NONE` case variants) — a server that accepts unsigned tokens. |
| **Weak secret** | Re-signs with a list of common weak HMAC secrets — a guessable signing key. |
| **Header injection** | Manipulates the `kid`, `jku`, `x5u`, and `jwk` header parameters — a server that trusts attacker-supplied key material. |

Generate the same set headless:

```bash
gori run jwt eyJhbGci... --attacks
```

Over MCP the `jwt_attacks` tool returns the identical list (and `jwt_decode` / `jwt_encode` cover steps 1 and 2). All three are read tools available even under `--read-only`, since they touch no network.

**Checkpoint.** The ATTACKS list is populated with ready-to-send token variants.

## 4. Replay and confirm

A forged token proves nothing until the server sees it. Pick a payload — your tampered token from step 2, or a preset from step 3 — and send it to **Repeater**, swap it into the `Authorization` header of the captured request, and re-send with `Ctrl-R`. Read the status against what the endpoint should return for a bad token:

- A `401` or `403` means the server rejected the forgery — it verified the signature.
- A `200` where you expected a reject means it did *not* verify — the token was accepted on your terms.

**Checkpoint.** You can tell an accepted forgery (a success status) from a rejected one (`401` / `403`), and you know which presets, if any, the server let through.

## Next Steps

- [Crack and forge session cookies](/playbooks/crack-and-forge-cookies/): the same read-tamper-replay loop for signed session cookies
- [JWT](/guide/jwt/): the two lenses, re-signing, and every attack in depth
- [CLI Reference](/reference/cli/#run-jwt): every `gori run jwt` option
