require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The polymorphic Overlay seam (src/gori/tui/overlay.cr) is what let the Runner collapse
# a modal's ~13 scattered `case @overlay` ladder entries into one @active_overlay dispatch.
# The Runner itself can't be unit-tested without a terminal, so these specs lock the
# CONTRACT the Runner's generic dispatch relies on:
#   - handle_key / handle_click return the :stay | :commit | :cancel vocabulary
#   - commit runs the injected on_commit closure and honours its Bool (false keeps it open)
#   - title / hint / key supply the chrome the collapsed ladders used to hard-code
# If this contract holds, migrating the next overlay onto the seam is a local change.

private def skey(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, char: char)
end

# Mirrors Runner#dispatch_overlay_key exactly: returns :closed when the shell would drop
# the overlay, :open when it stays. This is the seam the Runner drives.
private def dispatch_key(ov : Overlay, ev : Termisu::Event::Key) : Symbol
  case ov.handle_key(ev)
  when :cancel then :closed
  when :commit then ov.commit ? :closed : :open
  else              :open
  end
end

# Mirrors Runner#dispatch_overlay_click.
private def dispatch_click(ov : Overlay, area : Rect, mx : Int32, my : Int32) : Symbol
  case ov.handle_click(area, mx, my)
  when :cancel then :closed
  when :commit then ov.commit ? :closed : :open
  else              :open
  end
end

# A minimal Overlay to pin the base-class defaults the Runner leans on.
private class FakeOverlay < Overlay
  getter renders = 0

  def key : Symbol
    :fake
  end

  def title : String
    "FAKE"
  end

  def hint : String
    "fake hint"
  end

  def render(screen : Screen, area : Rect) : Nil
    @renders += 1
  end

  def handle_key(ev : Termisu::Event::Key) : Symbol
    :stay
  end
end

describe "Overlay seam — base contract" do
  it "defaults: no box, click dismisses, wheel/preedit are no-ops, commit closes" do
    ov = FakeOverlay.new
    area = Rect.new(0, 0, 80, 24)

    ov.overlay_box(area).should be_nil
    # No box → a click can't be inside → the shell dismisses (prior close-on-click-away).
    ov.handle_click(area, 10, 10).should eq(:cancel)
    # No-op hooks must not raise (the Runner calls them unconditionally).
    ov.handle_wheel(3)
    ov.set_preedit("한")
    # No on_commit supplied → commit is a no-op that closes.
    ov.commit.should be_true
  end

  it "commit runs the injected closure and honours its Bool" do
    ov = FakeOverlay.new
    calls = 0
    ov.on_commit = -> {
      calls += 1
      false # e.g. validation failed → keep the form up
    }
    ov.commit.should be_false
    calls.should eq(1)

    ov.on_commit = -> { true }
    ov.commit.should be_true
  end
end

describe "Overlay seam — ScopeRuleOverlay (first migrated modal)" do
  it "exposes the chrome the collapsed ladders used to hard-code" do
    ov = ScopeRuleOverlay.adding.as(Overlay)
    ov.key.should eq(:scope_rule)
    ov.title.should eq("SCOPE RULE")
    ov.hint.should_not be_empty
  end

  it "drives open → key → commit → apply(on_commit) → close through the generic dispatch" do
    committed = [] of {String, String, String}
    ov = ScopeRuleOverlay.new(kind: "include", match_type: "host")
    ov.on_commit = -> {
      committed << {ov.kind, ov.match_type, ov.pattern}
      true
    }
    over = ov.as(Overlay)

    # ↓ ↓ to the pattern row, type a value, ↵ commits.
    dispatch_key(over, skey(Termisu::Input::Key::Down)).should eq(:open)
    dispatch_key(over, skey(Termisu::Input::Key::Down)).should eq(:open)
    "acme.test".each_char { |c| dispatch_key(over, skey(Termisu::Input::Key::LowerA, c)) }
    dispatch_key(over, skey(Termisu::Input::Key::Enter)).should eq(:closed)

    committed.should eq([{"include", "host", "acme.test"}])
  end

  it "keeps the form open when on_commit reports failure (invalid pattern)" do
    ov = ScopeRuleOverlay.new(kind: "include", match_type: "host")
    ov.on_commit = -> { false } # apply rejected it
    over = ov.as(Overlay)

    ov.set_selected(3) # Save row
    dispatch_key(over, skey(Termisu::Input::Key::Enter)).should eq(:open)
  end

  it "esc cancels without committing" do
    committed = 0
    ov = ScopeRuleOverlay.adding
    ov.on_commit = -> {
      committed += 1
      true
    }
    dispatch_key(ov.as(Overlay), skey(Termisu::Input::Key::Escape)).should eq(:closed)
    committed.should eq(0)
  end

  it "click on the Save row commits; a click outside the card dismisses" do
    committed = 0
    ov = ScopeRuleOverlay.new(kind: "include", match_type: "host", pattern: "acme.test")
    ov.on_commit = -> {
      committed += 1
      true
    }
    over = ov.as(Overlay)
    area = Rect.new(0, 0, 80, 24)
    box = ov.overlay_box(area).not_nil!

    # Save is row index 3 (kind/type/pattern/save); its screen row is box.y + 2 + 3.
    dispatch_click(over, area, box.x + 3, box.y + 5).should eq(:closed)
    committed.should eq(1)

    # A click well outside the centered card is a dismiss (no commit).
    ov2 = ScopeRuleOverlay.adding.as(Overlay)
    dispatch_click(ov2, area, 0, 0).should eq(:closed)
  end

  it "wheel over the modal moves the selected field (delegates to move)" do
    ov = ScopeRuleOverlay.adding
    ov.on_save_row?.should be_false
    ov.as(Overlay).handle_wheel(3) # 3 notches down: kind → type → pattern → save
    ov.on_save_row?.should be_true
  end
end

# The HARD case the seam had to prove: a modal opened from TWO sites with different apply
# semantics (new-session vs reconfigure-current), which previously needed a shell-side
# @sequence_reconfigure flag. Under the seam that flag is gone — each open-site injects its
# own on_commit closure and the overlay only ever reports :commit. These specs lock that
# the closure injection carries the site-specific behaviour and the valid? gate.
private def seed(loc : Gori::Sequencer::TokenLoc? = Gori::Sequencer::TokenLoc.new(Gori::Sequencer::ExtractKind::Cookie, "session")) : SequenceSeed
  SequenceSeed.new(
    target: "https://acme.test/",
    request: "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
    http2: false,
    sni: nil,
    flow_id: nil,
    summary: "GET /",
    mode: Gori::Sequencer::Mode::LiveReplay,
    suggested_loc: loc,
    candidate_cookies: ["session"],
    candidate_headers: [] of String,
  )
end

describe "Overlay seam — SequenceConfigOverlay (hard case: 2 open-sites, no flag)" do
  it "exposes chrome + a self-contained handle_key (formerly Runner#handle_sequence_config_key)" do
    ov = SequenceConfigOverlay.new(seed).as(Overlay)
    ov.key.should eq(:sequence_config)
    ov.title.should eq("SEQUENCER")
    ov.hint.should_not be_empty
    # esc cancels; ↓ moves; the Start row commits — all owned by the overlay now.
    ov.handle_key(skey(Termisu::Input::Key::Escape)).should eq(:cancel)
  end

  it "routes the SAME :commit to different apply behaviour purely via the injected closure" do
    # Two independent open-sites, distinguished only by their closure — the exact thing the
    # deleted @sequence_reconfigure flag used to do.
    log = [] of String

    new_ov = SequenceConfigOverlay.new(seed)
    new_ov.on_commit = -> {
      log << "start_session"
      true
    }
    reconf_ov = SequenceConfigOverlay.new(seed)
    reconf_ov.on_commit = -> {
      log << "reconfigure_current"
      true
    }

    # Drive each to Start (row 5) and commit through the generic shell dispatch.
    [new_ov, reconf_ov].each do |ov|
      over = ov.as(Overlay)
      4.times { dispatch_key(over, skey(Termisu::Input::Key::Down)) } # selector → … → Start
      ov.on_start_row?.should be_true
      dispatch_key(over, skey(Termisu::Input::Key::Enter)).should eq(:closed)
    end

    log.should eq(["start_session", "reconfigure_current"])
  end

  it "keeps the form open when the token location is unset (valid? gate in commit)" do
    ov = SequenceConfigOverlay.new(seed(loc: nil)) # nothing pre-filled → invalid
    ov.valid?.should be_false
    # Real open-site gate: reject + keep open, mirroring Runner#commit_sequence.
    ov.on_commit = -> { ov.valid? }
    over = ov.as(Overlay)
    ov.set_selected(5) # Start row
    dispatch_key(over, skey(Termisu::Input::Key::Enter)).should eq(:open)
  end

  it "click on Start commits; a click outside dismisses" do
    committed = 0
    ov = SequenceConfigOverlay.new(seed)
    ov.on_commit = -> {
      committed += 1
      true
    }
    over = ov.as(Overlay)
    area = Rect.new(0, 0, 80, 24)
    box = ov.overlay_box(area).not_nil!
    # Start is row index 5; its screen row is box.y + 3 + 5.
    dispatch_click(over, area, box.x + 3, box.y + 8).should eq(:closed)
    committed.should eq(1)

    dispatch_click(SequenceConfigOverlay.new(seed).as(Overlay), area, 0, 0).should eq(:closed)
  end

  it "routes IME preedit to the selector field (the seam's per-modal-IME promise)" do
    ov = SequenceConfigOverlay.new(seed(loc: nil)) # blank selector, opens on that row
    ov.editing_selector?.should be_true
    # ASCII preedit so the assertion isn't defeated by the width-2 continuation cell a CJK
    # glyph leaves between codepoints in MemoryBackend#row; routing is content-agnostic.
    ov.as(Overlay).set_preedit("preedithere")
    mb = MemoryBackend.new(80, 24)
    ov.render(Screen.new(mb), Rect.new(0, 0, 80, 24))
    mb.contains?("preedithere").should be_true
  end
end

private def mseed(applicable = [Gori::Miner::Location::Query, Gori::Miner::Location::Json],
                  default = [Gori::Miner::Location::Query]) : MineSeed
  MineSeed.new(
    target: "https://acme.test/",
    request: "GET /?q=1 HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
    http2: false,
    sni: nil,
    flow_id: nil,
    summary: "GET /",
    applicable: applicable,
    default: default,
  )
end

describe "Overlay seam — MineConfigOverlay (laggard: keys were shell-owned; click toggles rows)" do
  it "exposes chrome + a self-contained handle_key (formerly Runner#handle_mine_config_key)" do
    ov = MineConfigOverlay.new(mseed).as(Overlay)
    ov.key.should eq(:mine_config)
    ov.title.should eq("MINE PARAMS")
    ov.hint.should_not be_empty
    ov.handle_key(skey(Termisu::Input::Key::Escape)).should eq(:cancel)
  end

  it "commits from the Start row through the generic dispatch" do
    ran = 0
    ov = MineConfigOverlay.new(mseed)
    ov.on_commit = -> {
      ran += 1
      true
    }
    over = ov.as(Overlay)
    # rows: [Query, Json, concurrency, notify, Start] → 4 downs to Start.
    4.times { dispatch_key(over, skey(Termisu::Input::Key::Down)) }
    ov.on_start_row?.should be_true
    dispatch_key(over, skey(Termisu::Input::Key::Enter)).should eq(:closed)
    ran.should eq(1)
  end

  it "keeps the form open when the commit closure rejects (no location selected)" do
    ov = MineConfigOverlay.new(mseed)
    ov.on_commit = -> { false } # e.g. any_checked? was false
    ov.set_selected(4)          # Start row
    dispatch_key(ov.as(Overlay), skey(Termisu::Input::Key::Enter)).should eq(:open)
  end

  it "click on a location row TOGGLES its checkbox (behaviour preserved from click_mine_config)" do
    ov = MineConfigOverlay.new(mseed)
    area = Rect.new(0, 0, 80, 24)
    box = ov.overlay_box(area).not_nil!
    before = ov.build_config.locations.includes?(Gori::Miner::Location::Query)
    # Row 0 (Query) is at box.y + 3; a click there selects AND toggles it.
    ov.as(Overlay).handle_click(area, box.x + 3, box.y + 3).should eq(:stay)
    ov.build_config.locations.includes?(Gori::Miner::Location::Query).should_not eq(before)
  end

  it "click on Start commits; a click outside dismisses" do
    ran = 0
    ov = MineConfigOverlay.new(mseed)
    ov.on_commit = -> {
      ran += 1
      true
    }
    over = ov.as(Overlay)
    area = Rect.new(0, 0, 80, 24)
    box = ov.overlay_box(area).not_nil!
    # Start is row index 4; its screen row is box.y + 3 + 4.
    dispatch_click(over, area, box.x + 3, box.y + 7).should eq(:closed)
    ran.should eq(1)

    dispatch_click(MineConfigOverlay.new(mseed).as(Overlay), area, 0, 0).should eq(:closed)
  end
end
