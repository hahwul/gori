require "../spec_helper"

private def with_store(&)
  path = File.tempname("gori-links", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

describe "entity_links (V21)" do
  it "creates a flow link when inserting a finding with flow_id" do
    with_store do |store|
      store.@db.scalar("PRAGMA user_version").should eq(Gori::Store::Schema::VERSION)
      fid = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "a.test", port: 80, method: "GET",
        target: "/x", http_version: "HTTP/1.1",
        head: "GET /x HTTP/1.1\r\nHost: a.test\r\n\r\n".to_slice, body: nil))
      finding_id = store.insert_finding("xss", Gori::Store::Severity::High, "a.test", fid)
      links = store.list_links(Gori::Store::LinkOwnerKind::Finding, finding_id)
      links.size.should eq(1)
      links[0].ref_kind.should eq(Gori::Store::LinkRefKind::Flow)
      links[0].ref_id.should eq(fid)
    end
  end

  it "adds, dedupes, and removes links" do
    with_store do |store|
      finding_id = store.insert_finding("t", Gori::Store::Severity::Info, nil, nil)
      store.add_link(Gori::Store::LinkOwnerKind::Finding, finding_id,
        Gori::Store::LinkRefKind::Flow, 42_i64).should_not be_nil
      store.add_link(Gori::Store::LinkOwnerKind::Finding, finding_id,
        Gori::Store::LinkRefKind::Flow, 42_i64).should be_nil
      store.list_links(Gori::Store::LinkOwnerKind::Finding, finding_id).size.should eq(1)
      link = store.list_links(Gori::Store::LinkOwnerKind::Finding, finding_id)[0]
      store.remove_link(link.id)
      store.list_links(Gori::Store::LinkOwnerKind::Finding, finding_id).should be_empty
    end
  end

  it "cascades link deletion when a finding is deleted" do
    with_store do |store|
      finding_id = store.insert_finding("t", Gori::Store::Severity::Info, nil, nil)
      store.add_link(Gori::Store::LinkOwnerKind::Finding, finding_id,
        Gori::Store::LinkRefKind::Replay, 7_i64)
      store.delete_finding(finding_id)
      store.list_links(Gori::Store::LinkOwnerKind::Finding, finding_id).should be_empty
    end
  end

  it "backfills flow links when upgrading from V20" do
    path = File.tempname("gori-v20-links", ".db")
    begin
      store = Gori::Store.open(path)
      fid = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 5_i64, scheme: "http", host: "a.test", port: 80, method: "GET",
        target: "/old", http_version: "HTTP/1.1",
        head: "GET /old HTTP/1.1\r\nHost: a.test\r\n\r\n".to_slice))
      store.@db.exec(
        "INSERT INTO findings (id, created_at, updated_at, title, severity, host, flow_id, notes, status) " \
        "VALUES (1, 5, 5, 'legacy', 2, 'a.test', ?, '', 0)", fid)
      store.@db.exec("DROP TABLE entity_links")
      store.@db.exec("ALTER TABLE replays DROP COLUMN mark_transform") # V22 (added a column to a pre-V17 table)
      store.@db.exec("DROP INDEX idx_flows_sizes")                     # V23
      store.@db.exec("DROP INDEX idx_ws_messages_replay")              # V26
      store.@db.exec("ALTER TABLE ws_messages DROP COLUMN replay_id")  # V26
      store.@db.exec("DROP INDEX idx_h2_frames_created")               # V27
      store.@db.exec("ALTER TABLE prism_issues DROP COLUMN sample_replay_id") # V28
      store.@db.exec("DROP TABLE prism_suppressions")                  # V29
      store.@db.exec("PRAGMA user_version = 20")
      store.close

      store = Gori::Store.open(path)
      store.@db.scalar("PRAGMA user_version").should eq(Gori::Store::Schema::VERSION)
      links = store.list_links(Gori::Store::LinkOwnerKind::Finding, 1_i64)
      links.size.should eq(1)
      links[0].ref_kind.should eq(Gori::Store::LinkRefKind::Flow)
      links[0].ref_id.should eq(fid)
      store.close
    ensure
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end

  it "skips corrupt entity_links rows with unknown kinds" do
    with_store do |store|
      finding_id = store.insert_finding("t", Gori::Store::Severity::Info, nil, nil)
      store.add_link(Gori::Store::LinkOwnerKind::Finding, finding_id,
        Gori::Store::LinkRefKind::Flow, 1_i64)
      store.@db.exec(
        "INSERT INTO entity_links (owner_kind, owner_id, ref_kind, ref_id, created_at) " \
        "VALUES ('bogus', ?, 'nope', 99, 1)", finding_id)
      links = store.list_links(Gori::Store::LinkOwnerKind::Finding, finding_id)
      links.size.should eq(1)
      links[0].ref_kind.should eq(Gori::Store::LinkRefKind::Flow)
    end
  end
end

describe Gori::Links do
  it "dedupes a finding's primary flow from the related list" do
    with_store do |store|
      fid = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "a.test", port: 80, method: "GET",
        target: "/", http_version: "HTTP/1.1",
        head: "GET / HTTP/1.1\r\nHost: a.test\r\n\r\n".to_slice))
      finding_id = store.insert_finding("t", Gori::Store::Severity::Info, nil, fid)
      store.add_link(Gori::Store::LinkOwnerKind::Finding, finding_id,
        Gori::Store::LinkRefKind::Replay, 3_i64)
      raw = store.list_links(Gori::Store::LinkOwnerKind::Finding, finding_id)
      raw.size.should eq(2)
      deduped = Gori::Links.dedupe_finding_flow(raw, fid)
      deduped.size.should eq(1)
      deduped[0].ref_kind.should eq(Gori::Store::LinkRefKind::Replay)
    end
  end
end

describe "Notes stable ids" do
  it "assigns ids when parsing a legacy plain-string notes array" do
    doc = Gori::Notes.parse(%({"cur":0,"notes":["alpha","beta"]}))
    doc.should eq(Gori::Notes::Doc.new(0, [
      Gori::Notes::NoteEntry.new(1_i64, "alpha"),
      Gori::Notes::NoteEntry.new(2_i64, "beta"),
    ], 3_i64))
  end
end
