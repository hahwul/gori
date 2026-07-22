require "./spec_helper"

private def with_store(&)
  path = File.tempname("gori-repeaters", ".db")
  store = Gori::Store.open(path)
  begin
    yield store, path
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

describe "Gori::Store repeater tabs (v9)" do
  it "round-trips insert → load" do
    with_store do |store|
      store.repeaters.should be_empty
      id = store.insert_repeater("https://a.test", "GET / HTTP/1.1\r\n\r\n".to_slice, false, true, 7_i64, 0)
      id.should be > 0

      rows = store.repeaters
      rows.size.should eq(1)
      r = rows.first
      r.id.should eq(id)
      r.target.should eq("https://a.test")
      r.request.should eq("GET / HTTP/1.1\r\n\r\n".to_slice)
      r.http2?.should be_false
      r.auto_content_length?.should be_true
      r.flow_id.should eq(7_i64)
      r.position.should eq(0)
    end
  end

  it "round-trips the http2 + auto_content_length flags and a NULL flow_id" do
    with_store do |store|
      id = store.insert_repeater("http://h2.test", "POST / HTTP/2\r\n\r\n".to_slice, true, false, nil, 0)
      r = store.repeaters.find!(&.id.==(id))
      r.http2?.should be_true
      r.auto_content_length?.should be_false
      r.flow_id.should be_nil
    end
  end

  it "updates a tab in place" do
    with_store do |store|
      id = store.insert_repeater("https://a.test", "GET / HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 0)
      store.update_repeater(id, "https://b.test", "PUT /x HTTP/1.1\r\n\r\n".to_slice, true, false)
      r = store.repeaters.find!(&.id.==(id))
      r.target.should eq("https://b.test")
      r.request.should eq("PUT /x HTTP/1.1\r\n\r\n".to_slice)
      r.http2?.should be_true
      r.auto_content_length?.should be_false
    end
  end

  it "deletes a tab" do
    with_store do |store|
      id = store.insert_repeater("https://a.test", "GET / HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 0)
      store.delete_repeater(id)
      store.repeaters.should be_empty
    end
  end

  it "orders by position then id (id breaks a position tie)" do
    with_store do |store|
      a = store.insert_repeater("https://a.test", "a".to_slice, false, true, nil, 2)
      b = store.insert_repeater("https://b.test", "b".to_slice, false, true, nil, 0)
      c = store.insert_repeater("https://c.test", "c".to_slice, false, true, nil, 0) # tie with b → id breaks it
      store.repeaters.map(&.id).should eq([b, c, a])
    end
  end

  it "starts a fresh tab with no persisted response (V11 columns NULL)" do
    with_store do |store|
      id = store.insert_repeater("https://a.test", "GET / HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 0)
      r = store.repeaters.find!(&.id.==(id))
      r.response_head.should be_nil
      r.response_body.should be_nil
      r.response_error.should be_nil
      r.response_duration_us.should be_nil
    end
  end

  it "round-trips a persisted last response (head + body + duration)" do
    with_store do |store|
      id = store.insert_repeater("https://a.test", "GET / HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 0)
      head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice
      body = "PONG".to_slice
      store.update_repeater_response(id, head, body, nil, 4200_i64)
      r = store.repeaters.find!(&.id.==(id))
      String.new(r.response_head.not_nil!).should eq("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n")
      String.new(r.response_body.not_nil!).should eq("PONG")
      r.response_error.should be_nil
      r.response_duration_us.should eq(4200_i64)
      # the request side is untouched by a response write
      r.request.should eq("GET / HTTP/1.1\r\n\r\n".to_slice)
    end
  end

  it "repeaters_meta omits the response BLOBs (lighter reconcile poll)" do
    with_store do |store|
      id = store.insert_repeater("https://a.test", "GET / HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 0)
      store.update_repeater_response(id, "HTTP/1.1 200 OK\r\n\r\n".to_slice, "body".to_slice, nil, 1_i64)
      meta = store.repeaters_meta.find!(&.id.==(id))
      meta.response_head.should be_nil # not loaded by the metadata query
      meta.response_body.should be_nil
      meta.target.should eq("https://a.test")                            # request side intact
      store.repeaters.find!(&.id.==(id)).response_head.should_not be_nil # full query still carries it
    end
  end

  it "persists an errored send (empty head, nil body, error text)" do
    with_store do |store|
      id = store.insert_repeater("https://a.test", "GET / HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 0)
      store.update_repeater_response(id, Bytes.empty, nil, "connect failed: a.test:443", 0_i64)
      r = store.repeaters.find!(&.id.==(id))
      r.response_body.should be_nil
      r.response_error.should eq("connect failed: a.test:443")
    end
  end

  it "reads a legacy row whose `request` was bound as a Crystal String (TEXT storage " \
     "class), the way an out-of-date gori writer bound it before the V2 fix" do
    with_store do |store, path|
      # Bypass insert_repeater (always binds Bytes) to reproduce a row written by a
      # mismatched-version writer still on the pre-V2 String bind — e.g. a long-lived
      # `gori mcp`/TUI process running an out-of-date binary against an
      # already-migrated project db. SQLite stores a String bind as TEXT storage class
      # even in a column declared/affinity TEXT-or-BLOB; reading it back as Bytes used
      # to raise an unhandled DB::ColumnTypeMismatchError. The body carries an embedded
      # NUL byte — the exact historical failure mode the V2 migration's own comment
      # describes (a single-arg `String.new(ptr)` read stops at the first 0x00) — so
      # this also guards against a future regression to a String-based (not CAST'd)
      # read silently truncating instead of raising.
      raw = DB.open("sqlite3:#{path}")
      begin
        now = Time.utc.to_unix_ms.to_i64 * 1000
        raw.exec(
          "INSERT INTO repeaters (created_at, updated_at, target, request, http2, auto_content_length, position) " \
          "VALUES (?,?,?,?,?,?,?)",
          now, now, "https://legacy.test", "POST /legacy HTTP/1.1\r\nContent-Length: 3\r\n\r\nA\u0000B", 0, 1, 0)
      ensure
        raw.close
      end

      expected = "POST /legacy HTTP/1.1\r\nContent-Length: 3\r\n\r\nA\u0000B".to_slice
      expected.includes?(0_u8).should be_true # sanity: the embedded NUL survives, not stripped by the literal itself
      id = store.repeaters.first.id
      store.repeaters.find!(&.id.==(id)).request.should eq(expected)
      store.get_repeater(id).not_nil!.request.should eq(expected)
      store.get_repeater_full(id).not_nil!.request.should eq(expected)
      store.repeaters_meta.find!(&.id.==(id)).request.should eq(expected)
      store.repeaters_mcp.find!(&.id.==(id)).request.should eq(expected)
    end
  end

  it "round-trips the V31 tags column (default nil, set + clear)" do
    with_store do |store|
      id = store.insert_repeater("https://a.test", "GET / HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 0)
      store.repeaters.find!(&.id.==(id)).tags.should be_nil # untagged by default

      store.set_repeater_tags(id, "idor auth")
      store.repeaters.find!(&.id.==(id)).tags.should eq("idor auth")

      # tagging does not rewrite the request (its own narrow UPDATE, like the name)
      store.repeaters.find!(&.id.==(id)).request.should eq("GET / HTTP/1.1\r\n\r\n".to_slice)

      store.set_repeater_tags(id, nil) # blank clears the column back to NULL
      store.repeaters.find!(&.id.==(id)).tags.should be_nil
    end
  end
end
