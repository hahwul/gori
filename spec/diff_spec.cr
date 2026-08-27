require "./spec_helper"
require "json"

# `Gori::Diff` — the retest axis: two projects, one endpoint-scale report. The three
# commitments the module doc names are what these examples pin: one notion of "the same
# endpoint" (the Sitemap's folding, over the UNION of both sides), one notion of "the same
# response" (a tolerance band, not byte equality), and absence reported as absence.

private def diff_store(&)
  path = File.tempname("gori-diff", ".db")
  store = Gori::Store.open(path, background_index: false)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def diff_flow(store : Gori::Store, target : String, *,
                      host : String = "acme.test", method : String = "GET",
                      status : Int32? = 200, ctype : String? = "application/json",
                      size : Int32 = 100, at : Int64 = 1_000_000_i64) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: at, scheme: "https", host: host, port: 443,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  if st = status
    body = "x" * size
    store.update_response(Gori::Store::CapturedResponse.new(
      flow_id: id, status: st, content_type: ctype,
      head: "HTTP/1.1 #{st} OK\r\n\r\n".to_slice, body: body.to_slice,
      body_size: body.bytesize.to_i64))
  end
  id
end

private def snapshot_of(store : Gori::Store, label : String) : Gori::Diff::Snapshot
  Gori::Diff::Snapshot.read(store, label, "#{label}.db", raise_on_error: true)
end

private def report_of(a : Gori::Store, b : Gori::Store, *, issues : Int32 = 0) : Gori::Diff::Report
  Gori::Diff.compare(issues > 0 ? a : nil, snapshot_of(a, "A"), snapshot_of(b, "B"), issue_limit: issues)
end

private def verdict_for(r : Gori::Diff::Report, path : String, method : String = "GET") : Gori::Diff::Verdict?
  r.rows.find { |row| row.key.path == path && row.key.method == method }.try(&.verdict)
end

describe Gori::Diff::Templates do
  it "keys an id-bearing endpoint by the folded template, so two engagements match" do
    t = Gori::Diff::Templates.new([
      {"h", "GET", "/users/3f2a8b1c-1111-2222-3333-444444444444"},
      {"h", "GET", "/users/aa112233-5566-7788-99aa-bbccddeeff00"},
    ])
    t.template("h", "/users/3f2a8b1c-1111-2222-3333-444444444444").should eq("/users/{uuid}")
  end

  it "folds a numeric run to a value-INDEPENDENT label" do
    # `group_sequences!` labels its fold with the ids it captured ("[1, 2, 3 … +9]"), which
    # is a fine tree row and a useless key: the other engagement captured other ids, so the
    # route would not match itself.
    entries = (1..12).map { |i| {"h", "GET", "/p/#{i}"} }
    t = Gori::Diff::Templates.new(entries)
    t.template("h", "/p/7").should eq("/p/{n}")
    t.template("h", "/p/12").should eq("/p/{n}")
  end

  it "keeps a route segment literal — /v1 and /v2 are different endpoints" do
    t = Gori::Diff::Templates.new([{"h", "GET", "/v1/ping"}, {"h", "GET", "/v2/ping"}])
    t.template("h", "/v1/ping").should eq("/v1/ping")
    t.template("h", "/v2/ping").should eq("/v2/ping")
  end

  it "keeps route structure UNDER a fold" do
    t = Gori::Diff::Templates.new([
      {"h", "GET", "/users/3f2a8b1c-1111-2222-3333-444444444444/orders"},
      {"h", "GET", "/users/aa112233-5566-7788-99aa-bbccddeeff00/orders"},
    ])
    t.template("h", "/users/3f2a8b1c-1111-2222-3333-444444444444/orders").should eq("/users/{uuid}/orders")
  end

  it "folds query variants onto their path" do
    t = Gori::Diff::Templates.new([{"h", "GET", "/search?q=widgets"}, {"h", "GET", "/search?q=other"}])
    t.template("h", "/search?q=widgets").should eq("/search")
  end

  it "folds the UNION, so a fold threshold met on one side alone still keys both" do
    # Two uuids on side A, ONE on side B. Folding each side alone leaves B literal
    # (TEMPLATE_GROUP_THRESHOLD is 2), which would report the route as both removed AND
    # added — the exact noise the folding exists to remove.
    a = [{"h", "GET", "/u/3f2a8b1c-1111-2222-3333-444444444444"},
         {"h", "GET", "/u/aa112233-5566-7788-99aa-bbccddeeff00"}]
    b = [{"h", "GET", "/u/bb998877-1111-2222-3333-444444444444"}]
    t = Gori::Diff::Templates.new(a + b)
    t.template("h", "/u/bb998877-1111-2222-3333-444444444444").should eq("/u/{uuid}")
  end

  it "answers with the target's own tree path for a host it never saw" do
    t = Gori::Diff::Templates.new([{"h", "GET", "/a"}])
    t.template("other.test", "https://other.test/b/").should eq("/b")
  end
end

describe Gori::Sitemap do
  it ".node_path re-derives the tree path a target lands on, without building a tree" do
    # The diff keys on `Node#path`; if this disagreed with `add`, a diff row would stop
    # naming the row the Sitemap tab draws.
    hosts = Gori::Sitemap.build([{"h", "GET", "https://h/api/users/"}, {"h", "GET", "/x?a=1"}, {"h", "GET", "/"}])
    paths = [] of String
    hosts.each { |host| Gori::Sitemap.post_order(host) { |n| paths << n.path unless n.path.empty? } }
    paths.should contain(Gori::Sitemap.node_path("https://h/api/users/"))
    paths.should contain(Gori::Sitemap.node_path("/x?a=1"))
    paths.should contain(Gori::Sitemap.node_path("/"))
    Gori::Sitemap.node_path("https://h/api/users/").should eq("/api/users")
    Gori::Sitemap.node_path("/x?a=1").should eq("/x?a=1")
    Gori::Sitemap.node_path("/").should eq("/")
  end
end

describe Gori::Diff::Compare do
  it "reports a dynamic-but-equivalent response as unchanged, not changed" do
    diff_store do |a|
      diff_store do |b|
        diff_flow(a, "/dash", size: 10_000)
        diff_flow(b, "/dash", size: 10_400) # 4% churn — a banner, a counter, a timestamp
        verdict_for(report_of(a, b), "/dash").should eq(Gori::Diff::Verdict::Unchanged)
      end
    end
  end

  it "reports a response that genuinely collapsed as changed" do
    diff_store do |a|
      diff_store do |b|
        diff_flow(a, "/dash", size: 10_000)
        diff_flow(b, "/dash", size: 40)
        verdict_for(report_of(a, b), "/dash").should eq(Gori::Diff::Verdict::Changed)
      end
    end
  end

  it "names the auth axis when an endpoint starts refusing" do
    diff_store do |a|
      diff_store do |b|
        diff_flow(a, "/admin", status: 200)
        diff_flow(b, "/admin", status: 403)
        row = report_of(a, b).rows.find! { |r| r.key.path == "/admin" }
        row.verdict.should eq(Gori::Diff::Verdict::Changed)
        row.changes.map(&.axis).should contain(Gori::Diff::Axis::Auth)
        row.changes.first.to_s.should eq("auth: not required → required")
      end
    end
  end

  it "tolerates a status that moved inside its class" do
    diff_store do |a|
      diff_store do |b|
        diff_flow(a, "/create", status: 200)
        diff_flow(b, "/create", status: 201)
        verdict_for(report_of(a, b), "/create").should eq(Gori::Diff::Verdict::Unchanged)
      end
    end
  end

  it "reports a content-type flip" do
    diff_store do |a|
      diff_store do |b|
        diff_flow(a, "/feed", ctype: "application/json")
        diff_flow(b, "/feed", ctype: "application/xml")
        row = report_of(a, b).rows.find! { |r| r.key.path == "/feed" }
        row.changes.map(&.axis).should eq([Gori::Diff::Axis::ContentType])
      end
    end
  end

  it "ignores a content-type PARAMETER — a charset is not a change" do
    diff_store do |a|
      diff_store do |b|
        diff_flow(a, "/feed", ctype: "application/json")
        diff_flow(b, "/feed", ctype: "application/json; charset=utf-8")
        verdict_for(report_of(a, b), "/feed").should eq(Gori::Diff::Verdict::Unchanged)
      end
    end
  end
end

describe "Gori::Diff verdicts" do
  it "separates 'not requested in B' from 'B asked and got 404'" do
    diff_store do |a|
      diff_store do |b|
        diff_flow(a, "/never-revisited")
        diff_flow(a, "/deleted")
        diff_flow(b, "/deleted", status: 404)
        diff_flow(b, "/brand-new")
        r = report_of(a, b)
        verdict_for(r, "/never-revisited").should eq(Gori::Diff::Verdict::Removed)
        verdict_for(r, "/deleted").should eq(Gori::Diff::Verdict::Gone)
        verdict_for(r, "/brand-new").should eq(Gori::Diff::Verdict::Added)
      end
    end
  end

  it "counts every verdict even when a caller lists only some" do
    diff_store do |a|
      diff_store do |b|
        diff_flow(a, "/same")
        diff_flow(b, "/same")
        diff_flow(b, "/new")
        counts = report_of(a, b).counts
        counts[Gori::Diff::Verdict::Unchanged].should eq(1)
        counts[Gori::Diff::Verdict::Added].should eq(1)
        # Every bucket is present with a number, so a reader can never mistake "not listed"
        # for "none" (see `Render::LISTED`, which drops unchanged from the LISTING only).
        Gori::Diff::Verdict.values.each { |v| counts.has_key?(v).should be_true }
      end
    end
  end

  it "does not call a POST and a GET on one path the same endpoint" do
    diff_store do |a|
      diff_store do |b|
        diff_flow(a, "/thing", method: "GET")
        diff_flow(b, "/thing", method: "POST")
        r = report_of(a, b)
        verdict_for(r, "/thing", "GET").should eq(Gori::Diff::Verdict::Removed)
        verdict_for(r, "/thing", "POST").should eq(Gori::Diff::Verdict::Added)
      end
    end
  end
end

describe "Gori::Diff no-response sentinel" do
  it "treats status 0 as 'no response', not as a reachable status" do
    # gori writes `status = 0` for an aborted intercept, an upstream failure and a pending
    # flow abandoned at shutdown. `0` is truthy in Crystal, so the obvious `if st = status`
    # put it in the observed set — where `reachable?` (`< 400`) then read a connection
    # failure as "A reached this endpoint".
    key = Gori::Diff::Key.new("acme.test", "GET", "/x")
    f = Gori::Diff::Facts.new(key)
    f.observe(Gori::Store::EndpointObservation.new(
      "acme.test", "GET", "/x", 0, nil, 1_i64, nil, nil, 1_i64, 1_i64, 1_i64))
    f.statuses.should be_empty
    f.pending?.should be_true
    f.reachable?.should be_false
  end

  it "does not report `gone` against a side that never reached the endpoint" do
    diff_store do |a|
      diff_store do |b|
        # Every capture on A errored; B answers 404. Nothing was ever reached, so this is
        # not evidence the endpoint was removed.
        id = a.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
          method: "GET", target: "/x", http_version: "HTTP/1.1",
          head: "GET /x HTTP/1.1\r\n\r\n".to_slice, source: Gori::FlowSource::Kind::Proxy))
        a.update_response(Gori::Store::CapturedResponse.new(
          flow_id: id, status: 0, head: Bytes.new(0),
          state: Gori::Store::FlowState::Error, error: "connection refused"))
        diff_flow(b, "/x", status: 404)
        verdict_for(report_of(a, b), "/x").should_not eq(Gori::Diff::Verdict::Gone)
      end
    end
  end
end

describe Gori::Diff::Report do
  it "states the coverage of each side beside the counts" do
    diff_store do |a|
      diff_store do |b|
        diff_flow(a, "/one", at: 1_000_000_i64)
        diff_flow(a, "/two", at: 2_000_000_i64)
        diff_flow(b, "/one", at: 3_000_000_i64)
        r = report_of(a, b)
        r.a.flows.should eq(2)
        r.a.endpoints.should eq(2)
        r.a.hosts.should eq(1)
        r.a.first_seen.should eq(1_000_000_i64)
        r.a.last_seen.should eq(2_000_000_i64)
        r.b.endpoints.should eq(1)
      end
    end
  end

  it "leads its caveats with the one the counts must not be read without" do
    diff_store do |a|
      diff_store { |b| report_of(a, b).caveats.first.should contain("coverage gap") }
    end
  end

  it "warns when one side captured with the scope lens on and the other with it off" do
    # Identical rules, different enabled flag: one side recorded a subset, the other
    # everything — exactly what the caveat is for, and what a rules-only comparison missed.
    diff_store do |a|
      diff_store do |b|
        [a, b].each { |s| s.add_scope_rule("include", "host", "acme.test") }
        a.set_setting(Gori::Scope::SETTING_ENABLED, "1")
        diff_flow(a, "/x")
        diff_flow(b, "/x")
        report_of(a, b).scope_mismatch?.should be_true
      end
    end
  end

  it "does not warn when the same rules were entered in a different order" do
    diff_store do |a|
      diff_store do |b|
        a.add_scope_rule("include", "host", "one.test")
        a.add_scope_rule("include", "host", "two.test")
        b.add_scope_rule("include", "host", "two.test")
        b.add_scope_rule("include", "host", "one.test")
        diff_flow(a, "/x")
        diff_flow(b, "/x")
        report_of(a, b).scope_mismatch?.should be_false
      end
    end
  end

  it "warns when the two projects were captured under different scope rules" do
    diff_store do |a|
      diff_store do |b|
        a.add_scope_rule("include", "host", "acme.test")
        diff_flow(a, "/x")
        diff_flow(b, "/x")
        r = report_of(a, b)
        r.scope_mismatch?.should be_true
        r.caveats.any?(&.includes?("scope rules differ")).should be_true
      end
    end
  end

  it "says so when a side's endpoint read was capped" do
    diff_store do |a|
      diff_store do |b|
        3.times { |i| diff_flow(a, "/p#{i}") }
        snap_a = Gori::Diff::Snapshot.read(a, "A", "a.db", limit: 2, raise_on_error: true)
        snap_b = Gori::Diff::Snapshot.read(b, "B", "b.db", raise_on_error: true)
        r = Gori::Diff.compare(nil, snap_a, snap_b)
        r.a.truncated.should be_true
        r.caveats.any?(&.includes?("hit its cap")).should be_true
      end
    end
  end
end

describe "Gori::Diff issue retest" do
  it "reports the endpoint each live issue sits on, without sending anything" do
    diff_store do |a|
      diff_store do |b|
        fid = diff_flow(a, "/admin", status: 200)
        diff_flow(b, "/admin", status: 403)
        a.insert_issue("Broken access control", Gori::Store::Severity::High, "acme.test", fid)
        retest = report_of(a, b, issues: 10).issues
        retest.size.should eq(1)
        retest.first.verdict.should eq(Gori::Diff::Verdict::Changed)
        retest.first.note.should contain("answers differently")
      end
    end
  end

  it "tells the operator an unchanged endpoint means the finding likely still stands" do
    diff_store do |a|
      diff_store do |b|
        fid = diff_flow(a, "/leak")
        diff_flow(b, "/leak")
        a.insert_issue("Data leak", Gori::Store::Severity::Medium, "acme.test", fid)
        report_of(a, b, issues: 10).issues.first.note.should contain("still stands")
      end
    end
  end

  it "reports how many live issues the cap left unasked" do
    diff_store do |a|
      diff_store do |b|
        fid = diff_flow(a, "/x")
        diff_flow(b, "/x")
        3.times { |i| a.insert_issue("Finding #{i}", Gori::Store::Severity::Low, "acme.test", fid) }
        r = report_of(a, b, issues: 2)
        r.issues.size.should eq(2)
        r.issues_dropped.should eq(1)
        r.caveats.any?(&.includes?("issue retest stopped")).should be_true
      end
    end
  end

  it "separates 'the link points outside this diff' from 'there is no link'" do
    # A `--query`/`--in-scope` narrowing (or the endpoint cap) leaves a perfectly good
    # evidence pointer resolving to no row. Calling that "no linked capture" tells the
    # operator their link is broken when it is intact.
    diff_store do |a|
      diff_store do |b|
        fid = diff_flow(a, "/elsewhere", host: "other.test")
        diff_flow(a, "/x")
        diff_flow(b, "/x")
        a.insert_issue("Filed against another host", Gori::Store::Severity::Low, "other.test", fid)
        snap_a = Gori::Diff::Snapshot.read(a, "A", "a.db", filter: Gori::QL.parse("host:acme.test"), raise_on_error: true)
        snap_b = Gori::Diff::Snapshot.read(b, "B", "b.db", raise_on_error: true)
        retest = Gori::Diff.compare(a, snap_a, snap_b, issue_limit: 10).issues
        retest.first.key.should_not be_nil # the pointer resolved
        retest.first.verdict.should be_nil # ...but this diff did not cover it
        retest.first.note.should contain("outside this diff")
      end
    end
  end

  it "says an issue cannot be keyed rather than skipping it" do
    diff_store do |a|
      diff_store do |b|
        a.insert_issue("Filed from memory", Gori::Store::Severity::Low, "acme.test", nil)
        retest = report_of(a, b, issues: 10).issues
        retest.size.should eq(1)
        retest.first.key.should be_nil
        retest.first.note.should contain("no linked capture")
      end
    end
  end

  it "leaves a resolved issue out — it is not a question about this engagement" do
    diff_store do |a|
      diff_store do |b|
        fid = diff_flow(a, "/fixed")
        id = a.insert_issue("Old finding", Gori::Store::Severity::Low, "acme.test", fid)
        a.update_issue(id, status: Gori::Store::Status::Resolved)
        report_of(a, b, issues: 10).issues.should be_empty
      end
    end
  end
end

describe Gori::Diff::Render do
  it "lists every verdict but unchanged by default, and counts all five either way" do
    diff_store do |a|
      diff_store do |b|
        diff_flow(a, "/same")
        diff_flow(b, "/same")
        diff_flow(b, "/new")
        text = Gori::Diff::Render.text(report_of(a, b))
        text.should contain("unchanged 1")
        text.should_not contain("### Unchanged")
        text.should contain("/new")
        text.should_not match(/^  GET acme\.test\/same/m)
      end
    end
  end

  it "names the ambiguity of 'removed' in the heading itself" do
    Gori::Diff::Render.heading(Gori::Diff::Verdict::Removed).should contain("coverage gap")
    Gori::Diff::Render.heading(Gori::Diff::Verdict::Gone).should contain("404/410")
  end

  it "renders a Markdown section with a coverage table" do
    diff_store do |a|
      diff_store do |b|
        diff_flow(a, "/gone-now")
        diff_flow(b, "/gone-now", status: 404)
        md = Gori::Diff::Render.markdown(report_of(a, b))
        md.should contain("## Retest diff — A → B")
        md.should contain("| flows | 1 | 1 |")
        md.should contain("`GET acme.test/gone-now`")
        md.should contain("> ")
      end
    end
  end

  it "fences an endpoint whose captured path holds a backtick" do
    # A path comes off the wire. An unfenced backtick closes the code span and spills the
    # rest of the row into prose in the deliverable operators are told to paste. (A query
    # cannot carry one this far — `fold_queries!` collapses the variants onto the path — so
    # the fixture puts it in a path SEGMENT, which stays literal.)
    diff_store do |a|
      diff_store do |b|
        diff_flow(b, "/re`port`")
        md = Gori::Diff::Render.markdown(report_of(a, b))
        md.should contain("`` GET acme.test/re`port` ``")
      end
    end
  end

  it "escapes a pipe in a label so it cannot split a Markdown table cell" do
    diff_store do |a|
      diff_store do |b|
        snap_a = Gori::Diff::Snapshot.read(a, "q3 | rerun", "a.db", raise_on_error: true)
        snap_b = Gori::Diff::Snapshot.read(b, "B", "b.db", raise_on_error: true)
        md = Gori::Diff::Render.markdown(Gori::Diff.compare(nil, snap_a, snap_b))
        md.should contain("q3 \\| rerun")
      end
    end
  end

  it "emits JSON an agent can read the verdict and the drill-down flow out of" do
    diff_store do |a|
      diff_store do |b|
        diff_flow(a, "/admin", status: 200)
        fid = diff_flow(b, "/admin", status: 403)
        j = JSON.parse(Gori::Diff::Render.json(report_of(a, b)))
        j["counts"]["changed"].as_i.should eq(1)
        row = j["endpoints"].as_a.first
        row["verdict"].as_s.should eq("changed")
        row["path"].as_s.should eq("/admin")
        row["b"]["sample_flow_id"].as_i64.should eq(fid)
        row["changes"].as_a.map(&.["axis"].as_s).should contain("auth")
        j["caveats"].as_a.first.as_s.should contain("coverage gap")
      end
    end
  end

  it "formats a timestamp exactly as the MCP and CLI surfaces do" do
    # Three copies of this three-liner exist on purpose (see `Render.iso`); they must agree.
    us = 1_777_636_800_123_456_i64
    Gori::Diff::Render.iso(us).should eq(Gori::MCP::Serialize.unix_micros_iso(us))
    Gori::Diff::Render.iso(us).should eq(Gori::CLI::Output.iso_time_utc(us))
  end
end

describe Gori::Tolerance do
  it "widens the band to twice the observed jitter" do
    # No jitter → the proportional floor. Jitter → twice it, once that exceeds the floor.
    Gori::Tolerance.band(1000_i64, 1000_i64, 1000_i64, Gori::Tolerance::LENGTH_FLOOR).should eq(10)
    Gori::Tolerance.band(900_i64, 1000_i64, 1000_i64, Gori::Tolerance::LENGTH_FLOOR).should eq(200)
  end

  it "keeps a fixed floor under a tiny response" do
    Gori::Tolerance.band(4_i64, 4_i64, 4_i64, Gori::Tolerance::LENGTH_FLOOR).should eq(8)
  end
end
