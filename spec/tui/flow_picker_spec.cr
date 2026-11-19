require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

private def flow_row(id : Int64, method : String, host : String, target : String) : Gori::Store::FlowRow
  Gori::Store::FlowRow.new(id, 1_i64, "https", method, host, 443, target,
    200, 100_i64, Gori::Store::FlowState::Complete, 50_i64, 1_i64, "text/plain")
end

private def sample_picker(target : Symbol = :a) : FlowPicker
  FlowPicker.new([
    flow_row(1_i64, "GET", "app.test", "/login"),
    flow_row(2_i64, "POST", "api.test", "/search"),
    flow_row(3_i64, "GET", "cdn.test", "/asset.js"),
  ], target)
end

private def pick_flows_now(picker : FlowPicker) : Nil
  picker.tick(Time.instant + FlowPicker::SEARCH_DELAY + 1.millisecond)
  deadline = Time.instant + 5.seconds
  until picker.tick(Time.instant)
    raise "flow picker search did not finish" if Time.instant > deadline
    sleep 1.millisecond
  end
end

describe Gori::Tui::FlowPicker do
  it "starts on the newest row with the whole snapshot visible" do
    p = sample_picker
    p.entry_count.should eq(3)
    p.selected.should eq(0)
    p.selected_row.try(&.id).should eq(1_i64)
  end

  it "filters on method, host and path, case-insensitively" do
    p = sample_picker
    OverlayHarness.new(p).type("POST")
    p.entry_count.should eq(1)
    p.selected_row.try(&.host).should eq("api.test")
  end

  it "requires EVERY whitespace-separated term to match, not the raw string" do
    p = sample_picker
    OverlayHarness.new(p).type("get cdn")
    p.entry_count.should eq(1)
    p.selected_row.try(&.id).should eq(3_i64)
  end

  it "⌫ widens the match set again and is a no-op on an empty query" do
    p = sample_picker
    h = OverlayHarness.new(p)
    h.type("api")
    p.entry_count.should eq(1)
    h.press(Termisu::Input::Key::Backspace)
    p.entry_count.should eq(2) # "ap" → app.test and api.test, not cdn.test
    2.times { h.press(Termisu::Input::Key::Backspace) }
    p.entry_count.should eq(3)
    h.press(Termisu::Input::Key::Backspace).should eq(:open)
    p.entry_count.should eq(3)
  end

  it "clamps movement at both ends of the filtered list" do
    p = sample_picker
    p.move(-5)
    p.selected.should eq(0)
    p.move(99)
    p.selected.should eq(2)
  end

  it "renders the card heading with its target slot, and the rows" do
    h = OverlayHarness.new(sample_picker(:b))
    h.rendered?("PICK FLOW B").should be_true
    h.rendered?("app.test/login").should be_true
    h.rendered?("POST").should be_true
  end

  it "says so rather than drawing nothing when there is no flow to pick" do
    OverlayHarness.new(FlowPicker.new([] of Gori::Store::FlowRow, :a))
      .rendered?("no flows captured yet").should be_true
    h = OverlayHarness.new(sample_picker)
    h.type("zzzz")
    h.rendered?("no flows match").should be_true
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    h.commits.should eq(0)
    sample_picker.hint.should contain("↵ choose")
  end

  it "separates an empty project from one the Scope lens emptied" do
    # The Comparer draws its rows through the lens, so `@rows.empty?` stopped meaning "nothing
    # captured" — and the two readings send the operator opposite ways (hunt for lost traffic
    # vs press `s`). The link picker keeps the unlensed default and the older sentence.
    lensed = OverlayHarness.new(FlowPicker.new([] of Gori::Store::FlowRow, :a, scoped: true))
    lensed.rendered?("no flows in scope").should be_true
    lensed.rendered?("Esc, then disable Scope lens").should be_true
    lensed.rendered?("no flows captured yet").should be_false

    OverlayHarness.new(FlowPicker.new([] of Gori::Store::FlowRow, :link))
      .rendered?("no flows captured yet").should be_true
  end

  it "filters the whole store before limiting what the picker shows" do
    with_store do |store|
      ids = ["/old_%", "/old_XY", "/other", "/old_%"].each_with_index.map do |path, index|
        host = index == 3 ? "other.test" : "app.test"
        store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: index.to_i64, scheme: "https", host: host, port: 443,
          method: "GET", target: "https://#{host}#{path}", http_version: "HTTP/1.1",
          head: "GET #{path} HTTP/1.1\r\n\r\n".to_slice, body: nil,
          source: Gori::FlowSource::Kind::Proxy))
      end.to_a

      picker = FlowPicker.for_store(store, :a, Gori::QL.parse("host:app.test"), limit: 2)
      h = OverlayHarness.new(picker)
      pick_flows_now(picker)
      picker.selected_row.try(&.id).should eq(ids[2])
      h.rendered?("2 shown · refine filter").should be_true

      h.type("get /OLD_%")
      picker.selected_row.should be_nil
      h.press(Termisu::Input::Key::Enter).should eq(:open)
      pick_flows_now(picker)
      picker.entry_count.should eq(1)
      picker.selected_row.try(&.id).should eq(ids[0])
      h.rendered?("2 shown · refine filter").should be_false
    end
  end

  it "distinguishes a failed query from an empty scoped result" do
    with_store do |store|
      broken = Gori::QL::Filter.new("missing_column = 1", [] of DB::Any)
      picker = FlowPicker.for_store(store, :a, broken, scoped: true)
      pick_flows_now(picker)
      h = OverlayHarness.new(picker)
      h.rendered?("could not search flows").should be_true
      h.rendered?("no flows in scope").should be_false
    end
  end
end

# --- Overlay seam (issue #355, batch C4) ------------------------------------------
describe "FlowPicker — Overlay contract" do
  it "carries the chrome the Runner's ladder arms used to hard-code" do
    # focus_label said the literal "PICK FLOW" even though the CARD heading names the slot
    # ("PICK FLOW A" / "PICK FLOW LINK"). Keep the badge slot-agnostic.
    OverlayHarness.new(sample_picker).assert_chrome(OverlayKind::ComparerPick, "PICK FLOW")
    sample_picker(:link).title.should eq("PICK FLOW")
    sample_picker.hint.should eq("type to filter · ↑/↓ select · ↵ choose · esc cancel")
  end

  it "routes the SAME :commit to different behaviour purely via the injected closure" do
    # One picker serves the Comparer (load the flow into slot A/B) and the entity-link flow
    # (attach it to an issue/note). Before the seam that fork was `if fp.target == :link`
    # INSIDE the shared commit; now the open-site supplies it and the picker stays dumb.
    log = [] of String

    slot = OverlayHarness.new(sample_picker(:a))
    slot.on_commit { log << "set_slot"; true }
    slot.press(Termisu::Input::Key::Enter).should eq(:closed)

    link = OverlayHarness.new(sample_picker(:link))
    link.on_commit { log << "add_link"; true }
    link.press(Termisu::Input::Key::Enter).should eq(:closed)

    log.should eq(["set_slot", "add_link"])
  end

  it "↵ commits the highlighted row; esc cancels without committing" do
    ov = sample_picker
    h = OverlayHarness.new(ov)
    chosen = [] of Int64
    h.on_commit { chosen << ov.selected_row.not_nil!.id; true }
    h.press(Termisu::Input::Key::Down)
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    chosen.should eq([2_i64])

    esc = OverlayHarness.new(sample_picker)
    esc.press(Termisu::Input::Key::Escape).should eq(:closed)
    esc.commits.should eq(0)
  end

  it "keeps the card up when the commit closure reports failure" do
    h = OverlayHarness.new(sample_picker, commit: false)
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    h.commits.should eq(1) # it DID run — it just refused to close
  end

  it "routes IME preedit into the filter bar" do
    h = OverlayHarness.new(sample_picker)
    h.preedit("preedithere")
    h.rendered?("preedithere").should be_true
  end

  it "opens on an empty typed bar, then shows the live filter" do
    h = OverlayHarness.new(sample_picker)
    h.rendered?("filter › ").should be_true
    h.rendered?("type to filter").should be_false # the status row's sentence, not the card's
    h.type("ap")
    h.rendered?("filter › ap").should be_true
  end

  it "clicking a row commits it; clicking outside dismisses; the wheel scrolls" do
    ov = sample_picker
    h = OverlayHarness.new(ov)
    h.click_in_box(3, 4).should eq(:closed) # list starts at box.y + 3 → second row
    ov.selected.should eq(1)
    h.commits.should eq(1)

    away = OverlayHarness.new(sample_picker)
    away.overlay.handle_click(away.area, 0, 0).should eq(:cancel)

    scrolled = sample_picker
    OverlayHarness.new(scrolled).wheel(2)
    scrolled.selected.should eq(2)
  end
end
