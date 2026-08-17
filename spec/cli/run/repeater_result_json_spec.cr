require "../../spec_helper"
require "json"

# `gori run repeater --format json` renders a `Repeater::Result`. The repeater writes NO
# History row and has no `--format raw`, so this object is the only record of the response
# bytes that surface produces — and a header value's 8-bit octets (the standard
# header-parsing probe) did not survive `scrub`, which replaced each with U+FFFD. They were
# unrecoverable from the CLI entirely. MCP had already been fixed with a
# `<field>_lossy` + `<field>_base64` pair; this is the same shape.
module Gori::CLI::Run
  def self.repeater_json_for_spec(result : Repeater::Result) : String
    repeater_json(result, nil)
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
