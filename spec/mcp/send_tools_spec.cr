require "../spec_helper"
require "../support/mcp_harness"

# An origin that reads the upgrade and REFUSES it with a real HTTP response. The handshake
# failed, but the origin answered — the distinction `WsEngine::Result#answered?` draws, and
# the one that decides whether a session's stored last response is replaced.
private def start_refusing_ws_origin(status : Int32) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    conn = origin.accept?
    origin.close rescue nil
    next unless conn
    begin
      conn.read_timeout = 5.seconds
      Gori::Proxy::Codec::Http1.read_head(conn)
      conn << "HTTP/1.1 #{status} Forbidden\r\nContent-Length: 0\r\n\r\n"
      conn.flush
    rescue
    ensure
      conn.close rescue nil
    end
  end
  port
end

# One-shot HTTP/1 origin used to verify send_request audit recording, response
# header redaction, and continuation reads for bodies larger than the MCP cap.
private def start_mcp_http_origin(body : String, extra_headers = "") : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Gori::Proxy::Codec::Http1.read_head(conn)
    conn << "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n" \
            "Content-Length: #{body.bytesize}\r\n#{extra_headers}\r\n#{body}"
    conn.flush
    conn.close
    origin.close
  rescue
    origin.close rescue nil
  end
  port
end

# One-shot origin that writes RAW response bytes (framing and all), so a test can hand the
# engine a chunked body with a trailer section, an 8-bit header value, or two conflicting
# Content-Length lines — shapes `start_mcp_http_origin` cannot express.
private def start_mcp_raw_origin(response : Bytes) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    Gori::Proxy::Codec::Http1.read_head(conn)
    conn.write(response)
    conn.flush
    conn.close
    origin.close
  rescue
    origin.close rescue nil
  end
  port
end

# One-shot origin that RECORDS the exact request bytes it received into `sink`, then replies
# 204. The recorded bytes — not gori's echo — are the evidence for a byte-exact send.
private def start_mcp_recording_origin(sink : Channel(Bytes)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    buf = IO::Memory.new
    begin
      if conn = origin.accept?
        # Read RAW to an idle timeout — no HTTP parsing. The whole point of these sends is
        # bytes a parser might reject, so a parsing origin could not record them.
        conn.read_timeout = 300.milliseconds
        tmp = Bytes.new(4096)
        begin
          while (n = conn.read(tmp)) > 0
            buf.write(tmp[0, n])
          end
        rescue
          # idle — the client has sent everything it is going to send
        end
        conn << "HTTP/1.1 204 No Content\r\n\r\n" rescue nil
        conn.flush rescue nil
        conn.close rescue nil
      end
    ensure
      origin.close rescue nil
      sink.send(buf.to_slice) rescue nil
    end
  end
  port
end

describe Gori::MCP::Server do
  describe "send_request" do
    it "records a successful request in History by default and redacts sensitive response headers" do
      with_store do |store|
        port = start_mcp_http_origin("hello", "Set-Cookie: session=top-secret\r\n")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/audit","allow_unscoped":true}}})
        resp = mcp_drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_false
        payload = mcp_tool_payload(resp)
        flow_id = payload["recorded_flow_id"].as_i64
        payload["headers"].as_a.find { |header| header["name"].as_s == "Set-Cookie" }.not_nil!["value"].as_s.should eq("[REDACTED]")
        payload["sensitive_headers_redacted"].as_bool.should be_true
        detail = store.get_flow(flow_id).not_nil!
        detail.row.target.should eq("/audit")
        detail.row.status.should eq(200)
        String.new(detail.response_body.not_nil!).should eq("hello")
      end
    end

    it "applies request-side Match & Replace rules only when apply_rules:true (R2-2)" do
      with_store do |store|
        port = start_mcp_http_origin("ok")
        Gori::Rules.load(store).add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
          "X-Rewritten", "gori-rewritten", op: Gori::Store::RuleOp::SetHeader)

        # apply_rules:true → the rule rewrites the OUTGOING request (and the recorded flow).
        on = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/","apply_rules":true,"allow_unscoped":true}}})
        payload = mcp_tool_payload(mcp_drive(store, on, verify_upstream: false)[0])
        payload["match_replace_applied"].as_bool.should be_true
        detail = store.get_flow(payload["recorded_flow_id"].as_i64).not_nil!
        String.new(detail.request_head).should contain("gori-rewritten")

        # default (no apply_rules) → byte-exact, rule NOT applied, flag absent.
        off = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/","allow_unscoped":true}}})
        p2 = mcp_tool_payload(mcp_drive(store, off, verify_upstream: false)[0])
        p2["match_replace_applied"]?.should be_nil
        d2 = store.get_flow(p2["recorded_flow_id"].as_i64).not_nil!
        String.new(d2.request_head).should_not contain("gori-rewritten")
      end
    end

    # An origin's trailer used to appear NOWHERE in the result while the `Trailer:`
    # announcement was echoed among the headers — which reads as "the origin sent none". A
    # trailer is where a trailer-smuggling / gRPC-over-h1 test's whole answer lives.
    it "surfaces a chunked response's trailers, separately from the headers" do
      with_store do |store|
        port = start_mcp_raw_origin(("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTrailer: X-T\r\n" \
                                     "Connection: close\r\n\r\n5\r\nhello\r\n0\r\nX-T: gotcha\r\n\r\n").to_slice)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/t","allow_unscoped":true}}})
        payload = mcp_tool_payload(mcp_drive(store, call, verify_upstream: false)[0])
        payload["body"]["text"].as_s.should eq("hello")
        payload["body"]["trailers"].as_a.map { |t| {t["name"].as_s, t["value"].as_s} }
          .should eq([{"X-T", "gotcha"}])
        # and it is NOT laundered into the header list, where it would be indistinguishable
        # from a header the origin actually sent in the head
        payload["headers"].as_a.map { |h| h["name"].as_s }.should_not contain("X-T")
      end
    end

    # The BODY had a base64 fallback for bytes JSON cannot carry; a header VALUE did not, so
    # `X-Bin: \x80\xff` came back as `X-Bin: ��` and the real octets were unrecoverable
    # through MCP entirely.
    it "hands back the exact bytes of a response header value it had to scrub" do
      with_store do |store|
        resp = IO::Memory.new
        resp << "HTTP/1.1 200 OK\r\nX-Bin: "
        resp.write(Bytes[0x80, 0xff])
        resp << "\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        port = start_mcp_raw_origin(resp.to_slice)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/h","allow_unscoped":true}}})
        payload = mcp_tool_payload(mcp_drive(store, call, verify_upstream: false)[0])
        hdr = payload["headers"].as_a.find { |h| h["name"].as_s == "X-Bin" }.not_nil!
        hdr["value_lossy"].as_bool.should be_true
        Base64.decode(hdr["value_base64"].as_s).should eq(Bytes[0x80, 0xff])
      end
    end

    # Two conflicting Content-Length headers is a response-splitting condition — arguably the
    # single most interesting result a tester can get — and it came back as
    # `error_kind:"other", error_code:"NETWORK_ERROR", retryable:true`, so an agent loops on
    # it forever instead of reporting a finding. gori raises this itself; a retry reproduces
    # it exactly.
    it "reports a deterministic protocol refusal as PROTOCOL_ERROR, not a retryable network error" do
      with_store do |store|
        port = start_mcp_raw_origin(("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 6\r\n" \
                                     "Connection: close\r\n\r\nhello").to_slice)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/s","allow_unscoped":true}}})
        payload = mcp_tool_payload(mcp_drive(store, call, verify_upstream: false)[0])
        payload["error"].as_s.should contain("Content-Length")
        payload["error_kind"].as_s.should eq("protocol")
        payload["error_code"].as_s.should eq("PROTOCOL_ERROR")
        payload["retryable"].as_bool.should be_false
      end
    end

    it "still reports a genuine connect failure as a retryable NETWORK_ERROR" do
      with_store do |store|
        closed = TCPServer.new("127.0.0.1", 0)
        port = closed.local_address.port
        closed.close
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/x","allow_unscoped":true}}})
        payload = mcp_tool_payload(mcp_drive(store, call, verify_upstream: false)[0])
        payload["error_kind"].as_s.should eq("connect")
        payload["error_code"].as_s.should eq("NETWORK_ERROR")
        payload["retryable"].as_bool.should be_true
      end
    end

    # A JSON string reaches the socket as its UTF-8 ENCODING, so `raw` could never put a raw
    # 0x00/0x80-0xFF byte on the wire — and `isError:false` plus an echo of the intended text
    # meant the caller never learned. The ORIGIN's recorded bytes are the evidence.
    it "puts raw_base64's exact octets on the wire (0x00, 0x80-0xFF, a lone surrogate)" do
      with_store do |store|
        sink = Channel(Bytes).new(1)
        port = start_mcp_recording_origin(sink)
        wire = IO::Memory.new
        wire << "POST /b HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nX-Bin: "
        wire.write(Bytes[0x80, 0x81, 0xfe, 0xff])
        wire << "\r\nContent-Length: 6\r\n\r\n"
        wire.write(Bytes[0x00, 0x80, 0xff, 0xed, 0xa0, 0x80]) # NUL, high bytes, a lone surrogate
        bytes = wire.to_slice
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":) +
               %({"url":"http://127.0.0.1:#{port}/","raw_base64":"#{Base64.strict_encode(bytes)}","allow_unscoped":true}}})
        mcp_drive(store, call, verify_upstream: false)
        sink.receive.should eq(bytes)
      end
    end

    it "puts body_base64's exact octets on the wire with a byte-accurate Content-Length" do
      with_store do |store|
        sink = Channel(Bytes).new(1)
        port = start_mcp_recording_origin(sink)
        body = Bytes[0x00, 0x80, 0xff]
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":) +
               %({"url":"http://127.0.0.1:#{port}/p","method":"POST","body_base64":"#{Base64.strict_encode(body)}","allow_unscoped":true}}})
        mcp_drive(store, call, verify_upstream: false)
        got = sink.receive
        String.new(got).should contain("Content-Length: 3")
        got[(got.size - 3)..].should eq(body)
      end
    end

    # `gori run repeater send --verbatim` and `send_websocket{repeater_id, verbatim}` have both
    # honoured this on a stored session; `send_request{repeater_id}` read the argument nowhere,
    # so a stored `$where` NoSQL payload was substituted (or refused for an unbound name) and
    # the reply reported a clean send of bytes the operator never wrote (#906).
    it "sends a repeater_id replay verbatim: no $VAR expansion, no CL resync" do
      with_store do |store|
        Gori::Env.save_project(store, [{"where", "SUBSTITUTED"}])
        sink = Channel(Bytes).new(1)
        port = start_mcp_recording_origin(sink)
        # Content-Length deliberately disagrees with the body: under verbatim it must survive.
        rid = store.insert_repeater(target: "http://127.0.0.1:#{port}",
          request: %(POST /q HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nContent-Length: 3\r\n\r\n{"$where":"1==1"}).to_slice,
          http2: false, auto_cl: true, flow_id: nil, position: 0, sni: nil)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"repeater_id":#{rid},"verbatim":true,"allow_unscoped":true}}})
        mcp_drive(store, call, verify_upstream: false)
        got = String.new(sink.receive)
        got.should contain(%({"$where":"1==1"}))
        got.should_not contain("SUBSTITUTED")
        got.should contain("Content-Length: 3")
      end
    end

    # h2 lowercases every field name (RFC 9113 §8.2.1), which is the one normalization a flow
    # replay still applies — everything else on that path is already byte-exact. The RECORDED
    # head is the evidence: it is written from the encoded wire before the dial, so a dead port
    # is enough.
    it "keeps a captured field's case on an h2 flow replay under verbatim" do
      with_store do |store|
        seed = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "http", host: "127.0.0.1", port: 1,
          method: "GET", target: "/c", http_version: "HTTP/1.1",
          head: "GET /c HTTP/1.1\r\nHost: 127.0.0.1:1\r\nX-Case-Probe: v\r\n\r\n".to_slice,
          body: nil, source: Gori::FlowSource::Kind::Proxy))
        heads = {true, false}.map do |verbatim|
          call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"flow_id":#{seed},"http2":true,"verbatim":#{verbatim},"allow_unscoped":true}}})
          id = mcp_tool_payload(mcp_drive(store, call)[0])["recorded_flow_id"].as_i64
          String.new(store.get_flow(id).not_nil!.request_head)
        end
        heads[0].should contain("X-Case-Probe")
        heads[1].should contain("x-case-probe")
      end
    end

    # The other half of `expand_request: !verbatim` on this path: the head pass is also what
    # promotes a bare LF to CRLF, and a bare-LF header terminator is the desync primitive the
    # flag exists to deliver. Only the $VAR and Content-Length halves had examples.
    it "keeps a bare-LF head terminator on a repeater_id replay under verbatim" do
      with_store do |store|
        sink = Channel(Bytes).new(1)
        port = start_mcp_recording_origin(sink)
        rid = store.insert_repeater(target: "http://127.0.0.1:#{port}",
          request: "GET /lf HTTP/1.1\nHost: 127.0.0.1:#{port}\n\n".to_slice,
          http2: false, auto_cl: true, flow_id: nil, position: 0, sni: nil)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"repeater_id":#{rid},"verbatim":true,"allow_unscoped":true}}})
        mcp_drive(store, call, verify_upstream: false)
        String.new(sink.receive).should_not contain("\r\n")
      end
    end

    it "promotes a bare-LF head on a repeater_id replay without verbatim" do
      with_store do |store|
        sink = Channel(Bytes).new(1)
        port = start_mcp_recording_origin(sink)
        rid = store.insert_repeater(target: "http://127.0.0.1:#{port}",
          request: "GET /lf HTTP/1.1\nHost: 127.0.0.1:#{port}\n\n".to_slice,
          http2: false, auto_cl: true, flow_id: nil, position: 0, sni: nil)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"repeater_id":#{rid},"allow_unscoped":true}}})
        mcp_drive(store, call, verify_upstream: false)
        String.new(sink.receive).should contain("\r\n")
      end
    end

    it "expands $VARs on a repeater_id replay without verbatim" do
      with_store do |store|
        Gori::Env.save_project(store, [{"where", "SUBSTITUTED"}])
        sink = Channel(Bytes).new(1)
        port = start_mcp_recording_origin(sink)
        rid = store.insert_repeater(target: "http://127.0.0.1:#{port}",
          request: %(POST /q HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nContent-Length: 17\r\n\r\n{"$where":"1==1"}).to_slice,
          http2: false, auto_cl: true, flow_id: nil, position: 0, sni: nil)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"repeater_id":#{rid},"allow_unscoped":true}}})
        mcp_drive(store, call, verify_upstream: false)
        String.new(sink.receive).should contain("SUBSTITUTED")
      end
    end

    it "allows an explicit unaudited send and an explicit sensitive-header response" do
      with_store do |store|
        port = start_mcp_http_origin("ok", "Set-Cookie: session=visible\r\n")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/","record_history":false,"include_sensitive_headers":true,"allow_unscoped":true}}})
        payload = mcp_tool_payload(mcp_drive(store, call, verify_upstream: false)[0])
        payload["recorded_flow_id"].raw.should be_nil
        payload["headers"].as_a.find { |header| header["name"].as_s == "Set-Cookie" }.not_nil!["value"].as_s.should eq("session=visible")
        store.count.should eq(0)
      end
    end

    it "pages the complete stored response after the inline body is truncated" do
      with_store do |store|
        body = "a" * (Gori::MCP::Serialize::MAX_TEXT + 4096)
        port = start_mcp_http_origin(body)
        send = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/big","allow_unscoped":true}}})
        sent = mcp_tool_payload(mcp_drive(store, send, verify_upstream: false)[0])
        sent["body"]["truncated"].as_bool.should be_true
        flow_id = sent["recorded_flow_id"].as_i64

        chunk_call = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_response_body_chunk","arguments":{"flow_id":#{flow_id},"offset":#{Gori::MCP::Serialize::MAX_TEXT},"limit":4096}}})
        chunk = mcp_tool_payload(mcp_drive(store, chunk_call)[0])
        chunk["returned_bytes"].as_i.should eq(4096)
        chunk["complete"].as_bool.should be_true
        chunk["text"].as_s.should eq("a" * 4096)
      end
    end

    it "repeaters a captured flow via flow_id without a url" do
      with_store do |store|
        id = mcp_seed_flow(store, "ex.test", "GET", "/repeater-me", 200)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"flow_id":#{id},"allow_unscoped":true}}})
        resp = mcp_drive(store, call, verify_upstream: false)[0]
        # May fail to connect in CI, but must NOT error with 'url is required'.
        resp["result"]["content"][0]["text"].as_s.should_not contain("'url' is required")
      end
    end

    it "honors an explicit http2:false to downgrade an h2-captured flow to HTTP/1.1" do
      with_store do |store|
        port = start_mcp_http_origin("downgraded")
        # A flow captured over h2 (http_version HTTP/2). Sending it to this HTTP/1.1
        # origin only succeeds if http2:false actually downgrades the transport — the
        # bug was `http2 = bool(h,"http2") || flow.http2`, where an explicit false was
        # OR'd away and the send stayed h2 (h2c to an h1 origin, which fails).
        id = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "http", host: "127.0.0.1", port: port,
          method: "GET", target: "/h2flow", http_version: "HTTP/2",
          head: "GET /h2flow HTTP/2\r\nHost: 127.0.0.1:#{port}\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"flow_id":#{id},"http2":false,"allow_unscoped":true}}})
        resp = mcp_drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_false
        mcp_tool_payload(resp)["status"].as_i.should eq(200)
      end
    end

    it "bounds a hung read with timeout_ms and returns a network-error result" do
      with_store do |store|
        origin = TCPServer.new("127.0.0.1", 0)
        port = origin.local_address.port
        spawn do
          if conn = origin.accept? # accept, then never respond so the read idles out
            sleep 5.seconds
            conn.close rescue nil
          end
        rescue
        end
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/","timeout_ms":200,"allow_unscoped":true}}})
        resp = mcp_drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_true
        mcp_tool_payload(resp)["error"].as_s.empty?.should be_false
        origin.close rescue nil
      end
    end

    it "returns isError on a connection failure (port 1)" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:1/","allow_unscoped":true}}})
        resp = mcp_drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true
        payload = mcp_tool_payload(resp)
        payload["error"].as_s.downcase.should contain("fail")
        payload["error_kind"].as_s.should eq("connect")       # classified network error
        payload["error_code"].as_s.should eq("NETWORK_ERROR") # structured-error contract (criterion #4)
        payload["retryable"].as_bool.should be_true
        store.get_flow(payload["recorded_flow_id"].as_i64).not_nil!.row.state.error?.should be_true
      end
    end

    it "preserves the attempt duration on a failed send's History flow" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:1/","allow_unscoped":true}}})
        payload = mcp_tool_payload(mcp_drive(store, call)[0])
        detail = store.get_flow(payload["recorded_flow_id"].as_i64).not_nil!
        detail.row.state.error?.should be_true
        detail.row.duration_us.should_not be_nil # was null before — the attempt time is kept
      end
    end

    it "links a saved repeater to an issue even when the origin is unavailable" do
      with_store do |store|
        issue_id = store.insert_issue("evidence", Gori::Store::Severity::Low, nil, nil)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:1/","save_as_repeater":true,"issue_id":#{issue_id},"allow_unscoped":true}}})
        mcp_drive(store, call)[0]["result"]["isError"].as_bool.should be_true
        repeater_id = store.repeaters_meta.last.id
        links = store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id)
        links.any? { |link| link.ref_kind.repeater? && link.ref_id == repeater_id }.should be_true
      end
    end

    it "save_as_repeater keeps the source SNI and does not force auto_content_length on" do
      with_store do |store|
        port = start_mcp_http_origin("ok")
        # Seed a repeater with an SNI and auto_cl OFF (byte-exact / CL-desync probe).
        rid = store.insert_repeater(
          target: "http://127.0.0.1:#{port}",
          request: "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice,
          http2: false, auto_cl: false, flow_id: nil, position: 0,
          sni: "backend.internal.example.com")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"repeater_id":#{rid},"save_as_repeater":true,"allow_unscoped":true}}})
        resp = mcp_drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_false
        # New row is the last repeater; source row kept.
        saved = store.repeaters_meta.last
        saved.id.should_not eq(rid)
        rec = store.get_repeater(saved.id).not_nil!
        rec.sni.should eq("backend.internal.example.com")
        rec.auto_content_length?.should be_false
      end
    end

    it "includes effective_request on a url send (no ignored fields)" do
      with_store do |store|
        port = start_mcp_http_origin("ok")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/path","method":"POST","allow_unscoped":true}}})
        p = mcp_tool_payload(mcp_drive(store, call, verify_upstream: false)[0])
        er = p["effective_request"]
        er["scheme"].as_s.should eq("http")
        er["host"].as_s.should eq("127.0.0.1")
        er["port"].as_i.should eq(port)
        er["method"].as_s.should eq("POST")
        er["target"].as_s.should eq("/path")
        p.as_h.has_key?("ignored_fields").should be_false
      end
    end

    # #906. The precedence used to be a REPORT: the stored request went out and
    # `ignored_fields` explained afterwards which overrides had been dropped — which, for a
    # state-changing repeater an agent meant to re-aim, is a second real execution announced
    # after the fact. It is a refusal now, and these four assert the refusal is COMPLETE:
    # no History row, and the one-shot origin still unconsumed.
    it "refuses repeater_id + request overrides without sending anything" do
      with_store do |store|
        port = start_mcp_http_origin("only-one-response")
        rid = store.insert_repeater(target: "http://127.0.0.1:#{port}",
          request: "POST /orders HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nContent-Length: 2\r\n\r\n{}".to_slice,
          http2: false, auto_cl: true, flow_id: nil, position: 0, sni: nil)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"repeater_id":#{rid},"url":"http://127.0.0.1:#{port}/harmless","method":"GET","body":"replacement","allow_unscoped":true}}})
        resp = mcp_drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_true
        sc = resp["result"]["structuredContent"]
        sc["error_code"].as_s.should eq("INVALID_ARGUMENT")
        fields = sc["details"]["conflicting_fields"].as_a.map(&.as_s)
        fields.should eq(["repeater_id", "url", "method", "body"])
        # The SOURCE, not the override — removing the override is what re-sends the stored POST.
        sc["field"].as_s.should eq("repeater_id")
        # Nothing reached the wire: no History row, and the origin's single response is still
        # there for the send that follows.
        store.recent_flows(10).should be_empty
        ok = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"repeater_id":#{rid},"allow_unscoped":true}}})
        mcp_tool_payload(mcp_drive(store, ok, verify_upstream: false)[0])["status"].as_i.should eq(200)
      end
    end

    it "refuses flow_id + url/method before the send and records no flow" do
      with_store do |store|
        id = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "http", host: "127.0.0.1", port: 1,
          method: "GET", target: "/seed", http_version: "HTTP/1.1",
          head: "GET /seed HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"flow_id":#{id},"url":"http://elsewhere.test/x","method":"POST","allow_unscoped":true}}})
        resp = mcp_drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true
        sc = resp["result"]["structuredContent"]
        sc["error_code"].as_s.should eq("INVALID_ARGUMENT")
        sc["details"]["conflicting_fields"].as_a.map(&.as_s).should eq(["flow_id", "url", "method"])
        text = resp["result"]["content"][0]["text"].as_s
        text.should contain("NOTHING was sent")
        text.should contain("get_flow")
        # The seed flow is the only row — no outbound request was recorded.
        store.recent_flows(10).map(&.id).should eq([id])
      end
    end

    it "refuses flow_id + repeater_id as a conflict naming both" do
      with_store do |store|
        fid = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "http", host: "127.0.0.1", port: 1,
          method: "GET", target: "/seed", http_version: "HTTP/1.1",
          head: "GET /seed HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
        rid = store.insert_repeater(target: "http://127.0.0.1:1",
          request: "GET /rep HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n".to_slice,
          http2: false, auto_cl: true, flow_id: nil, position: 0, sni: nil)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"flow_id":#{fid},"repeater_id":#{rid},"allow_unscoped":true}}})
        resp = mcp_drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true
        sc = resp["result"]["structuredContent"]
        sc["error_code"].as_s.should eq("INVALID_ARGUMENT")
        sc["details"]["conflicting_fields"].as_a.map(&.as_s).should eq(["flow_id", "repeater_id"])
        store.recent_flows(10).map(&.id).should eq([fid])
      end
    end

    it "refuses h2_fields beside a stored source with the same coded conflict" do
      with_store do |store|
        rid = store.insert_repeater(target: "http://127.0.0.1:1",
          request: "GET /rep HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n".to_slice,
          http2: false, auto_cl: true, flow_id: nil, position: 0, sni: nil)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"repeater_id":#{rid},"h2_fields":[[":method","GET"]],"allow_unscoped":true}}})
        resp = mcp_drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true
        sc = resp["result"]["structuredContent"]
        sc["error_code"].as_s.should eq("INVALID_ARGUMENT")
        sc["details"]["conflicting_fields"].as_a.map(&.as_s).should eq(["repeater_id", "h2_fields"])
        store.recent_flows(10).should be_empty
      end
    end

    # Per-send MODIFIERS are the other half of the contract: they still combine with a source,
    # so the refusal above cannot be implemented by refusing everything. The session is stored
    # as h2 and the origin speaks h1 ONLY, so a 200 is proof `http2:false` was threaded through
    # — not merely that the call was allowed past the gate.
    it "still honours per-send modifiers alongside repeater_id" do
      with_store do |store|
        port = start_mcp_http_origin("modifier-ok")
        rid = store.insert_repeater(target: "http://127.0.0.1:#{port}",
          request: "GET /rep HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n".to_slice,
          http2: true, auto_cl: true, flow_id: nil, position: 0, sni: nil)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"repeater_id":#{rid},"http2":false,"timeout_ms":5000,"insecure":true,"allow_unscoped":true}}})
        p = mcp_tool_payload(mcp_drive(store, call, verify_upstream: false)[0])
        p["status"].as_i.should eq(200)
        p["effective_request"]["http_version"].as_s.should eq("HTTP/1.1")
        p.as_h.has_key?("ignored_fields").should be_false
      end
    end

    # An argument that names nothing is not a second request. A client filling every declared
    # property of the schema sends these beside the one argument it means.
    it "does not read an empty url/headers/body as a conflicting override" do
      with_store do |store|
        port = start_mcp_http_origin("empty-args-ok")
        rid = store.insert_repeater(target: "http://127.0.0.1:#{port}",
          request: "GET /rep HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n".to_slice,
          http2: false, auto_cl: true, flow_id: nil, position: 0, sni: nil)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"repeater_id":#{rid},"url":"","headers":{},"raw_base64":"","allow_unscoped":true}}})
        mcp_tool_payload(mcp_drive(store, call, verify_upstream: false)[0])["status"].as_i.should eq(200)
      end
    end

    # `field` is what a client rendering a single argument tells the model to remove, and
    # removing an override re-sends the stored request — the side effect the gate exists to
    # prevent. So it names the SOURCE, and both halves of a doubled conflict are reported at
    # once rather than over two round trips.
    it "points `field` at the source and reports both halves of a doubled conflict" do
      with_store do |store|
        fid = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "http", host: "127.0.0.1", port: 1,
          method: "GET", target: "/seed", http_version: "HTTP/1.1",
          head: "GET /seed HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
        rid = store.insert_repeater(target: "http://127.0.0.1:1",
          request: "GET /rep HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n".to_slice,
          http2: false, auto_cl: true, flow_id: nil, position: 0, sni: nil)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"flow_id":#{fid},"repeater_id":#{rid},"url":"http://x.test/","body":"b","allow_unscoped":true}}})
        sc = mcp_drive(store, call)[0]["result"]["structuredContent"]
        sc["field"].as_s.should eq("flow_id")
        sc["details"]["conflicting_fields"].as_a.map(&.as_s).should eq(["flow_id", "repeater_id", "url", "body"])
      end
    end

    # The h1 text carrier cannot hold what an h2_fields caller is testing, so "describe the
    # request with url/method/headers/body" is the wrong way out of THAT conflict.
    it "points an h2_fields conflict at url + h2_fields, not at the h1 carrier" do
      with_store do |store|
        rid = store.insert_repeater(target: "http://127.0.0.1:1",
          request: "GET /rep HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n".to_slice,
          http2: false, auto_cl: true, flow_id: nil, position: 0, sni: nil)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"repeater_id":#{rid},"h2_fields":[[":method","GET"]],"allow_unscoped":true}}})
        text = mcp_drive(store, call)[0]["result"]["content"][0]["text"].as_s
        text.should contain("url + h2_fields")
        text.should_not contain("url/method/headers/body")
      end
    end

    # `verbatim` sent with auto-Content-Length OFF, so the tab it saves has to record that or
    # the saved row re-frames the deliberate mismatch on its first replay.
    it "saves a verbatim send's repeater with auto Content-Length off" do
      with_store do |store|
        port = start_mcp_http_origin("saved")
        rid = store.insert_repeater(target: "http://127.0.0.1:#{port}",
          request: "POST /q HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nContent-Length: 3\r\n\r\nlonger-body".to_slice,
          http2: false, auto_cl: true, flow_id: nil, position: 0, sni: nil)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"repeater_id":#{rid},"verbatim":true,"save_as_repeater":true,"allow_unscoped":true}}})
        p = mcp_tool_payload(mcp_drive(store, call, verify_upstream: false)[0])
        saved = store.get_repeater(p["saved_repeater_id"].as_i64).not_nil!
        saved.auto_content_length?.should be_false
        String.new(saved.request).should contain("Content-Length: 3")
      end
    end

    it "executes a saved HTTP repeater by repeater_id" do
      with_store do |store|
        port = start_mcp_http_origin("repeater-ok")
        rid = store.insert_repeater(target: "http://127.0.0.1:#{port}",
          request: "GET /rep HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n".to_slice,
          http2: false, auto_cl: true, flow_id: nil, position: 0, sni: nil)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"repeater_id":#{rid},"allow_unscoped":true}}})
        p = mcp_tool_payload(mcp_drive(store, call, verify_upstream: false)[0])
        p["status"].as_i.should eq(200)
        p["effective_request"]["target"].as_s.should eq("/rep")
        p["effective_request"]["host"].as_s.should eq("127.0.0.1")
      end
    end

    it "rejects send_request on a WebSocket repeater and points to send_websocket" do
      with_store do |store|
        rid = store.insert_repeater(target: "http://127.0.0.1:9",
          request: "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:9\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: x\r\nSec-WebSocket-Version: 13\r\n\r\n".to_slice,
          http2: false, auto_cl: true, flow_id: nil, position: 0, sni: nil)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"repeater_id":#{rid},"allow_unscoped":true}}})
        resp = mcp_drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["content"][0]["text"].as_s.should contain("send_websocket")
      end
    end
  end

  describe "scope enforcement (active tools)" do
    it "blocks an unscoped send by default when no scope is configured" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:1/"}}})
        resp = mcp_drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["error_code"].as_s.should eq("SCOPE_BLOCKED")
        resp["structuredContent"]["details"]["scope_decision"].as_s.should eq("unscoped")
        store.count.should eq(0) # refused before any History write
      end
    end

    it "allows an unscoped send with allow_unscoped:true, flagged unscoped" do
      with_store do |store|
        port = start_mcp_http_origin("ok")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/","allow_unscoped":true}}})
        p = mcp_tool_payload(mcp_drive(store, call, verify_upstream: false)[0])
        p["scope_decision"].as_s.should eq("unscoped")
        p["effective_host"].as_s.should eq("127.0.0.1")
      end
    end

    it "reports in_scope with the matched rule id when the host is included" do
      with_store do |store|
        store.add_scope_rule("include", "host", "127.0.0.1")
        port = start_mcp_http_origin("ok")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/"}}})
        p = mcp_tool_payload(mcp_drive(store, call, verify_upstream: false)[0])
        p["scope_decision"].as_s.should eq("in_scope")
        p["scope_rule_id"].as_i64.should be > 0
      end
    end

    it "blocks an out-of-scope send without sending or recording" do
      with_store do |store|
        store.add_scope_rule("include", "host", "example.com")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:1/"}}})
        resp = mcp_drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["error_code"].as_s.should eq("SCOPE_BLOCKED")
        store.count.should eq(0) # refused before any History write
      end
    end

    it "allows an out-of-scope send with allow_unscoped:true" do
      with_store do |store|
        store.add_scope_rule("include", "host", "example.com")
        port = start_mcp_http_origin("ok")
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/","allow_unscoped":true}}})
        p = mcp_tool_payload(mcp_drive(store, call, verify_upstream: false)[0])
        p["scope_decision"].as_s.should eq("out_of_scope")
      end
    end

    # A `raw` template's request line is taken VERBATIM (request_target in send.cr),
    # so it can be ABSOLUTE-FORM (`GET http://host/path HTTP/1.1`). The scope check
    # anchors on the DIAL host (built.host) reduced to origin-form, so an absolute-form
    # line whose host matches `url` still resolves in-scope (no URL doubling, host keyed
    # without port to match Scope.request_url's origin-form convention).
    it "reports in_scope for a raw request whose line is already ABSOLUTE-FORM" do
      with_store do |store|
        port = start_mcp_http_origin("ok")
        store.add_scope_rule("include", "regex", "^http://127\\.0\\.0\\.1/")
        raw = "GET http://127.0.0.1:#{port}/ HTTP/1.1\\r\\nHost: 127.0.0.1:#{port}\\r\\n\\r\\n"
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/","raw":"#{raw}"}}})
        p = mcp_tool_payload(mcp_drive(store, call, verify_upstream: false)[0])
        p["scope_decision"].as_s.should eq("in_scope")
        p["scope_rule_id"].as_i64.should be > 0
      end
    end

    # Host-header attack / cache-poisoning / SSRF-via-absolute-form: the caller DELIBERATELY
    # spoofs the request-line host to a DIFFERENT (here out-of-scope) host while dialing the
    # in-scope `url`. gori must ALLOW this and scope on the host it actually dials, so the
    # test proceeds against the in-scope origin and the spoofed line rides along verbatim.
    it "allows a deliberately spoofed request-line host, scoping on the dialed host" do
      with_store do |store|
        port = start_mcp_http_origin("ok")
        store.add_scope_rule("include", "regex", "^http://127\\.0\\.0\\.1/")
        raw = "GET http://evil.example/ HTTP/1.1\\r\\nHost: evil.example\\r\\n\\r\\n"
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://127.0.0.1:#{port}/","raw":"#{raw}"}}})
        p = mcp_tool_payload(mcp_drive(store, call, verify_upstream: false)[0])
        p["scope_decision"].as_s.should eq("in_scope") # scoped on the dialed 127.0.0.1, not the spoofed line
      end
    end

    # The converse (the bypass this closes): dialing an OUT-of-scope host while the
    # absolute-form line names the in-scope host must NOT report in_scope — the scope
    # decision follows the dialed host, so this is blocked without allow_unscoped.
    it "scopes a raw absolute-form send on the dialed host, not the request-line host (no bypass)" do
      with_store do |store|
        port = start_mcp_http_origin("ok")
        store.add_scope_rule("include", "string", "127.0.0.1")
        # Absolute-form line names the in-scope 127.0.0.1, but `url` dials the out-of-scope
        # 10.99.99.99. The gate follows the DIALED host → blocked (no allow_unscoped), and
        # nothing is sent (so the unroutable IP is never actually dialed).
        raw = "GET http://127.0.0.1:#{port}/ HTTP/1.1\\r\\nHost: 127.0.0.1:#{port}\\r\\n\\r\\n"
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":{"url":"http://10.99.99.99:#{port}/","raw":"#{raw}"}}})
        resp = mcp_drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_true
        sc = resp["result"]["structuredContent"]
        sc["error_code"].as_s.should eq("SCOPE_BLOCKED")
        sc["details"]["scope_decision"].as_s.should eq("out_of_scope")
      end
    end
  end

  describe "send_websocket" do
    it "performs the upgrade and returns the inbound frame transcript" do
      with_store do |store|
        port = start_mcp_ws_origin
        request = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
        repeater_id = store.insert_repeater("ws://127.0.0.1:#{port}", request.to_slice, false, true, nil, 0)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_websocket","arguments":{"repeater_id":#{repeater_id},"messages":["ping"],"idle_ms":100,"allow_unscoped":true}}})
        resp = mcp_drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_false
        payload = mcp_tool_payload(resp)
        payload["upgraded"].as_bool.should be_true
        payload["handshake_status"].as_i.should eq(101)
        payload["close_code"].as_i.should eq(1000)
        # The origin's CLOSE frame is now a transcript row of its own, not just a
        # `close_code` field — its REASON is where a server explains itself, and until V7 the
        # frame was dropped before anything above the relay could see it.
        payload["messages"].as_a.map { |message| {message["direction"].as_s, message["type"].as_s} }
          .should eq([{"out", "text"}, {"in", "text"}, {"in", "close"}])
        payload["messages"].as_a[0]["payload"].as_s.should eq("ping")
        payload["messages"].as_a[1]["payload"].as_s.should eq("ping")
        payload["messages"].as_a[2]["close_code"].as_i.should eq(1000)
        # `frame` reports what was FRAMED, so a shape test can be read back instead of taken
        # on trust. The default send is still an ordinary masked TEXT frame.
        payload["messages"].as_a[0]["frame"].as_s.should eq("TEXT")
        store.repeaters.find(&.id.==(repeater_id)).not_nil!.response_head.should_not be_nil
      end
    end

    it "rejects a non-WebSocket repeater before making a connection" do
      with_store do |store|
        repeater_id = store.insert_repeater("http://127.0.0.1:1", "GET / HTTP/1.1\r\nHost: x\r\n\r\n".to_slice, false, true, nil, 0)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_websocket","arguments":{"repeater_id":#{repeater_id},"allow_unscoped":true}}})
        resp = mcp_drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true
        resp["result"]["content"][0]["text"].as_s.should contain("not a WebSocket")
      end
    end

    it "uses the WebSocket engine and returns a clean connection error" do
      with_store do |store|
        repeater_id = store.insert_repeater("ws://127.0.0.1:1", "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".to_slice, false, true, nil, 0)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_websocket","arguments":{"repeater_id":#{repeater_id},"messages":["ping"],"idle_ms":100,"allow_unscoped":true}}})
        resp = mcp_drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_true
        payload = mcp_tool_payload(resp)
        payload["repeater_id"].as_i64.should eq(repeater_id)
        payload["upgraded"].as_bool.should be_false
        payload["error"].as_s.should contain("connect failed")
      end
    end

    # `gori run repeater send`'s WS path and the TUI's `drain_results` both persist the last
    # response ONLY on success, and both say why: a later FAILED re-send must not wipe a good
    # stored handshake. This surface wrote unconditionally, so one send at a session whose
    # origin was momentarily down (or whose target had been retargeted) replaced a stored 101
    # with an empty head — measured through the MCP stdio server, `length(response_head)`
    # 129 → 0 — taking the TUI tab's handshake card and `repeater send --diff`'s baseline with
    # it. Three surfaces, one row; the failure belongs in the RESULT, which carries it in full.
    it "keeps a good stored handshake when a later send fails" do
      with_store do |store|
        rid = store.insert_repeater("ws://127.0.0.1:1",
          "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".to_slice,
          false, true, nil, 0)
        good = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n"
        store.update_repeater_response(rid, good.to_slice, Bytes.empty, nil, 42_i64)

        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_websocket","arguments":{"repeater_id":#{rid},"messages":["ping"],"idle_ms":100,"allow_unscoped":true}}})
        resp = mcp_drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_true

        row = store.get_repeater_full(rid).not_nil!
        String.new(row.response_head.not_nil!).should eq(good)
        row.response_error.should be_nil
      end
    end

    # The other half of the same gate. `ok?` alone would keep the stale 101 forever at an
    # origin that has started answering 403 — the TUI handshake card, `repeater list` and
    # `repeater send --diff`'s baseline all going on showing a handshake the origin no longer
    # performs, with `--diff` silently comparing each new run against it. The origin ANSWERED;
    # that answer is the news, and it is what the row now holds.
    it "replaces the stored handshake when the origin answers, but does not upgrade" do
      with_store do |store|
        port = start_refusing_ws_origin(403)
        rid = store.insert_repeater("ws://127.0.0.1:#{port}",
          "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".to_slice,
          false, true, nil, 0)
        store.update_repeater_response(rid,
          "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n".to_slice, Bytes.empty, nil, 42_i64)

        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_websocket","arguments":{"repeater_id":#{rid},"messages":["ping"],"idle_ms":100,"allow_unscoped":true}}})
        resp = mcp_drive(store, call, verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_true

        row = store.get_repeater_full(rid).not_nil!
        String.new(row.response_head.not_nil!).should contain("403")
        row.response_error.not_nil!.should contain("did not upgrade")
      end
    end

    it "does not link the issue when a WebSocket send is scope-blocked" do
      with_store do |store|
        store.add_scope_rule("include", "host", "example.com") # blocks 127.0.0.1
        issue_id = store.insert_issue("ev", Gori::Store::Severity::Low, nil, nil)
        rid = store.insert_repeater("ws://127.0.0.1:1",
          "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".to_slice,
          false, true, nil, 0)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_websocket","arguments":{"repeater_id":#{rid},"issue_id":#{issue_id}}}})
        resp = mcp_drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["error_code"].as_s.should eq("SCOPE_BLOCKED")
        # the refused send must NOT have persisted the issue→repeater link
        store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id).empty?.should be_true
      end
    end
  end
end

describe "MCP send_websocket scope gate" do
  it "honours a path-scoped include the way send_request does" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("include", "string", "/chat")
      scope.enable
      ws = "GET /chat HTTP/1.1\r\nHost: acme.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
           "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
      rid = store.insert_repeater("https://acme.test", ws.to_slice, false, true, nil, 0)

      # Anchoring the check on a bare "/" refused this — the include names a PATH.
      r = tools_for(store).call("send_websocket", JSON.parse(%({"repeater_id":#{rid}})))
      r.error_code.should_not eq "SCOPE_BLOCKED"
    end
  end

  it "still refuses a target the scope does not include" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("include", "string", "/chat")
      scope.enable
      ws = "GET /admin HTTP/1.1\r\nHost: acme.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
           "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
      rid = store.insert_repeater("https://acme.test", ws.to_slice, false, true, nil, 0)

      r = tools_for(store).call("send_websocket", JSON.parse(%({"repeater_id":#{rid}})))
      r.error_code.should eq "SCOPE_BLOCKED"
    end
  end
end
