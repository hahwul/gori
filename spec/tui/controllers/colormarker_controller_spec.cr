require "../../support/tui_contract"

include Gori::Tui

private class ColorEditorRecordingHost < TuiContract::Host
  getter opened_rules = [] of Gori::Store::ColorRule?

  def open_colormarker_rule_editor(rule : Gori::Store::ColorRule?) : Nil
    @opened_rules << rule
  end
end

# A double-click opens the rule under the pointer, like ↵ / e — and only when the pair landed
# ON a row: in the card's empty space it used to edit whatever was highlighted.
describe "ColormarkerController double-click" do
  it "edits the rule under the pointer, and nothing off every row" do
    TuiContract.with_session("colormarker-dclick") do |session|
      session.colormarker.add("host:a.test", "red", name: "one").should be_true
      host = ColorEditorRecordingHost.new(session)
      host.tab = :colormarker
      ctl = ColormarkerController.new(host)
      backend = TuiContract.render(ctl)
      rect = TuiContract::AREA
      y = (0...rect.h).find { |row| backend.row(row).includes?("host:a.test") }.not_nil!
      ctl.handle_double_click(rect, 10, y + 2).should be_false # below the one row
      host.opened_rules.should be_empty
      ctl.handle_double_click(rect, 10, y).should be_true
      host.opened_rules.map { |r| r.try(&.name) }.should eq(["one"])
    end
  end
end

# The cursor follows the RULE across a peer's reorder. `Runner#apply_external_change` reloads
# the shared engine before the tab's `on_external_change`, so the anchor is noted first
# (`before_external_change`) — read after, it named whichever rule had slid into the slot.
describe "ColormarkerController under a peer's reorder" do
  it "keeps the highlight on the same rule, in the order the Runner reloads in" do
    TuiContract.with_session("colormarker-anchor") do |session|
      session.colormarker.add("host:a.test", "red", name: "one").should be_true
      session.colormarker.add("host:b.test", "red", name: "two").should be_true
      host = ColorEditorRecordingHost.new(session)
      host.tab = :colormarker
      ctl = ColormarkerController.new(host)
      ctl.on_enter
      TuiContract.render(ctl)
      ctl.selected_rule.not_nil!.name.should eq("one")

      ctl.before_external_change
      one = session.colormarker.rules.find! { |r| r.name == "one" }
      session.store.move_color_rule(one.id, 1).should be_true # the peer's reorder
      session.colormarker.reload                              # the Runner's, first
      ctl.on_external_change
      ctl.selected_rule.not_nil!.name.should eq("one")

      # …and across a tab entry, after ticks this tab did not see.
      TuiContract.render(ctl)
      session.store.move_color_rule(one.id, -1).should be_true
      session.colormarker.reload
      ctl.on_enter
      ctl.selected_rule.not_nil!.name.should eq("one")
    end
  end
end
