require "../spec_helper"
require "../support/probe_harness"

# `Probe::Scan::Persist` (#1392): the opt-in write-back a headless scan hands to `scan_all` —
# MCP `probe_scan{persist}` and `gori run probe --persist` both come through here, so the
# engine is where "a cancelled scan writes nothing" and "what was written committed" live.

private def seed(store) : Int64
  probe_capture_flow(store, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
    body: "<html><body>hi</body></html>").row.id
end

describe Gori::Probe::Scan::Persist do
  it "writes the flow detections through the Analyzer's merge and reports the commit" do
    with_store do |store|
      id = seed(store)
      persist = Gori::Probe::Scan::Persist.new
      dets, _ = Gori::Probe::Scan.scan_all(store, [id], active: false, persist: persist)
      persist.attempted?.should be_true
      persist.committed?.should be_true
      persist.detections.should eq(dets.size)
      store.probe_issues.map { |i| {i.code, i.host} }.to_set
        .should eq(dets.map { |d| {d.code, d.host} }.to_set)
      store.probe_issues.all? { |i| i.sample_flow_id == id }.should be_true
    end
  end

  it "writes nothing when no Persist is handed in" do
    with_store do |store|
      Gori::Probe::Scan.scan_all(store, [seed(store)], active: false)
      store.count_probe_issues.should eq(0)
    end
  end

  it "writes nothing from a stopped scan, and says it never tried" do
    with_store do |store|
      persist = Gori::Probe::Scan::Persist.new
      Gori::Probe::Scan.scan_all(store, [seed(store)], active: false, persist: persist, stop: -> { true })
      persist.attempted?.should be_false
      persist.committed?.should be_false
      store.count_probe_issues.should eq(0)
    end
  end
end
