require "../spec_helper"
require "../support/mcp_harness"

# An h1 origin that accepts N connections (one per race member) and records each request line,
# replying 200 + a per-path body so a test can tell the members apart.
private def start_mcp_race_origin(seen : Channel(String)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while conn = origin.accept?
      spawn_with(conn) do |c|
        head = Gori::Proxy::Codec::Http1.read_head(c)
        line = head ? String.new(head).lines.first? : nil
        seen.send(line || "")
        body = "hit"
        c << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n" << body
        c.flush
        c.close rescue nil
      end
    end
  rescue
  end
  port
end

private def seed_race_repeater(store, port : Int32, path : String) : Int64
  store.insert_repeater(target: "http://127.0.0.1:#{port}",
    request: "GET #{path} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n".to_slice,
    http2: false, auto_cl: true, flow_id: nil, position: 0, sni: nil)
end

describe Gori::MCP::Server do
  describe "race_requests" do
    it "races two saved repeaters against one origin and returns a result per member" do
      with_store do |store|
        seen = Channel(String).new(4)
        port = start_mcp_race_origin(seen)
        a = seed_race_repeater(store, port, "/apply-coupon")
        b = seed_race_repeater(store, port, "/checkout")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"race_requests","arguments":{"repeater_ids":[#{a},#{b}],"allow_unscoped":true}}})
        resp = mcp_drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_false
        payload = mcp_tool_payload(resp)
        payload["transport"].as_s.should eq("last-byte-sync h1")
        payload["responded"].as_i.should eq(2)
        members = payload["members"].as_a
        members.size.should eq(2)
        members.all?(&.["ok"].as_bool).should be_true
        members.all? { |m| m["status"].as_i == 200 }.should be_true

        got = [seen.receive, seen.receive].map(&.strip)
        got.sort.should eq(["GET /apply-coupon HTTP/1.1", "GET /checkout HTTP/1.1"])
      end
    end

    it "refuses a race of fewer than two members" do
      with_store do |store|
        rid = seed_race_repeater(store, 9, "/only")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"race_requests","arguments":{"repeater_ids":[#{rid}],"allow_unscoped":true}}})
        resp = mcp_drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.should contain("at least two")
      end
    end

    it "refuses a race whose members resolve to different origins" do
      with_store do |store|
        a = seed_race_repeater(store, 8001, "/a")
        b = seed_race_repeater(store, 8002, "/b")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"race_requests","arguments":{"repeater_ids":[#{a},#{b}],"allow_unscoped":true}}})
        resp = mcp_drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.should contain("differ in origin")
      end
    end

    it "refuses a member id that names no session" do
      with_store do |store|
        a = seed_race_repeater(store, 9, "/a")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"race_requests","arguments":{"repeater_ids":[#{a},999999],"allow_unscoped":true}}})
        resp = mcp_drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.should contain("no repeater with id 999999")
      end
    end

    # Sibling parity: send_request's repeater_id replay and send-group both refuse a session
    # whose request still holds live §…§ markers — the race must too, or it would put the literal
    # § bytes on the wire. verbatim waives it.
    it "refuses a member whose stored request holds live §…§ markers (waived by verbatim)" do
      with_store do |store|
        a = seed_race_repeater(store, 9, "/apply")
        b = store.insert_repeater(target: "http://127.0.0.1:9",
          request: "GET /q?x=§payload§ HTTP/1.1\r\nHost: 127.0.0.1:9\r\n\r\n".to_slice,
          http2: false, auto_cl: true, flow_id: nil, position: 0, sni: nil)
        args = %({"repeater_ids":[#{a},#{b}],"allow_unscoped":true})
        resp = mcp_drive(store, %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"race_requests","arguments":#{args}}}), verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.should contain("§")
        # verbatim waives it → past the marker gate (fails later on the dead port, not INVALID_ARGUMENT).
        vargs = %({"repeater_ids":[#{a},#{b}],"allow_unscoped":true,"verbatim":true})
        vresp = mcp_drive(store, %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"race_requests","arguments":#{vargs}}}), verify_upstream: false)[0]
        mcp_tool_payload(vresp)["members"]?.should_not be_nil # produced a race result, not a marker refusal
      end
    end

    # The group rides one Sender built from the anchor, so a member differing in SNI (or CL
    # policy / TLS preset) would be silently sent under the anchor's — refuse instead.
    it "refuses members that share an origin but differ in SNI" do
      with_store do |store|
        a = store.insert_repeater(target: "http://127.0.0.1:9", request: "GET /a HTTP/1.1\r\nHost: 127.0.0.1:9\r\n\r\n".to_slice,
          http2: false, auto_cl: true, flow_id: nil, position: 0, sni: nil)
        b = store.insert_repeater(target: "http://127.0.0.1:9", request: "GET /b HTTP/1.1\r\nHost: 127.0.0.1:9\r\n\r\n".to_slice,
          http2: false, auto_cl: true, flow_id: nil, position: 0, sni: "other.example")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"race_requests","arguments":{"repeater_ids":[#{a},#{b}],"allow_unscoped":true}}})
        resp = mcp_drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.should contain("SNI")
      end
    end
  end
end
