require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# Build the styled body line for a body of the given content-type. The fixture
# is a 4-line message (start line, one header, blank separator, body), so the
# body is always the last styled line.
private def body_spans(content_type : String, body : String, request = true) : Highlight::Line
  src = [request ? "POST /x HTTP/1.1" : "HTTP/1.1 200 OK", "Content-Type: #{content_type}", "", body]
  Highlight.from_lines(src, request).last
end

private def has_span?(line : Highlight::Line, text : String, fg : Gori::Tui::Color) : Bool
  line.any? { |s| s.text == text && s.fg == fg }
end

private def render(line : Highlight::Line, w = 80) : MemoryBackend
  backend = MemoryBackend.new(w, 1)
  Highlight.draw(Screen.new(backend), 0, 0, line, width: w)
  backend
end

describe Gori::Tui::Highlight do
  # The cardinal invariant: highlighting is a pure colour overlay. It must never
  # add, drop, reorder, or duplicate a character, and the line count must match
  # the plain split exactly (so scroll bounds + editor cursor stay aligned).
  describe "partition exactness (no character is ever lost)" do
    it "from_lines is strictly 1:1 and reconstructs every line verbatim" do
      src = [
        "POST /api?q=1 HTTP/1.1",
        "Host: h.test",
        "Content-Type: application/json",
        "Accept: */*",
        "",
        %({"key": "value", "n": -12.5e3, "ok": true, "z": null, "a": [1, 2]}),
        "trailing body line",
      ]
      lines = Highlight.from_lines(src, request: true)
      lines.size.should eq(src.size)
      lines.each_with_index { |l, i| l.map(&.text).join.should eq(src[i]) }
    end

    it "survives adversarial body lines without dropping characters" do
      [
        %({"a": "he said \\"hi\\"", "b": 1}), # escaped quotes
        %({"a": "unterminated),               # unterminated string
        %({}),                                # empty object
        "   {  \"x\"  :  42  }   ",           # odd whitespace
        "k1=v1&k2=&=v3&k4",                   # ragged form
        %(<a href="x" data-n='1'>t</a><br/>), # markup
        "<unclosed attr=",                    # unterminated tag
        "plain unstructured text — 안녕 © ∑",   # unicode + non-ascii
        "",                                   # empty line
      ].each do |body|
        src = ["POST /x HTTP/1.1", "Content-Type: application/json", "", body]
        Highlight.from_lines(src, request: true).last.map(&.text).join.should eq(body)
      end
    end

    it "message() reproduces the old `head + [\"\"] + body` plain layout 1:1" do
      head = "GET /a HTTP/1.1\r\nContent-Type: application/json\r\n\r\n".to_slice
      body = %({"x":1}).to_slice
      head_lines = String.new(head).split('\n').map(&.rstrip('\r'))
      expected = head_lines + [""] + [String.new(body)]

      lines = Highlight.message(head, body, request: true)
      lines.map { |l| l.map(&.text).join }.should eq(expected)
    end

    it "message() with no body matches the head-only plain layout" do
      head = "GET /a HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice
      expected = String.new(head).split('\n').map(&.rstrip('\r'))
      lines = Highlight.message(head, nil, request: true)
      lines.map { |l| l.map(&.text).join }.should eq(expected)
      # an empty body slice is treated as no body (no spurious separator line)
      Highlight.message(head, Bytes.new(0), request: true).size.should eq(expected.size)
    end
  end

  describe "HTTP structure" do
    it "colours the request line: verb, bright target, muted version" do
      line = Highlight.from_lines(["GET /path HTTP/1.1"], request: true).first
      b = render(line)
      b.fg_at(0, 0).should eq(Theme.method_color("GET")) # G
      b.fg_at(3, 0).should eq(Theme.muted)               # space
      b.fg_at(4, 0).should eq(Theme.text_bright)         # /path
      b.fg_at(10, 0).should eq(Theme.muted)              # HTTP/1.1
    end

    it "colours the status code by class" do
      render(Highlight.from_lines(["HTTP/1.1 200 OK"], false).first).fg_at(9, 0).should eq(Theme.green)
      render(Highlight.from_lines(["HTTP/1.1 404 NF"], false).first).fg_at(9, 0).should eq(Theme.yellow)
      render(Highlight.from_lines(["HTTP/1.1 503 NA"], false).first).fg_at(9, 0).should eq(Theme.red)
      # version stays muted
      render(Highlight.from_lines(["HTTP/1.1 200 OK"], false).first).fg_at(0, 0).should eq(Theme.muted)
    end

    it "colours header name / colon / value distinctly" do
      line = Highlight.from_lines(["GET / HTTP/1.1", "Host: h.test"], request: true)[1]
      has_span?(line, "Host", Theme.syn_header).should be_true
      has_span?(line, ":", Theme.muted).should be_true
      has_span?(line, " h.test", Theme.text).should be_true
    end

    it "keeps the first colon as the header separator (values may contain ':')" do
      line = Highlight.from_lines(["GET / HTTP/1.1", "Date: Mon 01:02:03"], request: true)[1]
      has_span?(line, "Date", Theme.syn_header).should be_true
      has_span?(line, " Mon 01:02:03", Theme.text).should be_true
    end
  end

  describe "JSON bodies" do
    it "accents keys, strings, numbers, and literals separately" do
      spans = body_spans("application/json", %({"a": "x", "n": -12.5, "ok": true, "z": null}))
      has_span?(spans, %("a"), Theme.syn_header).should be_true # key
      has_span?(spans, %("x"), Theme.syn_string).should be_true # value string
      has_span?(spans, "-12.5", Theme.syn_number).should be_true
      has_span?(spans, "true", Theme.syn_literal).should be_true
      has_span?(spans, "null", Theme.syn_literal).should be_true
      has_span?(spans, "{", Theme.muted).should be_true
    end

    it "matches +json suffix content types" do
      spans = body_spans("application/vnd.api+json", %({"k": 1}))
      has_span?(spans, %("k"), Theme.syn_header).should be_true
      has_span?(spans, "1", Theme.syn_number).should be_true
    end
  end

  describe "form-encoded bodies" do
    it "accents keys, mutes separators, leaves values as body text" do
      spans = body_spans("application/x-www-form-urlencoded", "user=admin&pw=s3cret")
      has_span?(spans, "user", Theme.syn_header).should be_true
      has_span?(spans, "admin", Theme.text).should be_true
      has_span?(spans, "&", Theme.muted).should be_true
      has_span?(spans, "=", Theme.muted).should be_true
    end
  end

  describe "markup bodies" do
    it "accents tag names and mutes the delimiters" do
      spans = body_spans("text/html", %(<div class="x">hi</div>), request: false)
      has_span?(spans, "div", Theme.syn_header).should be_true
      has_span?(spans, "<", Theme.muted).should be_true
      has_span?(spans, ">", Theme.muted).should be_true
    end
  end

  describe ".draw" do
    it "truncates with a trailing ellipsis exactly like Screen#fit" do
      b = MemoryBackend.new(20, 1)
      Highlight.draw(Screen.new(b), 0, 0, [Highlight::Span.new("abcdefghij", Theme.text)], width: 5)
      b.row(0)[0, 5].should eq("abcd…")
    end

    it "preserves per-span colour across a multi-span line" do
      line = [
        Highlight::Span.new("GET", Theme.green),
        Highlight::Span.new(" ", Theme.muted),
        Highlight::Span.new("/x", Theme.text_bright),
      ]
      b = render(line)
      b.fg_at(0, 0).should eq(Theme.green)
      b.fg_at(3, 0).should eq(Theme.muted)
      b.fg_at(4, 0).should eq(Theme.text_bright)
      b.row(0).rstrip.should eq("GET /x")
    end

    it "matches Screen#text glyph-for-glyph (and in the returned x) at every width" do
      # A single-span styled line must render byte-identically to the plain
      # path, so toggling highlighting never moves a cell — including the
      # width==1 corner where Screen#fit keeps the first glyph, not the ellipsis.
      {"hello", "ab", "x", "안녕하세요"}.each do |str|
        (0..7).each do |w|
          plain = MemoryBackend.new(10, 1)
          px = Screen.new(plain).text(0, 0, str, Theme.text, width: w)
          hl = MemoryBackend.new(10, 1)
          hx = Highlight.draw(Screen.new(hl), 0, 0, [Highlight::Span.new(str, Theme.text)], width: w)
          hl.row(0).should eq(plain.row(0)) # same glyphs (str=#{str.inspect}, w=#{w})
          hx.should eq(px)                  # same advance
        end
      end
    end

    it "shows the first glyph (not an ellipsis) in a 1-wide slot, like Screen#fit" do
      b = MemoryBackend.new(5, 1)
      Highlight.draw(Screen.new(b), 0, 0, [Highlight::Span.new("hello", Theme.text)], width: 1)
      b.row(0)[0, 1].should eq("h")
    end

    it "draws nothing for a zero/negative width" do
      b = MemoryBackend.new(10, 1)
      Highlight.draw(Screen.new(b), 0, 0, [Highlight::Span.new("hi", Theme.text)], width: 0)
      b.row(0).strip.should eq("")
    end
  end
end
