require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# THE invariant: the rects a view splits its container into must sum to no more than the
# container it was handed. Sequencer/Miner/Discover each FLOORED a pane height for
# legibility (`{h, 3}.max`, `{h, 1}.max`) with no matching ceiling at `rect.h`, so on a
# short body they placed the lower pane past `rect.bottom` and painted rows nobody owns —
# the status bar's row and the bottom margin, which no later pass repaints. `Layout.usable?`
# gates render and click at 40x8, so the reachable degenerate band is `body.h ∈ {1, 2}`;
# every example here renders into a backend TALLER than the rect so the overspill has
# somewhere to land and can be asserted as blank.

# Renders into a backend `pad` rows taller than `rect` and returns it, so the rows below
# the container are observable rather than clipped away by Screen's bounds check.
private def blank_row?(b : MemoryBackend, y : Int32) : Bool
  b.cluster_row(y).chars.all?(&.whitespace?)
end

private def first_row_index(b : MemoryBackend, h : Int32, text : String) : Int32
  (0...h).each { |y| return y if b.row(y).includes?(text) }
  -1
end

describe "short-body pane overspill" do
  # 60x12 with the sub-tab strip shown gives Sequencer a content rect of Rect(3, 7, 54, 2).
  # `cfg_h` floored at 3 and the lower pane at 2 painted rows 7..11 — row 10 is the status
  # row (repainted after) and ROW 11 is the bottom margin, outside the layout entirely.
  it "SequencerView keeps every drawn cell inside the rect it was handed" do
    {1, 2}.each do |body_h|
      view = SequencerView.new
      view.load("http://h.test", "GET /a HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, false, nil,
        Gori::Sequencer::Config.new)
      b = MemoryBackend.new(60, 12)
      rect = Rect.new(3, 12 - 2 - body_h, 54, body_h) # two spare rows below, as the real layout has
      view.render(Screen.new(b), rect, true)

      (rect.bottom...12).each do |y|
        blank_row?(b, y).should be_true # (h=#{body_h}) row #{y} is outside the container
      end
      # …and the hit-test must agree with the geometry, not with the inflated one: a click
      # on a row the renderer never owned belongs to no pane.
      view.pane_at(rect, rect.x + 2, rect.bottom).should be_nil # (h=#{body_h})
    end
  end

  it "MinerView keeps every drawn cell inside the rect it was handed" do
    {1, 2}.each do |body_h|
      view = MinerView.new
      view.load("http://h.test", "GET /a HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, false, nil,
        Gori::Miner::Config.new)
      b = MemoryBackend.new(60, 12)
      rect = Rect.new(3, 12 - 2 - body_h, 54, body_h)
      view.render(Screen.new(b), rect, true)

      (rect.bottom...12).each do |y|
        blank_row?(b, y).should be_true # (h=#{body_h}) row #{y} is outside the container
      end
      view.pane_at(rect, rect.x + 2, rect.bottom).should be_nil # (h=#{body_h})
    end
  end

  it "DiscoverView keeps every drawn cell inside the rect it was handed" do
    {1, 2}.each do |body_h|
      view = DiscoverView.new
      # The run is LOAD-BEARING, not scenery: with none, `render` short-circuits to the
      # onboarding card over the whole rect and never tiles the two panes this example exists
      # to measure. Remove it and the test passes without testing anything.
      view.add(DiscoverRun.new("http://a.test/", Gori::Discover::Config.new))
      b = MemoryBackend.new(60, 12)
      rect = Rect.new(3, 12 - 2 - body_h, 54, body_h)
      view.render(Screen.new(b), rect, true)

      (rect.bottom...12).each do |y|
        blank_row?(b, y).should be_true # (h=#{body_h}) row #{y} is outside the container
      end
      view.pane_at(rect, rect.x + 2, rect.bottom).should be_nil # (h=#{body_h})
    end
  end

  # The other half of the fix: render and the hit-test must derive from ONE source. These
  # pin the agreement at a HEALTHY size, where the clamp is a no-op — so the shared
  # derivation is what is under test, not the degenerate band.
  it "SequencerView#pane_at answers with the pane the renderer actually drew" do
    view = SequencerView.new
    view.load("http://h.test", "GET /a HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, false, nil,
      Gori::Sequencer::Config.new)
    rect = Rect.new(0, 0, 70, 30) # < 84 wide ⇒ Samples stacked above Analysis
    b = MemoryBackend.new(70, 30)
    view.render(Screen.new(b), rect, true)

    samples_y = first_row_index(b, 30, "SAMPLES")
    analysis_y = first_row_index(b, 30, "ANALYSIS")
    samples_y.should be > 0
    analysis_y.should be > samples_y
    view.pane_at(rect, 5, 0).should eq(:config)
    view.pane_at(rect, 5, samples_y).should eq(:samples)
    view.pane_at(rect, 5, analysis_y).should eq(:analysis)
  end

  it "MinerView#pane_at answers with the pane the renderer actually drew" do
    view = MinerView.new
    view.load("http://h.test", "GET /a HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, false, nil,
      Gori::Miner::Config.new)
    rect = Rect.new(0, 0, 70, 30)
    b = MemoryBackend.new(70, 30)
    view.render(Screen.new(b), rect, true)

    findings_y = first_row_index(b, 30, "FINDINGS")
    findings_y.should be > 0
    view.pane_at(rect, 5, 0).should eq(:summary)
    view.pane_at(rect, 5, findings_y).should eq(:results)
    view.pane_at(rect, 5, findings_y - 1).should eq(:summary)
  end

  # The divergence a SHARED derivation removes and two hand-matched clamps would not:
  # `render` floored `sum_h` at 1, `pane_at` re-derived it and did NOT, so at `rect.h == 3`
  # (where the `rect.h - 3` step drives `sum_h` to 0) the row `render` gave to SUMMARY
  # hit-tested to :results. Nothing caught it — the two copies were only ever compared by
  # eye. `pane_rects` makes the disagreement unrepresentable.
  it "MinerView#pane_at does not disagree with render on the row SUMMARY owns" do
    view = MinerView.new
    view.load("http://h.test", "GET /a HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, false, nil,
      Gori::Miner::Config.new)
    rect = Rect.new(0, 0, 70, 3)
    b = MemoryBackend.new(70, 3)
    view.render(Screen.new(b), rect, true)

    view.pane_at(rect, 5, rect.y).should eq(:summary) # SUMMARY's row, not FINDINGS'
    findings_y = first_row_index(b, 3, "FINDINGS")
    findings_y.should eq(1) # the card render actually framed starts below it
    view.pane_at(rect, 5, findings_y).should eq(:results)
  end
end
