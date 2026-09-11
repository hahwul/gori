require "./spec_helper"
require "../src/gori/redact/wire"

private def with_salt(&)
  before = Gori::Redact.salt
  Gori::Redact.salt = "spec-salt"
  begin
    yield
  ensure
    Gori::Redact.salt = before
  end
end

private def matcher
  Gori::Redact::Matcher.new(Gori::Redact::DEFAULT_PROFILE)
end

describe Gori::Redact::Wire do
  it "repairs Content-Length to describe the sanitized body" do
    with_salt do
      head = "POST /login HTTP/1.1\r\nHost: h.test\r\nContent-Type: application/json\r\nContent-Length: 31\r\n\r\n"
      body = %({"user":"ada","password":"pw"})
      s = Gori::Redact::Wire.message(head.to_slice, body.to_slice, matcher)
      s.count.should eq 1
      text = String.new(s.head)
      text.scan(/Content-Length/i).size.should eq 1
      text.should contain "Content-Length: #{s.body.not_nil!.size}"
      text.should end_with "\r\n\r\n"
      text.should contain "Host: h.test"
    end
  end

  it "adds a Content-Length to a head that carried none" do
    with_salt do
      head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
      s = Gori::Redact::Wire.message(head.to_slice, %({"token":"t"}).to_slice, matcher)
      String.new(s.head).should contain "Content-Length: #{s.body.not_nil!.size}\r\n\r\n"
    end
  end

  it "drops the transfer fields once the body has been decoded out of them" do
    with_salt do
      raw = %({"password":"pw","keep":1})
      chunked = "#{raw.bytesize.to_s(16)}\r\n#{raw}\r\n0\r\n\r\n"
      head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
      s = Gori::Redact::Wire.message(head.to_slice, chunked.to_slice, matcher)
      s.decoded?.should be_true
      s.count.should eq 1
      String.new(s.head).downcase.should_not contain "transfer-encoding"
      JSON.parse(String.new(s.body.not_nil!))["keep"].as_i.should eq 1
    end
  end

  it "leaves a message with no body alone" do
    head = "GET / HTTP/1.1\r\nHost: h.test\r\n\r\n"
    s = Gori::Redact::Wire.message(head.to_slice, nil, matcher)
    String.new(s.head).should eq head
    s.body.should be_nil
    s.result.shape.should eq Gori::Redact::Shape::Empty
  end

  it "frames a head that had no blank line rather than appending into the body" do
    with_salt do
      head = "POST / HTTP/1.1\r\nContent-Type: application/json"
      s = Gori::Redact::Wire.message(head.to_slice, %({"pin":"1234"}).to_slice, matcher)
      text = String.new(s.head)
      text.should end_with "\r\n\r\n"
      text.lines.size.should eq 4 # request line, type, length, the blank line
      text.should contain "Content-Type: application/json\r\nContent-Length:"
    end
  end

  it "leaves a head with no CRLF alone rather than framing one it cannot parse" do
    with_salt do
      # `Http1.strip_header_lines` — which removed the old Content-Length — sees no header
      # block here, so inserting one would leave the message carrying two framing fields.
      # The BODY is still sanitized; only the head is left as authored.
      head = "POST / HTTP/1.1\nContent-Length: 13\n\n"
      s = Gori::Redact::Wire.message(head.to_slice, %({"pin":"1234"}).to_slice, matcher)
      String.new(s.head).should eq head
      s.count.should eq 1
      String.new(s.body.not_nil!).should_not contain "1234"
    end
  end

  it "does not claim a body is plain when a coding did not come off" do
    with_salt do
      # `ContentDecode` stops at the first layer it cannot undo and hands back the bytes AS
      # THEY STOOD — de-chunked here, but still `compress`-coded — so a caller that reads only
      # "decoded is non-nil" would strip both framing headers and publish compressed bytes
      # labelled plain. The note is what separates the two, and `reframe` is gated on it.
      payload = Bytes[0x1f, 0x8b, 0x08, 0x00, 0xff, 0xfe]
      chunked = IO::Memory.new
      chunked << payload.size.to_s(16) << "\r\n"
      chunked.write(payload)
      chunked << "\r\n0\r\n\r\n"
      head = "HTTP/1.1 200 OK\r\nContent-Encoding: compress\r\nTransfer-Encoding: chunked\r\n\r\n"
      s = Gori::Redact::Wire.message(head.to_slice, chunked.to_slice, matcher)
      s.decoded?.should be_false
      s.result.withheld?.should be_true
      text = String.new(s.head)
      text.should contain "Content-Encoding: compress"
      text.should contain "Transfer-Encoding: chunked"
    end
  end

  describe "a whole flow" do
    it "sanitizes both sides and leaves the original detail untouched" do
      with_salt do
        row = Gori::Store::FlowRow.new(
          id: 1_i64, created_at: 0_i64, scheme: "https", method: "POST", host: "h.test",
          port: 443, target: "/login", status: 200, size: 0_i64,
          state: Gori::Store::FlowState::Complete)
        req_head = "POST /login HTTP/1.1\r\nContent-Type: application/json\r\n\r\n".to_slice
        req_body = %({"password":"pw"}).to_slice
        res_head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n".to_slice
        res_body = %({"access_token":"t"}).to_slice
        detail = Gori::Store::FlowDetail.new(row, "HTTP/1.1", req_head, req_body, res_head, res_body)
        clean, report = Gori::Redact::Wire.flow(detail, matcher)
        report.count.should eq 2
        report.redacted?.should be_true
        report.summary.should contain "2 values redacted"
        report.summary.should contain "profile \"default\""
        report.replacements.map(&.[0]).should eq ["request", "response"]
        String.new(clean.request_body.not_nil!).should_not contain "\"pw\""
        String.new(clean.response_body.not_nil!).should_not contain "\"t\""
        # The detail handed in still holds the captured octets.
        String.new(detail.request_body.not_nil!).should eq %({"password":"pw"})
      end
    end

    it "keeps a pending flow's absent response head absent" do
      with_salt do
        row = Gori::Store::FlowRow.new(
          id: 2_i64, created_at: 0_i64, scheme: "https", method: "GET", host: "h.test",
          port: 443, target: "/", status: nil, size: 0_i64,
          state: Gori::Store::FlowState::Pending)
        detail = Gori::Store::FlowDetail.new(row, "HTTP/1.1",
          "GET / HTTP/1.1\r\n\r\n".to_slice, nil, nil, nil)
        clean, report = Gori::Redact::Wire.flow(detail, matcher)
        clean.response_head.should be_nil
        report.count.should eq 0
        report.summary.should contain "0 values redacted"
      end
    end
  end
end
