require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The History detail's frozen-copy marker (#1038): says a frozen copy of THIS flow exists,
# never that the flow is immutable — the flow stays deletable, linkable, sendable.
describe "HistoryView's frozen-evidence marker" do
  it "appears on the stats line once a copy exists, counts them, and refreshes in place" do
    with_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
        method: "GET", target: "/f", http_version: "HTTP/1.1",
        head: "GET /f HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil,
        source: Gori::FlowSource::Kind::Proxy))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice, body: "ok".to_slice, duration_us: 10_i64))
      view = HistoryView.new
      view.reload(store)
      view.open_detail_id(id, store).should be_true
      view.detail_frozen_count.should eq(0)
      stats_row(view).should_not contain("frozen")

      issue = store.insert_issue("t", Gori::Store::Severity::Low, nil, nil)
      snap = Gori::Evidence.from_flow(store.get_flow(id).not_nil!)
      store.freeze_evidence(issue, snap)
      store.freeze_evidence(issue, snap)
      view.refresh_evidence_marker(store)
      view.detail_frozen_count.should eq(2)
      stats_row(view).should contain("frozen ×2")

      # And a fresh open reads it without being told.
      other = HistoryView.new
      other.reload(store)
      other.open_detail_id(id, store).should be_true
      other.detail_frozen_count.should eq(2)
    end
  end
end

private def stats_row(view) : String
  backend = MemoryBackend.new(120, 16)
  view.render_detail(Screen.new(backend), Rect.new(0, 0, 120, 16))
  (0...16).map { |y| backend.row(y) }.find!(&.includes?("req "))
end
