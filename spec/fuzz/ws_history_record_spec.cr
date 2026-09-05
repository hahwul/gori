require "../spec_helper"

private alias Fuzz = Gori::Fuzz

# `--record-history` / `record_history` write each fuzz result as a History flow. A WebSocket
# variation is not a flow, and recording one would MANUFACTURE evidence: the request head
# declares `Upgrade: websocket`, so `Store::FlowDetail#websocket?` answers true, but the row
# would carry a 101 with a synthesized body no 101 ever has and ZERO `ws_messages` rows beside
# it. It renders in History as a WebSocket with an empty transcript, and re-seeding a repeater
# from it yields a session with no frames.
#
# `gori run repeater send` has refused the same thing for the same reason since WebSocket replay
# landed ("--record-history is HTTP-only"). This is the Fuzzer half.
private WS_REQ = ("GET /ws HTTP/1.1\r\nHost: w.test\r\n" \
                  "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
                  "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n").to_slice

private HTTP_REQ = "GET /api?q=1 HTTP/1.1\r\nHost: w.test\r\n\r\n".to_slice

private HEAD_101 = ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
                    "Connection: Upgrade\r\n\r\n").to_slice

private HEAD_200 = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".to_slice

private def result(request : Bytes, head : Bytes, matched : Bool = true) : Fuzz::Result
  Fuzz::Result.new(1_i64, ["p"], nil, 101, 2_i64, 1, 1, 5_i64, nil, matched, false, nil,
    head: head, body: "hi".to_slice, request: request)
end

describe Gori::Fuzz::HistoryRecord do
  it "records an ordinary HTTP result" do
    with_store do |store|
      id = Fuzz::HistoryRecord.record(store, result(HTTP_REQ, HEAD_200),
        scheme: "http", host: "w.test", port: 80, http2: false,
        source: Gori::FlowSource::Kind::Fuzzer,
        surface: Gori::FlowSource::Surface::Cli) { |ex| raise ex }
      id.should_not be_nil
    end
  end

  it "does NOT record a result from a framed WebSocket run" do
    with_store do |store|
      id = Fuzz::HistoryRecord.record(store, result(WS_REQ, HEAD_101),
        scheme: "http", host: "w.test", port: 80, http2: false,
        source: Gori::FlowSource::Kind::Fuzzer,
        surface: Gori::FlowSource::Surface::Cli, websocket: true) { |ex| raise ex }
      id.should be_nil
    end
  end

  # The guard is about which ENGINE ran, not which bytes were sent. `--ws-http-only` sweeps the
  # very same handshake as an ordinary HTTP request, and that exchange is an ordinary flow with
  # nothing manufactured about it — both surfaces' refusal messages point the operator at that
  # flag as the way to get recording back, so it had better record.
  it "DOES record the same handshake bytes when the run was ws-http-only" do
    with_store do |store|
      id = Fuzz::HistoryRecord.record(store, result(WS_REQ, HEAD_101),
        scheme: "http", host: "w.test", port: 80, http2: false,
        source: Gori::FlowSource::Kind::Fuzzer,
        surface: Gori::FlowSource::Surface::Cli, websocket: false) { |ex| raise ex }
      id.should_not be_nil
    end
  end

  # `records?` must agree with `record`, or a surface reports "recorded 40 flows" over an empty
  # table: the count is taken from the predicate and the write from the other.
  it "reports a framed WebSocket result as not recordable, on either policy" do
    Fuzz::HistoryRecord.records?(:all, result(WS_REQ, HEAD_101), websocket: true).should be_false
    Fuzz::HistoryRecord.records?(:matched, result(WS_REQ, HEAD_101, matched: true), websocket: true).should be_false
    Fuzz::HistoryRecord.records?(:all, result(HTTP_REQ, HEAD_200)).should be_true
    Fuzz::HistoryRecord.records?(:all, result(WS_REQ, HEAD_101), websocket: false).should be_true
  end

  # The refusal sentence has ONE author, so `gori run fuzz` and MCP `fuzz_start` cannot word it
  # differently — the job `CLI::Run.ws_notice_dropped_note` already does for the seed side.
  it "publishes the refusal sentence both surfaces quote" do
    Fuzz::HistoryRecord::WS_UNSUPPORTED.should contain("HTTP-only")
    Fuzz::HistoryRecord::WS_UNSUPPORTED.should contain("framed exchange")
  end
end
