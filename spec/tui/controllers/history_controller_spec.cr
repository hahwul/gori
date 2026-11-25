require "../../support/tui_contract"
require "../../support/history_search"

include Gori::Tui

describe Gori::Tui::HistoryController do
  it "names the loaded subset in a capped mark toast and delete confirmation" do
    TuiContract.with_session("history-mark-cap") do |session|
      1001.times do |i|
        session.store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: i.to_i64, scheme: "http", host: "bulk.test", port: 80,
          method: "GET", target: "/#{i}", http_version: "HTTP/1.1",
          head: "GET /#{i} HTTP/1.1\r\nHost: bulk.test\r\n\r\n".to_slice, body: nil,
          source: Gori::FlowSource::Kind::Proxy))
      end
      session.store.flush
      host = TuiContract::Host.new(session)
      ctl = HistoryController.new(host)
      "host:bulk.test".each_char { |c| ctl.view.query_insert(c) }
      ctl.view.reload(session.store)
      settle_history(ctl, session.store)
      ctl.view.row_count.should eq(1000)

      ctl.history_mark_all
      host.statuses.last.should eq("1000 marked — only the loaded rows; more may match")
      ctl.history_delete
      host.confirms.last[1].should eq("Delete 1000 flows?\nOnly the loaded rows are marked; more may match the filter.\nThis can't be undone.")
    end
  end

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

  # At 80x24 the strip's footer read `… ^X hex · p pretty …`: the two view toggles had the
  # room, and the way out was cut.
  it "keeps the menu and the way out on an 80-column strip footer" do
    TuiContract.with_session("history-detail-narrow") do |session|
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
      ctl.view.detail_strip_focus?.should be_true

      fitted = Chrome.fit_hints(ctl.body_hint(:body), 57) # 80x24 beside the companion chip
      fitted.should eq("←/→ panes · ↓/↵ enter · ^X hex · space cmds · esc back")
      ctl.body_hint(:body).should contain("^R repeater · space cmds · esc back")
      ctl.body_hint(:body).should_not contain("find") # the strip's line stays as it was
    end
  end

  # ^F is the text pane's only search and the Editor scope has no menu rows, so the pane's
  # own line names it — early, since an 80-column row drops hints from the right.
  it "names ^F find on the detail text line, and keeps it at 80 columns" do
    TuiContract.with_session("history-detail-find") do |session|
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
      Chrome.fit_hints(ctl.body_hint(:body), 57).should start_with("↑/↓ move · ^F find · ")
      # Only the Runner's hard-coded ^F reaches the detail (`editor.find` is Editor-scope): a
      # keyset's own find key (vim's `/`) named here did nothing.
      prev_set, prev_os = Gori::Settings.editor_keyset, Gori::Settings.keymap_os
      begin
        Gori::Hotkeys::KEYSETS.each do |set|
          Gori::Hotkeys::PROFILES.each do |os|
            Gori::Settings.editor_keyset = set
            Gori::Settings.keymap_os = os
            ctl.body_hint(:body).should start_with("↑/↓ move · ^F find · ")
          end
        end
      ensure
        Gori::Settings.editor_keyset = prev_set
        Gori::Settings.keymap_os = prev_os
      end
    end
  end
end

private def hm_flow(store : Gori::Store, host : String, target : String) : Int64
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: host, port: 80,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil,
    source: Gori::FlowSource::Kind::Proxy))
end

private def hm_filter(ctl : HistoryController, store : Gori::Store, query : String) : Nil
  ctl.view.set_query(query)
  ctl.view.reload(store)
  settle_history(ctl, store)
end

# reports/loop #4: one mark the filter hides (`1 marked ·1 hidden`) silently turned a press on
# the visible cursor row into an action on that invisible flow. Every batch-capable verb now
# asks first, on a card that names the split and offers the cursor row alone.
private def with_hidden_mark(name : String, &)
  TuiContract.with_session(name) do |session|
    store = session.store
    hidden = hm_flow(store, "hidden.test", "/backups/db.sql.gz")
    shown = hm_flow(store, "shown.test", "/w1")
    store.flush
    host = TuiContract::Host.new(session)
    ctl = HistoryController.new(host)
    hm_filter(ctl, store, "host:hidden.test")
    ctl.history_mark_toggle
    hm_filter(ctl, store, "host:shown.test")
    ctl.view.selected_id.should eq(shown)
    ctl.view.marked_hidden_count.should eq(1)
    yield ctl, host, store, hidden, shown
  end
end

describe "HistoryController hidden-marks card" do
  it "asks before acting on a mark the filter hides, naming the split and the cursor row" do
    with_hidden_mark("history-hidden-card") do |ctl, host, _store, hidden, _shown|
      got = nil.as({Array(Int64), Bool}?)
      ctl.hidden_marks_card?("SEND TO REPEATER", "Open in Repeater") { |ids, c| got = {ids, c} }.should be_true
      host.confirms.last.should eq({"SEND TO REPEATER",
                                    "Open in Repeater 1 marked flow?\n1 marked · 1 not on the list.\nCursor row: “GET /w1”."})
      host.alt_confirms.last[2].should eq("all 1")
      host.alt_confirms.last[3].should eq("cursor row")
      got.should eq({[hidden], false})
    end
  end

  it "hands the cursor row alone to the `c` answer, and nothing to a decline" do
    with_hidden_mark("history-hidden-alt") do |ctl, host, _store, _hidden, shown|
      host.alt_answer = true
      got = nil.as({Array(Int64), Bool}?)
      ctl.hidden_marks_card?("COPY", "Copy the URLs of") { |ids, c| got = {ids, c} }
      got.should eq({[shown], true})

      host.alt_answer = nil
      got = nil
      ctl.hidden_marks_card?("COPY", "Copy the URLs of") { |ids, c| got = {ids, c} }.should be_true
      got.should be_nil
    end
  end

  it "stays out of the way while every mark is on screen" do
    with_hidden_mark("history-hidden-none") do |ctl, host, store, _hidden, _shown|
      hm_filter(ctl, store, "")
      ctl.view.marked_hidden_count.should eq(0)
      before = host.confirms.size
      ctl.hidden_marks_card?("SEND TO REPEATER", "Open in Repeater") { |_, _| }.should be_false
      host.confirms.size.should eq(before)
    end
  end

  it "has no cursor-row button when the filter shows no row at all" do
    with_hidden_mark("history-hidden-empty") do |ctl, host, store, _hidden, _shown|
      hm_filter(ctl, store, "host:nothing.test")
      ctl.view.selected_id.should be_nil
      ctl.hidden_marks_card?("ADD TO SCOPE", "Add the hosts of") { |_, _| }.should be_true
      host.alt_confirms.last[3].should be_nil
      host.confirms.last[1].should_not contain("Cursor row")
    end
  end

  it "makes the delete over a hidden mark the same card, and `c` deletes only the cursor row" do
    with_hidden_mark("history-hidden-delete") do |ctl, host, store, hidden, shown|
      host.alt_answer = true
      ctl.history_delete
      host.confirms.last.should eq({"DELETE FLOWS",
                                    "Delete 1 marked flow?\n1 marked · 1 not on the list.\nCursor row: “GET /w1”.\nThis can't be undone."})
      host.alt_confirms.last[2].should eq("delete 1")
      store.flow_row(shown).should be_nil
      store.flow_row(hidden).should_not be_nil
      host.statuses.last.should eq("flow deleted: GET /w1")
    end
  end

  it "deletes nothing when the hidden-marks delete card is declined" do
    with_hidden_mark("history-hidden-delete-no") do |ctl, host, store, hidden, shown|
      host.alt_answer = nil
      ctl.history_delete
      store.flow_row(shown).should_not be_nil
      store.flow_row(hidden).should_not be_nil
    end
  end
end
