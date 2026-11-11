require "../spec_helper"
require "../support/memory_backend"
require "../../src/gori/tui/evidence_view"

include Gori::Tui

private def archive_snapshot(path : String, status : Int32 = 200) : Gori::Evidence::Snapshot
  Gori::Evidence::Snapshot.new(
    Gori::Store::LinkRefKind::Flow, 12_i64, "GET", "https://acme.test#{path}",
    "HTTP/1.1", status, 4_000_i64, nil,
    "GET #{path} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, nil,
    "HTTP/1.1 #{status} OK\r\n\r\n".to_slice, "body".to_slice)
end

private def archive_render(view : EvidenceView, width = 120, height = 12) : String
  backend = MemoryBackend.new(width, height)
  view.render(Screen.new(backend), Rect.new(0, 0, width, height), focused: true)
  (0...height).map { |y| backend.row(y) }.join('\n')
end

describe Gori::Tui::EvidenceView do
  it "lists confirmation, request, response, Issue, time and source without loading a live source" do
    with_store do |store|
      issue = store.insert_issue("confirmed SQLi", Gori::Store::Severity::High, "acme.test", nil)
      store.update_issue(issue, status: Gori::Store::Status::Confirmed).should be_true
      id, status = store.freeze_evidence(issue, archive_snapshot("/login"))
      status.ok?.should be_true

      view = EvidenceView.new
      view.reload(store)
      text = archive_render(view)
      text.should contain("##{id}")
      text.should contain("CONFIRMED")
      text.should contain("GET /login")
      text.should contain("→ 200")
      text.should contain("##{issue}")
      text.should contain("hist #12")
    end
  end

  # The archive's filter follows the other lists: at rest it rides the pane's border (the row
  # above the view's rect) with the count and size, and has a row only while it is typed in.
  it "rests its filter on the pane border and gives the row to the list" do
    with_store do |store|
      issue = store.insert_issue("auth", Gori::Store::Severity::High, "acme.test", nil)
      store.freeze_evidence(issue, archive_snapshot("/before", 500))
      view = EvidenceView.new
      view.reload(store)
      rect = Rect.new(1, 1, 118, 10)
      rest = MemoryBackend.new(120, 12)
      view.render(Screen.new(rest), rect, focused: true)
      rest.row(0).should start_with("   / filter ") # `╭─` then the label
      rest.row(0).should contain(" 1/1 · ")
      rest.row(1).should contain("CONFIRM") # the column header is the pane's first row
      view.row_at(rect, 5, 3).should eq(0)

      view.start_query
      typing = MemoryBackend.new(120, 12)
      view.render(Screen.new(typing), rect, focused: true)
      typing.row(0).strip.should be_empty
      typing.row(1).should contain("filter › ")
      typing.row(1).should contain("fields: issue:")
      view.row_at(rect, 5, 4).should eq(0) # one row lower while the bar is open
    end
  end

  it "filters live and pins a two-row before/after comparison" do
    with_store do |store|
      issue = store.insert_issue("auth", Gori::Store::Severity::High, "acme.test", nil)
      first, _ = store.freeze_evidence(issue, archive_snapshot("/before", 500))
      second, _ = store.freeze_evidence(issue, archive_snapshot("/after", 200))
      view = EvidenceView.new
      view.reload(store)

      view.start_query
      "status:5xx".each_char { |ch| view.query_insert(ch) }
      view.rows.map(&.id).should eq([first])
      view.cancel_query

      # Clearing the filter keeps the row the operator was standing on.
      view.selected_id.should eq(first)
      view.compare_step.should be_nil
      view.compare_anchor.should eq(first)
      view.move(-1)
      view.compare_step.should eq({first, second})
      view.compare_anchor.should be_nil
    end
  end

  it "starts the REQUEST column where its header says, even beside a full-width CONFIRM" do
    with_store do |store|
      issue = store.insert_issue("noise", Gori::Store::Severity::Low, "acme.test", nil)
      store.update_issue(issue, status: Gori::Store::Status::FalsePositive).should be_true
      _, status = store.freeze_evidence(issue, archive_snapshot("/login"))
      status.ok?.should be_true

      view = EvidenceView.new
      view.reload(store)
      text = archive_render(view)
      text.should contain("FALSE-POSITIVE")

      rows = text.lines
      header = rows.find!(&.includes?("REQUEST"))
      row = rows.find!(&.includes?("FALSE-POSITIVE"))

      # The widest confirmation keeps its last letter instead of being overdrawn.
      row.index("GET /login").should eq(header.index("REQUEST"))
    end
  end
end
