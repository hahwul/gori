require "../../spec_helper"
require "json"

# `gori run repeater --format json` renders a `Repeater::Result`. The repeater writes NO
# History row and has no `--format raw`, so this object is the only record of the response
# bytes that surface produces — and a header value's 8-bit octets (the standard
# header-parsing probe) did not survive `scrub`, which replaced each with U+FFFD. They were
# unrecoverable from the CLI entirely. MCP had already been fixed with a
# `<field>_lossy` + `<field>_base64` pair; this is the same shape.
module Gori::CLI::Run
  def self.repeater_json_for_spec(result : Repeater::Result,
                                  response_write : WriteOutcome? = nil,
                                  history_write : WriteOutcome? = nil,
                                  recorded_flow_id : Int64? = nil) : String
    repeater_json(result, nil, false, recorded_flow_id, nil,
      response_write: response_write, history_write: history_write)
  end

  def self.ws_result_json_for_spec(id : Int64, result : Repeater::WsEngine::Result,
                                   response_write : WriteOutcome? = nil) : String
    ws_result_json(id, result, response_write)
  end

  def self.incomplete_reason_for_spec(result : Repeater::Result) : String
    incomplete_reason(result)
  end
end

private def result_of(head : Bytes, body : Bytes? = nil, error : String? = nil,
                      incomplete : Bool = false) : Gori::Repeater::Result
  Gori::Repeater::Result.new(head, body, nil, 1000_i64, error, incomplete)
end

describe "gori run repeater --format json — a lossy response head" do
  it "emits head_base64 + head_lossy when the head is not valid UTF-8" do
    head = "HTTP/1.1 200 OK\r\nX-Bad: A".to_slice + Bytes[0x80] + "B".to_slice + Bytes[0xFF] +
           "C\r\nContent-Length: 2\r\n\r\n".to_slice
    j = JSON.parse(Gori::CLI::Run.repeater_json_for_spec(result_of(head, "ok".to_slice)))
    j["head_lossy"].as_bool.should be_true
    Base64.decode(j["head_base64"].as_s).to_a.should eq(head.to_a)
    # The scrubbed text stays, so an ordinary reader is unaffected.
    j["head"].as_s.should contain("X-Bad: ")
  end

  it "emits neither field for an ordinary head, so the common object is unchanged" do
    j = JSON.parse(Gori::CLI::Run.repeater_json_for_spec(
      result_of("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".to_slice, "ok".to_slice)))
    j["head_lossy"]?.should be_nil
    j["head_base64"]?.should be_nil
  end

  # The engine deliberately KEEPS the response head on a framing error ("must NOT throw the
  # head away as a bare error string"), and the conflicting-Content-Length answer IS the
  # finding. JSON always rendered it; the default TEXT view printed one sentence and dropped
  # it — see `emit_repeater_result`, which now falls through to `print_message_text`.
  it "still carries the head of a FAILED result" do
    head = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 7\r\n\r\n".to_slice
    j = JSON.parse(Gori::CLI::Run.repeater_json_for_spec(
      result_of(head, nil, "conflicting Content-Length values")))
    j["ok"].as_bool.should be_false
    j["head"].as_s.should contain("Content-Length: 5\r\nContent-Length: 7")
  end

  # An error and a RESPONSE are not exclusive. Since RST_STREAM codes stopped being discarded,
  # an h2 stream reset AFTER a partial response yields a named error alongside a real status,
  # head and body — the second shape whose text rendering used to be one sentence.
  it "carries head AND body alongside a named error (h2 RST after a partial response)" do
    head = "HTTP/2 200\r\ncontent-type: application/json\r\n\r\n".to_slice
    j = JSON.parse(Gori::CLI::Run.repeater_json_for_spec(result_of(
      head, %({"partial":).to_slice, "h2 RST_STREAM CANCEL on stream 1", incomplete: true)))
    j["ok"].as_bool.should be_false
    j["error"].as_s.should contain("RST_STREAM CANCEL")
    j["head"].as_s.should contain("HTTP/2 200")
    j["body"]["text"].as_s.should eq(%({"partial":))
    j["incomplete"].as_bool.should be_true
    j["body"]["truncated"].as_bool.should be_true
    j["body"]["wire_truncated"].as_bool.should be_true
  end
end

# `Result#incomplete?` conflates TWO causes: the origin closed before the framed body
# finished, and gori's own capture ceiling stopping the read. The single sentence the CLI
# printed named only the first, so gori blamed the target for something gori did — and that
# got more visible once a genuinely-stated cause (an RST code) started taking the other
# branch. Told apart by the only evidence available here: a body sitting at the ceiling was
# cut by the ceiling.
describe "gori run repeater — why a response is incomplete" do
  head = "HTTP/1.1 200 OK\r\nContent-Length: 999999999\r\n\r\n".to_slice

  it "names the ORIGIN when the body stopped short of gori's ceiling" do
    Gori::CLI::Run.incomplete_reason_for_spec(result_of(head, "short".to_slice, incomplete: true))
      .should eq("incomplete — origin closed before the framed body finished")
  end

  it "names GORI'S OWN ceiling when the body is sitting exactly on it" do
    cap = Gori::Proxy::Codec::Body::CAPTURE_READ_MAX
    Gori::CLI::Run.incomplete_reason_for_spec(result_of(head, Bytes.new(cap), incomplete: true))
      .should eq("incomplete — gori stopped reading at its 8 MiB capture ceiling")
  end

  it "reaches the JSON object too, so the two surfaces agree" do
    j = JSON.parse(Gori::CLI::Run.repeater_json_for_spec(
      result_of(head, "short".to_slice, incomplete: true)))
    j["incomplete_reason"].as_s.should contain("origin closed")
  end
end

# What happened to the two writes a `repeater send` makes AFTER the origin answered — the
# stored response and the `--record-history` flow — as fields on the one object `--format
# json` prints. Both used to be STDERR prose under exit 0, emitted AFTER the JSON: `send 7
# --format json | jq` under a busy project was byte-identical to a success while the row still
# held the previous response, so the next `send 7 --diff` reported "no differences" against a
# stale baseline. Exit 0 is deliberate (the request reached the origin; a shell must not
# resend it), which is why the machine-readable half has to carry the answer.
describe "gori run repeater send --format json — did the post-send writes land?" do
  ok = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".to_slice

  it "says nothing about a write that was not attempted, so the common object is unchanged" do
    j = JSON.parse(Gori::CLI::Run.repeater_json_for_spec(result_of(ok, "ok".to_slice)))
    j["response_saved"]?.should be_nil
    j["response_save_error"]?.should be_nil
    j["history_saved"]?.should be_nil
    j["history_error"]?.should be_nil
  end

  it "carries response_saved:true when the row took the response" do
    j = JSON.parse(Gori::CLI::Run.repeater_json_for_spec(result_of(ok, "ok".to_slice),
      response_write: Gori::CLI::Run::WriteOutcome.new(nil)))
    j["response_saved"].as_bool.should be_true
    j["response_save_error"]?.should be_nil
  end

  it "carries response_saved:false AND the reason, over an otherwise successful send" do
    j = JSON.parse(Gori::CLI::Run.repeater_json_for_spec(result_of(ok, "ok".to_slice),
      response_write: Gori::CLI::Run::WriteOutcome.new("response was NOT saved: session #7 no longer exists")))
    j["ok"].as_bool.should be_true
    j["response_saved"].as_bool.should be_false
    j["response_save_error"].as_s.should contain("session #7 no longer exists")
  end

  # `recorded_flow_id: null` alone read the same as `--record-history` not passed.
  it "tells a failed History record from --record-history not passed" do
    failed = JSON.parse(Gori::CLI::Run.repeater_json_for_spec(result_of(ok, "ok".to_slice),
      history_write: Gori::CLI::Run::WriteOutcome.new("History was NOT saved: the project is busy")))
    failed["recorded_flow_id"]?.should be_nil
    failed["history_saved"].as_bool.should be_false
    failed["history_error"].as_s.should contain("History was NOT saved")

    recorded = JSON.parse(Gori::CLI::Run.repeater_json_for_spec(result_of(ok, "ok".to_slice),
      history_write: Gori::CLI::Run::WriteOutcome.new(nil), recorded_flow_id: 42_i64))
    recorded["recorded_flow_id"].as_i64.should eq(42)
    recorded["history_saved"].as_bool.should be_true
    recorded["history_error"]?.should be_nil
  end

  it "carries the same pair on the WebSocket object" do
    result = Gori::Repeater::WsEngine::Result.new(
      "HTTP/1.1 101 Switching Protocols\r\n\r\n".to_slice, [] of Gori::Repeater::WsEngine::Message,
      10_i64, nil, nil, nil, true)
    plain = JSON.parse(Gori::CLI::Run.ws_result_json_for_spec(3_i64, result))
    plain["response_saved"]?.should be_nil
    failed = JSON.parse(Gori::CLI::Run.ws_result_json_for_spec(3_i64, result,
      Gori::CLI::Run::WriteOutcome.new("response was NOT saved: project is busy")))
    failed["upgraded"].as_bool.should be_true
    failed["response_saved"].as_bool.should be_false
    failed["response_save_error"].as_s.should contain("NOT saved")
  end

  # The principle, pinned on the source: a report emitted before the side effect cannot carry
  # it. Both writes have to happen before the one emit.
  it "makes both writes before it emits the result" do
    src = File.read(File.join(__DIR__, "..", "..", "..", "src", "gori", "cli", "run", "repeater.cr"))
    send_body = src[/private def self\.cmd_repeater_send\(.*?\n      end\n/m].not_nil!
    emit_at = send_body.index("emit_repeater_result(result, new_body").not_nil!
    send_body.index("record_repeater_send_to_history(plan, wire, result").not_nil!.should be < emit_at
    send_body.index("persist_repeater_response(id, result.head").not_nil!.should be < emit_at
    ws_body = src[/private def self\.cmd_repeater_send_ws\(.*?\n      end\n/m].not_nil!
    ws_body.index("persist_repeater_response(id, result.handshake_head").not_nil!
      .should be < ws_body.index("emit_ws_result(id, result, format").not_nil!
  end
end

# #1384: a script branching on a failed `gori run send`/`repeater` had only the `error` sentence
# to match. MCP's result has carried `error_kind` / `error_code` / `retryable` / `delivered` and
# the parsed headers all along; the CLI object now carries the same fields, from the same
# classifier (`Repeater::SendError`), additively — `head` is still there.
describe "gori run repeater --format json — the MCP error and header fields (#1384)" do
  it "classifies a refused connection as a retryable connect error" do
    j = JSON.parse(Gori::CLI::Run.repeater_json_for_spec(
      result_of(Bytes.empty, nil, "connect failed: 127.0.0.1:19999 — host unreachable (DNS/refused/timeout)")))
    j["error_kind"].as_s.should eq("connect")
    j["error_code"].as_s.should eq("NETWORK_ERROR")
    j["retryable"].as_bool.should be_true
    j["delivered"].as_bool.should be_false
  end

  it "tells a timeout from a refused connection, and a framing refusal from both" do
    timeout = JSON.parse(Gori::CLI::Run.repeater_json_for_spec(result_of(Bytes.empty, nil, "read timed out after 10s")))
    timeout["error_kind"].as_s.should eq("timeout")
    framing = JSON.parse(Gori::CLI::Run.repeater_json_for_spec(
      result_of(Bytes.empty, nil, "conflicting Content-Length values")))
    framing["error_kind"].as_s.should eq("protocol")
    framing["retryable"].as_bool.should be_false
  end

  it "does not offer a retry of a request the origin already answered" do
    r = Gori::Repeater::Result.new(Bytes.empty, nil, nil, 1_i64, "connection closed mid-body", delivered: true)
    j = JSON.parse(Gori::CLI::Run.repeater_json_for_spec(r))
    j["delivered"].as_bool.should be_true
    j["retryable"].as_bool.should be_false
  end

  it "omits the error fields on a success, and lists the response headers in wire order" do
    head = "HTTP/1.1 201 Created\r\nX-B: 2\r\nSet-Cookie: a=1\r\nX-B: 3\r\n\r\n".to_slice
    raw = Gori::Proxy::Codec::Http1.parse_response_head(head)
    j = JSON.parse(Gori::CLI::Run.repeater_json_for_spec(Gori::Repeater::Result.new(head, Bytes.empty, raw, 1_i64)))
    j["error_kind"]?.should be_nil
    j["retryable"]?.should be_nil
    j["reason"].as_s.should eq("Created")
    j["http_version"].as_s.should eq("HTTP/1.1")
    j["headers"].as_a.map { |h| {h["name"].as_s, h["value"].as_s} }.should eq(
      [{"X-B", "2"}, {"Set-Cookie", "a=1"}, {"X-B", "3"}])
    # Unredacted, like `head`: the operator's own send is not an inventory listing.
    j["head"].as_s.should contain("Set-Cookie: a=1")
  end

  it "gives an 8-bit header value the lossy + base64 pair head carries" do
    head = "HTTP/1.1 200 OK\r\nX-Bad: A".to_slice + Bytes[0xFF] + "\r\n\r\n".to_slice
    raw = Gori::Proxy::Codec::Http1.parse_response_head(head)
    j = JSON.parse(Gori::CLI::Run.repeater_json_for_spec(Gori::Repeater::Result.new(head, Bytes.empty, raw, 1_i64)))
    bad = j["headers"].as_a.find! { |h| h["name"].as_s == "X-Bad" }
    bad["value_lossy"].as_bool.should be_true
    Base64.decode(bad["value_base64"].as_s).to_a.should eq("A".to_slice.to_a + [0xFF_u8])
  end
end
