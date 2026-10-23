require "../support/tui_contract"

include Gori::Tui

# A click on an Issues or Probe row while the `/` bar is being edited: like History's
# (`history_click_query_spec`), the click applies the query and leaves edit mode, and it lands
# on the row under the pointer on the frame that was clicked — the one drawn with the
# suggestion row up. Before, the detail opened with the bar still live behind it.

private def row_of(backend : MemoryBackend, text : String) : Int32
  TuiContract::AREA.h.times { |y| return y if backend.row(y).includes?(text) }
  raise "#{text} is not on screen"
end

describe "a list-row click while the QL bar is editing" do
  it "Issues: opens the clicked row and leaves edit mode" do
    TuiContract.with_session("issues-click-query") do |session|
      session.store.insert_issue("SQLi in /login", Gori::Store::Severity::Critical, "a.test", nil)
      host = TuiContract::Host.new(session)
      host.tab = :issues
      ctl = IssuesController.new(host)
      ctl.view.reload(session.store)
      ctl.view.start_query
      y = row_of(TuiContract.render(ctl), "SQLi in /login")
      ctl.handle_click(TuiContract::AREA, 10, y).should be_true
      ctl.view.querying?.should be_false
      ctl.view.detail_open?.should be_true
    end
  end

  it "Probe: opens the clicked row and leaves edit mode" do
    TuiContract.with_session("probe-click-query") do |session|
      session.store.upsert_probe_issue(Gori::Probe::Detection.new(
        "missing_csp", "headers", "a.test", "https://a.test/", "Missing CSP", Gori::Store::Severity::Low))
      host = TuiContract::Host.new(session)
      host.tab = :probe
      ctl = ProbeController.new(host)
      ctl.on_enter
      ctl.view.start_query
      y = row_of(TuiContract.render(ctl), "Missing CSP")
      ctl.handle_click(TuiContract::AREA, 10, y).should be_true
      ctl.view.querying?.should be_false
      ctl.view.detail_open?.should be_true
    end
  end
end
