require "../../support/tui_contract"
require "../../support/history_search"

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

  # With no flow in the project the footer named `↵ open` and `^R repeater`, two keys with
  # nothing to act on, and not the one action the card on screen offers.
  it "names the card's action, not list keys, while the project is empty" do
    TuiContract.with_session("history-footer-empty") do |session|
      ctl = HistoryController.new(TuiContract::Host.new(session))
      ctl.view.reload(session.store)
      settle_history(ctl, session.store)
      hint = ctl.body_hint(:body)
      hint.should contain("^P → Open browser")
      hint.should_not contain("repeater")
    end
  end
end

# A shell with the flow detail up, so `handle_detail_key` runs.
private class DetailUpHost < TuiContract::Host
  def overlay : Symbol
    :detail
  end
end

private def esc_key : Termisu::Event::Key
  Termisu::Event::Key.new(Termisu::Input::Key::Escape)
end

describe "HistoryController detail esc" do
  # esc steps out one level at a time: reading a response, esc is how an operator gets to the
  # strip to reach the request beside it, and it used to drop them on the list instead.
  it "goes from the text to the strip, and only the strip's esc leaves the detail" do
    TuiContract.with_session("history-detail-esc") do |session|
      id = session.store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
        method: "GET", target: "/x", http_version: "HTTP/1.1",
        head: "GET /x HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil,
        source: Gori::FlowSource::Kind::Proxy))
      session.store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
      session.store.flush
      ctl = HistoryController.new(DetailUpHost.new(session))
      ctl.view.reload(session.store)
      settle_history(ctl)
      ctl.view.open_detail(session.store).should be_true
      ctl.view.set_detail_focus(:body)

      ctl.handle_detail_key(esc_key).should be_true # claimed: text → strip
      ctl.view.detail_strip_focus?.should be_true
      ctl.handle_detail_key(esc_key).should be_false # the strip lets it reach `detail.close`
      ctl.body_hint(:body).should contain("esc back")
    end
  end
end
