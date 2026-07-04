require "./spec_helper"

private def with_store(&)
  path = File.tempname("gori-extra", ".db")
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

describe "Gori::Store scope rules + settings (v3)" do
  it "persists scope rules" do
    with_store do |store|
      store.scope_rules.should be_empty
      store.add_scope_rule("include", "host", "acme.test")
      store.add_scope_rule("include", "host", "acme.test") # UNIQUE(kind,type,pattern) → no dup
      store.add_scope_rule("exclude", "regex", "\\.png$")
      rows = store.scope_rules
      rows.map { |(_, kind, mt, pat)| {kind, mt, pat} }.should eq([
        {"include", "host", "acme.test"},
        {"exclude", "regex", "\\.png$"},
      ])
      store.remove_scope_rule(rows.first[0]) # by id
      store.scope_rules.map { |(_, _, _, pat)| pat }.should eq(["\\.png$"])
    end
  end

  it "persists settings" do
    with_store do |store|
      store.setting("scope_enabled").should be_nil
      store.set_setting("scope_enabled", "1")
      store.setting("scope_enabled").should eq("1")
      store.set_setting("scope_enabled", "0") # upsert
      store.setting("scope_enabled").should eq("0")
    end
  end

  it "deletes a setting so it reads nil again (project network override clear)" do
    with_store do |store|
      store.set_setting("net.bind_port", "9100")
      store.setting("net.bind_port").should eq("9100")
      store.delete_setting("net.bind_port")
      store.setting("net.bind_port").should be_nil
      store.delete_setting("net.bind_port") # deleting an absent key is a no-op
      store.setting("net.bind_port").should be_nil
    end
  end
end

describe "Gori::Store h2 raw frame log (v5)" do
  it "records a connection and its frames, read back in order" do
    with_store do |store|
      conn = store.insert_h2_connection("acme.test", 443, "h2")
      store.insert_h2_frame(conn, "out", 0x1_u8, 0x4_u8, 1_u32, "hdrblock".to_slice) # HEADERS
      store.insert_h2_frame(conn, "in", 0x0_u8, 0x1_u8, 1_u32, "body".to_slice)      # DATA END_STREAM
      store.flush                                                                    # h2 frames are fire-and-forget — barrier before reading them back

      store.count_h2_frames(conn).should eq(2)
      frames = store.h2_frames(conn)
      frames.size.should eq(2)
      frames[0].direction.should eq("out")
      frames[0].type.should eq(1)
      frames[0].stream_id.should eq(1)
      frames[0].length.should eq("hdrblock".bytesize)
      String.new(frames[0].payload).should eq("hdrblock")
      frames[1].direction.should eq("in")
      frames[1].type.should eq(0)
      # DATA (type 0) payloads are NOT persisted — they duplicate flows.request_body/
      # response_body byte-for-byte. The frame log keeps only the metadata + the TRUE byte
      # count in `length` (what the detail-view timeline renders); the payload is emptied.
      frames[1].length.should eq("body".bytesize)
      frames[1].payload.size.should eq(0)
    end
  end

  it "h2_frames(limit) returns the MOST RECENT n frames ascending; count is the full total" do
    with_store do |store|
      conn = store.insert_h2_connection("acme.test", 443, "h2")
      # HEADERS (0x1), not DATA — DATA payloads are dropped on write (dedup), so this window
      # test asserts on retained non-DATA payloads to prove ordering, not the dedup rule.
      10.times { |i| store.insert_h2_frame(conn, "out", 0x1_u8, 0x0_u8, 1_u32, "f#{i}".to_slice) }
      store.flush
      store.count_h2_frames(conn).should eq(10)                           # full count regardless of the window
      win = store.h2_frames(conn, 3)                                      # bounded to the latest 3
      win.map { |f| String.new(f.payload) }.should eq(["f7", "f8", "f9"]) # newest tail, ascending
      store.h2_frames(conn).size.should eq(10)                            # nil limit = all (unchanged)
    end
  end

  it "ws_messages(limit) returns the most recent n messages ascending; count is the full total" do
    with_store do |store|
      fid = 1_i64
      8.times { |i| store.insert_ws_message(fid, "out", 1, "m#{i}".to_slice) }
      store.flush
      store.count_ws_messages(fid).should eq(8)
      store.ws_messages(fid, 2).map { |m| String.new(m.payload) }.should eq(["m6", "m7"])
      store.ws_messages(fid).size.should eq(8)
    end
  end
end

describe "Gori::Store match rules (v4)" do
  it "creates, lists, toggles, and deletes rules" do
    with_store do |store|
      store.match_rules.should be_empty
      id = store.insert_rule(Gori::Store::RuleTarget::Response, "Server: nginx", "Server: gori")
      store.insert_rule(Gori::Store::RuleTarget::Request, "secret", "")

      rules = store.match_rules
      rules.size.should eq(2)
      first = store.match_rules.find!(&.id.==(id))
      first.target.should eq(Gori::Store::RuleTarget::Response)
      first.pattern.should eq("Server: nginx")
      first.replacement.should eq("Server: gori")
      first.enabled?.should be_true

      store.set_rule_enabled(id, false)
      store.match_rules.find!(&.id.==(id)).enabled?.should be_false

      store.delete_rule(id)
      store.match_rules.map(&.pattern).should eq(["secret"])
    end
  end
end

describe "Gori::Store findings (v3)" do
  it "creates, reads, updates, counts, and deletes findings" do
    with_store do |store|
      store.count_findings.should eq(0)
      id = store.insert_finding("Reflected XSS on /search", Gori::Store::Severity::High, "acme.test", 42_i64)
      store.insert_finding("Verbose error", Gori::Store::Severity::Low, "acme.test", nil)

      store.count_findings.should eq(2)
      f = store.get_finding(id).not_nil!
      f.title.should eq("Reflected XSS on /search")
      f.severity.should eq(Gori::Store::Severity::High)
      f.host.should eq("acme.test")
      f.flow_id.should eq(42)
      f.notes.should eq("")

      # ordered by severity desc
      store.findings.first.id.should eq(id)

      store.update_finding(id, severity: Gori::Store::Severity::Critical, notes: "PoC: <script>…")
      updated = store.get_finding(id).not_nil!
      updated.severity.should eq(Gori::Store::Severity::Critical)
      updated.notes.should eq("PoC: <script>…")

      store.delete_finding(id)
      store.count_findings.should eq(1)
      store.get_finding(id).should be_nil
    end
  end
end

private def req_for(target : String, host = "acme.test")
  Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "http", host: host, port: 80,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil)
end

private def respond(store, id : Int64, status : Int32)
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: "HTTP/1.1 #{status}\r\n\r\n".to_slice, body: nil))
end

describe "Gori::Store project-tab aggregates (AT A GLANCE viz)" do
  it "groups flow counts by status, with nil for still-pending flows" do
    with_store do |store|
      respond(store, store.insert_flow(req_for("/a")), 200)
      respond(store, store.insert_flow(req_for("/b")), 200)
      respond(store, store.insert_flow(req_for("/c")), 404)
      respond(store, store.insert_flow(req_for("/d")), 503)
      store.insert_flow(req_for("/pending")) # no response → status stays nil
      store.flush

      counts = store.flow_status_counts.to_h
      counts[200].should eq(2)
      counts[404].should eq(1)
      counts[503].should eq(1)
      counts[nil].should eq(1) # pending
    end
  end

  it "returns an empty status breakdown for a fresh store" do
    with_store do |store|
      store.flow_status_counts.should be_empty
    end
  end

  it "tallies findings by severity into a 5-slot array (0=Info .. 4=Critical)" do
    with_store do |store|
      store.insert_finding("crit", Gori::Store::Severity::Critical, "acme.test", nil)
      store.insert_finding("high a", Gori::Store::Severity::High, "acme.test", nil)
      store.insert_finding("high b", Gori::Store::Severity::High, "acme.test", nil)
      store.insert_finding("info", Gori::Store::Severity::Info, "acme.test", nil)
      store.flush

      f = store.findings_severity_counts
      f[0].should eq(1) # info
      f[2].should eq(0) # medium (none)
      f[3].should eq(2) # high
      f[4].should eq(1) # critical
    end
  end

  it "tallies prism issues by severity" do
    with_store do |store|
      store.upsert_prism_issue(Gori::Prism::Detection.new(
        code: "missing_hsts", category: "security", host: "acme.test",
        url: "http://acme.test/", title: "no hsts", severity: Gori::Store::Severity::Medium))
      store.upsert_prism_issue(Gori::Prism::Detection.new(
        code: "cors_wildcard", category: "security", host: "acme.test",
        url: "http://acme.test/api", title: "cors *", severity: Gori::Store::Severity::High))
      store.flush

      p = store.prism_severity_counts
      p[2].should eq(1) # medium
      p[3].should eq(1) # high
      p[4].should eq(0) # critical (none)
    end
  end
end
