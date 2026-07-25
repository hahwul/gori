require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

# LinksOverlay is the one C4 modal that is not a plain list: adding a link is a two-step
# flow that used to span the shell as three Runner ivars (@link_add_owner /
# @link_add_ref_kind plus the picker) and a pair of close methods that rebuilt this
# overlay from scratch on every sub-picker exit. The seam has ONE @active_overlay, so the
# sub-picker is held here instead and this overlay forwards to it. These specs pin both
# halves: the browse-mode keys, and the child lifecycle.

private def flow_row(id : Int64) : Gori::Store::FlowRow
  Gori::Store::FlowRow.new(id, 1_i64, "https", "GET", "app.test", 443, "/p#{id}",
    200, 100_i64, Gori::Store::FlowState::Complete, 50_i64, 1_i64, "text/plain")
end

private def child_picker : FlowPicker
  FlowPicker.new([flow_row(1_i64), flow_row(2_i64)], :link)
end

private def links_for(store, owner_id : Int64) : LinksOverlay
  lo = LinksOverlay.new(Gori::Store::LinkOwnerKind::Issue, owner_id)
  lo.reload(store)
  lo
end

private def with_store(&)
  path = File.tempname("gori-links", ".db")
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

describe Gori::Tui::LinksOverlay do
  it "names itself after its owner and carries both mode hints" do
    lo = LinksOverlay.new(Gori::Store::LinkOwnerKind::Issue, 7_i64)
    OverlayHarness.new(lo).assert_chrome(OverlayKind::Links, "LINKS — ISSUE #7")
    LinksOverlay.new(Gori::Store::LinkOwnerKind::Note, 3_i64).title.should eq("LINKS — NOTE #3")
    lo.hint.should eq("↑/↓ · ↵/o open · a add · d remove · esc close")
  end

  it "swaps the hint when `a` arms adding (was a ternary in the Runner's ladder)" do
    lo = LinksOverlay.new(Gori::Store::LinkOwnerKind::Issue, 1_i64)
    h = OverlayHarness.new(lo)
    h.press(Termisu::Input::Key::LowerA, 'a').should eq(:open)
    lo.adding?.should be_true
    lo.hint.should eq("f/r/z/m pick type · esc back")
    h.rendered?("choose type to add…").should be_true
  end

  it "esc backs out of adding, driven with the char a real terminal sends" do
    # REGRESSION GUARD, and a warning about the harness. gori enables the Kitty keyboard
    # protocol unconditionally (app.cr), under which Escape arrives as `CSI 27 u` and the
    # parser attaches `char: '\e'`. The pre-seam shell read `ev.char || key.to_char` and
    # backed out of adding on that branch — which reads like dead code, because termisu's
    # `Key#to_char` has NO mapping for Escape, and `OverlayHarness#press(Key::Escape)`
    # defaults `char: nil`. Driving it the harness's default way builds the legacy event
    # shape the app never receives, passes, and hides a modal the keyboard cannot leave.
    lo = LinksOverlay.new(Gori::Store::LinkOwnerKind::Issue, 1_i64)
    h = OverlayHarness.new(lo)
    h.press(Termisu::Input::Key::LowerA, 'a')
    lo.adding?.should be_true
    h.press(Termisu::Input::Key::Escape, '\e').should eq(:open)
    lo.adding?.should be_false
    lo.pending_add.should be_nil
    # …and a second esc, now in browse, closes the card.
    h.press(Termisu::Input::Key::Escape, '\e').should eq(:closed)
  end

  it "backs out on a legacy bare ESC too (char nil), not just the Kitty shape" do
    lo = LinksOverlay.new(Gori::Store::LinkOwnerKind::Issue, 1_i64)
    h = OverlayHarness.new(lo)
    h.press(Termisu::Input::Key::LowerA, 'a')
    h.press(Termisu::Input::Key::Escape).should eq(:open)
    lo.adding?.should be_false
  end

  it "swallows any other key while adding rather than half-leaving the flow" do
    lo = LinksOverlay.new(Gori::Store::LinkOwnerKind::Issue, 1_i64)
    h = OverlayHarness.new(lo)
    h.press(Termisu::Input::Key::LowerA, 'a')
    h.press(Termisu::Input::Key::LowerX, 'x').should eq(:open)
    lo.adding?.should be_true
    lo.pending_add.should be_nil
  end

  it "spells out each source key on the CARD, where there is room for it" do
    # The card hint and the shell's bottom-row hint are deliberately different strings:
    # only the card has the width to say which key means which source. Collapsing them
    # onto the terse bottom-row pair silently drops the only z=fuzz / m=miner legend.
    lo = LinksOverlay.new(Gori::Store::LinkOwnerKind::Issue, 1_i64)
    h = OverlayHarness.new(lo)
    h.rendered?("↑/↓ select · ↵/o open · a add · d remove · esc close").should be_true
    lo.hint.should eq("↑/↓ · ↵/o open · a add · d remove · esc close")

    h.press(Termisu::Input::Key::LowerA, 'a')
    h.rendered?("add: f flow · r repeater · z fuzz · m miner · esc back").should be_true
    lo.hint.should eq("f/r/z/m pick type · esc back")
  end

  it "browse: k/j navigate like ↑/↓, d removes and stays, esc cancels" do
    with_store do |store|
      id = store.insert_issue("target", Gori::Store::Severity::High, "app.test", nil)
      3.times { |i| store.add_link(Gori::Store::LinkOwnerKind::Issue, id, Gori::Store::LinkRefKind::Repeater, (i + 1).to_i64) }
      lo = links_for(store, id)
      lo.count.should eq(3)

      removes = 0
      lo.on_remove = -> { removes += 1; nil }
      h = OverlayHarness.new(lo)
      h.press(Termisu::Input::Key::LowerJ).should eq(:open)
      lo.selected.should eq(1)
      h.press(Termisu::Input::Key::LowerK).should eq(:open)
      lo.selected.should eq(0)

      h.press(Termisu::Input::Key::LowerD, 'd').should eq(:open) # removing is repeatable
      removes.should eq(1)
      h.commits.should eq(0) # remove is NOT the commit action

      esc = OverlayHarness.new(lo)
      esc.press(Termisu::Input::Key::Escape).should eq(:closed)
      esc.commits.should eq(0)
    end
  end

  it "↵ and `o` are the same open action" do
    with_store do |store|
      id = store.insert_issue("target", Gori::Store::Severity::High, "app.test", nil)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, id, Gori::Store::LinkRefKind::Repeater, 7_i64)
      lo = links_for(store, id)

      enter = OverlayHarness.new(lo)
      enter.press(Termisu::Input::Key::Enter).should eq(:closed)
      enter.commits.should eq(1)

      o = OverlayHarness.new(lo)
      o.press(Termisu::Input::Key::LowerO, 'o').should eq(:closed)
      o.commits.should eq(1)
    end
  end

  it "a ↵ with nothing to open keeps the card up (the old open_selected_link guard)" do
    # Runner#open_link_target reports false in exactly this case — and also after a real
    # open, because it closes itself first so navigate_link_ref's own @overlay survives.
    lo = LinksOverlay.new(Gori::Store::LinkOwnerKind::Issue, 1_i64)
    lo.selected_link.should be_nil
    h = OverlayHarness.new(lo, commit: false)
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    h.rendered?("no links yet — press a to add").should be_true
  end

  it "row clicks open, clicks away dismiss, clicks off the list are swallowed" do
    with_store do |store|
      id = store.insert_issue("target", Gori::Store::Severity::High, "app.test", nil)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, id, Gori::Store::LinkRefKind::Repeater, 7_i64)
      lo = links_for(store, id)

      h = OverlayHarness.new(lo)
      h.click_in_box(3, 3).should eq(:closed) # list starts at box.y + 3
      h.commits.should eq(1)

      away = OverlayHarness.new(links_for(store, id))
      away.overlay.handle_click(away.area, 0, 0).should eq(:cancel)

      inside = OverlayHarness.new(links_for(store, id))
      box = inside.box.not_nil!
      inside.overlay.handle_click(inside.area, box.x, box.y).should eq(:stay)
      inside.commits.should eq(0)
    end
  end

  it "can be rebuilt on a chosen row, for the add path that never left the list" do
    # Runner#open_link_add_picker uses this when a source has nothing to link ("no fuzz
    # sessions to link"): the user never left the card, so it is rebuilt on the row they
    # were on instead of snapping to the top. The ordinary pop-back after a sub-picker
    # does start at the top, which is what the pre-seam rebuild did.
    with_store do |store|
      id = store.insert_issue("t", Gori::Store::Severity::High, "app.test", nil)
      3.times { |i| store.add_link(Gori::Store::LinkOwnerKind::Issue, id, Gori::Store::LinkRefKind::Repeater, (i + 1).to_i64) }
      lo = links_for(store, id)
      lo.selected.should eq(0)
      lo.set_selected(2)
      lo.selected.should eq(2)
      # Out of range is clamped, not an index error — the list may have shrunk meanwhile.
      lo.set_selected(99)
      lo.selected.should eq(2)
    end
  end
end

describe "LinksOverlay — the add hand-off (Overlay#on_close nested-modal seam)" do
  it "arms pending_add and reports :cancel so the shell can swap in the sub-picker" do
    # The shell holds exactly ONE modal, so this card has to go before the sub-picker
    # arrives. :cancel drops it; on_close (injected by Runner#open_links_overlay) then
    # reads pending_add and opens the picker in its place.
    lo = LinksOverlay.new(Gori::Store::LinkOwnerKind::Note, 4_i64)
    lo.pending_add.should be_nil
    h = OverlayHarness.new(lo)
    h.press(Termisu::Input::Key::LowerA, 'a').should eq(:open)
    h.press(Termisu::Input::Key::LowerR, 'r').should eq(:closed)
    lo.pending_add.should eq('r')
    h.commits.should eq(0) # arming an add is NOT the card's commit action
  end

  it "accepts each of the four source keys and only those" do
    "frzm".each_char do |k|
      lo = LinksOverlay.new(Gori::Store::LinkOwnerKind::Issue, 1_i64)
      h = OverlayHarness.new(lo)
      h.press(Termisu::Input::Key::LowerA, 'a')
      h.press(Termisu::Input::Key::LowerF, k).should eq(:closed)
      lo.pending_add.should eq(k)
    end

    other = LinksOverlay.new(Gori::Store::LinkOwnerKind::Issue, 1_i64)
    oh = OverlayHarness.new(other)
    oh.press(Termisu::Input::Key::LowerA, 'a')
    oh.press(Termisu::Input::Key::LowerX, 'x').should eq(:open) # not a source
    other.pending_add.should be_nil
    other.adding?.should be_true
  end

  it "leaves pending_add nil on every exit that is NOT an add" do
    # on_close is shared between the add hand-off and the ↵/o navigation, so a stale
    # pending_add would re-open a picker after the user simply closed the card.
    esc = LinksOverlay.new(Gori::Store::LinkOwnerKind::Issue, 1_i64)
    OverlayHarness.new(esc).press(Termisu::Input::Key::Escape).should eq(:closed)
    esc.pending_add.should be_nil

    with_store do |store|
      id = store.insert_issue("t", Gori::Store::Severity::High, "app.test", nil)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, id, Gori::Store::LinkRefKind::Repeater, 7_i64)
      open_lo = links_for(store, id)
      OverlayHarness.new(open_lo).press(Termisu::Input::Key::Enter).should eq(:closed)
      open_lo.pending_add.should be_nil
    end
  end

  it "an armed add survives as the ONLY armed exit (on_close picks one branch)" do
    # Mirrors Runner#open_links_overlay's on_close: `if pending_add … elsif opening …`.
    lo = LinksOverlay.new(Gori::Store::LinkOwnerKind::Issue, 1_i64)
    h = OverlayHarness.new(lo)
    opened = [] of String
    h.on_commit { opened << "navigate"; true }
    h.press(Termisu::Input::Key::LowerA, 'a')
    h.press(Termisu::Input::Key::LowerZ, 'z').should eq(:closed)
    lo.pending_add.should eq('z')
    opened.should be_empty # the add path must not also trigger the open path
  end
end
