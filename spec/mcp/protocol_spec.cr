require "../spec_helper"
require "../support/mcp_harness"

# The two eras of MCP over one stdio process (src/gori/mcp/protocol.cr).
#
# `2026-07-28` removed the `initialize` handshake: version, identity and capabilities ride
# in every request's `_meta`, every result names its `resultType`, list results carry cache
# hints, and `server/discover` is the one RPC a server MUST implement. gori serves that
# revision and the four handshake ones from the same tool surface, so what these examples
# pin is the ENVELOPE — which is the only thing that differs, and the only thing a client
# of the wrong era can be broken by.

private VERSION = Gori::MCP::Protocol::LATEST
private META    = %("_meta":{"io.modelcontextprotocol/protocolVersion":"#{VERSION}",) +
                  %("io.modelcontextprotocol/clientCapabilities":{}})

private def modern(store, method : String, params : String = "") : JSON::Any
  body = params.empty? ? META : "#{params},#{META}"
  line = %({"jsonrpc":"2.0","id":7,"method":"#{method}","params":{#{body}}})
  mcp_drive(store, line).find { |l| l["id"]? == 7 }.not_nil!
end

# A one-shot loopback origin for the batch/ping example. It answers the request the batch's
# `send_request` makes — and the moment that request arrives, it writes `line` onto the
# server's OWN stdin. That is what puts a frame in front of the reader fiber while the worker
# is parked inside `handle_batch`, with nothing here timed. The pipe is hung up straight
# after, so the reader reaches EOF and `run` returns once the worker has drained.
private def poking_origin(line : String, writer : IO) : Int32
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    # `serve` as a call and not a block over the accept loop: a block captures the loop
    # variable (spec/support and src/gori/proxy/server.cr both carry the scar).
    conn = server.accept?
    poke_and_answer(conn, line, writer) if conn
    server.close rescue nil
  rescue
    server.close rescue nil
  end
  port
end

private def poke_and_answer(conn : TCPSocket, line : String, writer : IO) : Nil
  while (l = conn.gets("\r\n", chomp: true)) && !l.empty?
  end
  writer.puts(line)
  writer.flush
  writer.close
  conn << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
  conn.flush rescue nil
  conn.close rescue nil
rescue
  conn.close rescue nil
end

private def legacy(store, method : String, params : String = "{}") : JSON::Any
  init = %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}})
  line = %({"jsonrpc":"2.0","id":7,"method":"#{method}","params":#{params}})
  mcp_drive(store, init, line).find { |l| l["id"]? == 7 }.not_nil!
end

describe "MCP protocol version negotiation" do
  it "answers server/discover with the versions, capabilities and identity a client would have handshaken for" do
    with_store do |store|
      result = modern(store, "server/discover")["result"]
      result["resultType"].as_s.should eq("complete")
      versions = result["supportedVersions"].as_a.map(&.as_s)
      versions.first.should eq(VERSION)
      versions.should contain("2025-06-18")
      result["capabilities"]["tools"].as_h.should be_empty
      result["instructions"].as_s.should contain("gori MCP")
      result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"].as_s.should eq("gori")
    end
  end

  # The probe a dual-era client sends before it knows what it is talking to. Refusing it for
  # a missing version would answer "tell me what to say" with "say something first", and
  # send that client back to `initialize` for no reason.
  it "answers server/discover from a client that has not said which version it speaks" do
    with_store do |store|
      line = %({"jsonrpc":"2.0","id":7,"method":"server/discover"})
      res = mcp_drive(store, line).find { |l| l["id"]? == 7 }.not_nil!["result"]
      res["supportedVersions"].as_a.map(&.as_s).should contain(VERSION)
    end
  end

  it "refuses a version it does not speak with the list the client can retry from" do
    with_store do |store|
      line = %({"jsonrpc":"2.0","id":7,"method":"tools/list","params":) +
             %({"_meta":{"io.modelcontextprotocol/protocolVersion":"1999-01-01",) +
             %("io.modelcontextprotocol/clientCapabilities":{}}}})
      err = mcp_drive(store, line).find { |l| l["id"]? == 7 }.not_nil!["error"]
      err["code"].as_i.should eq(-32022)
      err["data"]["requested"].as_s.should eq("1999-01-01")
      err["data"]["supported"].as_a.map(&.as_s).should contain(VERSION)
    end
  end

  # Required on every modern request, and the refusal has to name the key: it is the only
  # thing that makes the mistake recoverable from the client's side.
  it "refuses a modern request that omits the client capabilities" do
    with_store do |store|
      line = %({"jsonrpc":"2.0","id":7,"method":"tools/list","params":) +
             %({"_meta":{"io.modelcontextprotocol/protocolVersion":"#{VERSION}"}}})
      err = mcp_drive(store, line).find { |l| l["id"]? == 7 }.not_nil!["error"]
      err["code"].as_i.should eq(-32602)
      err["message"].as_s.should contain("io.modelcontextprotocol/clientCapabilities")
    end
  end

  # …including on `server/discover`. What that request is excused from is naming an era at
  # all — the example above sends it bare and is answered. It is NOT excused from the
  # required fields of an era it has just declared: `ClientCapabilities` has no required
  # member, so `{}` is always available and a bootstrap probe is missing nothing.
  it "refuses a server/discover that declares a version but no capabilities" do
    with_store do |store|
      line = %({"jsonrpc":"2.0","id":7,"method":"server/discover","params":) +
             %({"_meta":{"io.modelcontextprotocol/protocolVersion":"#{VERSION}"}}})
      err = mcp_drive(store, line).find { |l| l["id"]? == 7 }.not_nil!["error"]
      err["code"].as_i.should eq(-32602)
      err["message"].as_s.should contain("io.modelcontextprotocol/clientCapabilities")
    end
  end

  # The array frame does not exist in the stateless revision (batching went in 2025-06-18),
  # so a member that has declared it must not be answered inside one — even though the
  # batch itself is still accepted, because 2025-03-26 made receiving them mandatory and we
  # still advertise that revision.
  it "refuses a modern request that arrives inside a JSON-RPC batch" do
    with_store do |store|
      line = "[" + %({"jsonrpc":"2.0","id":7,"method":"tools/list","params":) +
             %({"_meta":{"io.modelcontextprotocol/protocolVersion":"#{VERSION}",) +
             %("io.modelcontextprotocol/clientCapabilities":{}}}}) + "]"
      batch = mcp_drive(store, line)[0].as_a
      batch.size.should eq(1)
      batch[0]["error"]["code"].as_i.should eq(-32600)
      batch[0]["error"]["message"].as_s.should contain("batching")
      # …and the legacy member beside it is still answered, in the same array.
      mixed = "[" + %({"jsonrpc":"2.0","id":8,"method":"tools/list","params":{}}) + "]"
      mcp_drive(store, mixed)[0].as_a[0]["result"]["tools"].as_a.should_not be_empty
    end
  end

  # …and that refusal is the BATCH MEMBER's, not the connection's. `ping` is answered by the
  # READER, ahead of a queue that may be minutes deep, which is the whole reason the server
  # splits reader from worker — and `@batch` is the worker's, so a modern liveness probe
  # arriving while the worker happened to be mid-batch was refused for being inside an array
  # it was never part of. A client whose pings go unanswered decides the server is dead and
  # kills it mid-call, which is exactly the call it was waiting on.
  it "answers a modern ping that arrives while another fiber is running a batch" do
    reader, writer = IO.pipe
    with_store do |store|
      ping = %({"jsonrpc":"2.0","id":8,"method":"ping","params":{#{META}}})
      port = poking_origin(ping, writer)
      batch = "[" + %({"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"send_request",) +
              %("arguments":{"url":"http://127.0.0.1:#{port}/","allow_unscoped":true}}}) + "]"
      writer.puts(batch)
      writer.flush
      output = IO::Memory.new
      Gori::MCP::Server.new(store, allow_actions: true, verify_upstream: false,
        input: reader, output: output).run
      lines = output.to_s.each_line.reject(&.strip.empty?).map { |l| JSON.parse(l) }.to_a

      # The batch still left as one array, with its member's answer in it…
      array = lines.find(&.as_a?).not_nil!.as_a
      array.size.should eq(1)
      array[0]["id"].as_i.should eq(7)
      # …and the ping got a real result, on its own frame, beside it.
      pong = lines.find { |l| l.as_h? && l["id"]? == 8 }.not_nil!
      pong["error"]?.should be_nil
      pong["result"]["resultType"].as_s.should eq("complete")
    end
  ensure
    reader.try(&.close) rescue nil
    writer.try(&.close) rescue nil
  end

  # Nothing here is paginated, so any cursor a client sends is one this server never minted.
  # Answering page one anyway is the shape of a silent loop.
  it "refuses a tools/list cursor it never issued" do
    with_store do |store|
      line = %({"jsonrpc":"2.0","id":7,"method":"tools/list","params":{"cursor":"abc",) +
             %("_meta":{"io.modelcontextprotocol/protocolVersion":"#{VERSION}",) +
             %("io.modelcontextprotocol/clientCapabilities":{}}}})
      err = mcp_drive(store, line).find { |l| l["id"]? == 7 }.not_nil!["error"]
      err["code"].as_i.should eq(-32602)
      err["message"].as_s.should contain("cursor")
      mcp_drive(store, %({"jsonrpc":"2.0","id":7,"method":"tools/list","params":{"cursor":"abc"}}))
        .find { |l| l["id"]? == 7 }.not_nil!["error"]["code"].as_i.should eq(-32602)
    end
  end

  # The version half of the gate still applies there — that refusal is how a dual-era client
  # learns the server is modern and must not fall back to `initialize`.
  it "still refuses a server/discover that names a version it does not speak" do
    with_store do |store|
      line = %({"jsonrpc":"2.0","id":7,"method":"server/discover","params":) +
             %({"_meta":{"io.modelcontextprotocol/protocolVersion":"1999-01-01"}}})
      err = mcp_drive(store, line).find { |l| l["id"]? == 7 }.not_nil!["error"]
      err["code"].as_i.should eq(-32022)
    end
  end

  # The key is reserved by the spec and no handshake client writes it, so a slot that holds
  # something other than a string is a MODERN client's serialisation bug — `20260728`
  # unquoted, a `null` from an absent config. Reading it as legacy would serve that bug back
  # with a straight face; the refusal names the field and the shape it actually held.
  it "refuses a protocol version that is present but is not a string" do
    with_store do |store|
      {"20260728", "null", %(["#{VERSION}"])}.each do |bad|
        line = %({"jsonrpc":"2.0","id":7,"method":"tools/list","params":) +
               %({"_meta":{"io.modelcontextprotocol/protocolVersion":#{bad},) +
               %("io.modelcontextprotocol/clientCapabilities":{}}}})
        err = mcp_drive(store, line).find { |l| l["id"]? == 7 }.not_nil!["error"]
        err["code"].as_i.should eq(-32602)
        err["message"].as_s.should contain("io.modelcontextprotocol/protocolVersion")
      end
    end
  end

  # A field plainly present, refused as "required", reads as a server that cannot see it.
  it "names the shape when the client capabilities are the wrong one" do
    with_store do |store|
      line = %({"jsonrpc":"2.0","id":7,"method":"tools/list","params":) +
             %({"_meta":{"io.modelcontextprotocol/protocolVersion":"#{VERSION}",) +
             %("io.modelcontextprotocol/clientCapabilities":[]}}})
      err = mcp_drive(store, line).find { |l| l["id"]? == 7 }.not_nil!["error"]
      err["code"].as_i.should eq(-32602)
      err["message"].as_s.should contain("must be a JSON object")
      err["message"].as_s.should contain("an array")
    end
  end

  # A handshake revision named in `_meta` is a version we support spelled in a slot its own
  # revision does not define. Decoration, not an error — and not a promotion to modern.
  it "serves a legacy revision named in _meta under legacy semantics" do
    with_store do |store|
      line = %({"jsonrpc":"2.0","id":7,"method":"tools/list","params":) +
             %({"_meta":{"io.modelcontextprotocol/protocolVersion":"2025-06-18"}}})
      result = mcp_drive(store, line).find { |l| l["id"]? == 7 }.not_nil!["result"]
      result["resultType"]?.should be_nil
      result["tools"].as_a.should_not be_empty
    end
  end

  it "echoes a handshake revision it supports and falls back to the newest legacy one otherwise" do
    with_store do |store|
      ask = ->(v : String) do
        line = %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"#{v}"}})
        mcp_drive(store, line)[0]["result"]["protocolVersion"].as_s
      end
      ask.call("2024-11-05").should eq("2024-11-05")
      ask.call("2025-11-25").should eq("2025-11-25")
      ask.call("1999-01-01").should eq(Gori::MCP::Protocol::LEGACY_LATEST)
      # A client that sends `initialize` has chosen handshake semantics for itself; naming a
      # modern version back would promise per-request semantics it cannot switch to.
      ask.call(VERSION).should eq(Gori::MCP::Protocol::LEGACY_LATEST)
    end
  end
end

describe "MCP result envelope" do
  it "names the result type and the server on every modern result" do
    with_store do |store|
      %w[tools/list ping].each do |method|
        result = modern(store, method)["result"]
        result["resultType"].as_s.should eq("complete")
        result["_meta"]["io.modelcontextprotocol/serverInfo"]["version"].as_s.should eq(Gori::VERSION)
      end
      call = modern(store, "tools/call", %("name":"ql_reference","arguments":{}))["result"]
      call["resultType"].as_s.should eq("complete")
      call["isError"].as_bool.should be_false
    end
  end

  # The spec's own rule is that a missing `resultType` reads as `complete`, so a handshake
  # client is handed exactly the bytes it was before — nothing to re-learn.
  it "leaves a legacy result exactly as it was" do
    with_store do |store|
      result = legacy(store, "tools/list")["result"]
      result["resultType"]?.should be_nil
      result["_meta"]?.should be_nil
      result["ttlMs"]?.should be_nil
    end
  end

  it "carries cache hints on a modern tools/list only" do
    with_store do |store|
      result = modern(store, "tools/list")["result"]
      result["ttlMs"].as_i.should eq(Gori::MCP::Protocol::TOOLS_LIST_TTL_MS)
      result["cacheScope"].as_s.should eq("private")
      legacy(store, "tools/list")["result"]["cacheScope"]?.should be_nil
    end
  end

  # What makes the catalogue cacheable at all, and what the spec spells as a MUST NOT: the
  # set of tools "MUST NOT vary per-connection or as a side effect of other requests on the
  # connection". It is a function of the start-up flags (`--read-only`, `--tools`) and of
  # nothing a call can reach — `create_project` used to be listed on a live `unbound?` and
  # is not any more; it is advertised always and refuses at call time instead.
  #
  # Pinned here rather than claimed in a comment, because the failure is invisible from one
  # connection: a client caches the list for the five minutes `ttlMs` promises, and the
  # tool it was told about is gone.
  it "does not let the project binding change the catalogue at all" do
    names = ->(store : Gori::Store?, actions : Bool) do
      tools = Gori::MCP::Tools.new(store, allow_actions: actions, verify_upstream: false)
      JSON.parse(JSON.build { |j| tools.list(j) }).as_a.map(&.["name"].as_s).to_set
    end
    with_store do |store|
      names.call(nil, false).should eq(names.call(store, false))
      names.call(nil, true).should eq(names.call(store, true))
    end
  end

  # The freshness the example above earns: the same number from an unbound read-only server
  # as from a bound one, because there is nothing left for the binding to change.
  it "promises the same freshness before a project is bound" do
    line = %({"jsonrpc":"2.0","id":7,"method":"tools/list","params":{#{META}}})
    input = IO::Memory.new("#{line}\n")
    output = IO::Memory.new
    Gori::MCP::Server.new(nil, allow_actions: false, verify_upstream: false,
      input: input, output: output).run
    result = JSON.parse(output.to_s.each_line.reject(&.strip.empty?).first)["result"]
    result["tools"].as_a.map(&.["name"].as_s).should contain("create_project")
    result["ttlMs"].as_i.should eq(Gori::MCP::Protocol::TOOLS_LIST_TTL_MS)
  end
end

describe "MCP subscriptions" do
  # gori has nothing to push — no `listChanged`, no resources, and the one vendor
  # notification is confined to the handshake era. The conformant answer to that is the
  # EMPTY subscription, not `-32601`: acknowledge first (the spec's ordering rule), agree to
  # nothing ("notification types the server does not support are omitted"), then close the
  # way a server closes a stream it is ending itself.
  #
  # Closing at once is also the only safe shape: one worker fiber runs one request at a
  # time, so a stream held open would starve every tool call behind it.
  it "acknowledges a listen with an empty filter and closes it gracefully" do
    with_store do |store|
      line = %({"jsonrpc":"2.0","id":"sub-1","method":"subscriptions/listen","params":) +
             %({"notifications":{"toolsListChanged":true},#{META}}})
      out = mcp_drive(store, line)

      ack = out.find { |l| l["method"]? == "notifications/subscriptions/acknowledged" }.not_nil!
      ack["id"]?.should be_nil
      # In `_meta`, not beside it — a client demultiplexing one stdio channel looks in
      # exactly one place, and the id is the opening request's own.
      ack["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"].as_s.should eq("sub-1")
      ack["params"]["notifications"].as_h.should be_empty

      done = out.find { |l| l["id"]? == "sub-1" }.not_nil!["result"]
      done["resultType"].as_s.should eq("complete")
      done["_meta"]["io.modelcontextprotocol/subscriptionId"].as_s.should eq("sub-1")
      # The server's own identity rides in the same `_meta`; two `_meta` keys would be a
      # duplicate that some clients reject outright.
      done["_meta"]["io.modelcontextprotocol/serverInfo"]["name"].as_s.should eq("gori")

      # And the acknowledgement is FIRST.
      out.index(ack).not_nil!.should be < out.index { |l| l["id"]? == "sub-1" }.not_nil!
    end
  end
end

describe "MCP tools/call error reporting" do
  # "Protocol Errors indicate issues with the request structure itself that models are less
  # likely to be able to fix: Unknown tool …" — a name that is not in `tools/list` never
  # reached a tool, so it is not a tool result. The sentence survives as `error.message`.
  it "answers an unknown tool with a protocol error, not an isError result" do
    with_store do |store|
      res = modern(store, "tools/call", %("name":"no_such_tool","arguments":{}))
      res["result"]?.should be_nil
      res["error"]["code"].as_i.should eq(-32602)
      res["error"]["message"].as_s.should contain("no_such_tool")
    end
  end

  # A tool that RAN and failed stays on the other side of the line, because that is the
  # bucket a client is told to hand back to the model for a retry.
  it "keeps a tool's own failure as an isError result" do
    with_store do |store|
      res = modern(store, "tools/call", %("name":"get_flow","arguments":{"id":999999}))
      res["error"]?.should be_nil
      res["result"]["isError"].as_bool.should be_true
      res["result"]["structuredContent"]["error_code"].as_s.should eq("NOT_FOUND")
    end
  end

  # The `--tools` refusal is the same class: the tool is not advertised, so from the
  # client's side it does not exist. Its sentence is written to be read by the model and it
  # still is — as the error's message.
  it "answers a tool hidden by --tools the same way, keeping the sentence" do
    with_store do |store|
      filter = Gori::MCP::ToolFilter.parse("list_events", Gori::MCP::Tools::TOOL_NAMES,
        Gori::MCP::Tools::TOOL_DEPENDENCIES)
      filter.should be_a(Gori::MCP::ToolFilter)
      input = IO::Memory.new(%({"jsonrpc":"2.0","id":7,"method":"tools/call","params":) +
                             %({"name":"get_flow","arguments":{},#{META}}}) + "\n")
      output = IO::Memory.new
      Gori::MCP::Server.new(store, allow_actions: true, verify_upstream: false,
        tool_filter: filter.as(Gori::MCP::ToolFilter), input: input, output: output).run
      err = JSON.parse(output.to_s.each_line.reject(&.strip.empty?).first)["error"]
      err["code"].as_i.should eq(-32602)
      err["message"].as_s.should contain("tools/list")
    end
  end
end
