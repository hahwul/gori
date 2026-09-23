require "../spec_helper"
require "socket"

# #1068 — one saved session, two surfaces, two different bodies on the wire.
#
# A repeater session that is a DRAFT (no `flow_id`) and carries a `§value¦chain§` marker was
# sent rendered by the TUI (`user=YWRtaW4=`, CL 27) and LITERALLY by `gori run repeater send`
# and MCP `send_request` (`user=§admin¦base64-encode§`, CL 31) — with `Content-Length`
# resynced around the § bytes, so the divergence left no trace and MCP answered
# `isError:false, status:200` for a request nobody wrote.
#
# The fix is NOT to render headlessly: on an EVIDENCE session (non-NULL `flow_id`) the same
# rendering would delete two bytes the origin really sent, which is what
# `RepeaterView#markers_live?` exists to prevent. So the DRAFT half is refused at the send
# seam, and the EVIDENCE half must keep replaying its § byte-exact — both are pinned here.

private alias DM = Gori::Repeater::DraftMarkers

private def rec_for(request : String, flow_id : Int64? = nil) : Gori::Store::RepeaterRecord
  Gori::Store::RepeaterRecord.new(1_i64, "http://a.test", request.to_slice,
    false, true, flow_id, 0)
end

# A captured flow whose REQUEST is `request` — the bytes `DraftMarkers` reads to decide
# whether a flow-seeded session's § came from the origin or from the operator.
private def seed_flow(store, request : String) : Int64
  head, _, body = request.partition("\r\n\r\n")
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "a.test", port: 80,
    method: "POST", target: "/l", http_version: "HTTP/1.1",
    head: "#{head}\r\n\r\n".to_slice, body: body.empty? ? nil : body.to_slice,
    source: Gori::FlowSource::Kind::Import))
end

# An origin that records the exact bytes it was handed, then answers 204. Used for the half
# of the promise that is about SENDING: a captured § still goes out as the capture had it.
private def start_recording_origin(sink : Channel(Bytes)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    buf = IO::Memory.new
    begin
      if conn = origin.accept?
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

describe Gori::Repeater::DraftMarkers do
  it "answers true for a session with NO source flow holding a closed §…§ region" do
    with_store_env do |store|
      DM.live?(store, rec_for("POST /l HTTP/1.1\r\nHost: a.test\r\n\r\nuser=§admin¦base64-encode§")).should be_true
      # No chain is the same answer: `§admin§` renders to `admin`, which is still not these bytes.
      DM.live?(store, rec_for("POST /l HTTP/1.1\r\nHost: a.test\r\n\r\nuser=§admin§")).should be_true
    end
  end

  it "answers true for a FLOW-SEEDED session the operator marked by hand" do
    with_store_env do |store|
      # The commonest way a marker gets into a session at all: ^R off History, then ^T. The
      # capture carried no §, so every § in the row was typed here — which is exactly what
      # `RepeaterView#adopt_capture_markers` re-derives, making the tab render it on ^R.
      fid = seed_flow(store, "POST /l HTTP/1.1\r\nHost: a.test\r\n\r\nuser=admin")
      rec = rec_for("POST /l HTTP/1.1\r\nHost: a.test\r\n\r\nuser=§admin¦base64-encode§", flow_id: fid)
      DM.live?(store, rec).should be_true
    end
  end

  it "answers false when the CAPTURE carried a § of its own" do
    with_store_env do |store|
      # U+00A7 is ordinary text — this body is a German legal citation. gori cannot tell the
      # operator's § from the origin's here, so the TAB leaves its markers inert and says so on
      # the REQUEST border: the headless bytes already match it, and there is nothing to refuse.
      text = "POST /l HTTP/1.1\r\nHost: a.test\r\n\r\nz=§ 5 Abs. 2 §"
      fid = seed_flow(store, text)
      DM.live?(store, rec_for(text, flow_id: fid)).should be_false
      # A § in the capture's HEAD counts the same (the seed read head+body).
      head_fid = seed_flow(store, "POST /l HTTP/1.1\r\nHost: a.test\r\nX-Ref: §12§\r\n\r\nz=1")
      DM.live?(store, rec_for("POST /l HTTP/1.1\r\nHost: a.test\r\nX-Ref: §12§\r\n\r\nz=§1§",
        flow_id: head_fid)).should be_false
      # …and the same bytes with NO flow behind them are the operator's.
      DM.live?(store, rec_for(text)).should be_true
    end
  end

  it "answers false when the source flow is gone — the tab is inert there too" do
    with_store_env do |store|
      DM.live?(store, rec_for("POST /l HTTP/1.1\r\nHost: a.test\r\n\r\nz=§1§", flow_id: 4242_i64)).should be_false
    end
  end

  it "answers false for a request with no marker REGION" do
    with_store_env do |store|
      DM.live?(store, rec_for("GET / HTTP/1.1\r\nHost: a.test\r\n\r\n")).should be_false
      # An unbalanced trailing § opens no position (`Template.parse` folds it into literal
      # text), so there is nothing the tab would render differently.
      DM.live?(store, rec_for("GET /?q=§ HTTP/1.1\r\nHost: a.test\r\n\r\n")).should be_false
      # `§§` is the ESCAPE — one literal § on the wire, from every surface.
      DM.live?(store, rec_for("GET /?q=§§ HTTP/1.1\r\nHost: a.test\r\n\r\n")).should be_false
    end
  end

  it "does not walk a non-UTF-8 body as chars" do
    with_store_env do |store|
      # The byte prefilter is why: `marked_spans` walks chars, and a request gori stored may be
      # binary. This one holds no § byte, so the char walk never runs — and the answer is the
      # same one a valid-UTF-8 copy would get.
      bytes = Bytes[0x50, 0x4f, 0x53, 0x54, 0x20, 0x2f, 0x20, 0x48, 0x54, 0x54, 0x50, 0x2f, 0x31,
        0x2e, 0x31, 0x0d, 0x0a, 0x0d, 0x0a, 0xff, 0xfe, 0x01, 0x02]
      rec = Gori::Store::RepeaterRecord.new(1_i64, "http://a.test", bytes, false, true, nil, 0)
      DM.live?(store, rec).should be_false
    end
  end

  # `repeater send --path` sends an edited COPY; a marker the edit replaced is not on the wire,
  # so it must not refuse the send (#1116).
  it "answers about the request it is handed, not the stored one" do
    with_store do |store|
      rec = rec_for("GET /items/§id§ HTTP/1.1\r\nHost: h\r\n\r\n")
      Gori::Repeater::DraftMarkers.live?(store, rec).should be_true
      Gori::Repeater::DraftMarkers.live?(store, rec, "GET /items/42 HTTP/1.1\r\nHost: h\r\n\r\n".to_slice).should be_false
    end
  end

  it "writes ONE sentence both headless surfaces can carry" do
    msg = DM.refusal(7_i64, "Remedy here.")
    msg.should contain("repeater #7")
    msg.should contain("§…§")
    msg.should contain("Remedy here.")
  end
end

describe "MCP send_request — a session whose §…§ the tab would render (#1068)" do
  it "refuses a send from a session with no source flow, and records no History flow" do
    with_store_env do |store|
      id = store.insert_repeater("http://127.0.0.1:1/login",
        "POST /login HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 27\r\n\r\nuser=§admin¦base64-encode§".to_slice,
        false, true, nil, 0)
      r = tools_for(store).call("send_request",
        JSON.parse(%({"repeater_id":#{id},"allow_unscoped":true})))
      r.is_error.should be_true
      r.text.should contain("holds §…§ markers")
      r.text.should contain("NOTHING was sent")
      r.error_code.should eq("INVALID_ARGUMENT")
      r.field.should eq("repeater_id")
      # `record_history` defaults to true and writes the flow BEFORE the send, so an empty
      # History is the proof that the refusal landed ahead of the socket rather than after it.
      store.count?.should eq(0)
    end
  end

  it "refuses a FLOW-SEEDED session too when the capture carried no § of its own" do
    with_store_env do |store|
      # Keying the gate on `flow_id` alone would have let this through — and this is the
      # commonest marked session there is: ^R off History, ^T, save.
      flow_id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "127.0.0.1", port: 1,
        method: "POST", target: "/login", http_version: "HTTP/1.1",
        head: "POST /login HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice,
        body: "user=admin".to_slice, source: Gori::FlowSource::Kind::Import))
      id = store.insert_repeater("http://127.0.0.1:1",
        "POST /login HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\nuser=§admin¦base64-encode§".to_slice,
        false, true, flow_id, 0)
      r = tools_for(store).call("send_request",
        JSON.parse(%({"repeater_id":#{id},"allow_unscoped":true})))
      r.is_error.should be_true
      r.text.should contain("holds §…§ markers")
      store.count?.should eq(1) # the seed flow, and nothing this call wrote
    end
  end

  it "still replays a session whose § the CAPTURE carried, byte-exact" do
    with_store_env do |store|
      sink = Channel(Bytes).new(1)
      port = start_recording_origin(sink)
      body = "user=§admin¦base64-encode§"
      # The capture holds the § itself, so gori cannot attribute it — the TAB leaves the
      # markers inert and these bytes are what every surface sends.
      flow_id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "127.0.0.1", port: port,
        method: "POST", target: "/login", http_version: "HTTP/1.1",
        head: "POST /login HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice,
        body: body.to_slice, source: Gori::FlowSource::Kind::Import))
      id = store.insert_repeater("http://127.0.0.1:#{port}",
        "POST /login HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}".to_slice,
        false, true, flow_id, 0)
      r = tools_for(store).call("send_request",
        JSON.parse(%({"repeater_id":#{id},"allow_unscoped":true,"record_history":false})))
      r.is_error.should be_false
      # The § reached the origin as the capture held it — no rendering, no re-framing.
      String.new(sink.receive).should contain(body)
    end
  end

  it "sends the stored bytes as they are under verbatim:true" do
    with_store_env do |store|
      sink = Channel(Bytes).new(1)
      port = start_recording_origin(sink)
      body = "z=§ 5 Abs. 2 §"
      id = store.insert_repeater("http://127.0.0.1:#{port}",
        "POST /l HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}".to_slice,
        false, true, nil, 0)
      r = tools_for(store).call("send_request",
        JSON.parse(%({"repeater_id":#{id},"allow_unscoped":true,"record_history":false,"verbatim":true})))
      # The escape the refusal names: a session with no capture behind it whose § really is
      # data would otherwise be a one-way door.
      r.is_error.should be_false
      String.new(sink.receive).should contain(body)
    end
  end
end

describe "retest — a step whose session holds live §…§ (#1068)" do
  it "refuses the step at PLAN time, before the confirm counts it as a send" do
    with_store_env do |store|
      rid = store.insert_repeater("http://a.test",
        "POST /l HTTP/1.1\r\nHost: a.test\r\n\r\nuser=§admin¦base64-encode§".to_slice,
        false, true, nil, 0)
      issue_id = store.insert_issue("t", Gori::Store::Severity::High, "a.test", nil)
      store.add_retest_step(issue_id, :variant, Gori::Store::LinkRefKind::Repeater, rid, "status:200")
      planned = Gori::Retest.plan(store, issue_id)
      planned.size.should eq(1)
      planned[0].runnable?.should be_false
      planned[0].missing.not_nil!.should contain("holds §…§ markers")
    end
  end

  it "refuses at the SEND seam too — the row can change between plan and run" do
    with_store_env do |store|
      rid = store.insert_repeater("http://a.test",
        "POST /l HTTP/1.1\r\nHost: a.test\r\n\r\nuser=§admin¦base64-encode§".to_slice,
        false, true, nil, 0)
      step = Gori::Store::RetestStep.new(1_i64, 1_i64, 1, Gori::Store::RetestRole::Variant,
        Gori::Store::LinkRefKind::Repeater, rid, "", 0_i64, 0_i64)
      # Planned as RUNNABLE, the way a plan taken before a peer's edit would be.
      planned = Gori::Retest::Planned.new(step, "POST", "http://a.test/l", "repeater ##{rid}")
      backend = Gori::Retest::LiveBackend.new(store, ungated_outbound,
        issue_id: 1_i64, surface: Gori::FlowSource::Surface::Cli)
      obs = backend.send(planned)
      obs.blocked?.should be_true
      obs.blocked_reason.not_nil!.should contain("holds §…§ markers")
      obs.status.should be_nil
      # Nothing dialled, so `finish` has only the (unused) Outbound to close.
      backend.finish
    end
  end
end
