require "../spec_helper"
require "socket"
require "base64"
require "digest/sha1"

# The MCP surface read as an AGENT-DRIVEN security-testing API: every case here is one where
# gori answered `isError:false` for a request it had quietly rewritten, refused, truncated or
# dropped. The theme is a single rule — an agent cannot look at the wire, so anything gori did
# to the operator's bytes has to be readable in the reply, and anything gori could not do has
# to be a refusal that names the field.
#
# Helpers are file-local (Crystal's top-level `private def` is file-scoped) so this file does
# not depend on spec/mcp_spec.cr's.

private def with_store(&)
  path = File.tempname("gori-mcp-agent", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def drive(store, *lines, allow_actions = true, verify_upstream = true) : Array(JSON::Any)
  input = IO::Memory.new(lines.join('\n') + "\n")
  output = IO::Memory.new
  Gori::MCP::Server.new(store, allow_actions: allow_actions, verify_upstream: verify_upstream,
    input: input, output: output).run
  output.to_s.each_line.reject(&.strip.empty?).map { |l| JSON.parse(l) }.to_a
end

# The RAW response lines, not a re-parse — Crystal's `JSON.parse` turns an escaped sequence
# into U+FFFD, which would hide exactly the lossy-text bugs several of these cases are about.
private def drive_raw(store, *lines, allow_actions = true, verify_upstream = true) : String
  input = IO::Memory.new(lines.join('\n') + "\n")
  output = IO::Memory.new
  Gori::MCP::Server.new(store, allow_actions: allow_actions, verify_upstream: verify_upstream,
    input: input, output: output).run
  output.to_s
end

private def call_line(name : String, args : String, id = 1) : String
  %({"jsonrpc":"2.0","id":#{id},"method":"tools/call","params":{"name":"#{name}","arguments":#{args}}})
end

private def payload(resp : JSON::Any) : JSON::Any
  JSON.parse(resp["result"]["content"][0]["text"].as_s)
end

private def result_text(resp : JSON::Any) : String
  resp["result"]["content"][0]["text"].as_s
end

# A one-shot recording origin: keeps every byte of the request, answers a canned 200.
# Returns {port, channel that yields the exact request bytes}.
private def recording_origin(conns = 1) : {Int32, Channel(Bytes)}
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  seen = Channel(Bytes).new(conns)
  spawn do
    conns.times do
      break unless conn = server.accept?
      spawn do
        buf = IO::Memory.new
        begin
          conn.read_timeout = 300.milliseconds
          slice = Bytes.new(65536)
          loop do
            n = conn.read(slice)
            break if n == 0
            buf.write(slice[0, n])
          end
        rescue
        end
        begin
          conn << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
          conn.flush
        rescue
        end
        seen.send(buf.to_slice)
        conn.close rescue nil
      end
    end
  ensure
    server.close rescue nil
  end
  {port, seen}
end

private def ws_sink_origin(frames_out = 0) : {Int32, Channel(Bytes)}
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  seen = Channel(Bytes).new(1)
  spawn do
    next unless conn = server.accept?
    buf = IO::Memory.new
    begin
      conn.read_timeout = 2.seconds
      head = Gori::Proxy::Codec::Http1.read_head(conn).not_nil!
      key = String.new(head).each_line
        .find(&.downcase.starts_with?("sec-websocket-key:"))
        .try(&.split(':', 2)[1].strip) || ""
      accept = Base64.strict_encode(Digest::SHA1.digest(key + Gori::Repeater::WsEngine::GUID))
      conn << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
              "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
      conn.flush
      slice = Bytes.new(65536)
      loop do
        n = conn.read(slice)
        break if n == 0
        buf.write(slice[0, n])
      end
    rescue
    end
    seen.send(buf.to_slice)
    conn.close rescue nil
    server.close rescue nil
  end
  {port, seen}
end

# One client->server frame, decoded off the wire.
private record WireFrame, fin : Bool, rsv : Int32, opcode : Int32, masked : Bool,
  declared_len : Int32, mask_key : String, payload : Bytes

private def decode_frames(bytes : Bytes) : Array(WireFrame)
  out = [] of WireFrame
  i = 0
  while i + 2 <= bytes.size
    b0 = bytes[i]
    b1 = bytes[i + 1]
    fin = (b0 & 0x80) != 0
    rsv = ((b0 >> 4) & 0x07).to_i
    op = (b0 & 0x0f).to_i
    masked = (b1 & 0x80) != 0
    len = (b1 & 0x7f).to_i
    i += 2
    if len == 126
      len = (bytes[i].to_i << 8) | bytes[i + 1].to_i
      i += 2
    elsif len == 127
      len = 0
      8.times { |k| len = (len << 8) | bytes[i + k].to_i }
      i += 8
    end
    key = Bytes.empty
    if masked
      key = bytes[i, 4]
      i += 4
    end
    avail = Math.min(len, bytes.size - i)
    data = avail > 0 ? Bytes.new(avail) { |k| masked ? (bytes[i + k] ^ key[k % 4]) : bytes[i + k] } : Bytes.empty
    i += avail
    out << WireFrame.new(fin, rsv, op, masked, len, key.hexstring, data)
  end
  out
end

describe "MCP WebSocket frame object form" do
  # The object form re-read every key itself: `as_i?` returns nil for the NAMED opcode the
  # schema advertises and `as_bool?` nil for the `0`/`1` it advertises for fin/mask, so every
  # nil fell through to the encoder default. A PING went out as TEXT, a CLOSE as BINARY,
  # `fin:0` as FIN=1, `mask:0` masked — all with isError:false.
  it "honours a named opcode, an integer fin/mask, rsv, mask_key and the len alias" do
    with_store do |store|
      port, seen = ws_sink_origin
      request = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
      rid = store.insert_repeater("ws://127.0.0.1:#{port}", request.to_slice, false, true, nil, 0)
      msgs = %([{"opcode":"ping","text":"PING-NAME"},) +
             %({"opcode":"cont","text":"CONT"},) +
             %({"opcode":"pong","text":"PONG"},) +
             %({"opcode":"close","payload_hex":"03e9"},) +
             %({"opcode":"text","payload_base64":"//4="},) +
             %({"opcode":"text","text":"MASK0","mask":0},) +
             %({"opcode":"text","text":"FIN0","fin":0},) +
             %({"opcode":"text","text":"RSV","rsv":"4"},) +
             %({"opcode":"text","text":"KEY","mask_key":"aabbccdd"},) +
             %({"opcode":"text","text":"LEN","len":99}])
      resp = drive(store, call_line("send_websocket",
        %({"repeater_id":#{rid},"messages":#{msgs},"idle_ms":100,"allow_unscoped":true})),
        verify_upstream: false)[0]
      resp["result"]["isError"].as_bool.should be_false

      frames = decode_frames(receive_within(seen))
      frames.map(&.opcode).first(5).should eq([9, 0, 10, 8, 1])
      frames[3].payload.should eq(Bytes[0x03, 0xe9])
      frames[4].payload.should eq(Bytes[0xff, 0xfe])
      frames[5].masked.should be_false         # mask:0 (integer) honoured
      frames[6].fin.should be_false            # fin:0  (integer) honoured
      frames[7].rsv.should eq(4)               # rsv:"4" (stringified) honoured
      frames[8].mask_key.should eq("aabbccdd") # mask_key honoured
      frames[9].declared_len.should eq(99)     # `len` is an alias for declared_len
      frames[9].payload.size.should eq(3)      # …and the length header LIES, as asked
    end
  end

  # Every one of these used to be silently dropped or silently substituted.
  it "refuses an unreadable field by name instead of substituting a default" do
    with_store do |store|
      request = "GET /ws HTTP/1.1\r\nHost: h\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
      rid = store.insert_repeater("ws://127.0.0.1:1", request.to_slice, false, true, nil, 0)
      {
        %({"opcode":"bogus","text":"x"})              => "bad opcode",
        %({"opcode":1,"text":"x","rsv":9})            => "bad rsv",
        %({"opcode":1,"text":"x","mask_key":"zzzz"})  => "bad mask_key",
        %({"opcode":1,"text":"x","len":-1})           => "bad len",
        %({"opcode":1,"text":"x","nothing":1})        => "unknown frame field",
        %({"payload_base64":"!!!"})                   => "bad b64 payload",
        %({"opcode":1,"text":"a","payload_hex":"ff"}) => "pass only one of",
        %({})                                         => "no frame fields",
      }.each do |entry, want|
        resp = drive(store, call_line("send_websocket",
          %({"repeater_id":#{rid},"messages":[#{entry}],"idle_ms":50,"allow_unscoped":true})),
          verify_upstream: false)[0]
        resp["result"]["isError"].as_bool.should be_true
        text = result_text(resp)
        text.should contain("invalid 'messages' entry")
        text.should contain(want)
      end
    end
  end

  # `create_repeater` used to compact_map the nil away: it answered isError:false having
  # stored 2 of the 4 frames handed to it, so a run "passed" against a sequence never sent —
  # while `send_websocket`'s identical grammar refused the same entry.
  it "refuses a bad ws_out_messages entry on create_repeater and echoes the stored count" do
    with_store do |store|
      req = %(GET /ws HTTP/1.1\\r\\nHost: h\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\n\\r\\n)
      bad = drive(store, call_line("create_repeater",
        %({"target":"ws://127.0.0.1:1","request":"#{req}",) +
        %("ws_out_messages":["keep1",{"payload_base64":"!!!"},"keep2",{"nothing":1}]})))[0]
      bad["result"]["isError"].as_bool.should be_true
      result_text(bad).should contain("invalid 'ws_out_messages' entry")
      store.repeaters_meta.size.should eq(0)

      ok = drive(store, call_line("create_repeater",
        %({"target":"ws://127.0.0.1:1","request":"#{req}",) +
        %("ws_out_messages":["keep1",{"opcode":"ping","text":"p"},"keep2"]})))[0]
      ok["result"]["isError"].as_bool.should be_false
      body = payload(ok)
      body["ws_out_message_count"].as_i.should eq(3)
      # The PING is PERSISTED as opcode 9 — the half that made every later send from any
      # surface replay the wrong frame.
      store.ws_messages_for_repeater(body["id"].as_i64).map(&.opcode).should eq([1, 9, 1])
    end
  end
end

describe "MCP repeater request read-back" do
  # get_repeater_context is the ONLY read-back of a repeater's request, and it returned it
  # U+FFFD-scrubbed with no companion — so an agent that stored exact octets with
  # request_base64 could not verify them, and any edit it made destroyed them.
  it "emits <field>_lossy and a base64 companion when scrubbing changed the bytes" do
    with_store do |store|
      req = "POST /bin HTTP/1.1\r\nHost: h\r\nX-Bin: ".to_slice +
            Bytes[0xff, 0xfe] + "\r\nContent-Length: 6\r\n\r\nA".to_slice +
            Bytes[0x00] + "B".to_slice + Bytes[0xff] + "C".to_slice + Bytes[0x80]
      id = store.insert_repeater("http://127.0.0.1:1", req, false, true, nil, 0)

      raw = drive_raw(store, call_line("get_repeater_context",
        %({"id":#{id},"include_content":true,"include_sensitive":true})))
      s = payload(JSON.parse(raw.lines.first))["sessions"][0]
      s["request_lossy"].as_bool.should be_true
      Base64.decode(s["request_base64"].as_s).should eq(req)

      # base64 is ENCODING, not redaction — so it stays behind include_sensitive, exactly as
      # Serialize.emit_head_base64 gates a captured head.
      plain = payload(drive(store, call_line("get_repeater_context",
        %({"id":#{id},"include_content":true})))[0])["sessions"][0]
      plain["request_lossy"].as_bool.should be_true
      plain.as_h.has_key?("request_base64").should be_false
    end
  end

  # 16 KiB of a 20 KB request with no way to fetch byte 16385 is the same silence in another
  # shape: `get_response_body_chunk` served RESPONSES only.
  it "names a cursor for a truncated request and pages the whole thing back byte-exact" do
    with_store do |store|
      body = "Z" * 20_000
      req = "POST /big HTTP/1.1\r\nHost: h\r\nContent-Length: #{body.size}\r\n\r\n#{body}"
      id = store.insert_repeater("http://127.0.0.1:1", req.to_slice, false, true, nil, 0)

      s = payload(drive(store, call_line("get_repeater_context",
        %({"id":#{id},"include_content":true})))[0])["sessions"][0]
      s["request_truncated"].as_bool.should be_true
      s["request_total_bytes"].as_i.should eq(req.bytesize)
      s["request_read_more"].as_s.should contain(%(part: "request"))

      got = String.build do |io|
        offset = 0_i64
        loop do
          chunk = payload(drive(store, call_line("get_response_body_chunk",
            %({"repeater_id":#{id},"part":"request","offset":#{offset},"limit":8192})))[0])
          chunk["part"].as_s.should eq("request")
          io << chunk["text"].as_s
          break if chunk["complete"].as_bool
          offset = chunk["next_offset"].as_i64
        end
      end
      got.should eq(req)
    end
  end
end

describe "MCP boolean arguments" do
  # `bool(h, "x") || false` erased the difference between "absent" and "unintelligible":
  # `verbatim: 1` silently selected the mode that PROMOTES a bare-LF header terminator to
  # CRLF — destroying the desync primitive verbatim exists to deliver — and reported a clean
  # send. `insecure: 1` came back as a retryable NETWORK_ERROR, i.e. as a reason to loop.
  it "refuses an unreadable verbatim / insecure / allow_unscoped instead of falling back to false" do
    with_store do |store|
      {"verbatim", "insecure", "allow_unscoped"}.each do |flag|
        # No second `allow_unscoped` alongside it — a duplicate JSON key would win the parse
        # and the case would test nothing. The scope gate runs AFTER argument validation, so
        # an unscoped project is fine here.
        resp = drive(store, call_line("send_request",
          %({"url":"http://127.0.0.1:1/x","raw":"GET / HTTP/1.1\\r\\nHost: h\\r\\n\\r\\n",) +
          %("#{flag}":1,"record_history":false})))[0]
        resp["result"]["isError"].as_bool.should be_true
        result_text(resp).should contain("invalid '#{flag}' (expected true or false)")
      end
    end
  end

  it "still accepts the stringified booleans an LLM client emits" do
    with_store do |store|
      port, seen = recording_origin
      resp = drive(store, call_line("send_request",
        %({"url":"http://127.0.0.1:#{port}/x",) +
        %("raw":"GET /lf HTTP/1.1\\nHost: h\\n\\n","verbatim":"TRUE","allow_unscoped":"true"})))[0]
      resp["result"]["isError"].as_bool.should be_false
      String.new(receive_within(seen)).should eq("GET /lf HTTP/1.1\nHost: h\n\n")
    end
  end
end

describe "MCP effective_request" do
  # This field's contract is "what actually went out". A verbatim `GET /old09\r\n\r\n` is the
  # HTTP/0.9 handling probe; answering it with a version that was never on the wire tells the
  # agent its own test did not happen.
  it "reports a null http_version for a request line that carried none" do
    with_store do |store|
      port, seen = recording_origin
      resp = drive(store, call_line("send_request",
        %({"url":"http://127.0.0.1:#{port}/09","raw":"GET /old09\\r\\n\\r\\n",) +
        %("verbatim":true,"allow_unscoped":true})))[0]
      String.new(receive_within(seen)).should eq("GET /old09\r\n\r\n")
      payload(resp)["effective_request"]["http_version"].raw.should be_nil
    end
  end
end

describe "MCP flow replay" do
  # A captured flow is EVIDENCE — the operator authored none of those bytes. `$filter`/`$top`
  # (OData), `$where` (Mongo), `$IFS` (shell) and `$user.name` (SSTI) all live in ordinary
  # captured traffic, and the refusal's own remedy (set the var) makes the replay send a
  # DIFFERENT request. A bare-LF head is a desync primitive gori stores byte-exact.
  it "replays a captured $KEY head and a bare-LF head byte-exactly" do
    with_store do |store|
      port, seen = recording_origin(2)
      odata = "GET /api?$filter=name%20eq%20x&$top=10 HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n" \
              "X-Cmd: ;cat$IFS/etc/passwd\r\nCookie: tmpl=$user.name\r\n\r\n"
      bare = "POST /lf HTTP/1.1\nHost: 127.0.0.1:#{port}\nContent-Length: 5\n\nhello"
      [odata, bare].each do |text|
        id = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "http", host: "127.0.0.1", port: port,
          method: "GET", target: "/", http_version: "HTTP/1.1", head: text.to_slice))
        resp = drive(store, call_line("send_request",
          %({"flow_id":#{id},"allow_unscoped":true,"record_history":false})))[0]
        resp["result"]["isError"].as_bool.should be_false
        String.new(receive_within(seen)).should eq(text)
      end
    end
  end
end

describe "MCP field-native h2 evidence" do
  # `H2Engine.field_dump` is the faithful REPORT of a field list; it must not be the stored
  # head, because History and the Repeater are a REPLAY SOURCE and the dump's first line is
  # `:method: POST`, not a request line. Replaying such a row over h1 put a request with NO
  # request line on the wire and reported 200.
  it "records the replayable h1 projection and reports the faithful field list beside it" do
    with_store do |store|
      port, seen = recording_origin(2)
      fields = %([[":method","POST"],[":path","/api/v1/user?id=1"],[":scheme","http"],) +
               %([":authority","victim.example"],["cookie","sid=abc"]])
      resp = drive(store, call_line("send_request",
        %({"url":"http://127.0.0.1:#{port}/api/v1/user","h2_fields":#{fields},) +
        %("body":"{\\"a\\":1}","allow_unscoped":true,"save_as_repeater":true})))[0]
      body = payload(resp)
      receive_within(seen) # the h2 attempt itself

      body["sent_h2_fields"].as_a.map(&.as_a.first.as_s)
        .should eq([":method", ":path", ":scheme", ":authority", "cookie"])
      body["history_head_projected"].as_bool.should be_true

      detail = store.get_flow(body["recorded_flow_id"].as_i64).not_nil!
      head = String.new(detail.request_head.not_nil!)
      head.lines.first.should eq("POST /api/v1/user?id=1 HTTP/2")
      head.should contain("Host: victim.example")

      # …and the saved repeater really replays: a request LINE reaches the socket.
      saved = body["saved_repeater_id"].as_i64
      drive(store, call_line("send_request",
        %({"repeater_id":#{saved},"http2":false,"allow_unscoped":true,"record_history":false})))
      String.new(receive_within(seen)).lines.first.should eq("POST /api/v1/user?id=1 HTTP/1.1")
    end
  end
end

describe "MCP transport and error coding" do
  # A legal JSON number outside Int64 range makes Crystal's parser reject the whole line, so
  # a request that is only an ARGUMENT mistake came back `id: null` and a strict client's
  # pending promise for that id never resolved — the agent hung rather than seeing the error.
  it "echoes the request id on a parse error it can still read one from" do
    with_store do |store|
      lines = drive(store,
        %({"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"list_history","arguments":{"limit":1000000000000000000000000000000}}}))
      lines[0]["id"].as_i.should eq(7)
      lines[0]["error"]["code"].as_i.should eq(-32700)
    end
  end

  it "does not invent an id when the broken line carries none it can trust" do
    with_store do |store|
      drive(store, %({"jsonrpc":"2.0","method":"tools/call","params":{"arguments":{"id":9,"x":]}}))[0]["id"].raw.should be_nil
    end
  end

  # INTERNAL tells an agent's error policy "the server is broken, back off / escalate" for a
  # mistake in its own call, and the `tool error:` prefix made it read like a crash.
  it "codes a caller-facing Gori::Error as INVALID_ARGUMENT, not INTERNAL" do
    with_store do |store|
      resp = drive(store, call_line("list_env", %({"include_sensitive":"yes"})))[0]
      resp["result"]["structuredContent"]["error_code"].as_s.should eq("INVALID_ARGUMENT")
      result_text(resp).should_not contain("tool error:")
      result_text(resp).should contain("invalid 'include_sensitive'")
    end
  end
end

describe "MCP job-tool parity knobs" do
  # Each of these had a CLI flag and no MCP argument at all, so `unknown argument` was the
  # only answer an agent got. mine/sequence had NO route to SNI — and an SNI that differs
  # from the Host header is the vhost-confusion test those tools exist for.
  it "declares sni / throttle_ms / insecure where the CLI has them" do
    with_store do |store|
      {
        {"mine_start", %({"url":"http://127.0.0.1:1/","sni":"x","throttle_ms":5})},
        {"sequence_start", %({"url":"http://127.0.0.1:1/","sni":"x","throttle_ms":5})},
        {"discover_start", %({"url":"http://127.0.0.1:1/","throttle_ms":5})},
        {"probe_scan", %({"insecure":true})},
        {"intercept_forward_edit", %({"item_id":1,"raw":"GET / HTTP/1.1\\r\\n\\r\\n","update_content_length":false})},
        # `send_request` was the LAST send surface with no route to an SNI: the schema declared
        # none and the code only ever read a stored one off a flow/repeater row, so an agent
        # could not run the vhost-confusion test that every sibling tool's own description
        # names — and replaying a flow dialled with a ClientHello `gori run repeater
        # <flow-id> --sni` could change and this could not.
        {"send_request", %({"url":"http://127.0.0.1:1/","sni":"x"})},
      }.each do |(tool, args)|
        result_text(drive(store, call_line(tool, args))[0])
          .should_not contain("unknown argument")
      end
    end
  end
end

describe "MCP network-error classification" do
  # These are the ENGINE's sentences, written in another module. They are pinned here because
  # an agent's retry policy hangs off the classification: every one of them says "h2 ", which
  # PROTOCOL_ERROR_PHRASES matches, so without an earlier rule they all came back
  # PROTOCOL_ERROR / retryable:false — "stop and report a finding" — for conditions whose
  # correct action is to send the request again.
  it "classifies the h2 refusals a retry policy has to tell apart" do
    kind = ->(s : String) { Gori::MCP::Tools.network_error_kind(s) }

    # RFC 9113 §8.7: REFUSED_STREAM says the request was NOT processed — retry it.
    kind.call("h2 RST_STREAM REFUSED_STREAM on stream 1 from a.example:443").should eq("other")
    # A rate signal, not a malformed message.
    kind.call("h2 RST_STREAM ENHANCE_YOUR_CALM on stream 1 from a.example:443").should eq("other")
    # Silence is not proof the message was malformed.
    kind.call("no h2 response from a.example:443 — the connection closed before a response frame arrived")
      .should eq("no_response")
    kind.call("no h2 response from a.example:443 — the origin sent nothing before the read timed out")
      .should eq("timeout")

    # …while a condition gori can PROVE deterministic stays non-retryable.
    kind.call("h2 RST_STREAM CANCEL on stream 1 from a.example:443").should eq("protocol")
    kind.call("h2 flow control: only 16384 of 70000 request body bytes could be sent — " \
              "the origin closed the connection before granting window for the rest (RFC 9113 §6.9). " \
              "The request was NOT fully sent.").should eq("protocol")
    kind.call("conflicting Content-Length headers").should eq("protocol")
    kind.call("connect failed: a.example:443 — host unreachable (DNS/refused/timeout)").should eq("connect")
  end

  # Matched on the RFC error-code NAME, not on the sentence around it, so a reword of the
  # engine's phrasing cannot silently flip the verdict.
  it "keys on the spec error-code name rather than the surrounding sentence" do
    {"h2 stream 1 was refused (REFUSED_STREAM)", "peer sent RST_STREAM refused_stream"}.each do |s|
      Gori::MCP::Tools.network_error_kind(s).should eq("other")
    end
  end

  # RFC 9113 §8.1 lets an origin answer while the request body is still going out — the 413
  # every upload / body-size probe is looking for. The send comes back with a REAL response
  # (status 413, full head and body) and `ok:false`; only the REQUEST is partial. Reported as
  # a network error it was `retryable:true`, which tells an agent to re-send the whole body to
  # a server that already rejected it.
  #
  # The engine's sentence is pinned here AS DATA, not produced by a live origin, so this holds
  # whatever order the h2 change and this one land in.
  it "does not tell an agent to retry a body the origin already rejected" do
    truncated = "the request body was truncated at 4096 of 20000 bytes (the origin ended the " \
                "stream before the body finished, which RFC 9113 §8.1 permits). " \
                "The request was NOT fully sent."
    Gori::MCP::Tools.network_error_kind(truncated).should eq("truncated_request")
    Gori::MCP::Tools.send_error_code("truncated_request").should eq("REQUEST_TRUNCATED")

    # The two siblings that must keep the verdict they already earn. The flow-control stall is
    # the reason this cannot key on "NOT fully sent": that sentence ALREADY ends with it, and
    # it is a genuine stall with no response at all.
    stall = "h2 flow control: only 16384 of 70000 request body bytes could be sent — the " \
            "origin never granted flow-control window for the rest (RFC 9113 §6.9): its " \
            "connection window is 0 and its stream window 0. The request was NOT fully sent."
    Gori::MCP::Tools.network_error_kind(stall).should eq("protocol")

    # A GOAWAY/RST_STREAM reason APPENDS the truncation clause rather than replacing it, so
    # each keeps the verdict its own error code earns: REFUSED_STREAM stays retryable, CANCEL
    # stays a protocol verdict — the clause must not capture either.
    refused = "h2 RST_STREAM REFUSED_STREAM on stream 1 from a.example:443 — #{truncated}"
    Gori::MCP::Tools.network_error_kind(refused).should eq("other")
    cancel = "h2 RST_STREAM CANCEL on stream 1 from a.example:443 — #{truncated}"
    Gori::MCP::Tools.network_error_kind(cancel).should eq("protocol")
    goaway = "h2 GOAWAY INTERNAL_ERROR from a.example:443 — #{truncated}"
    Gori::MCP::Tools.network_error_kind(goaway).should eq("protocol")
  end

  # `retryable` is the field a caller branches on, so no kind may reach it by accident.
  it "keeps exactly the transient kinds retryable" do
    retryable = {"connect", "timeout", "no_response", "other", nil}
    final = {"protocol", "truncated_request"}
    retryable.each do |k|
      Gori::MCP::Tools.send_error_code(k).should eq("NETWORK_ERROR")
    end
    final.each do |k|
      Gori::MCP::Tools.send_error_code(k).should_not eq("NETWORK_ERROR")
    end
  end
end

describe "MCP WebSocket and gRPC projections in get_flow" do
  # RFC 6455 §8.1/§5.6 UTF-8 validation is a standard WebSocket test, so a TEXT frame
  # carrying invalid UTF-8 is the payload — and `scrub` renders two different invalid bytes
  # identically. `gori run show --format json` has emitted the companion all along.
  it "gives a TEXT frame's exact bytes back when scrubbing or clipping changed them" do
    invalid = Gori::Store::WsMessage.new(1_i64, 1_i64, nil, 0_i64, "out", 1,
      "invalid".to_slice + Bytes[0xff, 0xfe])
    json = JSON.build { |j| j.object { Gori::MCP::Serialize.emit_ws_messages(j, [invalid]) } }
    m = JSON.parse(json)["ws_messages"]["messages"][0]
    m["text_lossy"].as_bool.should be_true
    Base64.decode(m["base64"].as_s).should eq(invalid.payload)

    long = Gori::Store::WsMessage.new(1_i64, 1_i64, nil, 0_i64, "out", 1,
      ("B" * (Gori::MCP::Serialize::WS_PAYLOAD_MAX + 904)).to_slice)
    m2 = JSON.parse(JSON.build { |j| j.object { Gori::MCP::Serialize.emit_ws_messages(j, [long]) } })["ws_messages"]["messages"][0]
    m2["text_truncated"].as_bool.should be_true
    m2["text_lossy"].as_bool.should be_true
    Base64.decode(m2["base64"].as_s).size.should eq(long.payload.size)
  end

  it "leaves an ordinary text frame alone" do
    plain = Gori::Store::WsMessage.new(1_i64, 1_i64, nil, 0_i64, "out", 1, "hi".to_slice)
    json = JSON.build { |j| j.object { Gori::MCP::Serialize.emit_ws_messages(j, [plain]) } }
    json.should_not contain("text_lossy")
    json.should_not contain("\"base64\"")
  end

  # `Grpc.scan`'s residual is the whole point: `Grpc.messages` throws it away, so a
  # deliberately-wrong length prefix — one of the standard gRPC parser tests — rendered as
  # "no messages", which reads identically to "this flow is not gRPC". MCP had no gRPC view
  # at all, so an agent had to reframe the 5-byte prefixes itself.
  it "reports a gRPC framing failure rather than deleting the view" do
    head = "HTTP/2 200\r\ncontent-type: application/grpc\r\n\r\n".to_slice
    body = Bytes[0x00, 0x00, 0x00, 0x27, 0x0f] + "hello".to_slice # claims 9999, 5 arrive
    json = JSON.build { |j| j.object { Gori::MCP::Serialize.emit_grpc_messages(j, "response_grpc_messages", head, body) } }
    g = JSON.parse(json)["response_grpc_messages"]
    g["count"].as_i.should eq(0)
    g["residual_bytes"].as_i.should eq(10)
    g["framing_error"].as_s.should contain("not a complete gRPC frame")
  end

  it "decodes a well-framed gRPC message and names a grpc-web trailer" do
    head = "HTTP/2 200\r\ncontent-type: application/grpc-web\r\n\r\n".to_slice
    body = Bytes[0x00, 0, 0, 0, 5] + "hello".to_slice +
           Bytes[0x80, 0, 0, 0, 22] + "grpc-status:3\r\nx-a:b\r\n".to_slice
    g = JSON.parse(JSON.build { |j| j.object { Gori::MCP::Serialize.emit_grpc_messages(j, "response_grpc_messages", head, body) } })["response_grpc_messages"]
    g["count"].as_i.should eq(2)
    g.as_h.has_key?("framing_error").should be_false
    g["messages"][1]["trailer"].as_bool.should be_true
    g["messages"][1]["headers"]["grpc-status"].as_s.should eq("3")
  end

  it "emits nothing for a body that is not gRPC" do
    head = "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n\r\n".to_slice
    JSON.build { |j| j.object { Gori::MCP::Serialize.emit_grpc_messages(j, "response_grpc_messages", head, %({"a":1}).to_slice) } }
      .should eq("{}")
  end
end
