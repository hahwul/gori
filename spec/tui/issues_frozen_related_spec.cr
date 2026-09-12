require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The Issues detail's RELATED card once frozen evidence (#1038) shares it with live links.
# The two are different kinds of answer to "what backs this issue" — a live row is a
# pointer that can go stale, a frozen row is the bytes — and the card must say which is
# which, keep one cursor over both, and hand the Runner the right half for ↵ and `s`.
#
# What those two keys DO with the half they are handed is issues_related_enter_spec's.

private def captured(target : String) : Gori::Store::CapturedRequest
  Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil,
    source: Gori::FlowSource::Kind::Proxy)
end

private def frozen_flow(store, target : String) : Int64
  fid = store.insert_flow(captured(target))
  store.update_response(Gori::Store::CapturedResponse.new(
    fid, 500, "HTTP/1.1 500 Boom\r\n\r\n".to_slice, "stack".to_slice, duration_us: 9_i64))
  fid
end

private def render(view, w = 100, h = 22) : MemoryBackend
  backend = MemoryBackend.new(w, h)
  view.render(Screen.new(backend), Rect.new(0, 0, w, h), focused: true)
  backend
end

describe "the Issues detail's RELATED card with frozen evidence" do
  it "lists live links first, then frozen copies, badged, with one cursor over both" do
    with_store do |store|
      live = frozen_flow(store, "/live")
      src = frozen_flow(store, "/frozen")
      issue = store.insert_issue("SQLi", Gori::Store::Severity::High, "acme.test", nil)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, issue, Gori::Store::LinkRefKind::Flow, live)
      snap = Gori::Evidence.from_flow(store.get_flow(src).not_nil!)
      eid, status = store.freeze_evidence(issue, snap)
      status.ok?.should be_true

      view = IssuesView.new
      view.reload(store)
      view.open_detail(store).should be_true
      rows = view.related_rows
      rows.size.should eq(2)
      rows[0].frozen?.should be_false
      rows[0].live.not_nil!.link.ref_id.should eq(live)
      rows[1].frozen?.should be_true
      rows[1].frozen.not_nil!.id.should eq(eid)

      # The cursor opens on the live row: ↵ there shows the flow as it is now (the LIVE half of
      # the same viewer — see issues_related_enter_spec), and there is no evidence under it.
      view.selected_resolved_link.not_nil!.link.ref_id.should eq(live)
      view.selected_evidence.should be_nil
      view.links_at_bottom?.should be_false
      view.move_links(1)
      view.selected_resolved_link.should be_nil
      view.selected_evidence.not_nil!.id.should eq(eid)
      view.links_at_bottom?.should be_true

      backend = render(view)
      rel, _ = view.detail_split(Rect.new(0, 0, 100, 22))
      live_row = backend.row(rel.y + 1)
      frozen_row = backend.row(rel.y + 2)
      live_row.should contain("LIVE")
      live_row.should contain("[hist] GET acme.test/live")
      frozen_row.should contain("FROZEN")
      frozen_row.should contain("GET acme.test/frozen · hist ##{src} ·")
      frozen_row.should contain("· 500 ·")
      # The badge is the coloured part: FROZEN in the same hue the History detail's marker uses.
      backend.fg_at(rel.x + 2, rel.y + 2).should eq(Theme.syn_header)
      backend.fg_at(rel.x + 2, rel.y + 1).should eq(Theme.muted)
      # The border count SPLITS once a frozen copy is in the card: one live pointer, one copy.
      # `2` alone was true of the row count and false of everything an operator reads it for.
      backend.row(rel.y).should contain("1 · 1 frozen · space l")
    end
  end

  it "keeps the frozen row when the source is deleted, and its live link goes with the flow" do
    # `delete_flows` cascades the flow's entity_links (a hand-delete is the operator dropping
    # the capture); the retention sweep leaves them to go stale instead — the store spec
    # pins that path. Either way the copy is untouched: it is the reason the row exists.
    with_store do |store|
      src = frozen_flow(store, "/x")
      issue = store.insert_issue("t", Gori::Store::Severity::Low, nil, nil)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, issue, Gori::Store::LinkRefKind::Flow, src)
      store.freeze_evidence(issue, Gori::Evidence.from_flow(store.get_flow(src).not_nil!))
      store.delete_flows([src]).should be_true

      view = IssuesView.new
      view.reload(store)
      view.open_detail(store).should be_true
      view.related_rows.size.should eq(1)
      view.related_rows[0].frozen?.should be_true
      view.selected_evidence.not_nil!.source_id.should eq(src)
      backend = render(view)
      rel, _ = view.detail_split(Rect.new(0, 0, 100, 22))
      backend.row(rel.y + 1).should contain("FROZEN")
      backend.row(rel.y + 1).should contain("GET acme.test/x")
      backend.row(rel.y + 1).should contain("hist ##{src}")
    end
  end

  # The border count, and the meta block that no longer competes with the card for the answer.
  # An issue filed FROM a flow and then frozen has two rows: the live primary flow it was filed
  # from, and the immutable copy. The count splits them (`1 · 1 frozen`) because a single total
  # over two kinds of row cannot say how much of the backing survives retention.
  it "counts the primary flow in the live half and keeps no `flow` meta row above the card" do
    with_store do |store|
      src = frozen_flow(store, "/only")
      issue = store.insert_issue("SQLi", Gori::Store::Severity::High, "acme.test", src)
      store.freeze_evidence(issue, Gori::Evidence.from_flow(store.get_flow(src).not_nil!))[1].ok?.should be_true

      view = IssuesView.new
      view.reload(store)
      view.open_detail(store).should be_true
      backend = render(view)
      rel, _ = view.detail_split(Rect.new(0, 0, 100, 22))
      backend.row(rel.y).should contain("1 · 1 frozen · space l")
      # The primary flow is RELATED's FIRST row, live-badged like any other pointer…
      backend.row(rel.y + 1).should contain("LIVE")
      backend.row(rel.y + 1).should contain("GET acme.test/only")
      # …and the meta block above the card says nothing about it: three rows, and none of
      # them the `flow  GET … → 500` line this pane used to draw at y3.
      rel.y.should eq(3)
      (0...3).each { |y| backend.row(y).should_not contain("flow      ") }
    end
  end

  it "leaves a link-only issue the one number it has always shown" do
    with_store do |store|
      live = frozen_flow(store, "/live")
      issue = store.insert_issue("t", Gori::Store::Severity::Low, "acme.test", nil)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, issue, Gori::Store::LinkRefKind::Flow, live)
      view = IssuesView.new
      view.reload(store)
      view.open_detail(store).should be_true
      rel, _ = view.detail_split(Rect.new(0, 0, 100, 22))
      row = render(view).row(rel.y)
      row.should contain("1 · space l")
      row.should_not contain("frozen")
    end
  end

  it "lands the cursor on a copy by id and reloads after a delete" do
    with_store do |store|
      src = frozen_flow(store, "/y")
      issue = store.insert_issue("t", Gori::Store::Severity::Low, nil, nil)
      snap = Gori::Evidence.from_flow(store.get_flow(src).not_nil!)
      a, _ = store.freeze_evidence(issue, snap)
      b, _ = store.freeze_evidence(issue, snap)
      view = IssuesView.new
      view.reload(store)
      view.open_detail(store).should be_true
      view.select_evidence(b)
      view.selected_evidence.not_nil!.id.should eq(b)
      store.delete_evidence(b).should be_true
      view.reload_detail_links(store)
      view.related_rows.size.should eq(1)
      view.selected_evidence.not_nil!.id.should eq(a) # clamped onto the survivor
    end
  end
end
