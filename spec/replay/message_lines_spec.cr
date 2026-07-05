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

  it "shows a placeholder for a binary body instead of rendering raw bytes" do
    head = "HTTP/1.1 200 OK".to_slice
    body = Bytes[0x89, 0x50, 0x4e, 0x47, 0x00, 0xff, 0x01] # PNG-ish, contains NUL → binary
    lines = MessageLines.of(head, body, decode: false)
    lines[0].should eq("HTTP/1.1 200 OK")
    lines[1].should eq("")
    lines[2].should contain("binary body")
    lines[2].should contain("press x") # never the raw bytes (which desync the terminal)
  end

  it "scrubs stray non-UTF-8 bytes in an otherwise-text body (no wide-grapheme desync)" do
    head = "HTTP/1.1 200 OK".to_slice
    body = Bytes[0x68, 0x69, 0x80, 0x0a, 0x62, 0x79, 0x65] # "hi<0x80>\nbye" — invalid byte, no NUL
    lines = MessageLines.of(head, body, decode: false)
    lines.should eq(["HTTP/1.1 200 OK", "", "hi�", "bye"]) # invalid byte → U+FFFD (width 1)
  end
end
