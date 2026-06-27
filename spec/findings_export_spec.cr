require "./spec_helper"
require "../src/gori/findings_export"

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

describe Gori::Findings::Export do
  describe ".one_line" do
    it "collapses control characters so a value stays on one line" do
      Gori::Findings::Export.one_line("pwn\n## FAKE HEADING").should eq("pwn ## FAKE HEADING")
      Gori::Findings::Export.one_line("a\r\n\tb").should eq("a b")
      Gori::Findings::Export.one_line("  clean  ").should eq("clean")
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
        store.insert_finding("pwn\n## FAKE TITLE HEADING", Gori::Store::Severity::High, "h.test", id)

        md = Gori::Findings::Export.markdown(store.findings, store, "proj")

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

    it "collapses the host field so a fence/newline can't open a runaway block" do
      with_store do |store|
        store.insert_finding("clean title", Gori::Store::Severity::Low,
          "evil.test\n```\n## INJECTED VIA HOST", nil)
        md = Gori::Findings::Export.markdown(store.findings, store, "proj")
        # host collapses to one line: the ``` is inline (not its own fence line) and
        # the "## INJECTED" never becomes a heading.
        md.lines.count { |l| l.strip == "```" }.should eq(0)
        md.lines.any? { |l| l.starts_with?("## INJECTED") }.should be_false
        md.should contain("- **Host:** evil.test ``` ## INJECTED VIA HOST")
      end
    end
  end
end
