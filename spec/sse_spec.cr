require "./spec_helper"

private def parse(body : String) : Array(Gori::Sse::Event)
  Gori::Sse.events(body.to_slice)
end

describe Gori::Sse do
  describe ".sse?" do
    it "recognises text/event-stream (with params / casing / leading space)" do
      Gori::Sse.sse?("text/event-stream").should be_true
      Gori::Sse.sse?(" Text/Event-Stream; charset=utf-8").should be_true
      Gori::Sse.sse?("application/json").should be_false
      Gori::Sse.sse?(nil).should be_false
    end
  end

  describe ".events" do
    it "parses a single data event" do
      events = parse("data: hello\n\n")
      events.size.should eq(1)
      events[0].data.should eq("hello")
      events[0].type.should be_nil
      events[0].id.should be_nil
    end

    it "joins multiple data lines with newlines" do
      parse("data: a\ndata: b\n\n")[0].data.should eq("a\nb")
    end

    it "captures event type, id and retry" do
      e = parse("event: tick\nid: 5\nretry: 1000\ndata: x\n\n")[0]
      e.type.should eq("tick")
      e.id.should eq("5")
      e.retry.should eq(1000)
      e.data.should eq("x")
    end

    it "strips exactly one leading space after the colon" do
      parse("data:  two-leading\n\n")[0].data.should eq(" two-leading")
      parse("data:none\n\n")[0].data.should eq("none")
    end

    it "ignores comment lines and blocks without data" do
      events = parse(": keep-alive\n\nevent: ping\n\ndata: real\n\n")
      events.size.should eq(1)
      events[0].data.should eq("real")
    end

    it "carries the last id across following events (stream-level)" do
      events = parse("id: 1\ndata: a\n\ndata: b\n\n")
      events.map(&.id).should eq(["1", "1"])
    end

    it "handles CR, LF and CRLF line terminators" do
      parse("data: x\r\n\r\n")[0].data.should eq("x")
      parse("data: y\r\rdata: z\r\r")[0].data.should eq("y")
    end

    it "emits a trailing event with no terminating blank line (truncated capture)" do
      events = parse("data: partial")
      events.size.should eq(1)
      events[0].data.should eq("partial")
    end

    it "emits an event for a bare empty data field" do
      parse("data\n\n")[0].data.should eq("")
    end

    it "ignores an id containing a NUL" do
      parse("id: a\u0000b\ndata: x\n\n")[0].id.should be_nil
    end

    it "ignores a non-numeric retry" do
      parse("retry: soon\ndata: x\n\n")[0].retry.should be_nil
    end

    it "returns no events for an empty body" do
      parse("").should be_empty
    end

    it "treats an empty event type as the default (nil), not type=\"\"" do
      parse("event:\ndata: x\n\n")[0].type.should be_nil
      parse("event: \ndata: y\n\n")[0].type.should be_nil
    end

    it "clamps an all-digit retry that overflows Int32 instead of dropping it" do
      parse("retry: 99999999999999\ndata: x\n\n")[0].retry.should eq(Int32::MAX)
      parse("retry: 1500\ndata: x\n\n")[0].retry.should eq(1500)
    end
  end

  describe ".event_stream?" do
    it "detects a text/event-stream response head (casing / spaceless / charset)" do
      Gori::Sse.event_stream?("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".to_slice).should be_true
      Gori::Sse.event_stream?("HTTP/1.1 200 OK\r\ncontent-type:text/event-stream\r\n\r\n".to_slice).should be_true
      Gori::Sse.event_stream?("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\n\r\n".to_slice).should be_true
    end

    it "rejects a non-event-stream or absent content-type" do
      Gori::Sse.event_stream?("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n".to_slice).should be_false
      Gori::Sse.event_stream?("HTTP/1.1 200 OK\r\n\r\n".to_slice).should be_false
      Gori::Sse.event_stream?(nil).should be_false
    end
  end
end
