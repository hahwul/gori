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
  it "never replaces a pre-existing issue when allocating the next id" do
    with_store do |store|
      store.@db.exec(
        "INSERT INTO issues (id, created_at, updated_at, title, severity, host, flow_id, notes, status) " \
        "VALUES (1, 1, 1, 'existing', 0, NULL, NULL, '', 0)")
      new_id = store.insert_issue("new", Gori::Store::Severity::Info, nil, nil)
      new_id.should eq(2_i64)
      store.count_issues.should eq(2)
      store.get_issue(1_i64).not_nil!.title.should eq("existing")
      store.get_issue(2_i64).not_nil!.title.should eq("new")
    end
  end

  it "creates a flow link when inserting an issue with flow_id" do
    with_store do |store|
      store.@db.scalar("PRAGMA user_version").should eq(Gori::Store::Schema::VERSION)
      fid = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "a.test", port: 80, method: "GET",
        target: "/x", http_version: "HTTP/1.1",
        head: "GET /x HTTP/1.1\r\nHost: a.test\r\n\r\n".to_slice, body: nil))
      issue_id = store.insert_issue("xss", Gori::Store::Severity::High, "a.test", fid)
      links = store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id)
      links.size.should eq(1)
      links[0].ref_kind.should eq(Gori::Store::LinkRefKind::Flow)
      links[0].ref_id.should eq(fid)
    end
  end

  it "adds, dedupes, and removes links" do
    with_store do |store|
      issue_id = store.insert_issue("t", Gori::Store::Severity::Info, nil, nil)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, issue_id,
        Gori::Store::LinkRefKind::Flow, 42_i64).should_not be_nil
      store.add_link(Gori::Store::LinkOwnerKind::Issue, issue_id,
        Gori::Store::LinkRefKind::Flow, 42_i64).should be_nil
      store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id).size.should eq(1)
      link = store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id)[0]
      store.remove_link(link.id)
      store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id).should be_empty
    end
  end

  it "cascades link deletion when an issue is deleted" do
    with_store do |store|
      issue_id = store.insert_issue("t", Gori::Store::Severity::Info, nil, nil)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, issue_id,
        Gori::Store::LinkRefKind::Repeater, 7_i64)
      store.delete_issue(issue_id)
      store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id).should be_empty
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
        "INSERT INTO issues (id, created_at, updated_at, title, severity, host, flow_id, notes, status) " \
        "VALUES (1, 5, 5, 'legacy', 2, 'a.test', ?, '', 0)", fid)
      store.@db.exec("DROP TABLE entity_links")
      store.@db.exec("DROP INDEX idx_flows_sizes")                            # V23
      store.@db.exec("DROP INDEX idx_ws_messages_replay")                      # V26 (index keeps its historical name)
      store.@db.exec("ALTER TABLE ws_messages DROP COLUMN repeater_id")         # V26
      store.@db.exec("DROP INDEX idx_h2_frames_created")                      # V27
      store.@db.exec("ALTER TABLE probe_issues DROP COLUMN sample_repeater_id") # V28
      store.@db.exec("DROP TABLE probe_suppressions")                         # V29
      store.@db.exec("ALTER TABLE match_rules DROP COLUMN part")              # V30
      store.@db.exec("ALTER TABLE repeaters DROP COLUMN tags")                  # V31
      store.@db.exec("ALTER TABLE repeaters RENAME TO replays")                 # undo V32 so historical <V32 migrations replay against the old table name
      store.@db.exec("ALTER TABLE probe_issues RENAME TO prism_issues")         # undo V33 so historical <V33 migrations replay against the old table name
      store.@db.exec("ALTER TABLE issues RENAME TO findings")                   # undo V34 so historical <V34 migrations replay against the old table name
      store.@db.exec("DROP TABLE events")                                       # V35
      store.@db.exec("DROP TABLE intercept_held")                               # V36
      store.@db.exec("DROP TABLE intercept_commands")                           # V36
      store.@db.exec("DROP TABLE probe_custom_rules")                           # V38
      store.@db.exec("PRAGMA user_version = 20")
      store.close

      store = Gori::Store.open(path)
      store.@db.scalar("PRAGMA user_version").should eq(Gori::Store::Schema::VERSION)
      links = store.list_links(Gori::Store::LinkOwnerKind::Issue, 1_i64)
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
      issue_id = store.insert_issue("t", Gori::Store::Severity::Info, nil, nil)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, issue_id,
        Gori::Store::LinkRefKind::Flow, 1_i64)
      store.@db.exec(
        "INSERT INTO entity_links (owner_kind, owner_id, ref_kind, ref_id, created_at) " \
        "VALUES ('bogus', ?, 'nope', 99, 1)", issue_id)
      links = store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id)
      links.size.should eq(1)
      links[0].ref_kind.should eq(Gori::Store::LinkRefKind::Flow)
    end
  end
end

describe Gori::Links do
  it "dedupes an issue's primary flow from the related list" do
    with_store do |store|
      fid = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "a.test", port: 80, method: "GET",
        target: "/", http_version: "HTTP/1.1",
        head: "GET / HTTP/1.1\r\nHost: a.test\r\n\r\n".to_slice))
      issue_id = store.insert_issue("t", Gori::Store::Severity::Info, nil, fid)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, issue_id,
        Gori::Store::LinkRefKind::Repeater, 3_i64)
      raw = store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id)
      raw.size.should eq(2)
      deduped = Gori::Links.dedupe_issue_flow(raw, fid)
      deduped.size.should eq(1)
      deduped[0].ref_kind.should eq(Gori::Store::LinkRefKind::Repeater)
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
