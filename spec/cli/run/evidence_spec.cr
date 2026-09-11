require "../../spec_helper"

# `gori run evidence` — the headless half of frozen evidence (#1038). The `abort` branches
# call `exit`, so only the success paths and the pure helpers run here; the store contract
# (what a freeze writes, what survives) is spec/store/issue_evidence_spec.cr's.

module Gori::CLI::Run
  def self.resolve_freeze_ends_for_spec(issue_id : Int64?, ref_s : String?,
                                        ref_id : Int64?) : {Int64, Gori::Store::LinkRefKind, Int64}
    resolve_freeze_ends(issue_id, ref_s, ref_id)
  end

  def self.evidence_line_for_spec(m : Gori::Store::IssueEvidenceMeta) : String
    evidence_line(m)
  end

  def self.evidence_text_for_spec(ev : Gori::Store::IssueEvidence, include_sensitive : Bool) : String
    evidence_text(ev, include_sensitive)
  end
end

private def frozen(store) : Gori::Store::IssueEvidence
  fid = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: "acme.test", port: 443,
    method: "POST", target: "/login", http_version: "HTTP/1.1",
    head: "POST /login HTTP/1.1\r\nHost: acme.test\r\nCookie: sid=abc\r\n\r\n".to_slice, body: "u=a".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    fid, 200, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice, "welcome\e[2Jhi".to_slice, duration_us: 7_i64))
  iid = store.insert_issue("t", Gori::Store::Severity::Low, "acme.test", nil)
  id, status = store.freeze_evidence(iid, Gori::Evidence.from_flow(store.get_flow(fid).not_nil!))
  status.ok?.should be_true
  store.get_evidence(id).not_nil!
end

describe "gori run evidence" do
  it "resolves the freeze triple and admits only the two sources with one exchange" do
    iid, kind, rid = Gori::CLI::Run.resolve_freeze_ends_for_spec(3_i64, "repeater", 9_i64)
    iid.should eq(3_i64)
    kind.should eq(Gori::Store::LinkRefKind::Repeater)
    rid.should eq(9_i64)
    Gori::CLI::Run.resolve_freeze_ends_for_spec(3_i64, "flow", 9_i64)[1].should eq(Gori::Store::LinkRefKind::Flow)
  end

  it "lists one copy per line with its provenance and hash prefixes" do
    with_store do |store|
      ev = frozen(store)
      line = Gori::CLI::Run.evidence_line_for_spec(ev.meta)
      line.should start_with("##{ev.meta.id}  hist ##{ev.meta.source_id}  ")
      line.should contain("POST acme.test/login → 200  #{ev.meta.bytes} bytes  sha256 req #{ev.meta.request_sha256[0, 12]}… res #{ev.meta.response_sha256.not_nil![0, 12]}…")
      # Membership is on the line because the project-wide listing is where an ORPHAN has to
      # be recognisable — the copy no `--issue` listing can reach.
      line.should contain("issues ##{ev.meta.issue_ids.first}")
      store.unlink_evidence(ev.meta.id, ev.meta.issue_ids.first).should be_true
      orphan = store.get_evidence_meta(ev.meta.id).not_nil!
      Gori::CLI::Run.evidence_line_for_spec(orphan).should contain("issues orphaned")
    end
  end

  it "prints the copy with credentials redacted by default, controls stripped, and the raw head on request" do
    with_store do |store|
      ev = frozen(store)
      text = Gori::CLI::Run.evidence_text_for_spec(ev, false)
      text.should contain("frozen evidence ##{ev.meta.id}")
      text.should contain("issues:   ##{ev.meta.issue_ids.first}")
      text.should contain("sha256:   req #{ev.meta.request_sha256}")
      text.should contain("Cookie: [REDACTED]")
      text.should_not contain("sid=abc")
      text.should contain("--- response ---\nHTTP/1.1 200 OK")
      text.should contain("welcome")
      text.should_not contain("\e[2J") # a captured body must not drive the terminal it is printed on
      raw = Gori::CLI::Run.evidence_text_for_spec(ev, true)
      raw.should contain("Cookie: sid=abc")
      raw.should_not contain("--include-sensitive prints them")
    end
  end
end
