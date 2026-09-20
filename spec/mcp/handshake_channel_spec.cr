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
end
