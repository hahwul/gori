require "../spec_helper"
require "../support/mcp_harness"

# The JSON-RPC 2.0 ENVELOPE, checked before a message is read as a request (#1138).
#
# gori's MCP transport used to look at `method` and nothing else, so it answered
# `{"jsonrpc":"1.0"}`, a message carrying no version member at all, and ids of every shape
# JSON has — and it answered them in a `"jsonrpc":"2.0"` frame, rewriting the client's
# message into one it never sent. A client that ships a serialisation bug learns nothing
# from a server that repairs it, and a client correlating responses by id cannot match
# `{"id":{}}` against anything it is holding.
#
# The reader's `ping` fast path and the worker both read the envelope from one predicate,
# so a malformed line gets the same answer whichever fiber sees it first.
private def envelope_lines(store, *lines) : Array(JSON::Any)
  mcp_drive(store, *lines)
end

describe "MCP JSON-RPC envelope" do
  it "refuses a version that is not the string 2.0, and names what it got" do
    with_store do |store|
      out = envelope_lines(store,
        %({"jsonrpc":"1.0","id":1,"method":"ping"}),
        %({"jsonrpc":2,"id":2,"method":"ping"}),
        %({"jsonrpc":null,"id":3,"method":"ping"}))
      out.size.should eq(3)
      out.each(&.["error"]["code"].as_i.should(eq(-32600)))
      # Answered AT the request's own id: the client is holding a promise for it.
      out.map(&.["id"].as_i).should eq([1, 2, 3])
      out[0]["error"]["message"].as_s.should contain(%("1.0"))
      out[1]["error"]["message"].as_s.should contain("(got 2)")
    end
  end

  it "refuses a message with no jsonrpc member at all" do
    with_store do |store|
      out = envelope_lines(store, %({"id":7,"method":"ping"}))
      out.size.should eq(1)
      out[0]["error"]["code"].as_i.should eq(-32600)
      out[0]["error"]["message"].as_s.should contain("missing 'jsonrpc'")
      out[0]["id"].as_i.should eq(7)
    end
  end

  it "refuses an id that is not a string, a number or null — and answers at null" do
    with_store do |store|
      out = envelope_lines(store,
        %({"jsonrpc":"2.0","id":{},"method":"ping"}),
        %({"jsonrpc":"2.0","id":[1],"method":"ping"}),
        %({"jsonrpc":"2.0","id":true,"method":"ping"}))
      out.size.should eq(3)
      out.each do |l|
        l["error"]["code"].as_i.should eq(-32600)
        l["error"]["message"].as_s.should contain("'id' must be")
        # An id the spec does not allow cannot be echoed: the response would be
        # uncorrelatable either way, and null is what the spec says to send.
        l["id"].raw.should be_nil
      end
      out[0]["error"]["message"].as_s.should contain("an object")
      out[1]["error"]["message"].as_s.should contain("an array")
      out[2]["error"]["message"].as_s.should contain("a boolean")
    end
  end

  it "still serves a well-formed request, including the reader's ping fast path" do
    with_store do |store|
      out = envelope_lines(store,
        %({"jsonrpc":"2.0","id":4,"method":"ping"}),
        %({"jsonrpc":"2.0","id":"s","method":"ping"}),
        %({"jsonrpc":"2.0","id":null,"method":"ping"}))
      out.size.should eq(3)
      out.each(&.["error"]?.should(be_nil))
      out[0]["id"].as_i.should eq(4)
      out[1]["id"].as_s.should eq("s")
    end
  end

  it "holds a NOTIFICATION to the same envelope, and answers it at null" do
    with_store do |store|
      # A well-formed notification writes nothing at all…
      envelope_lines(store, %({"jsonrpc":"2.0","method":"notifications/initialized"})).should be_empty
      # …and a malformed one is a malformed message, reported the way the missing-`method`
      # case already is rather than swallowed.
      out = envelope_lines(store, %({"method":"notifications/initialized"}))
      out.size.should eq(1)
      out[0]["error"]["code"].as_i.should eq(-32600)
      out[0]["id"].raw.should be_nil
    end
  end

  it "checks every BATCH member, leaving its siblings' results beside the refusal" do
    with_store do |store|
      line = %([{"jsonrpc":"2.0","id":1,"method":"ping"},) +
             %({"jsonrpc":"1.0","id":2,"method":"ping"},) +
             %({"jsonrpc":"2.0","id":{},"method":"ping"}])
      out = envelope_lines(store, line)
      out.size.should eq(1)
      members = out[0].as_a
      members.size.should eq(3)
      members[0]["result"].should_not be_nil
      members[1]["error"]["code"].as_i.should eq(-32600)
      members[1]["id"].as_i.should eq(2)
      members[2]["error"]["code"].as_i.should eq(-32600)
      members[2]["id"].raw.should be_nil
    end
  end
end
