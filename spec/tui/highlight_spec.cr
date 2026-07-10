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

  # The body tokenizers were rewritten from `raw.chars` + `.join` to a byte-scan. These
  # reference impls are the ORIGINAL char-based tokenizers, kept here to fuzz-verify the byte
  # version is span-for-span identical (text + colour) across ASCII + multibyte inputs.
  describe "body tokenizer byte-scan equivalence" do
    ref_json = ->(raw : String) do
      spans = [] of Highlight::Span
      chars = raw.chars
      n = chars.size
      i = 0
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

    ref_markup = ->(raw : String) do
      spans = [] of Highlight::Span
      chars = raw.chars
      n = chars.size
      i = 0
      while i < n
        if chars[i] == '<'
          gt = i + 1
          while gt < n && chars[gt] != '>'
            gt += 1
          end
          closed = gt < n
          j = i + 1
          j += 1 if j < n && chars[j] == '/'
          spans << Highlight::Span.new(chars[i...j].join, Theme.muted)
          name = j
          while name < gt && (chars[name].ascii_letter? || chars[name].ascii_number? ||
                chars[name] == '-' || chars[name] == '_' || chars[name] == ':')
            name += 1
          end
          spans << Highlight::Span.new(chars[j...name].join, Theme.syn_header) if name > j
          spans << Highlight::Span.new(chars[name...gt].join, Theme.text) if name < gt
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
    pool = %w(" \\ { } [ ] : , & = < > / - _ + . e E a Z 0 9 x   가 é 🚀 t r u e n l s f) + ["\t"]

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
        %("trailing backslash\\),      # overshoot case
        %(<unclosed tag 가),           # no '>'
        "",                            # empty
        "{}[],:",                      # all structural
        "가나다라",                     # pure multibyte, no ASCII
      ]
      cases.each do |raw|
        Highlight.body_styled(raw, :json).should eq(ref_json.call(raw))
        Highlight.body_styled(raw, :form).should eq(ref_form.call(raw))
        Highlight.body_styled(raw, :html).should eq(ref_markup.call(raw))
      end
    end
  end
end
