+++
title = "Playbooks"
description = "Follow-along lessons that run a full gori workflow end to end — scope, map, intercept, fuzz, and report, one checkpoint at a time."
weight = 15
+++

The [Quick Start](/getting-started/quick-start/) leaves you at the core loop: capture a request, send it to Repeater, change it, send it again. A playbook is what comes next — one workflow run start to finish, with a checkpoint at every step so you always know whether you're on track.

These are not reference pages. The [Guide](/guide/) documents each tab in depth, one tool at a time; a playbook crosses tabs to finish a task the way an engagement actually does — scope before you capture, capture before you fuzz, confirm before you file. Read the Guide when you want to know what a tool *is*; work a playbook when you want to learn what to *do* with it.

> **Before you begin.** Playbooks send real traffic. Point gori at a target you are authorized to test — your own app, a staging box, or a deliberately vulnerable practice target — and keep it in [scope](/guide/proxy/#scope). Steps that need an exact result use a stable throwaway like `example.com`. Each step ends with a **Checkpoint**: what you should see before moving on.

## Topics

**Foundations** — set the guardrails before you touch the target:

- **[Set up an engagement](/playbooks/set-up-an-engagement/)**: a project, a scope, and a sandbox — why every active tool refuses to fire without them.
- **[Map the attack surface](/playbooks/map-the-attack-surface/)**: build a sitemap, then let Discover find the paths you never clicked.

**The manual loop** — the core of hands-on testing:

- **[Intercept and modify in flight](/playbooks/intercept-and-modify/)**: hold a request, change it, forward it — then make the edit stick as a rule.
- **[Fuzz a parameter](/playbooks/fuzz-a-parameter/)**: mark a position, attach a wordlist, and read the results that stand out.
- **[Carry a session](/playbooks/carry-a-session/)**: extract a token once and replay authenticated across every request and every sweep.

**Workbenches** — focused tools, one job each:

- **[Decode and transform data](/playbooks/decode-and-transform/)**: chain converters into a pipeline you can save and reuse.
- **[Attack a JWT](/playbooks/attack-a-jwt/)**: decode a token, tamper with its claims, and test whether the server checks the signature.
- **[Crack and forge session cookies](/playbooks/crack-and-forge-cookies/)**: read a signed Flask/Rack/Django cookie, recover its secret, and mint your own.
- **[Grade token randomness](/playbooks/grade-token-randomness/)**: collect a few hundred session tokens and let the Sequencer score their predictability.
- **[Confirm blind vulnerabilities with OAST](/playbooks/confirm-blind-vulns-oast/)**: plant an out-of-band payload and catch the callback that proves it fired.

**Wrap up** — turn findings into a report, or hand the project to an agent:

- **[Triage and report](/playbooks/triage-and-report/)**: file issues, prove a fix with the Comparer, and export a report a teammate can read.
- **[Run an AI co-pilot session](/playbooks/run-an-ai-co-pilot/)**: put an agent on the same project over MCP and watch every move it makes.

## Next Steps

- [Quick Start](/getting-started/quick-start/): the ten-minute path to the core loop, if you haven't run it yet
- [Guide](/guide/): in-depth reference for every tool a playbook touches
- [Reference](/reference/): every CLI subcommand, config key, and query-language filter
