require "../spec_helper"

# Exercises the production TermisuBackend (the double-buffered cell diff in
# src/gori/tui/screen.cr) against a recording terminal double. Guards two contracts:
#   1. Correctness: the cells the backend forwards leave termisu's buffer byte-identical
#      to eagerly forwarding EVERY drawn cell — including wide (CJK) graphemes and the
#      fill-then-draw double write, across scroll + resize.
#   2. Efficiency: an unchanged frame forwards zero cells; a partial change forwards only
#      the changed cells (never the whole screen).
# Termisu.new needs a live /dev/tty (absent in CI), so the backend is generic over the
# terminal type and driven here through a Termisu::Buffer-backed double.
module Gori::Tui
  # Minimal terminal double satisfying the backend's duck-typed `T`: records forwarded
  # cells into a real Termisu::Buffer (so cells can be inspected) and counts set_cell calls.
  private class FakeTerm
    getter buffer : Termisu::Buffer
    getter set_calls : Int32 = 0
    getter renders : Int32 = 0
    getter syncs : Int32 = 0

    def initialize(@w : Int32, @h : Int32)
      @buffer = Termisu::Buffer.new(@w, @h)
    end

    def set_cell(x : Int32, y : Int32, g : String, *, fg : Color, bg : Color, attr : Attribute) : Bool
      @set_calls += 1
      @buffer.set_cell(x, y, g, fg: fg, bg: bg, attr: attr)
    end

    def render : Nil
      @renders += 1
    end

    def sync : Nil
      @syncs += 1
    end

    def size : {Int32, Int32}
      {@w, @h}
    end

    # Mirror termisu's prepare_event, which resizes its own buffer to the Resize event's
    # dims BEFORE the app's handler (which then calls backend#resize) runs.
    def resize(w : Int32, h : Int32) : Nil
      @w, @h = w, h
      @buffer.resize(w, h)
    end

    def reset_counts : Nil
      @set_calls = 0
    end
  end

  # Eager reference: forwards every drawn cell straight to a Termisu::Buffer (the old
  # behaviour), so a test can compare the diffed buffer against the ground truth.
  private class EagerRefBackend < Backend
    getter buffer : Termisu::Buffer

    def initialize(@w : Int32, @h : Int32)
      @buffer = Termisu::Buffer.new(@w, @h)
    end

    def put(x : Int32, y : Int32, grapheme : Char | String, fg : Color, bg : Color, attr : Attribute) : Nil
      g = grapheme.is_a?(String) ? grapheme : grapheme.to_s
      @buffer.set_cell(x, y, g, fg: fg, bg: bg, attr: attr)
    end

    def size : {Int32, Int32}
      {@w, @h}
    end
  end

  def self.buffers_identical(a : Termisu::Buffer, b : Termisu::Buffer, w : Int32, h : Int32) : String?
    (0...h).each do |y|
      (0...w).each do |x|
        ca = a.get_cell(x, y)
        cb = b.get_cell(x, y)
        return "cell (#{x},#{y}) differs: eager=#{ca.inspect} diffed=#{cb.inspect}" if ca != cb
      end
    end
    nil
  end

  # Draw a frame into a screen: a full-screen fill (as runner#render does) then `lines`
  # left-aligned from row 0 — the canonical gori immediate-mode frame shape.
  def self.draw_frame(screen : Screen, lines : Array(String)) : Nil
    w, h = screen.width, screen.height
    screen.fill(Rect.new(0, 0, w, h), Theme.bg)
    lines.each_with_index do |line, y|
      break if y >= h
      screen.text(0, y, line, Theme.text)
    end
  end

  describe TermisuBackend do
    it "leaves termisu's buffer identical to eager forwarding (ASCII + CJK + scroll)" do
      w, h = 40, 12
      fake = FakeTerm.new(w, h)
      eager = EagerRefBackend.new(w, h)
      buffered = TermisuBackend.new(fake)
      bscreen = Screen.new(buffered)
      escreen = Screen.new(eager)

      frames = [
        ["GET /api HTTP/1.1", "Host: example.com", "안녕하세요 中文 test", "body line one"],
        ["GET /api HTTP/1.1", "Host: example.com", "안녕하세요 中文 test", "body line two"], # 1 line changed
        ["POST /x HTTP/1.1", "다른 줄 wide 文字", "narrow now", ""],                       # width transitions
        ["POST /x HTTP/1.1", "다른 줄 wide 文字", "narrow now", ""],                       # identical repaint
      ]

      frames.each do |lines|
        Gori::Tui.draw_frame(bscreen, lines)
        buffered.flush
        Gori::Tui.draw_frame(escreen, lines)
        # (eager buffer accumulates; comparing after each frame is fine — both hold the frame)
        diff = Gori::Tui.buffers_identical(eager.buffer, fake.buffer, w, h)
        diff.should be_nil
      end
    end

    it "forwards zero cells on an unchanged repaint" do
      w, h = 40, 10
      fake = FakeTerm.new(w, h)
      buffered = TermisuBackend.new(fake)
      screen = Screen.new(buffered)
      lines = ["line one", "line two", "안녕 wide 中"]

      Gori::Tui.draw_frame(screen, lines)
      buffered.flush # first frame forwards everything
      first = fake.set_calls
      first.should be > 0

      fake.reset_counts
      Gori::Tui.draw_frame(screen, lines)
      buffered.flush # identical frame → nothing to forward
      fake.set_calls.should eq(0)
      fake.renders.should be > 0 # still calls render (termisu no-ops its own diff)
    end

    it "forwards only the changed cells on a partial update" do
      w, h = 40, 10
      fake = FakeTerm.new(w, h)
      buffered = TermisuBackend.new(fake)
      screen = Screen.new(buffered)

      Gori::Tui.draw_frame(screen, ["hello world", "second line"])
      buffered.flush
      fake.reset_counts

      # Change only the first line's last word.
      Gori::Tui.draw_frame(screen, ["hello there", "second line"])
      buffered.flush
      # Only the differing tail cells forward — far fewer than a full 40*10 = 400 repaint.
      fake.set_calls.should be > 0
      fake.set_calls.should be < 20
    end

    it "full-forwards after a sync (resize / external clear) and matches eager" do
      w, h = 30, 8
      fake = FakeTerm.new(w, h)
      eager = EagerRefBackend.new(w, h)
      buffered = TermisuBackend.new(fake)
      bscreen = Screen.new(buffered)
      escreen = Screen.new(eager)
      lines = ["alpha", "beta gamma", "wide 한글 中"]

      Gori::Tui.draw_frame(bscreen, lines)
      buffered.flush
      Gori::Tui.draw_frame(escreen, lines)

      # A sync repaint (as after a resize) must re-forward every cell even though the
      # frame is unchanged, so a corrupted/cleared terminal is fully restored.
      fake.reset_counts
      Gori::Tui.draw_frame(bscreen, lines)
      buffered.flush(sync: true)
      fake.set_calls.should be > 0
      fake.syncs.should be > 0
      Gori::Tui.buffers_identical(eager.buffer, fake.buffer, w, h).should be_nil
    end

    # An overlay (popup / prompt) drawn over CJK body text overwrites the continuation
    # column of a wide glyph. termisu clears the orphaned lead; the backend must too, or
    # @front caches a phantom lead that the diff never repairs (persistent corruption).
    it "keeps an overlay over CJK body identical to eager across repaints (continuation orphan)" do
      w, h = 24, 6
      fake = FakeTerm.new(w, h)
      eager = EagerRefBackend.new(w, h)
      buffered = TermisuBackend.new(fake)
      bscreen = Screen.new(buffered)
      escreen = Screen.new(eager)
      body = ["가나다라마 abcde", "wide 中文 text here", "한글 body 中 line"]

      # Frame 1: just the CJK body. Frame 2: an overlay bar over the middle of each row
      # (its left edge deliberately lands mid-glyph). Frame 3: back to body only. Every
      # frame must match eager — a cached phantom lead would surface on frame 3.
      3.times do |n|
        Gori::Tui.draw_frame(bscreen, body)
        Gori::Tui.draw_frame(escreen, body)
        if n == 1
          (0...h).each do |y|
            bscreen.text(3, y, "[OVERLAY]", Theme.text_bright, Theme.accent_bg)
            escreen.text(3, y, "[OVERLAY]", Theme.text_bright, Theme.accent_bg)
          end
        end
        buffered.flush
        Gori::Tui.buffers_identical(eager.buffer, fake.buffer, w, h).should be_nil
      end
    end

    # A width-2 glyph with no room at the last column: termisu rejects it and keeps the
    # previous cell; the backend must store the space termisu shows, not the phantom lead.
    it "matches eager for a wide glyph at the last column (no room)" do
      w, h = 8, 2
      fake = FakeTerm.new(w, h)
      eager = EagerRefBackend.new(w, h)
      buffered = TermisuBackend.new(fake)
      # Fill both, then force a wide glyph into the final column.
      (0...w).each { |x| eager.put(x, 0, " ", Theme.text, Theme.bg, Attribute::None); buffered.put(x, 0, " ", Theme.text, Theme.bg, Attribute::None) }
      eager.put(w - 1, 0, "中", Theme.text, Theme.bg, Attribute::None)
      buffered.put(w - 1, 0, "中", Theme.text, Theme.bg, Attribute::None)
      buffered.flush
      Gori::Tui.buffers_identical(eager.buffer, fake.buffer, w, h).should be_nil
    end

    # A standalone width-0 combining mark (e.g. malformed proxied body): termisu rejects
    # it; the backend must substitute a space so its grid matches what termisu holds.
    it "matches eager for a standalone width-0 combining mark" do
      w, h = 6, 2
      fake = FakeTerm.new(w, h)
      eager = EagerRefBackend.new(w, h)
      buffered = TermisuBackend.new(fake)
      (0...w).each { |x| eager.put(x, 0, " ", Theme.text, Theme.bg, Attribute::None); buffered.put(x, 0, " ", Theme.text, Theme.bg, Attribute::None) }
      eager.put(2, 0, "́", Theme.text, Theme.bg, Attribute::None) # combining acute, no base
      buffered.put(2, 0, "́", Theme.text, Theme.bg, Attribute::None)
      buffered.flush
      Gori::Tui.buffers_identical(eager.buffer, fake.buffer, w, h).should be_nil
    end

    # Resize is driven by the event (backend#resize), NOT a live ioctl: after a resize the
    # grid re-fits and the next flush full-repaints at the new dims, matching eager.
    it "re-fits its grid on resize and full-forwards at the new size" do
      fake = FakeTerm.new(20, 5)
      buffered = TermisuBackend.new(fake)
      screen = Screen.new(buffered)
      Gori::Tui.draw_frame(screen, ["hello", "world"])
      buffered.flush
      buffered.size.should eq({20, 5})

      # Grow to 30x8. In the real runner, termisu resizes its buffer (prepare_event) THEN the
      # event handler calls backend#resize with the same dims — mirror that order here.
      fake.resize(30, 8)     # prepare_event
      buffered.resize(30, 8) # event handler
      buffered.size.should eq({30, 8})
      screen2 = Screen.new(buffered) # picks up the new dims from backend#size
      screen2.width.should eq(30)

      eager = EagerRefBackend.new(30, 8)
      escreen = Screen.new(eager)
      Gori::Tui.draw_frame(screen2, ["resized", "wider frame now"])
      Gori::Tui.draw_frame(escreen, ["resized", "wider frame now"])
      buffered.flush(sync: true)
      fake.syncs.should be > 0
      Gori::Tui.buffers_identical(eager.buffer, fake.buffer, 30, 8).should be_nil
    end

    # `fill_span` is the bulk path `Screen#fill` takes now; it must leave the grid exactly as
    # the per-cell path did, and the only place the two can disagree is a wide glyph the span
    # touches: its lead just outside the span's left edge, its continuation just past the
    # right edge, or both halves inside. Each is drawn, then filled over, then compared
    # against eager forwarding of the same sequence.
    it "fills over a wide glyph at either edge and inside a span identically to eager" do
      w, h = 20, 4
      fake = FakeTerm.new(w, h)
      eager = EagerRefBackend.new(w, h)
      buffered = TermisuBackend.new(fake)
      bscreen = Screen.new(buffered)
      escreen = Screen.new(eager)
      [bscreen, escreen].each do |sc|
        sc.fill(Rect.new(0, 0, w, h), Theme.bg)
        sc.text(4, 0, "中", Theme.text)                 # lead at 4, continuation at 5
        sc.fill(Rect.new(5, 0, 6, 1), Theme.accent_bg) # span starts ON the continuation → lead orphaned
        sc.text(4, 1, "中", Theme.text)
        sc.fill(Rect.new(0, 1, 5, 1), Theme.accent_bg) # span ends ON the lead → continuation orphaned
        sc.text(4, 2, "中文", Theme.text)
        sc.fill(Rect.new(2, 2, 8, 1), Theme.accent_bg) # both halves inside
        sc.text(w - 2, 3, "中", Theme.text)
        sc.fill(Rect.new(w - 4, 3, 40, 1), Theme.accent_bg) # clipped at the right edge
        sc.fill(Rect.new(-3, 3, 5, 1), Theme.selection_dim) # clipped at the left edge
      end
      buffered.flush
      Gori::Tui.buffers_identical(eager.buffer, fake.buffer, w, h).should be_nil
    end

    # --- Screenshot::Frame capture -----------------------------------------------------
    #
    # `snapshot` is the screenshot subsystem's whole read side, and the things it can get
    # wrong are all "which state did it read": the half-drawn frame instead of the shown
    # one, the continuation column's own colours instead of its lead's, termisu's default
    # instead of the theme's, or a wrap mark from a frame that is gone.

    it "snapshots the frame on screen, not the one being drawn" do
      fake = FakeTerm.new(12, 3)
      backend = TermisuBackend.new(fake)
      screen = Screen.new(backend)
      Gori::Tui.draw_frame(screen, ["shown"])
      backend.flush

      # A verb runs partway through the NEXT tick: the fill has happened and the new text
      # has not. @back holds that; the glass still holds the flushed frame.
      Gori::Tui.draw_frame(screen, ["drawing now"])
      frame = backend.snapshot.should_not be_nil
      frame.cols.should eq(12)
      frame.rows.should eq(3)
      frame.row_text(0).rstrip.should eq("shown")

      backend.flush
      backend.snapshot.not_nil!.row_text(0).rstrip.should eq("drawing now")
    end

    it "gives a wide glyph a lead and a continuation carrying the lead's colours" do
      fake = FakeTerm.new(8, 2)
      backend = TermisuBackend.new(fake)
      screen = Screen.new(backend)
      screen.fill(Rect.new(0, 0, 8, 2), Theme.bg)
      screen.text(1, 0, "中", Theme.red, Theme.accent_bg)
      backend.flush

      frame = backend.snapshot.not_nil!
      frame.at(1, 0).grapheme.should eq("中")
      frame.at(1, 0).cont?.should be_false
      frame.at(2, 0).cont?.should be_true
      frame.at(2, 0).grapheme.should eq("")
      # The band under the glyph has to cover both halves.
      frame.at(2, 0).bg.should eq(frame.at(1, 0).bg)
      frame.row_text(0).rstrip.should eq(" 中")
    end

    it "resolves the terminal default to the ACTIVE theme's canvas and ink" do
      was = Theme.active_name
      begin
        Theme.apply("goriday")
        fake = FakeTerm.new(6, 2)
        backend = TermisuBackend.new(fake)
        backend.flush # forward the untouched grid: every cell is GridCell.blank

        frame = backend.snapshot.not_nil!
        frame.theme.should eq("goriday")
        # GridCell.blank is a space with fg Color.white and bg Color.default. The DEFAULT is
        # the one that must follow the theme — taking termisu's {0,0,0} for it would paint a
        # paper-white screen's canvas black.
        frame.bg.should eq(Gori::Screenshot::RGB.of(Theme.bg, Gori::Screenshot::RGB::BLACK))
        frame.bg.to_hex.should eq("#faf9f7")
        frame.fg.to_hex.should eq("#33322f")
        frame.at(0, 0).bg.should eq(frame.bg)
        frame.blank_row?(0).should be_true
      ensure
        Theme.apply(was)
      end
    end

    it "carries a frame's wrap marks only until the next frame replaces them" do
      fake = FakeTerm.new(10, 4)
      backend = TermisuBackend.new(fake)
      screen = Screen.new(backend)

      # Marks belong to the frame being drawn, so nothing is visible before the flush.
      screen.mark_continuation(0, 1, 10)
      backend.snapshot.not_nil!.continuations.should be_empty
      backend.flush
      backend.snapshot.not_nil!.continuations
        .should eq([Gori::Screenshot::WrapSpan.new(1, 0, 10)])

      # A frame that does not re-report the mark drops it, exactly like an undrawn cell.
      backend.flush
      backend.snapshot.not_nil!.continuations.should be_empty
    end

    it "clips a wrap mark to the grid and drops one that lands off it" do
      fake = FakeTerm.new(10, 4)
      backend = TermisuBackend.new(fake)
      screen = Screen.new(backend)
      screen.mark_continuation(-3, 2, 20) # overhangs both edges
      screen.mark_continuation(0, 9, 5)   # past the bottom
      backend.flush
      backend.snapshot.not_nil!.continuations
        .should eq([Gori::Screenshot::WrapSpan.new(2, 0, 10)])
    end

    it "drops the wrap marks on resize along with the grids they described" do
      fake = FakeTerm.new(10, 4)
      backend = TermisuBackend.new(fake)
      Screen.new(backend).mark_continuation(0, 1, 10)
      backend.flush
      backend.snapshot.not_nil!.continuations.size.should eq(1)

      fake.resize(14, 6)
      backend.resize(14, 6)
      frame = backend.snapshot.not_nil!
      frame.cols.should eq(14)
      frame.continuations.should be_empty
    end

    it "answers nil from a backend with no front buffer" do
      # The ~7 recording backends in spec/ and bench/ inherit this, which is why the base
      # method is a default rather than an abstract one.
      EagerRefBackend.new(4, 2).snapshot.should be_nil
    end

    it "clips a fill that leaves the screen entirely without writing anything" do
      w, h = 10, 3
      fake = FakeTerm.new(w, h)
      buffered = TermisuBackend.new(fake)
      screen = Screen.new(buffered)
      screen.fill(Rect.new(0, 0, w, h), Theme.bg)
      buffered.flush
      fake.reset_counts
      screen.fill(Rect.new(w, 0, 5, h), Theme.accent_bg)  # off the right
      screen.fill(Rect.new(0, h, w, 2), Theme.accent_bg)  # off the bottom
      screen.fill(Rect.new(-5, 0, 5, h), Theme.accent_bg) # off the left
      buffered.flush
      fake.set_calls.should eq(0)
    end
  end
end
