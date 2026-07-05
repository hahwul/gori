require "../spec_helper"

private def fts_store(retention = 0, prune_interval = Gori::Store::PRUNE_INTERVAL, &)
  path = File.tempname("gori-fts-spec", ".db")
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

private def req_with_body(target : String, body : String?, method = "GET", ct : String? = nil)
  head = String.build do |io|
    io << method << " " << target << " HTTP/1.1\r\nHost: h.test\r\n"
    io << "Content-Type: " << ct << "\r\n" if ct
    io << "\r\n"
  end
  Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
    method: method, target: target, http_version: "HTTP/1.1",
    head: head.to_slice, body: body.try(&.to_slice))
end

private def resp_with_body(id : Int64, body : String?, ct = "text/html", status = 200)
  Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: "HTTP/1.1 #{status} OK\r\n\r\n".to_slice,
    body: body.try(&.to_slice), content_type: ct)
end

private def body_hits(store, term : String) : Array(Int64)
  store.search(Gori::QL.parse("body:#{term}"), 10).map(&.id)
end

# A QL::Filter whose raw SQL is syntactically invalid, so SQLite raises at query
# time (the FTS/complex-phrase failure mode the raise_on_error flag guards). Built
# directly since QL.parse only emits valid SQL.
private def broken_filter : Gori::QL::Filter
  Gori::QL::Filter.new("host GLOB (", [] of DB::Any)
end

describe "query error handling (raise_on_error)" do
  it "search swallows a failed query to [] by default, but re-raises when asked" do
    fts_store do |store|
      store.search(broken_filter, 10).should eq([] of Gori::Store::FlowRow)
      expect_raises(Exception) { store.search(broken_filter, 10, raise_on_error: true) }
    end
  end

  it "sitemap_entries swallows a failed query to [] by default, but re-raises when asked" do
    fts_store do |store|
      store.sitemap_entries(broken_filter).should be_empty
      expect_raises(Exception) { store.sitemap_entries(broken_filter, raise_on_error: true) }
    end
  end
end

describe "contentless FTS (V24)" do
  it "indexes the request body while Pending (before any response)" do
    fts_store do |store|
      id = store.insert_flow(req_with_body("/a", "alpharequesttoken"))
      store.flush
      body_hits(store, "alpharequesttoken").should eq([id])
    end
  end

  it "indexes the response body after update AND keeps the request body searchable" do
    fts_store do |store|
      id = store.insert_flow(req_with_body("/b", "betarequesttoken", method: "POST"))
      store.update_response(resp_with_body(id, "gammaresponsetoken"))
      store.flush
      body_hits(store, "gammaresponsetoken").should eq([id]) # response side re-indexed
      body_hits(store, "betarequesttoken").should eq([id])   # request side survived the rewrite
    end
  end

  it "supports substring matching (the reason we keep the trigram tokenizer)" do
    fts_store do |store|
      id = store.insert_flow(req_with_body("/s", nil))
      store.update_response(resp_with_body(id, %({"api":"mysupersecretvalue"})))
      store.flush
      body_hits(store, "supersecret").should eq([id]) # matches inside the word
    end
  end

  it "skips a binary response body (never indexed)" do
    fts_store do |store|
      id = store.insert_flow(req_with_body("/c", nil))
      store.update_response(resp_with_body(id, "binaryonlytoken", ct: "application/octet-stream"))
      store.flush
      body_hits(store, "binaryonlytoken").should be_empty
    end
  end

  it "skips a content-encoded (compressed) response body — unsearchable and index-bloating" do
    fts_store do |store|
      id = store.insert_flow(req_with_body("/gz", nil))
      # A text content type, but Content-Encoding present ⇒ the stored body is compressed
      # wire bytes: high-entropy (trigram-index bloat) and impossible to body-search for
      # readable text. It must be skipped like a binary body.
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200,
        head: "HTTP/1.1 200 OK\r\ncontent-type: text/html\r\ncontent-encoding: gzip\r\n\r\n".to_slice,
        body: "compressedbodytoken".to_slice, content_type: "text/html"))
      store.flush
      body_hits(store, "compressedbodytoken").should be_empty
    end
  end

  it "skips a content-encoded request body too" do
    fts_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
        method: "POST", target: "/up", http_version: "HTTP/1.1",
        head: "POST /up HTTP/1.1\r\nHost: h.test\r\ncontent-encoding: gzip\r\n\r\n".to_slice,
        body: "gzreqtoken".to_slice))
      store.flush
      body_hits(store, "gzreqtoken").should be_empty
    end
  end

  it "still indexes an identity/uncompressed text response (regression guard)" do
    fts_store do |store|
      id = store.insert_flow(req_with_body("/id", nil))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200,
        head: "HTTP/1.1 200 OK\r\ncontent-type: text/html\r\ncontent-encoding: identity\r\n\r\n".to_slice,
        body: "identitybodytoken".to_slice, content_type: "text/html"))
      store.flush
      body_hits(store, "identitybodytoken").should eq([id]) # identity ⇒ NOT skipped
    end
  end

  it "removes FTS rows on prune (contentless range delete leaves no dangling match)" do
    fts_store(retention: 5, prune_interval: 10) do |store|
      first = store.insert_flow(req_with_body("/old", "prunedbodytoken"))
      (2..12).each { |i| store.insert_flow(req_with_body("/#{i}", "keeptoken#{i}")) }
      store.flush
      store.flow_row(first).should be_nil                 # oldest flow pruned
      body_hits(store, "prunedbodytoken").should be_empty # …and its FTS row with it
    end
  end

  it "is idempotent when the response is recorded twice (last write wins)" do
    fts_store do |store|
      id = store.insert_flow(req_with_body("/d", nil))
      store.update_response(resp_with_body(id, "firsttoken"))
      store.update_response(resp_with_body(id, "secondtoken"))
      store.flush
      body_hits(store, "secondtoken").should eq([id])
      body_hits(store, "firsttoken").should be_empty # no stale posting, no dup-rowid error
    end
  end

  it "keeps NO shadow content copy (the disk win of contentless)" do
    fts_store do |store|
      store.insert_flow(req_with_body("/e", "sometoken"))
      store.flush
      names = [] of String
      store.@db.query("SELECT name FROM sqlite_master WHERE name LIKE 'flows_fts%'") do |rs|
        rs.each { names << rs.read(String) }
      end
      names.should_not contain("flows_fts_content") # present only for content-storing FTS5
    end
  end
end
