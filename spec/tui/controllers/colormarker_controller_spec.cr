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

# The resting filter label rides the rules card's top border, so it is drawn only when that
# card is: on a body too short for the card (the 40x8 floor leaves two rows) it used to stand
# alone on the first row with nothing under it.
describe "ColormarkerController filter label" do
  it "rides the rules card's border, and is absent when no card is drawn" do
    TuiContract.with_session("colormarker-filter-label") do |session|
      session.colormarker.add("host:a.test", "red", name: "one").should be_true
      host = ColorEditorRecordingHost.new(session)
      host.tab = :colormarker
      ctl = ColormarkerController.new(host)
      TuiContract.render(ctl).row(0).should start_with("╭─ / filter ─")
      short = MemoryBackend.new(100, 2)
      ctl.render_body(Screen.new(short), Rect.new(0, 0, 100, 2), :body)
      (0...2).each { |y| short.row(y).should_not contain("/ filter") }
    end
  end
end

# `/` filter, the query, ↵ — the keys the operator presses.
private def cm_filter(ctl : ColormarkerController, query : String) : Nil
  ctl.colormarker_filter
  query.each_char { |c| ctl.handle_list_filter_key(TuiContract.plain(c)) }
  ctl.handle_list_filter_key(TuiContract.key(Termisu::Input::Key::Enter))
end

private def cm_controller(session : Gori::Session) : {ColormarkerController, ColorEditorRecordingHost}
  host = ColorEditorRecordingHost.new(session)
  host.tab = :colormarker
  ctl = ColormarkerController.new(host)
  ctl.on_enter
  {ctl, host}
end

# A write that puts a rule in a new row finds that row in the list ON SCREEN, or says the
# `/` query hides it. "The last row of the scope block" read off the filtered list landed on
# whatever visible rule closed the block, so the form closed silently with the highlight (and
# the next `e`) on an unrelated rule while the new one painted rows off screen.
describe "ColormarkerController writes under a `/` filter" do
  it "says an added rule is hidden and keeps the cursor on the rule it was on" do
    TuiContract.with_session("colormarker-add-hidden") do |session|
      session.colormarker.add("host:a.test", "red", name: "crlf one").should be_true
      session.colormarker.add("host:b.test", "red", name: "unrelated").should be_true
      session.colormarker.add("host:c.test", "red", name: "crlf two").should be_true
      ctl, host = cm_controller(session)
      cm_filter(ctl, "crlf")
      TuiContract.render(ctl)
      ctl.selected_rule.not_nil!.name.should eq("crlf one")

      ctl.apply_color_rule(ColormarkerRuleOverlay.new(name: "hidden-new", match_filter: "host:z.test")).should be_true
      host.statuses.last.should eq("colour rule added · hidden by /")
      ctl.selected_rule.not_nil!.name.should eq("crlf one")
    end
  end

  it "lands on an added rule the query shows, without a toast" do
    TuiContract.with_session("colormarker-add-shown") do |session|
      session.colormarker.add("host:a.test", "red", name: "crlf one").should be_true
      session.colormarker.add("host:c.test", "red", name: "crlf two").should be_true
      ctl, host = cm_controller(session)
      cm_filter(ctl, "crlf")
      TuiContract.render(ctl)
      ctl.apply_color_rule(ColormarkerRuleOverlay.new(name: "crlf new", match_filter: "host:z.test")).should be_true
      host.statuses.should be_empty # the row it lands on says so
      ctl.selected_rule.not_nil!.name.should eq("crlf new")
    end
  end

  it "says an edit that stops matching the query hid the rule" do
    TuiContract.with_session("colormarker-edit-hidden") do |session|
      session.colormarker.add("host:a.test", "red", name: "crlf one").should be_true
      session.colormarker.add("host:c.test", "red", name: "crlf two").should be_true
      ctl, host = cm_controller(session)
      cm_filter(ctl, "crlf")
      TuiContract.render(ctl)
      one = ctl.selected_rule.not_nil!
      ctl.apply_color_rule(ColormarkerRuleOverlay.new(name: "renamed", match_filter: "host:a.test",
        edit_id: one.id, edit_scope: Gori::Store::RuleScope::Project)).should be_true
      host.statuses.last.should eq("colour rule saved · hidden by /")
      ctl.selected_rule.not_nil!.name.should eq("crlf two")
    end
  end

  # #9: one list's numbers. The engine's count of every enabled rule over the filtered row
  # count read `2/1 enabled`.
  it "counts the shown rules, with the whole list's size beside them" do
    TuiContract.with_session("colormarker-count") do |session|
      session.colormarker.add("host:a.test", "red", name: "crlf one").should be_true
      session.colormarker.add("host:b.test", "red", name: "two").should be_true
      session.colormarker.add("host:c.test", "red", name: "three").should be_true
      ctl, _host = cm_controller(session)
      TuiContract.render(ctl).row(0).should contain("3/3 enabled")
      cm_filter(ctl, "crlf")
      top = TuiContract.render(ctl).row(0)
      top.should contain("1/1 enabled · 3 total")
      top.should_not contain("3/1")
    end
  end
end

private def cm_with_globals(&)
  before = Gori::Settings.colormarker_rules
  counter = Gori::Settings.colormarker_next_rule_id
  prev_home = ENV["GORI_HOME"]?
  dir = File.tempname("gori-cm-toast-globals")
  Dir.mkdir_p(dir)
  begin
    ENV["GORI_HOME"] = dir
    Gori::Settings.colormarker_rules = [] of Gori::Settings::ColormarkerRule
    Gori::Settings.colormarker_next_rule_id = 1_i64
    yield
  ensure
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    Gori::Settings.colormarker_rules = before
    Gori::Settings.colormarker_next_rule_id = counter
    FileUtils.rm_rf(dir)
  end
end

private def cm_clear_filter(ctl : ColormarkerController) : Nil
  ctl.colormarker_filter
  ctl.handle_list_filter_key(TuiContract.key(Termisu::Input::Key::Escape))
end

private def cm_pick(ctl : ColormarkerController, name : String) : Nil
  ctl.handle_wheel(-1000)
  50.times do
    break if ctl.selected_rule.try(&.name) == name
    ctl.handle_wheel(1)
  end
  ctl.selected_rule.not_nil!.name.should eq(name)
end

# Every toast fits the status row whole at 80×24 (59 columns); the remedy in words is in the
# Notifications card.
describe "ColormarkerController write toasts" do
  it "fit the 80×24 status row, with and without the hidden-by-filter suffix" do
    cm_with_globals do
      TuiContract.with_session("cm-toast-width") do |session|
        session.colormarker.add("host:a.test", "red", name: "anchor-zz", enabled: false).should be_true
        session.colormarker.add("host:a.test", "red", name: "ganchor-zz", scope: Gori::Store::RuleScope::Global, enabled: false).should be_true
        ctl, host = cm_controller(session)

        cm_pick(ctl, "ganchor-zz")
        ctl.colormarker_duplicate
        cm_pick(ctl, "anchor-zz")
        ctl.colormarker_duplicate
        cm_pick(ctl, "anchor-zz copy")
        ctl.colormarker_scope_toggle
        ctl.colormarker_scope_toggle
        host.statuses.should contain("global colour rule duplicated (disabled, like the original)")
        host.statuses.should contain("colour rule is now GLOBAL — it applies in every project")
        host.statuses.should contain("colour rule is now project-scoped")

        # "zz host" shows both anchors, never a copy ("anchor-zz copy host…") or a new rule.
        cm_filter(ctl, "zz host")
        cm_pick(ctl, "ganchor-zz")
        ctl.colormarker_duplicate
        host.statuses.last.should eq("global colour rule copied (off) · hidden by /")
        cm_pick(ctl, "anchor-zz")
        ctl.colormarker_duplicate
        host.statuses.last.should eq("colour rule copied (off) · hidden by /")
        ctl.apply_color_rule(ColormarkerRuleOverlay.new(name: "q", match_filter: "host:q.test")).should be_true
        host.statuses.last.should eq("colour rule added · hidden by /")
        ctl.apply_color_rule(ColormarkerRuleOverlay.new(name: "gq", match_filter: "host:q.test", scope: "global")).should be_true
        host.statuses.last.should eq("global colour rule added · hidden by /")

        cm_clear_filter(ctl)
        cm_filter(ctl, "project")
        cm_pick(ctl, "q")
        ctl.colormarker_scope_toggle
        host.statuses.last.should eq("colour rule now GLOBAL (all projects) · hidden by /")
        cm_clear_filter(ctl)
        cm_filter(ctl, "global")
        cm_pick(ctl, "gq")
        ctl.colormarker_scope_toggle
        host.statuses.last.should eq("colour rule now project-scoped · hidden by /")

        host.statuses.each { |toast| Screen.display_width(toast).should be <= RowFilter::TOAST_COLS }
        note = host.notifications.all.find! { |entry| entry.message == "Colormarker: colour rule added, hidden by the filter" }
        note.detail.not_nil!.should contain("/ then esc clears the filter")
      end
    end
  end
end
