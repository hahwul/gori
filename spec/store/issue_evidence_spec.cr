require "../spec_helper"

# Frozen issue evidence (V26, #1038): an immutable copy of one exchange, owned by an issue,
# that ordinary workbench activity — a Repeater re-send, a retention sweep, a tab close —
# can neither change nor prune. These examples pin the product contract at the store: the
# copy and its live link commit together, the copy outlives its source, and the two
# refusals (issue gone, quota) are decided inside the write rather than guessed beforehand.

private def captured(target : String, body : String? = nil) : Gori::Store::CapturedRequest
  Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: "acme.test", port: 443,
    method: body ? "POST" : "GET", target: target, http_version: "HTTP/1.1",
    head: "#{body ? "POST" : "GET"} #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
    body: body.try(&.to_slice), source: Gori::FlowSource::Kind::Proxy)
end

private def respond(store, fid : Int64, body : String = "hello") : Nil
  store.update_response(Gori::Store::CapturedResponse.new(
    fid, 200, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice, body.to_slice,
    reason: "OK", content_type: "text/plain", duration_us: 4_200_i64))
end

private def flow_snapshot(store, fid : Int64) : Gori::Evidence::Snapshot
  Gori::Evidence.from_flow(store.get_flow(fid).not_nil!)
end

private def prune_store(retention, prune_interval, &)
  path = File.tempname("gori-evidence-prune", ".db")
  db = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
  Gori::Store::Schema.migrate!(db)
  store = Gori::Store.new(db, nil, retention_flows: retention, prune_interval: prune_interval)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

describe "Store#freeze_evidence (V26)" do
  it "copies a flow's exchange with its provenance and hashes, in one write with the live link" do
    with_store do |store|
      fid = store.insert_flow(captured("/login", "u=a&p=b"))
      respond(store, fid, "welcome")
      issue = store.insert_issue("SQLi", Gori::Store::Severity::High, "acme.test", nil)
      snap = flow_snapshot(store, fid)

      id, status = store.freeze_evidence(issue, snap, link: true)
      status.should eq(Gori::Store::FreezeStatus::Ok)
      id.should be > 0

      # The live link landed in the same transaction as the copy.
      links = store.list_links(Gori::Store::LinkOwnerKind::Issue, issue)
      links.map { |l| {l.ref_kind, l.ref_id} }.should eq([{Gori::Store::LinkRefKind::Flow, fid}])

      metas = store.issue_evidence(issue)
      metas.size.should eq(1)
      m = metas[0]
      m.id.should eq(id)
      m.issue_id.should eq(issue)
      m.source_kind.should eq(Gori::Store::LinkRefKind::Flow)
      m.source_id.should eq(fid)
      m.source_label.should eq("hist ##{fid}")
      m.method.should eq("POST")
      m.url.should eq("https://acme.test/login")
      m.protocol.should eq("HTTP/1.1")
      m.status.should eq(200)
      m.duration_us.should eq(4_200_i64)
      m.error.should be_nil
      m.request_truncated?.should be_false
      m.response_truncated?.should be_false
      m.request_sha256.should eq(snap.request_sha256)
      m.response_sha256.should eq(snap.response_sha256)
      m.bytes.should eq(snap.bytes)
      # The hash is over the STORED bytes — head + body — so a reader can verify the row.
      m.request_sha256.should eq(Digest::SHA256.hexdigest(
        "POST /login HTTP/1.1\r\nHost: acme.test\r\n\r\nu=a&p=b"))
      Gori::Evidence.label(m).should eq("POST acme.test/login")

      full = store.get_evidence(id).not_nil!
      full.meta.id.should eq(id)
      String.new(full.request_head).should start_with("POST /login")
      String.new(full.request_body.not_nil!).should eq("u=a&p=b")
      String.new(full.response_head.not_nil!).should start_with("HTTP/1.1 200")
      String.new(full.response_body.not_nil!).should eq("welcome")
      store.evidence_bytes.should eq(snap.bytes)
      store.count_evidence.should eq(1)
      store.evidence_count_for(Gori::Store::LinkRefKind::Flow, fid).should eq(1)
      store.evidence_count_for(Gori::Store::LinkRefKind::Repeater, fid).should eq(0)
    end
  end

  it "keeps the copy intact after the source flow is deleted and after retention prunes it" do
    prune_store(2, 1) do |store|
      fid = store.insert_flow(captured("/a"))
      respond(store, fid)
      store.flush
      issue = store.insert_issue("t", Gori::Store::Severity::Low, nil, nil)
      id, status = store.freeze_evidence(issue, flow_snapshot(store, fid), link: true)
      status.ok?.should be_true

      # Two more captures push the source below the cap of 2 and the sweep drops it.
      store.insert_flow(captured("/b"))
      store.insert_flow(captured("/c"))
      store.flush
      store.flow_row(fid).should be_nil

      # The live link is now stale, the frozen copy is not.
      Gori::Links.resolve(store, store.list_links(Gori::Store::LinkOwnerKind::Issue, issue)[0]).stale?.should be_true
      store.get_evidence(id).not_nil!.response_body.not_nil!.should eq("hello".to_slice)
      store.issue_evidence(issue).size.should eq(1)
    end
  end

  it "keeps a Repeater snapshot when the tab is re-sent, and when the tab is closed" do
    with_store do |store|
      rid = store.insert_repeater("https://acme.test", "GET /v1 HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        false, true, nil, 0)
      store.update_repeater_response(rid, "HTTP/1.1 500 Boom\r\n\r\n".to_slice, "stack".to_slice, nil, 9_i64)
      issue = store.insert_issue("t", Gori::Store::Severity::Low, nil, nil)
      snap = Gori::Evidence.from_repeater(store.get_repeater_full(rid).not_nil!).not_nil!
      snap.status.should eq(500)
      id, status = store.freeze_evidence(issue, snap, link: true)
      status.ok?.should be_true

      # The next send replaces the tab's response — the working tab stays sendable — and
      # the copy still says 500.
      store.update_repeater_response(rid, "HTTP/1.1 200 OK\r\n\r\n".to_slice, "fixed".to_slice, nil, 5_i64)
      store.get_repeater_full(rid).not_nil!.response_body.not_nil!.should eq("fixed".to_slice)
      frozen = store.get_evidence(id).not_nil!
      frozen.meta.status.should eq(500)
      frozen.response_body.not_nil!.should eq("stack".to_slice)

      # Closing the tab cascades the LIVE link (delete_repeater's contract) and nothing else.
      store.delete_repeater(rid).should be_true
      store.list_links(Gori::Store::LinkOwnerKind::Issue, issue).should be_empty
      store.issue_evidence(issue).size.should eq(1)
      store.get_evidence(id).not_nil!.meta.source_label.should eq("repeater ##{rid}")
    end
  end

  it "keeps several snapshots on one issue, oldest first" do
    with_store do |store|
      fid = store.insert_flow(captured("/x"))
      respond(store, fid, "before")
      issue = store.insert_issue("t", Gori::Store::Severity::Low, nil, nil)
      first, _ = store.freeze_evidence(issue, flow_snapshot(store, fid))
      # A retest lands a different response on a second flow; both copies stay.
      fid2 = store.insert_flow(captured("/x"))
      respond(store, fid2, "after")
      second, _ = store.freeze_evidence(issue, flow_snapshot(store, fid2))
      store.issue_evidence(issue).map(&.id).should eq([first, second])
      store.get_evidence(first).not_nil!.response_body.not_nil!.should eq("before".to_slice)
      store.get_evidence(second).not_nil!.response_body.not_nil!.should eq("after".to_slice)
      # `link: false` (the default) filed no live link — a freeze from the RELATED row of an
      # already-linked flow must not duplicate the link, and one from a fresh issue form
      # already has it from `insert_issue`.
      store.list_links(Gori::Store::LinkOwnerKind::Issue, issue).should be_empty
    end
  end

  it "refuses inside the write when the issue is gone, and when the quota would be exceeded" do
    with_store do |store|
      fid = store.insert_flow(captured("/q"))
      respond(store, fid, "0123456789")
      snap = flow_snapshot(store, fid)

      id, status = store.freeze_evidence(999_i64, snap)
      status.should eq(Gori::Store::FreezeStatus::IssueGone)
      id.should eq(0)
      store.count_evidence.should eq(0)

      issue = store.insert_issue("t", Gori::Store::Severity::Low, nil, nil)
      # A quota exactly one copy wide: the first fits, the second does not, and the refusal
      # writes nothing — including no link, so the failed batch leaves no half.
      _, status = store.freeze_evidence(issue, snap, quota: snap.bytes)
      status.ok?.should be_true
      id, status = store.freeze_evidence(issue, snap, link: true, quota: snap.bytes)
      status.should eq(Gori::Store::FreezeStatus::Quota)
      id.should eq(0)
      store.count_evidence.should eq(1)
      store.list_links(Gori::Store::LinkOwnerKind::Issue, issue).should be_empty
    end
  end

  it "cascades with its issue on delete and on clear, and deletes one copy on request" do
    with_store do |store|
      fid = store.insert_flow(captured("/c"))
      respond(store, fid)
      a = store.insert_issue("a", Gori::Store::Severity::Low, nil, nil)
      b = store.insert_issue("b", Gori::Store::Severity::Low, nil, nil)
      ea, _ = store.freeze_evidence(a, flow_snapshot(store, fid))
      eb1, _ = store.freeze_evidence(b, flow_snapshot(store, fid))
      eb2, _ = store.freeze_evidence(b, flow_snapshot(store, fid))

      store.delete_evidence(eb1).should be_true
      store.issue_evidence(b).map(&.id).should eq([eb2])

      store.delete_issue(a).should be_true
      store.get_evidence(ea).should be_nil
      store.count_evidence.should eq(1)

      store.clear_issues.should be_true
      store.count_evidence.should eq(0)
      store.get_evidence(eb2).should be_nil
    end
  end

  it "survives the compactor's sweep of everything a project can drop" do
    with_store do |store|
      fid = store.insert_flow(captured("/keep"))
      respond(store, fid)
      issue = store.insert_issue("t", Gori::Store::Severity::Low, nil, nil)
      id, _ = store.freeze_evidence(issue, flow_snapshot(store, fid), link: true)
      store.flush
      store.clear_flows.should be_true
      store.flow_row(fid).should be_nil
      store.get_evidence(id).not_nil!.response_body.not_nil!.should eq("hello".to_slice)
    end
  end
end
