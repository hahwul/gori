require "./spec_helper"

# `Gori::Evidence` builds the immutable copy (#1038) from either live source. The Repeater
# half is the one with judgement in it: its request is one wire blob, its response is
# "whatever the last send left", and a tab that was never sent has no exchange to freeze.

private def repeater(request : String, *, http2 = false, head : String? = nil,
                     body : String? = nil, error : String? = nil, target = "https://acme.test",
                     sent : String? = nil) : Gori::Store::RepeaterRecord
  Gori::Store::RepeaterRecord.new(7_i64, target, request.to_slice, http2, true, nil, 0,
    head.try(&.to_slice), body.try(&.to_slice), error, error ? nil : 12_i64,
    response_request_sha256: sent.try { |t| Gori::Evidence.request_digest(t.to_slice) })
end

private def evidence_filter_meta(id : Int64, issues : Array(Int64), method : String, url : String,
                                 status : Int32?, source = Gori::Store::LinkRefKind::Flow,
                                 at = Time.local(2026, 9, 11).to_unix * 1_000_000) : Gori::Store::IssueEvidenceMeta
  Gori::Store::IssueEvidenceMeta.new(id, issues, at, source, id + 10, method, url,
    "HTTP/1.1", status, 10_i64, nil, false, false, "req", "res", 42_i64)
end

describe Gori::Evidence do
  describe ".from_repeater" do
    it "splits the wire request at the blank line and reads the start line leniently" do
      snap = Gori::Evidence.from_repeater(repeater(
        "POST /api/x HTTP/1.1\nHost: acme.test\n\n{\"a\":1}",
        head: "HTTP/1.1 201 Created\r\nX: y\r\n\r\n", body: "{}")).not_nil!
      snap.source_kind.should eq(Gori::Store::LinkRefKind::Repeater)
      snap.source_id.should eq(7_i64)
      snap.method.should eq("POST")
      snap.url.should eq("https://acme.test/api/x")
      snap.protocol.should eq("HTTP/1.1")
      snap.status.should eq(201)
      snap.duration_us.should eq(12_i64)
      snap.error.should be_nil
      # The head keeps its blank-line terminator, exactly as `flows.request_head` does.
      String.new(snap.request_head).should eq("POST /api/x HTTP/1.1\nHost: acme.test\n\n")
      String.new(snap.request_body.not_nil!).should eq("{\"a\":1}")
      String.new(snap.response_body.not_nil!).should eq("{}")
      snap.response?.should be_true
      snap.bytes.should eq(snap.request_head.size + 7 + snap.response_head.not_nil!.size + 2)
      snap.request_sha256.should eq(Digest::SHA256.hexdigest("POST /api/x HTTP/1.1\nHost: acme.test\n\n{\"a\":1}"))
      snap.response_sha256.should eq(Digest::SHA256.hexdigest("HTTP/1.1 201 Created\r\nX: y\r\n\r\n{}"))
    end

    it "reports DRIFT when the saved request no longer hashes to what produced the response" do
      # The failure this exists for: send, edit the request, freeze. The row then holds an
      # edited request beside the earlier send's response and nothing in the bytes says so.
      snap = Gori::Evidence.from_repeater(repeater(
        "GET /admin HTTP/1.1\r\nHost: acme.test\r\n\r\n",
        head: "HTTP/1.1 200 OK\r\n\r\n", body: "ok",
        sent: "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n")).not_nil!
      snap.request_drifted?.should be_true
    end

    it "reports NO drift when the request still hashes to what produced the response" do
      req = "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n"
      snap = Gori::Evidence.from_repeater(repeater(req, head: "HTTP/1.1 200 OK\r\n\r\n",
        body: "ok", sent: req)).not_nil!
      snap.request_drifted?.should be_false
      # The digest the send side stores IS this snapshot's own request hash — the two are
      # computed over the same bytes, which is what makes the comparison mean anything.
      Gori::Evidence.request_digest(req.to_slice).should eq(snap.request_sha256)
    end

    it "leaves drift FALSE when the digest was never recorded — an unknown is not an accusation" do
      # A response persisted before Schema V28 (or by a gori that did not record it). The
      # request may well have been edited since; nothing here can tell, and guessing "drifted"
      # would refuse every pre-upgrade freeze on a surface that cannot explain why.
      snap = Gori::Evidence.from_repeater(repeater("GET /x HTTP/1.1\r\n\r\n",
        head: "HTTP/1.1 200 OK\r\n\r\n", body: "ok")).not_nil!
      snap.request_drifted?.should be_false
    end

    it "reports drift on an ERRORED send too — that error was the other request's" do
      # `from_repeater` already admits an errored send as evidence of the error. The claim it
      # makes ("these bytes could not be delivered") is about the request that was sent, so an
      # edit since invalidates it exactly as it invalidates a response.
      Gori::Evidence.from_repeater(repeater("GET /x HTTP/1.1\r\n\r\n", head: "",
        error: "connection refused", sent: "GET /y HTTP/1.1\r\n\r\n")).not_nil!
        .request_drifted?.should be_true
    end

    it "names the fix and the surface's own override, or nothing when there is nothing to refuse" do
      req = "GET /a HTTP/1.1\r\n\r\n"
      drifted = Gori::Evidence.from_repeater(repeater(req, head: "HTTP/1.1 200 OK\r\n\r\n",
        sent: "GET /b HTTP/1.1\r\n\r\n")).not_nil!
      clean = Gori::Evidence.from_repeater(repeater(req, head: "HTTP/1.1 200 OK\r\n\r\n", sent: req)).not_nil!

      msg = Gori::Evidence.drift_refusal(drifted, false, "--allow-drift").not_nil!
      msg.should contain("edited after this response was received")
      msg.should contain("send the tab again, or pass --allow-drift")
      Gori::Evidence.drift_refusal(drifted, false, "allow_drift:true").not_nil!.should contain("allow_drift:true")
      # The override, and a snapshot that never drifted, are both "nothing to say".
      Gori::Evidence.drift_refusal(drifted, true, "--allow-drift").should be_nil
      Gori::Evidence.drift_refusal(clean, false, "--allow-drift").should be_nil
    end

    it "refuses a tab that has never been sent — there is no exchange to freeze" do
      Gori::Evidence.from_repeater(repeater("GET / HTTP/1.1\r\n\r\n")).should be_nil
    end

    it "freezes an errored send as evidence of the error, with no response hash" do
      # `update_repeater_response` persists an EMPTY head on error; that is "no response".
      snap = Gori::Evidence.from_repeater(repeater("GET / HTTP/1.1\r\n\r\n", head: "",
        error: "connection refused")).not_nil!
      snap.error.should eq("connection refused")
      snap.status.should be_nil
      snap.response_head.should be_nil
      snap.response_body.should be_nil
      snap.response?.should be_false
      snap.response_sha256.should be_nil
      snap.duration_us.should be_nil
    end

    it "names HTTP/2 from the tab, not from a request line that may spell HTTP/1.1" do
      snap = Gori::Evidence.from_repeater(repeater("GET / HTTP/1.1\r\n\r\n", http2: true,
        head: "HTTP/2 200\r\n\r\n")).not_nil!
      snap.protocol.should eq("HTTP/2")
      snap.status.should eq(200)
    end

    it "composes the url from the ORIGIN the tab dials and the request target" do
      Gori::Evidence.repeater_url("https://a.test", "/p?q=1").should eq("https://a.test/p?q=1")
      Gori::Evidence.repeater_url("https://a.test", "HTTP://b.test/x").should eq("HTTP://b.test/x")
      Gori::Evidence.repeater_url("https://a.test", "*").should eq("https://a.test *")
      Gori::Evidence.repeater_url("https://a.test", "").should eq("https://a.test")
      # The sender reads {scheme, host, port} off the target field and ignores any path typed
      # there, so the copy's url must too — `/api` + `GET /login` reaches `/login`.
      Gori::Evidence.repeater_url("https://a.test/api", "/login").should eq("https://a.test/login")
      Gori::Evidence.repeater_url("https://a.test:8443/", "/x").should eq("https://a.test:8443/x")
      Gori::Evidence.repeater_url("a.test", "/x").should eq("http://a.test/x")
    end
  end

  describe ".freezable?" do
    it "admits a flow and a repeater session, not a fuzz or miner session" do
      Gori::Evidence.freezable?(Gori::Store::LinkRefKind::Flow).should be_true
      Gori::Evidence.freezable?(Gori::Store::LinkRefKind::Repeater).should be_true
      Gori::Evidence.freezable?(Gori::Store::LinkRefKind::Fuzz).should be_false
      Gori::Evidence.freezable?(Gori::Store::LinkRefKind::Miner).should be_false
    end
  end

  describe Gori::Evidence::Snapshot do
    it "costs the four blobs and nothing else" do
      big = Bytes.new(Gori::Evidence::LARGE_BYTES.to_i, 0x41_u8)
      snap = Gori::Evidence::Snapshot.new(Gori::Store::LinkRefKind::Flow, 1_i64, "GET", "http://a.test/",
        "HTTP/1.1", 200, nil, nil, "GET / HTTP/1.1\r\n\r\n".to_slice, nil, "HTTP/1.1 200 OK\r\n\r\n".to_slice, big)
      snap.bytes.should eq(18 + 19 + Gori::Evidence::LARGE_BYTES)
    end
  end

  describe ".snapshot_for" do
    it "refuses a PENDING flow by name — its response is still in flight" do
      with_store do |store|
        fid = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "http", host: "a.test", port: 80, method: "GET",
          target: "/slow", http_version: "HTTP/1.1",
          head: "GET /slow HTTP/1.1\r\nHost: a.test\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
        answer = Gori::Evidence.snapshot_for(store, Gori::Store::LinkRefKind::Flow, fid)
        answer.should be_a(String)
        answer.as(String).should contain("no response yet")
        # The response lands, and the same call now hands back the copy.
        store.update_response(Gori::Store::CapturedResponse.new(fid, 200, "HTTP/1.1 200 OK\r\n\r\n".to_slice, "ok".to_slice))
        Gori::Evidence.snapshot_for(store, Gori::Store::LinkRefKind::Flow, fid).should be_a(Gori::Evidence::Snapshot)
        # A gone flow, a never-sent tab and a fuzz ref each get their own sentence.
        Gori::Evidence.snapshot_for(store, Gori::Store::LinkRefKind::Flow, 999_i64).as(String).should contain("no flow with id 999")
        rid = store.insert_repeater("https://a.test", "GET / HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 0)
        Gori::Evidence.snapshot_for(store, Gori::Store::LinkRefKind::Repeater, rid).as(String).should contain("never been sent")
        Gori::Evidence.snapshot_for(store, Gori::Store::LinkRefKind::Fuzz, 1_i64).as(String).should contain("only a flow or a repeater")
      end
    end
  end

  describe ".label" do
    it "drops the scheme so a frozen row reads beside the live row it was taken from" do
      meta = Gori::Store::IssueEvidenceMeta.new(1_i64, [1_i64], 0_i64, Gori::Store::LinkRefKind::Flow, 3_i64,
        "GET", "https://acme.test/login?x=1", nil, nil, nil, nil, false, false, "", nil, 0_i64)
      Gori::Evidence.label(meta).should eq("GET acme.test/login?x=1")
    end
  end

  describe Gori::Evidence::Filter do
    it "filters the archive across provenance, request, response and mutable Issue state" do
      rows = [
        evidence_filter_meta(1_i64, [7_i64], "GET", "https://api.test/users?q=1", 200),
        evidence_filter_meta(2_i64, [] of Int64, "POST", "https://admin.test/login", 403,
          Gori::Store::LinkRefKind::Repeater),
      ]
      statuses = {7_i64 => Gori::Store::Status::Confirmed}

      Gori::Evidence::Filter.parse("issue:7 confirmation:confirmed").apply(rows, statuses).map(&.id).should eq([1_i64])
      Gori::Evidence::Filter.parse("host:admin.test method:post status:4xx src:repeater").apply(rows, statuses).map(&.id).should eq([2_i64])
      Gori::Evidence::Filter.parse("issue:orphaned date:2026-09-11").apply(rows, statuses).map(&.id).should eq([2_i64])
      Gori::Evidence::Filter.parse("(users OR login) -status:403").apply(rows, statuses).map(&.id).should eq([1_i64])

      malformed = evidence_filter_meta(3_i64, [] of Int64, String.new(Bytes[0xff]), String.new(Bytes[0xfe]), nil)
      Gori::Evidence::Filter.parse("method:x").apply([malformed], statuses).should be_empty
    end
  end
end
