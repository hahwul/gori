require "../spec_helper"

private alias Deflate = Gori::Repeater::WsDeflate

describe Gori::Repeater::WsDeflate do
  it "decodes the RFC 7692 Hello vector" do
    String.new(Deflate.inflate(Bytes[0xf2, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00], 100)).should eq("Hello")
  end

  it "decodes a final-block message from RFC 7692" do
    String.new(Deflate.inflate(Bytes[0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00, 0x00], 100)).should eq("Hello")
  end

  it "compresses independent text, empty and binary messages" do
    ["Hello".to_slice, Bytes.empty, Bytes[0, 255, 128], ("a" * 100_000).to_slice].each do |payload|
      Deflate.inflate(Deflate.compress(payload), payload.size).should eq(payload)
    end
  end

  it "bounds expanded bytes and rejects corrupt compressed data" do
    expect_raises(Deflate::Error, /receive cap/) { Deflate.inflate(Deflate.compress(("a" * 100_000).to_slice), 100) }
    expect_raises(Deflate::Error, /invalid/) { Deflate.inflate(Bytes[255, 255], 100) }
  end

  it "bounds work for an empty-block flood" do
    payload = IO::Memory.new
    100.times { payload.write(Bytes[1, 0, 0, 255, 255]) }
    payload.write_byte(0_u8)
    expect_raises(Deflate::Error, /work cap/) { Deflate.inflate(payload.to_slice, 100) }
  end

  it "accepts only the offered independent-message profile" do
    head = ->(value : String) { "HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Extensions: #{value}\r\n\r\n".to_slice }
    Deflate.negotiated?(head.call(Deflate::OFFER), true).should be_true
    Deflate.negotiated?(head.call("permessage-deflate; server_no_context_takeover"), true).should be_true
    Deflate.negotiated?(head.call(Deflate::OFFER), false).should be_false
    Deflate.negotiated?("HTTP/1.1 101 OK\r\n\r\n".to_slice, true).should be_false
    ["permessage-deflate", "permessage-deflate; server_no_context_takeover=1", "permessage-deflate; server_no_context_takeover; unknown", "permessage-deflate; server_no_context_takeover; server_no_context_takeover", "other"].each do |value|
      expect_raises(Deflate::Error) { Deflate.negotiated?(head.call(value), true) }
    end
  end
end
