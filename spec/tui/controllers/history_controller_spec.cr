require "../../support/tui_contract"

include Gori::Tui

describe Gori::Tui::HistoryController do
  # The toast, the tab and the tour all say "intercept"; the footer said "hold-mode".
  it "names the intercept key `intercept` in the list footer" do
    TuiContract.with_session("history-footer") do |session|
      ctl = HistoryController.new(TuiContract::Host.new(session))
      hint = ctl.body_hint(:body)
      hint.should contain("i intercept")
      hint.should_not contain("hold-mode")
    end
  end
end
