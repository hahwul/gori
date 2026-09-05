require "../spec_helper"
require "../support/fake_host"
require "../support/memory_backend"
require "../support/history_search"
require "file_utils"
require "../../src/gori/tui/controllers/history_controller"

include Gori::Tui

# A click on a History row while the QL bar is being edited: the click also applies the query
# and leaves edit mode, like ↵ — and the row it selects has to be the row under the pointer on
# the frame the operator clicked, which was drawn with the suggestion row up.

private CLICK_QUERY_CA = File.tempname("gori-click-query-ca")
Spec.after_suite { FileUtils.rm_rf(CLICK_QUERY_CA) }

private def char_key(c : Char) : Termisu::Event::Key
  Termisu::Event::Key.new(Termisu::Input::Key::LowerA, char: c)
end

private def with_history(&)
  root = File.tempname("gori-click-query")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("clickquery")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(CLICK_QUERY_CA), Gori::Verbs.registry, project)
  prev = Gori::Settings.history_preview
  begin
    Gori::Settings.history_preview = false
    host = FakeHost.new(session)
    ctl = HistoryController.new(host)
    (0...4).each do |i|
      session.store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64 + i, scheme: "http", host: "h.test", port: 80,
        method: "GET", target: "/#{i}", http_version: "HTTP/1.1",
        head: "GET /#{i} HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
    end
    session.store.flush
    ctl.view.reload(session.store)
    settle_history(ctl)
    yield ctl
  ensure
    Gori::Settings.history_preview = prev
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

describe "HistoryController — a row click while the QL bar is editing" do
  it "selects the row under the pointer on the frame that was clicked, then leaves edit mode" do
    with_history do |ctl|
      rect = Rect.new(0, 0, 80, 24)
      ctl.view.render_list(Screen.new(MemoryBackend.new(80, 24)), rect)
      ctl.view.selected_index.should eq(0)
      ctl.view.start_query
      # Painted while querying: frame (1) + bar (1) + suggestion row (1) + header (1) + divider (1)
      # — the first flow row is screen row 5, so row 2 sits at y = 7. Hit-testing after
      # `stop_query` dropped the suggestion row and landed one row below the pointer.
      ctl.handle_click(rect, 10, 7).should be_true
      ctl.view.querying?.should be_false
      ctl.view.selected_index.should eq(2)
    end
  end

  it "carries the clicked row by id across the reload the click applies" do
    with_history do |ctl|
      rect = Rect.new(0, 0, 80, 24)
      ctl.view.render_list(Screen.new(MemoryBackend.new(80, 24)), rect)
      ctl.view.start_query
      # Type a filter that keeps only /3 and /2; the debounced reload is still pending when the
      # click lands, so the frame under the pointer still shows all four rows.
      "path:/3 OR path:/2".each_char { |ch| ctl.handle_query_key(char_key(ch)) }
      ctl.view.row_id_at(3).should_not be_nil # still four rows: the reload has not run
      before = ctl.view.row_id_at(1).not_nil!
      ctl.handle_click(rect, 10, 6).should be_true # screen row 6 = list row 1 while querying
      ctl.view.querying?.should be_false
      settle_history(ctl)
      ctl.view.row_id_at(2).should be_nil # the applied query left two rows
      ctl.view.selected_id.should eq(before)
    end
  end
end
