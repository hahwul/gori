require "../spec_helper"
require "../support/mcp_harness"

describe Gori::MCP::Serialize do
  it "inlines short UTF-8 as text" do
    out = JSON.parse(JSON.build { |j| j.object { Gori::MCP::Serialize.emit_body(j, "body", nil, "hi".to_slice, false) } })
    out["body"]["encoding"].as_s.should eq("text")
    out["body"]["text"].as_s.should eq("hi")
    out["body"]["truncated"].as_bool.should be_false
  end

  it "truncates over-cap UTF-8 and flags it" do
    big = ("a" * (Gori::MCP::Serialize::MAX_TEXT + 100)).to_slice
    out = JSON.parse(JSON.build { |j| j.object { Gori::MCP::Serialize.emit_body(j, "body", nil, big, false) } })
    out["body"]["truncated"].as_bool.should be_true
    out["body"]["text"].as_s.bytesize.should eq(Gori::MCP::Serialize::MAX_TEXT)
  end

  it "emits null for an empty body" do
    out = JSON.parse(JSON.build { |j| j.object { Gori::MCP::Serialize.emit_body(j, "body", nil, nil, false) } })
    out["body"].raw.should be_nil
  end

  it "scrubs a malformed head to valid UTF-8 (no stream corruption)" do
    text = Gori::MCP::Serialize.head_text(Bytes[0xff, 0x41, 0xfe]).not_nil!
    text.valid_encoding?.should be_true
    text.should contain("A")
  end

  # `note:"de-chunked"` was the only trace a trailer section could exist: the head stops
  # before the body and the de-chunk stops at the 0-chunk, so `X-T: gotcha` appeared nowhere
  # while the origin's `Trailer:` announcement was echoed — which reads as "none was sent".
  it "surfaces a chunked response's trailers beside the de-chunked body" do
    head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTrailer: X-T\r\n\r\n".to_slice
    body = "5\r\nhello\r\n0\r\nX-T: gotcha\r\n\r\n".to_slice
    out = JSON.parse(JSON.build { |j| j.object { Gori::MCP::Serialize.emit_body(j, "body", head, body, false) } })
    out["body"]["text"].as_s.should eq("hello")
    out["body"]["trailers"].as_a.size.should eq(1)
    out["body"]["trailers"][0]["name"].as_s.should eq("X-T")
    out["body"]["trailers"][0]["value"].as_s.should eq("gotcha")
  end

  it "omits `trailers` entirely when the message has none" do
    head = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".to_slice
    out = JSON.parse(JSON.build { |j| j.object { Gori::MCP::Serialize.emit_body(j, "body", head, "hi".to_slice, false) } })
    out["body"].as_h.has_key?("trailers").should be_false
  end

  # The body had a base64 fallback and a header VALUE did not, so an 8-bit byte there came
  # back as `�` and was unrecoverable through MCP — two different invalid bytes rendered the
  # same. Trailers are header values too, and share the contract.
  it "hands back the exact bytes of a value scrubbing had to change" do
    built = JSON.build do |j|
      j.object { Gori::MCP::Serialize.emit_lossy_text(j, "value", String.new(Bytes[0x80, 0xff])) }
    end
    res = JSON.parse(built)
    res["value"].as_s.valid_encoding?.should be_true
    Base64.decode(res["value_base64"].as_s).should eq(Bytes[0x80, 0xff])
    res["value_lossy"].as_bool.should be_true
  end

  it "adds no base64 twin for a value that survived scrubbing intact" do
    out = JSON.parse(JSON.build { |j| j.object { Gori::MCP::Serialize.emit_lossy_text(j, "value", "plain") } })
    out["value"].as_s.should eq("plain")
    out.as_h.has_key?("value_base64").should be_false
    out.as_h.has_key?("value_lossy").should be_false
  end

  # base64 is encoding, not redaction — the raw head carries the Authorization/Cookie bytes
  # `response_head` carefully redacts, so the bytes are gated the way intercept_item_detail's
  # `raw_base64` is. The LOSSY FLAG is not gated: a caller must always learn that the text it
  # was handed is not the whole truth.
  it "flags a lossy head always, and emits its bytes only under include_sensitive" do
    head = Bytes[0x58, 0x3a, 0x20, 0x80, 0xff]
    built = JSON.build do |j|
      j.object { Gori::MCP::Serialize.emit_head_base64(j, "response_head", head, false) }
    end
    gated = JSON.parse(built)
    gated["response_head_lossy"].as_bool.should be_true
    gated.as_h.has_key?("response_head_base64").should be_false

    built = JSON.build do |j|
      j.object { Gori::MCP::Serialize.emit_head_base64(j, "response_head", head, true) }
    end

    opened = JSON.parse(built)
    Base64.decode(opened["response_head_base64"].as_s).should eq(head)
  end

  it "adds nothing for a head that is valid UTF-8" do
    built = JSON.build do |j|
      j.object { Gori::MCP::Serialize.emit_head_base64(j, "response_head", "HTTP/1.1 200 OK\r\n\r\n".to_slice, true) }
    end
    out = JSON.parse(built)
    out.as_h.should be_empty
  end
end
