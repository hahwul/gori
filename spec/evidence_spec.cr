require "./spec_helper"

# `Gori::Evidence` builds the immutable copy (#1038) from either live source. The Repeater
# half is the one with judgement in it: its request is one wire blob, its response is
# "whatever the last send left", and a tab that was never sent has no exchange to freeze.

private def repeater(request : String, *, http2 = false, head : String? = nil,
                     body : String? = nil, error : String? = nil, target = "https://acme.test") : Gori::Store::RepeaterRecord
  Gori::Store::RepeaterRecord.new(7_i64, target, request.to_slice, http2, true, nil, 0,
    head.try(&.to_slice), body.try(&.to_slice), error, error ? nil : 12_i64)
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

    it "composes the url from the origin and the request target without doubling either" do
      Gori::Evidence.repeater_url("https://a.test", "/p?q=1").should eq("https://a.test/p?q=1")
      Gori::Evidence.repeater_url("https://a.test", "HTTP://b.test/x").should eq("HTTP://b.test/x")
      Gori::Evidence.repeater_url("https://a.test", "*").should eq("https://a.test *")
      Gori::Evidence.repeater_url("https://a.test", "").should eq("https://a.test")
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
    it "marks a copy at or past LARGE_BYTES as worth a confirm" do
      big = Bytes.new(Gori::Evidence::LARGE_BYTES.to_i, 0x41_u8)
      snap = Gori::Evidence::Snapshot.new(Gori::Store::LinkRefKind::Flow, 1_i64, "GET", "http://a.test/",
        "HTTP/1.1", 200, nil, nil, "GET / HTTP/1.1\r\n\r\n".to_slice, nil, "HTTP/1.1 200 OK\r\n\r\n".to_slice, big)
      snap.large?.should be_true
      snap.bytes.should eq(18 + 19 + Gori::Evidence::LARGE_BYTES)
    end
  end

  describe ".label" do
    it "drops the scheme so a frozen row reads beside the live row it was taken from" do
      meta = Gori::Store::IssueEvidenceMeta.new(1_i64, 1_i64, 0_i64, Gori::Store::LinkRefKind::Flow, 3_i64,
        "GET", "https://acme.test/login?x=1", nil, nil, nil, nil, false, false, "", nil, 0_i64)
      Gori::Evidence.label(meta).should eq("GET acme.test/login?x=1")
    end
  end
end
