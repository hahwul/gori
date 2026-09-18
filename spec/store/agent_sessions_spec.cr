require "../spec_helper"

# Agent conversations and their transcripts (V29, #1093).
#
# The product contract these pin: the row is the CONVERSATION and survives a resume that has
# to change its uuid, a partial update touches only what it names (the operator's unsent draft
# is the one that would be noticed), one transcript line can never put unbounded bytes into
# the project, and both delete paths take the transcript with them.

# A store whose retention sweep can be driven from a spec: `prune` runs off the FLOW-insert
# cadence, so a small `prune_interval` plus a few captured flows is what makes
# `trim_agent_sessions` run at all.
private def prune_store(prune_interval, &)
  path = File.tempname("gori-agent-prune", ".db")
  db = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
  Gori::Store::Schema.migrate!(db)
  store = Gori::Store.new(db, nil, retention_flows: Gori::Store::RETENTION_UNLIMITED,
    prune_interval: prune_interval)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def capture_flow(store, n : Int32) : Int64
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64 + n, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: "/#{n}", http_version: "HTTP/1.1",
    head: "GET /#{n} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
    body: nil, source: Gori::FlowSource::Kind::Proxy))
end

describe "agent sessions store" do
  it "migrates to the current schema version with both tables" do
    with_store do |store|
      store.@db.scalar("PRAGMA user_version").as(Int64).to_i.should eq(Gori::Store::Schema::VERSION)
      %w[agent_sessions agent_messages].each do |table|
        store.@db.scalar(
          "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?", table)
          .as(Int64).should eq(1)
      end
      # The two read paths each have their covering index (schema.cr V29).
      %w[idx_agent_messages_session idx_agent_sessions_started].each do |idx|
        store.@db.scalar(
          "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = ?", idx)
          .as(Int64).should eq(1)
      end
    end
  end

  it "round trips a conversation through insert, update, finish and the reads" do
    with_store do |store|
      id = store.insert_agent_session("uuid-1", "claude", "sonnet", "")
      id.should be > 0

      row = store.agent_session(id).not_nil!
      row.session_uuid.should eq("uuid-1")
      row.resumed_from.should be_nil
      row.backend.should eq("claude")
      row.model.should eq("sonnet")
      row.title.should eq("")
      row.draft.should eq("")
      row.ended_at.should be_nil
      row.cost_usd.should eq(0.0)
      row.turns.should eq(0)
      row.started_at.should be > 0

      store.update_agent_session(id, title: "audit the login flow", draft: "and then ",
        cost_usd: 0.42, turns: 3).should be_true
      row = store.agent_session(id).not_nil!
      row.title.should eq("audit the login flow")
      row.draft.should eq("and then ")
      row.cost_usd.should eq(0.42)
      row.turns.should eq(3)

      store.finish_agent_session(id).should be_true
      store.agent_session(id).not_nil!.ended_at.should_not be_nil
      # Idempotent: a second call moves the stamp rather than refusing.
      store.finish_agent_session(id).should be_true
      store.agent_session(id).not_nil!.ended_at.should_not be_nil

      store.count_agent_sessions.should eq(1)
      store.list_agent_sessions(10).map(&.id).should eq([id])
    end
  end

  it "re-uuids one conversation in place when a spawn resumes it" do
    with_store do |store|
      id = store.insert_agent_session("uuid-1", "claude", nil, "")
      # Claude Code refuses a session-id it has already issued, so the resume mints a fresh
      # uuid and names the old one. Still ONE row: one scrollback, one cost, one title.
      store.update_agent_session(id, session_uuid: "uuid-2", resumed_from: "uuid-1").should be_true
      store.count_agent_sessions.should eq(1)
      store.agent_session_by_uuid("uuid-2").not_nil!.id.should eq(id)
      store.agent_session_by_uuid("uuid-2").not_nil!.resumed_from.should eq("uuid-1")
      # The old uuid is no longer a handle on anything — the row moved, it did not fork.
      store.agent_session_by_uuid("uuid-1").should be_nil
      store.agent_session_by_uuid("nope").should be_nil
    end
  end

  it "lists newest first" do
    with_store do |store|
      a = store.insert_agent_session("u-a", "claude", nil, "first")
      b = store.insert_agent_session("u-b", "claude", nil, "second")
      c = store.insert_agent_session("u-c", "claude", nil, "third")
      store.list_agent_sessions(10).map(&.id).should eq([c, b, a])
      store.list_agent_sessions(2).map(&.id).should eq([c, b])
    end
  end

  it "updates only the fields it was given, and writes nothing when given none" do
    with_store do |store|
      id = store.insert_agent_session("uuid-1", "claude", "opus", "a title")
      store.update_agent_session(id, draft: "half a thought").should be_true

      # The shape that matters: a turn-done frame reporting cost must not clear the draft the
      # operator is in the middle of typing.
      store.update_agent_session(id, cost_usd: 1.5, turns: 2).should be_true
      row = store.agent_session(id).not_nil!
      row.draft.should eq("half a thought")
      row.title.should eq("a title")
      row.model.should eq("opus")
      row.cost_usd.should eq(1.5)

      # Nothing to update: true, and the row is untouched.
      store.update_agent_session(id).should be_true
      after = store.agent_session(id).not_nil!
      after.draft.should eq("half a thought")
      after.title.should eq("a title")
      after.cost_usd.should eq(1.5)
      after.turns.should eq(2)

      # Zero is a value, not an absence — Crystal's only falsey values are nil and false.
      store.update_agent_session(id, cost_usd: 0.0, turns: 0).should be_true
      zeroed = store.agent_session(id).not_nil!
      zeroed.cost_usd.should eq(0.0)
      zeroed.turns.should eq(0)
    end
  end

  it "round trips a transcript in seq order" do
    with_store do |store|
      id = store.insert_agent_session("uuid-1", "claude", nil, "")
      store.insert_agent_message(id, 0, "user", "text", "scan the login form")
      store.insert_agent_message(id, 1, "assistant", "thinking", "let me look")
      store.insert_agent_message(id, 2, "tool", "tool_use", "list_history",
        payload: %({"limit":5}))
      store.insert_agent_message(id, 3, "tool", "tool_result", "5 flows", truncated: true)

      rows = store.agent_messages(id)
      rows.map(&.seq).should eq([0, 1, 2, 3])
      rows.map(&.role).should eq(%w[user assistant tool tool])
      rows.map(&.kind).should eq(%w[text thinking tool_use tool_result])
      rows[0].text.should eq("scan the login form")
      rows[0].payload.should be_nil
      rows[0].truncated?.should be_false
      rows[2].payload.should eq(%({"limit":5}))
      # A producer that already knows it cut a frame keeps that flag.
      rows[3].truncated?.should be_true
      rows.each(&.session_id.should eq(id))
      rows.each(&.created_at.should be > 0)

      # Another conversation's transcript is not this one's.
      other = store.insert_agent_session("uuid-2", "claude", nil, "")
      store.insert_agent_message(other, 0, "user", "text", "unrelated")
      store.agent_messages(id).size.should eq(4)
      store.agent_messages(other).map(&.text).should eq(["unrelated"])
    end
  end

  it "caps one transcript line and keeps the stored text valid UTF-8" do
    with_store do |store|
      id = store.insert_agent_session("uuid-1", "claude", nil, "")
      cap = Gori::Store::AGENT_MESSAGE_MAX_BYTES
      # Built so a 3-byte character STRADDLES the cap: pad to one byte short of it, then let
      # the multi-byte run begin. A byte-exact cut would split that character and store bytes
      # that are not UTF-8 at all.
      huge = ("a" * (cap - 1)) + ("한" * 1_000)
      huge.bytesize.should be > cap

      store.insert_agent_message(id, 0, "tool", "tool_result", huge).should be > 0
      row = store.agent_messages(id).first
      row.truncated?.should be_true
      row.text.bytesize.should be <= cap
      row.text.valid_encoding?.should be_true
      # Cut on the boundary BEFORE the straddling character, not through it.
      row.text.should eq("a" * (cap - 1))

      # Exactly at the cap is not truncated.
      store.insert_agent_message(id, 1, "tool", "tool_result", "b" * cap)
      at_cap = store.agent_messages(id)[1]
      at_cap.truncated?.should be_false
      at_cap.text.bytesize.should eq(cap)
    end
  end

  it "deletes a conversation with its transcript, and clears both tables" do
    with_store do |store|
      a = store.insert_agent_session("u-a", "claude", nil, "")
      b = store.insert_agent_session("u-b", "claude", nil, "")
      2.times { |i| store.insert_agent_message(a, i, "user", "text", "a#{i}") }
      2.times { |i| store.insert_agent_message(b, i, "user", "text", "b#{i}") }

      store.delete_agent_session(a).should be_true
      store.agent_session(a).should be_nil
      store.agent_messages(a).should be_empty
      # The neighbour is untouched.
      store.agent_messages(b).size.should eq(2)
      store.count_agent_sessions.should eq(1)

      store.clear_agent_sessions.should be_true
      store.count_agent_sessions.should eq(0)
      store.agent_messages(b).should be_empty
      store.@db.scalar("SELECT COUNT(*) FROM agent_messages").as(Int64).should eq(0)
    end
  end

  # The wired sweep, not a hand-rolled copy of it: `prune` is the only caller, it runs off the
  # FLOW-insert cadence, and `AGENT_SESSIONS_KEEP` is a constant with no constructor override —
  # so the only honest way to assert the cap is to go past it and make a prune happen.
  #
  # `flush` TWICE, for the reason `event_retention_spec` documents: a flush's reply goes out
  # with the batch's other deferred replies, BEFORE the writer loop reaches the retention branch
  # below them, so one flush fences the writes and not the sweep.
  it "trims to the newest AGENT_SESSIONS_KEEP conversations and takes their messages along" do
    prune_store(prune_interval: 2) do |store|
      keep = Gori::Store::AGENT_SESSIONS_KEEP
      total = keep + 5
      ids = (1..total).map do |n|
        id = store.insert_agent_session("u-#{n}", "claude", nil, "c#{n}")
        store.insert_agent_message(id, 0, "user", "text", "message #{n}")
        id
      end
      store.count_agent_sessions.should eq(total)

      2.times { |n| capture_flow(store, n) }
      store.flush
      store.flush

      store.count_agent_sessions.should eq(keep.to_i64)
      survivors = ids.last(keep)
      dropped = ids.first(total - keep)
      store.list_agent_sessions(total).map(&.id).should eq(survivors.reverse)
      # The transcript went with the conversation — the whole point of deleting the messages
      # first, in the same transaction.
      dropped.each do |id|
        store.agent_session(id).should be_nil
        store.agent_messages(id).should be_empty
      end
      survivors.each { |id| store.agent_messages(id).size.should eq(1) }
      store.@db.scalar("SELECT COUNT(*) FROM agent_messages").as(Int64).should eq(keep.to_i64)
    end
  end

  it "leaves a project already under the cap completely alone" do
    prune_store(prune_interval: 2) do |store|
      ids = (1..4).map { |n| store.insert_agent_session("u-#{n}", "claude", nil, "c#{n}") }
      ids.each { |id| store.insert_agent_message(id, 0, "user", "text", "hi") }
      2.times { |n| capture_flow(store, n) }
      store.flush
      store.flush

      store.count_agent_sessions.should eq(4)
      store.list_agent_sessions(10).map(&.id).should eq(ids.reverse)
      ids.each { |id| store.agent_messages(id).size.should eq(1) }
    end
  end
end
