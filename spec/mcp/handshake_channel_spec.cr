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
end
