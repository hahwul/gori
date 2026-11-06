require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

private def akey(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, char: char)
end

private def blank_snapshot : Gori::Tui::AdvancedSnapshot
  Gori::Tui::AdvancedSnapshot.new(
    conc: "20", rate: "", timeout: "", retries: "0", max_requests: "", race: "",
    follow: false, calibrate: false, keep_alive: true, update_cl: true, reframe_grpc: false,
    m_status: "", m_size: "", m_words: "", m_regex: "",
    f_status: "", f_size: "", f_words: "", f_regex: "")
end

# Rows are reached by KEY, never by a hardcoded index, so a new row can go in any section.
private def row_index(key : Symbol) : Int32
  FuzzAdvancedOverlay::ROWS.index! { |r| r[0] == key }
end

# ↓ presses from the first row to `key`'s: headers are stepped over, so they are not counted.
private def downs_to(key : Symbol) : Int32
  FuzzAdvancedOverlay::ROWS.reject { |r| r[2] == :header }.index! { |r| r[0] == key }
end

# A snapshot field by row key (every non-header ROWS key names an AdvancedSnapshot field).
private def field_of(snap : Gori::Tui::AdvancedSnapshot, key : Symbol) : String | Bool
  {% begin %}
    case key
    {% for ivar in Gori::Tui::AdvancedSnapshot.instance_vars %}
      when :{{ ivar.name.id }} then snap.{{ ivar.name.id }}
    {% end %}
    else raise "no snapshot field #{key}"
    end
  {% end %}
end

# The row keys whose value differs from `blank_snapshot` — "only this row was edited".
private def changed_keys(snap : Gori::Tui::AdvancedSnapshot) : Array(Symbol)
  FuzzAdvancedOverlay::ROWS.compact_map do |key, _, kind|
    key if kind != :header && field_of(snap, key) != field_of(blank_snapshot, key)
  end
end

describe Gori::Tui::FuzzAdvancedOverlay do
  it "edits the concurrency text row and reflects it in the snapshot" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    2.times { ov.handle_key(akey(Termisu::Input::Key::Backspace)) } # clear "20"
    "50".each_char { |c| ov.handle_key(akey(Termisu::Input::Key::LowerA, c)) }
    ov.snapshot.conc.should eq("50")
  end

  it "toggles a boolean row with space (←/→ on text rows never toggles it)" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    downs_to(:follow).times { ov.handle_key(akey(Termisu::Input::Key::Down)) }
    ov.handle_key(akey(Termisu::Input::Key::Space))
    ov.snapshot.follow.should be_true
  end

  it "esc returns :commit so the open-site's closure writes the snapshot back" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    ov.handle_key(akey(Termisu::Input::Key::Escape)).should eq(:commit)
  end

  it "renders every field on its own labeled row" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    backend = MemoryBackend.new(120, 30)
    ov.render(Screen.new(backend), Rect.new(0, 0, 120, 30))
    backend.contains?("ADVANCED").should be_true
    backend.contains?("Concurrency").should be_true
    backend.contains?("Match status").should be_true
    backend.contains?("Filter regex").should be_true
  end

  # --- Overlay seam (see overlay.cr): the routing the Runner's generic dispatch replaced.
  # OverlayHarness replays Runner#dispatch_overlay_key / #dispatch_overlay_click.
  it "exposes the chrome the collapsed ladders used to hard-code" do
    OverlayHarness.new(FuzzAdvancedOverlay.new(blank_snapshot)).assert_chrome(OverlayKind::FuzzAdvanced, "ADVANCED")
  end

  it "esc applies the edited snapshot through the injected closure" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    applied = [] of String
    h = OverlayHarness.new(ov)
    h.on_commit do
      applied << ov.snapshot.conc
      true
    end
    2.times { h.press(Termisu::Input::Key::Backspace) } # clear "20"
    h.type("50").should eq(:open)
    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    applied.should eq(["50"])
  end

  it "↵ advances a row and never commits, even on the LAST row" do
    # Pins the PRE-EXISTING behaviour the migration preserved: handle_key discards the
    # case's value, so ↵ never reaches the shell — only esc and a click-away apply. The
    # last row is now the `Macro on failure` text row (#1350), so ↵ there is the early return in
    # `handle_text` that keeps @sel from stepping out of ROWS' range; the toggle this example
    # used to end on (`Keep interesting only`, #1240) is asserted on its own row below.
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    h = OverlayHarness.new(ov)
    h.press(Termisu::Input::Key::Enter).should eq(:open) # first row → second
    h.commits.should eq(0)
    downs_to(:keep_interesting).times { h.press(Termisu::Input::Key::Down) }
    h.press(Termisu::Input::Key::Up) # the ↵ above already moved one row
    ov.snapshot.keep_interesting.should be_false
    h.press(Termisu::Input::Key::Enter).should eq(:open) # ↵ on a toggle row flips it
    h.commits.should eq(0)
    ov.snapshot.keep_interesting.should be_true

    last = FuzzAdvancedOverlay.new(blank_snapshot)
    lh = OverlayHarness.new(last)
    downs_to(:macro_on_failure).times { lh.press(Termisu::Input::Key::Down) }
    lh.type("stop")
    lh.press(Termisu::Input::Key::Enter).should eq(:open) # ↵ on the last (text) row: no commit, no overrun
    lh.commits.should eq(0)
    last.snapshot.macro_on_failure.should eq("stop")
  end

  it "a click outside the card APPLIES rather than dismissing" do
    # This modal has no cancel: apply_close_fuzz_advanced was the shell's click-away path too.
    away = OverlayHarness.new(FuzzAdvancedOverlay.new(blank_snapshot))
    away.click(0, 0).should eq(:closed)
    away.commits.should eq(1)
  end

  it "a click inside focuses the row under the pointer and stays open" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    h = OverlayHarness.new(ov)
    h.click_in_box(2, 1 + row_index(:follow)).should eq(:open) # rows start at box.y + 1
    h.commits.should eq(0)
    h.press(Termisu::Input::Key::Space)
    ov.snapshot.follow.should be_true
  end

  it "the wheel moves the selected row (base handle_wheel delegates to move)" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    h = OverlayHarness.new(ov)
    h.wheel(downs_to(:calibrate))
    h.press(Termisu::Input::Key::Space)
    ov.snapshot.calibrate.should be_true
    ov.snapshot.follow.should be_false
  end

  it "routes IME preedit into the focused text row" do
    h = OverlayHarness.new(FuzzAdvancedOverlay.new(blank_snapshot))
    h.preedit("한")
    h.rendered?("한").should be_true
  end

  it "APPLIES a click when the window is too small to draw the card" do
    # The overlay_box → nil path. OverlayHarness::DEFAULT_AREA is the whole screen, so this
    # path is unreachable through the default — pass an area that actually forces it. This
    # editor diverges from the base class on purpose: the pre-seam shell ran
    # `apply_close_fuzz_advanced(ov) if box.nil?`, so an unrenderable card must APPLY, and
    # the inherited :cancel would silently drop knobs the user had already edited.
    tiny = Gori::Tui::Rect.new(0, 0, 29, 6)
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    ov.overlay_box(tiny).should be_nil
    ov.handle_click(tiny, 5, 3).should eq(:commit)
    h = OverlayHarness.new(ov, area: tiny)
    h.click(5, 3).should eq(:closed)
    h.commits.should eq(1)
    h.rendered?("advanced editor").should be_true
  end

  it "toggles keep-alive, which starts on" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    ov.snapshot.keep_alive.should be_true
    downs_to(:keep_alive).times { ov.handle_key(akey(Termisu::Input::Key::Down)) }
    ov.handle_key(akey(Termisu::Input::Key::Space))
    ov.snapshot.keep_alive.should be_false
    ov.snapshot.calibrate.should be_false # the neighbouring toggles are untouched
    ov.snapshot.follow.should be_false
    ov.snapshot.update_cl.should be_true
  end

  # The gRPC reframe row is the ONE toggle on this card whose default is off, and it sits in
  # the wire section with Auto Content-Length because they are the same kind of knob pointed at
  # the two length declarations one gRPC request carries (DESIGN.md §7). It reaches the snapshot
  # like any other toggle — FuzzerView#apply_advanced is what puts it on `Fuzz::Config`.
  it "toggles gRPC reframe, which starts OFF (the headless default)" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    ov.snapshot.reframe_grpc.should be_false
    downs_to(:reframe_grpc).times { ov.handle_key(akey(Termisu::Input::Key::Down)) }
    ov.handle_key(akey(Termisu::Input::Key::Space))
    ov.snapshot.reframe_grpc.should be_true
    ov.snapshot.update_cl.should be_true # the other length knob is untouched
    ov.snapshot.keep_alive.should be_true
  end

  it "renders the gRPC reframe row with its unary caveat in the label" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    downs_to(:reframe_grpc).times { ov.handle_key(akey(Termisu::Input::Key::Down)) } # scroll it in
    backend = MemoryBackend.new(120, 30)
    ov.render(Screen.new(backend), Rect.new(0, 0, 120, 30))
    backend.contains?("gRPC reframe (unary)").should be_true
  end

  it "never focuses a row it did not draw — the hint row and the bottom border are not rows" do
    # `render` reserves the last two interior lines (the hint on box.bottom-2, the border on
    # box.bottom-1), but handle_click computed `i = my - (box.y + 1)` with no upper bound
    # beyond `ri < ROWS.size`, so a click on either selected @scroll + visible (+1) — an
    # index that was never under the cursor — and the next render scrolled to follow it.
    # Focus-only (no commit-on-row-click here), so nothing fired; still the wrong row.
    #
    # Production hands `layout.body`, which is what makes this reachable: the card clips to
    # 14 rows there, so only 11 of the ROWS are drawn. Under the harness's 80x24 default
    # every row fits and `visible == ROWS.size` hides the whole bug. The 16-row body is what
    # yields that 14-row card now that every modal insets from its area by 2.
    body = Gori::Tui::Rect.new(2, 4, 76, 16)
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    h = OverlayHarness.new(ov, area: body)
    box = h.box.not_nil!
    box.y.should eq(5) # rows run box.y+1 (6) .. 16; hint on 17, border on 18

    visible = 11 # the 14-row card's list: box.y+1 .. box.bottom-3

    h.click_in_box(2, 12).should eq(:open) # the hint row
    h.click_in_box(2, 13).should eq(:open) # the bottom border
    h.type("9")
    ov.snapshot.conc.should eq("209")            # focus never left the first row…
    changed_keys(ov.snapshot).should eq([:conc]) # …and no undrawn row took it

    # Positive control: the last drawn TEXT row is still a live click target.
    edge_i = (0...visible).to_a.reverse.find! { |i| FuzzAdvancedOverlay::ROWS[i][2] == :text }
    edge_key = FuzzAdvancedOverlay::ROWS[edge_i][0]
    edge = FuzzAdvancedOverlay.new(blank_snapshot)
    eh = OverlayHarness.new(edge, area: body)
    eh.click_in_box(2, 1 + edge_i).should eq(:open)
    eh.type("7")
    field_of(edge.snapshot, edge_key).should eq("#{field_of(blank_snapshot, edge_key)}7")
    changed_keys(edge.snapshot).should eq([edge_key])
  end

  it "offsets a click by the scroll position once the list has scrolled" do
    # Production hands an overlay `layout.body` — shorter than the screen and offset from it —
    # so this 16-row body renders a card clipped to 14 and the row list must scroll to reach the
    # bottom fields. That scroll is what makes handle_click's `@scroll + i` load-bearing:
    # @scroll only ever advances inside `render`, so a click example that never renders
    # leaves it at 0, where `@scroll + i` and plain `i` are indistinguishable.
    body = Gori::Tui::Rect.new(2, 4, 76, 16)
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    h = OverlayHarness.new(ov, area: body)
    h.box.should_not be_nil
    h.rendered?("Macro on failure").should be_false # off-screen until the list scrolls
    downs_to(:macro_on_failure).times { h.press(Termisu::Input::Key::Down) }
    h.rendered?("Macro on failure").should be_true # this render is what advances @scroll

    # The list has scrolled to its tail, so the first VISIBLE row is ROWS[size - 11], not
    # ROWS[0]. Click the first text row at least two lines down the scrolled list: a click
    # that ignored @scroll would land on an un-scrolled row near the top instead.
    scroll = FuzzAdvancedOverlay::ROWS.size - 11
    ov.@scroll.should eq(scroll)
    ti = (scroll + 2...FuzzAdvancedOverlay::ROWS.size).find! { |i| FuzzAdvancedOverlay::ROWS[i][2] == :text }
    key = FuzzAdvancedOverlay::ROWS[ti][0]
    h.click_in_box(2, 1 + ti - scroll).should eq(:open)
    h.type("9")
    field_of(ov.snapshot, key).should eq("#{field_of(blank_snapshot, key)}9")
    changed_keys(ov.snapshot).should eq([key]) # …and the un-scrolled rows stay untouched

    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    h.commits.should eq(1)
  end

  it "groups the rows into six sections, in this order" do
    sections = [] of {String, Array(String)}
    FuzzAdvancedOverlay::ROWS.each do |_, label, kind|
      kind == :header ? sections << {label, [] of String} : sections.last[1] << label
    end
    sections.should eq([
      {"engine", ["Concurrency", "Rate (rps)", "Timeout (s)", "Retries", "Max requests",
                  "Keep-alive", "Follow redirects", "Auto-calibrate"]},
      {"match", ["Match status", "Match size", "Match words", "Match time (ms)", "Match regex"]},
      {"filter", ["Filter status", "Filter size", "Filter words", "Filter time (ms)", "Filter regex"]},
      {"stop", ["Stop after N hits", "Stop on (DIM:SPEC)", "Keep interesting only"]},
      {"wire", ["Auto Content-Length", "TLS fingerprint", "Race (N conns)",
                "gRPC reframe (unary)", "gRPC field(s)"]},
      {"macro", ["Macro steps", "Macro cadence", "Macro must rebind", "Macro on failure"]},
    ])
  end

  it "draws each section header, muted, above its rows" do
    h = OverlayHarness.new(FuzzAdvancedOverlay.new(blank_snapshot), area: Gori::Tui::Rect.new(0, 0, 120, 50))
    %w[engine match filter stop wire macro].each { |s| h.rendered?("─ #{s} ─").should be_true }
  end

  it "↑/↓/⇥/⇧⇥, ↵ and the wheel never rest on a header" do
    headers = FuzzAdvancedOverlay::ROWS.each_index.select { |i| FuzzAdvancedOverlay::ROWS[i][2] == :header }.to_a
    rows = FuzzAdvancedOverlay::ROWS.size
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    seen = [ov.@sel]
    {Termisu::Input::Key::Down, Termisu::Input::Key::Tab}.each do |fwd|
      rows.times { ov.handle_key(akey(fwd)); seen << ov.@sel }
      {Termisu::Input::Key::Up, Termisu::Input::Key::BackTab}.each do |back|
        rows.times { ov.handle_key(akey(back)); seen << ov.@sel }
      end
    end
    ov.@sel.should eq(1) # clamps on the first row, under the engine header
    (seen & headers).should be_empty
    seen.uniq.sort!.should eq((0...rows).to_a - headers) # every other row is reachable

    enter = FuzzAdvancedOverlay.new(blank_snapshot)
    downs_to(:m_regex).times { enter.handle_key(akey(Termisu::Input::Key::Down)) }
    enter.handle_key(akey(Termisu::Input::Key::Enter)) # ↵ on a text row is "next"…
    enter.@sel.should eq(row_index(:f_status))         # …over the filter header

    wheel = FuzzAdvancedOverlay.new(blank_snapshot)
    wheel.handle_wheel(downs_to(:m_status))
    wheel.@sel.should eq(row_index(:m_status))
    wheel.handle_wheel(-1)
    wheel.@sel.should eq(row_index(:calibrate))
    wheel.handle_wheel(-rows)
    wheel.@sel.should eq(row_index(:conc))
  end

  it "a click on a header does nothing" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    h = OverlayHarness.new(ov, area: Gori::Tui::Rect.new(0, 0, 120, 50))
    downs_to(:m_size).times { h.press(Termisu::Input::Key::Down) }
    h.click_in_box(2, 1 + row_index(:match)).should eq(:open)
    h.click_in_box(2, 1 + row_index(:engine)).should eq(:open)
    ov.@sel.should eq(row_index(:m_size))
    h.commits.should eq(0)
  end

  it "keeps a section header on screen when ↑ reaches the section's first row" do
    body = Gori::Tui::Rect.new(2, 4, 76, 16)
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    h = OverlayHarness.new(ov, area: body)
    downs_to(:macro_on_failure).times { h.press(Termisu::Input::Key::Down) }
    h.rendered?("─ stop ─").should be_false
    (downs_to(:macro_on_failure) - downs_to(:stop_after)).times { h.press(Termisu::Input::Key::Up) }
    h.rendered?("Stop after N hits").should be_true
    h.rendered?("─ stop ─").should be_true # the header too, not just its first row
  end
end
