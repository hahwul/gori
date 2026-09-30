require "../spec_helper"

private def triage_flow(store : Gori::Store, target : String, method = "GET") : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
  id
end

private def triage_hit(store : Gori::Store, url : String, flow_id : Int64?, code = "secret_in_url",
                       category = "infoleak") : Nil
  store.upsert_probe_issue(Gori::Probe::Detection.new(
    code: code, category: category, host: "acme.test", url: url, title: "token in URL",
    severity: Gori::Store::Severity::High, evidence: "token", flow_id: flow_id))
end

# A promoted finding is the start of a report, so the Issue must carry what the finding knew —
# not only its title, severity and one flow (#1377).
describe "Gori::Probe::Triage.promote report carry-over" do
  it "writes the CWE, detail, remediation and every affected URL into the notes" do
    with_store do |store|
      a = triage_flow(store, "/a?token=1")
      b = triage_flow(store, "/b?token=2")
      triage_hit(store, "https://acme.test/a?token=1", a)
      triage_hit(store, "https://acme.test/b?token=2", b)
      issue = store.probe_issues.first

      res = Gori::Probe::Triage.promote(store, issue)
      notes = store.get_issue(res.issue_id.not_nil!).not_nil!.notes
      notes.should contain("secret_in_url")
      notes.should contain(Gori::Probe.cwe_id("secret_in_url").not_nil!)
      notes.should contain(Gori::Probe.cwe_name("secret_in_url").not_nil!)
      notes.should contain("Detail: token")
      notes.should contain(Gori::Probe.remediation("secret_in_url"))
      notes.should contain("- https://acme.test/a?token=1")
      notes.should contain("- https://acme.test/b?token=2")
    end
  end

  it "links every affected URL's captured flow as evidence, the sample once" do
    with_store do |store|
      a = triage_flow(store, "/a?token=1")
      b = triage_flow(store, "/b?token=2")
      triage_flow(store, "/b?token=2", method: "POST") # same URL, another endpoint
      triage_hit(store, "https://acme.test/a?token=1", a)
      triage_hit(store, "https://acme.test/b?token=2", b)
      triage_hit(store, "https://acme.test/gone?token=3", nil) # nothing captured for it
      issue = store.probe_issues.first

      res = Gori::Probe::Triage.promote(store, issue)
      links = store.list_links(Gori::Store::LinkOwnerKind::Issue, res.issue_id.not_nil!)
      links.map(&.ref_id).sort!.should eq([a, b].sort!)
      links.all?(&.ref_kind.flow?).should be_true
    end
  end

  it "uses a custom rule's own description in place of the built-in remediation" do
    with_store do |store|
      rid = store.insert_probe_custom_rule("Internal hostname", "Strip internal hostnames from responses.",
        "response", "body", "string", "corp.internal", Gori::Store::Severity::Low)
      triage_hit(store, "https://acme.test/x", nil, code: "custom_p_#{rid}", category: "custom")
      issue = store.probe_issues.first

      res = Gori::Probe::Triage.promote(store, issue)
      notes = store.get_issue(res.issue_id.not_nil!).not_nil!.notes
      notes.should contain("Description:\nStrip internal hostnames from responses.")
      notes.should_not contain("CWE-")
    end
  end
end
