require "../spec_helper"
require "../support/probe_harness"

private def make_issue(code, host = "acme.test") : Gori::Store::ProbeIssue
  Gori::Store::ProbeIssue.new(1_i64, code, "headers", host, "t",
    Gori::Store::Severity::Low, Gori::Store::Status::Open, 1_i64, [] of String, nil, nil, 1_i64, 1_i64)
end

# Flip one built-in probe rule on/off the way the Rules sub-tab does. `Probe.set_rule_enabled`
# (never a bare add/delete) is the single place the DEFAULT-OFF flip lives.
private def set_probe_rule_enabled(store, id : String, enabled : Bool) : Nil
  dis = store.probe_disabled_rules
  Gori::Probe.set_rule_enabled(dis, id, enabled)
  store.set_probe_disabled_rules(dis)
end

describe Gori::Probe::Analyzer do
  # Active only processes live channel events unless backfill re-arms recent History.
  # Without that, switching Passive→Active (or reopening a project already on Active)
  # never probes flows that already completed passive analysis.
  it "set_mode Active and start(Active) re-arm without raising on stored flows" do
    with_store do |store|
      probe_capture_flow(store, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        target: "/search?q=hi", body: "<p>hi</p>")
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")
      feed = Channel(Gori::Store::FlowEvent).new(8)

      # start while already Active (persisted project) — backfill path
      a = Gori::Probe::Analyzer.new(store, scope, feed, Gori::Probe::Mode::Active, true)
      a.start
      sleep 50.milliseconds # let the backfill fiber run (no network assert — queue may drop)
      a.stop

      # Passive → Active transition mid-session
      feed2 = Channel(Gori::Store::FlowEvent).new(8)
      b = Gori::Probe::Analyzer.new(store, scope, feed2, Gori::Probe::Mode::Passive, true)
      b.start
      b.set_mode(Gori::Probe::Mode::Active)
      sleep 50.milliseconds
      b.stop
    end
  end

  # The disabled-rule list is the ONLY thing between a disabled active rule and a real request.
  # `store.probe_disabled_rules` used to swallow a store/parse failure into an empty set — read
  # as "nothing is disabled" — so a corrupt value made ACTIVE probing send everything. The
  # commit that added the `degraded` flag could never fire because of that swallow.
  it "fails closed on active probing when the disabled-rule list cannot be read" do
    with_store do |store|
      probe_capture_flow(store, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        target: "/reflect?q=hi", body: "<p>hi</p>")
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")
      detail = store.recent_flows(1).first.try { |r| store.get_flow(r.id) }.not_nil!

      # Sanity: a readable (empty) disabled list estimates at least one active rule for this flow.
      feed = Channel(Gori::Store::FlowEvent).new(8)
      ok = Gori::Probe::Analyzer.new(store, scope, feed, Gori::Probe::Mode::Active, true)
      ok.active_estimate(detail).should_not be_empty

      # Corrupt the stored value to a truncated JSON blob — probe_disabled_rules now RAISES.
      store.@db.exec("INSERT OR REPLACE INTO settings (key, value) VALUES ('probe_disabled_rules', '[\"reflected')")
      expect_raises(JSON::ParseException) { store.probe_disabled_rules_strict } # active-send read raises
      store.probe_disabled_rules.should be_empty                                # display read degrades

      # An analyzer built on the corrupt store is degraded → estimates NOTHING (sends nothing).
      feed2 = Channel(Gori::Store::FlowEvent).new(8)
      degraded = Gori::Probe::Analyzer.new(store, scope, feed2, Gori::Probe::Mode::Active, true)
      degraded.active_estimate(detail).should be_empty
    end
  end

  # AGGRESSIVE drives the SAME automatic pipeline as ACTIVE (probes_actively?), but with widened
  # Options (unsafe methods + raised caps). It stays scope-gated. No network assert — the queue may
  # drop and sends to acme.test won't resolve; this verifies the pipeline re-arms and persists the
  # mode without raising over an in-scope unsafe-method (POST) flow.
  it "AGGRESSIVE mode re-arms the pipeline + persists over an in-scope POST flow" do
    with_store do |store|
      probe_capture_flow(store, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        target: "/submit?q=hi", method: "POST", body: "<p>hi</p>")
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")

      # start already in AGGRESSIVE (persisted project) — backfill path over the POST
      feed = Channel(Gori::Store::FlowEvent).new(8)
      a = Gori::Probe::Analyzer.new(store, scope, feed, Gori::Probe::Mode::Aggressive, true)
      a.start
      sleep 50.milliseconds
      a.stop

      # ACTIVE → AGGRESSIVE transition mid-session re-arms and persists the new mode.
      feed2 = Channel(Gori::Store::FlowEvent).new(8)
      b = Gori::Probe::Analyzer.new(store, scope, feed2, Gori::Probe::Mode::Active, true)
      b.start
      b.set_mode(Gori::Probe::Mode::Aggressive)
      store.probe_mode.should eq(Gori::Probe::Mode::Aggressive)
      sleep 50.milliseconds
      b.stop
    end
  end

  it "does not re-count a buffered WebSocket secret on every later frame (incremental rescan)" do
    with_store do |store|
      detail = probe_capture_flow(store,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
        target: "/ws", status: 101, content_type: nil,
        req_headers: "Upgrade: websocket\r\nConnection: Upgrade\r\n")
      fid = detail.row.id
      store.insert_ws_message(fid, "in", 1, "token=#{PROBE_AWS_KEY_ID}".to_slice) # secret frame
      scope = Gori::Scope.load(store)
      feed = Channel(Gori::Store::FlowEvent).new(8)
      a = Gori::Probe::Analyzer.new(store, scope, feed, Gori::Probe::Mode::Passive, true)
      a.start
      feed.send(Gori::Store::FlowEvent.new(fid, :updated)) # initial full scan → detect once
      sleep 120.milliseconds
      store.probe_issues.find(&.code.== "secret_in_ws").not_nil!.hit_count.should eq(1_i64)
      # A later, secret-free frame must NOT re-scan the still-buffered secret frame.
      store.insert_ws_message(fid, "in", 1, "ping".to_slice)
      feed.send(Gori::Store::FlowEvent.new(fid, :updated)) # rescan → only the new frame
      sleep 120.milliseconds
      store.probe_issues.find(&.code.== "secret_in_ws").not_nil!.hit_count.should eq(1_i64)
      a.stop
    end
  end

  it "pages a >WS_MSG_CAP WebSocket backlog without skipping a band (no missed secret)" do
    with_store do |store|
      detail = probe_capture_flow(store,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
        target: "/ws", status: 101, content_type: nil,
        req_headers: "Upgrade: websocket\r\nConnection: Upgrade\r\n")
      fid = detail.row.id
      store.insert_ws_message(fid, "in", 1, "hello".to_slice) # frame 1 (no secret) → sets hwm
      scope = Gori::Scope.load(store)
      feed = Channel(Gori::Store::FlowEvent).new(8)
      a = Gori::Probe::Analyzer.new(store, scope, feed, Gori::Probe::Mode::Passive, true)
      a.start
      feed.send(Gori::Store::FlowEvent.new(fid, :updated)) # initial scan; hwm = frame 1
      sleep 120.milliseconds
      # A burst of >WS_MSG_CAP(200) frames arrives with the secret in frame ~30 — the band a
      # last-200-window rescan would drop (window would be frames ~52..251).
      250.times do |k|
        payload = k == 28 ? "token=#{PROBE_AWS_KEY_ID}" : "frame#{k}"
        store.insert_ws_message(fid, "in", 1, payload.to_slice)
      end
      feed.send(Gori::Store::FlowEvent.new(fid, :updated)) # one rescan must page the whole backlog
      sleep 250.milliseconds
      store.probe_issues.count(&.code.== "secret_in_ws").should eq(1) # the banded secret was caught
      a.stop
    end
  end

  it "scans a WebSocket flow FIRST seen with a large backlog from its oldest frame" do
    with_store do |store|
      detail = probe_capture_flow(store,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
        target: "/ws", status: 101, content_type: nil,
        req_headers: "Upgrade: websocket\r\nConnection: Upgrade\r\n")
      fid = detail.row.id
      # A >WS_MSG_CAP backlog already exists before the FIRST scan (the live :updated was dropped
      # and catch_up picks it up late); the secret is in an OLD frame the last-window would skip.
      260.times do |k|
        payload = k == 20 ? "token=#{PROBE_AWS_KEY_ID}" : "frame#{k}"
        store.insert_ws_message(fid, "in", 1, payload.to_slice)
      end
      scope = Gori::Scope.load(store)
      feed = Channel(Gori::Store::FlowEvent).new(8)
      a = Gori::Probe::Analyzer.new(store, scope, feed, Gori::Probe::Mode::Passive, true)
      a.start
      feed.send(Gori::Store::FlowEvent.new(fid, :updated)) # first scan pages the whole backlog from frame 1
      sleep 250.milliseconds
      store.probe_issues.count(&.code.== "secret_in_ws").should eq(1)
      a.stop
    end
  end

  # The WS high-water mark must never advance over frames no rule READ. With ws_payloads off the
  # rescan still paged the buffer and moved the mark, so re-enabling the built-in could never
  # reach the frames captured while it was off — they were permanently invisible.
  it "detects a WS secret while ws_payloads is enabled (control for the disabled-rule case)" do
    with_store do |store|
      detail = probe_capture_flow(store,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
        target: "/ws", status: 101, content_type: nil,
        req_headers: "Upgrade: websocket\r\nConnection: Upgrade\r\n")
      fid = detail.row.id
      store.probe_disabled_rules_strict.includes?("ws_payloads").should be_false
      scope = Gori::Scope.load(store)
      feed = Channel(Gori::Store::FlowEvent).new(8)
      a = Gori::Probe::Analyzer.new(store, scope, feed, Gori::Probe::Mode::Passive, true)
      a.start
      store.insert_ws_message(fid, "in", 1, "token=#{PROBE_AWS_KEY_ID}".to_slice)
      feed.send(Gori::Store::FlowEvent.new(fid, :updated))
      sleep 200.milliseconds
      a.stop
      store.probe_issues.find(&.code.== "secret_in_ws").should_not be_nil
    end
  end

  it "re-enabling ws_payloads still scans the frames captured while it was off" do
    with_store do |store|
      detail = probe_capture_flow(store,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
        target: "/ws", status: 101, content_type: nil,
        req_headers: "Upgrade: websocket\r\nConnection: Upgrade\r\n")
      fid = detail.row.id
      # Rule OFF before Analyzer.new — initialize reads the disabled set once.
      set_probe_rule_enabled(store, "ws_payloads", false)
      store.probe_disabled_rules_strict.includes?("ws_payloads").should be_true

      scope = Gori::Scope.load(store)
      feed = Channel(Gori::Store::FlowEvent).new(8)
      a = Gori::Probe::Analyzer.new(store, scope, feed, Gori::Probe::Mode::Passive, true)
      a.start

      # The secret rides a frame captured while the rule was OFF — nothing reads it.
      store.insert_ws_message(fid, "in", 1, "token=#{PROBE_AWS_KEY_ID}".to_slice)
      feed.send(Gori::Store::FlowEvent.new(fid, :updated))
      sleep 200.milliseconds
      store.probe_issues.find(&.code.== "secret_in_ws").should be_nil # rule is off — expected

      # Operator re-enables the built-in; the TUI calls reload_rule_config.
      set_probe_rule_enabled(store, "ws_payloads", true)
      a.reload_rule_config
      # Recovery is driven by the NEXT rescan_ws, not by reload_rule_config itself. No NEW
      # ws_message: the secret exists only in the frame written while the rule was off.
      feed.send(Gori::Store::FlowEvent.new(fid, :updated))
      sleep 200.milliseconds
      a.stop

      store.probe_issues.find(&.code.== "secret_in_ws").should_not be_nil
    end
  end

  it "bumps store.probe_generation on persist and honors session suppress after hard delete" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nServer: x\r\n\r\n",
        target: "/", body: "<p>hi</p>")
      scope = Gori::Scope.load(store)
      feed = Channel(Gori::Store::FlowEvent).new(8)
      a = Gori::Probe::Analyzer.new(store, scope, feed, Gori::Probe::Mode::Passive, true)
      g0 = store.probe_generation

      a.scan_detail(detail)
      store.probe_generation.should be > g0
      before = store.count_probe_issues
      before.should be > 0

      # Simulate UI hard-delete + suppress of one issue (suppress first, like the TUI)
      issue = store.probe_issues.first
      a.suppress(issue.code, issue.host)
      store.delete_probe_issue(issue.id)
      store.count_probe_issues.should eq(before - 1)

      # Fresh flow on the same host: suppressed code must not resurrect
      d2 = probe_capture_flow(store, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nServer: x\r\n\r\n",
        target: "/b", body: "<p>hi</p>")
      a.scan_detail(d2)
      store.probe_issues.count { |i| i.code == issue.code && i.host == issue.host }.should eq(0)
    end
  end

  # Regression: delete used to only mute for the current process. Project leave/re-open
  # built a new Analyzer (empty @suppressed) and Active backfill re-inserted the row.
  it "hard-delete survives a new Analyzer (project re-open) via durable suppressions" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nServer: nginx\r\n\r\n",
        target: "/", body: "<p>hi</p>")
      scope = Gori::Scope.load(store)
      feed = Channel(Gori::Store::FlowEvent).new(8)
      a = Gori::Probe::Analyzer.new(store, scope, feed, Gori::Probe::Mode::Passive, true)
      a.scan_detail(detail)
      issue = store.probe_issues.find(&.code.==("tech_server")).not_nil!
      code, host = issue.code, issue.host

      # TUI delete path: memory suppress + store delete (store also writes probe_suppressions)
      a.suppress(code, host)
      store.delete_probe_issue(issue.id)
      store.probe_suppressed?(code, host).should be_true
      store.count_probe_issues.should eq(store.probe_issues.size)

      # Simulate leave_project → open again: brand-new Analyzer loads durable suppressions
      feed2 = Channel(Gori::Store::FlowEvent).new(8)
      b = Gori::Probe::Analyzer.new(store, scope, feed2, Gori::Probe::Mode::Passive, true)
      b.start # load_suppressions
      d2 = probe_capture_flow(store, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nServer: nginx\r\n\r\n",
        target: "/again", body: "<p>hi</p>")
      b.scan_detail(d2)
      store.probe_issues.count { |i| i.code == code && i.host == host }.should eq(0)

      # Store-level gate alone (no analyzer suppress) also blocks direct upsert
      det = Gori::Probe::Detection.new(code, "tech", host, "https://#{host}/", "Server: nginx",
        Gori::Store::Severity::Info, "nginx", d2.row.id)
      store.upsert_probe_issue(det)
      store.probe_issues.count { |i| i.code == code && i.host == host }.should eq(0)

      b.stop
    end
  end

  it "clear_probe_issues drops durable suppressions so a full rescan can re-find" do
    with_store do |store|
      d = Gori::Probe::Detection.new("reflected_param", "active", "xss.test", "https://xss.test/",
        "Reflected parameter", Gori::Store::Severity::Medium, "q", 1_i64)
      store.upsert_probe_issue(d)
      id = store.probe_issues.first.id
      store.delete_probe_issue(id)
      store.probe_suppressed?("reflected_param", "xss.test").should be_true

      store.clear_probe_issues
      store.probe_suppressed?("reflected_param", "xss.test").should be_false
      store.upsert_probe_issue(d)
      store.count_probe_issues.should eq(1)
    end
  end
end

describe Gori::Probe::Mode do
  it "persists per-project and defaults to Passive" do
    with_store do |store|
      store.probe_mode.should eq(Gori::Probe::Mode::Passive) # default when unset
      store.set_probe_mode(Gori::Probe::Mode::Active)
      store.probe_mode.should eq(Gori::Probe::Mode::Active)
    end
  end

  it "round-trips its label and cycles" do
    Gori::Probe::Mode.from_setting("off").should eq(Gori::Probe::Mode::Off)
    Gori::Probe::Mode.from_setting(nil).should eq(Gori::Probe::Mode::Passive)
    Gori::Probe::Mode.from_setting("aggressive").should eq(Gori::Probe::Mode::Aggressive)
    Gori::Probe::Mode::Off.cycle.should eq(Gori::Probe::Mode::Passive)
    # OFF → PASSIVE → ACTIVE → AGGRESSIVE → OFF
    Gori::Probe::Mode::Active.cycle.should eq(Gori::Probe::Mode::Aggressive)
    Gori::Probe::Mode::Aggressive.cycle.should eq(Gori::Probe::Mode::Off)
  end

  it "persists and reloads Aggressive" do
    with_store do |store|
      store.set_probe_mode(Gori::Probe::Mode::Aggressive)
      store.probe_mode.should eq(Gori::Probe::Mode::Aggressive)
    end
  end

  it "probes_actively? covers Active and Aggressive only" do
    Gori::Probe::Mode::Off.probes_actively?.should be_false
    Gori::Probe::Mode::Passive.probes_actively?.should be_false
    Gori::Probe::Mode::Active.probes_actively?.should be_true
    Gori::Probe::Mode::Aggressive.probes_actively?.should be_true
  end
end

describe "Gori::Probe::Filter (incomplete terms)" do
  it "treats a mid-typed negated field term as a no-op (does not blank the list)" do
    issues = [make_issue("missing_csp"), make_issue("missing_hsts")]
    Gori::Probe::Filter.parse("-host:").apply(issues).size.should eq(2)
    Gori::Probe::Filter.parse("host:").apply(issues).size.should eq(2)
    # a complete negated term still filters
    Gori::Probe::Filter.parse("-code:csp").apply(issues).map(&.code).should eq(["missing_hsts"])
  end

  it "reports whether the query explicitly constrains status (drives the open-only lens)" do
    Gori::Probe::Filter.parse("host:api").has_status_term?.should be_false
    Gori::Probe::Filter.parse("").has_status_term?.should be_false
    Gori::Probe::Filter.parse("status:fp host:api").has_status_term?.should be_true
    Gori::Probe::Filter.parse("-st:open").has_status_term?.should be_true
  end
end

describe Gori::Probe do
  describe ".group" do
    it "folds detections exactly like Store#upsert_probe_issue (severity/hit_count/affected/evidence)" do
      with_store do |store|
        det = ->(code : String, host : String, url : String, s : Gori::Store::Severity, ev : String?) do
          Gori::Probe::Detection.new(code, "headers", host, url, "t", s, ev)
        end
        low = Gori::Store::Severity::Low
        medium = Gori::Store::Severity::Medium
        dets = [
          det.call("missing_csp", "a.test", "https://a.test/1", low, nil),
          det.call("missing_csp", "a.test", "https://a.test/2", medium, "x"), # severity rises, url accumulates
          det.call("missing_csp", "a.test", "https://a.test/1", low, "y"),    # dup url (no add); evidence already set
          det.call("missing_hsts", "b.test", "https://b.test/1", low, nil),
        ]
        dets.each { |d| store.upsert_probe_issue(d) }
        stored = store.probe_issues.to_h { |i| {"#{i.code}@#{i.host}", i} }
        grouped = Gori::Probe.group(dets).to_h { |g| {"#{g.code}@#{g.host}", g} }

        grouped.size.should eq(stored.size)
        grouped.each do |key, g|
          s = stored[key]
          g.severity.should eq(s.severity)
          g.hit_count.to_i64.should eq(s.hit_count)
          g.affected.sort.should eq(s.affected.sort)
          g.evidence.should eq(s.evidence) # first non-nil wins (COALESCE)
          g.title.should eq(s.title)       # title tracks the same (highest-severity) observation
        end

        csp = grouped["missing_csp@a.test"]
        csp.severity.should eq(medium)                                   # max seen
        csp.hit_count.should eq(3)                                       # every observation
        csp.affected.should eq(["https://a.test/1", "https://a.test/2"]) # de-duplicated
        csp.evidence.should eq("x")                                      # first non-nil, not "y"
      end
    end

    it "sorts by severity desc and caps the affected list at PROBE_AFFECTED_CAP (hit_count still climbs)" do
      cap = Gori::Store::PROBE_AFFECTED_CAP
      dets = [] of Gori::Probe::Detection
      (cap + 10).times do |i|
        dets << Gori::Probe::Detection.new("missing_csp", "headers", "a.test",
          "https://a.test/#{i}", "t", Gori::Store::Severity::Low)
      end
      dets << Gori::Probe::Detection.new("secret_in_body", "infoleak", "a.test",
        "https://a.test/x", "t", Gori::Store::Severity::High)
      groups = Gori::Probe.group(dets)
      groups.first.code.should eq("secret_in_body") # High sorts above Low
      csp = groups.find!(&.code.==("missing_csp"))
      csp.hit_count.should eq(cap + 10) # every observation counted
      csp.affected.size.should eq(cap)  # but the URL list is capped
    end

    it "accumulates distinct secret/error types for one (code, host) group (not first-wins)" do
      dets = [
        Gori::Probe::Detection.new("secret_in_body", "infoleak", "a.test", "https://a.test/1", "t", Gori::Store::Severity::High, "AWS access key id"),
        Gori::Probe::Detection.new("secret_in_body", "infoleak", "a.test", "https://a.test/2", "t", Gori::Store::Severity::High, "GitHub token"),
        Gori::Probe::Detection.new("secret_in_body", "infoleak", "a.test", "https://a.test/1", "t", Gori::Store::Severity::High, "AWS access key id"),
      ]
      g = Gori::Probe.group(dets).find!(&.code.==("secret_in_body"))
      g.evidence.not_nil!.should contain("AWS access key id")
      g.evidence.not_nil!.should contain("GitHub token") # was masked by COALESCE-first-wins
      g.hit_count.should eq(3)
      # a non-type-labeled code still keeps the first sample (evidence is a one-off value)
      ip = [
        Gori::Probe::Detection.new("private_ip_leak", "infoleak", "b.test", "https://b.test/", "t", Gori::Store::Severity::Low, "10.0.0.1"),
        Gori::Probe::Detection.new("private_ip_leak", "infoleak", "b.test", "https://b.test/", "t", Gori::Store::Severity::Low, "192.168.0.1"),
      ]
      Gori::Probe.group(ip).find!(&.code.==("private_ip_leak")).evidence.should eq("10.0.0.1")
    end

    it "adopts the higher-severity title on escalation, staying consistent with the store" do
      with_store do |store|
        low = Gori::Probe::Detection.new("reflected_param", "active", "ex.test", "https://ex.test/api",
          "Reflected parameter (non-HTML context)", Gori::Store::Severity::Low, "q")
        high = Gori::Probe::Detection.new("reflected_param", "active", "ex.test", "https://ex.test/page",
          "Reflected parameter", Gori::Store::Severity::Medium, "name")
        dets = [low, high] # non-HTML first, then HTML escalates
        g = Gori::Probe.group(dets).find!(&.code.== "reflected_param")
        g.severity.should eq(Gori::Store::Severity::Medium)
        g.title.should eq("Reflected parameter") # not frozen at "(non-HTML context)"
        # and the headless group matches what the store persists for the same detections
        dets.each { |d| store.upsert_probe_issue(d) }
        stored = store.probe_issues.find!(&.code.== "reflected_param")
        g.title.should eq(stored.title)
        g.severity.should eq(stored.severity)
      end
    end

    it "tags the same code on different hosts as separate groups" do
      dets = [
        Gori::Probe::Detection.new("missing_hsts", "headers", "a.test", "https://a.test/", "t", Gori::Store::Severity::Low),
        Gori::Probe::Detection.new("missing_hsts", "headers", "b.test", "https://b.test/", "t", Gori::Store::Severity::Low),
      ]
      Gori::Probe.group(dets).map(&.host).sort!.should eq(["a.test", "b.test"])
    end
  end
end

describe Gori::Probe, "WebSocket + Repeater sources" do
  it "fingerprints a WebSocket upgrade and includes the path in evidence" do
    with_store do |store|
      req_headers = "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: chat\r\n"
      head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
      detail = probe_capture_flow(store, head, target: "/ws/chat", status: 101, content_type: nil,
        req_headers: req_headers)
      codes = probe_codes_of(Gori::Probe::Passive.analyze(detail))
      codes.should contain("tech_websocket")
      det = Gori::Probe::Passive.analyze(detail).find!(&.code.==("tech_websocket"))
      det.evidence.not_nil!.should contain("WebSocket")
      det.evidence.not_nil!.should contain("/ws/chat")
      det.evidence.not_nil!.should contain("chat")
      store.upsert_probe_issue(det)
      store.probe_tech_summary.should contain("WebSocket")
    end
  end

  it "flags secrets in captured WebSocket text messages (type only, never the value)" do
    with_store do |store|
      head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
      detail = probe_capture_flow(store, head, target: "/ws", status: 101, content_type: nil,
        req_headers: "Upgrade: websocket\r\nConnection: Upgrade\r\n")
      secret = PROBE_AWS_KEY_ID
      msgs = [
        Gori::Store::WsMessage.new(1_i64, detail.row.id, nil, 1_i64, "in", 1, "token=#{secret}".to_slice),
      ]
      dets = Gori::Probe::Passive.analyze(detail, msgs)
      hit = dets.find { |d| d.code == "secret_in_ws" }.not_nil!
      hit.evidence.should eq("AWS access key id")
      hit.evidence.not_nil!.should_not contain(secret)
    end
  end

  # Binary frames used to be skipped, and a spec asserted that without recording why. protobuf /
  # msgpack / CBOR over WebSocket is the mainstream encoding for realtime APIs and a token rides
  # in such a frame as an ordinary ASCII string field, so skipping them was a plain false negative
  # on the transport this rule exists for. No deframing is involved: the patterns are ASCII vendor
  # prefixes, and the projection maps every non-printable byte to a space.
  it "flags a secret embedded in a BINARY WebSocket frame" do
    with_store do |store|
      head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
      detail = probe_capture_flow(store, head, target: "/ws", status: 101, content_type: nil,
        req_headers: "Upgrade: websocket\r\nConnection: Upgrade\r\n")
      secret = PROBE_AWS_KEY_ID
      # A protobuf-ish frame: field tags and lengths around an ASCII string field.
      payload = Bytes.new(secret.bytesize + 6)
      payload[0] = 0x0a_u8; payload[1] = secret.bytesize.to_u8
      secret.to_slice.copy_to(payload.to_unsafe + 2, secret.bytesize)
      payload[secret.bytesize + 2] = 0x10_u8
      payload[secret.bytesize + 3] = 0xff_u8 # invalid UTF-8, so the text path would have mangled it
      payload[secret.bytesize + 4] = 0x00_u8
      payload[secret.bytesize + 5] = 0x80_u8
      bin = [Gori::Store::WsMessage.new(2_i64, detail.row.id, nil, 1_i64, "in", 2, payload)]
      hit = Gori::Probe::Passive.analyze(detail, bin).find { |d| d.code == "secret_in_ws" }.not_nil!
      hit.evidence.should eq("AWS access key id")
      hit.evidence.not_nil!.should_not contain(secret)
    end
  end

  it "does not scan control frames or gori's own advisory rows" do
    with_store do |store|
      head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
      detail = probe_capture_flow(store, head, target: "/ws", status: 101, content_type: nil,
        req_headers: "Upgrade: websocket\r\nConnection: Upgrade\r\n")
      secret = PROBE_AWS_KEY_ID
      # opcode 8 = close: a control frame carries no application payload.
      close = [Gori::Store::WsMessage.new(3_i64, detail.row.id, nil, 1_i64, "in", 8, secret.to_slice)]
      Gori::Probe::Passive.analyze(detail, close).map(&.code).should_not contain("secret_in_ws")
    end
  end

  it "finds nothing in a binary frame that carries no credential shape" do
    with_store do |store|
      head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
      detail = probe_capture_flow(store, head, target: "/ws", status: 101, content_type: nil,
        req_headers: "Upgrade: websocket\r\nConnection: Upgrade\r\n")
      noise = Bytes.new(4096) { |i| ((i * 37) % 256).to_u8 }
      Gori::Probe::Passive.analyze(detail, [
        Gori::Store::WsMessage.new(4_i64, detail.row.id, nil, 1_i64, "in", 2, noise),
      ]).map(&.code).should_not contain("secret_in_ws")
    end
  end

  it "builds a FlowDetail from a RepeaterRecord and passive-scans it" do
    with_store do |store|
      req = "GET /api HTTP/1.1\r\nHost: repeater.test\r\n\r\n"
      resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nServer: nginx/1.25\r\n\r\n"
      id = store.insert_repeater("https://repeater.test", req.to_slice, false, true, nil, 0)
      store.update_repeater_response(id, resp.to_slice, "<html/>".to_slice, nil, 12_i64)
      rec = store.get_repeater(id).not_nil!
      # get_repeater may not load response blobs — use full repeaters list
      rec = store.repeaters.find!(&.id.== id)
      detail = Gori::Probe.detail_from_repeater(rec).not_nil!
      detail.row.host.should eq("repeater.test")
      detail.row.method.should eq("GET")
      detail.row.status.should eq(200)
      dets = Gori::Probe::Passive.analyze(detail).map { |d|
        Gori::Probe.with_source(d, repeater_id: id)
      }
      dets.map(&.code).should contain("tech_server")
      dets.map(&.code).should contain("missing_csp")
      dets.each { |d| store.upsert_probe_issue(d) }
      issue = store.probe_issues.find!(&.code.==("tech_server"))
      issue.sample_repeater_id.should eq(id)
      issue.sample_flow_id.should be_nil
    end
  end

  it "parses request headers from an LF-joined Repeater request (normalizes the head to CRLF)" do
    with_store do |store|
      # The Repeater editor serializes request text with BARE-LF line endings; without CRLF
      # normalization Http1.parse_headers returns an empty list and every request-side rule
      # (CORS Origin, Basic auth, request tech) silently misses.
      req = "POST /login HTTP/1.1\nHost: acme.test\nAuthorization: Basic dXNlcjpwYXNz\n" \
            "Origin: https://evil.example\n"
      resp = "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://evil.example\r\n" \
             "Access-Control-Allow-Credentials: true\r\n\r\n"
      id = store.insert_repeater("http://acme.test", req.to_slice, false, false, nil, 0)
      store.update_repeater_response(id, resp.to_slice, "{}".to_slice, nil, 5_i64)
      rec = store.repeaters.find!(&.id.== id)
      detail = Gori::Probe.detail_from_repeater(rec).not_nil!
      detail.row.method.should eq("POST")
      codes = Gori::Probe::Passive.analyze(detail).map(&.code)
      codes.should contain("insecure_basic_auth")   # Authorization header now visible over http
      codes.should contain("cors_reflected_origin") # Origin header now visible
    end
  end

  it "skips Repeater tabs with no response head" do
    with_store do |store|
      id = store.insert_repeater("https://empty.test", "GET / HTTP/1.1\r\nHost: empty.test\r\n\r\n".to_slice,
        false, true, nil, 0)
      rec = store.repeaters_meta.find!(&.id.== id)
      Gori::Probe.detail_from_repeater(rec).should be_nil
    end
  end
end

describe "Gori::Probe.tech_summary" do
  it "does not raise on invalid-UTF-8 evidence (a hostile Server header byte)" do
    # tech_summary runs on the TUI render fiber (project_view / probe_view); a value-tech
    # evidence with a raw 0x80-0xFF byte would make the PCRE split raise and crash the whole
    # TUI. The `.scrub` keeps the first token instead. Byte 0x80 → U+FFFD, dropped by the split.
    rows = [{"tech_server", String.new(Bytes[0x6e, 0x67, 0x69, 0x6e, 0x78, 0x80])}] of {String, String?}
    out = Gori::Probe.tech_summary(rows)
    out.size.should eq(1)
    out[0].starts_with?("nginx").should be_true
    out[0].valid_encoding?.should be_true
  end
end

# Probe::Triage is the ONE promotion/dismiss implementation the TUI, `gori run probe`, and the
# MCP probe_* tools all call — so a finding triaged from any surface lands in the same state.
describe "Gori::Probe::Triage" do
  it "promotes once, marking the source Confirmed so a repeat cannot duplicate" do
    with_store do |store|
      store.upsert_probe_issue(Gori::Probe::Detection.new(
        code: "secret_in_url", category: "infoleak", host: "acme.test", title: "token in URL",
        severity: Gori::Store::Severity::High, url: "https://acme.test/x", evidence: "tok"))
      issue = store.probe_issues.first

      res = Gori::Probe::Triage.promote(store, issue)
      res.promoted?.should be_true
      created = store.get_issue(res.issue_id.not_nil!).not_nil!
      created.title.should eq(issue.title)
      created.severity.should eq(Gori::Store::Severity::High)
      store.get_probe_issue(issue.id).not_nil!.status.confirmed?.should be_true

      # Re-read (the in-memory `issue` still holds the pre-promotion status). A second call
      # reports AlreadyPromoted — distinct from Failed, which means nothing was written and
      # a retry IS correct.
      again = store.get_probe_issue(issue.id).not_nil!
      second = Gori::Probe::Triage.promote(store, again)
      second.promoted?.should be_false
      second.outcome.already_promoted?.should be_true
      second.issue_id.should be_nil
      store.issues.size.should eq(1)
    end
  end

  it "dismisses only an OPEN finding and re-opens anything else" do
    with_store do |store|
      store.upsert_probe_issue(Gori::Probe::Detection.new(
        code: "secret_in_url", category: "infoleak", host: "acme.test", title: "t",
        severity: Gori::Store::Severity::High, url: "https://acme.test/x"))
      issue = store.probe_issues.first

      Gori::Probe::Triage.toggle_dismiss(store, issue).false_positive?.should be_true
      Gori::Probe::Triage.toggle_dismiss(store, store.get_probe_issue(issue.id).not_nil!).open?.should be_true

      # A Confirmed (promoted) finding re-opens rather than being dismissed — the asymmetry
      # the TUI's `c` has always had, now shared.
      store.update_probe_issue_status(issue.id, Gori::Store::Status::Confirmed)
      Gori::Probe::Triage.toggle_dismiss(store, store.get_probe_issue(issue.id).not_nil!).open?.should be_true
    end
  end
end

describe "Gori::Probe.cwe" do
  # A CWE key that no rule emits is dead metadata nobody would ever notice — a typo'd code
  # ("secret_in_urls") maps forever and shows up nowhere. REMEDIATION is the de-facto registry
  # of emitted codes, so every CWE key must appear there.
  it "maps only codes that findings actually carry" do
    stray = Gori::Probe::CWE.keys.reject { |c| Gori::Probe::REMEDIATION.has_key?(c) }
    stray.should be_empty
  end

  # The inverse: a documented code with no CWE must be one of the deliberate exclusions, so a
  # newly added rule cannot quietly ship unclassified. Update this list ONLY with the reason.
  it "leaves exactly the deliberately unmapped codes without a CWE" do
    unmapped = Gori::Probe::REMEDIATION.keys.reject { |c| Gori::Probe::CWE.has_key?(c) }
    # jwt_in_body/jwt_in_ws are Info notes on where tokens flow — handing the client its own
    # token is the design, not a weakness (see Passive::Secrets::JWT). cookie_broad_domain is an
    # Info hardening note (a Domain scoped to a parent domain) that no CWE fits cleanly — 1275 is
    # SameSite, 565/732/668 all overreach — so it stays unmapped rather than borrowing a wrong id.
    unmapped.sort.should eq(["cookie_broad_domain", "jwt_in_body", "jwt_in_ws"])
  end

  it "renders the canonical CWE-<id> identifier and name" do
    Gori::Probe.cwe_id("dom_xss").should eq("CWE-79")
    Gori::Probe.cwe_name("cookie_no_httponly").should eq("Sensitive Cookie Without 'HttpOnly' Flag")
    Gori::Probe.cwe_id("tech_server").should be_nil
    Gori::Probe.cwe_id("custom_p_1").should be_nil
  end

  it "emits cwe fields in the shared JSON shape, and omits them when unmapped" do
    mapped = Gori::Probe::Detection.new("dom_xss", "client", "acme.test", "https://acme.test/",
      "t", Gori::Store::Severity::Medium)
    json = Gori::CLI::Output.probe_group_json(Gori::Probe.group([mapped]).first)
    JSON.parse(json)["cwe"].as_s.should eq("CWE-79")
    JSON.parse(json)["cwe_name"].as_s.should contain("Cross-site Scripting")

    tech = Gori::Probe::Detection.new("tech_server", "tech", "acme.test", "https://acme.test/",
      "t", Gori::Store::Severity::Info)
    parsed = JSON.parse(Gori::CLI::Output.probe_group_json(Gori::Probe.group([tech]).first))
    parsed.as_h.has_key?("cwe").should be_false
    parsed.as_h.has_key?("cwe_name").should be_false
  end
end
