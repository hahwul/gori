require "../../spec_helper"

include Gori::Tui

private def send(view : RepeaterView, request : String, status : Int32) : Nil
  view.replace_request(request)
  view.sent_request = {view.target, view.request_text, false, true, nil}
  view.apply(Gori::Repeater::Result.new("HTTP/1.1 #{status} X\r\n\r\n".to_slice, "b#{status}".to_slice, nil, 1_i64))
end

# #1808: a tab keeps its past sends, and the PAST SENDS picker puts one back.
describe "Gori::Tui::RepeaterView send history" do
  it "restores an earlier send's request and response, and a resend appends" do
    view = RepeaterView.new
    view.load_blank
    send(view, "GET /one?t=$ENV.TOKEN HTTP/1.1\r\nHost: example.com\r\n\r\n", 200)
    send(view, "GET /two HTTP/1.1\r\nHost: example.com\r\n\r\n", 403)
    view.clear_dirty

    view.restore_send(view.send_history[0]).should be_nil
    view.request_text.should start_with("GET /one?t=$ENV.TOKEN ") # the editor's text, unexpanded
    view.status_token.should eq("200")
    view.dirty?.should be_true # the restored request is what the tab saves

    send(view, view.request_text, 500)
    view.send_history.map(&.result.head).map { |h| String.new(h)[9, 3] }.should eq(%w[200 403 500])
  end

  it "keeps the newest #{RepeaterView::SEND_HISTORY_CAP} sends" do
    view = RepeaterView.new
    view.load_blank
    (RepeaterView::SEND_HISTORY_CAP + 2).times { |i| send(view, "GET /#{i} HTTP/1.1\r\n\r\n", 200) }
    view.send_history.size.should eq(RepeaterView::SEND_HISTORY_CAP)
    view.send_history.first.request.should start_with("GET /2 ")
  end

  it "refuses while a send is in flight, and records no refused send" do
    view = RepeaterView.new
    view.load_blank
    send(view, "GET / HTTP/1.1\r\n\r\n", 200)
    view.apply(Gori::Repeater::Result.new(Bytes.empty, nil, nil, 0_i64, "blocked by scope"), remember: false)
    view.send_history.size.should eq(1)
    view.inflight = true
    view.restore_send(view.send_history[0]).should eq("a send is in flight")
  end

  it "leaves the restore one ^Z away" do
    view = RepeaterView.new
    view.load_blank
    send(view, "GET /sent HTTP/1.1\r\n\r\n", 200)
    view.replace_request("GET /unsent-edit HTTP/1.1\r\n\r\n")
    view.restore_send(view.send_history[0])
    view.focus_pane(:request)
    view.edit_undo
    view.request_text.should start_with("GET /unsent-edit ")
  end

  it "keeps a captured tab's baselines, so a typed $ENV still expands after the restore" do
    view = RepeaterView.new
    view.restore("http://h.test/", "GET / HTTP/1.1\r\nHost: h.test\r\n\r\n", false, false, evidence: true)
    before = view.evidence_send_literals
    send(view, "GET /?t=$ENV.TOKEN HTTP/1.1\r\nHost: h.test\r\n\r\n", 200)
    view.restore_send(view.send_history[0]).should be_nil
    view.evidence_send_literals.should eq(before)
  end

  it "records nothing on a WebSocket tab sent as plain HTTP" do
    ws = "GET /ws HTTP/1.1\r\nHost: h.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
         "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    view = RepeaterView.new
    view.restore("http://h.test/", ws, false, false, ws_messages: [Gori::Store::WsOutMessage.text("hi")], ws_http_only: true)
    view.sent_request = {view.target, view.request_text, false, false, nil}
    view.apply(Gori::Repeater::Result.new("HTTP/1.1 200 X\r\n\r\n".to_slice, nil, nil, 1_i64))
    view.send_history.should be_empty
  end
end
