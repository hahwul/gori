+++
title = "Getting Started"
description = "Install gori, trust its CA, and capture your first request."
+++

Welcome to gori. This section takes you from a clean machine to a live proxy session — traffic in History, a few Day-1 keys under your fingers, and a first Replay.

## What You'll Learn

1. How to install and build gori
2. Starting the proxy and trusting the root CA (including a pre-trusted browser)
3. Capturing, filtering, and inspecting your first flows
4. The two discovery surfaces: command palette (`Ctrl-P`) and space menu (`Space`)
5. Sending a flow to Replay / Fuzzer and running one send
6. Where gori stores its data and how to configure it

## What Is gori?

gori is a keyboard-driven HTTP/HTTPS **intercepting proxy** and web-security toolkit that runs entirely in your terminal. It sits between your client and the server, records every request/response as a *flow*, and gives you a workbench to inspect, replay, fuzz, and scan that traffic.

It understands **HTTP/1.1, HTTP/2, WebSocket, gRPC, and Server-Sent Events**, and decodes common formats like JWT, SAML, and GraphQL inline. Everything you can do in the TUI is also reachable non-interactively through `gori run` and the built-in [MCP server](/guide/mcp/), so agents and scripts can drive the same project.

## Next Steps

- [Installation](/getting-started/installation/) — build gori from source
- [Quick Start](/getting-started/quick-start/) — capture, keys, and your first Replay
- [Configuration](/getting-started/configuration/) — settings, storage, and the CA