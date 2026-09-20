require "../spec_helper"
require "../support/mcp_harness"

private def handshake(store) : JSON::Any
  lines = mcp_drive(store, %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}))
  lines.find { |l| l["id"]? == 1 }.not_nil!["result"]
end

describe "MCP handshake (#1090)" do
  it "tells every client that operator messages exist and how to read them" do
    with_store do |store|
      handshake(store)["instructions"].as_s.should contain("operator_messages")
    end
  end

  it "declares the claude/channel capability only when the operator turned channels on" do
    with_store do |store|
      prev = Gori::Settings.mcp_channels?
      begin
        Gori::Settings.mcp_channels = false
        handshake(store)["capabilities"]["experimental"]?.should be_nil
        Gori::Settings.mcp_channels = true
        handshake(store)["capabilities"]["experimental"]["claude/channel"].as_h.should be_empty
      ensure
        Gori::Settings.mcp_channels = prev
      end
    end
  end

  # …and never to a STATELESS client, however the operator has the setting. The channel is
  # an unsolicited notification on stdout, and 2026-07-28 allows a stdio server exactly
  # three kinds of outbound message — a response, a notification belonging to an in-flight
  # request, and one on an acknowledged `subscriptions/listen` stream. A courier frame from
  # a free-running fiber is none of them, so the capability is not offered where it cannot
  # be honoured. The socket, Codex-queue and `operator_messages` routes are unaffected:
  # none of them writes to stdout.
  it "never declares the channel to a client on the stateless revision" do
    with_store do |store|
      prev = Gori::Settings.mcp_channels?
      begin
        Gori::Settings.mcp_channels = true
        line = %({"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":) +
               %({"io.modelcontextprotocol/protocolVersion":"2026-07-28",) +
               %("io.modelcontextprotocol/clientCapabilities":{}}}})
        caps = mcp_drive(store, line)[0]["result"]["capabilities"]
        caps["tools"].as_h.should be_empty
        caps["experimental"]?.should be_nil
      ensure
        Gori::Settings.mcp_channels = prev
      end
    end
  end

  # …and not declaring it must not UNdeclare it. The latch the courier reads used to be
  # written inside the capabilities builder, which `server/discover` also calls — so a
  # dual-era client that handshook and then probed discovery once had its channel route
  # silently retired for the rest of the session. The push is the only way to see the latch
  # from outside, so this drives a real courier: the operator's line has to come back out as
  # a `claude/channel` frame AFTER the probe.
  it "keeps a declared channel across a server/discover probe" do
    reader, writer = IO.pipe
    prev = Gori::Settings.mcp_channels?
    begin
      Gori::Settings.mcp_channels = true
      with_store do |store|
        output = IO::Memory.new
        writer.puts(%({"jsonrpc":"2.0","id":1,"method":"initialize","params":) +
                    %({"protocolVersion":"2025-06-18","clientInfo":{"name":"claude-code"}}}))
        writer.puts(%({"jsonrpc":"2.0","id":2,"method":"server/discover"}))
        writer.flush
        spawn do
          # The courier starts on the discovery answer and anchors its cursor at the feed's
          # end, so the message is posted only once that answer is out — otherwise it is
          # behind the cursor and no route would ever be asked for it.
          100.times { break if output.to_s.includes?(%("id":2)); sleep 10.milliseconds }
          store.post_agent_message("the operator is asking", "all", nil)
          # `notifications/…`, not `claude/channel`: the handshake reply above already
          # carries that name, as the capability it declares.
          100.times { break if output.to_s.includes?("notifications/claude/channel"); sleep 20.milliseconds }
          writer.close rescue nil
        end
        Gori::MCP::Server.new(store, allow_actions: true, verify_upstream: false,
          input: reader, output: output).run
        output.to_s.should contain("notifications/claude/channel")
      end
    ensure
      Gori::Settings.mcp_channels = prev
      reader.try(&.close) rescue nil
      writer.try(&.close) rescue nil
    end
  end
end
