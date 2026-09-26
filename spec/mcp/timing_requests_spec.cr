require "../spec_helper"
require "../support/mcp_harness"

# An h1 origin that accepts connections repeatedly and delays one path, so that variant is
# consistently slower — the differential signal timing_requests is meant to find.
private def start_mcp_timing_origin(slow_path : String, delay : Time::Span) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while conn = origin.accept?
      spawn_with(conn) do |c|
        head = Gori::Proxy::Codec::Http1.read_head(c)
        line = head ? String.new(head).lines.first? : nil
        sleep delay if line && line.includes?(slow_path)
        body = "ok"
        c << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n" << body
        c.flush
        c.close rescue nil
      end
    end
  rescue
  end
  port
end

private def seed_timing_repeater(store, port : Int32, path : String) : Int64
  store.insert_repeater(target: "http://127.0.0.1:#{port}",
    request: "GET #{path} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n".to_slice,
    http2: false, auto_cl: true, flow_id: nil, position: 0, sni: nil)
end

describe Gori::MCP::Server do
  describe "timing_requests" do
    it "returns a verdict + quartiles and finds the delayed variant slower" do
      with_store do |store|
        port = start_mcp_timing_origin("/slow", 6.milliseconds)
        a = seed_timing_repeater(store, port, "/slow")
        b = seed_timing_repeater(store, port, "/fast")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"timing_requests","arguments":{"repeater_ids":[#{a},#{b}],"count":30,"warmup":1,"allow_unscoped":true}}})
        resp = mcp_drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_false
        payload = mcp_tool_payload(resp)
        payload["verdict"].as_s.should eq("a_slower")
        payload["transport"].as_s.should eq("last-byte-sync h1")
        payload["pairs_valid"].as_i.should be >= 20
        payload["order"]["p_value"].as_f.should be < 0.01
        va = payload["variants"]["a"]
        vb = payload["variants"]["b"]
        va["median_us"].as_f.should be > vb["median_us"].as_f
        va["histogram"].as_a.size.should eq(Gori::Repeater::Timing::Stats::HIST_BINS)
      end
    end

    it "refuses anything but exactly two members" do
      with_store do |store|
        a = seed_timing_repeater(store, 9, "/a")
        b = seed_timing_repeater(store, 9, "/b")
        c = seed_timing_repeater(store, 9, "/c")
        one = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"timing_requests","arguments":{"repeater_ids":[#{a}],"allow_unscoped":true}}})
        r1 = mcp_drive(store, one, verify_upstream: false)[0]
        r1["result"]["isError"].as_bool.should be_true
        r1["result"]["content"][0]["text"].as_s.should contain("exactly two")
        three = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"timing_requests","arguments":{"repeater_ids":[#{a},#{b},#{c}],"allow_unscoped":true}}})
        r3 = mcp_drive(store, three, verify_upstream: false)[0]
        r3["result"]["isError"].as_bool.should be_true
        r3["result"]["content"][0]["text"].as_s.should contain("exactly two")
      end
    end

    it "refuses a pair that resolves to different origins" do
      with_store do |store|
        a = seed_timing_repeater(store, 8001, "/a")
        b = seed_timing_repeater(store, 8002, "/b")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"timing_requests","arguments":{"repeater_ids":[#{a},#{b}],"allow_unscoped":true}}})
        resp = mcp_drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.should contain("differ in origin")
      end
    end

    it "refuses a member id that names no session" do
      with_store do |store|
        a = seed_timing_repeater(store, 9, "/a")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"timing_requests","arguments":{"repeater_ids":[#{a},999999],"allow_unscoped":true}}})
        resp = mcp_drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.should contain("no repeater with id 999999")
      end
    end

    it "refuses a member with live §…§ markers, waived by verbatim" do
      with_store do |store|
        a = seed_timing_repeater(store, 9, "/apply")
        b = store.insert_repeater(target: "http://127.0.0.1:9",
          request: "GET /q?x=§payload§ HTTP/1.1\r\nHost: 127.0.0.1:9\r\n\r\n".to_slice,
          http2: false, auto_cl: true, flow_id: nil, position: 0, sni: nil)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"timing_requests","arguments":{"repeater_ids":[#{a},#{b}],"allow_unscoped":true}}})
        resp = mcp_drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.should contain("§")
      end
    end
  end
end
