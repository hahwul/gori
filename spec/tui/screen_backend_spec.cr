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
  end
end
