+++
title = "Crack and forge session cookies"
description = "Read a signed Flask, Rack, or Django cookie, recover the secret that signs it, and mint your own."
weight = 80

[extra]
group = "Workbenches"
+++

A signed session cookie stops the server from trusting a value the client can change — as long as the signing secret stays secret. This playbook reads a captured Flask, Rack, or Django cookie, tries candidate secrets against it, brute-forces the one that signs it, and re-signs a cookie carrying claims of your choosing, then replays it to see whether the server accepts the forgery. Budget about ten minutes, plus however long a wordlist takes to run.

gori has no cookie tab in the TUI; the whole workflow is the `gori run cookie` subcommand — store-free local compute, with the cookie taken from the argument or stdin — and its four MCP tools. Everything below runs from the shell.

> **Before you begin.** Have gori running as a proxy and capture a response that sets a signed session cookie — the `Set-Cookie` header on a login response is the usual source. The crack step also needs a wordlist of candidate secrets, one per line. Only test cookies from a host you're authorized to attack; the examples target `api.example.com`.

## 1. Decode the cookie

Copy the cookie value from the `Set-Cookie` header of the captured response and decode it. Decoding parses the cookie into its **payload**, **timestamp**, and **signature** without needing the key, so it works on any cookie you capture. gori auto-detects the framework — **Flask**, **Rack**, or **Django** — or you can pin it with `--type`:

```bash
gori run cookie 'eyJ1c2VyIjoi...'                 # decode is the default; framework auto-detected
gori run cookie 'eyJ1c2VyIjoi...' --type flask    # force the format
```

Over MCP this is the `cookie_decode` tool. A decode reveals what the cookie *claims* but never checks the signature — it tells you the session's contents, not whether the server would trust them.

**Checkpoint.** The decoded payload, its timestamp, and the signature print.

## 2. Verify against a candidate secret

If you have a hunch about the secret — a framework default, a reused key, a value pulled from source — check it before spending a wordlist. Verify tests one secret against the cookie's signature:

```bash
gori run cookie 'eyJ1c2VyIjoi...' --verify --secret hunter2
```

Over MCP this is `cookie_verify`. It answers a single question: does this secret produce this signature?

**Checkpoint.** Verify reports whether the candidate secret signs the cookie.

## 3. Crack the secret

When you don't know the secret, brute-force it. Crack re-signs the cookie with each candidate and stops at the one whose signature matches, drawing candidates from a newline-delimited file (`--wordlist`) or a comma-separated list (`--secrets`):

```bash
gori run cookie 'eyJ1c2VyIjoi...' --crack --wordlist secrets.txt
gori run cookie 'eyJ1c2VyIjoi...' --crack --secrets 'dev,changeme,secret'
```

Over MCP this is `cookie_crack`. It is the same primitive as verify, run across a list — so the quality of the wordlist is the whole game.

**Checkpoint.** The recovered secret is printed, or the run reports that the secret was not in the list.

## 4. Forge your own

With the secret in hand, mint a cookie that carries claims of your choosing and a valid signature the server will accept. Forge re-signs a payload with the secret; the shape depends on the framework:

```bash
gori run cookie --forge --type flask  --secret s3cret --payload '{"user":"admin"}'
gori run cookie --forge --type django --secret s3cret --payload '{"user":"admin"}' --salt <salt> --algorithm sha256
gori run cookie --forge --type rack   --secret s3cret --value <base64-marshal>
```

For Flask and Django, `--payload` is the session JSON to sign; Django also takes `--salt` and an `--algorithm` (`sha256` default, or `sha1`). Rack signs an opaque Base64 Marshal blob you pass as `--value` instead of `--payload`. Add `--timestamp=UNIX` to stamp a specific second rather than now. Over MCP this is `cookie_forge`.

Take the forged cookie into **Repeater**: set it as the request's `Cookie` header on an authenticated endpoint and re-send with `Ctrl-R`. If the server returns the session you forged — the admin view, another user's data — it trusted your signature.

**Checkpoint.** The server accepts the forged cookie and returns the authenticated response for the claims you chose.

## Next Steps

- [Grade token randomness](/playbooks/grade-token-randomness/): when a token isn't signed, test whether it's predictable instead
- [CLI Reference](/reference/cli/#run-cookie): every `gori run cookie` flag, including `--salt`, `--algorithm`, and `--timestamp`
- [Attack a JWT](/playbooks/attack-a-jwt/): the sibling workflow for signed JSON Web Tokens
