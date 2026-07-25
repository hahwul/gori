require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

private def tmp_store(&)
  path = File.tempname("gori-pao", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def flow(store, method, target) : Gori::Store::FlowDetail
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice, content_type: "text/html"))
  store.get_flow(id).not_nil!
end

private def est(id : String) : Gori::Probe::Analyzer::ActiveEstimate
  info = Gori::Probe::RuleInfo.new(id, id, "desc", Gori::Probe::Category::ACTIVE)
  Gori::Probe::Analyzer::ActiveEstimate.new(info, 1..1)
end

describe Gori::Tui::ProbeActiveOverlay do
  it "hides the unsafe row when safe and unsafe estimates match (GET flow)" do
    tmp_store do |store|
      d = flow(store, "GET", "/s?q=1")
      same = [est("reflected_param")]
      ov = ProbeActiveOverlay.new(d, same, same)
      # rows: [0]=notify, [1]=run — no unsafe opt-in offered.
      ov.on_run_row?.should be_true # starts on Run
      ov.allow_unsafe?.should be_false
      ov.estimate_empty?.should be_false
      ov.move(-1) # notify row
      ov.on_run_row?.should be_false
      ov.move(-1) # clamped — there is no unsafe row to land on
      ov.on_run_row?.should be_false
    end
  end

  it "offers an off-by-default unsafe opt-in for an unsafe-method flow (POST)" do
    tmp_store do |store|
      d = flow(store, "POST", "/submit?q=1")
      safe = [] of Gori::Probe::Analyzer::ActiveEstimate # nothing runs safe-only on a POST
      unsafe = [est("reflected_param")]                  # the opt-in surfaces the reflected-param check
      ov = ProbeActiveOverlay.new(d, safe, unsafe)

      # Default: opt-in OFF, so the safe (empty) estimate is selected → nothing to send.
      ov.allow_unsafe?.should be_false
      ov.estimate_empty?.should be_true

      # rows: [0]=notify, [1]=unsafe, [2]=run. Move onto the unsafe row and flip it on.
      ov.move(-1) # from Run(2) → unsafe(1)
      ov.toggle
      ov.allow_unsafe?.should be_true
      ov.estimate_empty?.should be_false # the widened estimate now has a check to send
      ov.total_label.should eq("1 request")

      # ‹/› also toggles it back off.
      ov.adjust(-1)
      ov.allow_unsafe?.should be_false
    end
  end

  it "renders without crashing and hit-tests all three rows for a POST flow" do
    tmp_store do |store|
      d = flow(store, "POST", "/submit?q=1")
      ov = ProbeActiveOverlay.new(d, [] of Gori::Probe::Analyzer::ActiveEstimate, [est("reflected_param")])
      screen = Screen.new(MemoryBackend.new(80, 24))
      area = Rect.new(0, 0, 80, 24)
      ov.render(screen, area)
      box = ov.overlay_box(area).not_nil!
      # notify + unsafe + run are all hit-testable (row_at maps their y bands to 0/1/2).
      rows = (box.y...box.bottom).compact_map { |y| ov.row_at(box, box.x + 3, y) }.uniq!.sort!
      rows.should eq([0, 1, 2])
    end
  end

  # --- Overlay seam (see overlay.cr): the routing the Runner's generic dispatch replaced.
  # OverlayHarness replays Runner#dispatch_overlay_key / #dispatch_overlay_click.
  it "exposes the chrome the collapsed ladders used to hard-code" do
    tmp_store do |store|
      ov = ProbeActiveOverlay.new(flow(store, "GET", "/s?q=1"), [est("x")], [est("x")])
      OverlayHarness.new(ov).assert_chrome(OverlayKind::ProbeActive, "ACTIVE SCAN")
    end
  end

  it "↵ on Run commits; esc cancels without running the scan" do
    tmp_store do |store|
      same = [est("reflected_param")]
      ov = ProbeActiveOverlay.new(flow(store, "GET", "/s?q=1"), same, same)
      h = OverlayHarness.new(ov)
      ov.on_run_row?.should be_true # opens on Run
      h.press(Termisu::Input::Key::Enter).should eq(:closed)
      h.commits.should eq(1)

      esc = OverlayHarness.new(ProbeActiveOverlay.new(flow(store, "GET", "/s?q=1"), same, same))
      esc.press(Termisu::Input::Key::Escape).should eq(:closed)
      esc.commits.should eq(0)
    end
  end

  it "keeps the popup up when the closure refuses (nothing to send)" do
    tmp_store do |store|
      # A POST with the unsafe opt-in still off: start_probe_active toasts and reports false.
      ov = ProbeActiveOverlay.new(flow(store, "POST", "/submit?q=1"),
        [] of Gori::Probe::Analyzer::ActiveEstimate, [est("reflected_param")])
      h = OverlayHarness.new(ov, commit: false)
      h.press(Termisu::Input::Key::Enter).should eq(:open)
      h.commits.should eq(1) # it DID run — it just refused to close
    end
  end

  it "␣ on a non-Run row toggles instead of committing" do
    tmp_store do |store|
      ov = ProbeActiveOverlay.new(flow(store, "POST", "/submit?q=1"),
        [] of Gori::Probe::Analyzer::ActiveEstimate, [est("reflected_param")])
      h = OverlayHarness.new(ov)
      h.press(Termisu::Input::Key::Up).should eq(:open) # Run → unsafe opt-in
      h.press(Termisu::Input::Key::Space).should eq(:open)
      ov.allow_unsafe?.should be_true
      h.commits.should eq(0)
    end
  end

  it "a click on Run commits, a click on another row toggles, a click outside dismisses" do
    tmp_store do |store|
      ov = ProbeActiveOverlay.new(flow(store, "POST", "/submit?q=1"),
        [] of Gori::Probe::Analyzer::ActiveEstimate, [est("reflected_param")])
      h = OverlayHarness.new(ov)
      box = h.box.not_nil!
      first = (box.y...box.bottom).find { |y| ov.row_at(box, box.x + 3, y) == 0 }.not_nil!

      # Row 1 is the unsafe opt-in: clicking it selects + flips, and stays open.
      h.click(box.x + 3, first + 1).should eq(:open)
      ov.allow_unsafe?.should be_true
      h.commits.should eq(0)

      # Row 2 is Run.
      h.click(box.x + 3, first + 2).should eq(:closed)
      h.commits.should eq(1)

      away = OverlayHarness.new(ProbeActiveOverlay.new(flow(store, "GET", "/s?q=1"), [est("x")], [est("x")]))
      away.click(0, 0).should eq(:closed)
      away.commits.should eq(0)
    end
  end

  it "the wheel moves the selected row (base handle_wheel delegates to move)" do
    tmp_store do |store|
      ov = ProbeActiveOverlay.new(flow(store, "GET", "/s?q=1"), [est("x")], [est("x")])
      ov.on_run_row?.should be_true
      OverlayHarness.new(ov).wheel(-1) # up one notch: Run → notify
      ov.on_run_row?.should be_false
    end
  end

  it "dismisses (never runs the scan on) a click when the window is too small" do
    # The overlay_box → nil path. OverlayHarness::DEFAULT_AREA is the whole screen, so this
    # path is unreachable through the default — pass an area that actually forces it. This
    # popup sends real requests on commit, so an unrenderable card MUST cancel, matching the
    # pre-seam `return close_probe_active if box.nil?`.
    tmp_store do |store|
      tiny = Gori::Tui::Rect.new(0, 0, 29, 6)
      ov = ProbeActiveOverlay.new(flow(store, "GET", "/s?q=1"), [est("x")], [est("x")])
      ov.overlay_box(tiny).should be_nil
      ov.handle_click(tiny, 5, 3).should eq(:cancel)
      h = OverlayHarness.new(ov, area: tiny)
      h.click(5, 3).should eq(:closed)
      h.commits.should eq(0)
      h.rendered?("window too small").should be_true
    end
  end

  it "runs the scan from a click in the rect the shell passes (layout.body)" do
    # Production hands an overlay `layout.body` — 6 rows shorter and offset from the screen.
    # Asserting row_at over that box would just restate the 80x24 example above, since the
    # card fits either way; drive a real click so the smaller rect is actually load-bearing.
    tmp_store do |store|
      body = Gori::Tui::Rect.new(2, 4, 76, 18)
      ov = ProbeActiveOverlay.new(flow(store, "POST", "/submit?q=1"),
        [] of Gori::Probe::Analyzer::ActiveEstimate, [est("reflected_param")])
      h = OverlayHarness.new(ov, area: body)
      box = h.box.not_nil!
      box.y.should be > 4 # centred inside the body rect, not the screen
      first = (box.y...box.bottom).find { |y| ov.row_at(box, box.x + 3, y) == 0 }.not_nil!

      # Row 1 is the unsafe opt-in, row 2 is Run — both must hit-test against THIS box.
      h.click(box.x + 3, first + 1).should eq(:open)
      ov.allow_unsafe?.should be_true
      h.click(box.x + 3, first + 2).should eq(:closed)
      h.commits.should eq(1)
    end
  end
end
