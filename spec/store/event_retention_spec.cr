require "../spec_helper"

# `events` had no cleanup path at all until `trim_events`: `oast_callbacks` and `fuzz_runs` are
# deleted with their session, `intercept_commands` is wiped by `clear_intercept_state!` at every
# capture start, and `flows` has retention — events were only ever inserted, for as long as a
# project was used. The sweep then ran off the FLOW-insert cadence only, which is the second half
# of the same hole and what `events_trim_interval` closes.
#
# `flush` TWICE wherever a sweep is asserted. `flush`'s reply goes out with the batch's other
# deferred replies, BEFORE the writer loop reaches the retention branch below them, so one flush
# fences the writes and not the sweep. A second flush is a second batch, and the loop cannot
# begin one until it has finished the previous iteration — the sweep included.
private def events_store(events_retention, prune_interval,
                         retention = Gori::Store::RETENTION_UNLIMITED,
                         events_trim_interval = Gori::Store::EVENTS_TRIM_INTERVAL, &)
  path = File.tempname("gori-event-retention", ".db")
  db = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
  Gori::Store::Schema.migrate!(db)
  store = Gori::Store.new(db, nil, retention_flows: retention, prune_interval: prune_interval,
    events_retention: events_retention, events_trim_interval: events_trim_interval)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def event_request(target : String) : Gori::Store::CapturedRequest
  Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "http", host: "acme.test", port: 80,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy)
end

describe "Store event-log retention" do
  it "keeps the newest N events and drops the rest" do
    events_store(5, 2) do |store|
      12.times { |i| store.insert_event("spec", "test", "info", "event #{i}") }
      store.flush
      # The sweep runs from the writer's insert path, so it takes flow inserts to trigger.
      2.times { |i| store.insert_flow(event_request("/trigger#{i}")) }
      store.flush

      rows = store.events_after(0_i64, 100)
      rows.size.should eq(5)
      rows.map(&.message).should eq((7..11).map { |i| "event #{i}" }) # the newest five
    end
  end

  it "runs even when flow retention is UNLIMITED" do
    # The surface that writes the most events is the MCP server, which opens with
    # RETENTION_UNLIMITED — so gating the trim on `@retention_flows` would exempt exactly the
    # case it exists for. Same bug the h2-frame reap above it already had and fixed.
    events_store(3, 2, retention: Gori::Store::RETENTION_UNLIMITED) do |store|
      8.times { |i| store.insert_event("spec", "test", "info", "e#{i}") }
      store.flush
      2.times { |i| store.insert_flow(event_request("/t#{i}")) }
      store.flush

      store.events_after(0_i64, 100).size.should eq(3)
    end
  end

  # THE case the cap was never enforced in. `prune` is the only caller of `trim_events` and it
  # runs off the FLOW-insert cadence, which is zero for the two surfaces that write most of these
  # rows: an MCP server (one `agent_action` per mutating tool call) and a TUI with capture off.
  # For those the cap was a number nothing applied, and the table grew for the life of the
  # project — which `events_recent` then pays for from the reading end, its scan window stopping
  # short of a feed it can no longer reach the bottom of.
  it "sweeps the feed in a store that never inserts a flow" do
    events_store(5, 2, events_trim_interval: 4) do |store|
      12.times { |i| store.insert_event("agent", "agent_action", "info", "call #{i}") }
      store.flush
      store.flush # fences the SWEEP, not just the writes — see the header

      rows = store.events_after(0_i64, 100)
      rows.size.should be <= 5 + 4           # the cap, plus at most one cadence of overshoot
      rows.last.message.should eq("call 11") # and the newest is still the newest
    end
  end

  # The event cadence must not double-sweep with the flow one, and must not starve it either:
  # a store doing both keeps one cap, reached by whichever counter fills first.
  it "keeps one cap when flows and events arrive together" do
    events_store(3, 2, retention: Gori::Store::RETENTION_UNLIMITED, events_trim_interval: 4) do |store|
      10.times do |i|
        store.insert_event("agent", "agent_action", "info", "e#{i}")
        store.insert_flow(event_request("/f#{i}"))
      end
      store.flush
      store.flush

      store.events_after(0_i64, 100).size.should be <= 3 + 4
      store.events_after(0_i64, 100).last.message.should eq("e9")
    end
  end

  it "leaves a table already under the cap completely alone" do
    events_store(50, 2) do |store|
      4.times { |i| store.insert_event("spec", "test", "info", "keep #{i}") }
      store.flush
      2.times { |i| store.insert_flow(event_request("/x#{i}")) }
      store.flush

      store.events_after(0_i64, 100).map(&.message).should eq((0..3).map { |i| "keep #{i}" })
    end
  end

  it "never takes a row a reader's watermark has not passed" do
    # `events.id` is AUTOINCREMENT, so it is monotonic and never reused: a forward cursor
    # (`events_after(since_id, limit)`) can only ever be behind the survivors, never inside a
    # hole the trim opened ahead of it.
    events_store(4, 2) do |store|
      6.times { |i| store.insert_event("spec", "test", "info", "a#{i}") }
      store.flush
      seen = store.events_after(0_i64, 100)
      watermark = seen.last.id

      6.times { |i| store.insert_event("spec", "test", "info", "b#{i}") }
      store.flush
      2.times { |i| store.insert_flow(event_request("/w#{i}")) }
      store.flush

      # Everything after the watermark is still deliverable, in order, with no gap before it.
      fresh = store.events_after(watermark, 100)
      fresh.map(&.message).should eq((2..5).map { |i| "b#{i}" })
      fresh.first.id.should be > watermark
    end
  end
end

# The dismiss verbs report "dismissed N" to the operator, so N has to be EXACT. It used to be
# produced by loading every probe_issues row (JSON-parsing `affected` on each) and counting in
# Crystal — which is also why capping that read looked attractive and would have been wrong:
# a LIMIT would have made this number quietly under-report what the dismiss just did.
describe "Store#open_probe_issue_count" do
  it "counts only OPEN findings, by code and by host, in SQL" do
    events_store(50, 1000) do |store|
      add = ->(code : String, host : String, status : Int32) do
        store.@db.exec(
          "INSERT INTO probe_issues (code, category, host, title, severity, status, hit_count, affected, first_seen, last_seen) " \
          "VALUES (?, 'c', ?, 't', 2, ?, 1, '[]', 1, 1)", code, host, status)
      end
      add.call("secret_in_url", "a.test", Gori::Store::Status::Open.value)
      add.call("secret_in_url", "b.test", Gori::Store::Status::Open.value)
      add.call("secret_in_url", "c.test", Gori::Store::Status::Resolved.value) # not open
      add.call("cors_wildcard", "a.test", Gori::Store::Status::Open.value)
      add.call("cors_wildcard", "b.test", Gori::Store::Status::FalsePositive.value)

      store.open_probe_issue_count(code: "secret_in_url").should eq(2) # the Resolved one is excluded
      store.open_probe_issue_count(host: "a.test").should eq(2)
      store.open_probe_issue_count(host: "b.test").should eq(1) # the FalsePositive one is excluded
      store.open_probe_issue_count.should eq(3)                 # every open finding
      store.open_probe_issue_count(code: "nope").should eq(0)
    end
  end
end
