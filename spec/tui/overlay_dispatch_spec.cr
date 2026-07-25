require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

# The polymorphic Overlay seam (src/gori/tui/overlay.cr) is what let the Runner collapse
# a modal's ~13 scattered `case @overlay` ladder entries into one @active_overlay dispatch.
# The Runner itself can't be unit-tested without a terminal, so these specs lock the
# CONTRACT the Runner's generic dispatch relies on:
#   - handle_key / handle_click return the :stay | :commit | :cancel vocabulary
#   - commit runs the injected on_commit closure and honours its Bool (false keeps it open)
#   - title / hint / key supply the chrome the collapsed ladders used to hard-code
# If this contract holds, migrating the next overlay onto the seam is a local change.
#
# Everything below drives the modal through OverlayHarness (spec/support/overlay_harness.cr),
# which replays Runner#dispatch_overlay_key / #dispatch_overlay_click exactly. A migration
# batch should reach for the harness rather than re-deriving that dispatch by hand.

private def skey(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, char: char)
end

# The OverlayKind round-trip spec CANNOT catch a wrong spelling: to_sym and from_sym are
# generated from the same constants with the same `underscore`, so they agree under any
# rename. Only a literal list pins the wire names, and they are load-bearing twice over:
# controllers compare `@host.overlay` against these symbols, and every symbol handed to
# from_sym now RAISES if it is not a member (it used to be a silent no-op).
EXPECTED_OVERLAY_SYMS = [
  :none, :detail, :palette, :issue_new, :confirm, :browser, :choice, :tabs_more,
  :comparer_pick, :repeater_subtab, :links, :issue_pick, :note_pick, :preferences,
  :settings, :tabs, :hosts, :env, :hotkeys, :notifications, :probe_active,
  :discover_config, :discover_headers, :fuzz_set, :fuzz_advanced, :oast_provider,
  :probe_rule, :rewriter_rule, :ca_import, :import, :scope_rule, :sequence_config,
  :mine_config,
]

# A minimal Overlay to pin the base-class defaults the Runner leans on. Its `key` has to
# name a real OverlayKind (that is the type), and Palette is the safe pick: the command
# palette is explicitly OUT of the migration's scope, so no production Overlay will ever
# claim it and collide with this double.
private class StubOverlay < Overlay
  getter renders = 0

  def key : OverlayKind
    OverlayKind::Palette
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

describe "OverlayKind — the state @overlay holds" do
  it "round-trips every member through the Host facade's Symbol bridge" do
    OverlayKind.values.each do |k|
      OverlayKind.from_sym(k.to_sym).should eq(k)
    end
  end

  it "spells every member exactly as the Host facade names it" do
    OverlayKind.values.map(&.to_sym).should eq(EXPECTED_OVERLAY_SYMS)
  end

  it "resolves every symbol a live call-site hands to from_sym" do
    # Reaching from_sym with a non-member is an ArgumentError out of handle_key, which the
    # event loop does not rescue. These are the literals runner.cr and history_controller.cr
    # actually pass: request_overlay(:detail/:none) and confirm(return_to:).
    {:none, :detail, :settings, :tabs, :discover_config}.each do |sym|
      OverlayKind.from_sym(sym).to_sym.should eq(sym)
    end
  end

  it "raises on an unknown symbol instead of silently landing on None" do
    expect_raises(ArgumentError, /unknown overlay kind/) { OverlayKind.from_sym(:probe_rules) }
  end

  it "leaves migrated modals out of the shell's input-capture list" do
    # A migration DELETES its member from Runner::MODAL_OVERLAYS — the migrated modal
    # answers modal_overlay? through active_overlay instead. Leaving a stale member behind
    # would make the gate true with no overlay object to route to.
    [OverlayKind::ScopeRule, OverlayKind::SequenceConfig, OverlayKind::MineConfig].each do |k|
      Runner::MODAL_OVERLAYS.includes?(k).should be_false
    end
  end

  it "still captures input for every UNMIGRATED modal" do
    # The other half of the gate. MODAL_OVERLAYS is the one line all five Phase 1 batches
    # edit, and an accidental deletion is invisible: the modal still renders, but the shell
    # stops treating it as capturing, so clicks fall through to the tab body behind the card
    # and the wheel scrolls that body. Pin the list until each batch removes its own member.
    unmigrated = OverlayKind.values - [
      OverlayKind::None, OverlayKind::Detail, # not modals: no card, never capture
      OverlayKind::ScopeRule, OverlayKind::SequenceConfig, OverlayKind::MineConfig,
    ]
    unmigrated.size.should eq(28)
    unmigrated.each do |k|
      Runner::MODAL_OVERLAYS.includes?(k).should be_true, "#{k} lost its input-capture gate"
    end
  end
end

describe "Overlay seam — base contract" do
  it "defaults: no box, click dismisses, wheel/preedit are no-ops, commit closes" do
    h = OverlayHarness.new(StubOverlay.new)

    h.box.should be_nil
    # No box → a click can't be inside → the shell dismisses (prior close-on-click-away).
    # Assert the RAW vocabulary, not just the harness's :closed: the harness maps both
    # :cancel and a truthy :commit to :closed, so `eq(:closed)` alone would still pass if
    # the default flipped to :commit — i.e. if clicking away silently APPLIED the modal.
    h.overlay.handle_click(h.area, 10, 10).should eq(:cancel)
    h.click(10, 10).should eq(:closed)
    h.commits.should eq(0) # dismissing must never run the commit closure
    # No-op hooks must not raise (the Runner calls them unconditionally).
    h.wheel(3)
    h.preedit("한")
  end

  it "commits with no on_commit supplied (the base-class nil branch) " do
    # The harness always injects a closure, so drive the bare overlay here: an open-site
    # that supplies no closure must still get a commit that closes rather than raising.
    StubOverlay.new.commit.should be_true
  end

  it "commit runs the injected closure and honours its Bool" do
    ov = StubOverlay.new
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
    OverlayHarness.new(ScopeRuleOverlay.adding).assert_chrome(OverlayKind::ScopeRule, "SCOPE RULE")
  end

  it "drives open → key → commit → apply(on_commit) → close through the generic dispatch" do
    committed = [] of {String, String, String}
    ov = ScopeRuleOverlay.new(kind: "include", match_type: "host")
    h = OverlayHarness.new(ov)
    h.on_commit do
      committed << {ov.kind, ov.match_type, ov.pattern}
      true
    end

    # ↓ ↓ to the pattern row, type a value, ↵ commits.
    h.press(Termisu::Input::Key::Down).should eq(:open)
    h.press(Termisu::Input::Key::Down).should eq(:open)
    h.type("acme.test").should eq(:open)
    h.press(Termisu::Input::Key::Enter).should eq(:closed)

    committed.should eq([{"include", "host", "acme.test"}])
    h.commits.should eq(1)
  end

  it "keeps the form open when on_commit reports failure (invalid pattern)" do
    ov = ScopeRuleOverlay.new(kind: "include", match_type: "host")
    h = OverlayHarness.new(ov, commit: false) # apply rejected it

    ov.set_selected(3) # Save row
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    h.commits.should eq(1) # it DID run — it just refused to close
  end

  it "esc cancels without committing" do
    h = OverlayHarness.new(ScopeRuleOverlay.adding)
    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    h.commits.should eq(0)
  end

  it "click on the Save row commits; a click outside the card dismisses" do
    h = OverlayHarness.new(ScopeRuleOverlay.new(kind: "include", match_type: "host", pattern: "acme.test"))

    # Save is row index 3 (kind/type/pattern/save); its screen row is box.y + 2 + 3.
    h.click_in_box(3, 5).should eq(:closed)
    h.commits.should eq(1)

    # A click well outside the centered card is a dismiss (no commit).
    away = OverlayHarness.new(ScopeRuleOverlay.adding)
    away.click(0, 0).should eq(:closed)
    away.commits.should eq(0)
  end

  it "wheel over the modal moves the selected field (delegates to move)" do
    ov = ScopeRuleOverlay.adding
    ov.on_save_row?.should be_false
    OverlayHarness.new(ov).wheel(3) # 3 notches down: kind → type → pattern → save
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
    ov = SequenceConfigOverlay.new(seed)
    OverlayHarness.new(ov).assert_chrome(OverlayKind::SequenceConfig, "SEQUENCER")
    # esc cancels; ↓ moves; the Start row commits — all owned by the overlay now.
    ov.as(Overlay).handle_key(skey(Termisu::Input::Key::Escape)).should eq(:cancel)
  end

  it "routes the SAME :commit to different apply behaviour purely via the injected closure" do
    # Two independent open-sites, distinguished only by their closure — the exact thing the
    # deleted @sequence_reconfigure flag used to do.
    log = [] of String

    new_h = OverlayHarness.new(SequenceConfigOverlay.new(seed))
    new_h.on_commit { log << "start_session"; true }
    reconf_h = OverlayHarness.new(SequenceConfigOverlay.new(seed))
    reconf_h.on_commit { log << "reconfigure_current"; true }

    # Drive each to Start (row 5) and commit through the generic shell dispatch.
    [new_h, reconf_h].each do |h|
      4.times { h.press(Termisu::Input::Key::Down) } # selector → … → Start
      h.overlay.as(SequenceConfigOverlay).on_start_row?.should be_true
      h.press(Termisu::Input::Key::Enter).should eq(:closed)
    end

    log.should eq(["start_session", "reconfigure_current"])
  end

  it "keeps the form open when the token location is unset (valid? gate in commit)" do
    ov = SequenceConfigOverlay.new(seed(loc: nil)) # nothing pre-filled → invalid
    ov.valid?.should be_false
    h = OverlayHarness.new(ov)
    h.on_commit { ov.valid? } # real open-site gate: reject + keep open, mirroring Runner#commit_sequence
    ov.set_selected(5)        # Start row
    h.press(Termisu::Input::Key::Enter).should eq(:open)
  end

  it "click on Start commits; a click outside dismisses" do
    h = OverlayHarness.new(SequenceConfigOverlay.new(seed))
    # Start is row index 5; its screen row is box.y + 3 + 5.
    h.click_in_box(3, 8).should eq(:closed)
    h.commits.should eq(1)

    OverlayHarness.new(SequenceConfigOverlay.new(seed)).click(0, 0).should eq(:closed)
  end

  it "routes IME preedit to the selector field (the seam's per-modal-IME promise)" do
    ov = SequenceConfigOverlay.new(seed(loc: nil)) # blank selector, opens on that row
    ov.editing_selector?.should be_true
    h = OverlayHarness.new(ov)
    # ASCII preedit so the assertion isn't defeated by the width-2 continuation cell a CJK
    # glyph leaves between codepoints in MemoryBackend#row; routing is content-agnostic.
    h.preedit("preedithere")
    h.rendered?("preedithere").should be_true
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
    ov = MineConfigOverlay.new(mseed)
    OverlayHarness.new(ov).assert_chrome(OverlayKind::MineConfig, "MINE PARAMS")
    ov.as(Overlay).handle_key(skey(Termisu::Input::Key::Escape)).should eq(:cancel)
  end

  it "commits from the Start row through the generic dispatch" do
    ov = MineConfigOverlay.new(mseed)
    h = OverlayHarness.new(ov)
    # rows: [Query, Json, concurrency, notify, Start] → 4 downs to Start.
    4.times { h.press(Termisu::Input::Key::Down) }
    ov.on_start_row?.should be_true
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    h.commits.should eq(1)
  end

  it "keeps the form open when the commit closure rejects (no location selected)" do
    ov = MineConfigOverlay.new(mseed)
    h = OverlayHarness.new(ov, commit: false) # e.g. any_checked? was false
    ov.set_selected(4)                        # Start row
    h.press(Termisu::Input::Key::Enter).should eq(:open)
  end

  it "click on a location row TOGGLES its checkbox (behaviour preserved from click_mine_config)" do
    ov = MineConfigOverlay.new(mseed)
    h = OverlayHarness.new(ov)
    before = ov.build_config.locations.includes?(Gori::Miner::Location::Query)
    # Row 0 (Query) is at box.y + 3; a click there selects AND toggles it.
    h.click_in_box(3, 3).should eq(:open)
    ov.build_config.locations.includes?(Gori::Miner::Location::Query).should_not eq(before)
  end

  it "click on Start commits; a click outside dismisses" do
    h = OverlayHarness.new(MineConfigOverlay.new(mseed))
    # Start is row index 4; its screen row is box.y + 3 + 4.
    h.click_in_box(3, 7).should eq(:closed)
    h.commits.should eq(1)

    OverlayHarness.new(MineConfigOverlay.new(mseed)).click(0, 0).should eq(:closed)
  end
end
