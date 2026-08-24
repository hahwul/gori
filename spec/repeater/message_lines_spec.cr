require "../spec_helper"

include Gori::Repeater

describe Gori::Repeater::MessageLines do
  it "joins head + a blank separator + body" do
    head = "GET / HTTP/1.1\r\nHost: x".to_slice
    body = "hello\nworld".to_slice
    MessageLines.of(head, body, decode: false).should eq(
      ["GET / HTTP/1.1", "Host: x", "", "hello", "world"])
  end

  # A head captured off the wire ends WITH its blank line, and `split` leaves an empty
  # trailing field for that final newline. Stating the separator once — instead of blank
  # line + split artifact + an appended third — is what makes the two shapes of one message
  # agree below.
  it "states the head/body separator once for a head that carries its own terminator" do
    head = "POST /a HTTP/1.1\r\nHost: x\r\n\r\n".to_slice
    MessageLines.of(head, "x=1".to_slice, decode: false).should eq(
      ["POST /a HTTP/1.1", "Host: x", "", "x=1"])
    MessageLines.of(head, nil, decode: false).should eq(["POST /a HTTP/1.1", "Host: x", ""])
  end

  # The Comparer's headline pair: a CAPTURED request (head and body held apart) against the
  # Repeater/fuzz re-send of it (one wire blob handed over as `head`, `body` nil). Byte-
  # identical requests used to differ by two lines — both of them blank — purely because of
  # which side of the split the bytes arrived on.
  it "gives the same lines whether the message arrives split or as one blob" do
    head = "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\n".to_slice
    split = MessageLines.of(head, "x=1".to_slice, decode: false)
    blob = MessageLines.of("POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nx=1".to_slice,
      nil, decode: false)
    split.should eq(blob)
  end

  it "still separates a head that does NOT carry its own blank line" do
    MessageLines.of("GET / HTTP/1.1\r\nHost: x".to_slice, "hi".to_slice, decode: false).should eq(
      ["GET / HTTP/1.1", "Host: x", "", "hi"])
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
    lines[2].should contain("binary body") # never the raw bytes (which desync the terminal)
    lines[2].should_not contain("press")   # shared by Comparer/CLI/MCP, which have no hex view
  end

  it "scrubs stray non-UTF-8 bytes in an otherwise-text body (no wide-grapheme desync)" do
    head = "HTTP/1.1 200 OK".to_slice
    body = Bytes[0x68, 0x69, 0x80, 0x0a, 0x62, 0x79, 0x65] # "hi<0x80>\nbye" — invalid byte, no NUL
    lines = MessageLines.of(head, body, decode: false)
    lines.should eq(["HTTP/1.1 200 OK", "", "hi�", "bye"]) # invalid byte → U+FFFD (width 1)
  end
end
