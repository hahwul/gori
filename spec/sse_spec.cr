require "./spec_helper"

private def parse(body : String) : Array(Gori::Sse::Event)
  Gori::Sse.events(body.to_slice)
end

describe Gori::Sse do
  describe ".sse?" do
    it "recognises text/event-stream (with params / casing / leading space)" do
      Gori::Sse.sse?("text/event-stream").should be_true
      Gori::Sse.sse?(" Text/Event-Stream; charset=utf-8").should be_true
      Gori::Sse.sse?("text/event-streaming").should be_false
      Gori::Sse.sse?("text/event-streamx").should be_false
      Gori::Sse.sse?("application/json").should be_false
      Gori::Sse.sse?(nil).should be_false
    end

    # The allocation-free pre-check in front of the parse (#1631) only ever rejects what the
    # parse would: every casing and padding the parse accepts still gets through it.
    it "answers exactly as the media-type parse does" do
      ["TEXT/EVENT-STREAM", "\ttext/event-stream ;q=1", "text/Event-Stream\r", "text/event-stream;",
       "event-stream", "text/event_stream", "text/eventstream", "", "a/b; x=text/event-stream"].each do |v|
        Gori::Sse.sse?(v).should eq(Gori::MediaType.essence(v) == "text/event-stream")
      end
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

    it "ignores a leading UTF-8 BOM (WHATWG preprocessing)" do
      e = parse("#{0xFEFF.chr}event: tick\ndata: hi\n\n")[0]
      e.type.should eq("tick") # BOM didn't mangle the first field name
      e.data.should eq("hi")
    end

    it "treats an empty event type as the default (nil), not type=\"\"" do
      parse("event:\ndata: x\n\n")[0].type.should be_nil
      parse("event: \ndata: y\n\n")[0].type.should be_nil
    end

    it "clamps an all-digit retry that overflows Int32 instead of dropping it" do
      parse("retry: 99999999999999\ndata: x\n\n")[0].retry.should eq(Int32::MAX)
      parse("retry: 1500\ndata: x\n\n")[0].retry.should eq(1500)
    end

    it "scrubs invalid UTF-8 so no raw bytes reach the display (a lying content-type can route binary here)" do
      # "data: A" + a truncated 3-byte sequence (\xE4\xB8) + "B\n\n"
      body = Bytes[0x64, 0x61, 0x74, 0x61, 0x3a, 0x20, 0x41, 0xE4, 0xB8, 0x42, 0x0a, 0x0a]
      events = Gori::Sse.events(body)
      events.size.should eq(1)
      events[0].data.valid_encoding?.should be_true # the width-desync corruption vector is gone
      events[0].data.should start_with("A")
      events[0].data.should end_with("B")
    end

    it "treats a CRLF split from a lone CR exactly as the terminators say" do
      parse("data: a\r\ndata: b\r\rdata: c\n\r\n").map(&.data).should eq(["a\nb", "c"])
      parse("data: end\r").map(&.data).should eq(["end"])
    end

    # The old split made a String per line before looking at any of them: 32 MiB of `a\n` cost
    # ~930 MiB. A line that is not a kept field now costs nothing at all.
    it "parses millions of lines without materialising them" do
      body = ("a\n" * (4 * 1024 * 1024)).to_slice
      GC.collect
      before = GC.stats.total_bytes
      Gori::Sse.events(body).should be_empty
      (GC.stats.total_bytes - before).should be < 1024 * 1024
    end

    it "caps one event's data, then keeps parsing" do
      line = "data: " + "x" * 1023 + "\n"
      body = line * (Gori::Sse::MAX_EVENT_DATA // 1024 + 8) + "\ndata: next\n\n"
      events = parse(body)
      events.size.should eq(2)
      events[0].data.bytesize.should be <= Gori::Sse::MAX_EVENT_DATA
      events[0].data.bytesize.should be > Gori::Sse::MAX_EVENT_DATA - 1024
      events[1].data.should eq("next")
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

  describe Gori::Sse::Counter do
    # The counter must agree with `events` however the bytes arrive: every split point, so a
    # CRLF, a BOM or a field name torn across two reads is still read once.
    it "counts what .events dispatches, at every split of the stream" do
      body = "\uFEFFdata: a\r\n\r\n: comment\n\nevent: x\ndata\n\n" \
             "id: 7\n\ndataset: no\n\ndata: b\rdata: c\r\rretry: 5\n\ndata: tail\n\n"
      bytes = body.to_slice
      expected = Gori::Sse.events(bytes).size
      expected.should eq(4)
      (0..bytes.size).each do |cut|
        c = Gori::Sse::Counter.new
        c.feed(bytes[0, cut], Int32::MAX)
        c.feed(bytes[cut..], Int32::MAX)
        c.count.should eq(expected)
      end
    end

    it "says where the limit-th event ended, so the rest is left unread" do
      bytes = "data: 1\n\ndata: 2\r\n\r\ndata: 3\n\n".to_slice
      c = Gori::Sse::Counter.new
      at = c.feed(bytes, 2).should_not be_nil
      String.new(bytes[0, at]).should eq("data: 1\n\ndata: 2\r\n\r\n")
      c.feed(Bytes.empty, 2).should be_nil
    end
  end

  # The one rendering History's EVENTS pane and the Repeater's response share (#1631).
  describe ".display_lines" do
    it "heads each event with its fields and indents its data, numbered past a dropped window" do
      events = Gori::Sse.events("id: 9\nevent: tick\nretry: 5\ndata: a\ndata: b\n\n".to_slice)
      Gori::Sse.display_lines(events, base: 4).should eq(["▸ event #5  type=tick  id=9  retry=5", "    a", "    b"])
      Gori::Sse.display_lines([] of Gori::Sse::Event).should eq(["(no events)"])
    end

    it "shows each event's arrival relative to the first, and nothing for an untimed one" do
      events = Gori::Sse.events("data: a\n\nid: 2\nevent: message\ndata: b\n\ndata: c\n\n".to_slice)
      times = [5_000_i64, 417_900_i64] # the third event has no time (a stream cut mid-event)
      Gori::Sse.display_lines(events, times: times).select(&.starts_with?("▸")).should eq([
        "▸ event #1  +0.000s", "▸ event #2  +0.412s  type=message  id=2", "▸ event #3  id=2", # the id carries over
      ])
      # A window keeps the first event as the origin, and the event numbers past it.
      lines, _ = Gori::Sse.latest_lines(events, 1, times)
      lines.first.should eq("▸ event #3  id=2")
      Gori::Sse.latest_lines(events[0, 2], 1, times)[0].first.should eq("▸ event #2  +0.412s  type=message  id=2")
    end
  end

  # When each event arrived (#1631): counted off the wire bytes, chunked or not, so the times
  # pair with `.events` by index.
  describe Gori::Sse::Arrivals do
    it "times each event the read that ends it, through chunk framing" do
      t0 = Time.instant
      a = Gori::Sse::Arrivals.new(chunked: true, started: t0)
      a.feed("b\r\ndata: one\n\n\r\n".to_slice, t0 + 10.milliseconds)
      a.feed("5\r\ndata:\r\n".to_slice, t0 + 20.milliseconds) # a chunk split mid-event
      a.feed("6\r\n two\n\n\r\n".to_slice, t0 + 30.milliseconds)
      a.times.should eq([10_000_i64, 30_000_i64])
      Gori::Sse.events("data: one\n\ndata: two\n\n".to_slice).size.should eq(a.times.size)
    end

    it "is not made for a stream the head leaves compressed, at any layer" do
      head = ->(fields : String) { "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n#{fields}\r\n".to_slice }
      Gori::Sse::Arrivals.for(head.call(""), false).should_not be_nil
      Gori::Sse::Arrivals.for(head.call("Transfer-Encoding: chunked\r\n"), true).should_not be_nil
      Gori::Sse::Arrivals.for(head.call("Content-Encoding: identity\r\n"), false).should_not be_nil
      Gori::Sse::Arrivals.for(head.call("Content-Encoding: gzip\r\n"), false).should be_nil
      # A coding under the final `chunked` is still a layer on the body.
      Gori::Sse::Arrivals.for(head.call("Transfer-Encoding: gzip, chunked\r\n"), true).should be_nil
      # Duplicated Content-Encoding: the first field is a layer even when the last says identity.
      Gori::Sse::Arrivals.for(head.call("Content-Encoding: gzip\r\nContent-Encoding: identity\r\n"), false).should be_nil
    end

    it "packs to eight bytes per time and back" do
      packed = Gori::Sse::Arrivals.pack([1_i64, 2_i64, 300_000_i64], from: 1)
      packed.size.should eq(16)
      Gori::Sse::Arrivals.unpack(packed).should eq([2_i64, 300_000_i64])
    end
  end
end
