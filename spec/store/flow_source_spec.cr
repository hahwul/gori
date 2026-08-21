require "../spec_helper"

private alias FS = Gori::FlowSource

private def tmp_store(&)
  path = File.tempname("gori-flowsrc", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    cleanup_db(path)
  end
end

private def cleanup_db(path : String)
  File.delete?(path)
  File.delete?("#{path}-wal")
  File.delete?("#{path}-shm")
end

private def captured(source : FS::Kind, surface : FS::Surface? = nil, ref : String? = nil,
                     target = "/x") : Gori::Store::CapturedRequest
  Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "t.test", port: 443,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: t.test\r\n\r\n".to_slice,
    source: source, source_surface: surface, source_ref: ref)
end

describe "flows.source (V17)" do
  it "round-trips the tool, the surface and the originating ref" do
    tmp_store do |store|
      id = store.insert_flow(captured(FS::Kind::Repeater, FS::Surface::Tui, "42"))
      row = store.flow_row(id).not_nil!
      row.source.should eq(FS::Kind::Repeater)
      row.source_surface.should eq(FS::Surface::Tui)
      row.source_ref.should eq("42")
      row.sent_by_gori?.should be_true
      # The detail projection embeds the row, so `get_flow` and MCP's serializer inherit it.
      store.get_flow(id).not_nil!.row.source.should eq(FS::Kind::Repeater)
    end
  end

  it "keeps a proxy capture's surface NULL — a client's request has no gori surface" do
    tmp_store do |store|
      row = store.flow_row(store.insert_flow(captured(FS::Kind::Proxy))).not_nil!
      row.source.should eq(FS::Kind::Proxy)
      row.source_surface.should be_nil
      row.source_ref.should be_nil
      row.sent_by_gori?.should be_false
    end
  end

  it "stamps the batch import path too, not just insert_flow" do
    # `insert_import_batch` is a second public writer and it shares `insert_one`, so this is the
    # assertion that the DTO — and not the single-insert call site — is what carries provenance.
    tmp_store do |store|
      ids = store.insert_import_batch_ids([
        {captured(FS::Kind::Import, nil, "acme.har", "/a"), nil},
        {captured(FS::Kind::Discover, FS::Surface::Cli, nil, "/b"), nil},
      ] of {Gori::Store::CapturedRequest, Gori::Store::CapturedResponse?})
      ids.size.should eq(2)
      first = store.flow_row(ids[0]).not_nil!
      first.source.should eq(FS::Kind::Import)
      first.source_ref.should eq("acme.har")
      first.sent_by_gori?.should be_false # read out of someone else's capture, not sent by gori
      store.flow_row(ids[1]).not_nil!.source.should eq(FS::Kind::Discover)
    end
  end

  it "stores every Kind so no member is unreachable through the column" do
    tmp_store do |store|
      FS::Kind.values.each do |k|
        row = store.flow_row(store.insert_flow(captured(k))).not_nil!
        row.source.should eq(k)
      end
    end
  end

  describe "a project captured before the columns existed" do
    it "upgrades to V17 leaving provenance NULL rather than guessing 'proxy'" do
      # gori was ALREADY recording repeater sends, fuzz hits, crawls and imports before this
      # migration, so a backfill would put a fact no capture produced on those rows. NULL means
      # "not recorded"; the SRC column draws it as `—` and `src:` matches it in NEITHER direction
      # (see ql_spec).
      path = build_pre_v17
      begin
        store = Gori::Store.open(path)
        begin
          rows = store.recent_flows(10)
          rows.size.should eq(2)
          rows.each do |row|
            row.source.should be_nil
            row.source_surface.should be_nil
            row.source_ref.should be_nil
            row.sent_by_gori?.should be_false # unknown must not be reported as gori's own
          end
        ensure
          store.close
        end
      ensure
        cleanup_db(path)
      end
    end

    it "records provenance on the flows written AFTER the upgrade" do
      path = build_pre_v17
      begin
        store = Gori::Store.open(path)
        begin
          id = store.insert_flow(captured(FS::Kind::Fuzzer, FS::Surface::Mcp, "job-7"))
          store.flow_row(id).not_nil!.source.should eq(FS::Kind::Fuzzer)
          # …and the pre-existing rows are still NULL beside it, which is the whole point.
          store.recent_flows(10).count(&.source.nil?).should eq(2)
        ensure
          store.close
        end
      ensure
        cleanup_db(path)
      end
    end
  end

  it "reads an unrecognised token as nil instead of raising mid-scroll" do
    # The vocabulary grows. A row written by a build that knew one more member — or hand-edited
    # in `sqlite3` — must not take the History list down; "not recorded" is the safe answer.
    path = File.tempname("gori-flowsrc-unknown", ".db")
    begin
      store = Gori::Store.open(path)
      id = store.insert_flow(captured(FS::Kind::Proxy))
      store.close
      DB.open("sqlite3:#{path}") do |db|
        db.exec("UPDATE flows SET source = 'teleporter', source_surface = 'hologram' WHERE id = ?", id)
      end
      reopened = Gori::Store.open(path)
      begin
        row = reopened.flow_row(id).not_nil!
        row.source.should be_nil
        row.source_surface.should be_nil
      ensure
        reopened.close
      end
    ensure
      cleanup_db(path)
    end
  end
end

# A database at the PRE-V17 shape, built by running V1..V16 exactly as a released gori would
# have, holding the flows an operator's existing project already contains — so `Store.open`
# drives the real V16 -> V17 upgrade over it.
private def build_pre_v17 : String
  path = File.tempname("gori-v17", ".db")
  DB.open("sqlite3:#{path}") do |db|
    db.using_connection do |c|
      Gori::Store::Schema::MIGRATIONS[0...16].each { |stmts| stmts.each { |sql| c.exec(sql) } }
      c.exec("PRAGMA user_version = 16")
      # One the proxy captured and one a `--record-history` repeater send wrote — indistinguishable
      # on disk, which is the defect V17 exists to fix and the reason neither may be backfilled.
      c.exec("INSERT INTO flows (created_at, scheme, host, port, method, target, http_version, " \
             "request_head, request_size, state, status) " \
             "VALUES (1,'https','t.test',443,'GET','/a','HTTP/1.1',?,10,1,200)",
        "GET /a HTTP/1.1\r\nHost: t.test\r\n\r\n".to_slice)
      c.exec("INSERT INTO flows (created_at, scheme, host, port, method, target, http_version, " \
             "request_head, request_size, state, status) " \
             "VALUES (2,'https','t.test',443,'POST','/b','HTTP/1.1',?,10,1,200)",
        "POST /b HTTP/1.1\r\nHost: t.test\r\n\r\n".to_slice)
    end
  end
  path
end
