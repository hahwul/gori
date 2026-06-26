require "../spec_helper"

include Gori::Replay

describe Gori::Replay::MessageLines do
  it "joins head + a blank separator + body" do
    head = "GET / HTTP/1.1\r\nHost: x".to_slice
    body = "hello\nworld".to_slice
    MessageLines.of(head, body, decode: false).should eq(
      ["GET / HTTP/1.1", "Host: x", "", "hello", "world"])
  end

  it "omits the separator + body when the body is empty or nil" do
    head = "GET / HTTP/1.1".to_slice
    MessageLines.of(head, nil, decode: false).should eq(["GET / HTTP/1.1"])
    MessageLines.of(head, Bytes.empty, decode: false).should eq(["GET / HTTP/1.1"])
  end

  it "returns no lines for a nil head and body" do
    MessageLines.of(nil, nil, decode: false).should be_empty
  end

  it "passes an unencoded body through even when decode is requested" do
    head = "HTTP/1.1 200 OK".to_slice
    body = "plain".to_slice
    MessageLines.of(head, body, decode: true).should eq(["HTTP/1.1 200 OK", "", "plain"])
  end
end
