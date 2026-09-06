require "../support/tui_contract"

include Gori::Tui

# `TabController#focus_resume` — re-entering a tab's body from OUTSIDE the focus ring (↓ off
# the tab bar, a "Go to …" jump, [ ] while in the body) keeps the pane the tab was last on.
#
# It used to go through `focus_first`, which every multi-pane view answers by slamming the
# pane back to its first one: read the Fuzzer RESULTS, esc to the strip, ↓ back in — and
# you were on the URL field. `focus_first`/`focus_last` still name the ENDS of the ring for
# ⇥/⇧⇥; resume is the third entry, and it moves nothing.

describe "TabController#focus_resume" do
  it "keeps the Fuzzer pane a resume lands on, where focus_first resets it" do
    view = FuzzerView.new
    view.load_request("https://h", "GET /?x=1 HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
    view.focus_pane(:results)
    view.focus_resume
    view.focus.should eq(:results)
    view.focus_first
    view.focus.should eq(:target)
  end

  it "still leaves the ^S SNI sub-field on a resume — the rule set_focus states" do
    view = FuzzerView.new
    view.load_request("https://h", "GET /?x=1 HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
    view.focus_pane(:target)
    view.toggle_sni_field
    view.editing_sni?.should be_true
    view.focus_resume
    view.focus.should eq(:target)
    view.editing_sni?.should be_false
  end

  it "keeps the Discover pane through the controller, where focus_first resets it" do
    TuiContract.with_session("resume-discover") do |session|
      TuiContract.each_controller(session) do |controller, _host|
        next unless controller.is_a?(DiscoverController)
        run = DiscoverRun.new("http://t", Gori::Discover::Config.new)
        run.add_finding(Gori::Discover::Finding.new("http://t/a", "GET", 200, 4_i64, "text/html",
          Gori::Discover::Source::Crawled, 1, 0.95, nil))
        controller.view.add(run)
        controller.view.focus_pane(:findings)
        controller.focus_resume
        controller.view.focus.should eq(:findings)
        controller.focus_first
        controller.view.focus.should eq(:runs)
      end
    end
  end

  it "is answered by every controller without raising, before and after a render" do
    TuiContract.with_session("resume") do |session|
      TuiContract.each_controller(session) do |controller, _host|
        controller.focus_resume
        TuiContract.render(controller)
        controller.focus_last
        controller.focus_resume
        TuiContract.render(controller)
      end
    end
  end
end
