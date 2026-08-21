require "../spec_helper"

# `flows.id` is a plain INTEGER PRIMARY KEY, i.e. the rowid, and SQLite REUSES it: clear the
# project and the next capture is handed id 1 again. Every column that points at a flow therefore
# has to be NULLed when that flow goes, or it silently re-points at unrelated traffic. That is
# what `detach_flow_refs` is for, and `probe_oast_probes` was missing from its list.
private def oast_store(&)
  path = File.tempname("gori-oast-detach", ".db")
  db = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
  Gori::Store::Schema.migrate!(db)
  store = Gori::Store.new(db, nil)
  begin
    yield store
  ensure
    done = Channel(Nil).new(1)
    spawn { store.close; done.send(nil) }
    select
    when done.receive then nil
    when timeout(20.seconds) then raise "store.close did not return"
    end
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def detach_request(target : String) : Gori::Store::CapturedRequest
  Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "http", host: "acme.test", port: 80, method: "GET",
    target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy)
end

private def plant_probe(store : Gori::Store, token : String, flow_id : Int64?) : Nil
  store.insert_probe_oast_probe(token, "http://x.oast.test/#{token}", 0_i64, "rule-1",
    "oob_rce", "injection", "Out-of-band callback", Gori::Store::Severity::High,
    "acme.test", "http://acme.test/planted", "param q", flow_id)
end

describe "an outstanding OAST probe whose flow is gone" do
  it "loses its flow reference on a history clear, so a later callback cannot cite a new flow" do
    oast_store do |store|
      planted = store.insert_flow(detach_request("/planted"))
      plant_probe(store, "tok-abcdefgh", planted)
      store.flush
      store.probe_oast_pending.first.flow_id.should eq(planted)

      # The probe deliberately OUTLIVES the traffic that planted it — that is what the table is
      # for — so the clear leaves the row and resets the rowid counter.
      store.clear_flows.should be_true
      store.flush
      reused = store.insert_flow(detach_request("/unrelated"))
      store.flush
      reused.should eq(planted) # the id really is handed out again

      # `Probe::OutOfBand.detection_for` passes this straight into a Detection, which
      # `upsert_probe_issue` writes as `probe_issues.sample_flow_id`. Non-nil here means the
      # finding cites `/unrelated` as the request that planted the payload.
      store.probe_oast_pending.first.flow_id.should be_nil
    end
  end

  it "loses it on a single-flow delete too" do
    oast_store do |store|
      planted = store.insert_flow(detach_request("/planted"))
      other = store.insert_flow(detach_request("/kept"))
      plant_probe(store, "tok-11111111", planted)
      plant_probe(store, "tok-22222222", other)
      store.flush

      store.delete_flow(planted).should be_true
      store.flush

      by_token = store.probe_oast_pending.to_h { |p| {p.token, p.flow_id} }
      by_token["tok-11111111"].should be_nil # its flow is gone
      by_token["tok-22222222"].should eq(other)
    end
  end

  it "keeps the probe row itself — the payload is still out there" do
    oast_store do |store|
      planted = store.insert_flow(detach_request("/planted"))
      plant_probe(store, "tok-33333333", planted)
      store.flush
      store.clear_flows
      store.flush
      # Detaching the reference must not be mistaken for dropping the probe: a callback that
      # arrives later still has to promote its finding, just without a flow to cite.
      pending = store.probe_oast_pending
      pending.size.should eq(1)
      pending.first.token.should eq("tok-33333333")
      pending.first.host.should eq("acme.test")
      pending.first.evidence.should eq("param q")
    end
  end
end
