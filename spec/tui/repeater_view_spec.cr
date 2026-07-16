require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def repeater_tmp_store(&)
  path = File.tempname("gori-rv", ".db")
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

describe Gori::Tui::RepeaterView do
  # These specs assert on RAW response rendering; keep the display-only pretty-printer
  # off so a (future) valid-JSON/XML fixture can't silently reflow and shift assertions.
  before_each { Gori::Settings.pretty_bodies_default = false }

  # The response pane's ^X hex dump: repeater_toggle_hex routes response-focus to
  # exactly this view toggle (the `x` key selects a line now — hex moved to ^X).
  it "toggle_resp_hex flips resp_hex? and renders a raw byte dump of the response" do
    view = RepeaterView.new
    view.load_blank
    view.apply(Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, "PONG".to_slice, nil, 1000_i64))
    view.focus_pane(:response)
    view.resp_hex?.should be_false # plain response mode by default

    view.toggle_resp_hex
    view.resp_hex?.should be_true
    hexb = MemoryBackend.new(120, 20)
    view.render(Screen.new(hexb), Rect.new(0, 0, 120, 20))
    hexb.contains?("00000000").should be_true    # hex dump offset column
    hexb.contains?("50 4f 4e 47").should be_true # "PONG" as raw bytes

    view.toggle_resp_hex # ^X again exits back to the decoded body
    view.resp_hex?.should be_false
    plain = MemoryBackend.new(120, 20)
    view.render(Screen.new(plain), Rect.new(0, 0, 120, 20))
    plain.contains?("PONG").should be_true
  end

  it "load_blank seeds an editable, sendable scaffold (no source flow)" do
    view = RepeaterView.new
    view.load_blank
    view.loaded?.should be_true
    view.http2?.should be_false
    view.focus.should eq(:target) # new requests start on the target (you change the URL first)

    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("https://example.com").should be_true # target field
    backend.contains?("GET / HTTP/1.1").should be_true      # scaffold request line
    backend.contains?("Host: example.com").should be_true   # scaffold header
    backend.contains?("— not sent — press ^R to resend —").should be_true
  end

  it "duplicate_from copies request content, flags, and last response (no source flow)" do
    src = RepeaterView.new
    src.load_blank
    src.name = "alpha"
    ok = Gori::Repeater::Result.new(
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice, "PONG".to_slice, nil, 1000_i64)
    src.apply(ok)

    dst = RepeaterView.new
    dst.duplicate_from(src)
    dst.loaded?.should be_true
    dst.target.should eq(src.target)
    dst.request_text.should eq(src.request_text)
    dst.name.should eq("alpha copy")
    dst.source_flow_id.should be_nil
    dst.dirty?.should be_true

    backend = MemoryBackend.new(120, 20)
    dst.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("PONG").should be_true
  end

  it "stays in plain response mode after sending a blank (nothing to diff against)" do
    view = RepeaterView.new
    view.load_blank
    ok = Gori::Repeater::Result.new(
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice, "PONG".to_slice, nil, 1000_i64)
    view.apply(ok)
    view.focus.should eq(:target) # send keeps the current focus (was :target from load_blank)

    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("PONG").should be_true
    # plain response mode: the diff toggle chip is inactive (muted), not lit — the
    # pane no longer carries a separate "response" chip (it's titled RESPONSE).
    ry = (0...20).find { |y| backend.row(y).includes?("d:diff") }.not_nil!
    dx = backend.row(ry).index("diff").not_nil!
    backend.fg_at(dx, ry).should eq(Theme.muted) # diff segment inactive
  end

  it "explains there is nothing to diff when a blank's response pane is toggled to diff" do
    view = RepeaterView.new
    view.load_blank
    ok = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, "PONG".to_slice, nil, 1000_i64)
    view.apply(ok)
    view.toggle_resp_mode # response → diff

    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("first send").should be_true # no previous response to diff against yet
    backend.contains?("+ PONG").should be_false    # not shown as a spurious addition
  end

  it "diffs the latest response against the PREVIOUS send (not just the original)" do
    view = RepeaterView.new
    view.load_blank
    first = Gori::Repeater::Result.new(
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice, "ONE".to_slice, nil, 1000_i64)
    view.apply(first) # first send: nothing to diff against yet → response mode
    view.focus.should eq(:target)
    view.toggle_resp_mode # user opens the diff tab

    second = Gori::Repeater::Result.new(
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice, "TWO".to_slice, nil, 1000_i64)
    view.apply(second) # second send keeps the diff tab (last-open) → diffs vs the first send

    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("- ONE").should be_true # previous response body removed
    backend.contains?("+ TWO").should be_true # current response body added
  end

  it "keeps the last-open response tab on send (does not auto-jump to diff)" do
    repeater_tmp_store do |store|
      # A History-loaded flow is diffable from the very first send (baseline = the
      # captured original), which used to force the diff tab open on send.
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
        method: "GET", target: "/", http_version: "HTTP/1.1",
        head: "GET / HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: Bytes.empty))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice, body: "ORIG".to_slice))
      view = RepeaterView.new
      view.load(store.get_flow(id).not_nil!)

      ok = Gori::Repeater::Result.new(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice, "NEW".to_slice, nil, 1000_i64)
      view.apply(ok) # send: must stay on response (the last-open tab), not jump to diff

      backend = MemoryBackend.new(120, 20)
      view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
      backend.contains?("NEW").should be_true
      # response view kept — the diff toggle was NOT auto-opened (muted, inactive)
      ry = (0...20).find { |y| backend.row(y).includes?("d:diff") }.not_nil!
      dx = backend.row(ry).index("diff").not_nil!
      backend.fg_at(dx, ry).should eq(Theme.muted) # diff tab NOT auto-opened
    end
  end

  it "drops back to response when an errored send can't render the held diff tab" do
    view = RepeaterView.new
    view.load_blank
    first = Gori::Repeater::Result.new(
      "HTTP/1.1 200 OK\r\n\r\n".to_slice, "ONE".to_slice, nil, 1000_i64)
    view.apply(first)
    view.toggle_resp_mode # open the diff tab
    err = Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, "connection refused")
    view.apply(err) # errored send: fall back so the error is visible in the response view

    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("repeater error: connection refused").should be_true
    # fell back to the response view — the diff toggle is inactive (muted)
    ry = (0...20).find { |y| backend.row(y).includes?("d:diff") }.not_nil!
    dx = backend.row(ry).index("diff").not_nil!
    backend.fg_at(dx, ry).should eq(Theme.muted)
  end

  it "auto-updates an existing Content-Length to match the edited body on send" do
    repeater_tmp_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
        method: "POST", target: "/x", http_version: "HTTP/1.1",
        head: "POST /x HTTP/1.1\r\nHost: h.test\r\nContent-Length: 99\r\n\r\n".to_slice,
        body: "hello".to_slice)) # stale CL=99, real body is 5 bytes
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
      detail = store.get_flow(id).not_nil!

      view = RepeaterView.new
      view.load(detail)
      view.auto_content_length?.should be_true                        # default on
      view.request_text.includes?("Content-Length: 5").should be_true # reflected in the editor too
      sent = String.new(view.request_bytes)
      sent.includes?("Content-Length: 5").should be_true   # recomputed to the body size
      sent.includes?("Content-Length: 99").should be_false # stale value replaced

      view.toggle_auto_content_length # off → send byte-exact (the already-synced editor)
      String.new(view.request_bytes).includes?("Content-Length: 5").should be_true

      byte_exact = RepeaterView.new
      byte_exact.restore("https://h.test",
        "POST /x HTTP/1.1\nHost: h.test\nContent-Length: 99\n\nhello", false, false)
      String.new(byte_exact.request_bytes).includes?("Content-Length: 99").should be_true
    end
  end

  it "reflects auto Content-Length in the visible REQUEST editor (^L on)" do
    view = RepeaterView.new
    view.restore("https://h.test",
      "POST /x HTTP/1.1\nHost: h.test\nContent-Length: 99\n\nhello", false, false)
    view.request_text.includes?("Content-Length: 99").should be_true

    view.toggle_auto_content_length # on → resync into the editor
    view.request_text.includes?("Content-Length: 5").should be_true
    view.request_text.includes?("Content-Length: 99").should be_false
  end

  it "reflects the RENDERED Content-Length when a §…§ marker + auto-CL are both on" do
    view = RepeaterView.new
    # auto-CL (^L) on; §…§ markers are always active (no mode). Body q=§hi§ is 8 raw bytes
    # but renders to q=hi (4 bytes) — the value ^R actually sends.
    view.restore("https://a.test",
      "POST /x HTTP/1.1\nHost: a.test\nContent-Length: 0\n\nq=§hi§", false, true)
    String.new(view.request_bytes).includes?("Content-Length: 4").should be_true # what ^R sends
    view.request_text.includes?("Content-Length: 4").should be_true              # editor matches (was 8)
    view.request_text.includes?("Content-Length: 8").should be_false
  end

  it "keeps the REQUEST editor's Content-Length in sync while editing the body" do
    view = RepeaterView.new
    view.restore("https://h.test",
      "POST /x HTTP/1.1\nHost: h.test\nContent-Length: 99\n\nhi", false, true)
    view.pane_advance(1)      # :target → :request
    view.goto_request_line(5) # body line
    view.edit_insert('!')
    view.request_text.includes?("Content-Length: 3").should be_true # body "hi!" is 3 bytes
    view.request_text.includes?("Content-Length: 99").should be_false
  end

  it "sends a lone § (no complete §…§ region) verbatim — byte-identical to today" do
    view = RepeaterView.new
    # a single § doesn't form a §…§ region, so there's nothing to render — sent as typed.
    view.restore("https://a.test", "POST /x HTTP/1.1\nHost: a.test\n\nq=§hi", false, false)
    String.new(view.request_bytes).should eq("POST /x HTTP/1.1\r\nHost: a.test\r\n\r\nq=§hi")
  end

  it "does not double CRLF when a $KEY value carries its own CRLF" do
    # A var value with an embedded CRLF must land in the wire request as a single CRLF,
    # not `\r\r\n` — parity with Env.expand_wire (the CLI/MCP send path). The old
    # split('\n').join("\r\n") over already-expanded text doubled it, corrupting the line.
    prev = Gori::Settings.env_vars
    begin
      Gori::Settings.env_vars = [{"MULTI", "a\r\nb"}]
      view = RepeaterView.new
      view.restore("https://h.test", "POST /x HTTP/1.1\nHost: h.test\n\n$MULTI", false, false)
      sent = String.new(view.request_bytes)
      sent.should eq("POST /x HTTP/1.1\r\nHost: h.test\r\n\r\na\r\nb")
      sent.includes?("\r\r\n").should be_false
    ensure
      Gori::Settings.env_vars = prev
    end
  end

  it "applies a §…§ marker's inline chain on send + resyncs Content-Length" do
    view = RepeaterView.new
    view.restore("https://a.test",
      "POST /x HTTP/1.1\nHost: a.test\nContent-Length: 99\n\ntok=§secret¦base64-encode§", false, true)
    sent = String.new(view.request_bytes)
    sent.includes?("tok=c2VjcmV0").should be_true       # base64("secret") == c2VjcmV0
    sent.includes?("Content-Length: 12").should be_true # body "tok=c2VjcmV0" is 12 bytes
    sent.includes?("Content-Length: 99").should be_false
  end

  it "CHAIN pane: focus a marker, type a chain, commit writes it back" do
    view = RepeaterView.new
    # marker at offset 0 → set_text zeroes the cursor, so it sits inside §v§
    view.restore("https://a.test", "§v§ HTTP/1.1\nHost: a.test\n\n", false, false)
    view.chain_pane_active?.should be_false
    view.focus_pane(:request)
    view.focus_chain_pane.should be_nil # in a marker → enters the pane (no hint)
    view.chain_pane_active?.should be_true
    "md5".each_char { |c| view.handle_chain_pane_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerA, char: c)) }
    view.commit_chain_pane
    view.chain_pane_active?.should be_false
    view.request_text.should contain("§v¦md5§")
  end

  it "CHAIN pane hints when the cursor isn't in a §…§ marker" do
    view = RepeaterView.new
    view.restore("https://a.test", "GET / HTTP/1.1\n\n", false, false)
    view.focus_pane(:request)
    view.focus_chain_pane.should_not be_nil # no marker under the cursor → hint, not activated
    view.chain_pane_active?.should be_false
  end

  it "shows the CHAIN pane only while the cursor is inside a §…§ marker (no mode toggle)" do
    # Cursor at offset 0 sits INSIDE the leading §v§ marker → CHAIN pane is split in.
    inside = RepeaterView.new
    inside.restore("https://a.test", "§v§ HTTP/1.1\nHost: a.test\n\n", false, false)
    b_in = MemoryBackend.new(120, 24)
    inside.render(Screen.new(b_in), Rect.new(0, 0, 120, 24))
    b_in.contains?("CHAIN").should be_true

    # Same buffer shape, but the marker is past the caret (offset 0 is on 'G') → no CHAIN pane.
    outside = RepeaterView.new
    outside.restore("https://a.test", "GET §v§ HTTP/1.1\nHost: a.test\n\n", false, false)
    b_out = MemoryBackend.new(120, 24)
    outside.render(Screen.new(b_out), Rect.new(0, 0, 120, 24))
    b_out.contains?("CHAIN").should be_false
  end

  it "load_grpc keeps the framed body byte-exact and the head editable" do
    repeater_tmp_store do |store|
      # one gRPC message: 1-byte flag + 4-byte len(3) + payload incl a non-UTF-8 0xFF
      body = Bytes[0x00, 0x00, 0x00, 0x00, 0x03, 0xFF, 0x01, 0x02]
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
        method: "POST", target: "/demo.Greeter/SayHello", http_version: "HTTP/2",
        head: "POST /demo.Greeter/SayHello HTTP/2\r\nHost: api.test\r\ncontent-type: application/grpc\r\nte: trailers\r\n\r\n".to_slice,
        body: body))
      detail = store.get_flow(id).not_nil!

      view = RepeaterView.new
      view.load_grpc(detail)
      view.grpc_mode?.should be_true
      view.http2?.should be_true

      sent = view.request_bytes
      String.new(sent).should contain("content-type: application/grpc")
      # the framed body is re-appended VERBATIM (a text round-trip would scrub 0xFF)
      sent[(sent.size - body.size)..].should eq(body)
      sent.includes?(0xFF_u8).should be_true
    end
  end

  it "reframes an edited unary gRPC payload with a corrected length prefix" do
    repeater_tmp_store do |store|
      body = Bytes[0x00, 0x00, 0x00, 0x00, 0x03, 0xFF, 0x01, 0x02] # one message, payload 0xFF 01 02
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
        method: "POST", target: "/S/M", http_version: "HTTP/2",
        head: "POST /S/M HTTP/2\r\nHost: api.test\r\ncontent-type: application/grpc\r\n\r\n".to_slice,
        body: body))
      view = RepeaterView.new
      view.load_grpc(store.get_flow(id).not_nil!)
      view.grpc_reframable?.should be_true

      # unmodified: the reframed body matches the captured framing byte-for-byte
      s0 = view.request_bytes
      s0[(s0.size - body.size)..].should eq(body)

      # hex-edit the payload: overtype 0xFF → 0xAB (length unchanged → prefix stays 3)
      view.toggle_request_hex.should be_true
      view.hex_set_nibble('a')
      view.hex_set_nibble('b')
      view.toggle_request_hex.should be_false # exit writes the edited payload back
      sent = view.request_bytes
      sent[(sent.size - 8)..].should eq(Bytes[0x00, 0x00, 0x00, 0x00, 0x03, 0xAB, 0x01, 0x02])
    end
  end

  it "pipeline_requests splits the editor on lone %%% lines and labels each request" do
    view = RepeaterView.new
    req = "GET /a HTTP/1.1\nHost: h\n\n%%%\nGET /b HTTP/1.1\nHost: h\n\n"
    view.restore("http://127.0.0.1", req, false, false)
    reqs = view.pipeline_requests
    reqs.size.should eq(2)
    reqs[0][0].should eq("GET /a HTTP/1.1") # label = the request line
    reqs[1][0].should eq("GET /b HTTP/1.1")
    # a bodyless head gets its CRLFCRLF terminator (the blank line is consumed by the split)
    String.new(reqs[0][1]).should eq("GET /a HTTP/1.1\r\nHost: h\r\n\r\n")
    String.new(reqs[1][1]).should eq("GET /b HTTP/1.1\r\nHost: h\r\n\r\n")
  end

  it "pipeline_requests keeps a bodied request's separator (no double terminator)" do
    view = RepeaterView.new
    req = "POST /a HTTP/1.1\nHost: h\nContent-Length: 4\n\ndata\n%%%\nGET /b HTTP/1.1\nHost: h\n"
    view.restore("http://127.0.0.1", req, false, false)
    reqs = view.pipeline_requests
    reqs.size.should eq(2)
    String.new(reqs[0][1]).should eq("POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 4\r\n\r\ndata")
    String.new(reqs[1][1]).should eq("GET /b HTTP/1.1\r\nHost: h\r\n\r\n")
  end

  it "group_sendable? is false in h2 / hex / gRPC modes" do
    view = RepeaterView.new
    view.load_blank
    view.group_sendable?.should be_true
    view.toggle_http2 # h2 → send_pipeline is an h1 primitive
    view.group_sendable?.should be_false
  end

  it "apply_group shows a per-response transcript and a single ^R send reclaims the pane" do
    view = RepeaterView.new
    view.load_blank
    head = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".to_slice
    resp = Gori::Proxy::Codec::Http1.parse_response_head(head)
    r1 = Gori::Repeater::Result.new(head, "hi".to_slice, resp, 1_000_i64)
    r2 = Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, "connect failed")
    view.apply_group([{"GET /a HTTP/1.1", r1}, {"GET /b HTTP/1.1", r2}])

    view.group_mode?.should be_true
    lines = view.resp_plain_lines
    lines.any?(&.includes?("req 1 · GET /a HTTP/1.1")).should be_true
    lines.any?(&.includes?("HTTP 200")).should be_true
    lines.any?(&.includes?("req 2 · GET /b HTTP/1.1")).should be_true
    lines.any?(&.includes?("connect failed")).should be_true

    # a normal single send takes the response pane back from the group transcript
    view.apply(Gori::Repeater::Result.new(head, "hi".to_slice, resp, 1_000_i64))
    view.group_mode?.should be_false
  end

  it "does not reframe a multi-message gRPC body — verbatim, hex refused" do
    repeater_tmp_store do |store|
      body = Bytes[0x00, 0x00, 0x00, 0x00, 0x01, 0xAA,
        0x00, 0x00, 0x00, 0x00, 0x01, 0xBB] # two framed messages
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
        method: "POST", target: "/S/M", http_version: "HTTP/2",
        head: "POST /S/M HTTP/2\r\nHost: api.test\r\ncontent-type: application/grpc\r\n\r\n".to_slice,
        body: body))
      view = RepeaterView.new
      view.load_grpc(store.get_flow(id).not_nil!)
      view.grpc_reframable?.should be_false
      view.toggle_request_hex.should be_false # nothing single-payload to edit
      sent = view.request_bytes
      sent[(sent.size - body.size)..].should eq(body)
    end
  end

  it "toggle_http2 flips the transport and retargets the request-line version token" do
    view = RepeaterView.new
    view.load_blank
    view.http2?.should be_false
    view.request_text.should contain("HTTP/1.1")

    view.toggle_http2.should be_true
    view.http2?.should be_true
    view.request_text.lines.first.should end_with("HTTP/2")
    view.request_text.should_not contain("HTTP/1.1")

    view.toggle_http2.should be_false
    view.http2?.should be_false
    view.request_text.lines.first.should end_with("HTTP/1.1")
  end

  it "toggle_http2 is refused for gRPC (h2) and WebSocket (h1) — the transport is intrinsic" do
    repeater_tmp_store do |store|
      gid = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
        method: "POST", target: "/demo.Greeter/SayHello", http_version: "HTTP/2",
        head: "POST /demo.Greeter/SayHello HTTP/2\r\nHost: api.test\r\ncontent-type: application/grpc\r\n\r\n".to_slice,
        body: Bytes[0x00, 0x00, 0x00, 0x00, 0x00]))
      gview = RepeaterView.new
      gview.load_grpc(store.get_flow(gid).not_nil!)
      gview.toggle_http2.should be_true # stays h2 — no flip
      gview.http2?.should be_true

      wid = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 2_i64, scheme: "https", host: "ws.test", port: 443,
        method: "GET", target: "/ws", http_version: "HTTP/1.1",
        head: "GET /ws HTTP/1.1\r\nHost: ws.test\r\nUpgrade: websocket\r\n\r\n".to_slice, body: nil))
      wview = RepeaterView.new
      wview.load_ws(store.get_flow(wid).not_nil!, [] of String)
      wview.toggle_http2.should be_false # stays h1 — no flip
      wview.http2?.should be_false
    end
  end

  it "ws_out_messages yields one clean frame per line and labels the tab by the upgrade request" do
    repeater_tmp_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "ws.test", port: 443,
        method: "GET", target: "/ws/chat", http_version: "HTTP/1.1",
        head: "GET /ws/chat HTTP/1.1\r\nHost: ws.test\r\nUpgrade: websocket\r\n\r\n".to_slice, body: nil))
      view = RepeaterView.new
      view.load_ws(store.get_flow(id).not_nil!, ["{\"a\":1}", "ping"])

      msgs = view.ws_out_messages
      msgs.size.should eq(2)
      # the editor joins with CRLF, so a naive split would leave a trailing '\r' on
      # every frame but the last — these must be clean.
      String.new(msgs[0].payload).should eq("{\"a\":1}")
      String.new(msgs[1].payload).should eq("ping")
      # the sub-tab label is the upgrade request line, NOT the first message
      view.summary.should eq("GET /ws/chat")
    end
  end
  it "allows editing both handshake request and messages in ws_mode" do
    repeater_tmp_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "ws.test", port: 443,
        method: "GET", target: "/ws/chat", http_version: "HTTP/1.1",
        head: "GET /ws/chat HTTP/1.1\r\nHost: ws.test\r\nUpgrade: websocket\r\n\r\n".to_slice, body: nil))
      view = RepeaterView.new
      view.load_ws(store.get_flow(id).not_nil!, ["{\"a\":1}", "ping"])

      view.ws_mode?.should be_true
      view.req_pane.should eq(:decoded)

      view.edit_insert('!')
      view.dirty?.should be_true
      msgs = view.ws_out_messages
      msgs.size.should eq(2)
      String.new(msgs[0].payload).should eq("!{\"a\":1}")

      view.clear_dirty
      view.dirty?.should be_false

      view.toggle_req_pane.should eq(:envelope)
      view.edit_insert('X')
      view.dirty?.should be_true
      String.new(view.ws_upgrade_bytes).should contain("XGET /ws/chat HTTP/1.1")
    end
  end

  it "renders a gRPC response as deframed messages + grpc-status" do
    repeater_tmp_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
        method: "POST", target: "/svc/M", http_version: "HTTP/2",
        head: "POST /svc/M HTTP/2\r\nHost: api.test\r\ncontent-type: application/grpc\r\n\r\n".to_slice,
        body: Bytes[0x00, 0x00, 0x00, 0x00, 0x01, 0x41]))
      view = RepeaterView.new
      view.load_grpc(store.get_flow(id).not_nil!)

      # a framed "Hello!" response + grpc-status 0 trailer (as H2Engine synthesises it)
      msg = "Hello!".to_slice
      body = IO::Memory.new
      body.write(Bytes[0x00, 0x00, 0x00, 0x00, msg.size.to_u8])
      body.write(msg)
      head = "HTTP/2 200 OK\r\ncontent-type: application/grpc\r\ngrpc-status: 0\r\ngrpc-message: OK\r\n\r\n"
      resp = Gori::Proxy::Codec::Http1.parse_response_head(head.to_slice)
      view.apply(Gori::Repeater::Result.new(head.to_slice, body.to_slice, resp, 5000_i64))

      backend = MemoryBackend.new(160, 24)
      view.render(Screen.new(backend), Rect.new(0, 0, 160, 24))
      backend.contains?("GRPC RESPONSE").should be_true
      backend.contains?("message #1").should be_true # deframed response message
      backend.contains?("Hello!").should be_true     # ASCII in the hex preview
      backend.contains?("grpc-status: 0 OK").should be_true
    end
  end

  it "restore re-opens a persisted tab and starts clean (not dirty)" do
    view = RepeaterView.new
    view.restore("https://api.test", "POST /x HTTP/1.1\nHost: api.test\n\nbody", true, false)
    view.loaded?.should be_true
    view.target.should eq("https://api.test")
    view.request_text.should eq("POST /x HTTP/1.1\nHost: api.test\n\nbody")
    view.http2?.should be_true
    view.auto_content_length?.should be_false
    view.dirty?.should be_false # synced/restored text must never be re-saved by us
  end

  it "restore with no persisted response starts the pane empty" do
    view = RepeaterView.new
    view.restore("https://api.test", "GET / HTTP/1.1\n\n", false, true)
    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("— not sent — press ^R to resend —").should be_true
  end

  it "restore re-populates a persisted last response (survives a reopen)" do
    view = RepeaterView.new
    head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice
    view.restore("https://api.test", "GET / HTTP/1.1\n\n", false, true,
      head, "RESTORED".to_slice, nil, 1234_i64)
    view.dirty?.should be_false # a restored tab must never be re-saved
    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("RESTORED").should be_true
    backend.contains?("— not sent —").should be_false
  end

  it "restore shows a persisted errored send" do
    view = RepeaterView.new
    view.restore("https://api.test", "GET / HTTP/1.1\n\n", false, true,
      Bytes.empty, nil, "connect failed: api.test:443", 0_i64)
    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("repeater error: connect failed: api.test:443").should be_true
  end

  it "seed_original re-arms the captured-original diff baseline after restore (reopened ^R tab)" do
    view = RepeaterView.new
    # reopened, never-sent History tab: restore() alone is non-diffable …
    view.restore("https://api.test", "GET / HTTP/1.1\n\n", false, true)
    orig_head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice
    view.seed_original(orig_head, "ORIGINAL".to_slice) # … the Runner re-seeds it from flow_id

    sent = Gori::Repeater::Result.new(
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice, "CHANGED".to_slice, nil, 1000_i64)
    view.apply(sent)      # first resend after reopen → baseline is the seeded original
    view.toggle_resp_mode # response → diff

    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("- ORIGINAL").should be_true # diffs against the captured original, not nothing
    backend.contains?("+ CHANGED").should be_true
  end

  it "seed_original is a no-op when the source flow captured no response" do
    view = RepeaterView.new
    view.restore("https://api.test", "GET / HTTP/1.1\n\n", false, true)
    view.seed_original(nil, nil) # flow without a response → stays non-diffable
    ok = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, "X".to_slice, nil, 1000_i64)
    view.apply(ok)
    view.toggle_resp_mode # → diff
    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("first send").should be_true # nothing to diff against yet
  end

  it "marks dirty on edits + flag toggles, and clears on restore" do
    view = RepeaterView.new
    view.load_blank
    view.dirty?.should be_false # a freshly opened tab is clean (persisted on creation)

    view.focus_first # :target
    view.target_insert('x')
    view.dirty?.should be_true
    view.clear_dirty

    view.pane_advance(1) # :target → :request
    view.edit_insert('y')
    view.dirty?.should be_true
    view.clear_dirty

    view.toggle_auto_content_length
    view.dirty?.should be_true

    view.restore("https://z.test", "GET / HTTP/1.1\n\n", false, true)
    view.dirty?.should be_false
  end

  it "label uses the custom name when set, else the request summary" do
    view = RepeaterView.new
    view.load_blank
    view.label(18).should eq("GET /") # auto-derived from the request line
    view.name = "auth flow"
    view.label(18).should eq("auth flow")
    view.name = "   " # blank → revert to the auto label
    view.label(18).should eq("GET /")
    view.name = nil
    view.label(18).should eq("GET /")
  end

  it "label truncates a long custom name" do
    view = RepeaterView.new
    view.load_blank
    view.name = "a-very-long-custom-tab-name"
    label = view.label(8)
    label.size.should be <= 8
    label.should end_with("…")
  end

  it "persists a repeater tab's custom name (set / clear)" do
    repeater_tmp_store do |store|
      id = store.insert_repeater("http://h/x", "GET /x HTTP/1.1", false, true, nil, 0)
      store.set_repeater_name(id, "my-tab")
      store.repeaters.first.name.should eq("my-tab")
      store.set_repeater_name(id, nil) # blank clears the custom name
      store.repeaters.first.name.should be_nil
    end
  end

  it "shows the response duration and size on the RESPONSE pane after a send" do
    view = RepeaterView.new
    view.load_blank
    head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice
    body = ("x" * 2048).to_slice
    view.apply(Gori::Repeater::Result.new(head, body, nil, 234_000_i64)) # 234 ms, head+body ≈ 2 KB

    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("234ms").should be_true
    backend.contains?("KB").should be_true
  end

  it "edits and exposes an SNI override (^S sub-field of the target)" do
    view = RepeaterView.new
    view.load_blank # focus starts on :target
    view.sni_override.should be_nil
    view.editing_sni?.should be_false

    view.toggle_sni_field # ^S → edit the SNI host
    view.editing_sni?.should be_true
    "evil.com".each_char { |c| view.target_insert(c) }
    view.sni.should eq("evil.com")               # the SNI field took the input, not the URL
    view.target.should eq("https://example.com") # URL untouched
    view.sni_override.should eq("evil.com")
    view.dirty?.should be_true

    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("SNI").should be_true
    backend.contains?("evil.com").should be_true
  end

  it "leaving the target pane exits the SNI sub-field (URL edits never land in SNI)" do
    view = RepeaterView.new
    view.load_blank
    view.toggle_sni_field
    "evil.com".each_char { |c| view.target_insert(c) }
    view.editing_sni?.should be_true

    view.pane_advance(1) # ↓/Tab down into the request pane
    view.editing_sni?.should be_false
    view.focus_first # …then back up to the target pane

    view.editing_sni?.should be_false # arrives on the URL field, not the stale SNI sub-field
    view.target_insert('Z')           # a URL keystroke must edit the URL…
    view.target.should eq("https://example.comZ")
    view.sni.should eq("evil.com") # …and leave the SNI value untouched
  end

  it "a click on the TARGET card's bottom border does not enter the SNI sub-field" do
    view = RepeaterView.new
    view.restore("https://10.0.0.5", "GET / HTTP/1.1\n\n", false, true, sni: "evil.com")
    rect = Rect.new(0, 0, 120, 20)
    # With an SNI override the card is 4 rows: border@y, URL@y+1, SNI@y+2, border@y+3.
    view.target_click_to_cursor(rect, 5, rect.y + 3) # the decorative bottom border
    view.editing_sni?.should be_false                # …must NOT switch to the SNI field
    view.target_click_to_cursor(rect, 5, rect.y + 2) # the real SNI row does
    view.editing_sni?.should be_true
  end

  it "restore seeds a persisted SNI override and shows it" do
    view = RepeaterView.new
    view.restore("https://10.0.0.5", "GET / HTTP/1.1\n\n", false, true, sni: "evil.com")
    view.sni_override.should eq("evil.com")
    view.dirty?.should be_false # a restored tab must never be re-saved

    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("evil.com").should be_true
  end

  it "persists a repeater tab's SNI override (set / clear)" do
    repeater_tmp_store do |store|
      id = store.insert_repeater("https://h/x", "GET /x HTTP/1.1", false, true, nil, 0, "evil.com")
      store.repeaters.first.sni.should eq("evil.com")
      store.repeaters_meta.first.sni.should eq("evil.com")                          # syncs via the fast reconcile poll too
      store.update_repeater(id, "https://h/x", "GET /x HTTP/1.1", false, true, nil) # clear
      store.repeaters.first.sni.should be_nil
    end
  end

  it "hscroll scrolls a long response body line sideways into view (shift+←/→)" do
    view = RepeaterView.new
    view.load_blank
    long_line = "HEAD" + ("." * 60) + "TAIL"
    ok = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, long_line.to_slice, nil, 1000_i64)
    view.apply(ok)

    rect = Rect.new(0, 0, 100, 20)
    backend = MemoryBackend.new(100, 20)
    view.render(Screen.new(backend), rect)
    backend.contains?("HEAD").should be_true
    backend.contains?("TAIL").should be_false # off the right edge, clipped

    20.times { view.hscroll(1) } # scroll well past the line's width
    backend2 = MemoryBackend.new(100, 20)
    view.render(Screen.new(backend2), rect)
    backend2.contains?("TAIL").should be_true
    backend2.contains?("HEAD").should be_false # scrolled off the left edge
  end

  it "defaults request and target to READ mode" do
    view = RepeaterView.new
    view.load_blank
    view.request_insert?.should be_false
    view.target_insert?.should be_false
  end

  it "toggles INS mode and shows the badge on the request pane" do
    view = RepeaterView.new
    view.load_blank
    view.focus_pane(:request)
    view.enter_request_insert!
    backend = MemoryBackend.new(120, 24)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 24))
    backend.contains?("i:INS").should be_true
    view.exit_request_insert!
    view.request_insert?.should be_false
    backend2 = MemoryBackend.new(120, 24)
    view.render(Screen.new(backend2), Rect.new(0, 0, 120, 24))
    backend2.contains?("NOR").should be_true
  end

  it "resp_move + selection returns plain text for copy" do
    view = RepeaterView.new
    view.load_blank
    ok = Gori::Repeater::Result.new(
      "HTTP/1.1 200 OK\r\n\r\n".to_slice, "LINE1\nLINE2".to_slice, nil, 1000_i64)
    view.apply(ok)
    view.focus_pane(:response)
    lines = view.resp_plain_lines
    lines.should_not be_empty
    view.resp_move(0, 0)
    view.resp_copy_text.should eq(lines[0])
    view.resp_move(0, 4, selecting: true)
    view.resp_copy_text.should eq(lines[0][0, 4])
  end

  it "^G go-to-line in the response pane also moves the caret (not just the scroll)" do
    view = RepeaterView.new
    view.load_blank
    ok = Gori::Repeater::Result.new(
      "HTTP/1.1 200 OK\r\n\r\n".to_slice, "LINE1\nLINE2\nLINE3\nLINE4".to_slice, nil, 1000_i64)
    view.apply(ok)
    view.focus_pane(:response)
    line3 = view.response_search_lines("LINE3").first # 0-based row of the body's 3rd line

    view.goto_response_line(line3 + 1) # 1-based
    view.resp_copy_text.should eq("LINE3")
    view.resp_move(-1, 0) # ↑ should step to LINE2, not jump from a stale pre-goto caret
    view.resp_copy_text.should eq("LINE2")
  end

  it "apply_peer_request keeps live response + focus (reconcile must not wipe a send)" do
    # Regression: reconcile used full restore() for request-side sync. restore() always
    # sets focus=:target and clears @result when no response BLOBs are passed — so a
    # post-send data_version poll (update_repeater_response bumps it) looked like the
    # response was reset and focus jumped to Target.
    view = RepeaterView.new
    view.load_blank
    view.focus_pane(:response)
    ok = Gori::Repeater::Result.new(
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice, "PONG".to_slice, nil, 1000_i64)
    view.apply(ok)
    view.focus_pane(:response)

    view.apply_peer_request("https://peer.example", "GET /peer HTTP/1.1\nHost: peer.example\n\n",
      false, true, sni: "")

    view.focus.should eq(:response)
    view.target.should eq("https://peer.example")
    view.request_text.should contain("GET /peer")
    # Response still present and renderable
    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("PONG").should be_true
    backend.contains?("— not sent —").should be_false
  end

  it "request_side_matches? treats empty SNI nil and \"\" as equal" do
    view = RepeaterView.new
    view.load_blank
    view.request_side_matches?(view.target, view.request_text, view.http2?,
      view.auto_content_length?, nil).should be_true
    view.request_side_matches?(view.target, view.request_text, view.http2?,
      view.auto_content_length?, "").should be_true
    view.request_side_matches?(view.target, view.request_text, view.http2?,
      view.auto_content_length?, "evil.com").should be_false
  end

  it "post-send store response write + peer request sync keeps the applied result" do
    # End-to-end shape of drain_results + reconcile without a full Host:
    # apply → persist response → apply_peer_request (what reconcile does on mismatch).
    path = File.tempname("gori-send-sync", ".db")
    store = Gori::Store.open(path)
    begin
      view = RepeaterView.new
      view.load_blank
      rid = store.insert_repeater(view.target, view.request_text, view.http2?, view.auto_content_length?,
        nil, 0, view.sni_override)
      view.clear_dirty
      ok = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, "KEEPME".to_slice, nil, 500_i64)
      view.apply(ok)
      view.focus_pane(:response)
      store.update_repeater_response(rid, ok.head, ok.body, nil, ok.duration_us)
      store.flush

      row = store.repeaters_meta.find { |r| r.id == rid }.not_nil!
      # Own row still matches → reconcile would skip. Force a peer-like request edit.
      store.update_repeater(rid, "https://peer.test", "GET /from-peer HTTP/1.1\nHost: peer.test\n\n",
        false, true, nil)
      store.flush
      row = store.repeaters_meta.find { |r| r.id == rid }.not_nil!
      view.request_side_matches?(row.target, row.request, row.http2?,
        row.auto_content_length?, row.sni).should be_false

      view.apply_peer_request(row.target, row.request, row.http2?, row.auto_content_length?,
        sni: row.sni || "")
      view.focus.should eq(:response)
      view.target.should eq("https://peer.test")
      backend = MemoryBackend.new(120, 20)
      view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
      backend.contains?("KEEPME").should be_true
    ensure
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end

  it "focused large-body paint + wheel scroll stay windowed (no full rematerialise)" do
    # Regression: paint_resp_line_chrome used to call resp_plain_lines once per
    # visible row every frame — with BodyLines that re-materialised ~N lines × H
    # rows (~300ms+ for 50k). Focused render + resp_scroll_view must stay far below
    # that full-body cost (same bar as History visible-only path).
    view = RepeaterView.new
    view.load_blank
    line = ("w" * 20) + "\n"
    n = 30_000
    io = IO::Memory.new(line.bytesize * n)
    n.times { io << line }
    body = io.to_slice
    head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice
    view.apply(Gori::Repeater::Result.new(head, body, nil, 1000_i64))
    view.focus_pane(:response)
    view.resp_line_source[0].should be > 25_000

    rect = Rect.new(0, 0, 120, 30)
    backend = MemoryBackend.new(120, 30)
    t0 = Time.instant
    5.times do |frame|
      view.resp_scroll_view(40) if frame > 0
      view.render(Screen.new(backend), rect)
    end
    paint_ms = (Time.instant - t0).total_milliseconds
    paint_ms.should be < 2_000.0

    t1 = Time.instant
    200.times { view.resp_move(1, 0) }
    move_ms = (Time.instant - t1).total_milliseconds
    move_ms.should be < 500.0

    backend.contains?("RESPONSE").should be_true
  end

  describe "pretty_print_request" do
    it "pretty-prints JSON request body in-place and preserves markers" do
      view = RepeaterView.new
      view.restore("https://api.test", "POST /x HTTP/1.1\nHost: api.test\nContent-Type: application/json\nContent-Length: 30\n\n{\"a\":\"§val§\",\"b\":[1,2]}", false, true)

      view.pretty_print_request.should be_nil # success
      view.request_text.should contain("\"a\": \"§val§\"")
      view.request_text.should contain("  \"b\": [\n    1,\n    2\n  ]")
      view.dirty?.should be_true
      view.request_text.should_not contain("Content-Length: 30")
    end
  end
end
