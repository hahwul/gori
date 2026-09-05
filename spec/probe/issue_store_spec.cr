require "../spec_helper"
require "../support/probe_harness"

describe Gori::Store::FlowRow do
  it "#url builds an absolute URL: absolute-form verbatim, non-default port kept, IPv6 bracketed" do
    mk = ->(scheme : String, host : String, port : Int32, target : String) do
      Gori::Store::FlowRow.new(1_i64, 0_i64, scheme, "GET", host, port, target, 200,
        0_i64, Gori::Store::FlowState::Complete)
    end
    mk.call("https", "ex.com", 443, "/a").url.should eq("https://ex.com/a")       # default port omitted
    mk.call("https", "ex.com", 8443, "/a").url.should eq("https://ex.com:8443/a") # non-default port kept
    mk.call("http", "::1", 8080, "/a").url.should eq("http://[::1]:8080/a")       # IPv6 literal bracketed
    mk.call("http", "h", 80, "http://h:8899/x").url.should eq("http://h:8899/x")  # absolute-form verbatim
  end
end

describe "Store bulk Probe dismiss" do
  it "mutes only OPEN issues matching the code/host, leaving already-triaged rows untouched" do
    with_store do |store|
      det = ->(code : String, host : String, url : String) do
        Gori::Probe::Detection.new(code, "headers", host, url, "t", Gori::Store::Severity::Low)
      end
      store.upsert_probe_issue(det.call("missing_hsts", "a.test", "https://a.test/"))
      store.upsert_probe_issue(det.call("missing_csp", "a.test", "https://a.test/"))
      store.upsert_probe_issue(det.call("missing_hsts", "b.test", "https://b.test/"))

      # Promote one to confirmed: a bulk dismiss must NOT clobber an already-triaged row.
      hsts_a = store.probe_issues.find { |i| i.code == "missing_hsts" && i.host == "a.test" }.not_nil!
      store.update_probe_issue_status(hsts_a.id, Gori::Store::Status::Confirmed)

      store.dismiss_probe_by_code("missing_hsts")
      by_key = store.probe_issues.to_h { |i| {"#{i.code}@#{i.host}", i.status} }
      by_key["missing_hsts@a.test"].should eq(Gori::Store::Status::Confirmed)     # triaged → untouched
      by_key["missing_hsts@b.test"].should eq(Gori::Store::Status::FalsePositive) # open → muted
      by_key["missing_csp@a.test"].should eq(Gori::Store::Status::Open)           # other code → untouched

      store.dismiss_probe_by_host("a.test")
      after = store.probe_issues.to_h { |i| {"#{i.code}@#{i.host}", i.status} }
      after["missing_csp@a.test"].should eq(Gori::Store::Status::FalsePositive) # open on host → muted
      after["missing_hsts@a.test"].should eq(Gori::Store::Status::Confirmed)    # still untouched
    end
  end
end

describe "Store#upsert_probe_issue (title stays consistent with severity)" do
  # A code whose title is severity-dependent (reflected_param: HTML ⇒ Medium "Reflected
  # parameter" vs non-HTML ⇒ Low "…(non-HTML context)") merges into one (code, host) group.
  # The title must track the HIGHEST-severity observation, not stay frozen at first-insert —
  # otherwise the escalated badge (MED) sits next to a non-HTML (non-exploitable) title.
  it "adopts the higher-severity title when a group's severity escalates" do
    with_store do |store|
      low = Gori::Probe::Detection.new("reflected_param", "active", "ex.test", "https://ex.test/api",
        "Reflected parameter (non-HTML context)", Gori::Store::Severity::Low, "q")
      high = Gori::Probe::Detection.new("reflected_param", "active", "ex.test", "https://ex.test/page",
        "Reflected parameter", Gori::Store::Severity::Medium, "name")
      store.upsert_probe_issue(low)  # non-HTML seen first
      store.upsert_probe_issue(high) # HTML on same host escalates the group
      row = store.probe_issues.find!(&.code.== "reflected_param")
      row.severity.should eq(Gori::Store::Severity::Medium)
      row.title.should eq("Reflected parameter") # was frozen at "(non-HTML context)"
    end
  end

  it "does not downgrade the title when a later, lower-severity observation merges in" do
    with_store do |store|
      high = Gori::Probe::Detection.new("reflected_param", "active", "ex.test", "https://ex.test/page",
        "Reflected parameter", Gori::Store::Severity::Medium, "name")
      low = Gori::Probe::Detection.new("reflected_param", "active", "ex.test", "https://ex.test/api",
        "Reflected parameter (non-HTML context)", Gori::Store::Severity::Low, "q")
      store.upsert_probe_issue(high)
      store.upsert_probe_issue(low) # lower severity must not clobber the escalated title
      row = store.probe_issues.find!(&.code.== "reflected_param")
      row.severity.should eq(Gori::Store::Severity::Medium)
      row.title.should eq("Reflected parameter")
    end
  end

  it "keeps a fixed-title code's title stable across regroups" do
    with_store do |store|
      d1 = Gori::Probe::Detection.new("missing_csp", "headers", "a.test", "https://a.test/1",
        "Missing Content-Security-Policy", Gori::Store::Severity::Low, nil)
      d2 = Gori::Probe::Detection.new("missing_csp", "headers", "a.test", "https://a.test/2",
        "Missing Content-Security-Policy", Gori::Store::Severity::Low, nil)
      store.upsert_probe_issue(d1)
      store.upsert_probe_issue(d2)
      store.probe_issues.find!(&.code.== "missing_csp").title.should eq("Missing Content-Security-Policy")
    end
  end
end

# The in-memory fold (`gori run probe`, MCP probe_scan) and the SQL upsert (TUI/capture) must
# agree on which codes accumulate their evidence. They did not: Group kept its own three-code
# copy of the list while Store's had grown to five, so a headless scan reported ONE of a host's
# third-party hosts and dropped the rest. Both now read Store::ACCUMULATING_EVIDENCE_CODES.
describe "Store#upsert_probe_issues (batched ↔ sequential parity)" do
  # `upsert_probe_issues` exists to collapse N writer round-trips into one, so its whole licence
  # is that it replays the SAME statements in the SAME order — no folding. That is only worth
  # anything if it is checked against the sequential path it replaced, on the cases where a fold
  # WOULD have diverged: composition onto a row that already exists (the Group parity specs below
  # only cover an empty store), an accumulating-evidence code, a severity raise that drags the
  # title with it, affected-URL dedup, and a suppression landing mid-batch.
  det = ->(code : String, host : String, url : String, sev : Gori::Store::Severity, title : String, evidence : String?) do
    Gori::Probe::Detection.new(code, "headers", host, url, title, sev, evidence)
  end

  # Everything but the id and the timestamps: the batch shares one now_us by design, and two
  # stores are opened microseconds apart, so times cannot be compared across the two runs.
  shape = ->(i : Gori::Store::ProbeIssue) do
    {i.code, i.category, i.host, i.title, i.severity, i.status,
     i.hit_count, i.affected, i.evidence, i.sample_flow_id}
  end

  run_both = ->(seed : Array(Gori::Probe::Detection), batch : Array(Gori::Probe::Detection), suppress : Array({String, String})) do
    out = [] of Array({String, String, String, String, Gori::Store::Severity, Gori::Store::Status, Int64, Array(String), String?, Int64?})
    2.times do |mode|
      with_store do |store|
        seed.each { |d| store.upsert_probe_issue(d) } # the pre-existing rows, same either way
        # A durable suppression is only ever created by a hard delete, so make one the real way.
        suppress.each do |(code, host)|
          store.upsert_probe_issue(det.call(code, host, "https://#{host}/seed",
            Gori::Store::Severity::Low, "t", nil))
          row = store.probe_issues.find { |i| i.code == code && i.host == host }.not_nil!
          store.delete_probe_issue(row.id)
        end
        if mode == 0
          batch.each { |d| store.upsert_probe_issue(d) } # sequential: one commit per detection
        else
          store.upsert_probe_issues(batch) # batched: one commit for all of them
        end
        out << store.probe_issues.map { |i| shape.call(i) }
      end
    end
    out
  end

  it "writes the same rows as the per-detection loop it replaced" do
    seed = [
      det.call("missing_sri", "acme.test", "https://acme.test/a", Gori::Store::Severity::Low, "SRI", "cdn.a.test"),
      det.call("weak_csp", "acme.test", "https://acme.test/a", Gori::Store::Severity::Low, "CSP", "first"),
    ]
    batch = [
      # accumulating code, new label → evidence must UNION, not overwrite and not concatenate blobs
      det.call("missing_sri", "acme.test", "https://acme.test/b", Gori::Store::Severity::Low, "SRI", "cdn.b.test"),
      # …and a third, so the batch composes onto its own earlier write, not just onto the seed
      det.call("missing_sri", "acme.test", "https://acme.test/c", Gori::Store::Severity::Low, "SRI", "cdn.c.test"),
      # same affected URL again → must dedup, hit_count still climbs
      det.call("missing_sri", "acme.test", "https://acme.test/b", Gori::Store::Severity::Low, "SRI", "cdn.b.test"),
      # non-accumulating code → first-wins evidence survives
      det.call("weak_csp", "acme.test", "https://acme.test/b", Gori::Store::Severity::Low, "CSP", "second"),
      # severity raise → title must be adopted with it
      det.call("weak_csp", "acme.test", "https://acme.test/c", Gori::Store::Severity::High, "CSP (worse)", "third"),
      # a brand-new (code, host) inside the batch → INSERT branch
      det.call("cors_wildcard", "other.test", "https://other.test/x", Gori::Store::Severity::Medium, "CORS", nil),
    ]
    seq, bat = run_both.call(seed, batch, [] of {String, String})
    bat.should eq(seq)
    # and the fold actually happened, so the comparison above is not two empty lists
    sri = bat.find { |r| r[0] == "missing_sri" }.not_nil!
    sri[8].not_nil!.should contain("cdn.c.test")
  end

  it "honours a suppression that lands mid-batch exactly as the sequential path did" do
    seed = [] of Gori::Probe::Detection
    batch = [
      det.call("missing_sri", "acme.test", "https://acme.test/a", Gori::Store::Severity::Low, "SRI", "cdn.a.test"),
      det.call("weak_csp", "acme.test", "https://acme.test/a", Gori::Store::Severity::Low, "CSP", "first"),
    ]
    seq, bat = run_both.call(seed, batch, [{"weak_csp", "acme.test"}])
    bat.should eq(seq)
    bat.map(&.[](0)).should eq(["missing_sri"]) # the suppressed code never lands
  end
end

describe "Gori::Probe evidence accumulation (Group ↔ Store parity)" do
  # Build N detections of one code on one host, each carrying a different evidence label.
  private_labels = ->(code : String, labels : Array(String)) do
    labels.map_with_index do |label, i|
      Gori::Probe::Detection.new(code, "headers", "acme.test", "https://acme.test/#{i}",
        "t", Gori::Store::Severity::Low, label)
    end
  end

  it "accumulates missing_sri third-party hosts in a headless fold, not just the first" do
    dets = private_labels.call("missing_sri", ["cdn.a.test", "cdn.b.test", "cdn.c.test"])
    g = Gori::Probe.group(dets)
    g.size.should eq(1)
    ev = g.first.evidence.not_nil!
    ev.should contain("cdn.a.test")
    ev.should contain("cdn.b.test")
    ev.should contain("cdn.c.test")
  end

  it "accumulates cookie names so a host with several unflagged cookies names them all" do
    dets = private_labels.call("cookie_no_httponly", ["sid", "csrf", "pref"])
    ev = Gori::Probe.group(dets).first.evidence.not_nil!
    %w[sid csrf pref].each { |n| ev.should contain(n) }
  end

  it "folds evidence identically in memory and in the DB" do
    with_store do |store|
      dets = private_labels.call("missing_sri", ["cdn.a.test", "cdn.b.test"])
      dets.each { |d| store.upsert_probe_issue(d) }
      stored = store.probe_issues.find(&.code.==("missing_sri")).not_nil!
      stored.evidence.should eq(Gori::Probe.group(dets).first.evidence)
    end
  end

  it "keeps a first-wins sample for a code that is NOT in the accumulating set" do
    dets = private_labels.call("weak_csp", ["first", "second"])
    ev = Gori::Probe.group(dets).first.evidence.not_nil!
    ev.should eq("first")
  end

  # merge_evidence dedups by splitting the stored string on ", ", so a per-cookie requirement
  # list joined the same way would be torn into fragments that read as other cookies' evidence.
  it "joins one cookie's unmet prefix requirements with ' + ' so the merge cannot split them" do
    with_store do |store|
      head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n" \
             "Set-Cookie: __Host-sid=a; Domain=acme.test\r\n\r\n"
      hit = probe_analyze(store, resp_head: head).find(&.code.==("cookie_prefix_violation")).not_nil!
      ev = hit.evidence.not_nil!
      ev.should contain("Secure + Path=/ + no Domain")
      # Two violating cookies on one host merge into two whole labels, not five fragments.
      other = Gori::Probe::Detection.new("cookie_prefix_violation", "cookies", "acme.test",
        "https://acme.test/2", "t", Gori::Store::Severity::Medium, "__Secure-tok: needs Secure")
      merged = Gori::Probe.group([hit, other]).first.evidence.not_nil!
      merged.split(", ").size.should eq(2)
    end
  end
end
