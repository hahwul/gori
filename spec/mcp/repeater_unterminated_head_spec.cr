require "../spec_helper"
require "../support/mcp_harness"

# #1075 on the MCP surface. The rule is the same one the CLI follows: an unterminated head is
# STORED and SENT exactly as handed in — a malformed request is a legitimate thing to send —
# and the only change is that every payload which reports a repeater request now says so.
#
# The field names are the point of these examples. An agent that learns to read
# `head_unterminated` on a create must find the same key on the listing it polls afterwards,
# or the marker is only as good as the surface it happened to be seen on first.
describe Gori::MCP::Server do
  describe "the unterminated-head marker" do
    truncated = "GET /x HTTP/1.1\\r\\nHost: api.test\\r\\n\\r"
    terminated = "GET /x HTTP/1.1\\r\\nHost: api.test\\r\\n\\r\\n"

    it "creates the session anyway, and names what it stored" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_repeater","arguments":{"target":"https://api.test","request":"#{truncated}"}}})
        resp = mcp_drive(store, call)[0]
        # NOT an error: the request was accepted and persisted, which is the whole design
        # constraint — gori has to be able to hold non-standard HTTP.
        resp["result"]["isError"]?.should_not be_true
        payload = mcp_tool_payload(resp)
        payload["id"].as_i64.should_not eq(0)
        payload["head_unterminated"].as_bool.should be_true
        payload["head_unterminated_note"].as_s.should eq(Gori::CLI::Run.unterminated_head_note)
      end
    end

    # Absent, not `false`: an untouched workbench must serialise exactly the payload it
    # always did.
    it "says nothing at all about a well-formed request" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_repeater","arguments":{"target":"https://api.test","request":"#{terminated}"}}})
        payload = mcp_tool_payload(mcp_drive(store, call)[0])
        payload["head_unterminated"]?.should be_nil
        payload["head_unterminated_note"]?.should be_nil
      end
    end

    # The write door a create-time-only marker would leave open: this tool replaces the
    # stored request wholesale, so a session created well-formed can become unterminated here.
    it "marks a session that update_repeater truncates, and clears the mark when it is fixed" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_repeater","arguments":{"target":"https://api.test","request":"#{terminated}"}}})
        id = mcp_tool_payload(mcp_drive(store, create)[0])["id"].as_i64

        broke = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"update_repeater","arguments":{"id":#{id},"request":"#{truncated}"}}})
        mcp_tool_payload(mcp_drive(store, broke)[0])["head_unterminated"].as_bool.should be_true

        fixed = %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"update_repeater","arguments":{"id":#{id},"request":"#{terminated}"}}})
        mcp_tool_payload(mcp_drive(store, fixed)[0])["head_unterminated"]?.should be_nil
      end
    end

    # The listing is where an agent finds the odd session out — the stored bytes of an
    # unterminated request render identically to a well-formed one everywhere else.
    it "carries the mark on the session listing get_repeater_context returns" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_repeater","arguments":{"target":"https://api.test","request":"#{truncated}"}}})
        id = mcp_tool_payload(mcp_drive(store, create)[0])["id"].as_i64

        ctx = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_repeater_context","arguments":{"id":#{id}}}})
        session = mcp_tool_payload(mcp_drive(store, ctx)[0])["sessions"][0]
        session["db_id"].as_i64.should eq(id)
        session["head_unterminated"].as_bool.should be_true
        session["head_unterminated_note"].as_s.should eq(Gori::CLI::Run.unterminated_head_note)
      end
    end

    # HTTP/2 has no blank-line head terminator on the wire: `H2Engine` re-encodes this text
    # as an HPACK field list in which the missing line was never represented. Marking an h2
    # session would leave a permanent defect flag on a tab whose every send is well-formed.
    it "exempts an HTTP/2 session on both the write and the listing" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_repeater","arguments":{"target":"https://api.test","request":"#{truncated}","http2":true}}})
        payload = mcp_tool_payload(mcp_drive(store, create)[0])
        payload["head_unterminated"]?.should be_nil
        id = payload["id"].as_i64

        ctx = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_repeater_context","arguments":{"id":#{id}}}})
        mcp_tool_payload(mcp_drive(store, ctx)[0])["sessions"][0]["head_unterminated"]?.should be_nil

        # …and switching the same row back to HTTP/1.1 brings the mark back, because the
        # bytes have not changed — only the engine that will frame them.
        h1 = %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"update_repeater","arguments":{"id":#{id},"http2":false}}})
        mcp_tool_payload(mcp_drive(store, h1)[0])["head_unterminated"].as_bool.should be_true
      end
    end

    # `WsEngine.build_handshake` re-terminates a framed handshake on every send, so marking
    # one would accuse gori of sending bytes it does not send. `ws_http_only` sends the same
    # bytes through the HTTP engine instead — untouched — so that session IS marked.
    it "exempts a framed WebSocket handshake but not a ws_http_only one" do
      with_store do |store|
        ws = "GET /chat HTTP/1.1\\r\\nHost: api.test\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\n\\r"
        framed = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_repeater","arguments":{"target":"https://api.test","request":"#{ws}"}}})
        mcp_tool_payload(mcp_drive(store, framed)[0])["head_unterminated"]?.should be_nil

        as_http = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_repeater","arguments":{"target":"https://api.test","request":"#{ws}","ws_http_only":true}}})
        mcp_tool_payload(mcp_drive(store, as_http)[0])["head_unterminated"].as_bool.should be_true
      end
    end
  end
end
