require "../spec_helper"
require "../support/probe_harness"

# A store whose issue write fails with a NON-DB error. DB::Error/SQLite3::Exception are
# deliberately re-raised by the analyzer (they mean the project is unusable, not that one
# detail is odd), so the interesting case is the other kind: findings were already made and
# the recording step blew up.
private class PersistFailingStore < Gori::Store
  # Hooked on the PLURAL, which is the single chokepoint: `upsert_probe_issue` delegates to it, so
  # this injects the failure no matter which entry point the analyzer reaches for. Overriding the
  # singular alone silently stopped injecting the day `persist` switched to writing a page's
  # findings in one round-trip — the spec kept passing locally and only CI noticed.
  def upsert_probe_issues(ds : Indexable(Gori::Probe::Detection)) : Nil
    raise ArgumentError.new("persist boom")
  end
end

private def open_failing_store(path : String) : PersistFailingStore
  url = "sqlite3:#{path}?journal_mode=wal&synchronous=normal&busy_timeout=5000"
  db = DB.open(url)
  Gori::SafeRegexp.install(db)
  Gori::Store::Schema.migrate!(db)
  PersistFailingStore.new(db)
end

private def with_failing_store(&)
  path = File.tempname("gori-persistfail", ".db")
  store = open_failing_store(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

module Gori::Probe
  class Analyzer
    def spec_analyzed : Set(Int64)
      @analyzed
    end

    def spec_rescan_ws(flow_id : Int64, detail : Gori::Store::FlowDetail? = nil) : Bool
      rescan_ws(flow_id, detail)
    end

    def spec_ws_hwm(flow_id : Int64) : Int64?
      @ws_hwm[flow_id]?
    end
  end
end

# A flow that reliably yields passive detections (a missing-security-headers family).
private def seed_flow(store : Gori::Store) : Gori::Store::FlowDetail
  head = "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n"
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "acme.test", port: 80,
    method: "GET", target: "/", http_version: "HTTP/1.1", head: head.to_slice, source: Gori::FlowSource::Kind::Proxy))
  resp_head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nSet-Cookie: sid=1\r\n\r\n"
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: resp_head.to_slice, body: "<html>hi</html>".to_slice,
    reason: "OK", content_type: "text/html", duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

# `scan_detail`'s blanket rescue covered three statements while its comment justified one
# ("a single detail's analysis blew up — skip it"). Past `Passive.analyze` the findings
# already exist, so swallowing there showed the operator a completed scan with no issues —
# indistinguishable from a clean target.
describe "Probe::Analyzer#scan_detail persistence failure" do
  it "reports findings it could not record instead of dropping them silently" do
    with_failing_store do |store|
      scope = Gori::Scope.load(store)
      analyzer = Gori::Probe::Analyzer.new(
        store, scope, Channel(Gori::Store::FlowEvent).new(1),
        Gori::Probe::Mode::Passive, true)
      detail = seed_flow(store)

      # Must not raise into the caller: the TUI event loop has no catch-all.
      analyzer.scan_detail(detail)

      # Bounded, never a bare `receive`: with the report missing there is no event to take
      # and a blocking read would HANG the suite instead of reporting a failure.
      select
      when ev = analyzer.events.receive
        ev.should be_a(Gori::Probe::ErrorEvent)
        ev.as(Gori::Probe::ErrorEvent).message.should contain("were not recorded")
      when timeout(5.seconds)
        fail "findings were dropped with no ErrorEvent"
      end
    end
  end

  it "does not acknowledge a live flow whose passive write failed" do
    with_failing_store do |store|
      scope = Gori::Scope.load(store)
      input = Channel(Gori::Store::FlowEvent).new(1)
      analyzer = Gori::Probe::Analyzer.new(
        store, scope, input, Gori::Probe::Mode::Passive, true)
      detail = seed_flow(store)
      analyzer.start
      input.send(Gori::Store::FlowEvent.new(detail.row.id, :updated))

      select
      when ev = analyzer.events.receive
        ev.should be_a(Gori::Probe::ErrorEvent)
      when timeout(5.seconds)
        fail "failed flow was not reported"
      end
      analyzer.spec_analyzed.should_not contain(detail.row.id)
      analyzer.stop
    end
  end

  it "does not advance the WebSocket cursor before its page is persisted" do
    with_failing_store do |store|
      head = "GET /ws HTTP/1.1\r\nHost: acme.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
        method: "GET", target: "/ws", http_version: "HTTP/1.1", head: head.to_slice,
        source: Gori::FlowSource::Kind::Proxy))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 101,
        head: "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".to_slice,
        body: nil, reason: "Switching Protocols", content_type: nil, duration_us: 1_i64))
      store.insert_ws_message(id, "in", 1, "token=#{PROBE_AWS_KEY_ID}".to_slice)
      detail = store.get_flow(id).not_nil!
      analyzer = Gori::Probe::Analyzer.new(
        store, Gori::Scope.load(store), Channel(Gori::Store::FlowEvent).new(1),
        Gori::Probe::Mode::Passive, true)

      analyzer.spec_rescan_ws(id, detail).should be_false
      analyzer.spec_ws_hwm(id).should be_nil
      analyzer.stop
    end
  end
end
