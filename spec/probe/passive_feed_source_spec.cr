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
#
# The guard's AXIS is what these specs mostly pin, because the first cut got it wrong in a way a
# green suite could not see: it filtered on `FlowSource::Kind#sent_by_gori?`, true for SEVEN
# kinds, when only TWO of them hand the same response to `scan_detail` by hand. That turned the
# passive engine off for Discover, Miner, Sequencer, Authorize and Probe — a crawl of a whole
# site reported zero leaked secrets, zero missing security headers, zero cookie-flag findings —
# and the suite stayed green because every assertion was written against the same wrong axis.
# So the table below is spelled out kind by kind WITH the call site (or its absence) that puts
# each on its side; a kind may only move to the skipped column when a real explicit scan lands.
module Gori::Probe
  class Analyzer
    def spec_catch_up : Nil
      catch_up
    end

    def spec_passive_feed?(row : Gori::Store::FlowRow) : Bool
      passive_feed?(row)
    end

    # `@analyzed` is the capped dedup set the eviction hazard below is about.
    def spec_analyzed : Set(Int64)
      @analyzed
    end
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

      # Skipped: FuzzerController#probe_scan_fuzz_result already scans this exact result.
      hits_for(store, "fuzz.test").should eq(0)
      # NOT skipped, and this is the regression the whole file exists to hold down. Nothing
      # anywhere calls scan_detail on a crawl's flows — the feed is Discover's ONLY passive
      # coverage, so filtering it out made `gori run discover` a scan that finds nothing.
      hits_for(store, "crawl.test").should be > 0
      # An IMPORTED flow is someone else's capture of a real endpoint — gori never sent it, so
      # it is evidence about the target and stays on the feed.
      hits_for(store, "import.test").should be > 0
      hits_for(store, "proxy.test").should be > 0
    end
  end

  # The axis, kind by kind, against the SEEDED store rather than the predicate alone: this is
  # the table the first cut got wrong, and reading it off real findings is what makes "Discover
  # scans nothing" visible instead of arithmetic on a boolean.
  it "scans every kind no surface scans by hand, and only skips the two that do" do
    with_store do |store|
      Gori::FlowSource::Kind.values.each { |k| seed_flow(store, "#{k.token}.test", k) }
      analyzer_for(store, Channel(Gori::Store::FlowEvent).new(1)).spec_catch_up
      store.flush

      scanned = Gori::FlowSource::Kind.values.select { |k| hits_for(store, "#{k.token}.test") > 0 }
      # Named as an exclusive split and asserted as a SUM, not a count: "no findings" and "never
      # looked" are the same number, so both halves are listed and both are checked.
      self_scanned = [Gori::FlowSource::Kind::Repeater, Gori::FlowSource::Kind::Fuzzer]
      on_feed = Gori::FlowSource::Kind.values - self_scanned
      scanned.sort_by(&.to_s).should eq(on_feed.sort_by(&.to_s))
      self_scanned.each { |k| hits_for(store, "#{k.token}.test").should eq(0) }
    end
  end

  # The live loop checked the guard AFTER `@analyzed << ev.id`, where `catch_up` checks it
  # before. `@analyzed` is capped (ANALYZED_CAP) and `trim` evicts the OLDEST ids, so every
  # skipped flow that got marked spent a slot and pushed a REAL proxy flow's id out. Once
  # evicted, `catch_up`'s `recent_flows` re-read no longer recognises that proxy flow and scans
  # it again — `upsert_probe_issues` bumps `hit_count` and flips `sample_flow_id`, which is the
  # same double-count arriving through the other door. Marking it is also what let a skipped
  # 101 flow reach `rescan_ws` on its NEXT `:updated` (the `@analyzed.includes?` fast path),
  # passively re-scanning frames `probe_scan_ws_repeater` had already counted.
  it "never marks a skipped flow as analyzed" do
    with_store do |store|
      input = Channel(Gori::Store::FlowEvent).new(8)
      analyzer = analyzer_for(store, input)
      rptr = seed_flow(store, "rptr.test", Gori::FlowSource::Kind::Repeater)
      fuzz = seed_flow(store, "fuzz.test", Gori::FlowSource::Kind::Fuzzer)
      proxied = seed_flow(store, "proxy.test", Gori::FlowSource::Kind::Proxy)
      analyzer.start
      input.send(Gori::Store::FlowEvent.new(rptr, :updated))
      input.send(Gori::Store::FlowEvent.new(fuzz, :updated))
      # In order, so findings for the LAST event prove the first two were already drained.
      input.send(Gori::Store::FlowEvent.new(proxied, :updated))
      deadline = Time.instant + 10.seconds
      until hits_for(store, "proxy.test") > 0 || Time.instant > deadline
        Fiber.yield
        store.flush
      end
      analyzer.stop

      analyzed = analyzer.spec_analyzed
      analyzed.should contain(proxied) # the flow it DID scan is deduped, as before
      # The two it skipped hold no slot, so the cap belongs entirely to scanned flows.
      analyzed.should_not contain(rptr)
      analyzed.should_not contain(fuzz)
      analyzed.size.should eq(1)
    end
  end

  # `self_scanned?` claims a call site for each `true`. A source-grep is the only thing that can
  # tell a real claim from a stale one, and a stale one is silent: the kind simply stops being
  # scanned. Comments are stripped so a call named only in prose cannot vouch for itself.
  it "backs every self_scanned? kind with a real scan_detail call site" do
    root = File.expand_path(File.join(__DIR__, "..", ".."))
    src = Dir.glob(File.join(root, "src", "**", "*.cr")).sort
      .reject(&.ends_with?(File.join("probe", "analyzer.cr")))
      .join('\n') do |f|
        File.read_lines(f).reject { |l| l.lstrip.starts_with?('#') }.join('\n')
      end
    # Repeater: RepeaterController (HTTP + WS) and MCP send_request's saved-repeater scan.
    src.should contain("probe.scan_detail(detail, repeater_id: repeater_id)")
    src.should contain("probe.scan_detail(detail, repeater_id: repeater_id, ws_messages: msgs)")
    src.should contain("Probe::Passive.analyze(detail).map")
    # Fuzzer: FuzzerController#probe_scan_fuzz_result.
    src.should contain("probe.scan_detail(detail)")
    Gori::FlowSource::Kind.values.select(&.self_scanned?).map(&.to_s).sort!
      .should eq(["Fuzzer", "Repeater"])
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
      # The line is `FlowSource::Kind#self_scanned?` — "is someone else already scanning this
      # exact response?" — so a workbench that learns to RECORD joins the feed by existing, and
      # leaves it only by also gaining an explicit scan. Spelled out per kind with the reason,
      # because the failure mode of the alternative (`sent_by_gori?`) was silent.
      {
        # No explicit scan anywhere — the feed is the only passive coverage these have.
        Gori::FlowSource::Kind::Proxy     => true, # the client's own traffic; the feed's reason to exist
        Gori::FlowSource::Kind::Discover  => true, # a crawl: nothing calls scan_detail on its flows
        Gori::FlowSource::Kind::Miner     => true, # ditto
        Gori::FlowSource::Kind::Sequencer => true, # ditto
        Gori::FlowSource::Kind::Authorize => true, # ditto
        Gori::FlowSource::Kind::Probe     => true, # ditto
        Gori::FlowSource::Kind::Import    => true, # gori never sent it; someone's capture of a real endpoint
        # Scanned by hand at a call site named in `self_scanned?` — on the feed too, they double-count.
        Gori::FlowSource::Kind::Repeater => false, # RepeaterController + MCP send_request
        Gori::FlowSource::Kind::Fuzzer   => false, # FuzzerController#probe_scan_fuzz_result
      }.each do |kind, on_feed|
        each_source[kind].should eq(on_feed)
      end
      # And the table is exhaustive — a new member must be placed deliberately, not defaulted.
      each_source.size.should eq(Gori::FlowSource::Kind.values.size)
    end
  end
end
