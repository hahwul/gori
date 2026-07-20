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
  it "highlights known and unknown env tokens in request lines" do
    Gori::Settings.env_vars = [{"HOST", "api.test"}]
    Gori::Settings.project_env_vars = [] of {String, String}
    src = ["GET http://$HOST/path HTTP/1.1", "X: $MISSING"]
    lines = Highlight.from_lines(src, request: true)
    lines[0].map(&.text).join.should eq(src[0])
    has_span?(lines[0], "$HOST", Theme.env_known).should be_true
    has_span?(lines[1], "$MISSING", Theme.env_unknown).should be_true
  ensure
    Gori::Settings.env_vars = [] of {String, String}
  end
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

    it "message() separates head from body with exactly one blank line" do
      head = "GET /a HTTP/1.1\r\nContent-Type: application/json\r\n\r\n".to_slice
      body = %({"x":1}).to_slice
      # The CRLFCRLF terminator must not leak extra blank lines: one separator only.
      expected = ["GET /a HTTP/1.1", "Content-Type: application/json", "", String.new(body)]

      lines = Highlight.message(head, body, request: true)
      lines.map { |l| l.map(&.text).join }.should eq(expected)
    end

    it "message() with no body ends on the last header, not blank lines" do
      head = "GET /a HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice
      expected = ["GET /a HTTP/1.1", "Host: h.test"]
      lines = Highlight.message(head, nil, request: true)
      lines.map { |l| l.map(&.text).join }.should eq(expected)
      # an empty body slice is treated as no body (no spurious separator line)
      Highlight.message(head, Bytes.new(0), request: true).size.should eq(expected.size)
    end

    it "message_windowed matches message() line-for-line including lazy body" do
      head = "GET /a HTTP/1.1\r\nContent-Type: text/plain\r\n\r\n".to_slice
      body = "line-one\r\nline-two\r\nline-three".to_slice
      full = Highlight.message(head, body, request: true).map { |l| l.map(&.text).join }
      win = Highlight.message_windowed(head, body, request: true)
      win.total.should eq(full.size)
      (0...win.total).each { |i| win.line_at(i).map(&.text).join.should eq(full[i]) }
    end

    it "BodyLines matches split('\\n').map rstrip CR without eager full materialisation" do
      raw = "a\r\nb\nc\r\n".to_slice
      expected = String.new(raw).scrub.split('\n').map(&.rstrip('\r'))
      bl = Highlight::BodyLines.from_bytes(raw)
      bl.size.should eq(expected.size)
      expected.each_with_index { |exp, i| bl[i].should eq(exp) }
      # empty / no-newline / trailing-newline edge cases
      Highlight::BodyLines.from_bytes(Bytes.empty).size.should eq(0)
      Highlight::BodyLines.from_bytes("solo".to_slice).size.should eq(1)
      Highlight::BodyLines.from_bytes("solo".to_slice)[0].should eq("solo")
      Highlight::BodyLines.from_bytes("\n".to_slice).size.should eq(2)
      Highlight::BodyLines.from_bytes("\n".to_slice)[0].should eq("")
      Highlight::BodyLines.from_bytes("\n".to_slice)[1].should eq("")
    end

    it "message_windowed opens a multi-MiB many-line body without hang and styles only on demand" do
      # Near capture-cap scale: ~1.5 MiB of short lines (~100k lines). Open must finish
      # quickly; line_at for a visible window must not re-style the whole body.
      line = "x" * 14 + "\n"
      n_lines = 100_000
      io = IO::Memory.new(line.bytesize * n_lines)
      n_lines.times { io << line }
      body = io.to_slice
      # Trailing LF ⇒ split produces n_lines content lines + one empty trailer (matches to_lines).
      expected_lines = String.new(body).split('\n').map(&.rstrip('\r'))
      head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice

      t0 = Time.instant
      win = Highlight.message_windowed(head, body, request: false)
      open_ms = (Time.instant - t0).total_milliseconds
      win.body.size.should eq(expected_lines.size)
      # Open only builds the LF index + styles the small head — not 100k body strings.
      open_ms.should be < 2_000.0

      # Steady "scroll": style a 40-line window twice (like two frames) — work is
      # proportional to the window, not the full body.
      t1 = Time.instant
      2.times do
        40.times { |i| win.line_at(win.head.size + 50_000 + i) }
      end
      scroll_ms = (Time.instant - t1).total_milliseconds
      scroll_ms.should be < 500.0
      # Spot-check content of a mid-body line
      win.line_at(win.head.size + 10).map(&.text).join.should eq("x" * 14)
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

    it "tokenises attribute names (syn_number) and quoted values (syn_string)" do
      spans = body_spans("text/html", %(<a href="/x" data-id='5'>), request: false)
      spans.map(&.text).join.should eq(%(<a href="/x" data-id='5'>))
      has_span?(spans, "href", Theme.syn_number).should be_true
      has_span?(spans, %("/x"), Theme.syn_string).should be_true
      has_span?(spans, "data-id", Theme.syn_number).should be_true
    end

    it "colours comments and declarations" do
      c = body_spans("text/html", "<!-- hi -->", request: false)
      has_span?(c, "<!-- hi -->", Theme.syn_comment).should be_true
      d = body_spans("text/html", "<!DOCTYPE html>", request: false)
      has_span?(d, "DOCTYPE", Theme.syn_keyword).should be_true
    end
  end

  describe "request-line query string" do
    it "breaks path / ? / query params" do
      line = Highlight.from_lines(["GET /api/users?id=42&sort=name HTTP/1.1"], request: true).first
      line.map(&.text).join.should eq("GET /api/users?id=42&sort=name HTTP/1.1")
      has_span?(line, "/api/users", Theme.text_bright).should be_true
      has_span?(line, "?", Theme.muted).should be_true
      has_span?(line, "id", Theme.syn_header).should be_true
      has_span?(line, "&", Theme.muted).should be_true
    end

    it "leaves a query-less target as a single bright span" do
      line = Highlight.from_lines(["GET /plain/path HTTP/1.1"], request: true).first
      has_span?(line, "/plain/path", Theme.text_bright).should be_true
    end
  end

  describe "header values" do
    it "tokenises Set-Cookie name/value and attributes" do
      line = Highlight.from_lines(["HTTP/1.1 200 OK", "Set-Cookie: sid=abc; Path=/; HttpOnly"], false)[1]
      line.map(&.text).join.should eq("Set-Cookie: sid=abc; Path=/; HttpOnly")
      has_span?(line, " sid", Theme.syn_header).should be_true
      has_span?(line, "abc", Theme.text).should be_true
      has_span?(line, " Path", Theme.syn_keyword).should be_true
      has_span?(line, " HttpOnly", Theme.syn_keyword).should be_true
    end

    it "colours the Authorization scheme distinctly from the credential" do
      line = Highlight.from_lines(["GET / HTTP/1.1", "Authorization: Bearer eyJhbGc"], request: true)[1]
      line.map(&.text).join.should eq("Authorization: Bearer eyJhbGc")
      has_span?(line, "Bearer", Theme.syn_keyword).should be_true
      has_span?(line, " eyJhbGc", Theme.syn_string).should be_true
    end

    it "keeps a structureless value as one plain span (Host / Date)" do
      line = Highlight.from_lines(["GET / HTTP/1.1", "Host: h.test"], request: true)[1]
      has_span?(line, " h.test", Theme.text).should be_true
      dline = Highlight.from_lines(["GET / HTTP/1.1", "Date: Mon 01:02:03"], request: true)[1]
      has_span?(dline, " Mon 01:02:03", Theme.text).should be_true
    end

    it "accents param keys in a generic value" do
      line = Highlight.from_lines(["HTTP/1.1 200 OK", "Content-Type: text/html; charset=utf-8"], false)[1]
      has_span?(line, " charset", Theme.syn_header).should be_true
      has_span?(line, "=", Theme.muted).should be_true
    end
  end

  describe "JSONC comments" do
    it "styles a leading // line as a comment (JWT markers)" do
      has_span?(body_spans("application/json", "// header"), "// header", Theme.syn_comment).should be_true
      has_span?(body_spans("application/json", "  // payload"), "  // payload", Theme.syn_comment).should be_true
      # a real JSON line is unaffected
      has_span?(body_spans("application/json", %({"a": 1})), %("a"), Theme.syn_header).should be_true
    end
  end

  describe "GraphQL bodies" do
    it "colours keywords, fields, and variables" do
      spans = Highlight.body_styled("query Q($id: ID!) { user(id: $id) { name } }", :graphql)
      spans.map(&.text).join.should eq("query Q($id: ID!) { user(id: $id) { name } }")
      has_span?(spans, "query", Theme.syn_keyword).should be_true
      has_span?(spans, "$id", Theme.syn_literal).should be_true
      has_span?(spans, "user", Theme.syn_header).should be_true
    end

    it "styles # comments" do
      has_span?(Highlight.body_styled("# operationName: Q", :graphql), "# operationName: Q", Theme.syn_comment).should be_true
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

    it "matches Screen#text across a MIXED ascii+wide multi-span line at every width" do
      # draw's ASCII fast path (width-1 char draw) and its grapheme path must compose:
      # width accumulates continuously across a span boundary where the branch flips, so a
      # line split into an ASCII prefix span + a wide (CJK) suffix span renders and advances
      # exactly like Screen#text over the concatenated string — truncation/ellipsis included.
      full = "id=42 값" # "id=42 " is printable ASCII (fast path), "값" is width-2 (grapheme path)
      {["id=42 ", "값"], ["id", "=42 값"], ["id=42", " 값"]}.each do |parts|
        line = parts.map { |p| Highlight::Span.new(p, Theme.text) }
        (0..10).each do |w|
          plain = MemoryBackend.new(12, 1)
          px = Screen.new(plain).text(0, 0, full, Theme.text, width: w)
          hl = MemoryBackend.new(12, 1)
          hx = Highlight.draw(Screen.new(hl), 0, 0, line, width: w)
          hl.row(0).should eq(plain.row(0)) # same glyphs (parts=#{parts.inspect}, w=#{w})
          hx.should eq(px)                  # same advance
        end
      end
    end

    it "draws nothing for a zero/negative width" do
      b = MemoryBackend.new(10, 1)
      Highlight.draw(Screen.new(b), 0, 0, [Highlight::Span.new("hi", Theme.text)], width: 0)
      b.row(0).strip.should eq("")
    end

    it "keeps a tab as one space cell so it matches Screen#text (issue #278)" do
      # A span with an embedded tab is NOT printable_ascii?, so draw takes the grapheme
      # path. That path must floor width-0 controls to 1 and substitute a space — same
      # as Screen#text's Char path — or the styled editor collapses "x,\ty" to "x,y"
      # while the caret still steps across the missing cell.
      {"x,\ty", "a\tb", "{\"a\":1,\t\"b\":2}"}.each do |str|
        plain = MemoryBackend.new(24, 1)
        px = Screen.new(plain).text(0, 0, str, Theme.text)
        hl = MemoryBackend.new(24, 1)
        hx = Highlight.draw(Screen.new(hl), 0, 0, [Highlight::Span.new(str, Theme.text)], width: 24)
        hl.row(0).should eq(plain.row(0)) # same glyphs (str=#{str.inspect})
        hx.should eq(px)                  # same advance
        # Explicit layout: tab → space, neighbours unmoved
        expected = str.gsub('\t', ' ')
        hl.row(0).rstrip.should eq(expected)
      end
    end

    it "line_width counts a tab as one column" do
      line = [Highlight::Span.new("a\tb", Theme.text)]
      Highlight.line_width(line).should eq(3)
      Highlight.line_width_upto(line, 10).should eq(3)
    end
  end

  # Grapheme-cluster alignment. `column_width` floors every CODEPOINT to ≥1, so a ZWJ /
  # skin-tone cluster measured that way is 3-9 columns wider than the single glyph `draw`
  # paints. Measuring the h-scroll clamp and the slice per CLUSTER (Screen.draw_width) is
  # what keeps them lined up with the cells — and stops the slicer cutting a cluster in half.
  describe "grapheme clusters (draw alignment)" do
    zwj = "\u{1F468}\u{200D}\u{1F4BB}"                                      # 👨‍💻 (3 cps, 2 cols)
    family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}" # 👨‍👩‍👧‍👦 (7 cps, 2 cols)

    it "line_width measures a cluster as its DRAWN columns, not its codepoint count" do
      # Under column_width these were 5 and 11, letting the h-scroll clamp run the view
      # 3 (resp. 9) columns past the end of the content.
      Highlight.line_width([Highlight::Span.new(zwj, Theme.text)]).should eq(2)
      Highlight.line_width([Highlight::Span.new(family, Theme.text)]).should eq(2)
      line = [Highlight::Span.new(zwj, Theme.text), Highlight::Span.new("abc", Theme.text)]
      Highlight.line_width(line).should eq(5)
      Highlight.line_width_upto(line, 99).should eq(5)
      Highlight.line_width_upto(line, 3).should be >= 3 # early exit still honoured
    end

    it "line_width agrees with what draw actually advances" do
      line = [Highlight::Span.new(zwj, Theme.text), Highlight::Span.new("abc", Theme.text)]
      b = MemoryBackend.new(40, 1)
      Highlight.draw(Screen.new(b), 0, 0, line, width: 40).should eq(Highlight.line_width(line))
    end

    it "slice_left never emits a partial cluster (no bare ZWJ / orphan modifier)" do
      # The bug: a per-codepoint cut could stop between 👨 and 💻 and emit the ZWJ (or the
      # tail half) as its own "glyph". A cluster must be all-or-nothing — kept whole, or
      # replaced by spaces when the cut straddles it.
      # An INTACT cluster of course still contains its ZWJ, so the assertion is on the
      # RESIDUE: delete every whole cluster from the output and nothing cluster-internal
      # (ZWJ, skin-tone modifier, either half of the pair) may be left behind.
      {zwj, family, "\u{1F44D}\u{1F3FD}"}.each do |emoji|
        line = [Highlight::Span.new(emoji + "abcdef", Theme.text)]
        (0..8).each do |col|
          sliced = Highlight.slice_left(line, col).map(&.text).join
          # Only the padding spaces and "abcdef" may remain — any leaked ZWJ, skin-tone
          # modifier or half-cluster would be non-ASCII and trip this. (col=#{col})
          sliced.gsub(emoji, "").ascii_only?.should be_true
          # And the cluster is either wholly present or wholly gone — never split.
          sliced.count(emoji[0]).should eq(sliced.includes?(emoji) ? 1 : 0)
        end
      end
    end

    it "slice_left_text never emits a partial cluster either" do
      (0..8).each do |col|
        sliced = Highlight.slice_left_text(family + "abcdef", col)
        sliced.gsub(family, "").ascii_only?.should be_true
      end
    end

    it "slice_left cuts in DRAWN columns so the remainder lines up with the cells" do
      # zwj is 2 drawn columns, so cutting 2 leaves exactly "abc" — under the old
      # per-codepoint math this needed a cut of 5 and any smaller cut leaked cluster parts.
      Highlight.slice_left([Highlight::Span.new(zwj + "abc", Theme.text)], 2)
        .map(&.text).join.should eq("abc")
      Highlight.slice_left_text(zwj + "abc", 2).should eq("abc")
      # Cutting INTO the cluster replaces it with blanks (it cannot be half-drawn).
      Highlight.slice_left_text(zwj + "abc", 1).should eq(" abc")
      # Identity below the cut, and tabs still count as their one cell.
      Highlight.slice_left_text(zwj + "abc", 0).should eq(zwj + "abc")
      Highlight.slice_left_text("a\tbc", 2).should eq("bc")
    end
  end

  # The search overlay repaints cells the base draw already painted, using screen.text
  # (grapheme-walked). Its column must therefore be grapheme-summed too, or the yellow
  # band lands right of the match and covers unrelated glyphs.
  describe "SearchHi column alignment" do
    it "highlights the match columns after a ZWJ emoji, not 3 columns right of them" do
      zwj = "\u{1F468}\u{200D}\u{1F4BB}"
      text = zwj + "needle"
      b = MemoryBackend.new(40, 1)
      screen = Screen.new(b)
      screen.text(0, 0, text, Theme.text)
      SearchHi.mark(screen, 0, 0, text, "needle", 40)
      # The emoji occupies cols 0-1, so "needle" is drawn at cols 2..7 and that is exactly
      # where the yellow band must sit. Under column_width it started at col 5.
      (2...8).each { |x| b.bg_at(x, 0).should eq(Theme.yellow) }
      b.bg_at(1, 0).should_not eq(Theme.yellow) # emoji untouched
      b.bg_at(8, 0).should_not eq(Theme.yellow) # nothing past the match
      b.row(0)[2, 6].should eq("needle")
    end

    it "still lands correctly after a tab (issue #278 case, ASCII path)" do
      text = "a\tneedle"
      b = MemoryBackend.new(40, 1)
      screen = Screen.new(b)
      screen.text(0, 0, text, Theme.text)
      SearchHi.mark(screen, 0, 0, text, "needle", 40)
      (2...8).each { |x| b.bg_at(x, 0).should eq(Theme.yellow) }
      b.bg_at(1, 0).should_not eq(Theme.yellow)
    end
  end

  # The body tokenizers were rewritten from `raw.chars` + `.join` to a byte-scan. These
  # reference impls are the ORIGINAL char-based tokenizers, kept here to fuzz-verify the byte
  # version is span-for-span identical (text + colour) across ASCII + multibyte inputs.
  describe "body tokenizer byte-scan equivalence" do
    ref_json = ->(raw : String) do
      spans = [] of Highlight::Span
      chars = raw.chars
      n = chars.size
      ws = 0
      while ws < n && chars[ws].ascii_whitespace?
        ws += 1
      end
      comment = ws + 1 < n && chars[ws] == '/' && chars[ws + 1] == '/' # JSONC line comment
      spans << Highlight::Span.new(raw, Theme.syn_comment) if comment
      i = comment ? n : 0 # a comment line skips the tokenizer loop
      while i < n
        c = chars[i]
        if c == '"'
          start = i
          i += 1
          while i < n
            if chars[i] == '\\'
              i += 2
            elsif chars[i] == '"'
              i += 1
              break
            else
              i += 1
            end
          end
          str = chars[start...i].join
          k = i
          while k < n && chars[k].ascii_whitespace?
            k += 1
          end
          key = k < n && chars[k] == ':'
          spans << Highlight::Span.new(str, key ? Theme.syn_header : Theme.syn_string)
        elsif c.ascii_number? || (c == '-' && i + 1 < n && chars[i + 1].ascii_number?)
          start = i
          i += 1
          while i < n && (chars[i].ascii_number? || "+-.eE".includes?(chars[i]))
            i += 1
          end
          spans << Highlight::Span.new(chars[start...i].join, Theme.syn_number)
        elsif c.ascii_letter?
          start = i
          i += 1
          while i < n && chars[i].ascii_letter?
            i += 1
          end
          word = chars[start...i].join
          spans << Highlight::Span.new(word, %w(true false null).includes?(word) ? Theme.syn_literal : Theme.text)
        elsif "{}[]:,".includes?(c)
          spans << Highlight::Span.new(c.to_s, Theme.muted)
          i += 1
        else
          start = i
          i += 1
          while i < n
            d = chars[i]
            break if d == '"' || d.ascii_letter? || d.ascii_number? || "{}[]:,".includes?(d) ||
                     (d == '-' && i + 1 < n && chars[i + 1].ascii_number?)
            i += 1
          end
          spans << Highlight::Span.new(chars[start...i].join, Theme.text)
        end
      end
      spans
    end

    ref_form = ->(raw : String) do
      spans = [] of Highlight::Span
      chars = raw.chars
      n = chars.size
      i = 0
      expect_key = true
      while i < n
        c = chars[i]
        if c == '&'
          spans << Highlight::Span.new("&", Theme.muted)
          i += 1
          expect_key = true
        elsif c == '='
          spans << Highlight::Span.new("=", Theme.muted)
          i += 1
          expect_key = false
        else
          start = i
          while i < n && chars[i] != '&' && chars[i] != '='
            i += 1
          end
          spans << Highlight::Span.new(chars[start...i].join, expect_key ? Theme.syn_header : Theme.text)
        end
      end
      spans
    end

    name_char = ->(c : Char) { c.ascii_letter? || c.ascii_number? || c == '-' || c == '_' || c == ':' }

    ref_attr = ->(seg : String) do
      spans = [] of Highlight::Span
      chars = seg.chars
      n = chars.size
      i = 0
      after_eq = false
      while i < n
        c = chars[i]
        if c == '"' || c == '\''
          quote = c
          start = i
          i += 1
          while i < n && chars[i] != quote
            i += 1
          end
          i += 1 if i < n
          spans << Highlight::Span.new(chars[start...i].join, Theme.syn_string)
          after_eq = false
        elsif c == '='
          spans << Highlight::Span.new("=", Theme.muted)
          i += 1
          after_eq = true
        elsif c == '/'
          spans << Highlight::Span.new("/", Theme.muted)
          i += 1
        elsif name_char.call(c)
          start = i
          i += 1
          while i < n && name_char.call(chars[i])
            i += 1
          end
          spans << Highlight::Span.new(chars[start...i].join, after_eq ? Theme.text : Theme.syn_number)
          after_eq = false
        else
          start = i
          i += 1
          while i < n
            d = chars[i]
            break if d == '"' || d == '\'' || d == '=' || d == '/' || name_char.call(d)
            i += 1
          end
          spans << Highlight::Span.new(chars[start...i].join, Theme.text)
          after_eq = false
        end
      end
      spans
    end

    ref_markup = ->(raw : String) do
      spans = [] of Highlight::Span
      chars = raw.chars
      n = chars.size
      i = 0
      while i < n
        if chars[i] == '<'
          # comment '<!-- … -->' (line-local)
          if i + 3 < n && chars[i + 1] == '!' && chars[i + 2] == '-' && chars[i + 3] == '-'
            close = nil.as(Int32?)
            k = i + 4
            while k + 2 < n
              if chars[k] == '-' && chars[k + 1] == '-' && chars[k + 2] == '>'
                close = k
                break
              end
              k += 1
            end
            stop = close ? close + 3 : n
            spans << Highlight::Span.new(chars[i...stop].join, Theme.syn_comment)
            i = stop
            next
          end
          gt = i + 1
          while gt < n && chars[gt] != '>'
            gt += 1
          end
          closed = gt < n
          j = i + 1
          decl = false
          if j < n && (chars[j] == '!' || chars[j] == '?')
            decl = true
            j += 1
          elsif j < n && chars[j] == '/'
            j += 1
          end
          spans << Highlight::Span.new(chars[i...j].join, Theme.muted)
          name = j
          while name < gt && name_char.call(chars[name])
            name += 1
          end
          spans << Highlight::Span.new(chars[j...name].join, decl ? Theme.syn_keyword : Theme.syn_header) if name > j
          if name < gt
            if decl
              spans << Highlight::Span.new(chars[name...gt].join, Theme.text)
            else
              ref_attr.call(chars[name...gt].join).each { |s| spans << s }
            end
          end
          spans << Highlight::Span.new(">", Theme.muted) if closed
          i = closed ? gt + 1 : gt
        else
          start = i
          i += 1
          while i < n && chars[i] != '<'
            i += 1
          end
          spans << Highlight::Span.new(chars[start...i].join, Theme.text)
        end
      end
      spans
    end

    # A varied byte/char pool: ASCII structural + hex + letters + multibyte (Korean, accented,
    # emoji), so tokens land next to multibyte content and near boundaries.
    pool = %w(" \\ { } [ ] : , & = < > / - _ + . e E a Z 0 9 x 가 é 🚀 t r u e n l s f) + ["\t"]

    it "matches the reference char tokenizer for :json / :form / :html over a fuzz corpus" do
      rng = Random.new(0x9051) # fixed seed → deterministic
      2000.times do
        len = rng.rand(0..40)
        raw = String.build { |io| len.times { io << pool[rng.rand(pool.size)] } }
        Highlight.body_styled(raw, :json).should eq(ref_json.call(raw))
        Highlight.body_styled(raw, :form).should eq(ref_form.call(raw))
        Highlight.body_styled(raw, :html).should eq(ref_markup.call(raw))
        # the load-bearing invariant: spans concat back to the exact line
        Highlight.body_styled(raw, :json).map(&.text).join.should eq(raw)
        Highlight.body_styled(raw, :html).map(&.text).join.should eq(raw)
        Highlight.body_styled(raw, :form).map(&.text).join.should eq(raw)
      end
    end

    it "matches on hand-picked edge cases (multibyte, trailing escape, unclosed tag)" do
      cases = [
        %({"이름": "값🚀", "n": -12.5e3, "ok": true}),
        %(a=가&b=é🚀&=x&flag),
        %(<div class="x">가나다</div><br/><b>té</b>),
        %("trailing backslash\\), # overshoot case
        %(<unclosed tag 가),       # no '>'
        "",                       # empty
        "{}[],:",                 # all structural
        "가나다라",                   # pure multibyte, no ASCII
      ]
      cases.each do |raw|
        Highlight.body_styled(raw, :json).should eq(ref_json.call(raw))
        Highlight.body_styled(raw, :form).should eq(ref_form.call(raw))
        Highlight.body_styled(raw, :html).should eq(ref_markup.call(raw))
      end
    end
  end

  describe ".conceal" do
    red = Gori::Tui::Color.from_hex("#ff0000")
    blue = Gori::Tui::Color.from_hex("#0000ff")

    it "is the identity when there are no ranges" do
      line = [Highlight::Span.new("hello", red)]
      Highlight.conceal(line, [] of {Int32, Int32}).should eq(line)
    end

    it "deletes a range from a single span, preserving styling" do
      line = [Highlight::Span.new("§data¦base64-encode§", red)]
      res = Highlight.conceal(line, [{5, 19}]) # hide ¦base64-encode, keep the closing §
      res.map(&.text).join.should eq("§data§")
      res.all? { |s| s.fg == red }.should be_true
    end

    it "deletes a range spanning multiple spans, keeping each survivor's style" do
      # "§data" (red) + "¦b64§" (blue); conceal chars [5,9) = "¦b64", keep the trailing §.
      line = [Highlight::Span.new("§data", red), Highlight::Span.new("¦b64§", blue)]
      res = Highlight.conceal(line, [{5, 9}])
      res.map(&.text).join.should eq("§data§")
      has_span?(res, "§data", red).should be_true
      has_span?(res, "§", blue).should be_true
    end

    it "keeps the concatenation equal to the source minus the deleted chars" do
      line = [Highlight::Span.new("abc", red), Highlight::Span.new("defg", blue)]
      Highlight.conceal(line, [{1, 3}, {4, 6}]).map(&.text).join.should eq("a" + "dg")
    end
  end
end
