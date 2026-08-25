require "../spec_helper"

# The Repeater records its sends by DEFAULT (`Settings.repeater_record_history?`), so `^R`
# writes a flow and publishes a `:updated` event on the very feed `Probe::Analyzer` drains.
# That gave every hand-driven send TWO passive consumers:
#
#   A. RepeaterController#probe_scan_repeater → scan_detail(detail, repeater_id: id)
#   B. HistoryRecord.record → insert_flow → publish → passive_loop → scan_detail(enqueue_active: true)
#
# Nothing dedups them (`@analyzed` holds flow ids and path A never touches it), and
# `upsert_probe_issues` keys on `(code, host)` with `hit_count = hit_count + 1` — so every
# finding on that host climbed by two per send, its provenance flipped to whichever path landed
# last, and in Active mode path B queued active probes against a request the operator sent by
# hand. `AuthorizeController` was given an explicit guard for exactly this; the analyzer was not.
#
# `catch_up` is exercised beside the live loop deliberately: it re-reads `recent_flows` with no
# source filter, so it reaches a flow the lossy live feed dropped and would re-open the hole.
module Gori::Probe
  class Analyzer
    def spec_catch_up : Nil
      catch_up
    end

    def spec_passive_feed?(row : Gori::Store::FlowRow) : Bool
      passive_feed?(row)
    end
  end
end

private def with_store(&)
  path = File.tempname("gori-probe-feed", ".db")
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

# A complete flow that reliably yields passive detections (the missing-security-headers family),
# tagged with the provenance under test.
private def seed_flow(store : Gori::Store, host : String,
                      source : Gori::FlowSource::Kind) : Int64
  head = "GET / HTTP/1.1\r\nHost: #{host}\r\n\r\n"
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: host, port: 80,
    method: "GET", target: "/", http_version: "HTTP/1.1", head: head.to_slice, source: source))
  resp_head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nSet-Cookie: sid=1\r\n\r\n"
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: resp_head.to_slice, body: "<html>hi</html>".to_slice,
    reason: "OK", content_type: "text/html", duration_us: 1_i64))
  store.flush
  id
end

private def hits_for(store : Gori::Store, host : String) : Int64
  store.probe_issues(host: host).sum(&.hit_count.to_i64)
end

private def analyzer_for(store : Gori::Store, input : Channel(Gori::Store::FlowEvent),
                         mode : Gori::Probe::Mode = Gori::Probe::Mode::Passive) : Gori::Probe::Analyzer
  Gori::Probe::Analyzer.new(store, Gori::Scope.load(store), input, mode, true)
end

describe "Probe::Analyzer passive feed provenance" do
  it "scans a PROXY flow off the live feed and skips a gori-originated one" do
    with_store do |store|
      input = Channel(Gori::Store::FlowEvent).new(8)
      analyzer = analyzer_for(store, input)
      rptr = seed_flow(store, "rptr.test", Gori::FlowSource::Kind::Repeater)
      proxied = seed_flow(store, "proxy.test", Gori::FlowSource::Kind::Proxy)
      analyzer.start
      # Order matters: the passive fiber drains in order, so findings for the SECOND event
      # prove the first was already handled — no sleep, no flake.
      input.send(Gori::Store::FlowEvent.new(rptr, :updated))
      input.send(Gori::Store::FlowEvent.new(proxied, :updated))

      deadline = Time.instant + 10.seconds
      until hits_for(store, "proxy.test") > 0 || Time.instant > deadline
        Fiber.yield
        store.flush
      end
      analyzer.stop

      hits_for(store, "proxy.test").should be > 0 # real client traffic still scans
      hits_for(store, "rptr.test").should eq(0)   # gori's own send does not
    end
  end

  it "counts a recorded Repeater send ONCE, through the explicit scan only" do
    with_store do |store|
      input = Channel(Gori::Store::FlowEvent).new(8)
      analyzer = analyzer_for(store, input)
      id = seed_flow(store, "rptr.test", Gori::FlowSource::Kind::Repeater)
      detail = store.get_flow(id).not_nil!

      # Path A — the RepeaterController's explicit scan. This must keep working.
      analyzer.scan_detail(detail, repeater_id: 42_i64)
      store.flush
      once = hits_for(store, "rptr.test")
      once.should be > 0
      store.probe_issues(host: "rptr.test").first.sample_repeater_id.should eq(42_i64)

      # Path B — the same send arriving on the History feed, and the catch-up sweep behind it.
      analyzer.start
      input.send(Gori::Store::FlowEvent.new(id, :updated))
      analyzer.spec_catch_up
      deadline = Time.instant + 2.seconds
      while Time.instant < deadline
        Fiber.yield
        store.flush
      end
      analyzer.stop

      hits_for(store, "rptr.test").should eq(once) # not 2x, not 3x
      # Provenance stays with the surface that actually ran the scan.
      store.probe_issues(host: "rptr.test").first.sample_repeater_id.should eq(42_i64)
    end
  end

  # The sweep re-reads recent_flows directly, so it is its own door into the same hole.
  it "keeps the catch-up sweep on the same side of the line" do
    with_store do |store|
      input = Channel(Gori::Store::FlowEvent).new(1)
      analyzer = analyzer_for(store, input)
      seed_flow(store, "fuzz.test", Gori::FlowSource::Kind::Fuzzer)
      seed_flow(store, "crawl.test", Gori::FlowSource::Kind::Discover)
      seed_flow(store, "import.test", Gori::FlowSource::Kind::Import)
      seed_flow(store, "proxy.test", Gori::FlowSource::Kind::Proxy)
      analyzer.spec_catch_up
      store.flush

      hits_for(store, "fuzz.test").should eq(0)
      hits_for(store, "crawl.test").should eq(0)
      # An IMPORTED flow is someone else's capture of a real endpoint — gori never sent it, so
      # it is evidence about the target and stays on the feed.
      hits_for(store, "import.test").should be > 0
      hits_for(store, "proxy.test").should be > 0
    end
  end

  # A row written before the V17 provenance columns has `source` NULL. Treating "not recorded"
  # as "gori's own" would silently switch passive scanning off for every project captured with
  # an older gori — the same call `Authorize::Passive.gori_originated?` makes.
  it "keeps a flow whose provenance was never recorded on the feed" do
    with_store do |store|
      analyzer = analyzer_for(store, Channel(Gori::Store::FlowEvent).new(1))
      legacy = Gori::Store::FlowRow.new(1_i64, 1_i64, "http", "GET", "legacy.test", 80, "/",
        200, 0_i64, Gori::Store::FlowState::Complete, source: nil)
      analyzer.spec_passive_feed?(legacy).should be_true

      each_source = Gori::FlowSource::Kind.values.map do |k|
        row = Gori::Store::FlowRow.new(1_i64, 1_i64, "http", "GET", "h.test", 80, "/",
          200, 0_i64, Gori::Store::FlowState::Complete, source: k)
        {k, analyzer.spec_passive_feed?(row)}
      end.to_h
      # The line is `FlowSource::Kind#sent_by_gori?`, drawn once — a workbench that learns to
      # record joins this guard by existing, not by remembering to edit it here.
      each_source[Gori::FlowSource::Kind::Proxy].should be_true
      each_source[Gori::FlowSource::Kind::Import].should be_true
      Gori::FlowSource::Kind.values.each do |k|
        each_source[k].should eq(!k.sent_by_gori?)
      end
    end
  end
end
