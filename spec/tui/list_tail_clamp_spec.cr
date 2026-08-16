require "../spec_helper"
require "../support/memory_backend"
require "../support/fake_context"

include Gori::Tui

# The tail clamp, on the five lists that were missing it.
#
# Every scrolling list here derives `@scroll` from its selection each frame, and the two rules
# that do it only fire when the CURSOR is outside the window. So when the list shrinks under a
# stale offset — a filter narrows it, a held request is forwarded — or the pane grows taller
# than the rows left below the offset, neither rule moves anything: the draw loop breaks at the
# now-shorter end and paints dead space, or nothing at all. Four lists (History, Issues, Probe,
# Sitemap) each hit that in the field and each grew its own clamp afterwards; these five never
# did, until `Viewport.scroll_to_show` gave all sixteen one derivation.
#
# Each example puts a list into the exact state the missing clamp mishandled and asserts the
# rows are ON SCREEN. There is no public `scroll` accessor on any of these views — which is the
# point: the regression was always visual, so it is pinned against what the renderer drew.

private def render_at(view, w : Int32, h : Int32, focused = true) : MemoryBackend
  backend = MemoryBackend.new(w, h)
  view.render(Screen.new(backend), Rect.new(0, 0, w, h), focused)
  backend
end

private def miner_finding(name : String) : Gori::Miner::Finding
  Gori::Miner::Finding.new(name, Gori::Miner::Location::Query, Gori::Miner::Evidence::Status,
    Gori::Miner::Confidence::Confirmed, nil, nil, 0_i64)
end

private def sequencer_sample(i : Int32) : Gori::Sequencer::Sample
  Gori::Sequencer::Sample.new(index: i, token: "tok#{i.to_s.rjust(2, '0')}", status: 200,
    length: 8, duration_us: 1000_i64, error: nil)
end

private def discover_finding(path : String) : Gori::Discover::Finding
  Gori::Discover::Finding.new(url: "http://d.test#{path}", method: "GET", status: 200,
    length: 10_i64, content_type: "text/html", source: Gori::Discover::Source::Crawled,
    depth: 1, confidence: 1.0, note: nil)
end

private def tmp_interceptor(&)
  path = File.tempname("gori-tailclamp", ".db")
  store = Gori::Store.open(path)
  begin
    ic = Gori::Interceptor.new(Gori::Scope.load(store))
    ic.toggle # enable
    yield ic
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

describe "list viewport tail clamp" do
  # --- the pane GREW: a terminal resized taller than the rows below the offset ----------
  # Nothing about the list changed and the cursor never left the window, so only the clamp
  # can pull the top of the list back into view.

  describe Gori::Tui::MinerView do
    it "shows the whole findings list again after the pane grows taller than it" do
      view = Gori::Tui::MinerView.new
      view.load("http://h.test", "GET /a HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, false, nil,
        Gori::Miner::Config.new)
      view.focus_pane(:results)
      12.times { |i| view.append_finding(miner_finding("param#{i.to_s.rjust(2, '0')}")) }
      view.results_move(11) # park on the last row

      short = render_at(view, 100, 14)
      short.contains?("param11").should be_true # the cursor row, wherever the window sits
      short.contains?("param00").should be_false

      tall = render_at(view, 100, 44) # every finding now fits
      tall.contains?("param00").should be_true
      tall.contains?("param11").should be_true
    end
  end

  describe Gori::Tui::SequencerView do
    it "shows the whole samples list again after the pane grows taller than it" do
      view = Gori::Tui::SequencerView.new
      view.load("http://h.test", "GET /a HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, false, nil,
        Gori::Sequencer::Config.new)
      view.focus_pane(:samples)
      12.times { |i| view.append_sample(sequencer_sample(i)) }
      view.samples_move(11)

      short = render_at(view, 120, 14)
      short.contains?("tok11").should be_true
      short.contains?("tok00").should be_false

      tall = render_at(view, 120, 44)
      tall.contains?("tok00").should be_true
      tall.contains?("tok11").should be_true
    end

    # --- auto-follow-the-tail (#711) ---------------------------------------------------
    # The decision is made at `append_sample`, not in render's `ensure_visible`: by render time
    # the list has already grown, so a cursor on what WAS the tail is indistinguishable from one
    # the operator parked a row above it. `@follow` — HistoryView's vocabulary, re-asked by every
    # cursor move as `@sel == follow_index` — is what tells them apart.
    it "drags the cursor down to the newest sample while a run streams" do
      view = Gori::Tui::SequencerView.new
      view.load("http://h.test", "GET /a HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, false, nil,
        Gori::Sequencer::Config.new)
      view.focus_pane(:samples)
      view.begin_run
      12.times { |i| view.append_sample(sequencer_sample(i)) }

      # No cursor key was pressed: the appends alone moved it.
      view.samples_selected_index.should eq(11)
      backend = render_at(view, 120, 20)
      backend.contains?("tok11").should be_true
      backend.contains?("tok00").should be_false # the window followed it down
    end

    # The other half of the promise: collecting 500 tokens must not fight an operator reading
    # row 07. Scrolling up is the "stop following" gesture, and walking back onto the newest
    # sample re-arms it.
    it "stops following the tail once the operator scrolls up, and re-arms at the bottom" do
      view = Gori::Tui::SequencerView.new
      view.load("http://h.test", "GET /a HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, false, nil,
        Gori::Sequencer::Config.new)
      view.focus_pane(:samples)
      view.begin_run
      12.times { |i| view.append_sample(sequencer_sample(i)) }
      view.samples_move(-4) # read row 07 while the run keeps collecting
      view.samples_selected_index.should eq(7)

      6.times { |i| view.append_sample(sequencer_sample(12 + i)) }
      view.samples_selected_index.should eq(7) # the cursor stayed where it was put
      backend = render_at(view, 120, 20)
      backend.contains?("tok07").should be_true
      backend.contains?("tok17").should be_false # and so did the window

      view.samples_move(10) # back down onto the newest sample
      view.samples_selected_index.should eq(17)
      view.append_sample(sequencer_sample(18))
      view.samples_selected_index.should eq(18) # following again
    end

    # A finished collection is a static list the operator reads. `finish_run` does not clear
    # `@follow` — `@running` is the gate, so a late append (a saved run reloaded, a stray
    # terminal event) never yanks the cursor out from under a reader.
    it "does not follow an append when no run is streaming" do
      view = Gori::Tui::SequencerView.new
      view.load("http://h.test", "GET /a HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, false, nil,
        Gori::Sequencer::Config.new)
      view.focus_pane(:samples)
      12.times { |i| view.append_sample(sequencer_sample(i)) }
      view.samples_selected_index.should eq(0)

      view.begin_run
      3.times { |i| view.append_sample(sequencer_sample(i)) }
      view.samples_selected_index.should eq(2)
      view.finish_run
      view.append_sample(sequencer_sample(3))
      view.samples_selected_index.should eq(2) # the run ended; the cursor is the operator's now
    end
  end

  describe Gori::Tui::DiscoverView do
    # The RUNS card, sibling of the FINDINGS card below. It grows a row per run, so on a short
    # terminal a session with a dozen crawls scrolls — and the offset it scrolled to survived
    # into a taller frame, leaving the earliest runs unreachable above the window with blank
    # rows below them. Those rows are the only place a still-crawling run's ^X lives.
    it "shows every run again after the pane grows taller than the runs list" do
      view = DiscoverView.new
      12.times do |i|
        run = DiscoverRun.new("http://r#{i.to_s.rjust(2, '0')}.test/", Gori::Discover::Config.new)
        run.status = :done
        view.add(run)
      end
      view.focus_pane(:runs)
      view.move_run(11) # `add` already selects the newest; park there explicitly

      short = render_at(view, 120, 16)
      short.contains?("r11.test").should be_true
      short.contains?("r00.test").should be_false

      tall = render_at(view, 120, 44) # every run now fits
      tall.contains?("r00.test").should be_true
      tall.contains?("r11.test").should be_true
    end

    it "shows the whole findings list again after the pane grows taller than it" do
      view = DiscoverView.new
      run = DiscoverRun.new("http://d.test/", Gori::Discover::Config.new)
      run.status = :done
      12.times { |i| run.add_finding(discover_finding("/f#{i.to_s.rjust(2, '0')}")) }
      view.add(run)
      view.focus_pane(:findings)
      view.move(11)

      short = render_at(view, 120, 16)
      short.contains?("/f11").should be_true
      short.contains?("/f00").should be_false

      tall = render_at(view, 120, 44)
      tall.contains?("/f00").should be_true
      tall.contains?("/f11").should be_true
    end
  end

  # --- the LIST shrank under a stale offset --------------------------------------------
  # The pane never changed size. Without the clamp the draw loop breaks on its first
  # iteration and the pane paints nothing at all.

  describe Gori::Tui::PaletteState do
    # The palette card's list height is a function of the area the shell hands it, and its own
    # `@scroll` is never reset by anything but a fresh construction — so a short window that
    # scrolled to the tail of a filtered list survives into the tall one the next frame draws.
    it "shows the whole filtered list again after the card grows taller than it" do
      ctx = FakeExecContext.new
      palette = PaletteState.new(Gori::Verbs.registry)
      palette.reset(ctx)
      "open".each_char { |c| palette.append(c, ctx) }
      palette.results.size.should be > 4 # a handful of verbs — well inside one full-size card
      first = palette.results.first.title
      last = palette.results.last.title
      palette.move(palette.results.size) # park on the last row

      draw = ->(h : Int32) {
        backend = MemoryBackend.new(80, h)
        palette.render(Screen.new(backend), Rect.new(0, 0, 80, h))
        backend
      }

      short = draw.call(8) # a two-row list band: the window scrolls to the tail
      short.contains?(last).should be_true
      short.contains?(first).should be_false

      tall = draw.call(40) # every result now fits
      tall.contains?(first).should be_true
      tall.contains?(last).should be_true
    end
  end

  describe Gori::Tui::HexEdit do
    # The Repeater's `^X` hex editor. Its offset is neither an ivar here nor derived per frame:
    # `render` TAKES it and RETURNS it, and RepeaterView persists the result
    # (`@scroll_req = h.render(…, @scroll_req)`). So the stale-offset state is reachable simply
    # by scrolling a long buffer and then DELETING most of it — the edit moves the cursor but
    # never the caller's offset. Without the clamp the pane then drew a single row of the
    # now-short buffer with the rest of the card blank.
    it "redraws the whole buffer after deletes shrink it under a scrolled offset" do
      hex = HexEdit.new(Bytes.new(48)) # 3 rows at 16 bytes/row
      hex.move_rows(2)                 # cursor onto the last row
      rect = Rect.new(0, 0, 80, 10)    # a pane taller than the whole buffer

      backend = MemoryBackend.new(80, 10)
      out = hex.render(Screen.new(backend), rect, true, 2) # a stale offset from a longer buffer

      out.should eq(0) # pulled back to the top: all three rows fit
      backend.contains?("00000000").should be_true
      backend.contains?("00000010").should be_true
      backend.contains?("00000020").should be_true
    end

    it "still follows the cursor down a buffer taller than the pane" do
      hex = HexEdit.new(Bytes.new(16 * 40))
      hex.move_rows(39)
      backend = MemoryBackend.new(80, 10)
      out = hex.render(Screen.new(backend), Rect.new(0, 0, 80, 10), true, 0)

      out.should eq(30) # one viewport back from row 39
      backend.contains?("00000270").should be_true
    end
  end

  describe Gori::Tui::InterceptView do
    it "draws the remaining queue after most of a scrolled hold list is forwarded" do
      tmp_interceptor do |ic|
        12.times do |i|
          p = "/p#{i.to_s.rjust(2, '0')}"
          spawn { ic.hold_request("GET #{p} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, method: "GET", target: p, host: "acme.test", port: 80, scheme: "http") }
        end
        Fiber.yield
        view = InterceptView.new
        view.reload(ic)
        view.move(11) # park on the last hold, scrolling the window to the tail

        held = ic.pending
        held.size.should eq(12)
        render_at(view, 100, 12)

        # Forward all but the last three. The queue is now shorter than the offset the
        # window is parked at, and `reload` re-clamps the SELECTION but not the offset.
        held.first(9).each { |it| ic.forward(it.id) }
        Fiber.yield
        view.reload(ic)
        view.empty?.should be_false

        backend = render_at(view, 100, 12)
        backend.contains?("acme.test/p09").should be_true
        backend.contains?("acme.test/p11").should be_true
        ic.forward_all # release the fibers still parked on a decision
      end
    end
  end
end
