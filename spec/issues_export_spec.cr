require "./spec_helper"
require "compress/gzip"
require "json"
require "../src/gori/issues_export"

private def gzip(data : String) : Bytes
  io = IO::Memory.new
  Compress::Gzip::Writer.open(io) { |w| w.print(data) }
  io.to_slice
end

private def with_store(&)
  path = File.tempname("gori-fexport", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# Returns the markdown with every fenced code block removed, so anything left is
# "live" Markdown that a renderer would interpret structurally.
private def strip_fences(md : String) : String
  out = [] of String
  fence : String? = nil
  md.each_line do |line|
    stripped = line.strip
    if f = fence
      fence = nil if stripped == f # closing fence (bare backticks)
      next
    end
    if stripped.starts_with?("```")
      fence = stripped.gsub(/[^`]/, "") # the run of backticks that must close it
      next
    end
    out << line
  end
  out.join("\n")
end

describe Gori::Issues::Export do
  describe ".one_line" do
    it "collapses control characters so a value stays on one line" do
      Gori::Issues::Export.one_line("pwn\n## FAKE HEADING").should eq("pwn ## FAKE HEADING")
      Gori::Issues::Export.one_line("a\r\n\tb").should eq("a b")
      Gori::Issues::Export.one_line("  clean  ").should eq("clean")
    end

    it "does not raise on invalid UTF-8 (a captured target/host can carry a raw byte)" do
      # The PCRE `gsub` inside one_line raises ArgumentError on invalid UTF-8; without the
      # `.scrub` this crashed `gori run issues --format markdown/text`. Byte 0x80 → U+FFFD.
      out = Gori::Issues::Export.one_line(String.new(Bytes[0x61, 0x80, 0x62]))
      out.should_not be_empty
      out.valid_encoding?.should be_true
    end
  end

  describe ".scrub_only" do
    it "fixes invalid UTF-8 but leaves newlines/control characters untouched" do
      # notes is multi-line by design — the encoding-safety half of one_line, without its
      # newline-collapsing half, since collapsing would mangle a legitimate multi-line note.
      scrubbed = Gori::Issues::Export.scrub_only(String.new(Bytes[0x6c, 0x31, 0xff, 0x0a, 0x6c, 0x32])) # "l1\xFF\nl2"
      scrubbed.valid_encoding?.should be_true
      scrubbed.should eq("l1�\nl2")
      scrubbed.lines.size.should eq(2) # the newline survived
    end
  end

  describe ".markdown" do
    it "keeps an attacker-controlled body (``` + headings) inside its code fence" do
      with_store do |store|
        id = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
          method: "POST", target: "/", http_version: "HTTP/1.1",
          head: "POST / HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil))
        # Body tries to break out of the ```http fence and inject a heading.
        evil = "```\n## INJECTED HEADING\n```\nmore".to_slice
        store.update_response(Gori::Store::CapturedResponse.new(
          flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice,
          body: evil, reason: "OK", content_type: "text/plain", duration_us: 1_i64))
        store.insert_issue("pwn\n## FAKE TITLE HEADING", Gori::Store::Severity::High, "h.test", id)

        md = Gori::Issues::Export.markdown(store.issues, store, "proj")

        # Body must be fenced with >3 backticks so its own ``` lines can't close it.
        md.should contain("````http")
        # With fences removed, no injected heading survives as live Markdown.
        live = strip_fences(md)
        live.should_not contain("INJECTED HEADING")
        # The newline in the title is collapsed — no fake "## FAKE TITLE HEADING" heading.
        live.lines.any? { |l| l.starts_with?("## FAKE TITLE HEADING") }.should be_false
        live.should contain("## [high] pwn ## FAKE TITLE HEADING") # one real heading line
      end
    end

    it "does not drop a valid-UTF-8 body that truncation splits mid-codepoint" do
      with_store do |store|
        id = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
          method: "GET", target: "/", http_version: "HTTP/1.1",
          head: "GET / HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil))
        cap = Gori::Issues::Export::EVIDENCE_CAP
        # Pad so a 3-byte char straddles the cap boundary: body[0, cap] ends mid-codepoint,
        # which used to make the slice's valid_encoding? false → whole body dropped as binary.
        big = ("a" * (cap - 1)) + "한" # 65535 ASCII + a 3-byte UTF-8 char → the cut splits it
        store.update_response(Gori::Store::CapturedResponse.new(
          flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice,
          body: big.to_slice, reason: "OK", content_type: "text/plain", duration_us: 1_i64))
        store.insert_issue("big utf8 body", Gori::Store::Severity::High, "h.test", id)

        md = Gori::Issues::Export.markdown(store.issues, store, "proj")
        md.should_not contain("binary body omitted") # the valid text must NOT be dropped
        md.should contain("body truncated")          # it's shown (truncated), not omitted
      end
    end

    it "still shows the readable prefix when an invalid byte is deeper than the cap" do
      with_store do |store|
        id = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
          method: "GET", target: "/", http_version: "HTTP/1.1",
          head: "GET / HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil))
        cap = Gori::Issues::Export::EVIDENCE_CAP
        # Valid ASCII through the cap, then a stray 0xFF byte DEEPER than the cap. The slice
        # (first `cap` bytes) is valid text, so the readable prefix must still be shown —
        # checking the whole body would wrongly call it binary.
        body = ("a" * cap).to_slice + Bytes[0xFF_u8] + ("bbbbb").to_slice
        store.update_response(Gori::Store::CapturedResponse.new(
          flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice,
          body: body, reason: "OK", content_type: "text/plain", duration_us: 1_i64))
        store.insert_issue("deep invalid byte", Gori::Store::Severity::High, "h.test", id)

        md = Gori::Issues::Export.markdown(store.issues, store, "proj")
        md.should_not contain("binary body omitted")
        md.should contain("body truncated")
      end
    end

    it "decodes a gzip Content-Encoding body instead of dropping it as binary" do
      with_store do |store|
        id = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
          method: "GET", target: "/", http_version: "HTTP/1.1",
          head: "GET / HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil))
        store.update_response(Gori::Store::CapturedResponse.new(
          flow_id: id, status: 200,
          head: "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\n".to_slice,
          body: gzip("gzip-body-marker-XYZ123"), reason: "OK", content_type: "application/json", duration_us: 1_i64))
        store.insert_issue("gzip evidence", Gori::Store::Severity::Low, "h.test", id)

        md = Gori::Issues::Export.markdown(store.issues, store, "proj")
        md.should contain("gzip-body-marker-XYZ123")
        md.should_not contain("binary body omitted")
      end
    end

    it "de-chunks a Transfer-Encoding: chunked body instead of embedding wire framing" do
      with_store do |store|
        id = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
          method: "GET", target: "/", http_version: "HTTP/1.1",
          head: "GET / HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil))
        # "5\r\nhello\r\n0\r\n\r\n" — a single 5-byte chunk, then the terminator.
        chunked = "5\r\nhello\r\n0\r\n\r\n".to_slice
        store.update_response(Gori::Store::CapturedResponse.new(
          flow_id: id, status: 200,
          head: "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".to_slice,
          body: chunked, reason: "OK", content_type: "text/plain", duration_us: 1_i64))
        store.insert_issue("chunked evidence", Gori::Store::Severity::Low, "h.test", id)

        md = Gori::Issues::Export.markdown(store.issues, store, "proj")
        md.should contain("\nhello\n") # the decoded body, on its own line inside the fence
        md.should_not contain("5\r\nhello")
        md.should_not contain("0\r\n\r\n")
      end
    end

    it "collapses the host field so a fence/newline can't open a runaway block" do
      with_store do |store|
        store.insert_issue("clean title", Gori::Store::Severity::Low,
          "evil.test\n```\n## INJECTED VIA HOST", nil)
        md = Gori::Issues::Export.markdown(store.issues, store, "proj")
        # host collapses to one line: the ``` is inline (not its own fence line) and
        # the "## INJECTED" never becomes a heading.
        md.lines.count { |l| l.strip == "```" }.should eq(0)
        md.lines.any? { |l| l.starts_with?("## INJECTED") }.should be_false
        md.should contain("- **Host:** evil.test ``` ## INJECTED VIA HOST")
      end
    end

    it "does not raise on a multi-line notes field with an invalid UTF-8 byte, and keeps its newlines" do
      # Bug: title/host were routed through one_line (which scrubs), but the notes line
      # (`io << f.notes` directly) was not — the ONE field markdown's own .scrub convention
      # missed. notes is multi-line by design, so it needs scrub_only, not one_line.
      with_store do |store|
        id = store.insert_issue("clean title", Gori::Store::Severity::Low, "clean.host", nil)
        store.update_issue(id, notes: String.new(Bytes[0x6c, 0x31, 0xff, 0x0a, 0x6c, 0x32])) # "l1\xFF\nl2"

        md = Gori::Issues::Export.markdown(store.issues, store, "proj")
        md.valid_encoding?.should be_true
        md.should contain("l1�\nl2") # newline preserved, invalid byte scrubbed to U+FFFD
      end
    end
  end

  describe ".json" do
    it "does not raise and stays valid UTF-8 when title/host/notes carry a raw invalid byte" do
      # Unlike .markdown's one_line() convention, .json wrote these fields straight into
      # JSON::Builder, which performs NO UTF-8 validation — an invalid byte (e.g. a captured
      # h2 :authority) passed straight through to `gori run issues --format json`.
      with_store do |store|
        id = store.insert_issue(String.new(Bytes[0x62, 0x61, 0x64, 0xff, 0x74]), # "bad\xFFt"
          Gori::Store::Severity::High, String.new(Bytes[0x68, 0xff, 0x6f]),      # "h\xFFo"
          nil        )
        store.update_issue(id, notes: String.new(Bytes[0x6e, 0x31, 0xff, 0x0a, 0x6e, 0x32])) # "n1\xFF\nn2"

        json_out = Gori::Issues::Export.json(store.issues, store)
        json_out.valid_encoding?.should be_true
        parsed = JSON.parse(json_out) # would raise on malformed JSON; also proves it's parseable
        issue = parsed.as_a.first
        issue["title"].as_s.valid_encoding?.should be_true
        issue["host"].as_s.valid_encoding?.should be_true
        issue["notes"].as_s.valid_encoding?.should be_true
        issue["notes"].as_s.lines.size.should eq(2) # notes keeps its newline (scrub_only, not one_line)
      end
    end

    it "emits null for a nil host, not the string 'null'" do
      with_store do |store|
        store.insert_issue("t", Gori::Store::Severity::Info, nil, nil)
        parsed = JSON.parse(Gori::Issues::Export.json(store.issues, store))
        parsed.as_a.first["host"].raw.should be_nil
      end
    end
  end
end
