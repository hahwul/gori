require "../spec_helper"

# Schema V28 adds `repeaters.response_request_sha256` — the digest that lets a freeze tell a
# matching request/response pair from a request edited after its response arrived (#1038).
#
# The only thing a migration can get wrong here is inventing a value. A row written by an
# older gori genuinely does not know which bytes produced its stored response, and NULL is
# the honest answer: `Evidence.from_repeater` reads it as "not recorded" and leaves
# `request_drifted` false, so an upgrade neither refuses old freezes nor blesses them.

private def build_v27_repeater_db(path : String) : DB::Database
  db = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
  Gori::Store::Schema::MIGRATIONS[0...27].each do |statements|
    statements.each { |sql| db.exec(sql) }
  end
  db.exec("PRAGMA user_version = 27")
  db
end

describe "repeater response digest schema V28" do
  it "migrates a V27 project, leaving an existing response's digest NULL rather than guessing" do
    path = File.tempname("gori-repeater-v28", ".db")
    db = build_v27_repeater_db(path)
    store = nil.as(Gori::Store?)
    begin
      db.exec("INSERT INTO repeaters (created_at, updated_at, target, request, http2, " \
              "auto_content_length, position, response_head, response_body, response_duration_us) " \
              "VALUES (1, 1, 'https://legacy.test', ?, 0, 1, 0, ?, ?, 9)",
        "GET /admin HTTP/1.1\r\nHost: legacy.test\r\n\r\n".to_slice,
        "HTTP/1.1 200 OK\r\n\r\n".to_slice, "ok".to_slice)
      legacy = db.scalar("SELECT last_insert_rowid()").as(Int64)
      db.close

      store = Gori::Store.open(path)
      store.@db.scalar("PRAGMA user_version").as(Int64).should eq(Gori::Store::Schema::VERSION.to_i64)

      rec = store.get_repeater_full(legacy).not_nil!
      rec.response_request_sha256.should be_nil
      String.new(rec.response_body.not_nil!).should eq("ok") # byte-preserving, like every ALTER here

      # …and NULL is read as an unknown, not as a drift: this is the pre-upgrade freeze that
      # must keep working, with the docs' "freeze right after the send" still its only rule.
      Gori::Evidence.from_repeater(rec).not_nil!.request_drifted?.should be_false
    ensure
      store.try(&.close)
      db.close rescue nil
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end

  it "records the digest on the next send, so a project upgraded mid-test starts detecting drift" do
    with_store do |store|
      req = "POST /pay HTTP/1.1\r\nHost: a.test\r\n\r\namount=1"
      id = store.insert_repeater("https://a.test", req.to_slice, false, true, nil, 0)
      store.update_repeater_response(id, "HTTP/1.1 200 OK\r\n\r\n".to_slice, "paid".to_slice, nil, 3_i64,
        request_sha256: Gori::Evidence.request_digest(req.to_slice))
      Gori::Evidence.from_repeater(store.get_repeater_full(id).not_nil!).not_nil!
        .request_drifted?.should be_false

      # The sequence the feature exists for: edit the saved request, freeze nothing yet.
      store.update_repeater(id, "https://a.test", "POST /pay HTTP/1.1\r\nHost: a.test\r\n\r\namount=999".to_slice,
        false, true, nil)
      Gori::Evidence.from_repeater(store.get_repeater_full(id).not_nil!).not_nil!
        .request_drifted?.should be_true
    end
  end
end
