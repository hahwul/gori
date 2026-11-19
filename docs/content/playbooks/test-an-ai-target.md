+++
title = "Test an AI target"
description = "Find the LLM and MCP calls in a capture, judge a prompt injection by its hit rate, carry an MCP session, and check the tool definitions a model is told to trust."
weight = 105

[extra]
group = "Workbenches"
+++

This playbook treats an application that talks to a model, and an MCP server that hands tools to one, as targets like any other. It finds their calls in History, measures an injection by its hit rate, replays a stateful MCP call, and checks what a tool list tells the model. gori does not call a model. Every request here goes to the target you captured. Budget about fifteen minutes.

> **Before you begin.** [Set up an engagement](/playbooks/set-up-an-engagement/) first, and capture the application's traffic through the proxy: at least one LLM API call, or one MCP exchange (`initialize`, then `tools/list` or `tools/call`). Only test a target you are authorized to test. The examples use `mcp.example.com` as a stand-in.

## 1. Find the calls

An LLM API call is recognised by its request body (a `model` beside `messages` or `input`), not by its host, so a self-hosted gateway counts too. An MCP call is JSON-RPC, whatever path it is posted to.

```bash
gori run history -q 'llm:true'                              # every LLM API call
gori run history -q 'llm:claude'                            # one model family
gori run history -q 'rpc:tools/call'                        # MCP tool calls
gori run history -q 'rpc:tools/call req.body:get_weather'   # one tool, by name
```

In the TUI the same queries go in History's filter, and a matching flow gets an **LLM** or **MCP** pane in its detail: the messages and reply, or each call's method, params and result.

**Checkpoint.** The query lists the calls you made, and opening one shows the conversation or the tool call decoded.

## 2. Read a rate, not one answer

A model can answer the same request differently each time, so one send proves little either way. Send the request as it stands N times and count the hits. A run whose only payload set is **null** payloads needs no `§…§` position:

```bash
gori run fuzz <flow-id> --null=20 --mr 'PWNED' --concurrency 2
# done · 20 sent · 7 shown · 0 errors
```

`--mr` is the marker your injection asks the model to print. A streamed reply is matched as reassembled text, so a word split across two SSE events still counts. In the TUI add a **Null** set in the Fuzzer and read `7 hit` in the RESULTS header. Over MCP it is `payloads: [{"null": 20}]`, and `fuzz_status` returns `matched` beside `sent`.

To vary the injection instead, mark the prompt text and sweep a wordlist, as in [Fuzz a parameter](/playbooks/fuzz-a-parameter/).

**Checkpoint.** The run reports hits against sends. Seven of twenty is a measurable finding, and zero of twenty is stronger evidence than zero of one.

## 3. Keep the conversation for the report

A finding needs an exchange a reader can follow, as well as the raw bytes.

```bash
gori run show <flow-id> --format transcript > finding.md
```

That writes each request message under its role, then the reply and its tool calls, as Markdown. In the TUI it is **Copy as… › LLM transcript** on the flow.

**Checkpoint.** The file reads as a conversation: the system prompt first, your injected message, then what the model answered.

## 4. Carry an MCP session

A stateless MCP server answers a replayed `tools/call` as it is. A stateful one requires an `initialize` exchange first, returns an `Mcp-Session-Id`, and answers `404` once that session is gone. A [session slot](/playbooks/carry-a-session/) with two refresh steps does the handshake for you.

Bind the session id wherever a response carries it:

```bash
gori run rewriter extract add --name MCPSID --kind header --selector Mcp-Session-Id \
  --when 'header:mcp-session-id'
```

Save the two handshake requests as Repeater sessions, from the flows you captured:

```bash
gori run repeater create --flow <initialize-flow> --name mcp-init
gori run repeater create --flow <initialized-notification-flow> --name mcp-ready
```

Open `mcp-ready` and change its session header to `Mcp-Session-Id: $BIND.MCPSID`. A refresh step is sent without the slot's headers, so the stale session is not handed back to `initialize`, and this one request has to name the fresh id itself. A JSON-RPC `id` that must be new on every send can be written `"id": "$GEN.UUID"`.

Then make the slot: the header it writes, the rule it owns, the steps that renew it, and how often.

```bash
gori run session add --name mcp --set 'Mcp-Session-Id: $BIND.MCPSID' --rule MCPSID \
  --refresh <mcp-init-id>,<mcp-ready-id> --refresh-before ttl=10m
gori run repeater send <tools-call-session> --slot mcp
```

Pick a `ttl` shorter than the server keeps an idle session. gori renews before a send, not in response to a `404`, so a session the server drops early shows up as `404` rows until the next refresh. `gori run session refresh mcp` runs the steps by hand to check them, and an agent does the same with `refresh_session_slot`.

**Checkpoint.** The send prints `slot: sending as mcp` and the tool's result, and `gori run history -q 'src:refresh'` lists the two handshake requests.

## 5. Fuzz a tool's arguments

With the slot carrying the session, a tool argument is an ordinary position. Mark it in the saved `tools/call` session and sweep:

```bash
# body: {"jsonrpc":"2.0","id":"$GEN.UUID","method":"tools/call",
#        "params":{"name":"read_file","arguments":{"path":"§notes.txt§"}}}
gori run fuzz --repeater <tools-call-session> --slot mcp --preset traversal --mr 'root:'
```

A tool's failure usually comes back as `200` with `"isError": true` in the result, so match on the body rather than the status.

**Checkpoint.** Every row is an answer from the tool, not a `404`, and the rows that matched are the arguments worth reading.

## 6. Check what the tool list tells the model

A `tools/list` result is text the client's model reads as trusted. The passive `llm_prompt_injection` rule flags a description that addresses the model behind the user's back:

```bash
gori run probe 'rpc:tools/list'
```

A server can also change a definition after the client approved it. Compare two captures of the list, taken at different times or as different users:

```bash
tools() { gori run show "$1" --json | jq -r '.json_rpc.calls[0].reply'; }
diff <(tools 41) <(tools 97)
```

That prints the reply as indented JSON whether it arrived as one body or as an event stream, so the diff shows only the tool, description or schema that changed.

**Checkpoint.** `probe` either reports `llm_prompt_injection` on the list or reports nothing, and the diff is empty for a server whose definitions did not change.

## Next Steps

- [Carry a session](/playbooks/carry-a-session/): slots, extract rules and refresh steps in full
- [Fuzz a parameter](/playbooks/fuzz-a-parameter/): positions, payload sets and matchers
- [Triage and report](/playbooks/triage-and-report/): turn a hit rate and a transcript into an issue
- [Query language](/reference/query-language/): `llm:`, `rpc:` and the rest of the filter grammar
