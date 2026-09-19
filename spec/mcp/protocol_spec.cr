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
end
