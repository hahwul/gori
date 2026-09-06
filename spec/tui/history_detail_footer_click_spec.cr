require "../spec_helper"
require "../support/fake_host"
require "../support/memory_backend"
require "../support/history_search"
require "file_utils"
require "../../src/gori/tui/controllers/history_controller"

include Gori::Tui

# The detail drill-in's footer strip (status · sizes · latency · provenance) is a readout,
# not text. A click on it must not reach the read cursor: the text rect the hit-test walks
# stops above the strip, and a pointer past the rect used to clamp to the last text row.

private CLICK_FOOTER_CA = File.tempname("gori-click-footer-ca")
Spec.after_suite { FileUtils.rm_rf(CLICK_FOOTER_CA) }

# The shell keeps the detail OPEN state; the controller only asks which overlay is up.
private class DetailHost < FakeHost
  def overlay : Symbol
    :detail
  end
end

private def with_detail(&)
  root = File.tempname("gori-click-footer")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("clickfooter")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(CLICK_FOOTER_CA), Gori::Verbs.registry, project)
  begin
    host = DetailHost.new(session)
    ctl = HistoryController.new(host)
    id = session.store.insert_flow(Gori::Store::CapturedRequest.new(
      created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
      method: "GET", target: "/resent", http_version: "HTTP/1.1",
      head: "GET /resent HTTP/1.1\r\nHost: h.test\r\nAccept: */*\r\nX-A: 1\r\nX-B: 2\r\n\r\n".to_slice,
      body: nil, source: Gori::FlowSource::Kind::Repeater,
      source_surface: Gori::FlowSource::Surface::Tui, source_ref: "7"))
    session.store.update_response(Gori::Store::CapturedResponse.new(
      flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice, duration_us: 1_000_i64))
    session.store.flush
    ctl.view.reload(session.store)
    settle_history(ctl)
    ctl.view.open_detail(session.store).should be_true
    yield ctl
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

describe "HistoryController — a click on the detail footer strip" do
  it "leaves the read cursor where it was, while a click on the text moves it" do
    with_detail do |ctl|
      rect = Rect.new(0, 0, 100, 20)
      inner = rect.inset(1, 1)
      ctl.view.render_detail(Screen.new(MemoryBackend.new(100, 20)), inner)
      # inner rows 1..18; text from row 3; strip = divider + stats + provenance = 3 rows, so
      # the text rect ends at row 15 and the strip occupies 16, 17, 18.
      body = ctl.view.detail_text_rect(inner).not_nil!
      body.bottom.should eq(16)
      ctl.view.detail_at_top?.should be_true
      ctl.handle_click(rect, 10, 17).should be_true # the stats row
      ctl.view.detail_at_top?.should be_true
      ctl.handle_click(rect, 10, 18).should be_true # the provenance row
      ctl.view.detail_at_top?.should be_true
      ctl.handle_click(rect, 10, body.bottom - 1).should be_true # the last TEXT row
      ctl.view.detail_at_top?.should be_false
    end
  end
end
