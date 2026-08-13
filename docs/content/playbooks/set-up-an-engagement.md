+++
title = "Set up an engagement"
description = "Create a project, draw a scope, and lock the test inside a sandbox — the guardrails every active tool checks before it fires."
weight = 10

[extra]
group = "Foundations"
+++

Before you capture a single request, you set the boundaries of the test: which project holds the traffic, which hosts are in scope, and whether gori is allowed to touch anything else at all. This playbook walks all three. It takes about five minutes, and it is what makes every later step safe — Repeater, Fuzzer, and the scanners all refuse to fire at a target you haven't scoped.

> **Before you begin.** Work through the [Quick Start](/getting-started/quick-start/) first, so gori is running and you can move between tabs. Have the host you're authorized to test in mind; the examples use `api.example.com` as a stand-in.

## 1. Create a project

A project is one SQLite database — its own history, scope, issues, and notes, isolated from every other engagement. Keeping each target in its own project is what lets scope and the sandbox mean anything.

In the TUI, open the project picker from the command palette (`Ctrl-P`, then type *project*) and start a new one. Or create it from the shell before the proxy ever starts, so a script can lay down scope and env first:

```bash
gori run project create "Acme API" --description="staging engagement"
```

Creating a name that already exists just reopens it, so this is safe to re-run.

**Checkpoint.** The **Project** tab header shows your project name, and **History** (tab `3`) is empty.

## 2. Draw your scope

Open the **Project** tab, arrow to the **SCOPE** card, and press `↓` or `Enter` to drop into it. Scope is a list of **include** and **exclude** rules, each matching by **host**, **string**, or **regex**. Add an include for your target, then exclude the noise you don't care about:

```bash
gori run project scope add --kind=include --type=host  --pattern=api.example.com
gori run project scope add --kind=exclude --type=regex --pattern='\.(css|js|png|woff2?)$'
```

Scope is evaluated as an **allowlist**: a flow is in scope when at least one include rule matches and no exclude rule does. That definition drives the next two steps.

**Checkpoint.** `gori run project scope` (or the SCOPE card) lists both rules. Nothing is filtered or blocked yet — you've only described the boundary.

## 3. Focus your view with the scope lens

Press `s` anywhere to toggle the **scope lens**. It filters History, the Sitemap, and the other views down to in-scope traffic, so a busy capture collapses to just your target. It is a *lens*, not a gate: out-of-scope flows are still captured and reappear the moment you toggle it back off.

**Checkpoint.** With the lens on, History shows only `api.example.com` rows. Press `s` again and the rest of the traffic returns.

## 4. Contain the test with the sandbox

The scope lens hides traffic; the **sandbox** stops it. Turn it on from the **Project → NETWORK** pane, or from anywhere with `Ctrl-P` → **Toggle sandbox**:

```bash
gori run project sandbox on
```

While it's on, the proxy forwards only the requests your scope allows and blocks everything else before it reaches the origin. A blocked request comes back as a `403` carrying an `X-Gori-Sandbox: blocked` header (on HTTP/2 the stream is cancelled instead), and the attempt is still recorded as an aborted flow, so you can see what tried to leave.

Because scope is an allowlist, **a sandbox with no include rule blocks everything** — which is exactly why you drew scope first. A red `sandbox` chip stays lit in the top bar the whole time it's on.

**Checkpoint.** The `sandbox` chip is lit. A request to an out-of-scope site fails; a request to `api.example.com` goes through. Toggle the sandbox off to roam freely again.

## 5. Redirect a host without touching DNS (optional)

If your target's name has to resolve somewhere other than public DNS — a staging box, a local instance — add a **host override** in the **Project → HOST OVERRIDES** card. It changes only the TCP dial target; the SNI, certificate name, and `Host` header stay the original name, so the server sees an ordinary request:

```bash
gori run project host-override add --host=api.example.com --ip=10.0.0.1
```

**Checkpoint.** `gori run project host-override` lists the entry, and a request to `api.example.com` now connects to `10.0.0.1`.

## Why scope comes first

Scope isn't only a filter. The active tools enforce it on their own: **Repeater**, **Fuzzer**, **Miner**, and the MCP `send_request` tool refuse an out-of-scope target with a `SCOPE_BLOCKED` error, whether or not the sandbox is on. That is the guardrail that stops a stray replay or a fuzzing run from reaching a host you never meant to touch. Set scope once, here, and every later playbook inherits it.

## Next Steps

- [Map the attack surface](/playbooks/map-the-attack-surface/): turn a scoped capture into a sitemap
- [Proxy & History](/guide/proxy/#scope): the full reference for scope, the sandbox, and host overrides
- [Query Language](/reference/query-language/): filter History by more than just host
