require "../../spec_helper"

# --- file-local harness (mirrors spec/probe_spec.cr's private with_store/capture_flow) ---

private def with_store(&)
  path = File.tempname("gori-tech-test", ".db")
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

private def capture_flow(store, *, status = 200, content_type : String? = "text/html",
                         resp_headers = "", body : String = "OK") : Gori::Store::FlowDetail
  head = "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n"
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: "/", http_version: "HTTP/1.1", head: head.to_slice, body: nil)
  id = store.insert_flow(req)
  rhead = String.build do |io|
    io << "HTTP/1.1 " << status << " OK\r\n"
    io << "Content-Type: " << content_type << "\r\n" if content_type
    io << resp_headers
    io << "\r\n"
  end
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: rhead.to_slice,
    body: body.to_slice, reason: "OK", content_type: content_type, duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

describe Gori::Probe::Passive::Tech do
  describe ".alt_svc_h3_evidence" do
    it "extracts evidence for standard h3" do
      ev = Gori::Probe::Passive::Tech.alt_svc_h3_evidence(%(h3=":443"; ma=2592000))
      ev.should eq(%(h3=":443"; ma=2592000))
    end

    it "extracts evidence for draft version h3-29" do
      ev = Gori::Probe::Passive::Tech.alt_svc_h3_evidence(%(h3-29=":443"; ma=3600, h3-27=":443"))
      ev.should eq(%(h3-29=":443"; ma=3600))
    end

    it "extracts evidence for draft version h3-Q050" do
      ev = Gori::Probe::Passive::Tech.alt_svc_h3_evidence(%(h3-Q050=":443"))
      ev.should eq(%(h3-Q050=":443"))
    end

    it "finds h3 when preceded by other protocols" do
      ev = Gori::Probe::Passive::Tech.alt_svc_h3_evidence(%(h2=":443"; ma=86400, h3=":443"; ma=86400))
      ev.should eq(%(h3=":443"; ma=86400))
    end

    it "returns nil for clear directive" do
      Gori::Probe::Passive::Tech.alt_svc_h3_evidence("clear").should be_nil
    end

    it "returns nil for h2 only" do
      Gori::Probe::Passive::Tech.alt_svc_h3_evidence(%(h2=":443"; ma=86400)).should be_nil
    end

    it "returns nil for unrelated tokens" do
      Gori::Probe::Passive::Tech.alt_svc_h3_evidence(%(fooh3=":443")).should be_nil
      Gori::Probe::Passive::Tech.alt_svc_h3_evidence(%(h32=":443")).should be_nil
    end
  end

  describe "passive analysis for Alt-Svc HTTP/3" do
    it "flags Alt-Svc advertising h3" do
      with_store do |store|
        flow = capture_flow(store, resp_headers: %(Alt-Svc: h3=":443"; ma=2592000\r\n))
        dets = Gori::Probe::Passive.analyze(flow)
        h3 = dets.find { |d| d.code == "tech_http3" }
        h3.should_not be_nil
        det = h3.not_nil!
        det.category.should eq(Gori::Probe::Category::TECH)
        det.severity.should eq(Gori::Store::Severity::Info)
        det.title.should eq("HTTP/3 advertised via Alt-Svc")
        det.evidence.should eq(%(h3=":443"; ma=2592000))
      end
    end

    it "flags Alt-Svc advertising h3-29" do
      with_store do |store|
        flow = capture_flow(store, resp_headers: %(alt-svc: h3-29=":443"; ma=3600\r\n))
        dets = Gori::Probe::Passive.analyze(flow)
        h3 = dets.find { |d| d.code == "tech_http3" }
        h3.should_not be_nil
        h3.not_nil!.evidence.should eq(%(h3-29=":443"; ma=3600))
      end
    end

    it "does not flag Alt-Svc with only h2 or clear" do
      with_store do |store|
        flow1 = capture_flow(store, resp_headers: %(Alt-Svc: h2=":443"\r\n))
        Gori::Probe::Passive.analyze(flow1).map(&.code).should_not contain("tech_http3")

        flow2 = capture_flow(store, resp_headers: %(Alt-Svc: clear\r\n))
        Gori::Probe::Passive.analyze(flow2).map(&.code).should_not contain("tech_http3")
      end
    end

    it "maps tech_http3 to HTTP/3 in tech_summary" do
      summary = Gori::Probe.tech_summary([{"tech_http3", %(h3=":443")}])
      summary.should contain("HTTP/3")
    end

    it "logs an event in the events feed on Alt-Svc h3 discovery" do
      with_store do |store|
        flow = capture_flow(store, resp_headers: %(Alt-Svc: h3=":443"; ma=2592000\r\n))
        scope = Gori::Scope.load(store)
        feed = Channel(Gori::Store::FlowEvent).new(8)
        analyzer = Gori::Probe::Analyzer.new(store, scope, feed, Gori::Probe::Mode::Passive, true)
        analyzer.start
        feed.send(Gori::Store::FlowEvent.new(flow.row.id, :updated))
        sleep 150.milliseconds
        events = store.events_after(0_i64, 50)
        h3_event = events.find { |e| e.kind == "alt_svc_h3" }
        h3_event.should_not be_nil
        ev = h3_event.not_nil!
        ev.source.should eq("probe")
        ev.level.should eq("info")
        ev.message.should contain("acme.test advertised HTTP/3")
        analyzer.stop
      end
    end
  end
end
